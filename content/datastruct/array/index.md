---
title: "数据结构-Array"
date: 2026-08-04T15:56:26+08:00
draft: false
summary: ""
carousel: true
---

## Summary

数组是最基础、也最被低估的数据结构。它的两个标签——**连续存储**和 **O(1) 随机访问**——不仅决定了它自己的性能，还撑起了几乎所有更复杂的结构(栈、队列、堆、哈希表的桶、邻接矩阵)，以及一整套只有数组才玩得转的算法套路(双指针、前缀和、差分、滑动窗口)。真正吃透数组，是吃透后面一切的前提。

---

## 数组在内存里到底长什么样

假设有一个 `[5]int32`，每个 `int32` 占 4 字节，它在内存里是这样的:

```
下标:      0        1        2        3        4
        ┌────────┬────────┬────────┬────────┬────────┐
内存:    │ 4 字节 │ 4 字节  │ 4 字节  │ 4 字节  │ 4 字节 │
        └────────┴────────┴────────┴────────┴────────┘
地址:   1000     1004     1008     1012     1016
        ↑
      首地址 base
```

因为元素**等大**、内存**连续**，访问第 `i` 个元素时，CPU 不需要一个个数过去，而是直接用一个乘加算出地址:

```
element_address = base_address + i * element_size
```

访问下标 2:`1000 + 2 * 4 = 1008`，一步到位。**这个"一步算出地址"就是 O(1) 随机访问的本质**，也是数组区别于链表最核心的优势——链表的节点散落各处，想找第 i 个只能从头走 i 步。

---

## CPU 缓存行(Cache Line)

内存比 CPU 慢两个数量级，所以 CPU 有多级缓存(L1/L2/L3)。CPU 从内存加载数据时，**不是只加载你要的那几个字节，而是一次加载一整条"缓存行"(cache line，通常 64 字节)**。

数组是连续存储，所以访问 `a[0]` 时，`a[1]`、`a[2]`…… 很可能已经被顺带加载进缓存了，接下来遍历它们直接命中，极快。这叫**空间局部性**。链表则相反:节点散落各处，访问下一个大概率是一次缓存未命中(cache miss)，要重新去慢速内存取。**这就是为什么即使链表和数组遍历都是理论 O(n)，数组在真实机器上往往快好几倍。** 

---

## 数组是所有数据结构的基石

很多"高级"结构，底层其实就是一个数组 + 规则:

- **栈 / 队列**:用数组 + 下标即可实现(顺序栈、循环队列)。
- **堆(二叉堆)**:一棵完全二叉树直接压进数组，下标 `i` 的左右孩子是 `2i+1`、`2i+2`，父亲是 `(i-1)/2`
- **哈希表的桶数组**:哈希函数把 key 映射成下标，底层就是一个数组。
- **字符串**:本质是字符/字节的数组(Go中 的 `string` 底层是只读 `[]byte`)。
- **位图 / 位集合(bitset)**:用数组的每一个 bit 表示一个元素在不在，极省空间，uniswap的Tick系统就是使用这个数据结构。判重、布隆过滤器都靠它:
- **图的邻接矩阵**:`matrix[i][j]` 表示 i、j 之间有没有边，就是个二维数组。
- **环形缓冲(ring buffer)**:数组 + 取模下标，循环利用空间，是循环队列和很多 IO 缓冲的原型。
- **稀疏数组(sparse array)**:当绝大多数元素是同一个默认值(如 0)时，只记录"非默认"的少数位置，省内存。

---

## 数组上的经典算法范式

### 原地操作(LeetCode 189. Rotate Array）

利用 O(1) 随机访问，直接在原数组上交换/覆盖，不开辅助数组，做到 **O(1) 额外空间**。最基本的是"交换"和"反转":

```go
func rotate(nums []int， k int) {
	if k == 0 {
		return
	}
	length := len(nums)
	if length == 0 {
		return
	}
	if k%length == 0 {
		return
	}
	if k > length {
		k = k % length
	}

	tmp := append([]int{}， nums[len(nums)-k:]...)
	copy(nums[k:]， nums[:length-k])
	copy(nums[:k]， tmp)
}
```
> 我这实现空间上不是O(1)

### 双指针 · 对撞指针(167. Two Sum II - Input Array Is Sorted)

两个指针从两端向中间逼近。适合**有序数组求一对元素**、判断回文等:

```go
func twoSumSorted(a []int， target int) (int， int) {
    i， j := 0， len(a)-1
    for i < j {
        s := a[i] + a[j]
        switch {
        case s == target:
            return i， j
        case s < target:
            i++ // 和太小，左指针右移变大
        default:
            j-- // 和太大，右指针左移变小
        }
    }
    return -1， -1
}
```

