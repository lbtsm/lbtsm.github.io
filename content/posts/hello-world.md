---
title: "Hello World - 博客上线"
date: 2026-07-12
draft: false
tags: ["公告"]
categories: ["杂记"]
summary: "新博客基于 Hugo + PaperMod 搭建,只写 Markdown、push 即自动部署。"
---

新博客上线了 🎉

这个博客基于 [Hugo](https://gohugo.io/) + [PaperMod](https://github.com/adityatelange/hugo-PaperMod) 主题搭建,
托管在 GitHub Pages,通过 GitHub Actions 自动构建部署。

## 我怎么写文章

只需在 `content/posts/` 下新建一个 markdown 文件,带上 front matter:

```markdown
---
title: "文章标题"
date: 2026-07-12
tags: ["标签"]
---

正文内容……
```

然后 `git push`,GitHub Actions 会自动构建并发布到 <https://blog.lbtsm.site>。

## 代码高亮示例

```go
package main

import "fmt"

func main() {
    fmt.Println("Hello, blog!")
}
```

就这么简单。
