---
title: "Binarysearch"
date: 2026-09-22T16:52:07+08:00
draft: false
tags: []
categories: []
summary: ""
---

## Summary

当你你手里有一本厚厚的电话簿,要找"张伟"这个名字。你会从第一页一页页翻——还是会直接翻到中间,看看翻到的是"李"还是"王":姓氏排在"张"前面就往后翻,排在后面就往前翻。每翻一次,剩下要找的范围就少一半。一千页的电话簿,最多翻十次就能定位。

这就是二分查找的全部思想:**在一个有序的范围里,每次砍掉一半**。

听起来简单到不值得单独开一节,但二分查找是公认最容易写错的简单算法。有个流传很广的说法:Jon Bentley 曾让上百名职业程序员现场手写二分,只有约 10% 一次写对。Bentley 自己在《编程珠玑》里写的版本,和 Java 标准库里的 `Arrays.binarySearch`,都被发现存在整数溢出的 bug,而且那个 bug 在 JDK 里潜伏了九年。

问题不在思想,在**边界**。区间是开是闭、`mid` 怎么算、循环条件用 `<` 还是 `<=`、找不到时返回什么——这几个地方任意一个想岔了,程序就会漏掉一个元素,或者死循环。所以这一章的重点不是"理解二分",而是**建立一套自己永远不会写错的写法**。

各位可以先自己写一遍自己理解的二分查找，再使用以下例子进行测试，如果没问题的话，可以不用看的。

```go
// Example 1
// [1, 3, 5, 7, 9]
// find 9
// Example 2
// [1, 2]
// find 2
// Example 3
// [1, 3, 5, 7, 9]
// find 3
// Example 4
// [1, 2, 3]
// find 3
// Example 5
// [1, 3, 5, 7, 9]
// find 6
```

## 二分能用的前提

首先二分查找不是万能的,它有两个硬性前提:

**前提一:数据有序。** 更准确地说,是数据在你关心的那个维度上**单调**。因为二分每一步都要做一个判断:"目标在左半边还是右半边",只有单调性能保证这个判断是可靠的。数组 `[1, 5, 3, 9]` 里查 3,你翻到中间看到 5,根本没法断定 3 在哪边。

**前提二:能 O(1) 随机访问。** 二分要不停地"跳到中间那个位置",数组做得到(`a[mid]` 一步到位,靠的是 `基址 + mid × 元素大小` 直接算出内存地址),链表做不到——链表要走到第 `mid` 个节点得从头爬 `mid` 步,爬的代价把省下来的时间全吃光了,总复杂度反而退化成 O(n)。这就是为什么你会看到"链表用归并排序,不用快排;链表查找不用二分,用哈希表"。

顺带说个容易被忽略的现实:**"有序"这个前提本身是有成本的**。如果你只查一次,先排序 O(n log n) 再二分 O(log n),还不如直接线性扫一遍 O(n)。二分真正划算的场景是**排一次、查很多次**:排序成本被摊薄到几乎为零,之后每次查询都是 O(log n)。数据库给字段建索引(B+ 树),本质就是这笔账。

---

## 两种区间写法:先选一种,然后从一而终

二分写错,九成错在**区间定义前后不一致**。所以第一步是明确:`left` 和 `right` 这两个指针,圈出来的是一个什么区间。

主流有两种约定,各自自洽,但**不能混用**:

```
写法 A:左闭右闭 [left, right]
        right 指向的元素"在搜索范围内",是候选之一
        初始 right = n-1

写法 B:左闭右开 [left, right)
        right 指向的元素"不在搜索范围内",是个哨兵位
        初始 right = n
```

选定之后,循环条件和指针移动方式都由它推导出来,不需要死记:

**写法 A(左闭右闭)的推导:**
- 区间 `[left, right]` 什么时候还有元素?`left <= right` 时(比如 `[3,3]` 里还有一个元素)。所以循环条件是 `while left <= right`。
- 判定 `a[mid] < target` 说明 mid 及其左边全不要了,新区间是 `[mid+1, right]`,所以 `left = mid + 1`。
- 判定 `a[mid] > target` 说明 mid 及其右边全不要了,新区间是 `[left, mid-1]`,所以 `right = mid - 1`。

