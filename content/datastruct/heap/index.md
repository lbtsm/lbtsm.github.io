---
title: "数据结构-堆与优先队列"
date: 2026-09-03T21:16:43+08:00
draft: false
summary: ""
carousel: true
---

## Summary

前面讲队列的时候,规则是"先进先出"——排队买票,来得早的先走。但现实里大量场景不讲先来后到,只讲**谁最急**:医院急诊室按病情严重程度排,操作系统按优先级调度进程,定时任务按到期时间触发。

这类需求抽象出来是同一个操作:**在一堆动态变化的数据里,随时取出"最小(或最大)的那一个"**。堆就是为这个操作而生的结构,而优先队列是它对外的那层接口。

这篇会先把堆本身讲透,然后拿 Kubernetes 的 `client-go` 开刀——它的 workqueue 是"用堆做工程"的教科书级案例,把延时重试、去重、优先级更新这些真实问题全踩了一遍。

---

## 为什么需要堆

先看看已有的结构能不能顶上。需求是两个操作反复交替:**插入一个元素**、**取出当前最小的元素**。

**方案一:用无序数组。** 插入是尾部追加,O(1),很快。但取最小值要遍历全部元素,O(n)。

**方案二:用有序数组(或有序链表)。** 取最小值是取头部,O(1),很快。但插入要找位置 + 挪动后面所有元素,O(n)。

```
无序数组:  插入 O(1)      取最小 O(n)
有序数组:  插入 O(n)      取最小 O(1)
```

两个方案各有一头是 O(n),而我们的场景是**两个操作交替高频发生**,所以总代价还是被 O(n) 那一头拖死。

问题出在哪?出在**我们要的信息其实很少,但排序给的信息太多了**。有序数组维护了"所有元素之间的完整顺序关系",而我们每次只需要知道"谁是最小的",剩下 n-1 个元素谁在前谁在后完全不关心。为了那一个信息,付出了全排序的代价。

**堆的思路就是:只维护"部分有序"——保证根是最小的,别的不管。**

```
有序数组:  1 3 4 7 8 9 12      ← 完全有序,信息过剩
堆:              1
                / \
               3   4           ← 只保证"父 < 子",兄弟之间不排序
              / \  / \
             7  8 9  12
```

维护的约束变少了,代价自然就下来了:两个操作都是 **O(log n)**。

---

## 堆是什么

**堆是一棵满足堆序性质的完全二叉树。** 两个关键词都不能少。

**完全二叉树**:除最后一层外都填满,最后一层的节点靠左连续排列。

**堆序性质**:每个节点和它的孩子之间有固定的大小关系。

- **小顶堆(min-heap)**:父节点 ≤ 两个孩子。根是全局最小值。
- **大顶堆(max-heap)**:父节点 ≥ 两个孩子。根是全局最大值。

```
小顶堆:                     大顶堆:
        1                          9
       / \                        / \
      3   4                      7   8
     / \  / \                   / \  / \
    7  8 9  12                 3  1 4  2

  根 = 最小值                  根 = 最大值
```

有两点特别容易搞错,单独强调一下:

**第一,堆只约束父子,不约束兄弟。** 上面小顶堆里 3 和 4 是兄弟,3 < 4;但如果换成 4 和 3 也完全合法。**所以堆不是有序的**,你不能指望遍历堆的数组能得到有序序列，这一点和二叉搜索树是不一样的。

**第二,堆只保证根是极值,不保证第二层就是第二小。** 小顶堆里第二小的元素一定是根的两个孩子之一(因为其他节点都在某个孩子的子树里,必然比那个孩子大),但**它可能在左也可能在右**,要比一下才知道。

### 用数组存储,不需要指针

这是堆最漂亮的地方。因为它是完全二叉树——节点靠左连续、中间没有空洞——所以可以**按层序直接铺进数组**,父子关系用下标算出来,一个指针都不用存:

