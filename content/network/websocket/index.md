---
title: "Websocket"
date: 2026-10-22T15:30:11+08:00
draft: false
tags: []
categories: []
summary: ""
---

## Summary

在实际工作中产品经理给你的 SaaS 后台提了一个需求:加一个在线客服。客户在网页右下角的聊天框里提问,客服在管理后台里回复;客服后台的右上角有个小铃铛,来了新工单就亮一个红点,这个需求你会怎么处理呢,需要用到哪些网络知识呢。

这个需求里有两处"有事要立刻知道":

- 客服点了发送,回复要立刻出现在客户的聊天框里。
- 客户提交了新工单,客服后台的铃铛要立刻亮。

两处的共同点是,消息产生在服务端,需要服务端去通知浏览器。而之前我们讲的HTTP只有一种对话方式:一问一答，是无法处理这个的。

---

## 先把问题看准:TCP 本来就能双向说话

首先"服务端不能主动发消息"这个说法其实不准确。之前讲到 TCP 时,讲过连接建立后,两个方向各有一条独立的字节流,任何一方都可以随时往自己那个方向写数据,这叫**全双工**。四次挥手要挥四次,正是因为两个方向要各自关闭。

限制不在 TCP,而在 HTTP 给这条连接定的规矩:浏览器发一个请求,服务端回一个响应。即使 keep-alive 让连接一直开着,服务端也不能在没有请求的时候往里写东西,浏览器的 HTTP 解析器会把这当成协议错误。

```
TCP 层:   浏览器 ◀═════════════════▶ 服务端     两个方向随时可写

HTTP 层:  浏览器 ──── 请求 ────▶ 服务端
          浏览器 ◀─── 响应 ───── 服务端         一问一答,服务端不能先开口
```

打个比方,TCP 是一条接通了的电话线,两边都能说话;HTTP 是两个人约好的规矩:只有我问了你才能答。电话线本身没问题,是规矩把一半能力锁住了。

后面我们来看都有哪些方案，可以实现从服务端随时把消息传过去。

---

## 短轮询

最直接的做法是让浏览器定时来问。每条聊天消息在数据库里有一个自增的序号 `seq`,客户的聊天框每 3 秒请求一次:

```
GET /api/conversations/88/messages?after=1024
```

意思是"把第 1024 条之后的新消息给我"。

```
聊天框: 1024 之后有新消息吗? ──▶ 服务端: 没有
        (等 3 秒)
聊天框: 1024 之后有新消息吗? ──▶ 服务端: 没有
        (等 3 秒)
聊天框: 1024 之后有新消息吗? ──▶ 服务端: 有,第 1025 条:"您好,请问订单号是多少?"
```

这一版半小时就能写完,但毛病也很明显。

**慢。** 客服发出回复后,最多要等 3 秒客户才看到。聊天的时候,3 秒的延迟已经很明显了。轮询间隔调短能缓解,但会让下一个问题更严重。

**浪费。** 一次对话里大部分时间是在等对方打字,绝大多数请求返回的都是"没有"。每次白问都要带上几百字节的 HTTP 头和 Cookie,服务端还要查一次数据库。假如同时有 1 万个客户开着聊天框,就是每秒 3333 个请求,几乎全是空转,数据库被这些"有没有新消息"压得喘不过气。

不过短轮询有一个后面会用上的优点:**它不会漏。** 浏览器记住"我看到第几条了",下次就从下一条接着拉。网络断了、页面休眠了、服务端重启了,恢复后照样从断点继续。每次请求都是独立的,不依赖任何连接状态。这个性质先记着,后面还要用它。

---

## 长轮询,让服务端先别回

短轮询浪费在"没消息也立刻回答"。那就改一下:浏览器来问的时候,如果没有新消息,服务端先不回,把请求挂着,等有新消息了再回。

```
聊天框: 1024 之后有新消息吗? ──▶ 服务端: (没有,先挂着)
                                          ...
                                          客服发了一条回复
        ◀───────────────────────────── 立刻返回第 1025 条
聊天框: (收到后马上再问 1025 之后) ──▶ 服务端: (又挂着)
```

