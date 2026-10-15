---
title: "GitHub：被我当成网盘用了很多年的开发平台"
date: 2026-10-15T18:07:51+08:00
draft: false
tags: ["github", "ci/cd", "工具"]
categories: []
summary: "用了 GitHub 很多年，才发现自己只用了它的十分之一：代码托管之外，它还能自动测试、自动构建、自动部署、自动发版、自动修依赖、拦截泄露的密钥，甚至直接在浏览器里写代码。"
---

## Summary

GitHub 我用了很多年，可回头一想，我对它的用法基本就三个动作：`git push`、看看别人的代码、点个 Star。说白了，是把它当成一个**带网页的 Git 网盘**在用。

直到写了博客配了自动部署，才意识到问题：我 push 一下 Markdown，几十秒后网站就自己更新了。中间谁帮我装的 Hugo？谁帮我构建的？又是谁把文件传到服务器上的？顺着这个问题往下挖，才发现 GitHub 早就不只是"放代码的地方"，而是一整套**开发平台**：写代码、审代码、测代码、构建、发布、部署、安全检查，几乎每一环它都能接手。

这篇就把这些我"用了很多年却不知道"的东西捋一遍。重点放在 **GitHub Actions**（CI/CD 的核心），其他功能讲清楚是什么、能解决什么问题，最后附一些很实用的冷门技巧。

---

## GitHub 是什么

先打个比方。如果 Git 是一个**保险柜**，能帮你保存每一次修改的历史，那么 GitHub 一开始只是一个**放保险柜的银行**：保险柜放在云上，大家都能来取。

但这些年，这家银行在保险柜周围盖了一整栋楼：

```
                         ┌──────────────── GitHub ────────────────┐
                         │                                         │
   写代码                 │  Codespaces / github.dev / Copilot      │  ← 开发环境
     │                   │                                         │
     ▼                   │                                         │
   提交 ── git push ───▶  │  Repository（Git 托管，最初的那个保险柜）   │  ← 存储
     │                   │                                         │
     ▼                   │                                         │
   协作讨论               │  Issues / Pull Request / Projects       │  ← 协作
     │                   │                                         │
     ▼                   │                                         │
   自动化                 │  Actions（测试、构建、部署、定时任务）       │  ← 流水线
     │                   │                                         │
     ▼                   │                                         │
   分发                   │  Releases / Packages(ghcr.io) / Pages   │  ← 交付
     │                   │                                         │
     ▼                   │                                         │
   安全                   │  Dependabot / Secret scanning / CodeQL  │  ← 安保
                         └─────────────────────────────────────────┘
```

从上到下，基本就是一行代码从"写出来"到"上线跑起来"的完整路径。以前我只用了中间那一格 Repository，后面也一格一格讲。

---

## 协作

### PR 本质上是一个"代码讨论帖"

Pull Request（简称 PR，GitLab 里叫 Merge Request）的字面意思是"请把我的分支拉进去"。但它真正的价值不在最后那个合并按钮，而在合并之前的**讨论**：

- **逐行评论**：可以针对某一行甚至某几行留言，而不是笼统地说"这里有问题"。
- **Suggested changes（建议修改）**：评论时点一下 ± 图标，直接写出改后的代码。作者看到后点 "Commit suggestion" 就能一键采纳，不用自己再改一遍。
- **Draft PR（草稿 PR）**：代码还没写完，但想先让别人看看方向，就开成草稿。草稿状态下不能合并，也不会自动通知 reviewer。
- **三种合并方式**：
  - Merge commit：保留分支上的所有提交，再加一个合并节点；
  - Squash and merge：把分支上的十几个"fix typo"压成一个提交，主干历史最干净；
  - Rebase and merge：把提交逐个接到主干末尾，历史是一条直线。

### 用关键字把 Issue 和 PR 串起来

在 PR 描述或提交信息里写上 `Fixes #12`（也可以用 `Closes`、`Resolves`），PR 合并进默认分支时，**12 号 Issue 会自动关闭**，两者还会互相显示链接。这个功能很小，但项目一大，"这个 bug 是哪次改动修好的"就全靠它来追溯。

