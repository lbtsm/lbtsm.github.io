---
title: "路由协议-lifi"
date: 2026-08-14T22:08:56+08:00
draft: false
tags: ["跨链", "LI.FI", "跨链聚合器", "Diamond", "UniswapX", "Intent", "Solver", "OIF", "ERC-7683"]
categories: ["webthree"]
summary: "从 LI.FI 是什么、开发者怎么接入,一路讲到它的内部架构(Diamond 代理、BridgeData/SwapData、寻路在链下执行在链上),再对标 UniswapX;后半篇单独讲 LI.FI Intents & Solver——意图市场怎么运作、Escrow/Compact 两种锁资金方式、四种订单类型与荷兰拍公式,以及集成方和 solver 各自怎么接入。"
---

## 导读

链多了以后，钱包里的资产是**碎的**:USDC 在 Polygon、ETH 在 Arbitrum、稳定币又躺在 Base。想把 A 链的某个币变成 B 链的另一个币，你得亲手干三件麻烦事——**选一座靠谱的桥**(几十座桥各有价格、速度、安全性)、**在两头各做一次 DEX 兑换**(桥往往只认少数几种中转币)、再**把这一长串调用拼成交易发出去**。LI.FI 就是把这三件事打包掉的**跨链聚合器**:你告诉它"从哪条链的什么币，到哪条链的什么币"，它负责比价选路、拼好交易、一把执行完。

但 LI.FI 其实有**两条产品线、两套范式**,这也是这篇文章的分界:

- **前半篇(一~二)讲聚合器**——链下给你算路线，**你自己发交易、自己付 gas、自己扛桥的风险**。
- **后半篇(四~五)讲 LI.FI Intents**——你只表达意图，**solver 用自己的钱先把币给你**,风险和选路都转移出去。
- **中间第三节**用 UniswapX 做参照，把这两种范式的分界线说清楚。

按目的挑着看:

| 你想干什么 | 直接跳到 |
|---|---|
| 快速给产品接一个跨链换币 | **一** · 三种接入姿势 |
| 搞懂 LI.FI 合约是怎么设计的 | **二** · 内部架构 |
| 分清"聚合器"和"意图"到底差在哪 | **三** · 对标 UniswapX、**六** · 三者对比 |
| 理解 Intents / solver 的运作原理 | **四** |
| 上手写 Intents 的接入代码 | **五** |

---

## 一、聚合器:它解决什么问题、怎么接入

### 多链流动性割裂

单看一条链，Uniswap 这类 DEX 已经把"同链换币"解决得很好了。但一旦跨链，事情立刻变复杂:

- **桥太多太杂**:Stargate、Across、Hop、CCTP、Connext…… 每座桥支持的链、收的币、手续费、到账速度、安全模型都不一样，用户根本挑不过来。
- **两头都要兑换**:桥通常只搬运少数几种"标准中转币"(比如 USDC、原生 ETH)。你手里的币桥不收，就得先在源链换成它认的币;到了目标链，你要的币桥又不给，还得再换一次。
- **一趟跨链 = 一串动作**:源链 swap → 跨桥 → 目标链 swap，中间任何一步失败都可能卡住资金。

LI.FI 干的就是跨链世界里的"**聚合 + 比价 + 执行**":把几十座桥、多家 DEX 聚合器接进来，帮你算出一条最优路线，再把整串动作打包成一次可执行的交易。你可以把它理解成**跨链版的 1inch/0x**——只不过它聚合的不只是 DEX，还有一堆桥。

### 三种接入姿势:Widget / SDK / 直接调合约

你想在自己的产品里加"跨链换币"，LI.FI 给了三个由浅入深的入口:

**① Widget:一段代码嵌一个完整 UI。** 最省事，连界面都不用写。装个 `@lifi/widget`，丢进页面就有一个能选链、选币、比价、发交易的完整组件。

**② SDK / API:只要数据和执行，UI 自己做。** 最常用的接入方式。核心就两步——**问路线**(`getRoutes`)、**执行**(`executeRoute`)，中间的选桥、编 calldata、授权、发交易、跨链状态轮询，SDK 全包了。