```go
// 左闭右闭:在有序数组 a 中查找 target,返回下标;不存在返回 -1
func binarySearch(a []int, target int) int {
    left, right := 0, len(a)-1 // 注意:右闭,所以是 n-1
    for left <= right {        // 区间非空的条件
        mid := left + (right-left)/2
        switch {
        case a[mid] == target:
            return mid
        case a[mid] < target:
            left = mid + 1 // mid 已排除
        default:
            right = mid - 1 // mid 已排除
        }
    }
    return -1
}
```

**写法 B(左闭右开)的推导:**
- 区间 `[left, right)` 什么时候还有元素?`left < right` 时(`[3,3)` 是空区间)。所以循环条件是 `while left < right`。
- `a[mid] > target` 时新区间是 `[left, mid)`,所以 `right = mid`——注意这里**不减 1**,因为 right 本来就取不到。

```go
// 左闭右开
func binarySearchHalfOpen(a []int, target int) int {
    left, right := 0, len(a) // 注意:右开,所以是 n
    for left < right {       // 区间非空的条件
        mid := left + (right-left)/2
        switch {
        case a[mid] == target:
            return mid
        case a[mid] < target:
            left = mid + 1
        default:
            right = mid // 不减 1
        }
    }
    return -1
}
```

两种写法没有优劣之分。建议**挑一种当自己的默认写法,以后所有二分题都用它**,把肌肉记忆固定下来。本章后面统一用左闭右闭。

---

## JDK中那个潜伏九年的 bug:`(left+right)/2` 会溢出

上面代码里的 `mid := left + (right-left)/2` 看着别扭,为什么不直接写 `(left + right) / 2`?

因为当 `left` 和 `right` 都很大时,`left + right` 可能**超出整型的表示范围**,变成负数。在 Java 里 `int` 是 32 位,最大约 21 亿,两个 10 亿以上的下标一加就溢出成负数,然后 `a[负数]` 直接抛异常。2006 年 Google 的 Joshua Bloch 写了篇著名的文章 "Extra, Extra - Read All About It: Nearly All Binary Searches and Mergesorts are Broken",披露 JDK 里这个 bug 存在了九年。

`left + (right-left)/2` 在数学上完全等价(`left + (right-left)/2 = (left+right)/2`),但计算过程中 `right - left` 永远不会超过数组长度,所以不可能溢出。

在任何场景下，只要是使用了数值类型的操作，一定要考虑边界问题，要让自己养成这种条件反射。另外还有一种比较优雅的写法就是位移操作，`(left + right) >>> 1`，靠无符号右移把溢出后的负数救回来。

---


## 二分的真正难点:查"边界"而不是查"某个值"

工程里 90% 的二分需求,其实不是"找到 target 就返回",而是这类问题:

- 数组里有多个 5,我要**第一个** 5 的位置
- 数组里没有 5,我要"**如果插入 5,应该插到哪**"
- 我要**第一个大于等于 5** 的元素 / **最后一个小于 5** 的元素

这类叫**边界查找**,也叫 `lower_bound` / `upper_bound`(名字来自 C++ STL)。它比"精确查找"更常用,也更容易写错。

关键的思路转变是:**别再想"找到就返回",改成"不断收缩,直到区间为空,此时 left 停在哪就是答案"**。

### lower_bound:第一个 >= target 的位置

```
a = [1, 3, 5, 5, 5, 8, 9]
             ↑
target = 5,lower_bound 返回 2(第一个 5 的下标)
target = 6,lower_bound 返回 5(第一个 >= 6 的是 8)
target = 10,lower_bound 返回 7(全都小于 10,返回 n,表示"插到末尾")
```

写法上和精确查找的差别只有一处:**找到相等时不立刻返回,而是继续往左收缩**,因为左边可能还有相等的。

```go
// Example []int{1, 3, 5, 5, 5, 8, 9} find 3, return 2
// lowerBound 返回第一个 >= target 的下标;全都小于 target 时返回 len(a)
func lowerBound(a []int, target int) int {
    left, right := 0, len(a)-1
    ans := -1 // not found or length of array
    for left <= right {
        mid := left + (right-left)/2
        if a[mid] >= target { // upper_bound 时，变成 a[mid] > target 
            ans = mid       // mid 是一个候选答案,记下来
            right = mid - 1 // 但左边可能还有更靠前的,继续往左找
        } else {
            left = mid + 1
        }
    }
    return ans
}
```

这个 `ans` 变量是让二分变简单的关键技巧。你不用去推敲"循环结束时 left 到底停在哪",而是**每次遇到一个合法候选就存下来,然后继续往更优的方向找**。

有了这两个函数,一堆问题瞬间变成一行:

