---
title: "数据结构-Hashtable"
date: 2026-08-14T15:37:29+08:00
draft: false
summary: ""
carousel: true
---

## Summary

**用一个函数直接"算"出元素在哪，一步到位 O(1)**。它的灵魂就一句话:**哈希表 = 数组 + 一个把 key 变成下标的哈希函数**，用"算地址"代替"找元素"。代价是天下没有免费的午餐:key 无限、桶有限，冲突必然发生，于是又牵出**拉链法/开放寻址**两套解决方案，以及**装载因子 + 扩容 rehash** 这套动态维稳机制。

---

## 核心思想:把 key 变成数组下标

数组的超能力是 `base + i * size` 一步算出地址。但我们手里的 key 是字符串、地址、结构体，不是下标。哈希表就架一座桥:拿一个**哈希函数**把任意 key 砸成一个整数，再对桶数组长度取模，得到下标:

```
key ──hash()──▶ 一个大整数 ──% len──▶ 下标 ──▶ 桶(bucket)

"apple"  ─hash→ 3208616981 % 8 = 5 ─▶ 桶[5]
"banana" ─hash→  773291043 % 8 = 3 ─▶ 桶[3]
```

哈希函数长什么样?不神秘，就是一堆位运算把字节搅匀。工程里常用 FNV-1a，十来行就能写出一个把字符串打散得很均匀的版本:

```go
// FNV-1a:把任意字符串搅成一个 uint32
func hash(key string) uint32 {
	var h uint32 = 2166136261 // FNV offset basis
	for i := 0; i < len(key); i++ {
		h ^= uint32(key[i]) // 异或吃进一个字节
		h *= 16777619       // 再乘一个大质数,把影响扩散到所有位
	}
	return h
}
```

一个能用的哈希函数要满足两点:一是**确定性**，同一个 key 每次算出同一个值(不然存进去就找不回来);二是**均匀**，把 key 尽量摊平到各个桶，别都挤一个格子——做不到均匀，哈希表就退化成链表了。

> 上面取模我写的是 `% len`，但你翻 Go、Java 的源码会发现它们用的是 `hash & (len-1)`。这不是炫技:**当桶数组长度是 2 的幂时，`hash & (n-1)` 完全等价于 `hash % n`，而位与比取模快得多。** 这也是为什么它们的桶数永远是 2 的幂。

---

## 哈希冲突

key 是无限的(任意长的字符串)，桶是有限的(就那么长的数组)，迟早两个不同的 key 会算到同一个下标——这就是**哈希冲突**。上面 `banana` 和别的词都可能落到桶 3。冲突不是"能不能避免"，是**必然发生、只能想办法收拾**。两条主流路子:

### 拉链法(链地址法)

桶里不直接存值，而是存一条**链表的头**。撞到同一个桶的元素，串成一条链挂后面。查找时先定位桶，再沿链比对 key。冲突少时链很短、接近 O(1);冲突多时链变长、退化到 O(n)。这就是经典的"**数组 + 链表**"组合，Go、Java 8 之前的 `HashMap` 都是这一类。

```
桶[3] ─▶ [banana|7] ─▶ [cherry|9] ─▶ nil
```

### 开放寻址法

不用链表，所有元素都直接住数组里。撞了就**往后找下一个空位**(最简单的叫线性探测):

```
桶[3] 被 banana 占了 → cherry 来了看桶[4] → 空,cherry 住桶[4]
```

好处是全部连续存储、**缓存友好**，没有链表指针到处跳。坏处是删除麻烦:不能直接清空格子，否则探测链断了(后面的元素就找不到)，得打个"**墓碑**(tombstone)"标记;而且越满探测越慢，对装载因子更敏感。Python 的 dict 走这条，**Go 1.24+ 的 map 也从拉链法换到了这条路**——这个反转后面会细说。

| | 拉链法 | 开放寻址 |
|---|---|---|
| 存储 | 数组 + 链表 | 纯数组 |
| 缓存友好 | 一般(链表跳来跳去) | **好**(连续) |
| 删除 | **简单**,断链即可 | 麻烦,要墓碑 |
| 高装载因子 | 抗压(链变长而已) | 脆(探测急剧变慢) |
| 额外内存 | 每个元素多一个指针 | 省 |

---

## 手写一个拉链法哈希表

光说不练没用，我们把上面这套亲手撸出来。一个桶是一条冲突链，节点带 `next`:

```go
type entry struct {
	key   string
	value int
	next  *entry // 同一个桶里的冲突链
}

type HashMap struct {
	buckets []*entry // 桶数组:每个元素是一条冲突链的头
	size    int      // 已存元素个数(算装载因子用)
}

func NewHashMap() *HashMap {
	return &HashMap{buckets: make([]*entry, 8)} // 初始 8 个桶(2 的幂)
}

// 算下标:长度是 2 的幂,用位与代替取模
func (m *HashMap) index(key string) int {
	return int(hash(key) & uint32(len(m.buckets)-1))
}
```