**③ 直接调合约:自己拼交易、自己发。** 不走 SDK，链下拿到路线数据后，自己把参数发给 LI.FI 的入口合约 `LiFiDiamond`。适合需要极致控制、或要把跨链塞进自己合约逻辑里的场景。走这条路就得懂它的内部结构了——下面正式进入内部架构。

> 三种姿势的分界很清楚:**要快用 Widget，要灵活用 SDK，要极致控制直接调合约**。绝大多数团队停在 SDK 这一层就够了。

---

## 二、聚合器的内部架构

### 一次跨链到底分几步

要看懂内部，先建立心智模型。“USDC on Polygon → ETH on Arbitrum” 这件事，拆开其实是三段:

```
①源链 swap        ②跨桥              ③目标链 swap
USDC ──DEX──▶ 桥认识的中转币 ──bridge──▶ 到账 ──DEX──▶ ETH
(Polygon)                              (Arbitrum)
```

- **第①段**:桥通常只认少数几种币。你手里的币桥不收，先在源链用一个 DEX 换成桥认识的中转币。
- **第②段**:调具体某座桥(Stargate / Across / …)把中转币跨过去。
- **第③段**:到了目标链，你要的最终币桥不给，再用目标链的 DEX 换一次。

第①③段不一定都有——桥直接收你的币、你要的就是到账的币，那这两段就省了。LI.FI 的合约要做的，就是把这条"可长可短"的链路，用一套**统一的接口**表达并执行。

### Diamond 模式:一个地址装下所有桥

桥有几十座，每座桥接入逻辑都不一样。最笨的做法是每座桥一个合约、用户面对一堆地址——没法维护。LI.FI 用的是 **EIP-2535，也就是 Diamond(钻石)代理模式**。

核心结构叫 `LiFiDiamond`。它本身几乎没有业务逻辑，只做一件事:**根据你调用的函数选择器(前 4 字节)，`delegatecall` 到对应的 facet(切面)合约去执行。**

```
                    ┌───────────────────────────┐
   用户只面对 ──▶   │      LiFiDiamond (代理)     │  ← 唯一入口地址
                    │  按 selector 分发 delegatecall│
                    └──────────────┬────────────┘
             ┌────────────┬────────┼─────────┬────────────┐
             ▼            ▼        ▼         ▼            ▼
        StargateFacet  HopFacet  AcrossFacet ...   GenericSwapFacet
        (每座桥 = 一个 facet，只放这座桥的接入逻辑)
```

`delegatecall` 是关键:它是"**借你的代码，在我的存储上跑**"。facet 里的代码执行时，读写的是 `LiFiDiamond` 的 storage、`msg.sender` 还是原始用户。所以对外永远是一个地址、一套状态，逻辑却散在几十个 facet 里。这套设计正好戳中跨链聚合器的痛点:

- **可插拔升级**:加一座新桥，只要部署一个新 facet，再通过 `DiamondCut` 把它的函数选择器挂上去，**地址不变、用户不用改集成**;下架同理，摘掉选择器。
- **绕开合约体积上限**:以太坊单合约有 24KB 字节码上限，几十座桥塞一个合约早爆了，切成 facet 就没这问题。
- **配套工具 facet**:`DiamondCutFacet`(增删改切面)、`DiamondLoupeFacet`(查有哪些 facet/函数)、`OwnershipFacet`、`WithdrawFacet`。

> 一个要留神的坑:所有 facet 共用钻石同一片 storage，两个 facet 若用同一个 slot 存不同东西就会**存储冲突**互相踩。Diamond 的解法是 "Diamond Storage"——每个 facet 用一个哈希算出的、几乎不可能撞的固定 slot 起点各存各的。

### 两个核心结构体:BridgeData 与 SwapData

不管走哪座桥，LI.FI 都用两个结构体描述一次操作。吃透这俩，就懂了它接口设计的全部精髓。

**`BridgeData`——描述"这一趟跨链的意图"**(桥无关的公共部分):

