# HBS 主题迁移设计

## 目标

将博客从 PaperMod 迁移到官方 Hugo Theme Bootstrap（HBS）v1.13.3，并采用官方演示站的默认博客视觉：Bootstrap 顶部导航、自动深浅色模式、紫色强调色、封面轮播、文章卡片、分类标签侧栏和移动端响应式布局。

迁移保留现有文章、URL、标签、分类、导航和 GitHub Pages 域名，不复制 PaperMod 的首页横幅或模板。

## 主题依赖

站点继续使用现有的 Git 子模块管理方式：

- 移除 `themes/PaperMod` 子模块。
- 添加 `themes/hugo-theme-bootstrap` 子模块。
- 将主题固定在 `v1.13.3`，避免部署时随 `master` 变化。
- 更新 `.gitmodules` 和 `hugo.toml` 中的主题名称。

虽然 HBS 官方更推荐 Hugo Module，但当前仓库和 GitHub Actions 已完整支持递归子模块。沿用子模块能减少仓库结构和部署方式的变化。

## 资源构建

HBS 使用 Hugo Pipes、Bootstrap、PostCSS 和 npm 依赖。迁移将：

- 由 `hugo mod npm pack` 生成站点级 `package.json`。
- 提交 `package.hugo.json`、`package.json` 和锁文件，使本地与 CI 使用相同依赖。
- 在 GitHub Actions 中设置 Node.js，并在 Hugo 构建前运行 `npm ci`。
- 继续使用 Hugo Extended 0.164.0；该版本满足 HBS v1.13.x 的版本要求。

## 站点配置

保留以下现有行为：

- `baseURL`、中文语言、CJK 字数统计和分页大小。
- `posts`、`datastruct`、`webthree` 三个主内容 section。
- 文章、标签、归档、搜索、关于导航。
- RSS、sitemap、CNAME 和代码高亮。

PaperMod 专属参数将替换为 HBS 参数：

- `color = "auto"`，默认跟随系统深浅色。
- 使用紫色 HBS palette，与官方主题截图一致。
- 开启首页封面轮播、搜索栏、阅读时间、面包屑和文章目录。
- 开启分类、标签、归档、近期文章侧栏组件。
- 开启代码复制、行号和折叠辅助功能。
- 禁用当前未配置的评论、打赏和社交分享模块。

PaperMod 的 `homeInfoParams`、Fuse 搜索参数、JSON 首页输出和 `assets/css/extended/side-toc.css` 不再使用。

## 内容兼容

所有内容目录和永久链接保持不变：

```text
/posts/*
/datastruct/*
/webthree/*
/about/
/archives/
/search/
```

页面束图片继续保留在各文章目录内。现有 PaperMod `cover.image` 将改为 HBS 原生识别的 `featured.png` 页面资源，确保轮播、文章缩略图、社交元数据和正文封面使用同一资源，并保留 Hugo 图片裁剪优化。

`archives.md` 和 `search.md` 将调整为 HBS 对应布局，但 URL 不变。文章正文中的 Markdown、代码块、表格、GIF 和内嵌 HTML 不改写，除非实际构建揭示明确的不兼容。

## 首页与文章页

首页采用 HBS 原生博客结构：

1. 顶部 Bootstrap 导航和搜索入口。
2. 最新带图文章组成封面轮播。
3. 主栏按时间展示文章卡片。
4. 侧栏展示分类、标签、归档和近期文章。
5. 小屏幕自动折叠导航与侧栏，文章列表变为单列。

文章页采用 HBS 原生标题、元信息、封面、侧边目录、代码工具栏、上一篇/下一篇和相关文章组件，不保留 PaperMod 模板覆盖。

## 构建与验证

本次按用户要求不采用 TDD 红灯阶段，但完成后必须进行以下验证：

- `npm ci` 成功。
- `hugo --minify --gc` 成功。
- 现有构建测试通过，并按 HBS 生成结构调整必要断言。
- 首页仍包含 `posts`、`datastruct`、`webthree` 文章链接。
- `/archives/`、`/search/`、`/about/` 和各文章 URL 正常生成。
- 页面束封面在首页、section 列表和文章页可见。
- 浏览器检查桌面与移动端的深色、浅色模式，无重叠、溢出或空白资源。

## 变更保护

- 不回退或重写当前未提交的文章标题修改。
- 不把 `.superpowers/` 视觉草图目录加入版本控制，并将其加入 `.gitignore`。
- 不推送远程仓库，除非用户另行要求。

## 非目标

- 不复刻 Hugo Themes 展示页左侧的主题介绍文字和统计表。
- 不引入自定义首页模板来模拟 PaperMod。
- 不启用 PWA、评论、打赏、DocSearch 或第三方分析。
- 不修改文章正文内容。
