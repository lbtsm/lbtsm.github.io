---
title: "IO多路复用"
date: 2026-11-17T20:57:54+08:00
draft: false
tags: []
categories: []
summary: ""
---

## Summary

说起 epoll,流传最广的说法是:"epoll 比 select 快,因为它用了红黑树和 mmap,复杂度是 O(1)。"这句话几乎每个词都不太对:mmap 是以讹传讹,epoll 根本没用它;红黑树管的是"登记和注销",和"为什么快"关系不大;O(1) 也不成立,`epoll_wait` 返回 k 个事件至少要做 O(k) 的事。真正的原因只有两条:**名单常驻内核,不用每轮重交;就绪的连接由回调主动报到,不用挨个去查。** 而且 epoll 并不是在所有场景下都更快。

把这两条想清楚,线上几种怪现象也就有了解释:某几条连接偶尔"卡住",`ss` 看到 `Recv-Q` 里躺着数据却没人读;服务跑几天就报 `too many open files`;CPU 吃满,`strace` 里 `epoll_wait` 不停地立刻返回;多个 worker 进程的机器 CPU 一跳一跳,`accept` 大量返回 `EAGAIN`。

还是那家饭馆。厨师把一万家供应商列成单子交给经理,"谁的货到了叫我"。饭馆前后换过三任经理,第一任每轮拿着整张单子挨家打电话,第二任换了本好用点的本子还是挨家打,第三任让每家供应商装了个按钮,货一到按一下,经理桌上的灯就亮。这三任经理就是 select、poll、epoll。

---

## 先搞清楚:一个线程怎么同时等很多个 fd

线程阻塞在一个 fd 上,是被内核挂起、移出运行队列,等数据到了再被唤醒。"唤醒"要靠一个具体的机制:**内核里每个 socket 都有一条等待队列**,想等这个 socket 的线程在队列里挂一个条目;网卡数据进了接收缓冲区,内核就沿着这条队列把挂着的条目逐个"叫一声"。

一个线程只能在一个地方睡,却想等一万个 socket,办法只能是:**在一万条等待队列上各挂一个条目,任何一个被叫到都把它唤醒。** 所有多路复用机制都绕不开这件事,它们的区别只在三个问题上的答法:

```
                          select / poll                  epoll
① 名单放哪              每次调用由程序交一遍            登记一次,常驻内核
② 怎么知道谁就绪        醒来后把整张名单挨个查一遍      回调把就绪的放进一个链表
③ 结果怎么给回去        整张名单拷回去,程序再挨个看    只拷就绪的那几个
```

①决定每轮要拷多少数据、挂多少次等待队列;②③决定每轮要查多少个 fd。前两代在三个问题上都和"总连接数"成正比,epoll 把②③降到了和"就绪连接数"成正比。后面的所有细节,都是这张表的展开。

---

## 讲 select / poll / epoll 前必须认识的几个词

- **就绪**:fd 现在做某个操作不会阻塞。**可读**包括四种情况:接收缓冲区里有数据;对端关闭了连接(此时 `read` 返回 0);连接出错;监听 socket 上有已完成握手、等着 `accept` 的连接。**可写**是发送缓冲区有空位。注意"对端关闭"也算可读——忘了处理 `read` 返回 0,是后面"CPU 空转"的常见根源。
- **等待队列(wait queue)**:内核里挂在每个 socket(以及管道、eventfd 等)上的一条链表,记着"谁在等我"。状态变化时内核遍历它,调用每个条目上的唤醒函数。
- **关注列表与就绪列表**:`epoll(7)` 用的两个词。关注列表(interest list)是"你让内核盯着的 fd 和事件",就绪列表(ready list)是"其中已经就绪、等着交给你的"。select / poll 的关注列表每次随调用带进内核,epoll 的则一直留在内核里。
- **水平触发(LT)与边缘触发(ET)**:"只要还就绪就一直报"和"只在状态变化那一下报一次"。
- **惊群**:很多个线程或进程在等同一件事,事情来了全被叫醒,但只有一个能真正接手,其余白醒一趟。

**一句话:多路复用就是让一个线程同时挂在很多条等待队列上;三代实现的差别,是名单放哪、谁就绪怎么查。**

---

## select 为什么有 1024 上限?

### 第一任经理:每轮整张单子挨家打电话

select 用一个**位图**表示名单,类型叫 `fd_set`:第 n 位是 1,表示"我关心 fd n"。读、写、异常各一张。

```c
fd_set readfds;
FD_ZERO(&readfds);                  // 每轮都要清空重来
FD_SET(fd1, &readfds);              // 第 fd1 位置 1
FD_SET(fd2, &readfds);

select(maxfd + 1, &readfds, NULL, NULL, &timeout);   // 交给内核,等着

for (int fd = 0; fd <= maxfd; fd++)                  // 拿回来,从头翻
    if (FD_ISSET(fd, &readfds))
        handle(fd);
```