```solidity
struct BridgeData {
    bytes32 transactionId;      // 全局唯一 ID,串起源链和目标链的两笔交易
    string  bridge;             // 走哪座桥,如 "stargate"
    string  integrator;         // 集成方(谁家 App 发起的),用于分成/统计
    address referrer;           // 推荐人
    address sendingAssetId;     // 源链上要发出去的币(address(0) 表示原生币)
    address receiver;           // 目标链上的收款地址
    uint256 minAmount;          // 交给桥的最小数量(滑点保护下限)
    uint256 destinationChainId; // 目标链 ID
    bool    hasSourceSwaps;     // 源链上是否要先做 swap(对应第①段)
    bool    hasDestinationCall; // 目标链上是否要再做一步调用(对应第③段)
}
```

最后两个 `bool` 是路由"开关":告诉合约这趟是三段全跑，还是只跨桥。`hasSourceSwaps` 为真就先在源链兑换再上桥;`hasDestinationCall` 为真就得带着目标链要执行的动作一起跨过去。

**`SwapData`——描述"一步 DEX 兑换"**(源链、目标链的每一次 swap 都用它):

```solidity
struct SwapData {
    address callTo;            // 去调哪个合约做兑换(某个 DEX / 聚合器)
    address approveTo;         // 把授权给谁(有时和 callTo 不是同一个)
    address sendingAssetId;    // 换出的币
    address receivingAssetId;  // 换入的币
    uint256 fromAmount;        // 换出多少
    bytes   callData;          // 喂给那个 DEX 的完整调用数据
    bool    requiresDeposit;   // 是否需要先把币拉进来
}
```

注意 `callData` 这个 `bytes` 字段——它是**一整段预先编码好的、要发给某个 DEX 的调用数据**。也就是说 LI.FI 合约自己**不懂**任何一个 DEX 的接口，它只是拿着这段现成的 calldata 去 `call`。这一点是理解整个架构的关键，下面专门说。

### LibSwap:怎么执行一次"不认识"的兑换

上面说合约不懂任何 DEX，那 swap 到底怎么跑?逻辑集中在 `LibSwap.swap()`，动作朴素得很:

1. 校验 `callTo` 是个合约、`fromAmount` 不为 0;
2. 记下**兑换前**目标币的余额(快照);
3. 换出的是 ERC20 就给 `approveTo` 授权;是原生币就把数量作为 `msg.value` 带上;
4. 对 `callTo` 发一个 **low-level call**，把 `callData` 原样打过去;失败就把底层错误冒泡出来;
5. 再读一次目标币余额，**用前后差值**算出这次换回来多少，emit `AssetSwapped`。

看懂这个就明白:它是**用"转账 + 授权 + 裸调用 + 余额做差"这套通用动作，去适配任意 DEX**。今天接 0x、明天接 1inch、后天接 Paraswap，合约一行都不用改——因为具体怎么换，全写在链下拼好的那段 `callData` 里。

### 精髓:寻路在链下，执行在链上

这是最容易被忽略、但最重要的一点:**LI.FI 的合约本身不做"寻路"。**

"从哪座桥走最便宜、源链用哪个 DEX、滑点怎么设、calldata 怎么编"——这些是 LI.FI 的**链下 API / SDK** 算出来的。链下把最优路线规划好，编码成 `BridgeData` + `SwapData[]`，让你把这坨参数发给链上合约。合约的职责只有一个:**忠实地、原子地把链下拼好的这套动作执行掉**，中间哪一步失败就整笔回滚。

```
链下(API/SDK):比价、选桥、算滑点、拼 calldata  ──▶  链上(LiFiDiamond):照单执行、失败回滚
        “聪明”的部分                                       “可信”的部分
```

这套分工是几乎所有 DEX / 跨链聚合器的通用范式:易变、算力重的策略放链下，要求可信、原子的结算放链上。真正在源链 / 目标链执行兑换的，可以是 0x、1inch、Paraswap 这些外部聚合器，也可以是 LI.FI 自己的链上路由 `LiFiDEXAggregator`(fork 自 SushiSwap 的 RouteProcessor)。