```
        1                下标:  0  1  2  3  4  5  6
       / \               数组: [1, 3, 4, 7, 8, 9, 12]
      3   4
     / \  / \            对下标 i (从 0 开始):
    7  8 9  12             左孩子 = 2i + 1
                           右孩子 = 2i + 2
                           父亲   = (i - 1) / 2
```

验证一下:下标 1 的元素是 3,它的左孩子在 `2*1+1 = 3`,即 7;右孩子在 `2*1+2 = 4`,即 8。对上了。

这带来三个实际好处:

- **内存紧凑**,没有指针开销(链式二叉树每个节点要多存两个 8 字节指针)
- **缓存友好**,父子在数组里位置相近,大概率落在同一条缓存行上
- **实现简单**,不用处理指针的各种边界情况

---

## 两个核心操作

堆的所有操作都建立在两个动作上:**上浮**和**下沉**。名字很直观——元素在树里往上冒或者往下沉,直到回到合法的位置。

### 上浮(siftUp):用于插入

新元素只能加在**数组末尾**(也就是完全二叉树最后一层的下一个空位),否则会破坏完全二叉树的形态。但它放在那里可能比父亲小,违反堆序,所以要往上冒。

```
插入 2 到这个小顶堆:

        1                    1                      1
       / \                  / \                    / \
      3   4      →         3   4        →         2   4
     / \  / \             / \  / \               / \  / \
    7  8 9  12           7  8 9  12             7  3 9  12
                        /                      /
                       2                      8
                    ← 放末尾                ← 2 < 3,交换
                       2 < 8,交换             2 > 1,停止
```

每次和父亲比一次,最多走到根,所以是 **O(log n)**。

```go
// 小顶堆的上浮
func siftUp(h []int, i int) {
    for i > 0 {
        parent := (i - 1) / 2
        if h[parent] <= h[i] {
            break                  // 已经满足堆序,停
        }
        h[parent], h[i] = h[i], h[parent]
        i = parent
    }
}
```

### 下沉(siftDown):用于删除极值

取走根之后,根的位置空了。不能直接把某个孩子提上来——那样会在树中间留个洞,破坏完全二叉树。正确做法是:**把数组最后一个元素搬到根上**,长度减一,然后让它往下沉。

```
从小顶堆取出最小值 1:

        1                  12                    3                    3
       / \                / \                   / \                  / \
      3   4      →       3   4        →       12   4       →        7   4
     / \  / \           / \  /                / \  /                / \  /
    7  8 9  12         7  8 9                7  8 9               12  8 9

   取走根 1          末尾的 12 搬到根      12 和较小的孩子       12 和较小的孩子
                     (长度减一)          3 交换               7 交换,没孩子了,停
```

注意一个细节:**下沉时必须和两个孩子中较小的那个交换**(小顶堆)。如果随便挑一个,换完之后新的父节点可能还是比另一个孩子大,堆序照样破了。

```go
// 小顶堆的下沉,n 是堆的有效长度
func siftDown(h []int, i, n int) {
    for {
        left, right := 2*i+1, 2*i+2
        smallest := i

        if left < n && h[left] < h[smallest] {
            smallest = left
        }
        if right < n && h[right] < h[smallest] {
            smallest = right      // 关键:挑两个孩子里更小的
        }
        if smallest == i {
            break                 // 自己就是最小,停
        }
        h[i], h[smallest] = h[smallest], h[i]
        i = smallest
    }
}
```

### 建堆:为什么是 O(n) 而不是 O(n log n)

建堆最好的方式是使用下沉建堆，复杂度为：O(n log n)。

可以这么理解，当你构建一个公司的体系时，底层员工肯定是最多的，如果要动底层员工，每个人都要执行一步，那就是O(n)，但是如果使用下沉，那就从董事长（非叶子节点）开始，他们最多移动O(log n)。所以使用下沉复杂度最低，方便的话自己写一下建堆的代码，可以深入理解。

---

## 优先队列 = 堆的接口