一次 `select` 调用在内核里做了这些事:

```
① 把三张位图从用户内存拷进内核
② 从 fd 0 查到 maxfd:对每个置位的 fd 调它的 poll 函数
     - 问"你现在就绪吗"
     - 顺手在它的等待队列上挂一个条目(这样它就绪时能叫醒我)
③ 一个都没就绪 → 线程睡下
④ 任何一个 fd 就绪 → 被叫醒 → 回到 ② 把所有 fd 再查一遍,收集结果
⑤ 把挂在每个 fd 上的等待队列条目全部摘掉
⑥ 把位图改写成"只剩就绪的位",拷回用户内存
```

`select(2)` 写得很明白:返回时位图是**原地修改**的,所以循环里每轮都得重新置位。

### 1024 是什么限制

这个上限来自 glibc 把 `fd_set` 定义成**固定大小**的类型,`FD_SETSIZE` = 1024,也就是 1024 位。位号就是 fd 号,所以它限制的不是"最多监听 1024 个",而是"**fd 编号必须小于 1024**"。

几个容易答错的细节:

- 一个进程打开了两千个文件,哪怕只监听其中编号 1500 的那一个,select 也用不了——位图里没有第 1500 位。
- `select(2)` 的原话是:对 ≥ `FD_SETSIZE` 的 fd 调 `FD_SET` 是**未定义行为**。实际效果是越界写内存,悄悄改坏栈上别的变量,不会报错。
- `ulimit -n` 调到十万也没用,它管的是能开多少 fd,不会改变编译期写死的位图大小。
- 内核本身并不限制 1024,它只按你传的 `maxfd + 1` 去读位图;限制在用户态的类型定义上。

### select 真正的问题

1024 只是最显眼的毛病,换个大位图就能绕过去。

- **每轮拷整张位图进出**:名单没变也要拷,根子是内核不记得上次的名单。
- **每轮在每个 fd 上挂、摘等待队列条目**:一万个 fd,一次调用就是一万次挂、一万次摘。
- **内核查一遍、程序再扫一遍,都是 O(总数)**:一万个连接三个就绪,也得查一万个、扫一万位。

> 放回饭馆:经理每轮拿着整张单子,挨家打电话问"货到了吗",还要留话"到了回我电话";有人回电后,他又把整张单子重新打一遍,确认到底是哪几家。单子越长,经理越累,和到货的有几家无关。

---

## poll 改进了什么,没改进什么

poll 把位图换成 `struct pollfd` 数组:

```c
struct pollfd fds[N];
fds[0].fd = fd1;  fds[0].events = POLLIN;    // 关心"可读"
fds[1].fd = fd2;  fds[1].events = POLLIN;
poll(fds, N, timeout);
// 返回后内核把结果写在每项的 revents 里,程序还是要一项项看
```

改进有两点:

- **fd 编号不受 1024 限制**:数组每项直接写 fd 号,多大都行。数组长度也不是无限的,`nfds` 超过进程的 `RLIMIT_NOFILE`(`ulimit -n`)会返回 `EINVAL`。
- **输入和输出分开**:程序填 `events`,内核只写 `revents`,下一轮不用重新填。

没改进的是本质:**每轮仍然把整个数组拷进内核,对每一项挂、摘等待队列,内核逐个查、程序逐项扫。** 成本照样和总连接数成正比。第二任经理换了本更好用的通讯录,打电话的方式一点没变。

---

## epoll 为什么快、快在哪?

### 第三任经理:名单常驻,货到按铃

epoll 基于两个观察:**名单大部分时间不变**,所以登记一次让内核记住,有增减时再改;**与其挨个去问,不如让就绪的自己报到**。对应三个系统调用:

```c
// ① 建一个 epoll 实例,返回一个 fd 代表它
int epfd = epoll_create1(EPOLL_CLOEXEC);

// ② 连接建立时登记一次,关闭前注销 —— 只在名单有变化时调用
struct epoll_event ev = { .events = EPOLLIN, .data.fd = fd };
epoll_ctl(epfd, EPOLL_CTL_ADD, fd, &ev);

// ③ 等待:拿回来的直接就是就绪的那几个
struct epoll_event events[128];
int n = epoll_wait(epfd, events, 128, -1);
for (int i = 0; i < n; i++)
    handle(events[i].data.fd);
```

`epoll_event.data` 是一个随你填的 64 位字段,内核原样带回。填 fd 号最简单;成熟的实现一般填一个指向"连接对象"的指针,事件回来直接拿到对象,省掉一次查表——Go 运行时就是这么做的。