### 目标链的另一半:Receiver

还有第③段——目标链的 swap——它其实发生在**另一条链、另一笔交易**里，源链交易管不着。桥能保证的只是"把中转币送到目标链的某个地址"。

所以 LI.FI 在目标链部署了 `Receiver` 类合约作为**收款落点**:桥把币打给它，它带着当初 `hasDestinationCall` 一起跨过来的指令，在目标链上替你把最后一步兑换做掉，再把成品打给真正的 `receiver`。这就是为什么 `BridgeData` 里要有 `hasDestinationCall` 这个开关——它决定了目标链到账后是"直接给你"还是"还得再折腾一下"。

---

## 三、对比:它对标 UniswapX 吗?

会问这个问题很自然:UniswapX 也在做"跨链、找最优执行"，那 LI.FI 是不是就是跨链版的它?**答案是:目标有重叠，但架构范式完全不同，算不上严格一对一对标。** 差别在于"谁来执行、怎么定价"。

**LI.FI 是"聚合器/路由"范式**:链下帮你算好路线，但**交易是你自己发的、gas 是你自己付的、执行风险(滑点、桥出问题)也是你承担**。它的价值在于把几十座桥和多个 DEX 聚合到一个接口，帮你选路——正是上面内部架构讲的那套。

**UniswapX 是"意图(intent)/拍卖"范式**:你不发交易，而是**签一个离线订单**——只声明"我出多少 A、最少要拿回多少 B"，剩下的不管。然后一批叫 **filler(solver)** 的专业做市商，在一个**荷兰式拍卖**里竞争:报价从高往低降，谁先愿意用最好的价格成交谁就接单，**由 filler 替你上链、替你垫 gas**。跨链时，filler 先在目标链把币打给你，再通过一个**结算预言机**(消息桥)把你锁在源链的输入放给 filler(这套正是 ERC-7683 跨链意图标准的落地)。

一个对比就清楚了:

| | LI.FI | UniswapX |
|---|---|---|
| 范式 | 聚合器 / 路由 | 意图 + 荷兰拍 |
| 用户做什么 | 发一笔交易 | **签一个离线订单** |
| 谁执行、谁付 gas | **你自己** | **filler 替你做、替你垫** |
| 定价 | 链下比价选路 | filler 竞价(RFQ 定起拍价) |
| 聚合的是 | **一堆桥 + 多个 DEX** | filler 背后的任意流动性 |
| 跨链方式 | 直接调桥(桥选择透明) | filler 垫付 + 结算预言机回收 |
| 用户的桥风险 | 直接暴露(你走哪座桥你知道) | 转嫁给 filler，用户少接触桥 |
| 长尾/薄流动性币 | 有桥有 DEX 就能拼 | 没 filler 有货就可能流拍 |

**一句话总结这场对比**:LI.FI 把"复杂性"透明地摊在你面前让你选路、你执行;UniswapX 把"复杂性"整个甩给 filler，你只签个意图、坐等收货。两者都在解决"跨链最优执行"，方向也在收敛(UniswapX 往跨链走，LI.FI 也在做 intent 能力)，但出发点一个是**"聚合执行"**、一个是**"意图 + 竞价"**——殊途同归的两条路线，而不是同一套东西。

---

## 四、LI.FI Intents:意图市场怎么运作

### 定位:和聚合器是两套东西

上面留了个尾巴——"LI.FI 也在做 intent 能力"。这不是 roadmap 上的空话，而是一条已经上线的独立产品线:**LI.FI Intents**,一个 solver(做市商)报价市场。

要先钉死一件事:**它和上半篇讲的聚合器是两套东西**，不是同一个接口换了个名字。

- **聚合器**(`LiFiDiamond`):链下给你算路线，**你自己发交易、自己付 gas、自己承担桥的风险**，桥是谁你一清二楚。
- **Intents**:你只表达"我出 10 USDC on Base，要 Arbitrum 上的 USDC"，一批 **solver** 用**自己的钱**先在目标链把币给你，之后再回源链把你锁住的输入拿走。选路、桥的风险、跨链等待，全转移到 solver 那一侧。