**Put**——先看装载因子要不要扩容，再沿链找:key 已存在就更新，否则头插一个新节点:

```go
func (m *HashMap) Put(key string, value int) {
	// 装载因子 = size/桶数,超过 0.75 先扩容再插
	if float64(m.size)/float64(len(m.buckets)) > 0.75 {
		m.resize()
	}
	i := m.index(key)
	for e := m.buckets[i]; e != nil; e = e.next {
		if e.key == key { // key 已存在:更新值,不新增
			e.value = value
			return
		}
	}
	// 不存在:头插(O(1),新节点接到链头)
	m.buckets[i] = &entry{key: key, value: value, next: m.buckets[i]}
	m.size++
}
```

**Get**——定位桶，沿链比对 key。用 `(int, bool)` 双返回值区分"值是 0"和"根本没这个 key":

```go
func (m *HashMap) Get(key string) (int, bool) {
	for e := m.buckets[m.index(key)]; e != nil; e = e.next {
		if e.key == key {
			return e.value, true
		}
	}
	return 0, false
}
```

**Delete**——删链表节点要处理"删头"的边界。这里用**二级指针** `**entry`，让删头和删中间走同一套逻辑，省掉 `if 是头节点` 的特判:

```go
func (m *HashMap) Delete(key string) {
	pp := &m.buckets[m.index(key)] // 指向"当前指针"的指针
	for *pp != nil {
		if (*pp).key == key {
			*pp = (*pp).next // 直接改上一级的指向,绕过被删节点
			m.size--
			return
		}
		pp = &(*pp).next
	}
}
```

**resize**——最关键的一步:桶数翻倍，把**每个旧元素按新长度重新落桶**。注意不能照搬旧下标——桶数变了，`hash & (n-1)` 的结果全变了:

```go
func (m *HashMap) resize() {
	old := m.buckets
	m.buckets = make([]*entry, len(old)*2) // 桶数翻倍
	m.size = 0
	for _, head := range old { // 遍历旧桶的每条链
		for e := head; e != nil; e = e.next {
			m.Put(e.key, e.value) // 用新长度重新算下标、重新落桶
		}
	}
}
```

一百多行，一个能用的哈希表就齐了。跑一下:

```go
m := NewHashMap()
m.Put("apple", 7)
m.Put("banana", 9)
m.Put("apple", 42) // 覆盖
fmt.Println(m.Get("apple"))  // 42 true
fmt.Println(m.Get("cherry")) // 0 false
m.Delete("banana")
fmt.Println(m.Get("banana"))  // 0 false
```

---

## 装载因子与扩容:均摊 O(1) 的来由

上面 `Put` 里那行 `> 0.75` 就是**装载因子**阈值。装载因子 = 元素数 / 桶数，衡量"挤不挤":太高冲突多、链变长、退化 O(n);太低一堆空桶、浪费内存。所以到阈值就翻倍扩容 + 全量 rehash。

rehash 要遍历所有元素，这**一次**是 O(n)。但它不是每次插入都发生，而是攒够了才来一趟，摊到每一次插入上——**均摊仍是 O(1)**，和数组 `append` 翻倍扩容是完全一样的均摊思想。为什么翻倍能把冲突打散:

```
旧数组 n=4,元素挤在桶 3 → 扩容到 n=8 后重新取模
下标 3: 3 & 3 = 3,  3 & 7 = 3   → 还在桶 3
下标 7: 7 & 3 = 3,  7 & 7 = 7   → 挪到桶 7
原来同挤桶 3 的两个,扩容后被拆到 3 和 7,冲突缓解
```

> 我这个手写版 `resize` 是**一次性**搬完所有元素——几百万个 key 时这一下会明显卡顿。生产级实现都不会这么干,思路是**把这次 O(n) 的开销摊平到后续操作里**,避免单次长停顿。
>
> **Redis** 用的是经典的**渐进式 rehash**:新旧两个哈希表并存,之后每次读写顺手搬一小撮过去,搬完才丢掉旧表。**Go 1.24+** 换了个更巧的办法——它把数据分成多张小表,**哪张满了就单独分裂哪张**,一次只动一小部分,"渐进"就成了结构自带的性质(后面细说)。思想是一样的:**别一次搬完,改成分期付款。**

---

## Go 的 map 到底长什么样

手写版懂了，本来想说"Go 的 map 就是同一套思想的工业级加强版"——**但这话现在不能说了。Go 1.24 把 map 整个重写了，换的不是参数，是算法。**

```
Go ≤ 1.23   拉链法的加强版      runtime/map.go               hmap / bmap，靠 overflow 挂链
Go ≥ 1.24   Swiss Tables       internal/runtime/maps/       Map / table / group，开放寻址，没有链
```