### epoll 的红黑树和就绪链表各存什么?

每个 epoll 实例在内核里是一个 `struct eventpoll`(源码 `fs/eventpoll.c`),关键字段:

```
struct eventpoll(一个 epoll 实例)
┌──────────────────────────────────────────────────────────────┐
│ rbr      红黑树:关注列表。每个节点是一个 epitem                   │
│          按(file 指针, fd)排序,增删改查 O(log n)                │
│ rdllist  双向链表:就绪列表。挂的也是 epitem(同一批对象)            │
│ wq       等待队列:睡在 epoll_wait 上的线程                      │
│ ovflist  epoll_wait 正在往用户态拷结果时,新就绪的先暂存这里        │
└──────────────────────────────────────────────────────────────┘

struct epitem(一条登记记录,epoll_ctl ADD 时创建)
┌──────────────────────────────────────────────────────────────┐
│ ffd      被监听的 file 和 fd                                   │
│ event    你关心的事件和 data 字段                               │
│ rbn      挂在红黑树上的节点                                     │
│ rdllink  挂在就绪链表上的节点(不就绪时不在链表里)                  │
│ pwqlist  它挂在目标 socket 等待队列上的那些条目                   │
└──────────────────────────────────────────────────────────────┘
```

一个 epitem 同时有两个"挂钩":`rbn` 让它常驻红黑树,`rdllink` 让它在就绪时进链表。**红黑树服务 `epoll_ctl`,就绪链表服务 `epoll_wait`。** 红黑树的用处是 `epoll_ctl` 时快速判断"这个 fd 登记过没有"、按 fd 找到记录去修改或删除;选它而不是哈希表,是因为内核里"元素多、增删查频繁、最坏情况不能退化"的地方普遍用红黑树。所以"epoll 快是因为红黑树"说反了因果:红黑树只是让登记操作也不慢。

### 回调:就绪的 fd 怎么自己进链表

快的关键在 `epoll_ctl(ADD)` 那一刻:内核调用目标 socket 的 poll 函数,通过 `ep_ptable_queue_proc` 在 socket 的等待队列上**挂一个条目,条目的唤醒函数是 `ep_poll_callback`**。这一挂就挂到注销为止,不像 select 每轮挂、每轮摘。

```
网卡收到这条连接的数据
   ↓
协议栈处理,数据放进 socket 的接收缓冲区
   ↓
遍历 socket 的等待队列,调用每个条目的唤醒函数
   ↓
ep_poll_callback:把对应的 epitem 挂到 rdllist 上(已在链表里就不重复挂)
                 若 wq 上有线程睡在 epoll_wait,叫醒它
   ↓
epoll_wait 醒来,从 rdllist 取出 epitem
   - 再调一次 socket 的 poll 函数确认现在的就绪状态
   - 把事件拷进用户给的数组,最多 maxevents 个
   ↓
返回 n
```

select / poll 是"拉":程序来问,内核现场挨个查。epoll 是"推":数据一到,回调就把连接放进链表,程序来问时直接交出。跟HTTP轮训换成ws长链接很像。

### 两个流传很广的错误说法

- **"epoll 用 mmap 共享内存,不用拷贝。"** 错。`epoll_wait` 返回时内核用普通的拷贝(`__put_user`)把事件写进程序传入的数组,源码里找不到 mmap。省掉的是"每轮拷整张名单",不是拷贝本身。
- **"epoll 所有操作都是 O(1)。"** 不准确。`epoll_ctl` 要在红黑树上查找,O(log n);`epoll_wait` 返回 k 个事件至少 O(k);每个事件到达还有回调、加锁、唤醒的成本。准确的说法是:**epoll 每轮的成本和就绪数成正比,和总连接数无关。**

### 三代放在一起

| | select | poll | epoll |
|---|---|---|---|
| 名单 | 位图,每轮交一遍 | 数组,每轮交一遍 | 红黑树,常驻内核 |
| fd 编号 / 数量 | 编号 < 1024 | 数量 ≤ `RLIMIT_NOFILE` | 受 fd 上限和 `max_user_watches` |
| 等待队列条目 | 每轮挂 n 个、摘 n 个 | 同左 | ADD 时挂一次 |
| 找出谁就绪 | 内核查 n 个 | 内核查 n 个 | 取就绪链表,k 个 |
| 程序找结果 | 扫 n 位 | 扫 n 项 | 直接拿到 k 个 |
| 触发方式 | 只有水平 | 只有水平 | 水平 / 边缘 |
| 可移植性 | POSIX,到处都有 | POSIX,到处都有 | 仅 Linux |