它还有个身份值得单独提:LI.FI Intents 是 **OIF(Open Intents Framework)** 的官方实现。OIF 是以太坊基金会牵头的开源意图框架，合约在 `openintentsframework/oif-contracts`。这跟上文提到的 **ERC-7683** 是同一条脉络——7683 定义"跨链订单长什么样"(统一订单结构 + 结算接口)，OIF 往前又走一步:把**锁资金、验证交付、跨链传消息**这三件事彻底拆成可自由组合的模块。所以这一章学到的东西不只对 LI.FI 有用，它正在变成行业公共标准。

### 角色与组件:六个名字先认清

| 名字 | 在链上/链下 | 干什么 |
|---|---|---|
| **Intent** | 用户表达 | 只描述"想要的结果",不指定执行路径 |
| **Solver** | 链下 + 双链发交易 | 挂报价、用**自有资金**垫付填单、事后回源链收钱 |
| **Input Settler** | 源链合约 | 管源链的钱:锁进来、验证通过后放给 solver |
| ├ `InputSettlerEscrow` | 源链 | **逐笔托管**:一单一锁 |
| └ `InputSettlerCompact` | 源链 | **一次充值**:基于 Uniswap 的 The Compact 资源锁，之后多次下单免 gas |
| **Output Settler** | 目标链合约 | 接收 solver 的交付、记录 fill、产出可验证的凭证 |
| **Oracle** | 跨链消息层 | 把"目标链确实交付了"这个事实搬回源链 |
| **Order Server** | 链下(LI.FI 运营) | 把用户 intent 撮合到 solver 已挂的报价上，并分发订单流 |

最容易混的是 **Input Settler / Output Settler / Oracle 的分工**,一句话记法:**Output Settler 负责"证明发生了什么"，Oracle 负责"把这个证明搬过去"，Input Settler 负责"看到证明就付钱"。**

### 一次 intent 的完整生命周期

```
源链 (Base)                                              目标链 (Arbitrum)
─────────────────────────────────────────────────────────────────────────
① 用户锁钱 + 声明想要什么
   InputSettlerEscrow.open(order)  ──emit Open──┐
                                                 │
② 订单流分发                                     ▼
   Order Server  ◀── WebSocket/链上事件 ──▶  Solver 集群
                                                 │
③ 撮合:拿 intent 去匹配 solver 早就挂好的报价     │
                                                 ▼
④                                    Solver 用自己的钱交付
                                     OutputSettler.fill(...)  ← 谁先 fill 谁赢
                                                 │
⑤ 验证 + 结算                          Oracle 打包凭证并跨链提交
   InputSettler.finalise()  ◀────── efficientRequireProven ────┘
   → 托管的 10 USDC 放给 solver
```

几个细节决定了这套东西的手感:

- **步骤①之后用户就没事了**。不用等、不用再签、不用管走哪座桥。到账速度取决于 solver 的垫资意愿，通常是秒级。
- **步骤④的胜负由速度决定**:"第一个调用 `fill(...)` 并写下自己 identifier 的 solver"拿走这一单。多输出订单里，**谁填掉第一个 output 谁就拿走全部 inputs**,但所有 output 填完之前 inputs 一直锁着。
- **步骤⑤是 solver 承担的风险窗口**:钱已经垫出去了，凭证还没回到源链。这段时间的跨链消息延迟、gas 波动、甚至 oracle 出问题，都算在 solver 头上——这也是为什么用户端体验能那么快。
- **两个 deadline 别搞混**:`fillDeadline` 是 solver 必须填完的截止时间;`expires` 之后用户才能领退款。`fillDeadline` 一定要留足余量早于 `expires`,否则会出现"solver 刚填完、用户已经能退款"的尴尬窗口。官方 quickstart 给的是 fill 30 分钟、expire 60 分钟。