```go
// target 出现了多少次
count := upperBound(a, target) - lowerBound(a, target)

// target 是否存在
i := lowerBound(a, target)
exists := i < len(a) && a[i] == target

// 严格小于 target 的元素有多少个
less := lowerBound(a, target)
```

**建议:把 `lowerBound` 当成你的基础件,精确查找反而用它拼出来。** 这样你只需要保证一个函数写对,而不是每道题重写一遍二分。

---

## 二分答案:当"数组"不存在的时候

这是二分最容易被低估的用法,也是从"会做题"跨到"会用算法"的分水岭。

前面所有例子都在一个真实存在的有序数组里找。但很多问题里根本没有数组——有的是一个**答案的取值范围**,以及一个**判断某个答案可不可行的函数**。如果"可行性"随答案单调变化(小的答案都可行、大的都不可行,或者反过来),就能对答案本身二分。

这个套路叫**二分答案**(binary search on the answer)。识别它的信号词是:"**求最小的最大值**"、"**求最大的最小值**"、"**求满足条件的最小/最大的 X**"。

举个具体的:**分割数组的最大值**(LeetCode 410)。把数组分成 m 个连续子数组,让"各子数组和的最大值"尽可能小,求这个最小值。

直接想怎么分,思路会绕进死胡同。换个角度:**假设答案是 x,能不能验证 x 是否可行?** 也就是"每段和都不超过 x 的前提下,能不能分成 m 段以内"。这个验证很简单——贪心地从左往右累加,超了就切一刀,数一数切了几段。

```
限制 x = 18:  [7,2,5] [10,8]   → 2 段,≤ m,可行
限制 x = 10:  [7,2] [5] [10] [8] → 4 段,> m,不可行

可行性随 x 单调:x 越大越容易可行
x:  9  10  ... 17  18  19  20 ...
可行? ✗  ✗  ...  ✗  ✓  ✓  ✓ ...
                     ↑ 我们要找的就是这个分界点
```

单调性一确认,就是标准的"找第一个可行的 x",即在答案范围上做 lower_bound:

```go
// splitArray:把 nums 分成 m 个连续子数组,最小化"各段和的最大值"
func splitArray(nums []int, m int) int {
    // 答案的下界:至少要装得下最大的那个元素
    // 答案的上界:全部放一段,就是总和
    left, right := 0, 0
    for _, v := range nums {
        if v > left {
            left = v
        }
        right += v
    }

    // check(x):每段和不超过 x 时,最少要分几段
    check := func(x int) bool {
        segments, sum := 1, 0
        for _, v := range nums {
            if sum+v > x {
                segments++ // 装不下了,切一刀,另起一段
                sum = v
            } else {
                sum += v
            }
        }
        return segments <= m // 段数没超,说明 x 这个限制是可行的
    }

    ans := right
    for left <= right {
        mid := left + (right-left)/2
        if check(mid) {
            ans = mid       // mid 可行,记下来
            right = mid - 1 // 试试还能不能更小
        } else {
            left = mid + 1 // mid 太小了,放宽限制
        }
    }
    return ans
}
```

注意结构和 `lowerBound` 一模一样,只是把 `a[mid] >= target` 换成了 `check(mid)`。**二分答案的全部难度都在"设计 check 函数"和"论证单调性"上,二分骨架本身是死的。**

这个套路在工程里非常实用:

- **限流阈值调参**:找"能扛住不超时的最大 QPS"
- **容量规划**:找"能在 T 秒内处理完的最少机器数"
- **Gas 估算**:以太坊的 `eth_estimateGas` 本质就是对 gas limit 二分,反复模拟执行,找"刚好不会 out-of-gas 的最小值"。这是 Go 后端调链上接口时天天在用的东西,geth 的 `gasprice`/`estimateGas` 实现里就是一个标准二分循环。
- **打包/传输**:找"分片大小取多少能在带宽限制内传完"

---

## 常见坑速查

**坑一:死循环。** 最典型的是把 `right = mid - 1` 写成 `right = mid`(在左闭右闭写法里)。当区间收缩到两个元素、`mid` 恰好等于 `left` 时,`right = mid` 没有让区间变小,循环就卡死了。判断方法:**确保每次迭代区间严格变小**。

**坑二:区间写法混用。** `right` 初始化成 `len(a)` 却用 `left <= right` 循环,第一次就会访问 `a[len(a)]` 越界。选定一种写法后,初始值、循环条件、指针更新三者必须配套。