10 万连接、100 个就绪:select / poll 每轮在内核里过 10 万个 fd,epoll 只处理 100 个。真实服务器恰好是"连接很多、同一时刻在说话的很少",这就是 epoll 能撑到十万、百万连接的原因。

---

## poll 一定比 poll 快吗?

不一定。epoll 优化的是"总数大、就绪少",离开这个前提,它的固定开销就显出来了:

- **连接少**:几十个 fd 时,poll 每轮拷几百字节、查几十项,成本很低;epoll 多出来的红黑树、回调、自旋锁都是额外开销。两者差别通常可以忽略。
- **几乎全部活跃**:一千个连接每轮九百个就绪,epoll 也要处理九百个,"只处理就绪的"不再省事;LT 模式下就绪项还要放回链表、下轮再确认一次。
- **短连接为主**:每条连接都要 `epoll_ctl(ADD)` 和 `epoll_ctl(DEL)` 各一次系统调用。连接只活几毫秒、只收发一次数据时,这两次调用占比不小;poll 只需在下一轮的数组里加一项、删一项。

所以 libevent、Redis 这类库都保留了 select / poll 的后端,epoll 不可用时退回去用。**选 epoll 不是因为它在每个场景都快,而是它在最常见、最吃力的场景里成本不随连接数涨。** 要比较,就拿自己的连接数和活跃比例去测,不要只看复杂度。

---

## LT 和 ET:灯一直亮,还是只叮一声

- **水平触发(LT,Level Triggered)**,默认:只要 fd 还处于就绪状态(比如缓冲区还有数据),每次 `epoll_wait` 都报它。像呼叫灯,事没处理完就一直亮。
- **边缘触发(ET,Edge Triggered)**,加 `EPOLLET`:只在状态**变化**时报一次——缓冲区从空变成有数据,或者又来了一批新数据。像门铃,按一下响一声。

(这两个词来自电路:看电平高低叫"水平",看从低跳到高的那一下叫"边缘"。)

在内核里,两者只差一行逻辑:`epoll_wait` 把一个就绪的 epitem 交给程序后,**LT 会把它重新挂回 rdllist**,下一轮再调 poll 函数确认,还就绪就再报,不就绪就丢掉;**ET 不放回**,只有 `ep_poll_callback` 因为新数据到来再次被调用,它才重新进链表。

### 只读一半会怎样

`epoll(7)` 里有个经典例子:管道写端写了 2KB,读端收到事件后只读 1KB,然后再调 `epoll_wait`。用 ET 的话,第二次 `epoll_wait` 可能一直阻塞下去,尽管缓冲区里明明还有 1KB。

下面用 socketpair 做同样的实验,每一步都用超时为 0 的 `epoll_wait` 问一下"现在有几个就绪":

```go
//go:build linux

// 需在 Linux 上运行:对比 LT 和 ET 在"只读一半"时的行为
package main

import (
	"fmt"
	"syscall"
)

func must(err error) {
	if err != nil {
		panic(err)
	}
}

// pending 用 timeout=0 问一次:现在有几个就绪事件
func pending(epfd int) int {
	events := make([]syscall.EpollEvent, 8)
	n, err := syscall.EpollWait(epfd, events, 0)
	must(err)
	return n
}

func try(name string, flags uint32) {
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0) // fds[1] 写,fds[0] 读
	must(err)
	defer syscall.Close(fds[0])
	defer syscall.Close(fds[1])
	must(syscall.SetNonblock(fds[0], true))

	epfd, err := syscall.EpollCreate1(syscall.EPOLL_CLOEXEC)
	must(err)
	defer syscall.Close(epfd)
	ev := syscall.EpollEvent{Events: flags, Fd: int32(fds[0])}
	must(syscall.EpollCtl(epfd, syscall.EPOLL_CTL_ADD, fds[0], &ev))

	syscall.Write(fds[1], make([]byte, 100)) // 对端发来 100 字节
	first := pending(epfd)

	buf := make([]byte, 50)
	syscall.Read(fds[0], buf) // 只读 50,还剩 50 在内核缓冲区
	half := pending(epfd)

	total := 0 // 正确做法:一直读到 EAGAIN
	for {
		n, err := syscall.Read(fds[0], buf)
		if err != nil || n == 0 { // EAGAIN 表示读空了
			break
		}
		total += n
	}
	fmt.Printf("%s 第一次:%d 个就绪  读一半后:%d 个  读到 EAGAIN(补读 %d 字节)后:%d 个\n",
		name, first, half, total, pending(epfd))
}

func main() {
	try("LT", syscall.EPOLLIN)
	try("ET", syscall.EPOLLIN|syscall.EPOLLET)
}
```

这段代码依赖 epoll,只在 Linux 上编译检查过(`GOOS=linux go vet`、`go build`)。把同一个实验换成 macOS 的 kqueue 实际跑了一遍,ET 那一行"读一半后"是 0 个,LT 是 1 个。