### 6.3 双指针 · 快慢指针 (26. Remove Duplicates from Sorted Array、80. Remove Duplicates from Sorted Array II)

一快一慢同向移动，慢指针维护"已处理好的边界"。适合**原地删除/去重/移动**:

```go
func removeDuplicates(nums []int) int {
    if len(nums) <= 2 {
        return len(nums)
    }
    slow := 2                       // 第 0 个元素天然保留，从 1 开始写
    for fast := 2; fast < len(nums); fast++ {
        if nums[fast] != nums[slow-2] {   // 和已保留的最后一个不同 → 是新元素
            nums[slow] = nums[fast]
            slow++
        }
    }
    return slow
}
```

### 6.4 前缀和（303. Range Sum Query - Immutable）

预先算出"从头到每个位置的累加和"，之后**任意区间和都能 O(1) 查询**。用 O(n) 预处理换来无数次 O(1) 查询:

```go
type NumArray struct {
    sums []int
}

func Constructor(nums []int) NumArray {
    sum := make([]int， len(nums)+1)
    for i， v := range nums {
        sum[i+1] = sum[i] + v
    }
    return NumArray{ sums : sum }
}

func (this *NumArray) SumRange(left int， right int) int {
    return this.sums[right+1] - this.sums[left]
}
```

### 6.5 差分数组（1094. Car Pooling）

前缀和的"逆操作"。当需要**对某个区间整体加同一个值、且这种区间更新很多次**时，用差分数组能把每次更新降到 O(1)，最后一次前缀和还原:

```go
func carPooling(trips [][]int， capacity int) bool {
    diff := make([]int， 1001)
    for _， t := range trips {
        num， from， to := t[0]， t[1]， t[2]
        diff[from] += num
        diff[to]   -= num
    }

    cur := 0
    for _， d := range diff {
        cur += d
        if cur > capacity {
            return false
        }
    }
    return true
}
```


### 6.6 滑动窗口（3. Longest Substring Without Repeating Characters）

用两个指针维护一个"窗口"，随着右指针扩张、左指针收缩，**避免重复计算**。定长窗口最直观——进一个、出一个:（这个用法在TCP流量控制里面也有使用到）

```go
func lengthOfLongestSubstring(s string) int {
	record := make(map[byte]int) // 记录字符最近一次出现的下标
	left， ret := 0， 0
	for right := 0; right < len(s); right++ {
		one := s[right]
		if idx， ok := record[one]; ok && idx >= left {
			left = idx + 1
		}
		record[one] = right
		if right+1-left > ret {
			ret = right + 1 - left
		}
	}
	return ret
}
```

---

## 某语言的具体实现

前面讲的都是"数组"这个数据结构的通用道理。这一节看 Go 是怎么落地的——它把"静态数组"和"动态数组"分成 `array` 和 `slice` 两个东西，搞混它们是 Go 新手最常见的 bug 来源。

### 数组 `[N]T`:值类型

```go
var a [3]int = [3]int{1， 2， 3}
b := a          // 整个数组被【拷贝】!b 和 a 是两份独立数据
b[0] = 99       // a 仍然是 [1 2 3]
fmt.Println(a == b) // 数组支持 == 比较(元素逐个比)，这里 false
```

Go 的数组是**值类型**，赋值、传参都**整体拷贝**;长度是类型的一部分，`[3]int` 和 `[4]int` 是**不同类型**。一般也不用数组，都用切片。

### 切片 `[]T`:动态数组，本质是个"视图"

切片不是数组，它是一个**三元组结构体**，指向某个底层数组:

```go
type slice struct {
	array unsafe.Pointer
	len   int
	cap   int
}
```

```go
s := make([]int， 3， 5)  // len=3， cap=5，底层数组能放 5 个
fmt.Println(len(s)， cap(s)) // 3 5
```

### append 与扩容(当前版本 go1.26.3)

动态数据 append 多数操作均为O(1), 偶尔扩容O(n)，均摊下来就是O(1) —— 这是数组最重要的复杂度结论。

`append` 时，编译器先计算 newLen = oldLen + num，若 newLen > cap(oldSlice)，就会触发扩容，调用 growslice（runtime/slice.go）函数。

