# Webthree 首页展示设计

## 目标

让 `content/webthree/` 下的普通页面与 `posts`、`datastruct` 页面一样显示在博客首页，同时保留独立的 `/webthree/` section 列表页。

## 当前问题

PaperMod 首页只展示 `params.mainSections` 指定的内容类型。当前配置仅包含 `posts` 和 `datastruct`，因此 Hugo 虽然识别了 `/webthree/lifi/` 页面，但首页列表会过滤掉它。

`content/webthree/` 还缺少 `_index.md`，没有像 `datastruct` 一样显式定义 section 元数据和级联分类。

## 设计

1. 将 `webthree` 加入 `hugo.toml` 的 `params.mainSections`。
2. 新建 `content/webthree/_index.md`，显式建立 Web3 section。
3. 在 `_index.md` 中通过 `cascade` 为子页面设置 `Web3` 标签和分类，保持与 `datastruct` 的组织方式一致。
4. 不修改 PaperMod 主题模板，继续使用现有首页过滤机制。

首页的数据流为：

```text
content/webthree/*/index.md
        -> Hugo 识别为 type=webthree
        -> params.mainSections 包含 webthree
        -> PaperMod 首页和归档列表展示页面
```

## 行为

- `/webthree/lifi/` 文章继续使用现有 URL。
- `/webthree/` 展示 Web3 section 的文章列表。
- Web3 文章出现在博客首页和归档页。
- `posts` 与 `datastruct` 的现有展示行为不变。

## 验证

构建测试需要断言：

- Hugo 构建成功。
- 首页 HTML 包含 `/webthree/lifi/` 链接。
- `/webthree/index.html` 存在并包含 `/webthree/lifi/` 链接。
- 现有测试继续通过。

## 非目标

- 不增加新的导航菜单项。
- 不修改 PaperMod 主题文件。
- 不调整 `lifi` 正文内容或 URL。