用 Go 里写起来很自然,一个 `select` 等三件事:

```go
func pollHandler(w http.ResponseWriter, r *http.Request) {
    convID := r.PathValue("id")
    after, _ := strconv.ParseInt(r.URL.Query().Get("after"), 10, 64)

    if msgs := store.MessagesAfter(convID, after); len(msgs) > 0 {
        json.NewEncoder(w).Encode(msgs) // 已经有新消息,直接返回
        return
    }

    ch := hub.Watch(convID) // 这个会话来了新消息,ch 就会收到通知
    defer hub.Unwatch(convID, ch)
    select {
    case <-ch:
        json.NewEncoder(w).Encode(store.MessagesAfter(convID, after))
    case <-time.After(25 * time.Second): // 一直没消息也得回,原因见下
        w.WriteHeader(http.StatusNoContent)
    case <-r.Context().Done(): // 客户关了页面
    }
}
```

延迟问题解决了:客服一发送,挂着的请求马上带着新消息返回。数据库的压力也小了,没有消息时请求只是挂在内存里等,不查库。

那个 25 秒的超时是被逼出来的。浏览器和你的服务之间隔着 Nginx、云 LB 这些代理,它们都有空闲超时,Nginx 的 `proxy_read_timeout` 默认 60 秒。一个请求挂太久没响应,会被代理直接掐断,浏览器收到一个 504。所以服务端得赶在代理超时之前,主动回一个"暂时没有",让浏览器重新来问。**中间设备的空闲超时**这个问题,到了 WebSocket 会以更隐蔽的方式再出现一次。

长轮询的代价有两个:

- **服务端要同时挂着大量请求。** 在 Go 里这不算什么,一个挂起的请求就是一个阻塞的 goroutine,几 KB 内存。但对"一个连接一个线程"的老式服务器,1 万个挂起的请求就是 1 万个线程,这就是当年 C10K 问题的由来。
- **两次请求之间有空档。** 一个响应返回、下一个请求还没到的这几十毫秒里,如果客服又连发了一条,服务端手上没有挂着的请求可以回。好在 `after=序号` 还在:下一个请求一来,带着"我看到第 1025 条了",服务端把后面的补上就行。

早期的网页聊天(比如十几年前的网页版 QQ、Gmail 聊天)就是用长轮询做的。今天它还常用在扫码登录、等支付结果这类**一次性等待**的场景:等到一个结果就结束,不需要源源不断的消息。

---

## SSE,让响应永远不结束

长轮询每回一条消息就结束响应,然后重新请求。再往前走一步:响应干脆不结束,有一条消息就往里写一条。

响应头里不写 `Content-Length`,body 就可以一块一块往外发,只要服务端不发结束标记,这个响应就一直开着。**SSE(Server-Sent Events)** 就是在这个基础上约定了一个极简的文本格式。客服后台的铃铛用它来做,线上的样子是这样的:

```
HTTP/1.1 200 OK
Content-Type: text/event-stream

id: 301
event: ticket
data: {"ticket":5521,"title":"退款申请","from":"张女士"}

id: 302
event: ticket
data: {"ticket":5522,"title":"发票抬头修改","from":"李先生"}

```

每条消息由若干 `字段: 值` 的行组成,空行表示一条消息结束。服务端的 Go 代码:

```go
func notifyHandler(w http.ResponseWriter, r *http.Request) {
    w.Header().Set("Content-Type", "text/event-stream")
    w.Header().Set("Cache-Control", "no-cache")
    flusher := w.(http.Flusher)

    ch := notify.Subscribe(currentAgent(r))
    defer notify.Unsubscribe(ch)
    for {
        select {
        case n := <-ch:
            fmt.Fprintf(w, "id: %d\nevent: ticket\ndata: %s\n\n", n.Seq, n.JSON())
            flusher.Flush() // 不 Flush 就攒在缓冲区里发不出去
        case <-r.Context().Done():
            return
        }
    }
}
```

浏览器这边只要几行:

```javascript
const es = new EventSource('/api/agent/notifications');
es.addEventListener('ticket', e => bell.light(JSON.parse(e.data)));
// 断线后浏览器自动重连,并在请求头里带上 Last-Event-ID: 302
```

