# 用户视角功能对照清单（只读摸底）

更新时间：2026-10-23
参照端：Rebased 1.1.13（`io.github.detachhead.rebased`），源码基线
`/Users/arix/src/rebased/plugins/git4idea`
本端：Arbor（`Arbor/` SwiftUI + `arbor-engine/` Rust）

## 0. 为什么再做一次

`docs/git-parity-matrix.csv` 和 `docs/rebased-action-audit.md` 是**自下而上**的对账：
按 git4idea 注册的 action/group id 逐条核销。它证明"没有遗漏 action"，
但证明不了"用户看到的每个入口都在、都在它该在的位置"。差距来自三处：

1. **平台动作**（`Vcs.ShowHistoryForBlock` 这类由 platform 注册、被 Git 菜单引用的
   id）不在这套 id 统计里，因此从来没人核销过。
2. **装配关系**（`add-to-group` 的 anchor/relative-to）决定用户在哪一层菜单里点得到，
   id 存在 ≠ 入口可达。
3. **面板与工具窗**（Commit / Stage / Log / Saved Patches / Working Trees）不是 action，
   矩阵只记"哪个 controller 实现了它"，不记"用户在哪看见它"。

本文按用户实际浏览路径，从上到下走一遍。

## 1. 方法

参照端：解析
`backend/resources/intellij.vcs.git.backend.xml`、`shared/.../intellij.vcs.git.shared.xml`、
`frontend/.../intellij.vcs.git.frontend.xml`，把 `<action>` / `<group>` /
`<reference>` / `<add-to-group group-id anchor relative-to-action>` 还原成菜单树，
文案取自 `messages/GitBundle.properties`、`messages/GitFrontendBundle.properties`。

本端：Arbor 的 SwiftUI 菜单、`.contextMenu`、工具窗、对话框源码，加上
`Arbor/Localizable.xcstrings`（1598 个 key）做存在性校验。

判定口径：

| 记号 | 含义 |
| --- | --- |
| ✅ | 有，且用户能找到的位置等价 |
| 🟡 | 能力有，但入口位置、层级或形态不同（用户要多走一步或需要先知道） |
| ❌ | 用户视角缺失 |
| N/A | 依赖 IDE 宿主，原生应用没有对应物，不需复刻 |

## 2. 结论

- **功能点：0 项缺失。** 469 行矩阵里没有未决的功能性 `partial`；9 项
  `out-of-scope` 全部是调试动作、IDE 补全、插件平台或纯布局细节。
- **入口可达性：8 处结构差异**，其中 **3 处是用户会真的找不到东西**：
  History for Block、项目树上的 Ignore 动作、Log 分支面板的齿轮菜单。
- **平台动作是盲区：** 6 个被 Git 菜单引用但以 platform id 注册的动作从未被核销，
  其中 1 个（`Vcs.ShowHistoryForBlock`）确认缺失。
- 其余差异集中在 `docs/visual-baseline.md` 已记录的呈现层（C3–C9、L2–L8）。

## 3. 逐 surface 对照

### A. 主菜单 VCS > Git

参照端 `Git.MainMenu`（挂在 `VcsGroups` 的 `Vcs.MainMenu` 之后）共 16 组，含 4 个子菜单。