ET 下"读一半后"是 0:剩下的 50 字节还在缓冲区里,但不会再有通知。如果对方的协议是"等你回复了才发下一条",这条连接就永远停在这里——不报错、不断开,只是再也没有动静。

### ET 为什么必须读到 EAGAIN、为什么要配非阻塞?

ET 只在变化时通知,所以**每次收到通知,都要把缓冲区读空,否则剩下的数据不会再有人提醒你。** 而"读空"这件事,程序没办法提前知道——缓冲区里有多少字节,不读不知道。唯一可靠的判断是:一直读,直到 `read` 告诉你"现在没有了",也就是返回 `EAGAIN`。

```c
for (;;) {
    ssize_t n = read(fd, buf, sizeof buf);
    if (n > 0)  { append(conn, buf, n); continue; }   // 读到了,接着读
    if (n == 0) { on_peer_closed(conn); break; }      // 对端关闭
    if (errno == EINTR)  continue;                    // 被信号打断,重试
    if (errno == EAGAIN) break;                       // 读空了,回去等下一次通知
    on_error(conn); break;                            // 其他错误,关连接
}
```

`read` 返回的字节数小于缓冲区大小,也**不能**当作"读空了"的信号:可能读的那一刻正好又来了数据,也可能数据分几批到达。只有 `EAGAIN` 才算数。`epoll(7)` 给 ET 的建议用法就两句:**用非阻塞 fd;只在 `read` / `write` 返回 `EAGAIN` 之后才去等下一个事件。**

非阻塞是这个循环能结束的前提:最后一次 `read` 时缓冲区已经空了,阻塞 fd 会在这里一直睡下去,事件循环线程被一个连接卡死,其他九千多个连接全没人管。

监听 socket 也是一样:ET 下一次可读通知可能对应好几个排队的新连接,要循环 `accept` 到 `EAGAIN`。只 accept 一个就回去等,剩下的连接会一直躺在全连接队列里,客户端表现为连接超时。

另外,ET 不等于"每个网络包恰好通知一次"。`epoll(7)` 特意说明:ET 下收到多批数据也可能产生多次事件,多次变化也可能合并成一次通知。**以 `read` 的返回值判断进度,不要靠数事件。**

### 读到 EAGAIN 会不会饿死别的连接

会。`epoll(7)` 专门提了这个问题:一个连接的数据源源不断,"读到 EAGAIN"可能很久都读不完,同一批里的其他连接一直轮不到。

不能简单地"读够 64KB 就走"——ET 下走了就不会再有通知。标准做法是程序自己维护一个**待续列表**:单个连接这一轮读够预算还没到 `EAGAIN`,就把它放进待续列表;事件循环每轮先处理 `epoll_wait` 返回的新事件,再给待续列表里的连接各读一份预算,直到某个连接真的读到 `EAGAIN` 才把它移出。读空的责任没变,只是分几轮完成。LT 没有这个问题,读够预算直接走,下一轮它还会被报出来。

### 写事件怎么注册

可写的条件是"发送缓冲区有空位",而空闲连接的发送缓冲区**几乎总是有空位**。于是:

- **LT 下常驻 `EPOLLOUT` 会空转**:每次 `epoll_wait` 都立刻返回一大堆"可写",CPU 吃满却什么都没写。正确做法是平时只关心 `EPOLLIN`,`write` 写不完(返回 `EAGAIN` 或部分写入)时才 `epoll_ctl(MOD)` 加上 `EPOLLOUT`,写完再去掉。代价是多两次系统调用。
- **ET 下可以一直挂着 `EPOLLOUT`**:它只在"缓冲区从满变成有空位"时报一次,不会空转。有数据要发就直接 `write`,写不完再等那一次通知。Go 运行时就是这么做的,注册时读写一起挂上,之后再也不用 MOD。

### LT 和 ET 怎么选?

| | 水平触发(LT) | 边缘触发(ET) |
|---|---|---|
| 读的规矩 | 读多少都行,下一轮还会报 | 必须读到 `EAGAIN` |
| fd 是否必须非阻塞 | 强烈建议(就绪只是提示) | 必须 |
| 写事件 | 只在写不完时挂 `EPOLLOUT` | 可以一直挂着 |
| 通知次数 | 多,没处理完反复报 | 少,只在变化时报 |
| 写错的后果 | 多处理几轮、或者 CPU 空转,容易发现 | 连接偶发卡死,很难复现 |
| 谁在用 | Redis、libevent 默认、多数手写服务 | Nginx、Go 运行时 |