注意那个 `id` 字段。连接断了之后,浏览器会自动重连,并在请求头里带上 `Last-Event-ID: 302`,服务端看到就知道从第 303 条开始补发。长轮询里靠 `after=序号` 手工处理的续传,SSE 直接做进了协议和浏览器里。

对通知界面的铃铛这个需求,SSE 正合适:消息只从服务端流向浏览器,它就是普通的 HTTP 响应,Nginx、CDN、LB 基本不用改配置,断线重连和续传浏览器全包了。**铃铛做到 SSE 就可以停了**,不必上 WebSocket。

其实现在我们每天都在用的一个 SSE 例子是 AI 对话:ChatGPT、Claude 网页上那种一个字一个字往外蹦的打字机效果,以及它们 API 的流式输出(`stream: true`),走的都是 SSE。模型生成一个 token 就往响应里写一行 `data: ...`,浏览器收到一行渲染一行。

有一个小限制:HTTP/1.1 下浏览器对同一个域名最多同时开 6 个连接,每个 SSE 都占一个。客服开了 7 个后台标签页,第 7 个就卡住了。换成 HTTP/2 就没有这个问题,所有 SSE 都是同一条连接上的不同流。

那聊天框能不能也用 SSE?可以:服务端的新消息用 SSE 推下来,客户发消息就普通地 `POST /messages`。很多系统确实就是这么做的,够用。

但聊天还有一些更细的需求:客户每敲一个字,客服那边要显示"对方正在输入…";客服读了消息,客户这边要显示"已读"。这些都是**浏览器往服务端发的、频率很高的小消息**,每一条都发一个完整的 POST,头部比内容大几十倍,延迟也高。到了这一步,就需要一条两个方向都能随时说话的通道了。

---

## WebSocket,握手之后不再说 HTTP

### 先借 HTTP 的道,再把 HTTP 扔掉

既然 HTTP 的规矩是问题所在,为什么不直接用 TCP?

这个是因为浏览器出于安全考虑,不允许网页开裸 TCP 连接;而且现实网络里,很多防火墙和代理只放行 80/443 端口上的 HTTP 流量,一个不认识的协议根本过不去。

WebSocket 的办法是:**先发一个普通的 HTTP 请求,在里面申请换协议;对方同意之后,这条 TCP 连接就不再说 HTTP 了。**

```
浏览器发一个看起来很普通的 HTTP 请求:
  GET /ws/chat HTTP/1.1
  Host: app.example.com
  Upgrade: websocket                  ← 我想换成 websocket 协议
  Connection: Upgrade
  Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
  Sec-WebSocket-Version: 13
  Origin: https://app.example.com
  Cookie: session=...

服务端同意:
  HTTP/1.1 101 Switching Protocols
  Upgrade: websocket
  Connection: Upgrade
  Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=

━━━━━ 从这一刻起,这条 TCP 连接上不再有 HTTP ━━━━━
```

对一路上的代理和防火墙来说,这就是一个发往 443 的普通 HTTP 请求,自然放行。等它们反应过来,连接已经换成别的协议了(这也是为什么代理要专门配置才能正确转发 WebSocket)。这里握手里的 `Origin` 和 `Cookie` 两个头先留意一下,后面的安全问题就出在它们身上。

`Sec-WebSocket-Accept` 计算的算法和常量都是公开的,所以它不提供任何安全性。它的作用是确认对方真的实现了 WebSocket:一个普通的 HTTP 服务器不会知道这个常量,也就算不出正确的值,浏览器不会把它误当成 WebSocket 服务器。

101状态码 之后,那条被 HTTP 规矩锁住的电话线解锁了。两边都可以随时往里写,谁也不用等谁先问。

### 拿回了全双工,还得自己分帧

拿回的是裸 TCP,也就拿回了 TCP 的老问题。TCP 是**字节流**,没有消息边界:服务端连续给你写了两条聊天消息,你一次 `Read` 可能读到一条半,也可能读到两条粘在一起。HTTP 用 `Content-Length` 或分块来划分边界,现在没有 HTTP 了,WebSocket 得自己来。