| 参照端 | Arbor | 判定 |
| --- | --- | --- |
| Commit… / Push… / Update Project | 同名 | ✅ |
| Pull… / Fetch / Unshallow repository | Pull… / Fetch / Fetch All / Prune Remote Branches / Fetch Full History…（浅克隆时出现） | ✅（Arbor 多 3 项 fetch 变体） |
| Merge… + `Merge ▸`（Commit merge / Abort Merge） | Merge… + 条件渲染的操作恢复项 | 🟡 无常驻子菜单 |
| Rebase… + `Rebase ▸`（Abort / Continue / Skip） | Rebase… + 条件渲染的 `Rebase in Progress ▸` | 🟡 无常驻子菜单 |
| Resolve Conflicts… / Revert Resolved | 同名 | ✅ |
| Branches… / New Branch… / New Tag… / Reset HEAD… | 同名（Branches 在文件中部而非这一组） | 🟡 分组顺序不同 |
| New Worktree… / Worktrees… | Worktrees…（含创建） | 🟡 合成一个入口 |
| Show Log | 藏在 `Tool Windows ▸` 里 | 🟡 多一层 |
| `File Actions ▸` | `File Actions ▸`（仅在有文件选区时出现） | ✅ |
| `Uncommitted Changes ▸` | `Local Changes ▸` | 🟡 命名不同 |
| Manage Remotes… / Clone… | Configure Remotes… / Clone Git Repository… | ✅ |
| VCS Quick List | `Quick Git Actions…`（放在 Git 子菜单内） | 🟡 层级不同 |
| Abort Revert / Continue Cherry-Pick / Abort Cherry-Pick | 条件渲染的操作恢复项 | ✅ |

结构性差异：Rebased 是 `VCS > Git`，Arbor 是 **`VCS > Git > Git`**（多一层），
且约 45 项平铺，只有 4 个二级子菜单。

### B. `Local Changes` 子菜单

| 参照端 | Arbor | 判定 |
| --- | --- | --- |
| Shelve changes… / Show Shelf / Stash Changes… / Unstash Changes… | Shelve… / Show Shelf / Stash… / Unstash… | ✅ |
| — | Show Stash（额外入口） | ✅ |
| Revert… | Revert Selected Changes… | ✅ |
| UML Diff | — | N/A（IDE 专属） |

### C. 项目树 / 文件右键

参照端 `Git.ContextMenu` = `FileActions` + Show Current Revision + Revert/Revert Files +
Resolve Conflicts + Revert Resolved。

| 参照端 | Arbor（`ProjectFileTreeView.swift`） | 判定 |
| --- | --- | --- |
| Checkin Files… / Add | 同名 | ✅ |
| Annotate | 同名 | ✅ |
| Compare with HEAD / Compare with Selected Revision… | 同名 | ✅ |
| Compare with Branch or Tag… | 同名（另有目录级的两个变体） | ✅ |
| Show File History | 同名 | ✅ |
| Show Current Revision | 同名 | ✅ |
| Revert / Revert Files | Revert | ✅ |
| Resolve Conflicts / Revert Resolved | 同名 | ✅ |
| **Show History for Selection…**（`Vcs.ShowHistoryForBlock`） | 代码视图行选择右键 `Show History for Selection…` | ✅（2026-10-23 补齐） |
| **`Ignore ▸`**（Add to .gitignore / Edit .gitignore / Add to .git/info/exclude） | **无**；只在 Changes 列表提供 `Ignore (add to .gitignore)` | ❌ |
| — | Copy Relative Path | 🟡 语义待验（矩阵记 verified-partial） |

### D. Changes 视图右键（含冲突）

| 参照端 | Arbor | 判定 |
| --- | --- | --- |
| Revert / Revert Files | Changes 列表 Revert | ✅ |
| Shelve / Ignore | Changes 列表有 `Ignore (add to .gitignore)`、Shelf 入口 | ✅ |
| `Git.ChangesView.Conflicts ▸`（Merge / Accept Theirs / Accept Yours） | 冲突工作台里逐块 `Accept Ours` / `Accept Theirs` / 外部 merge tool | 🟡 不在 Changes 列表就地解决 |
| Create Patch from Changes / to Clipboard | Create Patch（含 copy to clipboard 选项） | ✅ |
| Group By / Refresh | 同名 | ✅ |

### E. Commit 工具窗

参照端 CommitView：`Changes 2 files` + 全选勾选、`Unversioned Files 5 files` 折叠三态组、
`2 modified` 计数、齿轮（Commit All when Nothing Is Staged / Configure Local Changes）、
`Commit` + `Commit and Push…`。