### 给主干加一道门：分支保护

只有一个人用的仓库，往 main 上直接 push 没什么问题。但只要是多人协作，或者 main 一更新就会自动部署（后面讲 CD 时就是这样），就需要给 main 加门禁。在 **Settings → Rules（Rulesets）** 或旧版的 **Branch protection** 里可以设置：

- 禁止直接 push，必须走 PR；
- 必须有 N 个人 approve 才能合并；
- **必须等 CI 检查通过才能合并**（这一条和 Actions 配合，是 CI 的真正意义所在）；
- 禁止 force push，禁止删除分支。

配合仓库里的 `CODEOWNERS` 文件，还能实现"改了 `deploy/` 目录下的文件，就必须让运维同学 review"这样的规则：

```
# .github/CODEOWNERS
/deploy/      @ops-team
*.go          @lbtsm
```

### Issues 之外的项目管理

- **Projects**：看板 / 表格 / 路线图视图，把 Issue 和 PR 拖进去管理状态，相当于一个轻量版的 Jira。
- **Discussions**：论坛式的讨论区。适合放"怎么用"一类的问题，把 Issues 留给真正的 bug 和需求。
- **Issue 模板**：在 `.github/ISSUE_TEMPLATE/` 下放模板，别人提 bug 时就会被引导着填写版本、复现步骤等信息。

---

## 重头戏：GitHub Actions

### 先说 CI/CD 解决什么问题

先想象一下没有自动化时，一次上线要做哪些事：

```
本地写完代码 → 自己跑测试（经常忘） → 自己编译 → scp 传到服务器
            → ssh 上去 → 停掉旧进程 → 起新进程 → 看日志确认没挂
```

每一步都靠人手，每一步都可能出错：忘了跑测试、编译时环境不一样、传错文件、重启漏了一台机器。

**CI（Continuous Integration，持续集成）**说白了就是：**每次有人提交代码，机器都自动帮你检查一遍**，包括编译能不能过、测试能不能过、代码风格对不对。问题在合并之前就会暴露出来，不用等到上线。

**CD（Continuous Delivery / Deployment，持续交付 / 持续部署）**是更进一步：**检查通过后，机器自动把代码构建成产物，并部署到服务器上**。

GitHub Actions 就是 GitHub 内置的这套"自动化机器人"：仓库里放一个 YAML 文件，描述"发生什么事的时候，做哪些事"，GitHub 就会分配一台临时的虚拟机，按你的描述去执行。

### 五个概念，一张图

Actions 的概念不多，可以类比成一家工厂：

```
事件（on）        →  触发开工的信号：有人 push、开 PR、打 tag、定时到点、手动点按钮
Workflow（工作流） →  一份完整的生产计划，放在 .github/workflows/xxx.yml
Job（作业）        →  一条生产线；默认多条线并行，也可以用 needs 规定先后顺序
Runner（运行器）   →  执行生产线的那台机器（GitHub 提供的临时虚拟机，或你自己的服务器）
Step（步骤）       →  生产线上的一道道工序：要么跑一条 shell 命令（run），要么用别人封装好的模块（uses）
```

最后一个 `uses` 引用的东西也叫 **Action**，就是别人封装好的可复用步骤，比如"检出代码""安装 Go""登录 Docker 仓库"。它们来自 **GitHub Marketplace**，数量有好几万，绝大多数常见需求都有现成的，这也是 Actions 比自己搭 Jenkins 省事的主要原因。

### 拆解一个真实例子