两者的性能差别在多数服务里远小于业务处理本身。手写事件循环,默认用 LT;**ET 的价值在于省掉 MOD 调用和重复通知,适合被一个成熟框架(或运行时)统一封装起来,而不是散落在业务代码里。**

还有一个相关标志 `EPOLLONESHOT`(Linux 2.6.2 起):报一次事件后自动把这个 fd 在关注列表里禁用,处理完要用 `EPOLL_CTL_MOD` 重新启用。它用在多个线程共用一个 epoll 实例的场景,保证同一个连接同一时刻只被一个线程处理;处理线程忘了重新启用,这个连接就永远沉默。

---

## epoll_wait 返回后为什么还可能读到 EAGAIN?

刚报了"可读",马上 `read` 却得到 `EAGAIN`,这是正常现象,不是 bug。具体有这几种来源:

- **别人先读走了**:多个线程或进程等同一批 fd,同一个事件被两方都拿到,先到的把数据读光。监听 socket 上最常见:一个新连接叫醒好几个 worker,只有一个 `accept` 成功,其余全是 `EAGAIN`。
- **上一轮已经读空了**:ET 下你在读到 `EAGAIN` 的循环里,新数据到了,回调又把 fd 放进了就绪链表;但这批数据已经被你同一个循环读走了。下一次 `epoll_wait` 照样报它,读一下就是 `EAGAIN`。
- **数据到了又没了**:`select(2)` 的 BUGS 一节明确写着,Linux 上 select 可能报告某个 socket 可读,接下来的 `read` 却会阻塞,例子是数据到达后校验和出错被丢弃;同类情况在 poll、epoll 上也可能出现。
- **运行时帮你缓存了旧通知**:Go 的 netpoll 会把"来过一次就绪"记下来,下一次读时消费。如果那批数据已经读过,这次就是一次 `EAGAIN`,随后进入等待。

所以事件循环的读路径必须把 `EAGAIN` 当作"本轮结束、回去等",而不是错误;更不能用阻塞 fd 去赌"报了就绪就一定有数据"。

### 关掉的 fd 为什么还会报事件

epoll 的关注列表登记的其实不是"fd 号",而是 fd 背后那个**打开文件对象**(内核的 `struct file`)。`epoll(7)` 写明:只有指向同一个打开文件对象的**所有** fd 都关闭后,它才会从关注列表里移除。程序 `dup` 过这个 fd,或者 `fork` 出的子进程还持有它,你 `close` 了自己那一份,epoll 还会继续报它的事件——而报上来的 fd 号已经被你关了,甚至已经被新连接复用。

稳妥的顺序是**先 `epoll_ctl(DEL)`,再 `close`**。更隐蔽的问题是 fd 号复用:fd 3 关闭后马上分给一个新连接,一个在途的旧事件或晚到的异步任务只记得"3",就会把旧连接的事算到新连接头上。所以成熟实现在 `data` 字段里放的是连接对象指针加一个代际编号,而不是裸 fd 号。

---

## 惊群是什么,EPOLLEXCLUSIVE / SO_REUSEPORT 怎么解决?

**惊群(thundering herd)**:一群线程或进程在等同一件事,事情来了全被叫醒,只有一个抢到,其余白醒一趟又睡回去。每次白醒都是一次上下文切换,worker 越多越浪费,表现为 CPU 使用率一跳一跳、`accept` 大量返回 `EAGAIN`。

要分清几种情况:

- **多个线程阻塞在同一个监听 socket 的 `accept` 上**:这种惊群早已在内核里解决,`accept` 的等待是"独占"的,一个连接只叫醒一个。
- **多个进程各有自己的 epoll 实例,都登记了同一个监听 socket**:这是 Nginx 式多 worker 的结构,也是今天说"惊群"主要指的情况。每个 epoll 实例都在监听 socket 的等待队列上挂了自己的回调条目,新连接到来,队列上每个条目都被调用,每个 epoll 实例都被唤醒。
- **多个线程在同一个 epoll 实例上 `epoll_wait`**:内核一次只叫醒其中一个,但 LT 下就绪项会被放回链表并再唤醒别人,同一个 fd 可能同时交给两个线程,这就是 `EPOLLONESHOT` 要解决的问题。

针对第二种,有两个办法:

**`EPOLLEXCLUSIVE`(Linux 4.5 起)**:`epoll_ctl(ADD)` 时加上它,这个 epoll 实例在目标 fd 的等待队列上挂的就是"独占"条目。`epoll_ctl(2)` 的措辞很谨慎:多个 epoll 实例都用这个标志挂在同一个 fd 上时,事件到来**"一个或多个"**实例会收到——它大幅减少白醒,不保证只叫醒一个。它还有使用限制:只能在 `EPOLL_CTL_ADD` 时设置,之后不能对这个 fd 做 `EPOLL_CTL_MOD`,只能和 `EPOLLIN`、`EPOLLOUT`、`EPOLLWAKEUP`、`EPOLLET` 搭配。

