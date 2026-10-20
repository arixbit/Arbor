# Rebased Git action 覆盖审计

更新时间：2026-10-20

## 结论

用 `scripts/audit-git-actions.py` 对账 `intellij-community/plugins/git4idea`
注册的全部 action/group id：

| 指标 | 数量 |
|---|---|
| git4idea 注册的 id 总数 | 174 |
| `docs/git-parity-matrix.csv` 已提及 | 143 |
| 未提及 | 31 |
| 未提及中的**叶子动作**（真正的功能入口） | **0** |
| 未提及中的分组容器（菜单/工具栏/齿轮/锚点） | 31 |

也就是说：**没有遗漏的 Git 功能入口**。剩下 31 个全部是 IntelliJ 用来装配
菜单和工具栏的容器 id，本身不承载功能；它们引用的子动作要么已有独立 id 且
被矩阵覆盖，要么是 IDE 平台动作（不在 Git 功能范围内）。

> 与之前口头提到的「28 个」的口径差异：早先的扫描只统计 `Git*` 前缀，
> 漏掉了 4 个 `git.*` 小写设置项和 IDE 平台 id（`MainToolbarQuickActions.VCS`、
> `Vcs.ToolbarWidget.ShareProject`、`Vcs.ToolbarWidget.CreateRepository.LocalHistory`、
> `git.branches.popup.filter.by.separator`），本次是全量口径。

复跑：

```sh
python3 scripts/audit-git-actions.py            # 人读
python3 scripts/audit-git-actions.py --json     # 机器读
```

## 31 个未覆盖 id 逐个说明

### 1. 分支弹窗的装配分组

| id | 内容 | Arbor 现状 |
|---|---|---|
| `Git.Branch.Backend` | 分支弹窗 backend 侧分组：ref 比较、tracked、push tags、rename、new worktree | 子动作全部已覆盖 |
| `Git.Branch.Backend.Checkout` | 空锚点，仅用于排序 | 无功能 |
| `Git.Branch.Checkout` | 只含 `Git.Checkout.Update`（已覆盖） | 已覆盖 |
| `Git.Branch.Placeholder` | 空锚点 | 无功能 |
| `Git.Branch.Tracked` | tracked 分支子菜单（类 `GitTrackedBranchActionGroup`） | Arbor 的 `Tracked Branch: X` 子菜单对应 |
| `Git.Experimental.Branch.Popup.Actions` | 实验性分组，引用 UpdateProject / CheckinProject / Commit.Stage / Vcs.Push | 全部已覆盖 |

### 2. 设置 / 齿轮菜单

| id | 内容 | Arbor 现状 |
|---|---|---|
| `Git.Branches.Popup.Settings` | 弹窗齿轮：filter by action/repository、group by directory、track repos synchronously、show recent、show tags、resize | 6 个里 5 个有（见下方「小差异」） |
| `git.branches.popup.filter.by.separator` | 该菜单里的「带文字分隔符」，纯视觉 | 不需要 |
| `Git.Log.Branches.Settings` | Log 分支面板齿轮：on-selection 行为、GroupBy.Directory、show tags | Arbor 的 `On selection` picker + 分组开关对应 |
| `Git.Log.Branches.Grouping.Settings` | 分组子菜单（GroupBy.Repository） | 已覆盖 |
| `Git.Stage.Ui.Settings` | Stage 工具窗齿轮：GroupBy、ToggleIgnored | 已覆盖（`Show Ignored` + 分组） |
| `Git.Stage.Configure` | Stage 工具窗齿轮：Enable / Disable（关掉整个 Stage 工具窗） | 架构性差异：Arbor 的暂存视图常驻 |
| `Git.Branches.Popup.SpeedSearch` | 只是把 `EditorCut` / `EditorPaste` 挂进 speed search 上下文 | IDE 平台动作 |

### 3. 工具栏 / 上下文菜单（内容全是已覆盖动作）