**方向变了**:从前面对比表里的"拉链法"那一栏，跳到了"开放寻址"那一栏。这套东西来自 Google Abseil 的 `flat_hash_map`，业界一般叫 **Swiss Tables**。

下面讲 1.26.3 的现行实现，源码在 `internal/runtime/maps/` 下的 `map.go`、`table.go`、`group.go`。

### 核心:8 个槽 + 一个控制字

```
Map
 └─ dirPtr ─▶ [ table0 │ table1 │ ... ]        目录，存多张 table
                  │
                  └─▶ [ group0 │ group1 │ ... ]

     一个 group:
     ┌───────────────────────────────────────────────┐
     │ ctrl(8 字节)  每槽 1 字节: 空 / 墓碑 / h2      │  ← 精华在这
     ├───────────────────────────────────────────────┤
     │ slots[8]      8 个 key/elem 对                 │
     └───────────────────────────────────────────────┘
```

查找就三步，关键全在那个控制字上:

1. key 的哈希拆成 **h1**(选哪个 group)和 **h2**(高 7 位，存进控制字)
2. 定位到 group 之后，**把 8 个控制字节一次性和 h2 比对**——amd64 上是真的 SIMD 指令(`pcmpeqb` + `pmovmskb`)，非 x86 平台用 uint64 位运算模拟同样的效果
3. 拿到一个"哪几个槽可能匹配"的**位掩码**，只对这几个槽真正去比完整 key

**这就是它甩开拉链法的地方:一条指令筛掉 8 个槽。** 而我们手写的那个链表，每次都要一个个跳指针，每跳一下都可能是一次 cache miss。

槽满了怎么办?**不挂溢出桶，而是开放寻址**——按二次探测的顺序去下一个 group 找空位。所以 1.24+ 的 map 里**压根没有"链"这个东西了**。

### 跟我们手写版比，差别在这几点

- **一次比 8 个，而不是一个个跳。** 手写版查一个 key 要顺着链表一路 `node = node.next`，Go 一条 SIMD 指令就把 8 个候选筛完。
- **冲突不挂链，改成往后找。** 手写版桶满了就往链表尾巴上挂;Go 直接跳到下一个 group 探测。**少了指针跳转，全是连续内存访问。**
- **删除要留"墓碑"。** 这是开放寻址绕不过去的坑:不能直接把槽清空，否则会截断后面的探测链——后面的元素就永远找不到了。所以标记成 tombstone。手写版的拉链法没这个问题，直接摘链表节点就行。
- **每个 group 至少留一个空槽**(最大装载因子 7/8 = 87.5%)，保证探测一定能停下来。
- **小 map 有专门快路径。** 元素 ≤ 8 时，`dirPtr` 直接指向一个 group，连 table 那层都不要——因为现实里绝大多数 map 都很小，这条快路径很值。
- **扩容不再是"重建整个 map"。** 目录里哪张 table 装满了，**就单独把那一张分裂成两张**(可扩展哈希)。所以"渐进式搬迁"变成了结构自带的性质，不用像旧实现那样手工维护"新旧两个桶数组 + 每次操作搬 1~2 个桶"。

> 写到这我自己的一点感慨:**开放寻址在教科书里通常被讲成"拉链法的备选方案"，实践中好像总是拉链法赢。** 但 Swiss Tables 说明胜负是会翻的——一旦硬件给了你"一条指令并行比 8 个字节"这种能力，算法的账就得重算一遍。**"哪个方案更好"从来不是纯理论问题，它取决于你跑在什么硬件上。**

---

## 三个必踩的坑

**坑 1:遍历顺序是随机的。** Go 故意在遍历时加随机起点，就是逼你别依赖顺序:

```go
m := map[string]int{"a": 1, "b": 2, "c": 3}
for k := range m {
	fmt.Print(k, " ") // 每次运行顺序都可能不同:c a b / b c a ...
}

// 要有序,自己捞出来排:
keys := make([]string, 0, len(m))
for k := range m {
	keys = append(keys, k)
}
sort.Strings(keys) // a b c
```

**坑 2:并发读写直接 fatal，`recover` 都拦不住。** 不是普通 panic，是整个进程挂掉:

```go
m := map[int]int{}
go func() { for { m[1] = 1 } }() // 一个协程写
go func() { for { _ = m[1] } }() // 另一个协程读
// fatal error: concurrent map read and map write
```

并发场景老实加锁(`sync.RWMutex`)，或读多写少用 `sync.Map`。

**坑 3:不能对 map 元素取地址。** 因为扩容会搬动元素、地址随时失效，编译器干脆禁止:

```go
type Point struct{ X, Y int }
mp := map[string]Point{"a": {1, 2}}

// mp["a"].X = 10        // 编译错误:cannot assign to struct field mp["a"].X
p := mp["a"]             // 正确:整体取出
p.X = 10                 //       改
mp["a"] = p              //       放回
// 或者干脆存指针:map[string]*Point,直接 mp["a"].X = 10
```