**`SO_REUSEPORT`(Linux 3.9 起)**:换个思路,不让大家盯同一个 socket。每个 worker 各自创建一个监听 socket,都绑在同一个端口上,内核收到新连接时按四元组哈希直接分给其中一个 socket。**不是让大家抢得更有序,而是由内核直接分配,根本不用抢。** 代价是某个 worker 卡住时,分给它的连接会在它的队列里排队,别的 worker 帮不上忙。

Nginx 这几种方案的演进(`accept_mutex` → `EPOLLEXCLUSIVE` → `reuseport`)。

---

## 线上排查

| 现象 | 多半是什么 | 怎么确认 |
|---|---|---|
| 个别连接偶发"卡住",不报错不断开 | ET 下没读到 `EAGAIN` 就回去等,剩余数据没人读 | `ss -tnp` 看这条连接 `Recv-Q` 长期不为 0;同时 `strace -p <pid> -e trace=epoll_wait` 显示进程在正常 `epoll_wait`,就是不来读它 |
| `accept: too many open files`,新连接全进不来 | fd 泄漏(连接、文件、`resp.Body` 没关),或上限太低 | `ls /proc/<pid>/fd \| wc -l` 隔几分钟看是否只涨不跌;`grep 'open files' /proc/<pid>/limits` 看上限;`ls -l /proc/<pid>/fd \| grep -c socket` 看是不是 socket 在漏 |
| 泄漏的是 socket,且大量 `CLOSE_WAIT` | 对端已关闭,本端读到 0 却没 `close` | `ss -tanp state close-wait \| grep <pid>`,数量和 fd 增长同步 |
| CPU 很高,业务量很小,`strace` 里 `epoll_wait` 一直立刻返回 | LT 下常驻 `EPOLLOUT`;或对端关闭后没处理(`read` 返回 0 不关连接,LT 每轮都报可读) | `strace -T -p <pid> -e trace=epoll_wait,read` 看 `epoll_wait` 是否总返回 `= 1` 且耗时接近 0,后面跟着 `read(...) = 0` 或根本没有读写 |
| 多 worker 进程,CPU 和上下文切换周期性尖峰 | 惊群:所有 worker 被同一个新连接叫醒 | `strace -f -p <master_pid> -e trace=accept4` 看大量 `= -1 EAGAIN`;`pidstat -w 1` 看 `cswch/s` |
| `epoll_ctl` 返回 `ENOSPC` | 用户的 epoll 登记总数超过 `max_user_watches` | `cat /proc/sys/fs/epoll/max_user_watches`;看有没有程序在不停 ADD 不 DEL |
| 所有连接的延迟一起升高,`Recv-Q` 普遍积压 | 事件循环里某个回调慢(同步查库、读大文件),`epoll_wait` 很久才被调一次 | `strace -T -p <pid>` 看两次 `epoll_wait` 之间间隔很长、中间夹着慢调用;或 `perf top -p <pid>` |

看一个进程的 epoll 实例登记了什么:`ls -l /proc/<pid>/fd | grep eventpoll` 找到 epoll 的 fd 号,再 `cat /proc/<pid>/fdinfo/<该 fd 号>`,每一行 `tfd:` 是一个被监听的 fd,`events:` 是关心的事件掩码(十六进制)。

---

## 关联

- **fd 数和 goroutine 数一起监控。** Go 自动提了软上限,"默认 1024"一般碰不到,但泄漏照样会把硬上限耗光:`resp.Body` 没关、数据库连接没归还、WebSocket 订阅断了没清理,跑几天就 `too many open files`。中继、监听服务长期连着多条链的 RPC 和 WebSocket 订阅,最容易漏。把进程 fd 数(`/proc/self/fd` 的条目数)和 `runtime.NumGoroutine()` 放进监控,两条曲线"只涨不跌"都是早期信号。
- **先别急着换事件循环库。** 标准库"一个连接一个 goroutine"撑几万连接没问题。到百万长连接,goroutine 栈和 GC 扫描才成为瓶颈,那时才值得看 gnet、字节的 netpoll 这类直接操作 epoll 的库,代价是改回回调式写法。
- **P2P 节点的连接形态正是 epoll 的主场。** geth 这类节点维持成百上千条对等连接,大部分时间空闲,区块和交易广播时才集中活跃——"连接多、活跃少",一个 epoll 实例加 goroutine 就能扛住。
- **推与拉的取舍可以迁移到你的系统里。** 定时扫数据库找新任务、每隔几秒轮询链上高度是拉,订阅 `newHeads`、用消息队列通知是推。事件稀疏时推省掉大量空转;但之前的结论同样成立:事件很密集、几乎每轮都有事时,批量拉反而更划算,还省掉了维护订阅关系的成本。
- **"一个卡住,全部停摆"在任何事件循环里都成立。** 自己写的"一个 goroutine 从 channel 取事件、分发给处理函数"的循环,和 epoll 事件循环是同构的:循环里同步调一个没有超时的 RPC,所有后续事件都得等。