它的办法是在每条消息前面加一个**帧头**,帧头里写明这一帧的类型和长度。最小的帧头只有 2 字节:

```
 字节 0                          字节 1
 ┌───┬───────┬────────────┐  ┌──────┬─────────────────────┐
 │FIN│ RSV×3 │ opcode(4位)│  │ MASK │ 载荷长度(7 位)       │
 └───┴───────┴────────────┘  └──────┴─────────────────────┘
 后面按需跟:扩展长度(16 或 64 位)、掩码密钥(4 字节)、载荷数据
```

- **载荷长度**:7 位能表示 0~125。填 126 表示后面 2 字节才是真实长度,填 127 表示后面 8 字节才是。小消息只花 2 字节,大消息也能表示。
- **opcode**:这一帧是什么。`0x1` 文本,`0x2` 二进制,`0x8` 关闭,`0x9` Ping,`0xA` Pong。后三种叫控制帧,后面会讲到。
- **FIN**:是不是这条消息的最后一帧。一条大消息可以拆成多帧发。

和 HTTP 比一下开销:一条"对方正在输入"的通知,JSON 是 `{"type":"typing","conv":88}`,不到 30 字节。用 WebSocket 发,额外开销是 2~6 字节帧头;用 POST 发,要加上几百字节的请求头、Cookie 和响应头。这类高频小消息,正是 WebSocket 省得最多的地方。

**MASK 那一位有个奇怪的规定:浏览器发给服务端的帧必须加掩码,服务端发给浏览器的不能加。** 加掩码就是用帧头里一个随机的 4 字节密钥,和载荷逐字节异或。密钥就明文放在帧头里,所以掩码不提供任何机密性。

它防的是一种针对老式缓存代理的攻击。如果网页脚本能控制网线上出现的每一个字节,恶意网页就可以在 WebSocket 消息里构造一段看起来像 `GET /app.js HTTP/1.1 ...` 的内容。某些不懂 WebSocket 的透明代理会把它当成一个真的 HTTP 请求,还可能把攻击者伪造的响应缓存下来,之后发给所有访问 `app.js` 的用户,这叫**缓存投毒**。加了随机掩码之后,攻击者无法预测网线上的实际字节,也就构造不出"像 HTTP"的内容。服务端发出的数据不受网页脚本控制,所以不需要掩码。

这是一个为了兼容现实世界里各种老旧设备而付出的设计代价:协议本身不需要它,但不加就不安全。

### 四个版本放在一起看

| | 短轮询 | 长轮询 | SSE | WebSocket |
|---|---|---|---|---|
| 拿回了多少 TCP 能力 | 没有 | 服务端可以晚点回 | 服务端可以一直写 | 两边都随时写 |
| 延迟 | 一个轮询周期 | 低 | 低 | 低 |
| 每条消息的额外开销 | 完整的请求 + 响应头 | 完整的请求 + 响应头 | 几个字节的字段名 | 2~14 字节帧头 |
| 代理和 LB | 不用改 | 注意超时 | 基本不用改 | 要专门配置 |
| 断线重连、续传 | 天然 | 自己带序号 | 浏览器自带 | 全部自己写 |
| 典型场景 | 低频查询、补拉历史 | 扫码登录、等支付结果 | 通知、进度、AI 流式输出 | 聊天、协作编辑、游戏 |

越往右,从 TCP 拿回的能力越多,要自己负责的事情也越多。

### HTTP/2 和 HTTP/3 之后

这几年还有几个相关的东西,顺带说清楚,免得混淆:

- **HTTP/2 的 Server Push 不是这个问题的答案。** 它是服务端在浏览器请求 HTML 时,顺手把 CSS、JS 推进浏览器缓存,网页里的代码根本收不到这些推送。但是效果不好,Chrome 已在 2022 年移除。
- **WebSocket 可以跑在 HTTP/2 和 HTTP/3 上**(RFC 8441、RFC 9220)。这时它不再独占一条 TCP 连接,而是复用连接里的一个流,握手也从 `Upgrade` 换成了扩展的 `CONNECT` 方法。
- **WebTransport** 是基于 HTTP/3的新方案,一个会话里可以开多条独立的流,还能发不保证送达的数据报,适合游戏和音视频这类场景。
- **服务和服务之间**,如果双方都是自己写的,常用 gRPC 的双向流:它跑在 HTTP/2 上,能力和 WebSocket 相当,还自带接口定义和代码生成。