堆是**实现**,优先队列是**接口**。优先队列定义的是"能插入、能取出优先级最高的",至于内部用什么实现它不管——可以用堆,也可以用有序链表、跳表、配对堆。但实践中绝大多数优先队列就是用二叉堆实现的,所以这两个词经常混用。

### Go 的 container/heap

Go 标准库不直接给你一个"优先队列"类型,而是给了一套**算法**:你提供底层容器和比较规则,它帮你维护堆序。这是典型的 Go 风格——用接口把算法和数据解耦。

你需要实现 `heap.Interface` 的五个方法:

```go
type Interface interface {
    sort.Interface          // Len() int, Less(i, j int) bool, Swap(i, j int)
    Push(x any)             // 把元素加到末尾
    Pop() any               // 从末尾摘掉元素并返回
}
```

这里有个**几乎人人踩过的坑**:接口里的 `Push`/`Pop` 和你实际调用的 `heap.Push`/`heap.Pop` **不是同一个东西**，具体的可以看下container/heap.go源码的额位置。

```
实现的接口Push(x any)，只负责"追加到末尾",不维护堆序，所以不是真的上浮，heap.Push(h, x) 才是完成的流程。

你实现的 pq.Pop()，只负责"摘掉末尾元素"，不回自动下沉，heap.Pop(h) 才是完整的流程。
```

**所以业务代码永远调用 `heap.Push` / `heap.Pop`(包级函数),绝不直接调用 `pq.Push` / `pq.Pop`(方法)。** 直接调方法的话堆序不会被维护,退化成普通切片操作,而且不报错——是那种能安静运行很久的 bug。

`container/heap` 还给了两个很有用的函数,后面 client-go 会用到:

- `heap.Fix(h, i)`:下标 i 的元素**优先级变了**,就地修复堆序(向上或向下都行)。
- `heap.Remove(h, i)`:删除任意位置的元素,O(log n)。

---

## client-go 实战:workqueue 里的堆

`client-go` 是 Kubernetes 的官方 Go 客户端,所有 controller 都基于它写。它的 `workqueue` 包是"用堆解决真实工程问题"的最佳教材,因为 controller 的核心循环天然需要队列:**事件进来 → 放队列 → worker 取出处理 → 失败了延迟重试**。

以下的代码都来自 `client-go` master 分支。

### 延时队列:一个按时间排序的小顶堆

`DelayingInterface` 提供 `AddAfter(item, duration)`——"这个东西过 5 秒再给我"。这是失败重试和退避的基础设施。

实现它需要回答一个问题:成千上万个待延时的 item,怎么知道**下一个该到期的是哪个**?这正是堆的主场——按到期时间建小顶堆,根就是最近要到期的那个。

先看数据结构(`util/workqueue/delaying_queue.go`):

```go
// waitFor 保存"要加入的数据"和"该在什么时候加入"
type waitFor[T any] struct {
	data    T
	readyAt time.Time
	// index in the priority queue (heap)
	index int          // ← 记住自己在堆里的位置,后面 heap.Fix 要用
}

// 底层就是一个切片,没有任何多余包装
type waitForPriorityQueue[T any] []*waitFor[T]

func (pq waitForPriorityQueue[T]) Len() int {
	return len(pq)
}

// 比较规则:readyAt 早的排前面 → 小顶堆,根是"最近要到期的"
func (pq waitForPriorityQueue[T]) Less(i, j int) bool {
	return pq[i].readyAt.Before(pq[j].readyAt)
}

// 注意这里:交换元素的同时,必须同步更新它们记录的 index
func (pq waitForPriorityQueue[T]) Swap(i, j int) {
	pq[i], pq[j] = pq[j], pq[i]
	pq[i].index = i
	pq[j].index = j
}

// Push adds an item to the queue. Push should not be called directly; instead, // 注释中直接把上述的坑写在这里
// use `heap.Push`.
func (pq *waitForPriorityQueue[T]) Push(x interface{}) {
	n := len(*pq)
	item := x.(*waitFor[T])
	item.index = n
	*pq = append(*pq, item)      // 只是追加,不管堆序
}

// Pop removes an item from the queue. Pop should not be called directly;
// instead, use `heap.Pop`.
func (pq *waitForPriorityQueue[T]) Pop() interface{} {
	n := len(*pq)
	item := (*pq)[n-1]
	item.index = -1              // 标记"已不在堆中"
	*pq = (*pq)[0:(n - 1)]
	return item
}

// Peek returns the item at the beginning of the queue, without removing the
// item or otherwise mutating the queue. It is safe to call directly.
func (pq waitForPriorityQueue[T]) Peek() interface{} {
	return pq[0]                 // 根 = 最近到期的那个
}
```