最好的例子就是github可以让你自己构建一个博客网站，例如 [lbtsm.github.io](https://github.com/lbtsm/lbtsm.github.io)。这个博客的仓库里有一个 `.github/workflows/deploy.yml`，下面把它拆开逐段讲解：

```yaml
name: Deploy Hugo site to Pages

on:
  push:
    branches: ["master"]   # 事件 1：有代码 push 到 master, 现在基本都是main了
  workflow_dispatch:       # 事件 2：在网页上手动点 "Run workflow"
```

`on` 定义了**什么时候开工**。这里是两种情况：push 到 master 时，或者在 Actions 页面手动触发。

```yaml
permissions:
  contents: read
  pages: write
  id-token: write
```

`permissions` 定义**这次运行能拿到哪些权限**。每次运行时，GitHub 都会自动发一个临时令牌 `GITHUB_TOKEN`，这里的意思是：允许它读代码、写 Pages、申请一个身份凭证（`id-token`，后面讲 OIDC 时会再遇到它）。原则是给最小权限，用不到的不给。

```yaml
concurrency:
  group: "pages"
  cancel-in-progress: false
```

`concurrency` 用来**防止两次部署打架**。如果连续 push 两次，第二次部署会排队，等第一次跑完再执行。

```yaml
jobs:
  build:
    runs-on: ubuntu-latest          # 要一台 GitHub 提供的 Ubuntu 虚拟机
    env:
      HUGO_VERSION: 0.164.0
    steps:
      - name: Install Hugo CLI       # 工序 1：自己下载安装 Hugo（run = 跑 shell）
        run: |
          wget -O ${{ runner.temp }}/hugo.deb \
            https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/hugo_extended_${HUGO_VERSION}_linux-amd64.deb
          sudo dpkg -i ${{ runner.temp }}/hugo.deb

      - name: Checkout (含主题子模块)  # 工序 2：把仓库代码拉到虚拟机上（uses = 用现成 Action）
        uses: actions/checkout@v4
        with:
          submodules: recursive

      - name: 运行构建产物校验          # 工序 3：构建并跑测试，失败就到此为止，不会部署
        run: bash tests/build_test.sh

      - name: Upload artifact        # 工序 4：把构建出的 public/ 目录打包，交给下一条生产线
        uses: actions/upload-pages-artifact@v3
        with:
          path: ./public

  deploy:
    needs: build                     # 等 build 成功之后才开始
    runs-on: ubuntu-latest
    environment:
      name: github-pages
    steps:
      - name: Deploy to GitHub Pages
        uses: actions/deploy-pages@v4
```

（省略了 Node 和 Pages 初始化两个步骤，不影响理解。）

整个流程串起来是这样的：

```
git push master
      │
      ▼
 GitHub 收到事件，开一台全新的 Ubuntu 虚拟机
      │
      ▼
 ┌── job: build ─────────────────────────────────┐
 │ 装 Hugo → 拉代码 → 构建 + 测试 → 打包 public/     │
 └───────────────────────┬───────────────────────┘
                         │ 成功（needs: build）
                         ▼
 ┌── job: deploy ────────────────────────────────┐
 │ 把产物发布到 GitHub Pages                        │
 └───────────────────────────────────────────────┘
      │
      ▼
 虚拟机销毁，blog.lbtsm.site 更新完成
```

这里有个关键点：**每次运行用的都是一台全新的、干净的虚拟机**，跑完就销毁。所以它不会有"我本地能跑，换台机器就不行"的问题，环境里有什么，完全由 YAML 文件决定。这也是 CI 最核心的价值之一：**构建环境本身被写进了代码里**。

### CI：给 Go 项目加一个"每次提 PR 自动测试"

理解了结构，写一个 CI 就很简单了。下面是一个 Go 项目最常见的配置：

```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [main]
  pull_request:              # 每次有人开 PR 或往 PR 里推新提交，都会触发

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        go: ["1.24", "1.25"] # 矩阵：同时在两个 Go 版本上各跑一遍
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: ${{ matrix.go }}   # setup-go 会自动缓存依赖，第二次跑会快很多
      - run: go vet ./...
      - run: go test -race ./...
```

`matrix`（矩阵）是个很好用的功能：写一份配置，就能展开成多个并行的 job。比如 `go × os` 写成 `2 × 3`，就会同时跑 6 个组合。

配好之后，PR 页面底部会出现一个 ✅ 或 ❌。再结合上面讲的分支保护，开启"必须等 CI 通过才能合并"，**测试不过的代码就根本进不了 main**。这才是 CI 完整的闭环。

### CD：push 之后自动部署到自己的服务器

博客部署到的是 GitHub Pages，属于 GitHub 自家的服务。如果要部署到自己的云服务器，最直接的思路是：**让 Actions 的虚拟机扮演你，ssh 上去执行部署命令**。

```yaml
# .github/workflows/deploy.yml
name: Deploy

on:
  push:
    tags: ["v*"]                 # 打 v1.2.3 这种 tag 时才部署，日常 push 不会触发

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production      # 关联 production 环境（可以配置审批，见下文）
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: "1.25"
      - run: CGO_ENABLED=0 GOOS=linux go build -o app ./cmd/app

      - name: 上传并重启
        env:
          SSH_KEY: ${{ secrets.DEPLOY_SSH_KEY }}   # 私钥从 Secrets 读取，不写在代码里
          HOST: ${{ secrets.DEPLOY_HOST }}
        run: |
          mkdir -p ~/.ssh
          echo "$SSH_KEY" > ~/.ssh/id_ed25519 && chmod 600 ~/.ssh/id_ed25519
          ssh-keyscan -H "$HOST" >> ~/.ssh/known_hosts
          scp app deploy@$HOST:/opt/app/app.new
          ssh deploy@$HOST 'cd /opt/app && mv app.new app && systemctl restart app'
```

这里出现了两个新东西：

**Secrets（机密）**：在 **Settings → Secrets and variables → Actions** 里添加。添加后值就看不到了，只能覆盖；在日志里打印出来时，也会被自动替换成 `***`。私钥、密码、API Token 这类东西都应该放在这里，**绝对不要写进 YAML 文件或代码里**。

**Environment（环境）**：可以创建 `staging`、`production` 等环境，每个环境有自己的一套 Secrets，还可以设置**保护规则**，比如"部署到 production 之前必须由某人在网页上点批准"，或者"只允许 main 分支部署到这个环境"。这样就相当于在自动部署链路上加了一道人工闸门。

部署链路也不止 ssh 这一种。常见的还有：构建 Docker 镜像推到仓库，服务器再拉取；或者部署到 Kubernetes、云函数。但思路都一样：**拿到凭证 → 把产物送过去 → 让它生效**。

### 发版：打个 tag，自动编译出全平台二进制

开源 Go 项目的 Releases 页面里，常常有 `linux-amd64`、`darwin-arm64`、`windows-amd64.exe` 一大堆文件。这些基本都不是作者手动编译上传的，而是像下面这样配好之后，**打一个 tag 就全自动生成**：

```yaml
on:
  push:
    tags: ["v*"]

permissions:
  contents: write              # 需要写权限才能创建 Release

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0       # goreleaser 需要完整的 git 历史来生成 changelog
      - uses: actions/setup-go@v5
      - uses: goreleaser/goreleaser-action@v6
        with:
          args: release --clean
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

[GoReleaser](https://goreleaser.com) 会交叉编译出各平台的二进制文件，打包、计算校验和，根据提交记录生成 changelog，再一起上传到 Releases 页面。你要做的只有一句 `git tag v1.0.0 && git push --tags`。

### 其他几种触发方式

`on:` 后面能写的远不止 push 和 PR，Actions 也不只是用来做 CI/CD 的：

| 触发方式 | 写法 | 典型用途 |
|---|---|---|
| 定时任务 | `schedule: - cron: "0 1 * * *"` | 每天跑一次爬虫、生成日报、检查证书是否快过期 |
| 手动按钮 | `workflow_dispatch` | 网页上点按钮触发，还可以定义输入框（比如选择部署到哪个环境） |
| Issue / 评论 | `issues`、`issue_comment` | 新 Issue 自动打标签，评论里写 `/deploy` 就触发部署 |
| 发布 Release | `release` | 发版后自动推送通知 |
| 被其他工作流调用 | `workflow_call` | 抽出公共流程，多个仓库复用 |

定时任务有两个要注意的地方：**cron 用的是 UTC 时间**，北京时间早上 9 点要写成 `0 1 * * *`；另外，**公开仓库如果 60 天没有任何提交，定时任务会被自动停用**。

很多人用"定时任务 + 免费虚拟机"这个组合做各种小工具，比如每天抓取热榜推送到微信、自动签到、定期备份某个 API 的数据。说白了，它就是一台**每次只能活几分钟（单个 job 最长 6 小时）的免费服务器**。

### 免费额度和自托管 Runner

- **公开仓库**：使用 GitHub 提供的标准 Runner 基本免费。
- **私有仓库**：免费账号每月有一定的分钟额度（Free 计划长期是 2000 分钟/月左右），超出部分按分钟计费。macOS 虚拟机的计费倍率比 Linux 高得多。具体数字经常调整，以官方 Billing 页面为准。

如果你有自己的服务器，还可以把它注册成 **Self-hosted runner（自托管运行器）**：在服务器上运行 GitHub 提供的 agent 程序，然后在 workflow 里写 `runs-on: self-hosted`，任务就会在你自己的机器上执行。适合这几种场景：

- 需要 GPU 或特殊硬件；
- 构建很重，想用自己的大机器；
- 部署目标在内网，从外面 ssh 不进去，干脆让内网机器自己来拉取任务执行。

自托管 Runner 是机器**主动连接** GitHub 来领任务的，所以不需要开放任何入站端口，这一点对内网环境很友好。但要注意：**不要在公开仓库上使用自托管 Runner**。任何人 fork 你的仓库后提一个 PR，就有可能让你的机器执行他写的代码。

### 拓展

**第一个：用 OIDC 代替长期密钥。** 上面提到把 ssh 私钥放进 Secrets，这种做法能用，但这把密钥是长期有效的，一旦泄露就很麻烦。更现代的做法是 **OIDC**：workflow 运行时向 GitHub 申请一张"身份证明"（一个 JWT），上面写着"我是 xxx/xxx 仓库 main 分支上的一次运行"；AWS、GCP、阿里云等云厂商验证这张证明后，**临时**发放几分钟有效的访问凭证。整个过程不存在任何长期密钥，也就没有东西可泄露。前面博客部署配置里的 `id-token: write`，就是在允许 workflow 申请这张身份证明，`deploy-pages` 背后用的正是这个机制。

**第二个：第三方 Action 是供应链风险。** `uses: 某人/某action@v1` 本质上是在你的流水线里**运行别人的代码**，而且 `v1` 这样的 tag 是可以被重新指向的。2025 年 3 月就发生过一次真实事件：一个被大量项目使用的 Action（`tj-actions/changed-files`）被攻击者篡改，tag 被指向了恶意代码，导致大批仓库的 Secrets 被打印到公开日志里。防范办法是：

- 官方的 `actions/*` 可以按版本 tag 引用；
- 第三方 Action **固定到完整的 commit SHA**，比如 `uses: foo/bar@3f1c9a...`（完整的 40 位哈希），再配合 Dependabot 自动提 PR 来更新版本；
- `permissions` 只给最小权限。

### 本地调试：act

每改一次 YAML 就 push 一次、等虚拟机跑完才看结果，效率很低。[nektos/act](https://github.com/nektos/act) 可以用 Docker 在本地模拟运行 workflow：

```bash
brew install act
act -l            # 列出所有 job
act pull_request  # 模拟一次 PR 事件
```

它不能百分之百还原 GitHub 的环境，但大多数语法错误和脚本问题在本地就能发现。

---

## 交付：Releases、Packages、Pages

代码构建好之后，要有地方存放和分发。GitHub 提供了三种：

**Releases（发布）**：基于 git tag，给某个版本附上说明文字和二进制文件。就是上面提到的 GoReleaser 上传文件的地方。

**Packages / GHCR**：GitHub 自带的制品仓库，支持 npm、Maven、NuGet 等，最常用的是 **Docker 镜像仓库 `ghcr.io`**。在 workflow 里用 `GITHUB_TOKEN` 就能登录推送，不用另外申请 Docker Hub 账号：

```yaml
permissions:
  packages: write
steps:
  - uses: docker/login-action@v3
    with:
      registry: ghcr.io
      username: ${{ github.actor }}
      password: ${{ secrets.GITHUB_TOKEN }}
  - uses: docker/build-push-action@v6
    with:
      push: true
      tags: ghcr.io/lbtsm/app:latest
```

服务器上 `docker pull ghcr.io/lbtsm/app:latest` 就能用。公开镜像拉取不需要登录。

**Pages（静态网站托管）**：免费托管静态网站，也支持绑定自定义域名并自动配置 HTTPS。博客就托管在 Pages 上。它只能托管静态文件（HTML/CSS/JS），没有后端；但配合 Hugo、VitePress、Docusaurus 这类生成器，用来做博客、项目文档、个人主页已经足够了。还有一个小彩蛋：如果仓库名是 `用户名.github.io`，它就是你的个人主页，地址就是 `https://用户名.github.io`。

---

## 安全：GitHub 会默默帮你盯着的东西

### Dependabot：依赖的"体检医生"

你的项目依赖了几十上百个第三方库，其中某个库爆出漏洞时，你不一定知道。Dependabot 做两件事：

- **安全告警（alerts）**：对比你的 `go.mod`、`package.json` 和公开的漏洞数据库，发现命中就提醒你，能自动修复时还会直接提一个升级 PR。
- **版本更新（version updates）**：定期检查依赖有没有新版本，有的话自动提 PR。配合 CI，测试通过后点一下合并就完成了升级。

配置也很简单，在仓库里放一个 `.github/dependabot.yml`：

```yaml
version: 2
updates:
  - package-ecosystem: "gomod"
    directory: "/"
    schedule:
      interval: "weekly"
  - package-ecosystem: "github-actions"   # 连 workflow 里引用的 Action 版本也能管
    directory: "/"
    schedule:
      interval: "weekly"
```

### Secret scanning：拦截泄露的密钥

把私钥、云厂商的 AccessKey、数据库密码误提交到仓库，是最常见、后果也最严重的事故之一。而且**提交之后再删除是没用的**：git 历史里还在，fork 和镜像里也还在，网上有大量爬虫专门扫描 GitHub 上新出现的密钥，泄露后几分钟内就可能被利用。

GitHub 的 Secret scanning 能识别上百种服务商的密钥格式，其中 **Push protection（推送保护）**这个功能会在 `git push` 时直接**拒绝**含有密钥的提交，并告诉你是哪个文件、哪一行。公开仓库默认已经开启了这个功能，私有仓库可以在 **Settings → Code security** 里查看。它相当于最后一道防线，但不能代替好习惯：**提交之前一定要看一眼 `git status` 和 `git diff --cached`**，确认没有把本地的配置文件、密钥文件加进去。这个配置是很实用的，建议打开，因为之前我就是没注意，提交了自己的一个私钥，结果账号就泄漏了。

真的泄露了怎么办？正确的顺序是：**先去对应平台作废并更换这把密钥**，然后再考虑清理 git 历史。清理历史只能避免以后再被看到，挡不住已经发生的泄露。

### Code scanning（CodeQL）

CodeQL 会对代码做静态分析，找出 SQL 注入、路径穿越、不安全的反序列化等问题，结果显示在 PR 和 Security 页面里。它本身也是用 Actions 运行的，在 **Security → Code scanning** 里一键就能启用默认配置。公开仓库免费使用。

### 账号本身的安全

- **2FA（两步验证）**：现在 GitHub 已经要求代码贡献者必须开启。
- **Fine-grained token（细粒度令牌）**：代替以前的 classic token，可以限定"只能访问某一个仓库的某几种权限"，并设置过期时间。
- **Deploy key**：只绑定在单个仓库上的 SSH 公钥，适合让服务器只读拉取某一个仓库，而不是把你个人账号的 SSH key 放到服务器上。
- **签名提交**：用 SSH 或 GPG 密钥给 commit 签名后，提交记录旁会显示绿色的 **Verified** 标记，证明这条提交确实是你本人提交的（git 的作者名和邮箱是可以随便填的，签名不行）。

---

## 开发环境：不用本地也能写代码

**github.dev**：在任何仓库页面**按一下键盘上的 `.` 键**，就会在浏览器里打开一个网页版 VS Code。它能浏览、搜索和编辑整个仓库，改完直接提交。没有终端，不能运行代码，但用来快速改个文档、读读源码非常方便。把网址里的 `github.com` 改成 `github.dev` 效果也一样。

**Codespaces**：真正的云端开发机。点 **Code → Codespaces → Create** 就会启动一台带终端的云端虚拟机，在浏览器或本地 VS Code 里连接使用，可以编译、运行、调试。仓库里如果放了 `.devcontainer/devcontainer.json`，所有人打开的都是同一套预装好依赖的环境，**新人入职"配环境配一天"的问题就解决了**。个人账号每月有一定免费额度，用完计费，记得不用时关掉。

**Copilot**：AI 编程助手，除了在编辑器里补全代码，还能在网页上解释代码、帮你 review PR；它的 coding agent 还可以**直接把一个 Issue 指派给它**，它会自己写代码、自己跑 Actions 测试，最后提一个 PR 给你审核。

---

## 一堆"早知道就好了"的小技巧

**网页快捷键**（在仓库页面按 `?` 可以看到完整列表）：

| 按键 | 作用 |
|---|---|
| `.` | 用 github.dev 打开当前仓库 |
| `t` | 文件模糊搜索，比一层层点目录快得多 |
| `y` | 把当前文件的 URL 换成带 commit 哈希的永久链接（分支更新后链接也不会失效） |
| `/` 或 `s` | 聚焦到搜索框 |
| `b` | 在文件页面打开 blame，看每一行是谁在什么时候改的 |

**URL 技巧**：

- 在文件链接末尾加 `#L10-L20`，可以直接高亮第 10 到 20 行，适合发给同事说"看这几行"。
- 在 PR 或 commit 的链接末尾加 `.patch` 或 `.diff`，就能得到纯文本的补丁，可以直接 `curl ... | git apply`。
- **`https://github.com/用户名.keys`** 会返回这个用户上传到 GitHub 的所有 SSH 公钥。给新服务器配置登录时，`curl https://github.com/你的用户名.keys >> ~/.ssh/authorized_keys` 一条命令就够了，Ubuntu 的 `ssh-import-id gh:用户名` 用的也是这个接口。把 `.keys` 换成 `.gpg` 可以拿到 GPG 公钥。
- 比较两个分支或 tag：`https://github.com/owner/repo/compare/v1.0.0...v1.1.0`。

**gh 命令行**：GitHub 官方 CLI，让你几乎不用离开终端：

```bash
brew install gh && gh auth login
gh repo clone owner/repo
gh pr list / gh pr checkout 123 / gh pr view --web
gh issue create
gh run list / gh run watch        # 在终端里实时看 Actions 跑到哪一步了
gh run view --log-failed          # 只看失败步骤的日志，排查 CI 很好用
gh release create v1.0.0 ./dist/*
```

**其他冷知识**：

- 新建一个和用户名**同名的仓库**，里面的 README 会显示在你的个人主页顶部，很多人用它做个人简介。
- **Gist** 是轻量版的仓库，适合分享一段代码或一个配置文件。每个 Gist 本身也是一个 git 仓库，可以 clone。
- **代码搜索**支持很多语法，比如 `repo:golang/go language:go "func Marshal"`、`path:*.yml "self-hosted"`，搜索开源项目的写法很方便。
- **Template repository（模板仓库）**：把一个仓库标记成模板后，别人可以一键生成一个结构完全相同、但历史独立的新仓库，适合做项目脚手架。
- http://github.com/trending 目前流行的repo

---

## 结语

回头看，我用了这么多年的 GitHub，其实一直站在一栋大楼的门口，以为它只是个存放代码的柜台。真正的变化在于思路：**以前是人记住流程、人去执行；现在是把流程写成代码，交给机器去执行**。测试会不会忘跑、部署有没有漏掉一台机器、密钥会不会被误提交，这些原本要靠"人细心"的事，都可以变成"机器每次都检查"的事。