---

## 上线之后:连接会悄悄死掉

WebSocket 版本写好了,本地测试一切正常:客户发消息,客服秒收;客服打字,客户那边立刻显示"正在输入"。部署到线上之后,开始陆续收到两种奇怪的反馈。

### 现象一:聊着聊着就断了

客户反馈聊天框时不时显示"连接已断开,正在重连"。查日志发现规律:只要双方一分钟没说话,连接就断。

这是因为你的服务前面有 Nginx,`proxy_read_timeout` 默认 60 秒:60 秒内这条连接上没有数据,Nginx 就认为后端没响应,把连接关掉。长轮询时你知道要赶在 60 秒内回,而聊天的双方完全可能一两分钟不说话(客户去翻订单号了),连接就被掐了。

Nginx 转发 WebSocket 要专门这样配:

```nginx
location /ws/ {
    proxy_pass http://chat_backend;
    proxy_http_version 1.1;                  # Upgrade 是 HTTP/1.1 的机制
    proxy_set_header Upgrade $http_upgrade;  # 这两个头是逐跳的,不会自动转发,要手动透传
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 3600s;                # 默认 60s,不改就是一分钟不说话就断
}
```

但调大超时只解决了 Nginx 这一处。从客户的浏览器到你的服务,路上任何**需要记住连接状态**的设备都有空闲超时:云厂商的负载均衡器(AWS ALB 默认 60 秒)、客户家里路由器和运营商的 NAT、公司防火墙。这些大部分根本不归你管。

### 现象二:客服看到客户在线,发消息却石沉大海

第二个现象更隐蔽:客服后台显示某个客户"在线",客服回了好几条,客户却说什么都没收到,刷新页面才看到。

这是 TCP 的**假死**。客户合上了笔记本盖子、手机进了电梯、Wi-Fi 切到了 4G,浏览器那一侧的连接就这么没了,根本没机会发 FIN。服务端的 TCP 不知道对面已经没了,连接状态一直是 ESTABLISHED,服务端往里写消息,写进了本地发送缓冲区就算成功,不会报错。在线状态是根据"连接还在"来判断的,于是客服一直看到客户"在线"。

TCP 自己有一个 keepalive 机制能发现这种情况,但 Linux 默认连接空闲 2 小时之后才开始探测,对实时服务来说等于没有。

这种"看起来好好的,其实对面早没了"的连接,是长连接服务最常见也最难查的故障。服务以为有 1 万个客户在线,实际上一半是僵尸连接,白白占着内存和文件描述符,在线状态也全是错的。

### 心跳:一个机制治两个病

两个现象用同一个办法解决:**应用层自己定期发心跳。** WebSocket 协议里为此准备了 Ping 和 Pong 两种控制帧,收到 Ping 的一方必须回一个 Pong。

```
服务端每 30 秒给每条连接发一个 Ping
  ├─ 收到 Pong → 对面还活着,把"死亡计时器"重置到 60 秒后
  └─ 60 秒内什么都没收到 → 判定连接已死,关闭它,把客户标成离线
```

- 对现象一:每 30 秒就有数据经过,路上所有设备都不会认为连接空闲。所以心跳间隔要比路径上**最短的那个空闲超时**还短。
- 对现象二:Pong 迟迟不来,就说明对面没了,不用再等 TCP 的 2 小时,在线状态也就准了。

心跳最常见的错误写法是只发 Ping、不检查 Pong。这样能防住现象一,但防不住现象二:对面已经死了,你的 Ping 照样能写进本地的发送缓冲区,写操作不报错,你还以为一切正常。**一定要配读超时,并且在收到 Pong 时重置它。**