几个值得学的点:

**① 自定义了一个 `Peek`,并且注明"可以直接调"。** `heap.Interface` 里没有 Peek,但"只看一眼根、不取出"是刚需。因为根永远在下标 0,所以 `pq[0]` 就够了,不需要任何堆操作——所以它是安全的。

**② 每个元素记着自己的 `index`。** 这是为了支持"优先级更新",下面细说。

### 为什么要存 index:heap.Fix 与优先级更新

`AddAfter` 有个语义问题:同一个 item 被要求延时两次怎么办?比如一个 Pod 先被要求"10 秒后重试",紧接着又被要求"2 秒后重试"。

Kubernetes 的选择是**取更早的那个**——用户既然要求更快处理,就别让它多等。代码在 `insert` 函数里:

```go
// insert adds the entry to the priority queue, or updates the readyAt if it already exists in the queue
func insert[T comparable](q *waitForPriorityQueue[T], knownEntries map[T]*waitFor[T], entry *waitFor[T]) {
	// if the entry already exists, update the time only if it would cause the item to be queued sooner
	existing, exists := knownEntries[entry.data]
	if exists {
		if existing.readyAt.After(entry.readyAt) {
			existing.readyAt = entry.readyAt    // 改成更早的时间
			heap.Fix(q, existing.index)         // 就地修堆序,O(log n)
		}
		return                                  // 不重复入堆
	}

	heap.Push(q, entry)
	knownEntries[entry.data] = entry
}
```

这段短短十几行,信息量很大:

**堆 + map 是一对标配。** 堆本身只能高效拿极值,**不能高效查找"某个特定元素在哪"**——那需要 O(n) 遍历。所以旁边挂一个 `map[数据]*元素` 做索引,查找变成 O(1)。这个组合(堆负责排序、map 负责定位)在工程里到处都是。

**`heap.Fix` 比"删了再插"划算。** 想改一个元素的优先级,朴素做法是 `heap.Remove` + `heap.Push`,两次 O(log n) 加上重新分配。`heap.Fix(q, i)` 只从位置 i 开始修一个方向,一次 O(log n)。

**而 `Fix` 需要知道 i,这就是 `index` 字段存在的全部理由。** 也正因为如此,`Swap` 里那两行 `pq[i].index = i` 绝对不能漏——一旦漏了,index 就和真实位置脱钩,`heap.Fix` 会去修一个错误的位置,堆序静默损坏。**这是自己实现 heap.Interface 时最容易出的错。**

### 主循环:堆的根用来算定时器

拿到"最近要到期的元素"之后怎么等?这里的处理很值得学(`waitingLoop` 函数):