| id | 内容 | Arbor 现状 |
|---|---|---|
| `Git.Log.Toolbar` | Log 工具栏，只含 cherry-pick 高亮开关 | 已覆盖 |
| `Git.LogContextMenu` | 文件历史右键菜单 | 已覆盖 |
| `Git.MainMenu.FileActions` | `VCS > Git > File Actions` 子菜单，包 `Git.FileActions` | 已覆盖 |
| `Git.Stage.Index.File.Menu` | 编辑器右键：Show Local / Compare Staged↔Head / Staged↔Local / 三版本 | 已覆盖 |
| `Git.Stage.Local.File.Menu` | `Git.ContextMenu` 子菜单：Show Staged / Compare / 三版本 | 已覆盖 |
| `Git.Stage.Toolbar` | Stage 工具栏：Diff / Refresh / Add Tracked / Stash Silently / GroupBy / ToggleIgnored | 已覆盖 |
| `Git.Stage.Tree.Menu` | Stage 树右键 17 项（merge/accept/add/reset/stash files/revert/ignore/diff/三栏/补丁/历史） | 已覆盖；`$Delete`、`Diff.ShowDiff`、`EditSource`、`ChangesView.CreatePatch*` 是平台动作，Arbor 有对应实现 |
| `Git.Stage.Tree.Menu.LocalHistory` | 只挂 `LocalHistory` | IDE 平台功能 |
| `Git.ChangesView.Conflicts` | 冲突右键：Merge / Accept Yours / Accept Theirs | 已覆盖 |
| `Git.Stash.ChangesBrowser.ContextMenu` | Stash 变更浏览器右键：ShowDiffWithLocal / EditSource / OpenRepositoryVersion / ApplySelectedChanges | 已覆盖（平台动作的 git 等价实现） |
| `Git.Stash.Operations.ContextMenu` | Pop / Apply / Unstash As / Drop / Clear | 已覆盖 |
| `Git.WorkingTrees.ToolwindowGroup.Popup` | Working Trees：Open / Remove | 已覆盖 |
| `Git.WorkingTrees.ToolwindowGroup.Toolbar` | Working Trees 工具栏：New / Remove / Refresh / Prune | 已覆盖 |
| `GitMergeRebaseWidgetGroup` | 编辑器内 merge/rebase 小部件：ResolveConflicts / RevertResolved / Rebase·Merge·CherryPick·Revert 的 Continue/Abort | 已覆盖 |
| `GitMainToolbarQuickActions` | IDE 主工具栏 VCS quick actions 宿主 | IDE 组装，无功能 |
| `MainToolbarQuickActions.VCS` | 同上（平台分组） | IDE 组装，无功能 |
| `Vcs.ToolbarWidget.ShareProject` | IDE 的 Share Project 小部件 | 平台功能 |
| `Vcs.ToolbarWidget.CreateRepository.LocalHistory` | IDE 的 Show Project History | 平台功能 |

## 容器里发现的小差异（非功能缺失）

1. **`git.branches.popup.filter.by.repository`**：单 root 的分支弹窗齿轮菜单里只有
   `Show Recent Branches` / `Show Actions in Search Results` / `Show Tags` /
   `Group by Directory` 四项；`filterByRepository` 只在 multi-root popover 里实现
   （`Dialogs+Branch.swift` 的 `repositoryFilter`）。属于「能力有、单 root 菜单没暴露」。
2. **`git.branches.popup.resize`**：IntelliJ 允许在弹窗里直接拖拽调整尺寸；Arbor 用
   固定布局 + 分隔条，无同名动作。
3. **`Git.Stage.Configure`（Enable/Disable）**：IntelliJ 可以整块关闭 Stage 工具窗，
   Arbor 的暂存视图是常驻工作页，没有「关闭工具窗」概念。
4. 其余未覆盖子动作全部是 IDE 平台 id（`Diff.ShowDiff`、`ChangesView.Refresh`、
   `EditorCut`、`LocalHistory`、`ContextHelp`、`Vcs.UpdateProject` …），不属于
   Git 功能范围。

## 判定口径

- 「已覆盖」= 矩阵里有独立 id 的行，且 `docs/git-parity-gap-report.md` 记录了对应
  的用户可见行为；`verified-partial` 只表示 IntelliJ 宿主生命周期（DataContext /
  VcsNotifier / Swing UI automation）不可得，与本审计无关。
- 容器 id 不计入功能覆盖：IntelliJ 把它们拆开是为了按 host 注入不同动作，Arbor 用
  直接的 SwiftUI 菜单/工具栏装配，没有对应概念。
