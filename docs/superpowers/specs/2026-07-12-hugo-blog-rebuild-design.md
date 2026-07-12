# 博客重建设计文档 — Hugo + GitHub Actions 自动部署

日期: 2026-07-12
仓库: `git@github.com:lbtsm/lbtsm.github.io.git` (GitHub Pages 用户站)
域名: `blog.lbtsm.site`

## 1. 目标

把博客重建为「**只写 markdown → push 到 GitHub → 自动构建部署**」的工作流,
使用成熟静态站点框架,配套 TDD 风格的构建产物校验。

作者日常只需在 `content/posts/` 下写 md 文件,push 后由 CI 自动上线,
本地无需手动构建(如需预览可选装 Hugo)。

## 2. 关键决策(已与用户确认)

| 决策项 | 选择 | 理由 |
|--------|------|------|
| 框架 | **Hugo** | 原博客即 Hugo,迁移最顺;构建极快,主题生态成熟 |
| 主题 | **PaperMod** (git submodule) | 最流行的 Hugo 博客主题,简洁快速,自带深浅色/搜索/标签 |
| 部署 | **GitHub Actions → Pages** | 仓库只存源码,CI 构建并部署,契合「只写 md」目标 |
| 旧内容 | **不迁移,全新开始** | 原始 md 已丢失,仅剩 HTML 成品;用新内容验证流程 |
| TDD 范围 | **构建 + 产物校验** | 静态站点的「测试」落点在构建产物断言 |
| 域名 | 保留 `blog.lbtsm.site` | 通过 `static/CNAME` 保留现有自定义域名 |

## 3. 架构与部署流程

```
作者写 md (content/posts/*.md)
      │  git push 到 master
      ▼
GitHub Actions (.github/workflows/deploy.yml)
      │  1. checkout (submodules: recursive)
      │  2. 安装 Hugo (extended)
      │  3. 运行 tests/build_test.sh  ← 测试不过则失败,不部署
      │  4. hugo --minify (已包含在测试脚本中)
      ▼
public/ 静态产物 → 上传为 Pages artifact → actions/deploy-pages 上线
      ▼
https://blog.lbtsm.site  (CNAME 由 static/CNAME 提供)
```

Pages 源在仓库设置里设为 **"GitHub Actions"**(非分支服务)。

## 4. 目录结构(master 分支)

```
lbtsm.github.io/
├── hugo.toml                  # 主配置: baseURL/title/theme/menu/params
├── content/
│   ├── posts/
│   │   ├── uniswap.md         # 迁移用户手头 docs/uniswap.md 作首篇
│   │   └── hello-world.md     # 示例文章, 演示 front matter 与格式
│   └── about.md               # 关于页
├── static/
│   └── CNAME                  # 内容: blog.lbtsm.site
├── themes/PaperMod/           # git submodule
├── archetypes/default.md      # `hugo new` 的 front matter 模板
├── .github/workflows/deploy.yml
├── tests/
│   └── build_test.sh          # TDD 构建产物断言
└── docs/superpowers/specs/    # 本设计文档
```

旧的 HTML/css/js/dist/favicon 等生成物目录清除。
(如需保留 favicon 等资源,可挑出放入 `static/`,当前默认清除。)

## 5. 配置要点 (hugo.toml)

- `baseURL = "https://blog.lbtsm.site/"`
- `title`、`languageCode`(如 `zh-cn`)、`theme = "PaperMod"`
- 菜单: 首页 / 文章归档 / 标签 / 关于
- PaperMod params: 深浅色切换、代码高亮、文章 ToC、首页模式
- 开启 RSS (`index.xml`) 与 sitemap(Hugo 默认输出)

## 6. TDD 测试计划

`tests/build_test.sh` — 一组针对构建产物的断言。
**流程: 先写断言并确认全部失败(红),再逐步搭建配置让断言通过(绿)。**

断言清单:
1. `hugo --minify` 退出码为 0(构建成功)
2. 生成 `public/index.html`(首页存在)
3. 每篇文章生成对应页面(如 `public/posts/uniswap/index.html`)
4. 生成 `public/index.xml`(RSS)与 `public/sitemap.xml`
5. `public/CNAME` 存在且内容严格等于 `blog.lbtsm.site`
6. 文章 front matter 合法: 含 `title`、`date`,且 `date` 可解析
7. 首页 HTML 中能检索到文章标题(渲染链路连通)

脚本以非零退出码表示失败,可本地运行,也在 CI 部署前执行——
测试不过则 workflow 失败、不上线。

## 7. 本地环境

- 运行测试/本地预览需安装 Hugo extended: `brew install hugo`
- 本地预览: `hugo server -D`
- 日常写作: 只需新增/编辑 `content/posts/*.md` 并 push;不装 Hugo 也可由 CI 构建

## 8. 非目标 (YAGNI)

- 不做评论系统、不接统计分析(后续需要再加)
- 不迁移旧文章、不做死链/图片引用检查(当前 TDD 范围外)
- 不做多语言站点

## 9. 交付后验收

- push 一次 md 改动,GitHub Actions 绿灯,`https://blog.lbtsm.site` 显示新内容
- `tests/build_test.sh` 本地与 CI 均通过
- 新增文章仅需在 `content/posts/` 加一个 md 文件