```go
for {
    now := q.clock.Now()

    // 1) 先把所有已经到期的都取出来,塞进真正的工作队列
    for waitingForQueue.Len() > 0 {
        entry := waitingForQueue.Peek().(*waitFor[T])
        if entry.readyAt.After(now) {
            break                                   // 根都没到期,后面的更不可能
        }
        entry = heap.Pop(waitingForQueue).(*waitFor[T])
        q.Add(entry.data)
        delete(waitingEntryByData, entry.data)
    }

    // 2) 按"根的到期时间"设一个定时器,而不是轮询
    nextReadyAt := never
    if waitingForQueue.Len() > 0 {
        entry := waitingForQueue.Peek().(*waitFor[T])
        nextReadyAtTimer = q.clock.NewTimer(entry.readyAt.Sub(now))
        nextReadyAt = nextReadyAtTimer.C()
    }

    select {
    case <-q.stopCh:
        return
    case <-q.heartbeat.C():        // 兜底心跳,防止永久阻塞
    case <-nextReadyAt:            // 最近的那个到期了,回到循环顶部
    case waitEntry := <-q.waitingForAddCh:
        // 有新的延时请求进来
    }
}
```

三个设计值得单独说:

**① `break` 那一行是堆序性质的直接应用。** 根没到期,就说明**整个堆里没有任何元素到期**——因为根是最小的。所以可以立刻停止检查,不需要扫剩下的元素。如果底层不是堆而是普通切片,这里就得全表扫描。

**② 用定时器而不是轮询。** 拿根的到期时间算出"还要睡多久",精确睡到那一刻。如果改成"每 100ms 醒一次看看有没有到期的",既浪费 CPU 又有最多 100ms 的延迟误差。**堆让"下一次该在什么时候醒"变成一个 O(1) 的查询(Peek 根)**,定时器方案才成立。

**③ `Peek` 和 `Pop` 分工明确。** 只是想"看看什么时候醒"用 `Peek`(不改堆);确定要处理了才 `Pop`(改堆)。如果没有 Peek,只能先 Pop 出来看,发现没到期还得 Push 回去,白做两次 O(log n)。

这套"**堆存到期时间 + 根算定时器**"的组合是定时任务调度的通用范式。Go 运行时自己的 timer、Redis 的过期键、Java 的 `ScheduledThreadPoolExecutor`、各种延时消息队列,内核都是这个思路(有些用时间轮优化,但基本盘是它)。

### 另一个例子:tools/cache 里的通用堆

`client-go` 里还有一个更通用的封装,`tools/cache/heap.go`。它把"堆 + map + 锁 + 条件变量"打包成了一个线程安全的生产者消费者队列:

```go
type heapData struct {
	// items is a map from key of the objects to the objects and their index.
	items map[string]*heapItem     // key → (对象, 在堆里的下标)
	// queue keeps the keys of objects stored in "items".
	queue []string                 // 堆本身,存的是 key 不是对象

	keyFunc  KeyFunc               // 怎么从对象算出 key
	lessFunc LessFunc              // 怎么比较两个对象   ← 优先级规则注入
}

func (h *heapData) Less(i, j int) bool {
	if i > len(h.queue) || j > len(h.queue) {
		return false
	}
	itemi, ok := h.items[h.queue[i]]
	if !ok {
		return false
	}
	itemj, ok := h.items[h.queue[j]]
	if !ok {
		return false
	}
	return h.lessFunc(itemi.obj, itemj.obj)    // 委托给用户传入的函数
}
```

和上面的延时队列比,这里有两处不同的取舍:

**① 堆里存的是 key(string),不是对象本身。** 对象放在 map 里,堆只排序 key。好处是 `Swap` 交换的是 string 而不是大结构体;代价是每次 `Less` 都要查两次 map。

**② 比较规则由外部注入(`LessFunc`)。** 延时队列的 `Less` 写死了"按 readyAt 比",因为它只干一件事。而这个 `Heap` 是通用组件,优先级规则必须让调用方决定。这就是"策略模式"在 Go 里最自然的形态——传一个函数进来。

对外的 `Pop` 用条件变量实现了阻塞语义:

```go
func (h *Heap) Pop() (interface{}, error) {
	h.lock.Lock()
	defer h.lock.Unlock()
	for len(h.data.queue) == 0 {
		// 队列空 → 阻塞等待,直到有人 Add 或者 Close
		if h.closed {
			return nil, fmt.Errorf("heap is closed")
		}
		h.cond.Wait()
	}
	obj := heap.Pop(h.data)
	// ...
}
```

