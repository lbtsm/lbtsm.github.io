# HBS Theme Migration Implementation Plan

> **For Codex:** Execute this plan directly in the current worktree. The user explicitly requested implementation without a TDD red/green cycle and approved working on `master`.

**Goal:** Replace PaperMod with the official Hugo Bootstrap Theme v1.13.3 and reproduce its default purple, responsive blog layout while preserving the site's existing content, URLs, and navigation.

**Architecture:** Keep Hugo page bundles and existing sections (`posts`, `datastruct`, `webthree`) unchanged. Install HBS as a pinned Git submodule, add its required npm asset pipeline, translate PaperMod configuration/front matter to HBS conventions, then validate the generated site and inspect it in desktop/mobile browsers.

**Tech Stack:** Hugo Extended 0.164.0, Hugo Bootstrap Theme v1.13.3, Bootstrap 5, Node.js 22, npm, GitHub Actions.

---

## Task 1: Replace the Theme Dependency

**Files:**
- Modify: `.gitmodules`
- Remove: `themes/PaperMod`
- Add: `themes/hugo-theme-bootstrap`
- Modify: `.gitignore`

1. Remove the PaperMod submodule from the working tree and index.
2. Add `https://github.com/razonyang/hugo-theme-bootstrap.git` at `themes/hugo-theme-bootstrap`.
3. Check out the exact `v1.13.3` release commit.
4. Ignore the local `.superpowers/` visual-design scratch directory.
5. Verify `.gitmodules` and the pinned submodule commit.

## Task 2: Configure HBS and Its Asset Pipeline

**Files:**
- Modify: `hugo.toml`
- Generate: `package.hugo.json`
- Add: `package.json`
- Add: `package-lock.json`

1. Replace PaperMod-only parameters with HBS configuration.
2. Preserve the current base URL, Chinese language, pagination, taxonomies, menus, unsafe Markdown HTML, and main content sections.
3. Enable the official purple palette, automatic light/dark mode, search bar, carousel, sidebar widgets, table of contents, article navigation, image viewer, and code line numbers.
4. Leave PWA, comments, rewards, analytics, DocSearch, and repository integration disabled.
5. Run `hugo mod npm pack` to generate the theme dependency manifest.
6. Add a minimal root `package.json`, install dependencies, and commit the resulting lockfile for reproducible local and CI builds.

## Task 3: Translate Existing Article Images

**Files:**
- Modify: `content/posts/https/index.md`
- Modify: `content/posts/uniswap/index.md`
- Modify: `content/datastruct/array/index.md`
- Modify: `content/datastruct/list/index.md`
- Modify: `content/datastruct/stack/index.md`
- Modify: `content/datastruct/hashtable/index.md`

1. Remove each PaperMod `cover.image` block and rename its page-bundle resource to HBS's native `*feature*` pattern.
2. Add `carousel = true` to image-backed articles so the official homepage carousel is populated.
3. Preserve all existing titles, dates, tags, categories, body content, page bundles, and user edits.

## Task 4: Update CI and Build Checks

**Files:**
- Modify: `.github/workflows/deploy.yml`
- Modify: `tests/build_test.sh`
- Remove: `assets/css/extended/side-toc.css`

1. Add Node.js 22 setup and `npm ci` before the Hugo build check.
2. Rename TDD wording in the workflow and shell script to neutral build-verification wording.
3. Keep the existing assertions for posts, section pages, RSS, sitemap, CNAME, URLs, and front matter.
4. Add HBS-specific checks for the generated Bootstrap assets, navigation/search entry, carousel, and article images.
5. Remove the PaperMod-only TOC stylesheet.

## Task 5: Build and Visual Verification

**Files:**
- Verify generated `public/` output only; do not commit it.

1. Run `npm ci`.
2. Run `bash tests/build_test.sh` and fix any HBS integration errors.
3. Run `hugo server --bind 127.0.0.1` on an available port.
4. Inspect the homepage and representative article pages at desktop and mobile widths.
5. Verify purple HBS styling, automatic color-mode control, navigation, search, carousel images, cards, sidebar, responsive layout, and absence of broken/overlapping content.
6. Leave the development server running and report its local URL.
