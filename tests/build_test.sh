#!/usr/bin/env bash
# 构建产物校验 (TDD)
# 先构建站点, 再对 public/ 产物逐条断言。任一断言失败即以非零码退出。
# 用法: bash tests/build_test.sh
set -uo pipefail

# 切到仓库根目录(脚本位于 tests/ 下)
cd "$(dirname "$0")/.." || exit 2

PASS=0
FAIL=0
DOMAIN="blog.lbtsm.site"
PUBLIC="public"

ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

echo "== 1. hugo --minify 构建 =="
if command -v hugo >/dev/null 2>&1; then
  rm -rf "$PUBLIC"
  if hugo --minify --gc >/tmp/hugo_build.log 2>&1; then
    ok "hugo 构建成功 (退出码 0)"
  else
    bad "hugo 构建失败, 见 /tmp/hugo_build.log"
    tail -20 /tmp/hugo_build.log
  fi
else
  bad "未安装 hugo, 无法构建 (brew install hugo)"
fi

echo "== 2. 首页存在 =="
[ -f "$PUBLIC/index.html" ] && ok "public/index.html 存在" || bad "缺少 public/index.html"

echo "== 3. 文章页生成 =="
# 动态发现文章: 支持平铺 md (posts/foo.md) 与页面束 (posts/foo/index.md)
shopt -s nullglob
slugs=()
for md in content/posts/*.md; do
  # _index.md 是 section 索引页, 不是文章
  [ "$(basename "$md")" = "_index.md" ] && continue
  slugs+=("$(basename "$md" .md)")
done
for md in content/posts/*/index.md; do
  slugs+=("$(basename "$(dirname "$md")")")
done
if [ ${#slugs[@]} -eq 0 ]; then
  bad "content/posts 下没有发现任何文章"
fi
for slug in "${slugs[@]}"; do
  # 草稿不会生成页面, 跳过 draft: true 的文章
  src="content/posts/$slug.md"; [ -f "$src" ] || src="content/posts/$slug/index.md"
  if awk 'NR==1&&/^---/{f=1;next} /^---/{exit} f' "$src" | grep -qE '^draft:[[:space:]]*true'; then
    continue
  fi
  if [ -f "$PUBLIC/posts/$slug/index.html" ]; then
    ok "文章页 posts/$slug/ 存在"
  else
    bad "缺少文章页 posts/$slug/index.html"
  fi
done

echo "== 4. RSS 与 sitemap =="
[ -f "$PUBLIC/index.xml" ]   && ok "RSS public/index.xml 存在"   || bad "缺少 public/index.xml"
[ -f "$PUBLIC/sitemap.xml" ] && ok "sitemap public/sitemap.xml 存在" || bad "缺少 public/sitemap.xml"

echo "== 5. CNAME 自定义域名 =="
if [ -f "$PUBLIC/CNAME" ]; then
  content="$(tr -d '[:space:]' < "$PUBLIC/CNAME")"
  [ "$content" = "$DOMAIN" ] && ok "CNAME 内容 == $DOMAIN" || bad "CNAME 内容为 '$content', 期望 '$DOMAIN'"
else
  bad "缺少 public/CNAME"
fi

echo "== 6. 文章 front matter 合法 =="
# 每篇文章 md 必须含 title 和可解析的 date
posts=(content/posts/*.md content/posts/*/index.md)
if [ ${#posts[@]} -eq 0 ]; then
  bad "content/posts 下没有任何文章"
fi
for md in "${posts[@]}"; do
  [ "$(basename "$md")" = "_index.md" ] && continue
  fm="$(awk 'NR==1&&/^---/{f=1;next} /^---/{exit} f' "$md")"
  title="$(printf '%s\n' "$fm" | grep -E '^title:' | head -1)"
  date="$(printf '%s\n' "$fm" | grep -E '^date:'  | head -1 | sed -E 's/^date:[[:space:]]*//; s/^["'\'']//; s/["'\'']$//')"
  base="$(basename "$md")"
  [ -n "$title" ] && ok "$base 含 title" || bad "$base 缺少 title"
  if [ -n "$date" ] && date -j -f "%Y-%m-%d" "${date:0:10}" >/dev/null 2>&1; then
    ok "$base date 可解析 ($date)"
  elif [ -n "$date" ] && date -d "$date" >/dev/null 2>&1; then
    ok "$base date 可解析 ($date)"
  else
    bad "$base date 缺失或无法解析 ('$date')"
  fi
done

echo "== 7. 无重复 URL: 平铺 md 与同名 bundle 不得并存 =="
for d in content/posts/*/; do
  slug="$(basename "$d")"
  if [ -f "content/posts/$slug.md" ] && [ -f "content/posts/$slug/index.md" ]; then
    bad "posts/$slug.md 与 posts/$slug/index.md 并存, 会争抢同一 URL"
  else
    ok "posts/$slug 无平铺/bundle 冲突"
  fi
done

echo "== 8. 首页渲染出文章标题 =="
# uniswap 文章标题应出现在首页 HTML 中, 证明渲染链路连通
if [ -f "$PUBLIC/index.html" ] && grep -q "Uniswap" "$PUBLIC/index.html"; then
  ok "首页包含文章标题 (Uniswap)"
else
  bad "首页未渲染出文章标题 (Uniswap)"
fi

echo ""
echo "==========================="
echo "通过: $PASS  失败: $FAIL"
echo "==========================="
[ "$FAIL" -eq 0 ]