```go
func growslice(oldPtr unsafe.Pointer, newLen, oldCap, num int, et *_type) slice {
    oldLen := newLen - num // 切片当前的长度
    // ... 
    if et.Size_ == 0 {
        return slice{unsafe.Pointer(&zerobase), newLen, newLen} // 这一行就是为什么创建 []struct{}，不会产生新的内存的原因
    }

    newcap := nextslicecap(newLen, oldCap)   // 第一步:算“理论新容量”

    noscan := !et.Pointers() // 第二步:把 newcap*元素大小 向上对齐到内存 size class
    var overflow bool
    var lenmem, newlenmem, capmem uintptr
    switch {
    case et.Size_ == 1:                      // 元素 1 字节,免
        lenmem    = uintptr(oldLen) // 旧的长度
        newlenmem = uintptr(newLen) // 新的长度
        capmem    = roundupsize(uintptr(newcap), noscan) // 字节对齐，内存对齐可以运行下，最下面的一段代码
        overflow  = uintptr(newcap) > maxAlloc // 溢出检查
        newcap    = int(capmem) // 获得新容量， 以下case大同小异，
    case et.Size_ == goarch.PtrSize:         // 元素=一个指针宽(例如：[]int、[]*T),乘除被优化成移位
    case isPowerOfTwo(et.Size_):             // 使用位移进行计算
    default:                                 // 默认情况，直接乘除
        lenmem = uintptr(oldLen) * et.Size_ // 旧长度*元素大小
    }

    if overflow || capmem > maxAlloc {
        panic(errorString("growslice: len out of range"))
    }

    // 分配 + 拷贝
    var p unsafe.Pointer
    if noscan {
        p = mallocgc(capmem, nil, false)
        // append 马上会覆盖 [oldLen, newLen),只需清零“不会被覆盖”的尾部
        memclrNoHeapPointers(add(p, newlenmem), capmem-newlenmem)
    } else {
        p = mallocgc(capmem, et, true)       // 含指针,必须清零好让 GC 能扫描
        if lenmem > 0 && writeBarrier.enabled {
            bulkBarrierPreWriteSrcOnly(uintptr(p), uintptr(oldPtr), lenmem-et.Size_+et.PtrBytes, et)
        }
    }
    memmove(p, oldPtr, lenmem)               // 旧数据整体拷到新数组
    return slice{p, newLen, newcap}
}
```

nextslicecap 函数

```go
func nextslicecap(newLen, oldCap int) int {
      newcap := oldCap
      doublecap := newcap + newcap
      if newLen > doublecap {
          return newLen              // 翻倍都不够 → 直接使用最新长度newLen=oldLen+num（新添加的元素数量）
      }

      const threshold = 256
      if oldCap < threshold {
          return doublecap           // < threshold :直接翻倍
      }
      for {
          newcap += (newcap + 3*threshold) >> 2//大切片:从 2x 平滑过渡到 1.25x
          if uint(newcap) >= uint(newLen) {
              break
          }
      }
      if newcap <= 0 {
          return newLen              // 溢出兜底
      }
      return newcap
  }
```

**为什么扩容要成倍增长,而不是每次 +1?** 若每次只加 1,插入 n 个元素要拷贝 `1+2+…+n = O(n²)` 次,灾难。成倍增长时,虽然单次扩容 O(n),但扩容越来越稀疏,把总代价均摊到每次 append 上,**均摊复杂度仍是 O(1)**——这是"均摊分析"最经典的例子。

### 共享底层数组——最经典的坑

切片类似是"视图"，多个切片可指向同一个底层数组，这是 Go 数组类知识里**最容易踩的雷**:

```go
s := []int{1， 2， 3， 4， 5}
sub := s[1:3]        // sub = [2 3]，和 s 共享同一底层数组
sub[0] = 99          // s 也变了! s 变成 [1 99 3 4 5]
```

更隐蔽的是 `append` 引发的意外覆盖:

```go
a := []int{1， 2， 3， 4， 5}
b := a[:2]            // b=[1 2]， len=2， cap=5(和 a 共享)
b = append(b， 100)   // cap 够，直接写进底层数组下标 2 → a 变成 [1 2 100 4 5]!
```

**防御**:用**三索引切片** `s[low:high:max]` 限制 cap，或用 `copy` 深拷贝:

```go
b := a[0:2:2]
c := make([]int， len(a));
copy(c， a) // 或干脆拷一份
```

### nil 切片 vs 空切片

```go
var s1 []int          // nil 切片:s1 == nil 为 true，len/cap 都是 0，可直接 append
s2 := []int{}         // 空切片:s2 != nil 为 false，len/cap 为 0
```

两者都能安全 `append` 和 `range`，日常用 `var s []int` 声明 nil 切片即可。序列化 JSON 时 nil → `null`、空切片 → `[]`，写 API 时要注意。

### 内存对齐测试代码

```go
type One struct {
    a bool
    b int64
    c bool
}
fmt.Println("unsafe.Sizeof(One{}) ", unsafe.Sizeof(One{}))

type Two struct {
    b int64
    a bool
    c bool
}
fmt.Println("unsafe.Sizeof(Two{}) ", unsafe.Sizeof(Two{}))
```