Arbor Commit 工作页：Commit/Stash 双 tab、`● Default N` changelist 行、
`Ignored Files` 默认展开、Unstaged/Staged 两段、footer `Template`/`Skip hooks`/
`Commit`/`Commit and …`/`Commit and Rebase`。

判定：功能齐，呈现层 7 处差异全部已在 `docs/visual-baseline.md` 记录
（C3 标题、C4 ignored 默认展开、C5 untracked 未独立分组、C6 footer 按钮集、
C7 缺计数、C8 状态徽章、C9 无文件类型图标）。齿轮菜单里的
`Configure Local Changes` 因架构差异不存在（见 F）。

### F. Stage 工具窗

参照端有**独立的 Stage 工具窗**：View Options（Group By / Toggle Ignored）、
Stage All Tracked、Stash Silently、Diff/Refresh、树右键（Merge / Accept Theirs /
Accept Yours / Add / Add No Content / Reset / Stash Files / Revert / Delete / Ignore /
3-side diff / Create Patch / Show History）、Index 与 Local 两个文件级菜单
（Show Local/Staged Version、Compare with Staged/Local Version、Compare HEAD, Staged and Local）。

Arbor：**决策 5 明确不复刻**——固定 staged-only 模型，没有独立 Stage 工具窗。
这些动作分散在 Commit 工作页、项目树和 Diff 视图（`Show Local Version`、
`Show Staged Version`、`IndexToHead` / `WorktreeToIndex` / `ThreeVersionComparisonView`
都有实现）。

判定：🟡 有意的产品差异（已登记 out-of-scope：`Git.Stage.Enable` / `Git.Stage.Disable`）。
用户视角代价：必须开通 `Show Ignored` 才能看到被忽略的文件，且没有
"Commit All when nothing is staged" 之外的 staging 模式切换。

### G. Log 工具窗

| 参照端 | Arbor | 判定 |
| --- | --- | --- |
| 提交右键：Reset / Revert / Uncommit / Reword / Fixup / Squash Into / Drop / Squash Commits / Interactive Rebase / Push Up to Here / Add Commits to Remote Branch / New Branch / New Tag / Checkout & Browse | 全部有，另多 Revert Selected、Cherry-pick Selected、Compare with Current、Browse Repository at Revision、Open in Browser / Copy Link、Open Pull Requests、Comment this commit | ✅（Arbor 为超集） |
| 工具栏 `Not Cherry-Picked Commits` | `Highlight Cherry-Picked Commits` 菜单 | ✅ |
| Branches 面板**齿轮**：Update Branch Filter / Navigate Log to Branch Head / Group By Directory / Show Tags | `On selection` Picker（两选项）+ 分组开关 | 🟡 形态不同 |
| 分支多选、revision/range 输入 | 同名 | ✅ |
| Compare with Branch 双栏 | 有 | ✅ |
| Log 页签（Reflog / Console / Command / File History / Working Trees / Pull Requests） | 有（含外部 Log 窗口的页签持久化） | ✅ |
| Presentation Settings（显示列/高亮器） | 有 | ✅ |
| Author / Date 列 | 无（`L2`） | 🟡 待补 |

### H. Branches 弹窗 / VCS widget

| 参照端 | Arbor | 判定 |
| --- | --- | --- |
| 状态栏 VCS widget 打开分支弹窗 | 工具栏分支按钮 popover | 🟡 入口位置不同 |
| 分支树、checkout（含 Update / with Rebase / as New Branch）、compare、show diff、rebase、merge、update、push、pull with merge/rebase、rename、delete | 全部有 | ✅ |
| `Tracked Branch: X ▸` | 同名子菜单 | ✅ |
| `Push Tags ▸`（每 remote 一个 wrapper） | `Push All Tags` + 多 remote 展开 | ✅ |
| 弹窗齿轮：filter by action / filter by repository / group by directory / track recent / show tags / resize | `Show Actions in Search Results` / `Show Tags` / `Group by Directory` / `Show Recent Branches` | 🟡 少 `filter by repository`（仅 multi-root）与 resize（out-of-scope） |
| Find Merged… / Cleanup Branches… | 同名 | ✅ |