### 关键设计:standing quotes,不是逐笔 RFQ

这是 LI.FI Intents 和 UniswapX / 传统 RFQ 最不一样的一点，也是它敢说自己延迟低的原因。

**传统 RFQ 是"问价"**:每来一笔单子，广播给所有 solver，等它们各自报价，再挑最优。往返一圈，几百毫秒到几秒就没了，而且 solver 不报你就没价。

**LI.FI Intents 是"挂单簿"**:solver 提前把自己的**报价曲线**批量上传——哪些路由、什么价格曲线、支持多大金额区间,一次能推最多 **20 万条**报价。用户的 intent 进来时，order server 直接在这份已有库存里**查表撮合**。

```
RFQ:      intent ──▶ 广播 ──▶ 等 N 个 solver 回价 ──▶ 选最优   (每笔都要等一轮)
Standing: solver ──▶ 预先上传 20 万条报价曲线
                        ↓
          intent ──▶ 直接查表撮合                              (零往返)
```

代价是报价的**时效性**:挂出去的曲线不是实时算的，市场剧烈波动时 solver 得自己勤快地刷新库存，否则要么亏、要么撤单。这也解释了为什么它的可用路由是**动态**的——覆盖范围随 solver 的实时库存一直在变，官方文档里的链和路由列表甚至是前端实时拉 `GET /chains/supported` 和 `GET /routes` 渲染出来的，而不是写死的。

### 三段解耦:OIF 真正的技术贡献

上文说过聚合器的精髓是"寻路在链下、执行在链上"。Intents 这一侧的精髓是另一句:**把锁资金、验证交付、跨链传消息拆开,各自可替换。**

以前的意图/跨链协议这三件事是焊死在一起的——换个消息桥就得重写结算合约。OIF 的做法是只规定极窄的接口。

**Output Settler 只需要暴露一个校验函数**:

```solidity
interface IPayloadCreator {
    function arePayloadsValid(bytes[] calldata payloads) external view returns (bool);
}
```

注意 `payloads` 是 **不透明的 `bytes[]`**。这意味着一次 fill 只要能被表达成一串字节，什么订单类型、什么虚拟机都能塞进来——这就是为什么同一套框架能同时挂上 EVM、Tron，甚至有个 `BitcoinOracle.sol`。

**Oracle 提交前先自证**:

```solidity
function submit(address proofSource, bytes[] calldata payloads) external payable {
    if (!IPayloadCreator(proofSource).arePayloadsValid(payloads)) revert NotAllPayloadsValid();
    _submit(proofSource, payloads);
}
```

**Input Settler 只问一句"证过了吗"**:

```solidity
interface IValidationLayer {
    /// @param proofSeries remoteOracle、remoteChainId、dataHash 按 32*4=128 字节分块编码
    function efficientRequireProven(bytes calldata proofSeries) external view;
}
```

这个函数**不返回 bool,而是不满足就 revert**——省掉调用方的分支判断，也让"空证明序列直接通过"这种同链场景自然成立。跨链只搬 **payload 的哈希**而不是完整数据，gas 便宜，但代价是:因为 payload 本身不标准，输入侧和输出侧的编码有可能**互不兼容**,官方文档自己也提示了这个坑。

现成的 oracle 实现有三个:`PolymerOracleMapped.sol`(默认，走 Polymer)、`WormholeOracle.sol`、`BitcoinOracle.sol`。

**同链交易是这套架构的一个漂亮特例**:订单格式完全不变,但**跨链消息那一段直接塌缩掉**——把 output settler 同时配成 input oracle 和 output oracle,它自己给自己作证,不需要任何外部验证层。所以"同链 swap"和"跨链 swap"在这套 API 里是同一个接口,这也是 LI.FI Intents 敢同时卖同链和跨链两种流量的原因。

### 两种锁资金方式:Escrow 还是 Compact

这是接入时的第一个真正的架构选择。

