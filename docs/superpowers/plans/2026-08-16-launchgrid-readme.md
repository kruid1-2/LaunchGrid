# LaunchGrid README Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a truthful Chinese README to the GitHub repository homepage and keep the existing feature branch synchronized with it.

**Architecture:** The repository-root `README.md` is the only user-facing deliverable. It documents the project in the same practical style as iPhone Inspector, using current source code and verified commands as evidence. The README commit lands on `main` so GitHub renders it immediately; `main` is then merged back into the existing feature branch.

**Tech Stack:** Markdown, Git, GitHub CLI, Xcode 26.2, Swift, SwiftUI, AppKit

## Global Constraints

- Chinese is the primary language; retain English API names, commands, and shortcuts.
- Do not add badges, releases, download links, license claims, or screenshots that do not exist.
- Do not describe ad-hoc signing as notarized distribution.
- State the current deployment-target mismatch: Xcode project `13.0`, `Package.swift` `26.0`, product target macOS 26.
- Do not stage backups, build outputs, icon candidates, or unrelated projects.

---

### Task 1: Publish the Repository README on `main`

**Files:**
- Create: `README.md`
- Reference: `docs/superpowers/specs/2026-08-16-launchgrid-readme-design.md`
- Reference: `LaunchGrid/LaunchGrid.xcodeproj/project.pbxproj`
- Reference: `LaunchGrid/script/build_and_run.sh`

**Interfaces:**
- Consumes: the current LaunchGrid source tree and the verified build entrypoint `LaunchGrid/script/build_and_run.sh`
- Produces: a repository-root README rendered by GitHub on the default branch

- [ ] **Step 1: Switch to the default branch without touching unrelated untracked files**

Run:

```bash
git status -sb
git switch main
```

Expected: branch becomes `main`; unrelated untracked directories remain untouched.

- [ ] **Step 2: Write the README with the approved structure**

Create `README.md` containing these exact factual sections:

- `# LaunchGrid` and a Chinese description of the classic Launchpad-style macOS launcher.
- `## 已实现功能`: local application scanning, icons and names, search, launch, horizontal paging, current-mouse display placement, hide/reopen behavior.
- `## 操作方式`: click, trackpad/horizontal scroll, `Command-F`, `Return`, and two-stage `Escape` behavior.
- `## 构建要求`: macOS 26 product target, Xcode 26 with macOS 26 SDK, Intel and Apple Silicon; disclose the Xcode `13.0` versus SwiftPM `26.0` mismatch.
- `## 构建与运行`: `cd LaunchGrid`, `./script/build_and_run.sh`, and `./script/build_and_run.sh --verify`.
- `## 项目结构`: SwiftUI UI, AppKit window/input, application scanner/launcher, icon cache, paging surface.
- `## 本地运行与隐私`: no account, server, network upload, `sudo`, or system-file modification.
- `## 当前验证`: Xcode 26.2, macOS 26.5.1, Intel host, universal Debug/Release builds, verified launch; GUI smoothness remains manual.
- `## 已知限制`: no notarized release, reordering/folders/global hotkey/login item not implemented, deployment mismatch unresolved.

- [ ] **Step 3: Validate README paths, commands, and Markdown whitespace**

Run:

```bash
test -f README.md
test -f LaunchGrid/LaunchGrid.xcodeproj/project.pbxproj
test -x LaunchGrid/script/build_and_run.sh
rg -n '^## ' README.md
git diff --check -- README.md
```

Expected: all commands exit `0`; README contains all eight required second-level headings.

- [ ] **Step 4: Run the documented build and launch verification**

Run:

```bash
cd LaunchGrid
./script/build_and_run.sh --verify
```

Expected: `xcodebuild` exits `0`, reports `BUILD SUCCEEDED`, bundle signing verification succeeds, and the process check exits `0`.

- [ ] **Step 5: Commit only the README and push `main`**

Run:

```bash
git add -- README.md
git diff --cached --check
git diff --cached --name-status
git commit -m "docs: add LaunchGrid project guide"
git push origin main
```

Expected: the staged file list contains only `README.md`; `main` push succeeds without force.

### Task 2: Synchronize and Verify the Existing Feature Branch

**Files:**
- Merge: `main` into `codex/paging-idle-prewarm-scheduler`
- Verify: GitHub repository `kruid1-2/LaunchGrid`
- Verify: draft PR `kruid1-2/LaunchGrid#1`

**Interfaces:**
- Consumes: the README commit now present on `origin/main`
- Produces: a feature branch containing the same README and a GitHub homepage that renders it

- [ ] **Step 1: Merge `main` into the feature branch and push**

Run:

```bash
git switch codex/paging-idle-prewarm-scheduler
git merge --no-edit main
git push origin codex/paging-idle-prewarm-scheduler
```

Expected: merge succeeds without conflict; push succeeds without force.

- [ ] **Step 2: Verify GitHub renders the README and branch SHAs match**

Run:

```bash
gh api 'repos/kruid1-2/LaunchGrid/readme?ref=main' --jq '.path'
gh api 'repos/kruid1-2/LaunchGrid/contents/README.md?ref=main' --jq '.sha'
gh pr view 1 --repo kruid1-2/LaunchGrid --json state,isDraft,headRefName,headRefOid,url
git ls-remote --heads origin main codex/paging-idle-prewarm-scheduler
git status -sb
```

Expected: GitHub returns `README.md`; PR #1 remains open/draft; local and remote feature-branch SHAs match; only pre-existing unrelated untracked files remain.