### I. Stash / Shelf（参照端是 Saved Patches 工具窗）

| 参照端 | Arbor | 判定 |
| --- | --- | --- |
| Pop / Apply / Unstash… / Drop / Clear | 全部有（`Clear All Stashes`） | ✅ |
| Unstash As（branch + Pop + restore staged） | 同名组合对话框 | ✅ |
| Preview Diff 开关（持久化） | 同名 | ✅ |
| Changes browser 右键 | 有 | ✅ |
| 独立工具窗 | 嵌在 Commit 工作页的 Stash / Shelf tab | 🟡 |

### J. Working Trees

参照端：`Show Working Trees` 工具窗（Open as a Project / Delete…）。
Arbor：Operations 工具窗的 `Worktrees` 模式（含 refresh / prune / 新建 / 占用分支校验）。

判定：🟡 同能力、不同容器（Arbor 的 Operations 一个工具窗承载
Tasks / Operation History / Git Console / Worktrees / Submodules / Git Roots）。

### K. 冲突

| 参照端 | Arbor | 判定 |
| --- | --- | --- |
| Resolve Conflicts 对话框（三栏 merge） | 冲突工作台（三方视图 + 逐块决策） | ✅ |
| Changes 列表就地 Accept Yours / Accept Theirs | 冲突工作台内逐块 | 🟡 |
| 编辑器内 `MergeConflictResolveUtil` 提示 | 文件预览里的冲突条 | ✅ |
| 外部 merge tool | `Run Git's configured external merge tool` | ✅ |
| 冲突后 Continue / Skip / Abort 通知 | 操作恢复项 + 通知 | ✅ |

### L. Hosting

| 参照端 | Arbor | 判定 |
| --- | --- | --- |
| `Open in Browser ▸` / `Copy Link ▸`（0 / 1 / 多 remote 三种 presentation） | 同名，含按 remote 展开 | ✅ |
| Pull Requests（Log 里 Open PR、Comment this commit） | 同名 + Hosting 面板 `Pull Requests & Reviews` | ✅ |
| Share Project On（GitHub/GitLab） | 无 | N/A（IDE 项目分享，不是 Git 操作） |

### M. 设置

参照端：`VCS > Git`（`GitVcsPanel` 一个页面，内含 VCS 映射 / 路径 / 更新方法 /
合并工具 / GPG / SSH）+ `generalVcsSettingsExtension`（Log commit editing）+
`Configure GPG Agent`。

Arbor：15 个设置源文件（Branch / Commit / Display / Executable / IncomingChanges /
LocalChanges / MergeTool / OperationDialog / ProjectSettingsKey / Push / SSH / Signing /
Update / ProjectGitIncomingChanges / Diagnostics），分散在设置窗口多个面板。

判定：✅ 覆盖面足够，🟡 组织方式不同（IntelliJ 单页 vs Arbor 多面板），
用户需要多翻一层才能找到项目级覆盖。

### N. 通知 / 状态栏 / 操作恢复

| 参照端 | Arbor | 判定 |
| --- | --- | --- |
| `VcsNotifier` 通知 + 状态栏 | `FeedbackCenter` + 原生 UNUserNotificationCenter + Operation Log | ✅ |
| 顶部 `GitMergeRebaseWidget`（冲突/合并/变基恢复条） | 条件渲染的操作恢复菜单 + 状态栏 | 🟡 无独立顶部条 |
| 状态栏分支部件（ahead/behind） | 有 | ✅ |
| 多 root 逐 root 结果树 | Operation Log 详情按 root 展示 | ✅ |

## 4. 平台动作：从未被核销的盲区

这些 id 由 platform 注册、被 Git 菜单引用，因此不进 `rebased-action-audit.py` 的统计，
`git-parity-matrix.csv` 里也没有对应行。