| | **Escrow** | **Compact**(资源锁) |
|---|---|---|
| 锁定方式 | **逐笔**,每单一次链上锁 | **一次充值**,余额反复用 |
| 提单方式 | 链上 `open` / `openFor` | **链下** `POST /orders/submit` |
| Gas | 每单都要付 | 首次充值后**免 gas** |
| 用户签什么 | 一笔交易 | 一个 **EIP-712 `BatchCompact` 签名** |
| 结算函数 | `finalise`(solver 自己调) | `finaliseWithSignature`(任何人可调) |
| 订单类型标识 | 链上检测 | `CatalystCompactOrder` |
| 适合谁 | **绝大多数集成方** | 高频下单、要 gasless、或本身就是资源锁原生应用 |

Compact 用的是 Uniswap 的 **The Compact** 资源锁。它的信任模型多了两个角色,值得单独理解:

- **sponsor** = 用户,锁里的钱是他的;
- **arbiter** = `InputSettlerCompact` 合约,负责最终裁定放款;
- **allocator** = 提供 nonce 域的角色,职责是**不给超出用户余额的重叠锁重复签名**。

安全边界因此是:用户信任 arbiter 不会欺诈性地 finalise，arbiter 和 solver 信任 allocator 不会超额共签。**没有任何单一角色能独立动用资金**——这是资源锁相对"直接托管"的核心卖点:钱在你自己的锁里,不在别人的合约里躺着。

**注意"gasless"是个有条件的说法**:提单确实零 gas,但首次充值(Escrow 是每笔的 approve/deposit)仍然是实打实的链上交易。文档也直说了:多数集成方**先用 Escrow**,有 gasless 刚需再上 Compact。

合约地址(EVM 各链**同址**,靠 keyless CREATE2 工厂部署,新 EVM 链可以无许可加):

| 合约 | 地址 |
|---|---|
| `InputSettlerEscrow` | `0x00fC00edbe7C003b006f870068c548940000223e` |
| `InputSettlerCompact` | `0x0000000000cd5f7fDEc90a03a31F79E5Fbc6A9Cf` |
| The Compact | `0x00000000000000171ede64904551eeDF3C6C9788` |
| `OutputSettler` | `0x75220B7600c300005038432a0000f308e0000068` |
| Polymer Oracle(主网) | `0x008C3800F3Ad9b3B662d002E90Cc00000000eE17` |
| Polymer Oracle(测试网) | `0xC401b53377b8A71A7cEB820e6a4dC53832343a90` |

Tron 另有一套:`InputSettlerEscrow` = `TXmVLCXzrhzmeCfchDPTmFF6Qe7rg3H7Kk`、`OutputSettler` = `THWDD3umarircbqo8jXxVazbpJnE25VjhN`、Polymer Oracle = `TCeNWukZUoTSrgWZEMpn9X8C5NtV8Rsy6c`。

### 订单类型:一个 `context` 字段撑起四种拍卖

目前只有一个输出结算器 `OutputSettlerSimple.sol`,但它靠 `MandateOutput.context` 的**首字节**区分出四种订单:

| 类型 | 首字节 | 语义 |
|---|---|---|
| 限价单 Limit | `0x00` 或空 `0x` | 固定价,谁先填谁得 |
| 独占限价单 Exclusive Limit | `0xe0` | 指定 solver 在窗口内独占,**LI.FI Widget 的默认类型** |
| 荷兰拍 Dutch | `0x01` | 价格随时间衰减 |
| 独占荷兰拍 Exclusive Dutch | `0xe1` | 独占窗口 + 衰减曲线 |

`MandateOutput` 结构体本身很规整:

```solidity
struct MandateOutput {
    bytes32 oracle;      // 目标链用哪个 oracle 作证
    bytes32 settler;     // 目标链的 output settler
    uint256 chainId;     // 目标链
    bytes32 token;       // 要交付的币
    uint256 amount;      // 要交付的量(荷兰拍里这是"地板价")
    bytes32 recipient;   // 收款人
    bytes   call;        // 交付后要执行的自定义 calldata
    bytes   context;     // ← 拍卖类型全靠它
}
```

