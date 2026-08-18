# Webthree Home List Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show pages from `content/webthree/` on the blog home page while preserving the `/webthree/` section page.

**Architecture:** Keep PaperMod's existing `mainSections` filtering and register `webthree` as another main section. Define the section explicitly with `_index.md`, and extend the existing shell build test so future configuration changes cannot silently remove Web3 pages from the home page.

**Tech Stack:** Hugo 0.164, PaperMod, TOML configuration, YAML front matter, Bash build assertions

**Execution Note:** The user explicitly requested direct implementation without a TDD red phase. The final build regression checks remain required.

---

### Task 1: Add Regression Coverage for Webthree

**Files:**
- Modify: `tests/build_test.sh:14-15`
- Modify: `tests/build_test.sh:115-121`

- [ ] **Step 1: Register `webthree` in the tested content sections**

Change the section array to:

```bash
SECTIONS=(posts datastruct webthree)
```

- [ ] **Step 2: Add home-page and section-page assertions**

Append these assertions after the existing Uniswap home-page assertion:

```bash
if [ -f "$PUBLIC/index.html" ] && grep -q "/webthree/lifi/" "$PUBLIC/index.html"; then
  ok "首页包含 Web3 文章链接 (/webthree/lifi/)"
else
  bad "首页未渲染 Web3 文章链接 (/webthree/lifi/)"
fi

if [ -f "$PUBLIC/webthree/index.html" ] && grep -q "/webthree/lifi/" "$PUBLIC/webthree/index.html"; then
  ok "Web3 section 包含文章链接 (/webthree/lifi/)"
else
  bad "Web3 section 缺少文章链接 (/webthree/lifi/)"
fi
```

- [ ] **Step 3: Defer test execution until the section is registered**

Do not run a standalone failing-test phase. Continue to Task 2, then run the full build regression test after the implementation is present.

### Task 2: Register the Webthree Section

**Files:**
- Modify: `hugo.toml:57`
- Create: `content/webthree/_index.md`

- [ ] **Step 1: Add `webthree` to the home-page section filter**

Change the configuration to:

```toml
mainSections = ["posts", "datastruct", "webthree"]
```

- [ ] **Step 2: Create the Webthree section entry**

Create `content/webthree/_index.md` with:

```yaml
---
title: ""
cascade:
  tags: ["Web3"]
  categories: ["Web3"]
---
```

- [ ] **Step 3: Run the focused build regression test**

Run:

```bash
bash tests/build_test.sh
```

Expected: exit status 0; output includes `首页包含 Web3 文章链接 (/webthree/lifi/)` and `Web3 section 包含文章链接 (/webthree/lifi/)`.

- [ ] **Step 4: Inspect Hugo's page model**

Run:

```bash
hugo list all
```

Expected: output includes both `content/webthree/_index.md` with kind `section` and `content/webthree/lifi/index.md` with kind `page`.

- [ ] **Step 5: Check the final diff**

Run:

```bash
git diff --check
git diff -- hugo.toml tests/build_test.sh content/webthree/_index.md
```

Expected: no whitespace errors; no PaperMod theme files or unrelated files are modified.

### Task 3: Commit the Implementation

**Files:**
- Stage: `hugo.toml`
- Stage: `tests/build_test.sh`
- Stage: `content/webthree/_index.md`
- Stage: `content/webthree/lifi/index.md`
- Stage: `docs/superpowers/plans/2026-08-18-webthree-home-list.md`

- [ ] **Step 1: Stage only Webthree implementation files**

```bash
git add hugo.toml tests/build_test.sh content/webthree docs/superpowers/plans/2026-08-18-webthree-home-list.md
```

- [ ] **Step 2: Verify the staged file list**

Run:

```bash
git diff --cached --name-only
```

Expected files:

```text
content/webthree/_index.md
content/webthree/lifi/index.md
docs/superpowers/plans/2026-08-18-webthree-home-list.md
hugo.toml
tests/build_test.sh
```

- [ ] **Step 3: Commit**

```bash
git commit -m "feat: list webthree articles on homepage"
```

- [ ] **Step 4: Confirm the worktree state**

Run:

```bash
git status --short
```

Expected: no remaining changes from this implementation. Any unrelated pre-existing changes remain untouched and are reported separately.