这里有一个浏览器特有的限制:**网页里的 JavaScript 没法发 Ping 帧**,浏览器的 WebSocket API 根本没有这个方法。浏览器只会在收到服务端的 Ping 时自动回 Pong。所以协议层的 Ping/Pong 只能由服务端发起,用来检测客户端。如果浏览器这一侧也想尽快发现"连接已经死了"(比如在页面上提示"网络已断开"),就得在应用层自己约定一种心跳消息,比如每 25 秒发一条 `{"type":"ping"}`,服务端回 `{"type":"pong"}`,一段时间没收到就主动断开重连。

---

## 断了之后:重连要做三件事

心跳只负责发现连接死了。网络切换、页面休眠、服务端发布新版本,连接一定会断,断了之后浏览器的重连逻辑要处理三件事。

**① 指数退避加随机抖动。** 你发布新版本,重启了一台聊天服务器,连在上面的几千个客户同时断开。如果每个浏览器都立刻重连、失败了再立刻重连,刚起来的服务就会被这波流量再次打垮,这叫**惊群**。正确做法是重连间隔按 1s、2s、4s、8s 递增到一个上限,每次再加一点随机时间,把这几千个客户端在时间上摊开。

**② 恢复连接上的状态。** 这是最容易漏的一件。客户打开聊天框时,浏览器在连接上发过一条"我要加入会话 88";客服登录后台时,发过"我负责这几个队列"。这些关系是记在服务端那条连接上的,重连之后是一条全新的连接,服务端对它一无所知。如果重连后不重新发这些消息,连接是通的,心跳也正常,但一条消息都收不到,而且没有任何报错。线上看到"重连成功但收不到消息",第一个就查这里。

**③ 补上断线期间的消息。** WebSocket 不会替你重发断线期间错过的消息,SSE 有 `Last-Event-ID`,WebSocket 没有。这时候上面说的那个短轮询就派上用场了:浏览器记着自己收到的最后一条消息序号,重连成功后,先用普通 HTTP 请求一次 `GET /messages?after=1031`,把空档补齐,再继续收推送。

几乎所有 IM 系统都是这个结构:**WebSocket 负责"快",HTTP 按序号拉取负责"全"。** 推送丢了不要紧,序号会告诉你缺了哪段,HTTP 会把它补回来。这也意味着服务端推送的每条消息都要带序号,浏览器收到时按序号去重,同一条消息推送和补拉各来一次,也只显示一次。

---

## 服务端规模化:长连接和基础设施的摩擦

用户量上来之后,一台聊天服务器不够用了,要部署多台。这时会碰到短连接时代没有的问题。

### 负载均衡对长连接失效

四层负载均衡只在建连那一刻选一次后端。对短连接,每次请求都重新选,负载自然均匀;对一条要活几个小时的 WebSocket,这一次选择就决定了它整个生命周期待在哪台机器上。

```
扩容前:2 台机器,各 5000 条连接,都很吃力
扩容后:3 台机器 → 老的两台还是各 5000,新机器 0 条
       只有新建的连接才会分过去,可能几个小时都不均衡
```

扩容几乎不起作用。解法和 gRPC 里的 `MaxConnectionAge` 一样:**给每条连接设一个最长寿命**(比如 30 分钟加一点随机),到期后服务端发一个 Close 帧(状态码 1001,表示"服务端要走了"),浏览器按短线重连处理,重连时就会被 LB 分到负载更低的机器上。有了上面的补拉,这次重连对用户是无感的。

发布时也一样。滚动更新要下线一台机器,不能直接杀进程,让上面几千条连接同时超时、同时重连。正确的顺序是:先从 LB 摘掉,再给存量连接分批发 Close 帧,让浏览器带着抖动陆续迁走,最后才退出。

### 客户和客服连在不同的机器上

部署成多台之后,马上会出现一个单机时不存在的 bug:客服发了消息,客户收不到。

原因很简单:客户的 WebSocket 连在 1 号机,客服的连在 2 号机。客服的消息到了 2 号机,2 号机在自己内存里找会话 88 的连接,找不到,因为客户根本不在这台机器上。

```
客户 ──WS──▶ 聊天服务 1 号机          客服 ──WS──▶ 聊天服务 2 号机
                                                    │ 收到客服的回复
                                                    │ 在本机找会话 88 的连接 → 没有
                                                    ✗ 消息就这么丢了
```