注意 `for` 而不是 `if`——被唤醒后要**重新检查条件**,因为可能有其他消费者先抢到了元素。这是条件变量的标准用法,写成 `if` 就是虚假唤醒 bug。

### 对照组:不用堆的那个队列

`client-go` 最常用的 `workqueue.Typed`(基础 FIFO)反而**没有用堆**。看它的字段就明白为什么:

```go
type Typed[t comparable] struct {
	queue []t                  // 就是个切片,FIFO

	dirty      sets.Set[t]     // 需要处理的
	processing sets.Set[t]     // 正在处理的
}
```

controller 的语义是"**这个资源变了,去调谐一次**"。同一个资源在短时间内变了 10 次,只需要调谐一次就够了(因为调谐总是读取最新状态)。所以这个队列的核心需求不是优先级,而是**去重**——用两个 set 实现"处理中的东西如果又变脏了,处理完再重新入队一次,且只入一次"。

**放在一起看的价值在于:同一个包里,需求不同就选了不同结构。** 需要按时间排序 → 堆;只需要去重和先来后到 → 切片 + set。**不要因为学了堆就到处用堆**,这是 client-go 给的最实在的一课。

---

## 常见坑

**① 直接调用 `pq.Push()` 而不是 `heap.Push(pq, x)`。** 堆序不会被维护,而且不报错。前面说过,这是最高频的错误。

**② 自定义 `Swap` 时忘了同步 index。** 如果你的元素记录了自己在堆里的下标(为了用 `heap.Fix`),`Swap` 里必须更新它。漏掉之后 `Fix` 会修错位置,表现为"偶发的顺序错乱",极难排查。

**③ 以为遍历堆的数组能得到有序序列。** 堆只保证父子关系。要有序输出只能反复 `Pop`,那就是堆排序,O(n log n)。

**④ 大顶堆小顶堆搞反。** 求"**最大**的 K 个数"要用**小顶堆**(堆里维护当前最大的 K 个,根是这 K 个里最小的,新元素比根大就替换掉根)。这个反直觉,是面试高频错点。记法:**堆顶放的是"最容易被淘汰的那个"。**

**⑤ 在 `Less` 里做重活。** `Less` 在一次插入中会被调用 log n 次,建堆时被调用 O(n) 次。如果里面有字符串拼接、map 查找、反射,整体性能会明显下降。上面 `heapData.Less` 每次查两次 map 已经是有代价的设计,只是它换来了别的好处。

**⑥ 忘了堆不支持高效查找。** 想知道"元素 X 在不在堆里",堆本身只能 O(n) 遍历。需要就配一个 map,像 client-go 那样。

---

## 复杂度与适用场景

| 操作 | 复杂度 | 说明 |
|---|---|---|
| 取极值(Peek) | O(1) | 就是根,下标 0 |
| 插入(Push) | O(log n) | 末尾追加 + 上浮 |
| 删除极值(Pop) | O(log n) | 根与末尾交换 + 下沉 |
| 修改优先级(Fix) | O(log n) | 需要知道下标 |
| 删除任意元素(Remove) | O(log n) | 需要知道下标 |
| 建堆 | **O(n)** | 倒序下沉,不是 O(n log n) |
| 查找任意元素 | O(n) | 堆的短板,要配 map |

和其他结构的取舍:

| | 取极值 | 插入 | 查找任意 | 有序遍历 |
|---|---|---|---|---|
| **堆** | **O(1)** | **O(log n)** | O(n) | 不支持 |
| 有序数组 | O(1) | O(n) | O(log n) | 支持 |
| 平衡树 / 跳表 | O(log n) | O(log n) | **O(log n)** | **支持** |
| 哈希表 | O(n) | O(1) | **O(1)** | 不支持 |

**选堆的判据很清晰:只关心极值、不需要有序遍历、不需要按值查找。** 三条里有一条不满足,就该考虑平衡树或跳表了。