地址字段全是 `bytes32`(左填充),这样非 EVM 链的地址也塞得下——又是"为多虚拟机留门"的设计。

**`context` 的编码**:

```
限价单:        context = "0x" 或 "0x00"
独占限价单:    bytes1(0xe0) | bytes32(exclusiveFor) | bytes4(startTime)
荷兰拍:        bytes1(0x01) | uint32(startTime) | uint32(stopTime) | uint256(slope)
独占荷兰拍:    bytes1(0xe1) | bytes32(exclusiveFor) | uint32(startTime) | uint32(stopTime) | uint256(slope)
```

**荷兰拍的价格公式**(合约里就这么几行):

```solidity
uint32 currentTime = max(block.timestamp, startTime);
if (stopTime < currentTime) return amount;
uint256 timeDiff = stopTime - currentTime;
return amount + slope * timeDiff;
```

读法:**solver 需要交付的数量 = 地板价 `amount` + 剩余时间 × 斜率**。所以

- 天花板是 `amount + (stopTime - startTime) * slope`,出现在 `startTime`;
- 越早填,solver 交付得越多(**solver 越亏、用户越赚**);
- 时间推向 `stopTime`,线性衰减到地板价 `amount`;
- 过了 `stopTime` 就是平的限价单。

于是形成一场博弈:solver 想等价格衰减到自己有利润再动手，但等着就有被别人抢单的风险。**这正是荷兰拍在替用户压价**——和 UniswapX 的荷兰拍是同一个机理,只不过 LI.FI 这套是**在链上按 `block.timestamp` 结算**的,不依赖链下拍卖服务。

**独占窗口**的用处是省 gas:在 `startTime` 之前只有指定的 `exclusiveFor` 能填,`startTime` 之后放开给所有人。配合 order server 的 **Reputation(声誉)系统**,可以把单子先给历史表现好的 solver,避免一堆 solver 同时抢单、大部分交易 revert 掉白烧 gas。官方建议的窗口是 **30 秒到 1 分钟**。

两个实现时要留神的点:

1. **多输出的荷兰拍只有第一个 output 是拍卖**,其余全按最差价格结算。原因很直白:solver 只在第一个 output 上竞争(赢下它就等于赢下整单)。
2. 官方文档里独占荷兰拍的类型标识写的是 `0xe1`,但编码示例里的首字节写成了 `0x01`——**这两处对不上**,实现前请以 `oif-contracts` 里 `OutputSettlerSimple.sol` 的源码为准。
3. 同一个 `orderId` 下**每个 output 只能被填一次**,合约把 output 哈希后记在按 `orderId` 索引的 mapping 里去重。

---

## 参考

- [LI.FI 合约仓库(lifinance/contracts)](https://github.com/lifinance/contracts)
- [LI.FI Intents 官方文档 · Introduction](https://docs.li.fi/lifi-intents/introduction)
- [LI.FI Intents Quickstart(Escrow 完整代码)](https://docs.li.fi/lifi-intents/quickstart)
- [LI.FI Intents 架构总览](https://docs.li.fi/lifi-intents/architecture/overview) · [拍卖机制](https://docs.li.fi/lifi-intents/for-solvers/auctions) · [Solver API](https://docs.li.fi/lifi-intents/for-solvers/api-overview)
- [Order Server 交互式 API 文档](https://order.li.fi/docs)
- [Open Intents Framework(OIF)](https://openintents.xyz/) · [oif-contracts 源码](https://github.com/openintentsframework/oif-contracts)
- [The Compact(Uniswap 资源锁)](https://github.com/Uniswap/the-compact)
- [UniswapX Overview | Uniswap Developers](https://developers.uniswap.org/docs/liquidity/uniswapx/overview)
- [How Dutch Auctions Deliver Better Swaps | Uniswap Blog](https://blog.uniswap.org/how-dutch-auctions-deliver-better-swaps)
- [ERC-7683 跨链意图标准解读 | BuildBear](https://medium.com/buildbear/a-deep-dive-into-erc-7683-for-cross-chain-intent-8368818e0f07)