每台机器只知道自己手上有哪些连接。要让消息跨机器送达,中间得加一个所有实例都连着的消息通道。最常见的做法是用 Redis 的发布订阅:

```
                          ┌──────────────────┐
客户 ──WS──▶ 1 号机 ◀────  │  Redis Pub/Sub   │◀──── 2 号机 ◀──WS── 客服
               │  订阅了   │  频道 conv:88    │  发布到           
               │  conv:88 └──────────────────┘  conv:88
               ▼
         推给本机上会话 88 的连接
```

- 每台机器有连接加入某个会话时,就去订阅对应的频道(`conv:88`);这个会话在本机上没有连接了,就退订。
- 任何一台机器收到一条消息,先写数据库(拿到序号),再发布到对应频道。
- 所有订阅了这个频道的机器都会收到,各自推给本机上的相关连接。

Redis Pub/Sub 本身不保证送达,某台机器恰好在重连 Redis 时错过了一条,这条消息就没推出去。但这没关系:消息已经在数据库里了,浏览器会在补拉里拿到它。**推送通道可以不可靠,只要有序号和补拉兜底。** 对消息可靠性要求更高、或者量更大的系统,会把 Redis Pub/Sub 换成 Kafka、NATS 这类消息队列,思路是一样的。

"在线状态"也是同一个问题:客户在不在线,不能只看本机有没有他的连接。一般是每台机器把"谁连在我这里"写进 Redis 并设过期时间,心跳时续期,过期了就是离线。

### 每条连接都占资源

每条 WebSocket 连接在服务端至少占:一个文件描述符、读写缓冲区、一到两个 goroutine。

```
1 万连接:   默认配置就行
10 万连接:  调大 ulimit -n(进程能打开的文件描述符上限)和内核的连接相关参数
100 万连接: 每条连接几 KB 的开销乘以一百万,就要认真优化了
```

Go 的 `net` 包底层已经用 epoll 做了事件驱动,"一条连接一个 goroutine"的写法在几十万连接以内都很好用。到百万级时,每条连接两个 goroutine 的栈加上缓冲区开始显得重,这时才轮到 gnet、netpoll 这类事件循环框架。没到那个量级之前,标准写法就够了。

---

## 代码实现

Go 标准库没有 WebSocket(`golang.org/x/net/websocket` 已不推荐使用)。常用的是 `gorilla/websocket`,生态最成熟;`coder/websocket`(原 `nhooyr.io/websocket`)API 更现代,原生支持 context。下面服务端用 gorilla,浏览器端用原生的 `WebSocket`。

### 服务端:一个读者,一个写者

gorilla 的连接**不支持并发写**:两个 goroutine 同时调 `WriteMessage`,帧会交错写乱,甚至 panic。而聊天服务偏偏有好几个地方要往同一条连接写:转发聊天消息、推"正在输入"、定时发 Ping、下线时发 Close。

标准解法是每条连接配一个专门负责写的 goroutine,其他人要发消息,都通过 channel 交给它。"要通过通信来共享内存":

```go
type Client struct {
    conn *websocket.Conn
    send chan []byte // 要发给这个连接的消息都进这里,带缓冲
}

const (
    pingPeriod = 30 * time.Second
    pongWait   = 60 * time.Second // 必须比 pingPeriod 长
)

// 唯一的写者:聊天消息和心跳 Ping 都从这里发
func (c *Client) writePump() {
    ticker := time.NewTicker(pingPeriod)
    defer func() { ticker.Stop(); c.conn.Close() }()
    for {
        select {
        case msg, ok := <-c.send:
            c.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
            if !ok { // send 被关闭,说明该下线了
                c.conn.WriteMessage(websocket.CloseMessage, nil)
                return
            }
            if err := c.conn.WriteMessage(websocket.TextMessage, msg); err != nil {
                return
            }
        case <-ticker.C:
            c.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
            if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
                return
            }
        }
    }
}

// 唯一的读者:同时负责检查 Pong,也就是 6.3 节的"死亡计时器"
func (c *Client) readPump() {
    defer c.conn.Close()
    c.conn.SetReadLimit(64 << 10) // 单条消息上限 64KB,防止有人发超大帧撑爆内存
    c.conn.SetReadDeadline(time.Now().Add(pongWait))
    c.conn.SetPongHandler(func(string) error {
        c.conn.SetReadDeadline(time.Now().Add(pongWait)) // 收到 Pong,计时器重置
        return nil
    })
    for {
        _, data, err := c.conn.ReadMessage() // 超时、对端关闭都会从这里返回 err
        if err != nil {
            return
        }
        handle(c, data) // 发言、正在输入、已读、加入会话……
    }
}
```