**坑三:忘了检查结果。** `lowerBound` 返回的下标可能等于 `len(a)`,也可能指向一个不等于 target 的元素。用之前必须 `i < len(a) && a[i] == target`,顺序不能反(Go 的 `&&` 短路求值保证了不会越界)。

**坑四:对未排序数据用二分。** 结果不是报错,而是**静默返回错误答案**——这是最难查的一类 bug。写工具函数时,如果调用方可能传未排序数据,值得在测试里加一条断言。

**坑五:浮点数二分不能用 `left <= right`。** 浮点数没有"相邻"的概念,减 1 加 1 都不成立。标准做法是**固定迭代次数**(通常 100 次,精度远超 float64 能表达的范围)或者判断 `right - left > 1e-9`:

```go
func sqrtFloat(x float64) float64 {
    left, right := 0.0, x
    if x < 1 {
        right = 1 // x < 1 时平方根大于 x 本身
    }
    for i := 0; i < 100; i++ { // 固定次数,不判相等
        mid := left + (right-left)/2
        if mid*mid < x {
            left = mid
        } else {
            right = mid
        }
    }
    return left
}
```

---

## Go 标准库里的二分

自己会写是一回事,工程里该用标准库还是要用。

**`sort.SearchInts` / `sort.SearchStrings` / `sort.SearchFloat64s`** —— 就是 `lowerBound`,返回第一个 >= target 的下标,找不到返回 `len(a)`:

```go
a := []int{1, 3, 5, 5, 5, 8, 9}
i := sort.SearchInts(a, 5) // i = 2
found := i < len(a) && a[i] == 5
```

**`sort.Search(n, f)`** —— 最通用的那个,也是最值得掌握的。它在 `[0, n)` 上找**第一个让 `f(i)` 返回 true 的 i**,前提是 `f` 单调(false...false true...true)。它本身就是"二分答案"的现成骨架:

```go
// 用 sort.Search 实现 lowerBound
i := sort.Search(len(a), func(i int) bool { return a[i] >= 5 })

// 用 sort.Search 做二分答案(注意这里在 [0, right-left] 上二分,再偏移)
x := left + sort.Search(right-left+1, func(i int) bool { return check(left + i) })
```

**`slices.BinarySearch`(Go 1.21+)** —— 泛型版本,返回值更友好,直接给你 `(下标, 是否找到)`,省掉了自己判断相等这一步:

```go
a := []int{1, 3, 5, 5, 5, 8, 9}
i, ok := slices.BinarySearch(a, 5)          // i = 2, ok = true
j, ok2 := slices.BinarySearch(a, 6)         // j = 5, ok2 = false(6 该插在下标 5)

// 自定义比较:结构体切片按某字段二分
type Order struct{ Price, Amount int }
idx, found := slices.BinarySearchFunc(orders, 100, func(o Order, target int) int {
    return cmp.Compare(o.Price, target)
})
```

新代码优先用 `slices.BinarySearch`,它的 `(i, ok)` 返回值设计让"找不到时插到哪"这个信息也一并给了你,配合 `slices.Insert` 就能维护一个始终有序的切片。

---

## 实际场景应用

**订单簿与价格档位。** DEX 聚合器/做市里维护的价格档位是有序的,查"某个价格能吃到多少量"、"往哪个档位插新单",就是 `lowerBound` + `slices.Insert`。用二分维护有序切片,在数据量不大(几百到几千)时比红黑树更快——因为切片连续内存对 CPU 缓存友好,`memmove` 的常数极小。

**区块高度定位。** "找到时间戳最接近某个时刻的区块"、"找第一个高度 >= N 且包含某事件的区块",都是在单调递增的高度/时间上二分。跨链桥做重组检测、补历史事件时反复用到。注意区块时间戳虽然大体单调,但存在允许的漂移,写代码时要以**高度**为二分维度,不要以时间戳。

**Gas 估算。** 上面提过,`eth_estimateGas` 就是对 gas limit 二分 + 反复 `eth_call` 模拟。理解它是二分,你就明白为什么估算会比普通调用慢好几倍(要执行 log(range) 次模拟),以及为什么估出来的值有时候不准(状态在两次模拟之间变了,单调性假设被打破)。

**限流与背压调参。** 找"系统能承受的最大并发数"是典型的二分答案,check 函数就是压测一轮看错误率。比起手工试参数,写成二分能少试很多次。