| 平台动作 id | 文案 | 引用位置 | Arbor |
| --- | --- | --- | --- |
| `Vcs.ShowHistoryForBlock` | Show History for Selection… | `Git.FileActions` | ✅ `block_history` + 行选择右键 |
| `$Delete` | Delete | `Git.Stage.Tree.Menu` | ✅ 变更列表 / 项目树右键 `Delete…` |
| `ChangesView.CreatePatchFromChanges` | Create Patch… | `Git.Stage.Tree.Menu` | ✅ Create Patch |
| `ChangesView.CreatePatchToClipboard` | Create Patch to Clipboard | 同上 | ✅ 选项内 |
| `EditSource` | Jump to Source | `Git.Stage.Tree.Menu` | N/A（无编辑器） |
| `Vcs.UmlDiff` | UML Diff | `Git.MainMenu.LocalChanges` | N/A（IDE 专属） |
| `CopyFileReference` / `CopyPathFromRepositoryRootProvider` | Path From Repository Root | `CopyFileReference` | 🟡 语义待验 |

2026-10-23 起这张表由 `scripts/audit-user-surface.py` 自动核销：`declared` 与
`platform` 两类动作必须在 `scripts/user-surface-baseline.txt` 里逐条给出结论，
否则脚本退出 1。

## 5. Arbor 独有（参照端没有）

- VCS > Git 里：Search Everywhere、Quick Git Actions、Git Roots、Operation Log、
  Git Console、Git LFS、Git Hooks、Apply Patch from Clipboard。
- Log 右键：Revert Selected Commits、Cherry-pick Selected Commits、
  Reset Selected Revisions、Browse Repository at Revision、Rewrite Selected Commit as
  Fixup/Squash。
- 项目树：`Compare Directory with Branch or Tag…`、`Compare Directory with Selected Revision…`。
- 独立 `VCS > Git > Tool Windows` 分组与可分离的外部 Log 窗口。
- `Language…` 菜单项（en / zh-Hans 切换）。

## 6. 明确不复刻

`docs/git-parity-matrix.csv` 的 9 项 `out-of-scope`：
`TestGitHttpLoginDialogAction`（调试）、`Git.Stage.Enable/Disable`（决策 5）、
`git.branches.popup.resize`、`Git.Log.Hide.Branches`（布局细节）、
`git.commit.completion.fixup.squash`（用户明确不做 IDE 补全）、
`Git.Compare.With.Branch.Popup.Settings`（布局）、`Git.Log.Internal`（internal）、
`Vcs.Show.Shelf.RemoteActions`（需要 IntelliJ remote backend / 插件平台）。

再加上本清单新识别的一类：**IDE 宿主能力**——PSI/VFS、编辑器内嵌 diff、
行号 gutter blame、Local History、UML Diff、Share Project。这些不是 Git 功能，
是 IDE 提供的宿主裁决，原生应用要么自建要么不做。

## 7. 后续动作

1. ~~**Show History for Selection…**~~ 已补齐（2026-10-23）：引擎 `block_history`（`git log -L`）
   + 代码视图行选择右键 `Show History for Selection…`。
2. **项目树右键的 Ignore 子菜单** — 现在用户必须先切到 Changes 列表才能忽略文件，
   而 Rebased 在文件树上就能做。
3. **Log 分支面板齿轮** — 把 `On selection` Picker 换成齿轮菜单，与 Rebased 的
   `Branches Pane Settings` 对齐；同时补 `filter by repository`。
4. ~~**`$Delete`**~~ 已补齐（2026-10-23）：变更列表与项目树右键的 `Delete…`
   → 确认后按 owning Git root 删除，不跑 `git rm`。
5. 呈现层（C4/C5/C8/C9/L2）另列，不在本次只读摸底范围内。

审计方法已固化：`python3 scripts/audit-user-surface.py`；CI 用
`--snapshot scripts/user-surface.json` 复核台账。