往一个会话里广播的时候还有一个坑:某个客户网络很差,消费得慢,它的 `send` 缓冲满了。如果广播协程在这里阻塞等它,同一台机器上所有其他人都跟着收不到消息,一个慢客户端拖垮所有人。正确做法是满了就把它踢掉,让它自己重连、补拉:

```go
for c := range room.clients {
    select {
    case c.send <- msg:
    default: // 缓冲满了 = 这个客户端跟不上,断开它
        close(c.send)
        delete(room.clients, c)
    }
}
```

被踢掉的客户端不会丢消息,补拉会把它错过的都拿回来。这又是"推送可以不可靠,序号兜底"的一个好处:服务端可以放心地丢弃,而不用为了一个慢客户端拖住所有人。

### 浏览器端:重连循环

```javascript
let lastSeq = loadLastSeq();   // 本地记着收到的最后一条消息序号
let backoff = 1000;

function connect() {
  const ws = new WebSocket('wss://app.example.com/ws/chat');
  let heartbeat, deadTimer;

  ws.onopen = async () => {
    backoff = 1000;                                       // 连上了,退避时间复位
    ws.send(JSON.stringify({ type: 'join', conv: 88 }));  // ② 恢复连接上的状态
    const missed = await fetch(`/api/conversations/88/messages?after=${lastSeq}`)
                           .then(r => r.json());          // ③ 补拉断线期间的消息
    missed.forEach(render);

    heartbeat = setInterval(() => ws.send('{"type":"ping"}'), 25000);
  };

  ws.onmessage = e => {
    clearTimeout(deadTimer);                              // 收到任何东西都说明连接活着
    deadTimer = setTimeout(() => ws.close(), 60000);
    const msg = JSON.parse(e.data);
    if (msg.type === 'message' && msg.seq > lastSeq) {    // 按序号去重
      render(msg);
      lastSeq = msg.seq;
    }
  };

  ws.onclose = () => {
    clearInterval(heartbeat);
    clearTimeout(deadTimer);
    const jitter = Math.random() * backoff / 2;
    setTimeout(connect, backoff + jitter);                // ① 退避加抖动
    backoff = Math.min(backoff * 2, 30000);
  };
}
connect();
```

这段代码里,补拉和推送可能会把同一条消息各送来一次,`msg.seq > lastSeq` 这一个判断就把重复挡住了。

### 安全:CSWSH

前面服务端代码里省略了 `Upgrader` 的配置,其中 `CheckOrigin` 必须认真写:

```go
var upgrader = websocket.Upgrader{
    CheckOrigin: func(r *http.Request) bool {
        return r.Header.Get("Origin") == "https://app.example.com"
    },
}
```

原因是**跨站 WebSocket 劫持(CSWSH)**。浏览器里的 WebSocket 不受同源策略限制:一个客服在登录了后台的情况下,点开了一个恶意链接,这个页面可以直接 `new WebSocket("wss://app.example.com/ws/chat")`,浏览器会自动带上你网站的 Cookie(5.1 节握手里那个 `Cookie` 头)。如果服务端只靠 Cookie 认人,攻击者就以这个客服的身份建立了连接,能读到所有客户的对话,还能冒充客服发消息。

两道防线都要有:

1. 握手时严格校验 `Origin` 头,只接受自己的域名。恶意页面发起的连接,浏览器会如实带上恶意页面自己的 Origin,脚本改不了它。
2. 不要只靠 Cookie 认证。握手时校验一个短期 token(放在 URL 参数或子协议头里),或者要求连接建立后浏览器先发一条认证消息,通过了才推数据。