---

## 总结

```
一个线程等很多 fd = 在很多条等待队列上各挂一个条目
  │ 三个问题:名单放哪?谁就绪怎么查?结果怎么给回去?
  ├─ select:位图每轮交一遍,内核挨个查、挨个挂摘;1024 限的是 fd 编号
  ├─ poll:数组,编号不限;每轮全量的成本没变
  └─ epoll:红黑树存关注列表(服务 epoll_ctl),回调把就绪的放进链表(服务 epoll_wait)
       成本 ∝ 就绪数;不是 mmap、不是 O(1);连接少/全活跃/短连接时不占优势
       ├─ LT:还就绪就一直报 —— 手写默认用它,EPOLLOUT 按需挂
       └─ ET:变化时报一次 —— 必须非阻塞、读/写/accept 到 EAGAIN,注意饥饿

就绪只是提示 → read 仍可能 EAGAIN;先 DEL 再 close
惊群 → EPOLLEXCLUSIVE(减少白醒)/ SO_REUSEPORT(内核分配,不抢)
kqueue ≈ epoll(EV_CLEAR = ET);IOCP 是完成通知
Go:一个 epoll、ET、读写一次挂齐;先读后等 + pdReady → 不漏事件
```

最该记住的几句话:

- **多路复用就是一个线程挂在很多条等待队列上。** select / poll / epoll 的差别只在名单放哪、谁就绪怎么查。
- **select 的 1024 限制的是 fd 编号,不是监听数量**;它和 poll 真正的问题是每轮全量拷贝、全量检查,成本和总连接数成正比。
- **epoll 快在名单常驻内核、就绪的由回调主动进链表,成本和就绪数成正比。** 红黑树只是让 `epoll_ctl` 不慢;mmap 是谣言。
- **epoll 擅长"连接多、活跃少",连接少、全活跃或短连接为主时不一定比 poll 快。**
- **ET 只通知一次,所以 fd 必须非阻塞、每次都要读到 `EAGAIN`;手写服务默认用 LT。**
- **就绪只是提示,`EAGAIN` 是正常的"本轮结束",不是错误。**
- **Go 用 ET 是为了读写一次挂齐、省掉 `epoll_ctl`;靠"先读后等"和 `pdReady` 保证不漏事件。**

---

## 参考资料

- 《UNIX 网络编程 卷一》第 6 章 —— select 和 poll 的权威讲解
- [Linux `epoll(7)`](https://man7.org/linux/man-pages/man7/epoll.7.html) —— LT / ET 的准确定义、2KB 管道的例子、ET 的建议用法、饥饿问题、close 与 dup 的规则
- [Linux `epoll_ctl(2)`](https://man7.org/linux/man-pages/man2/epoll_ctl.2.html) —— `EPOLLET`、`EPOLLONESHOT`、`EPOLLEXCLUSIVE` 的语义和限制,普通文件返回 `EPERM`、`max_user_watches` 对应 `ENOSPC`
- [Linux `select(2)`](https://man7.org/linux/man-pages/man2/select.2.html) —— `FD_SETSIZE` 的警告、位图原地修改、"报可读但 read 会阻塞"的 BUGS 一节
- [Linux `poll(2)`](https://man7.org/linux/man-pages/man2/poll.2.html) —— `pollfd` 结构和 `nfds` 超过 `RLIMIT_NOFILE` 的 `EINVAL`
- [Linux 源码 `fs/eventpoll.c`](https://github.com/torvalds/linux/blob/master/fs/eventpoll.c) —— `eventpoll`、`epitem`、`ep_poll_callback` 的实现
- [The C10K problem(Dan Kegel)](http://www.kegel.com/c10k.html) —— 多路复用演进的原始讨论
- 《Linux 高性能服务器编程》(游双)—— 中文书里讲 epoll 和 LT / ET 最实用的
- [Go `runtime/netpoll_epoll.go`](https://github.com/golang/go/blob/master/src/runtime/netpoll_epoll.go) —— Go 怎么用 epoll,两百行出头;配合同目录 `netpoll.go` 开头关于 `pdReady` / `pdWait` 的注释读
- [Go `internal/poll/fd_unix.go`](https://github.com/golang/go/blob/master/src/internal/poll/fd_unix.go) —— `FD.Read` 的"先读,`EAGAIN` 再等"循环
