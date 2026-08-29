# IntelliJ Git 对等差距报告

更新时间：2026-08-29

## 2026-08-29 V1 scope closure

V1 的 in-scope Git 用户行为已完成并通过真实 Git fixture、Rust workspace
和 Swift/macOS 全量测试验证。矩阵中的 `verified-partial` 表示核心用户可见
行为已经交付，剩余差异只属于明确接受的宿主平台生命周期或呈现边界：
IntelliJ `DataContext`、`VcsNotifier`、`DialogWrapper`、VFS/PSI/dirty-scope
生命周期、Swing/UI automation、插件平台和其它 VCS 均不属于 V1。需要完整
原生宿主能力的条目保留在 `verified-partial`，并在各行的 failure/notes 中说明；
没有未决的 in-scope 功能性 `partial` 条目。跨 Git root 的操作继续采用
IntelliJ 的逐 root partial-result 语义，不虚构跨 root 原子事务。

交互式 rebase 的 merge 控制行可通过 Native Todo 编辑器完整编辑；Drop/Extract
Selected Changes 已覆盖 merge descendant 拓扑和 gitlink 边界；Submodule 的
Add/Update/Sync/Deinit/Remove/Push 具备 root-scoped retry/undo。其余差异是宿主
生命周期或已记录的安全 fail-closed 边界，不阻塞 V1 发布。

2026-08-28 `Git.Show.Stash` gap closed：主菜单此前只有 Show Shelf，没有 fork 中独立的 Show Stash 入口；现在两者都进入 Commit/Stash 工作页，且不混同 Unstash 弹窗。菜单顺序按 fork 的 `Git.MainMenu.LocalChanges` 对齐。

2026-08-28 `Git.Stash.UnstashAs` gap closed：fork 在 Saved Patches 的单 stash context menu 提供 Apply、Pop、Unstash As、Drop；Arbor 现在增加单 stash Unstash As 对话框，覆盖可选 branch、Pop 和恢复 staged state，并以 stash ID 重新解析栈位置。原生 SavedPatches/DataContext/VcsNotifier lifecycle 与 UI automation 仍为 partial。

2026-08-28 `Git.Stash.Toggle.Split.Preview` gap closed：fork 的 stash 工具页提供应用级持久化 split-preview toggle；Arbor 现在默认以内嵌分栏显示 stash diff，关闭后取消自动内嵌预览，但显式 View Diff 仍通过独立 sheet 可用。当前仍是 SwiftUI 状态切换，不具备原生 action update/message-bus 和 UI automation lifecycle。

2026-08-28 Stash preview identity gap closed：Stash 工作页预览现在以 stash ID 而非 stack index 作为稳定身份；读取前重新映射当前 index，刷新或删除前置 stash 后不会错看其它 stash，目标消失时 fail-closed 关闭预览。

2026-08-28 Stash operation identity gap closed：对照 fork 的 `StashInfo` 对象动作语义，Commit/Stash 工作页、旧侧栏、Branches Popup、Unstash/Unstash As、Pull/Update、Checkout/Reset/Force-update 恢复、多 root Update 恢复和 Diff/Preview 现在跨异步操作保存 stash commit ID，并在调用底层 index API 前重新解析当前栈位置；冲突完成、项目级 resolver 和保存变更入口也沿用该 ID。Diff sheet 额外绑定 root + stash ID，旧请求不能覆盖新请求。新状态优先按 ID；旧状态仅有 Pull message 时要求唯一匹配，缺少 ID 且无法唯一匹配时保留 stash 并明确失败，不再猜测 `stash@{0}` 或旧 index。底层引擎仍使用 index API，但不再把过期 index 当作业务身份；原生 SavedPatches/DataContext/VcsNotifier lifecycle 和 UI automation 仍为 partial。

2026-08-28 Stash restore stale-state hardening：Pull 失败后的 stash 恢复冲突、多 root Merge/Smart Merge marker 重建和 remote-branch pull 入口现在继续传递引擎返回的 stash ID；冲突完成后按 ID 删除，旧持久化状态缺少 ID 时 fail-closed 并保留 stash。Pop/Drop/Branch/Pull 恢复或 Clear 成功后，若独立 diff sheet 仍绑定已消费的 stash，会按 root + stash ID 关闭；旧 diff 请求的错误反馈也不会污染新选择。原生 SavedPatches/DataContext/VcsNotifier lifecycle 和 UI automation 仍为 partial。

2026-08-28 `Git.Stash` 显式对话框差距补齐：fork 的 `GitStashDialog` 使用 root chooser、current branch 展示和 `Keep index`，不提供 include-untracked/ignored 复选框。当前 Arbor 已按所选 Git root 执行真实 `stash push --keep-index` 等价语义；Pull/Update 的完整现场保存和 Stash Files 的 untracked 选项仍保持独立，不因显式 Stash 对话框收窄而回归。原生 DialogWrapper/ChangeListManager/VcsNotifier/DataContext lifecycle 和 UI automation 仍为 partial。

2026-08-28 `Git.Pull` 主菜单交互对齐：fork 的单一 Pull action 现在对应 Arbor 的 `VCS > Git > Pull…`，直接进入可选择 root、remote、remote-tracking branch 和持久化 options 的 dialog；Merge/Rebase 仍作为 dialog option 与分支级动作保留。原生 `GitPull`/`DialogWrapper`/`VcsNotifier` lifecycle 和 UI automation 仍为 partial。

2026-08-28 `GitCreateNewBranchAction` 的 fresh/unborn 边界补齐：对照 fork 的 action update 与 actionPerformed 双重检查，Arbor 顶层 `New Branch…` 现在在任一受影响 Git root 没有 `HEAD` 时保持可见但禁用，并在通知直达时再次 fail-closed；Branches Popup 原有的同一边界保持不变。原生 action/DataContext lifecycle 和 UI automation 仍为 partial。

2026-08-28 `FindMergedLocalBranchesAction` 的入口边界补齐：fork 仅在至少一个 Git root 有两个以上 local branches 时启用；Arbor 的 single-root 与 multi-root Branches Popup 现在按同一条件禁用无候选的 `Find Merged…`，不改变现有只读扫描与报告逻辑。原生 action/DataContext lifecycle 和 UI automation 仍为 partial。

2026-08-28 `Git.Init` 重复初始化安全边界补齐：对照 fork 的 `GitUtil.isUnderGit(root)` 与 warning dialog，当前初始化入口会先解析所选目录的 owning Git root；若目录本身或其子目录已经在 Git worktree 内，必须显式确认后才执行 `git init`，取消保持无副作用。原生 FileChooser/ProjectLevelVcsManager/VcsNotifier lifecycle 与 UI automation 仍为 partial。

2026-08-28 `Git.Checkout.Update` 调用时状态校验补齐：单 root 入口现在在任何 checkout 前重新确认本地分支仍有有效 tracking branch；过期 dashboard snapshot 会 fail-closed 并提示刷新，不会先切换分支再无条件报告成功。原生 `ActionData`/`DataContext`/`VcsNotifier` lifecycle、远端对象级解析和 UI automation 仍为 partial。

2026-08-28 Cleanup Branches 表格选择语义补齐：对照 fork `CleanupBranchesDialog` 的 JTable 行选择与 `CopyProvider`，Arbor 现在把“表格行选中”（用于 Copy）和“Selected 列勾选”（用于 Delete）分开维护；复制保持当前可见排序后的 branch/date/tracked 三列 tab-separated 顺序，筛选会同步清理隐藏行选择。原生 JTable/CopyProvider/DataContext 生命周期和 UI automation 仍为 partial。

2026-08-28 Git 文件上下文菜单补齐：对照 fork `Git.ContextMenu`，项目文件树现在提供 Checkin Files、Add、Compare、History、Annotate、Revert、Resolve Conflicts 和 Revert Resolved；Add/Revert 在执行前按路径重新解析 owning Git root，目录递归 Add 与冲突目录聚合暂不启用，避免把 `git add <directory>` 的副作用误当作 IntelliJ 的 unversioned-only 语义。原生 VersionControlsGroup/DataContext/VcsNotifier 生命周期和 UI automation 仍为 partial。

2026-08-28 `Show.Current.Revision` 入口补齐：对照 fork `Git.ContextMenu` 挂载的平台 `ShowBaseRevisionAction`，项目文件树文件上下文菜单现在显示当前文件最近提交的 revision、author、date 和完整 message；查询按最深 owning Git root、`--all`、follow-renames 路由，无历史、untracked、ignored、conflicted 文件 fail-closed。SwiftUI sheet 替代原生 notification popup，原生 DataContext/ProgressManager/VcsNotifier lifecycle 和 UI automation 仍为 partial。

2026-08-27 Git 主菜单 Clone 入口补齐：fork 的 `Git.MainMenu` 直接注册 `Git.Clone`；Arbor 现在在 `VCS > Git` 增加同名入口，并复用已有 `RebasedCloneDialog`，File 菜单和空状态页路径保持不变。没有新增 clone 实现分支，避免三个入口产生不同语义。

2026-08-27 Git Reset Head 主菜单入口补齐：对照 fork 的 `GitResetHead`/`GitResetDialog`，Arbor 现在在 `VCS > Git` 提供 `Reset Head…`，支持选择 Git root、输入并 Validate 任意 revision expression、选择 Soft/Mixed/Hard，并复用既有 root-scoped reset recovery、Smart/Force 与 Undo/Keep 链路。`Reset to Remote Branch…` 仍是独立的 fetch + hard-reset 快捷动作；原生 DialogWrapper/ProgressIndicator/VcsNotifier/DataContext lifecycle 仍为 partial。

2026-08-27 Git Revert Resolved 主菜单入口补齐：对照 fork 的 `GitRevertResolvedAction`，`VCS > Git` 现在提供 selection-scoped `Revert Resolved`；仅当当前明确选中的路径属于 resolved-conflict ledger 时启用，并复用既有 root-scoped `revert_resolved_conflict`。原生 DataContext 多选、VcsNotifier lifecycle 和 UI automation 仍为 partial。

2026-08-27 Git.FileActions 主菜单 action group 补齐：对照 fork 的 `Git.MainMenu.FileActions`，`VCS > Git > File Actions` 现在在有明确文件/目录选区时显示 Checkin Files、Add、Annotate、Compare with HEAD、Compare with Selected Revision、Compare with Branch or Tag 和 Show File History；Add/Checkin 重新校验状态与 owning Git root，比较/历史使用 root-relative 路径。原生多选 DataContext、History for Block、VcsNotifier lifecycle 和 UI automation 仍为 partial。

2026-08-27 Branches Popup Tag action parity 补齐：对照 fork 的 `GitBranchesTreeActionsForSelectionTest`，单 root 与 multi-root 的非当前 Tag 右键菜单现在提供 `Checkout`，路由到既有 root-scoped tag checkout；当前 Tag 保留 Show Diff/Push 等安全动作，并移除 IntelliJ 不提供的 branch-only `New Working Tree` 与 `Rename`。剩余差距是原生 `GitCheckoutAction`/DataContext/VcsNotifier lifecycle、smart-checkout 细节和 UI automation。

2026-08-27 单 root Branches Popup 无 remote 的 Push 可达性补齐：对照 fork 的 `GitPushBranchAction`，本地分支即使没有 configured remote 也会打开 Push dialog，不再静默丢弃点击；Push 模式明确提示先配置 remote，并提供 Configure Remotes 入口。`Commit and Push` 在无 remote 时仍保留既有的 commit-only fallback，避免把两种 action 的语义混在一起。剩余差距是原生 `VcsPushDialog` 空 remote presentation、VcsNotifier/DataContext lifecycle 和 UI automation。

2026-08-27 单 root Branches Popup 分支 Push 入口补齐：参考 fork 的 `GitPushBranchAction`，`RebasedBranchesPopover` 现在在本地分支行的 action menu 中提供 `Push…`，当前分支和非当前分支都把所选 branch 作为 Push dialog 的 source；此前单 root 的 action availability 虽然已声明 `.push`，但没有渲染该菜单项，只能从全局 Push 入口操作 checked-out branch。multi-root 分支 Push 已有 root-qualified dialog。剩余差距是原生 `VcsPushDialog`/VcsNotifier/DataContext lifecycle 和 UI automation。

2026-08-27 in-memory 历史改写取消语义补齐：对照 fork 的 `executeInMemoryWithFallback` 与后台操作取消边界，修复 Arbor 默认对象级 Log Drop/Interactive Rebase 不消费用户 Cancel 句柄的问题。现在对象级 rebase 在保存现场前及每个重放步骤前检查 `GitCancelHandle`；取消返回 `Cancelled`、恢复原 HEAD 边界，并由保存现场包装器恢复 staged/unstaged/untracked 场景。Log Drop 已切换到 cancellable API；剩余差距是原生 ProgressIndicator/ProgressWindow/DataContext lifecycle 和 UI automation。

2026-08-27 多 root Log Revert/Cherry-pick Abort 语义校正：对照 fork 的 `GitApplyChangesProcess` 单次用户操作生命周期，修复 Arbor 在启动前为所有 Git root 写入恢复 marker 后，用户从当前 root 选择 Abort 只中止 Git、却留下后续 root Retry marker 的问题。现在 Abort 成功会按 session + operation 清理当前及后续 root 的 marker，并撤销对应陈旧通知；Continue 仍按 batch 顺序自动推进。新增 session cancellation scope 回归测试。剩余差距是原生 VcsNotifier/DataContext lifecycle 和 UI automation。

2026-08-27 Submodule Sync 面板入口补齐：当前 Operations > Submodules 面板新增显式 `Sync` 按钮，调用已有的 root-scoped `submoduleSync` durable runner；它执行递归 `git submodule sync`，保留认证、取消、失败通知和跨重启 Retry 语义。此前能力只存在于 WorkspaceOperations，用户无法从 Submodule 面板触发。剩余差距是原生 action-group/DataContext/VcsNotifier lifecycle 和 UI automation，故新增 verified-partial 记录。

2026-08-27 Git annotate options 对照补齐：参考 fork `GitToggleAnnotationOptionsActionProvider`/`GitAnnotationProvider`，Blame 现在默认忽略空白，菜单可切换文件内移动、跨文件移动和 prefer commit date；Rust HEAD/worktree runner 真实传递 `-w`/`-M`/`-C`，两种查看器使用同一持久化设置。新增默认值/持久化映射与真实 Git blame 语义回归。剩余差距是原生 AnnotationGutter/FileAnnotation/DataContext 生命周期、受影响路径缓存、系统编辑器 gutter 和 UI automation，故标记为 verified-partial。

2026-08-27 Native rebase 进度/取消生命周期对照补齐：参考 fork 的 `GitRebaser`/`GitRebaseProcess`，所有经过 `rebase_with_system_options` 的 structured、branch-targeted、root 和 non-interactive native rebase 现在统一使用 `GitCommandSpec`/`gitprocess::run`，因此复用进程组取消、stderr 流式读取、失败分类和 `FeedbackCenter` 的 Git progress snapshot；Git 的 `Rebasing (n/m)` 输出会被转换为百分比。取消在 native state 已建立时保留可 Continue/Skip/Abort 的 recovery state，尚未建立时清理 support 并返回 `Cancelled`；raw-todo/capture 路径原本已有同一 runner。新增 parser focused test，并通过 rebase_options、rebase_todo、rebase_merges、multi_root 回归。剩余差距是 fork 更细的 ProgressIndicator/重试策略、gix object-level rebase/merge 的 indeterminate 阶段、原生 VcsNotifier/DataContext 生命周期和 UI automation。

2026-08-27 Interactive Rebase `--update-refs` 重排语义校正：精确对照 fork 的 `GitRebaseTodoModel.Type.NonUnite.UpdateRef` 与真实 Git native todo 后，修复 preserve-merges structured/multi-root 路径的序列编辑器只移动 `pick`、却把连续 `update-ref` 控制块留在旧位置的问题；现在每个连续 `update-ref` block 会随其前置 pick 一起移动，label/reset/merge 等拓扑控制行仍保持原生锚点。新增 shell editor 单测和真实 multi-root rebase 回归，验证重排并 reword 后被跟踪分支仍指向正确的新提交。剩余差距是 structured editor 尚未像 fork 那样把 `UPDATE_REF` 建模为可见的非提交行，用户仍需进入 Native Todo 文本编辑器做控制行编辑，以及原生 action/DataContext/VcsNotifier lifecycle 和 UI automation。

2026-08-27 Commit warning 顺序交互对照补齐：参考 fork `GitCheckinHandlerFactory` 的有序 `CommitCheck` 与 `GitCrlfDialog`，单 root 与 multi-root 提交现在按 warning category 逐个显示 native modal decision，而不是把不同问题压成一个 aggregate alert；每个 warning 独立提供 Commit Anyway/Cancel、CRLF 的 Set `core.autocrlf` and Commit，以及项目级 Do-not-ask，重复 category 在同一提交中不会重复打扰。剩余差距收敛为 native DialogWrapper/CommitCheck lifecycle、详情链接、VcsNotifier/DataContext 和 UI automation。

2026-08-27 Commit and Rebase autosquash 语义校正：对照 fork 的 `GitRebaseCheckinHandlerFactory`，Fixup/Squash 提交完成后的自动整合现在改走 native `git rebase -i --autosquash`，而不是误用 Rust 对象级 todo 重放；Arbor 仍在启动前校验目标位于当前 rebase 范围，root target 使用 `--root`，并保留现有取消、冲突暂停、本地现场恢复与 expected-HEAD Undo。新增 native 普通/root autosquash 回归；原生通知分组、Commit Executor/DialogWrapper 生命周期和 UI automation 仍为 partial。

2026-08-27 IntelliJ in-memory commit editing registry 对照补齐：新增默认开启的全局 `git.in.memory.commit.editing.operations.enabled` 等价设置，并真正参与 Log 驱动的 structured interactive rebase 与直接 Drop Selected Commits 分流；无 EDIT、非 merge-preserving 的 linear/root todo 使用 Rust 对象级引擎，设置关闭、包含 EDIT、保留 merge 拓扑或其它 native fallback 条件则使用 Git interactive rebase。native structured actions 已覆盖 pick/drop/edit/reword/squash/fixup；in-memory conflict 现在先安全 abort、恢复原 HEAD/本地现场，再重放完整 native todo，native 再次冲突时保留原生恢复状态。默认关闭的 `git.in.memory.interactive.rebase.debug.notify.errors` registry，以及原生 VcsNotifier/DataContext/UI automation 仍为 partial。

2026-08-27 Auto Fetch/LS_REMOTE incoming branch state 对照补齐：参考 `GitBranchIncomingOutgoingManager`，Arbor 现在按 `Git root + remote + branch` 保留 live remote 已知有 incoming、但本地 remote-tracking ref 尚未更新的状态，并在单 root/多 root Branches Popup、分支按钮和状态栏显示未知数量的 `↓?` 标记；轮询发布带已检查 remote 身份的完整 incoming/error 快照，空快照会清除已确认无 incoming 的旧状态和过期通知，失败或被其它窗口占用的 remote 保留旧状态。该状态只用于展示，不改变 tracked upstream、checkout、pull 或 push action availability；原生 `VcsNotifier`/permission/banner、完整 dashboard data model 与 UI automation 仍为 partial。

2026-08-27 Git incoming/outgoing advanced visibility gate 对照补齐：参考 `git.update.incoming.outgoing.info`，Arbor 现在以默认开启的全局设置统一控制 incoming/outgoing 信息与 Auto Fetch/LS_REMOTE monitor；关闭时保留原策略但使其失效，隐藏 Branches Popup、状态栏和多 root Branches 的同步徽标，并撤销旧的 incoming/error 可操作通知；项目级设置显示相同的 disabled 反馈。LS_REMOTE 仍只检查配置 upstream，FETCH/LS_REMOTE 的 root、remote、取消和失败语义不变；原生 `AdvancedSettingsPredicate`/`GitVcsSettings`/VcsNotifier/DataContext lifecycle 与 UI automation 仍为 partial。

2026-08-27 Update Project 全局未就绪前置检查补齐：参考 `GitUpdateProcess.isUpdateNotReady()`，Rust 复合 Update Project 现在在 fetch、保存本地变更或更新任何 root 之前，统一检查所有选中 root 的进行中 Git 操作和未解决 index 冲突；阻塞 root 返回失败原因，其余 root 返回未执行行，避免先更新部分 root 后才在后续 root 失败。Swift 将该结果映射为 `Update Project unavailable`，保留 root-qualified Operation Log 结果并提供 Conflict Workbench；取消仍保持原有取消语义。原生 `GitUpdateExecutionProcess`/VcsNotifier/DataContext lifecycle 与 UI automation 仍为 partial。

2026-08-27 Update Project 全部 root 不可更新时的就绪语义补齐：参考 `GitUpdateProcess.checkTrackedBranchesConfiguration()`，多 root Update Project 现在在所有 root 都是 detached HEAD 或没有 tracked upstream 时报告 `Update Project unavailable`，不再把全 skipped 结果伪装成成功；通知保留 root 结果树，并提供 root-scoped Choose Upstream / Open Branches 恢复入口。只有至少一个 root 真正可更新时，其他 detached/untracked root 才继续按 skipped partial 语义处理；native VcsNotifier/DataContext lifecycle 与 UI automation 仍为 partial。

2026-08-27 Changes Browser 多 root commit identity 对照补齐：参考 IntelliJ Changes Browser 对选中 commit 的来源保留语义，aggregate Log 现在按 `Git root + commit ID` 分组；两个独立仓库即使出现相同 object ID，也不会把文件树混到同一组或复用同一个子模块变更请求。root-qualified patch 分组、单 root/多 root diff 与既有 parent 分组保持不变；原生 VcsLog/ChangesBrowser/DataContext/VcsNotifier lifecycle 与 UI automation 仍为 partial。

2026-08-27 Shelf DeleteProvider 混合选择生命周期补齐：参考 `ShelvedChangesViewManager.deleteShelves` 的统一删除计划，active Shelf/成员与 Recently Deleted Shelf/成员的混合 Delete 现在收敛为一个 root-scoped `ShelfDeletePlan`，在单一串行 runner 中按 list → member 顺序执行，最终只发布一次 Shelf 快照和通知；成功 active 删除携带原始 timestamp 进入统一 Undo，失败范围保留 active/deleted 与 list/member 类型并通过 Codable Retry action 回放。此前 DeleteProvider 会启动最多四个互不协调的 mutation runner，可能造成多次通知和快照覆盖；原生 `ShelvedChangesViewManager`/DataContext/VcsNotifier lifecycle、完整 recycle action model 与 UI automation 仍为 partial。

2026-08-27 Shelf 单项 action 反馈语义校正：对照参考 `ApplyShelfAction` / `PopShelfAction` 与 Shelf Drop action，单 Shelf Apply (Keep)、Unshelve and Remove、Pop、Drop 的 Operation Log/进度标题现在分别对应真实 action；此前单项 Apply 会记录成 `Pop shelf`，Pop 会记录成 `Unshelve changes`，Drop 还使用了不一致的 `Drop shelve`。本次只修正反馈语义，不改变 differentiated apply/pop、Recently Deleted 或恢复快照边界；原生 VcsNotifier/DataContext lifecycle 与 UI automation 仍为 partial。

2026-08-27 Interactive Rebase todo 组移动/拖放对照补齐：参考 `GitRebaseTodoModel.exchangeIndices` 的 `UniteRoot/UniteChild` 语义，结构化 single-root 与 multi-root editor 的箭头移动、拖放现在都按完整 squash/fixup group 处理；移动 group root 会带着 children 一起移动，child 跨出原 group 会先转为独立 `pick`，移动到另一 group 的 child 前会重新挂为 `fixup`，组内 child 的交换也遵循参考实现的先脱离、再定位、必要时重新加入流程。merge-preserving 的 native label/reset/merge 控制行边界仍由既有 fail-closed 保护。新增 4 个 CompareSelection 回归场景并通过 Swift 全量 648 tests；完整 native control-row 编辑、通知分组和 UI automation 仍为 partial。

2026-08-27 IntelliJ 高级 Git 设置尾差补齐：参考 `git.read.content.with`，Revision Browser 现在支持 `NONE/FILTERS/TEXTCONV` 三种历史文件内容模式，默认 `FILTERS`，并通过共享 system-Git 字节通道执行路径 filter/textconv；参考 `git.commit.do.not.run.commit.hooks`，全局设置现在覆盖单 root、multi-root、amend 与 Commit and Push 的 hooks 选择；参考 `GitRefNameValidator` 与 `git.branch.cleanup.symbol`，新建分支、worktree 分支和 Push target 在输入时清理非法 ref 字符、空格、连续分隔符和结尾模式，最终执行前再次清理。对应的 AdvancedSettings/Native DialogWrapper/DataContext/VcsNotifier 生命周期和精确 caret/UI automation 仍为 partial。

2026-08-27 Update Project 自动打开 Update Info 对照补齐：参考 `git.update.info.auto.open.enabled`（Advanced Settings，默认开启），Arbor 现在在全局设置提供同名语义；Update Project 的单 root、多 root、partial result 与失败 root Retry 只要产生 received commit ranges 就自动打开专用 Update Info tab，关闭后保留当前 Log 并继续提供通知中的 `View Commits`。参考实现共享的 Push/Force-push update ranges 也接入该开关；普通 Pull 与其它非更新恢复流程不自动继承该上下文。原生 AdvancedSettings/VcsNotifier/DataContext lifecycle 与 UI automation 仍为 partial。

2026-08-27 Update Info project-level path filter 对照补齐：参考 `GitVcsPanel.updateProjectInfoFilter()`，Project Git Settings 现在按 project path 保存 root-qualified Update Info 路径选择；`View Commits` 新建的 Update Info tab 会加载该过滤器，tab 内修改也回写项目设置，空值表示显示所有更新路径，跨 root 同名路径不会串 root，项目外路径被安全忽略。原生 StructureFilterPopupComponent/FileFilterModel、精确 project configuration storage、DataContext/VcsNotifier 与 UI automation 仍为 partial。

2026-08-27 Update Project/View Commits 独立 Log tab 对照补齐：参考 `GitUpdateInfoAsLog.findOrCreateLogUi()`，`View Commits` 现在先保存当前 Log context，再按 root-qualified before/after ranges 查找或创建独立 `Update Info` tab；普通 Log 不再被更新范围覆盖，多 root ranges 继续走 aggregate loader，切换 tab 会恢复各自的 aggregate branch/range/root filters。旧的 external Log tab 持久化数据仍可解码。完整原生 `VcsLogManager`/`UpdateInfoTree` lifecycle、StructureFilterPopupComponent 的 native lifecycle、DataContext/VcsNotifier 与 UI automation 仍为 partial。

2026-08-27 Recently Deleted raw patch 成员删除边界补齐：参考 `ShelveChangesViewManager.MyShelveDeleteProvider` 的成员级删除语义，Arbor 现在只解析 raw patch 的 UTF-8 header/path，按字节定位并裁剪 selected member，未选中的非 UTF-8 payload 原样保留；Recently Deleted 列表也不再因为合法的非 UTF-8 patch 内容整体失败。路径不安全、header/path 非法或 patch 无法建立成员边界时仍 fail-closed，不做部分写入；raw patch 的 apply/结构化预览仍要求 UTF-8，完整 binary provider、DataContext/delete-provider lifecycle、通知分组仍为 partial。

2026-08-27 Checkout with Rebase 远程分支工作流对照收口：参考 fork 的 `GitCheckoutWithRebaseAction` 与 `GitCheckoutAndRebaseRemoteBranchWorkflow`，remote Checkout with Rebase 现在在单 root 与 root-scoped multi-root 入口统一打开 New Branch 对话框；本地同名 branch 已存在且未勾选 Reset 时复用该 branch，勾选 Reset 才强制重置，目标就是当前 branch 时 fail closed。此前 multi-root remote 入口错误复用了 Checkout+Update（会把 remote-tracking branch 当成更新目标），现已改为先创建/复用 local branch，再按 `rebase --autostash HEAD <branch>` rebase 到当前分支。剩余差距是跨 root 选中仓库的统一聚合、原生 action/DataContext/VcsNotifier lifecycle 与 UI automation。

2026-08-27 Update Selected Branch current/non-current 分流对照收口：参考 fork 的 `GitUpdateSelectedBranchAction` 与 `GitBranchActionsUtil.updateBranches`，当前分支现在读取项目级 Merge/Rebase 设置并通过带认证、取消和本地变更保存策略的 root update；非当前分支通过同一认证 broker/取消句柄 fetch 后只快进目标本地 ref，不 checkout、不改变当前工作树。Branches Dashboard 的多选也不再错误排除当前分支，混合 current/non-current selection 会按 root 重新读取真实分支状态后执行；configured upstream 解析支持最长 remote 前缀。非快进/冲突仍进入现有更新状态恢复；原生 `GitUpdateExecutionProcess`、`GitFetchSupport`、`VcsNotifier`/`DataContext` lifecycle 与 UI automation 仍为 partial。

2026-08-27 外部 VFS 任意文件名 rename 的内容身份恢复：参考 fork 的 `GitVFSListener` 与 Git 自身的 clean-filter 语义，FSEvents 缺少 old endpoint 时，Arbor 现在对 untracked 新端点计算 `git hash-object --path`，并与 deleted tracked index blob 做一对一匹配；只有每个 blob 在候选新旧集合中都唯一时才自动执行 Add+Remove。重复 blob、内容被修改、目录事件、路径不安全、Git 查询失败或没有匹配时仍进入 basename review 或保守 Add，不猜测旧端点；已有 filesystem identity、status `oldPath` 和 case-only force move 路径不变。剩余差距是 GitVFSListener 原生 permission/banner/action history/UI automation，以及相同内容但实际来源无关时仍需更强的 VFS provenance、modified-rename similarity 与完整 native lifecycle。

2026-08-27 外部 VFS 未配对 rename 安全边界校正：参考 fork 的 `GitVFSListener`，FSEvents 缺少 old endpoint 时，即使同一批 status 恰好只有一个 untracked 新文件和一个 deleted 旧文件，也不能把数量唯一当作身份唯一；Arbor 现在只对 basename 候选打开显式 one-to-one review，无法证明时只保守处理新端点，不自动 Remove 旧端点。已有 filesystem identity、Git status `oldPath`、case-only force move、directory review 和 root-scoped action ledger 语义保持不变；剩余是原生 VFS permission/banner/action history/UI automation，以及无身份时更强的 arbitrary-basename rename 恢复。

2026-08-27 Search Everywhere Git contributor 对照补齐：参考 fork 的 `GitSearchEverywhereContributor`，Search Everywhere 现在按 root 搜索 local branch、remote-tracking branch、tag，以及至少 7 位 hex hash 的提交和至少 3 个字符的提交 message；结果保留 repository identity，并统一在对应 Git Log 中定位，不再把 local branch 误当作 checkout-only 结果。提交 message 查询使用 Rust `log_with_command --all --grep`，未引入 shell 拼接。参考 contributor 的 native Search Everywhere contributor、index freshness、DataContext/action-group 和 UI automation 仍为 partial。

2026-08-27 Log 分支仓库分组项目边界补齐：参考 `GroupBranchByRepositoryAction` 仅在多仓库 dashboard 可见的语义，`MultiRootLogBranchesPanel` 现在在挂载和 project root 切换时重新读取 project-scoped `groupByRepository`，并继续在用户切换时写回同一项目键；因此 Log 面板重建不会把上一个项目的 repository grouping 带入当前项目。原生 `BRANCHES_UI_CONTROLLER`/action-group、repository tree lifecycle 和 UI automation 仍为 partial。

2026-08-27 Interactive Rebase squash/fixup group 语义补齐：参考 `GitRebaseTodoModel` 的 UniteRoot/UniteChild 模型，structured single-root 与 multi-root editor 现在对组内 child 执行 Pick/Edit/Drop 时先脱离并移动到组尾；对 root 执行 Drop 会连同整组标记为 Drop；child 不再暴露 Reword。这样不会生成“drop 前驱后仍 fixup”或把 reword 错应用到 squash child 的非法 todo。merge-preserving 的 label/reset/merge 控制行仍由 native todo fallback 保持，完整原生通知分组和 merge descendant control-row 编辑仍为 partial。

2026-08-27 Log 分支目录分组项目边界补齐：参考 `Git.Log.Branches.GroupBy.Directory`，单 root 与 multi-root Log 分支树现在与 Branches Popup 共用 project-scoped 分组设置，默认开启；切换项目、重建 workspace 或重新进入 Log 面板会恢复对应项目值，目录折叠状态继续按 root/project 隔离。原生 action-group/DataContext/repository tree lifecycle 与 UI automation 仍为 partial。

2026-08-27 `Git.Commit.Stage` action 映射收口：固定 staging-area workspace 统一承载 `Git.Commit.Stage` 与 `CheckinProject` 的提交暂存区入口，不重复创建第二种提交模式；提交、multi-root Commit All、Amend、before-commit 检查与失败 root Retry 已有覆盖，原生 action-group/DataContext/VcsNotifier lifecycle 与 UI automation 仍为 partial。

2026-08-27 Git Stage 三版本交互暂存对照补齐：参考 `GitStageThreeSideDiffAction` / `GitStageDiffUtil`，`ThreeVersionComparisonView` 现在保留 HEAD、Staged、Worktree 总览，并提供 HEAD→Staged 与 Staged→Local 两个 pairwise diff；hunk action 分别支持 Unstage，以及 Stage/Rollback，实际写入复用 Rust partial-staging 引擎。完整 IntelliJ DiffManager 三栏对齐、区间级接受动作、原生 action/DataContext lifecycle 和 UI automation 仍为 partial。

2026-08-27 Git Stage ignored 显示设置对照补齐：参考 fork 的 `GitStageUiSettings` project workspace state，`Git.Stage.ToggleIgnored` 现在按标准化 project path 持久化；切换项目或重建 Commit 工作区会恢复各自设置，默认仍为显示。原生 GitStageUiSettings/DataContext/action lifecycle 和 UI automation 仍为 partial。

2026-08-27 Git Stage Local/Staged 比较交互对照补齐：参考 fork 的 `GitStageCompareLocalWithStagedAction` / `GitStageCompareStagedWithLocalAction` 共用 `compareStagedWithLocal`，两种入口现在都使用 staged → local 的 staging 坐标系，并在 hunk 上提供 Stage/Rollback；`Staged with HEAD` 保留 Unstage hunk。完整 DiffManager action/DataContext lifecycle、GitIndexVirtualFile/VFS 生命周期和 UI automation 仍为 partial。

2026-08-27 multi-root Commit CRLF 修复动作收口：修复对话框选择“Set core.autocrlf and Commit”后此前只在 single-root 生效的路径差异；现在 multi-root 也会在任何 Git 写入前只写一次 global `core.autocrlf=input`，写入失败按 IntelliJ 非阻断语义继续提交并保留下次告警。单 root 行为不变；原生 CRLF DialogWrapper、project/DataContext/VcsNotifier 生命周期和 UI automation 仍为 partial。

2026-08-26 Commit warning CRLF 语义校正：参考 fork `GitCrlfProblemsDetector`，Arbor 现在先读取有效 `core.autocrlf`，在 `true/input` 时跳过 CRLF warning；再用 Git 自己解析 `.gitattributes` 的 `text`、legacy `crlf` 与 `binary` 属性，已明确声明换行意图的文件不重复报警，属性读取失败则不制造告警。CRLF 检测也从“必须混合 LF/CRLF”收敛为“工作区存在 CRLF”，与 fork 的 `detectLineSeparator` 触发边界一致；新增 `arbor-engine/tests/commit_checks.rs::crlf_warning_respects_autocrlf_and_gitattributes`。原生 CRLF DialogWrapper、project/DataContext/VcsNotifier 生命周期和 UI automation 仍为 partial。

2026-08-26 Find Merged 多 root 目标分支边界校正：对照 fork 的 `reposWithTarget`，Arbor 现在只把包含目标本地分支的 Git root 交给 comparator；没有该目标的 root 计入发现总数但不再伪造扫描错误。真正的 Git comparator 错误、取消状态、已完成 root 和扫描统计仍保留在结果报告中；无结果时 UI 不再误称为仓库加载失败。

2026-08-26 embedded GPG launcher 远程 entrypoint 对照补齐：参考 fork `PinentryShellScriptLauncherGenerator` 的 `IJ_PINENTRY_ENTRYPOINT=` 分支，Arbor launcher 现在从该 token 提取 entrypoint 并以原始 `argv` 转发，避免远程开发 GPG 请求错误落入本机 pinentry fallback；本机 Arbor token 仍只进入 `--arbor-pinentry`。新增包含空格路径的真实 `/bin/sh` 路由测试；entrypoint 的产生和远程生命周期仍由远程开发宿主负责，真实 GPG signing GUI automation 与原生 DialogWrapper 生命周期仍是 partial。

2026-08-26 Shelf 树状态项目隔离对照校正：审计发现 `RebasedCommitWorkspace` 的 Shelves 展开、目录分组和 Recently Deleted 展开仍使用全局 `@AppStorage`，会把一个项目的视图状态带到另一个项目。现在三项设置统一按标准化 project path 写入 `UserDefaults`，项目切换时重新加载，默认值保持 IntelliJ 式展开/目录树；新增 `testShelfTreeSettingsAreProjectScoped` 覆盖不同项目互不污染。Shelf 的完整回收 action model、细粒度通知生命周期和 UI automation 仍是 partial。

2026-08-26 secondary Shelf 外部 metadata 刷新对照补齐：secondary root 的 `.git/arbor-shelves*` 变化现在会在 aggregate root refresh 后重新加载完整 Shelf、Recently Deleted 和 changelist snapshot；修复已有 `shelfRootSnapshots` 遮蔽新 Branches snapshot 导致的陈旧列表，新增 root/作用域回归测试。IntelliJ 原生 `ShelveChangesManagerListener`、VcsNotifier/DataContext 生命周期和 UI automation 仍为 partial。

2026-08-26 Compare Branches 两侧方向对照补齐：参考 `CompareBranchesDiffPanel` 的 `SWAP_SIDES_IN_COMPARE_BRANCHES`，Branches 的 `Show Diff with Working Tree` 现在默认把当前工作树放在左侧、选中分支放在右侧；`Swap Sides` 按项目持久化，并对已解析的 hunk 交换起点、行号及增删侧，异步加载带方向代际校验。该设置只作用于 branch-vs-working-tree 文件比较，不改变 Log 的 revision-vs-working-tree `Compare with Current` 语义。剩余差距是原生 CompareBranchesDiffPanel/ChangesBrowser/DataContext 生命周期和 UI automation。

2026-08-26 `Git.Add` ignored-file confirmation 对照补齐：fork 的 `GitAdd` 将 `FileStatus.IGNORED` 纳入 Add to Git，并把 `containsIgnored` 交给确认流程；Arbor 的 Ignored Files 现在提供右键 `Add to Git…`，确认后复用 root-scoped `stage(path:)` 将当前内容写入 index，取消则保持 ignored 状态。Ignore 与 Exclude 入口不变；原生 ScheduleForAdditionAction/ChangesView/DataContext 生命周期和 UI automation 仍为 partial。

2026-08-26 `Git.Ignore.File` enablement 对照校正：fork 的 `IgnoreFileActionGroup` 只对 unversioned files 建立 Ignore/Exclude action；Arbor 之前在 tracked、staged、ignored 行上也展示 Ignore，可能把无效规则写入 `.gitignore`。现在两类入口仅对 `unstaged == untracked && staged == unchanged` 的文件显示，且保留当前 root-scoped 写入路径；已有 ignore-file 候选选择、多文件共同 ignore、原生 ChangesView/DataContext 生命周期和 UI automation 仍为 partial。

2026-08-26 `Git.Ignore.File` ignore-file candidate 对照补齐：fork 会从目标文件所在目录及祖先目录中收集现有 `.gitignore`，多个候选进入 `Ignore in…` 子菜单，并按所选 ignore 文件目录生成相对规则；Arbor 现在复用同一 root-scoped candidate 集合，Rust 在写入前校验 ignore 文件位于 worktree 内且确实覆盖目标路径，未找到候选时继续写根 `.gitignore`。多文件共同候选、创建任意祖先目录的新 ignore 文件、原生 ChangesView/DataContext 生命周期和 UI automation 仍为 partial。

2026-08-26 Commit warning 的 rebase 上下文对照补齐：fork 的 `GitDetachedRootCheckinHandler` 在交互式 rebase 中抑制 generic detached HEAD warning，在其它未完成 rebase 中显示专用 rebase warning；Arbor 的 `commit_checks()` 现在输出结构化 `RebaseInProgress`，交互式 rebase 不再输出 `DetachedHead`，非交互式 rebase 显示专用消息，Swift 继续复用项目级 detached-head warning 开关。真实 DialogWrapper/VcsNotifier/DataContext 生命周期、detached rebase 特殊 UI 和 UI automation 仍为 partial。

2026-08-26 `Git.Show.Stage` 入口对照补齐：fork 将 Staging Area 注册为独立的 `Git.Show.Stage` action；Arbor 现在在 VCS > Git 下提供 `Show Staging Area`，并通过当前 Git action context 做 enablement 检查后打开现有固定双栏 Commit/Staging 工作区，同时清除 Shelf tab 选择。这样补齐的是 IntelliJ 的 action reachability，不重复引入第二种 staging 模式；native action-group/DataContext/Commit tool-window focus 生命周期和 UI automation 仍为 partial。

2026-08-26 Git 主菜单进行中操作 action group 对照补齐：参考 fork 的 `Git.MainMenu.MergeActions`、`Git.MainMenu.RebaseActions` 和 `Git.Ongoing.Rebase.Actions`，Arbor 现在从 focused `operation_state()` 读取当前 root，主菜单按参考分组提供 `Commit Merge` / `Abort Merge`、`Rebase in Progress` 下的 Abort/Continue/Skip，以及 Cherry-pick/Revert 的恢复 action；请求始终携带 project/root scope，不会把 secondary root 的状态误发给当前 Repository。Branches Popup 继续只暴露 `Git.Ongoing.Rebase.Actions`（Merge 仅 Abort），顶部 widget 的 Merge 继续按钮也改为 `Commit Merge`，冲突时按 `GitMergeCommitAction` 规则禁用。剩余差距是原生 action-group/DataContext/VcsNotifier 生命周期和 UI automation。

2026-08-26 Multi-root Rebase result-tree 生命周期对照补齐：参考 IntelliJ 多 root Update/Rebase 的 grouped partial result 语义，Arbor 之前把暂停中的 root 误映射为 success，并且稳定通知在 Retry/异常路径重新进入 Working 时会清空旧 rows。现在 paused root 在 Operation Log 中显示为 partial；重试开始前保留已完成/待处理 root 的累计树；Rust 抛出操作级错误时也重新挂回当前 session rows；首次执行不会伪造“未尝试”结果。仍保留 native VcsNotifier/DataContext/action lifecycle 和 UI automation 的 partial 边界。

2026-08-26 全局 Merge/Rebase widget 对照补齐：参考 fork 的 `main.toolbar.git.MergeRebase` / `GitMergeRebaseWidget`，Arbor 之前只在 Commit 工作区显示 `OperationRecoveryBar`，导致用户切到 Log、Branches 等工作区后看不到进行中的 Git 操作入口。现在 `RebasedTopBar` 持续显示 root-aware widget；当前 root 的 Continue/Skip/Abort/Resolve Conflicts/Revert Resolved 复用现有 `operation_state()` 与 resolved-conflict ledger 路由，secondary root 先打开该 root 的 Recovery/Conflict Resolver，避免把动作误发给当前选中的其它 Repository。原生 action-group/DataContext/VcsNotifier 生命周期和 UI automation 仍为 partial。

2026-08-26 Branch Popup Commit action 对照补齐：参考 fork 的 `Git.Experimental.Branch.Popup.Actions`（`CheckinProject` / `Git.Commit.Stage`），Arbor 的单 root 与 multi-root Branches Popup 现在都提供 root-safe `Commit Changes…` 顶层 action；它进入现有 Commit workspace，并参与 speed-search、上下键、Enter 和 disabled presentation。固定 staging-area 产品决策下将两个参考 action 合并为一个提交入口；无本地变更时保持可见但禁用。原生 action-group/DataContext 生命周期、Commit tool-window 的 native focus 与 UI automation 仍为 partial。

2026-08-26 Git Roots Pull All 行为收敛：审计发现 Git Roots 面板的 Pull All (Merge/Rebase) 仍调用旧的 `run_multi_root_operation`，绕过 Update Project 已具备的 credential broker、取消句柄、Fetch tag policy、Smart 保存/恢复本地现场、冲突恢复和 root-scoped Retry。现在两个 Pull All 入口统一进入 `executeMultiRootUpdate`；旧版持久化 Pull retry action 也转入同一条 selected-root update runner，避免入口不同导致本地现场和失败恢复语义不同。参考 `GitUpdateProcess` 的 root updater 仍有原生 VcsNotifier/DataContext 生命周期和 UI automation 差异。

2026-08-26 Merge rollback result-tree 对照补齐：复核 fork 的 `GitMergeOperation` 后确认，多 root rollback 的 IntelliJ 语义是逐 repository 执行、按失败类型选择 smart/simple/merge rollback，并不提供跨 root atomic transaction。Arbor 已有 expected-HEAD guarded 的 root-qualified rollback semantic action；本轮补上 rollback 成功/失败结果的持久化 `FeedbackResultRow`，并把累计 rows 放进 Retry Remaining Rollback semantic request，重试后只替换重试 root，Operation Log 重载后仍能看到每个 Git root 的最终状态。剩余差距收敛为 native VcsNotifier/DataContext/action lifecycle 与 UI automation，而不是重复引入跨 root 原子回滚。

2026-08-26 Commit message cleanup 对照补齐：参考 fork 的 `GitCommitMessageFormatter`，`git commit-tree` 不会自动读取 `commit.cleanup`，因此 IntelliJ 在对象写入前按 `default/whitespace/scissors`、`verbatim`、`strip` 和 `core.commentChar` 清理提交信息。Arbor 的 gix `commit_inner`、amend、multi-root commit、merge finish 和 object-level rebase replay 现在共用同一 formatter；系统 Git `commit_with_options` 路径继续由 Git 自身负责 cleanup。Rust 回归覆盖默认 whitespace、strip + 自定义 comment prefix、verbatim、multi-root 和 merge；剩余差距是原生 CommitOptionsPanel/GitCheckinEnvironment/VcsNotifier/DataContext 生命周期与 UI automation。

2026-08-26 HTTPS askpass 会话对照补齐：参考 fork 的 `GitHttpGuiAuthenticator`，Arbor 现在为每个认证轮次保留无密码 `remote_url`，Swift 按完整远端 URL 记住非敏感用户名；用户名 prompt 中一次输入的 password 会在同轮 password prompt 中复用，从而保持一次认证对话；认证失败通过无秘密 callback 清除对应 host/user 的 Keychain secret，再进入最多一次的 fresh askpass retry。此处仍保持 SSH passphrase、host-key、credential helper/agent 和 hosting token 的边界，不把它们误记为 HTTP remote credential。真实 sshd、Keychain UI automation 与 helper/agent 来源级成功观测仍是 partial。

对照范围：

- 参考实现：`/Users/arix/src/rebased/plugins/git4idea/backend/src`、`shared/src`，以及平台 Shelf/Conflict 能力：`/Users/arix/src/rebased/platform/vcs-impl/src/com/intellij/openapi/vcs/changes/shelf`、`.../merge`。
- Arbor：`arbor-engine/src`、`Arbor/*.swift`、`docs/git-parity-matrix.csv`。
- 只比较 Git 能力和 Git 交互，不把 IDE 补全/重构/构建、其它 VCS、插件平台纳入缺口。

## 结论

Arbor 已覆盖 Git 日常主链路：status、三层 staging、diff、log、branch/remote、fetch/pull/push、stash、shelve、merge/rebase、revert/cherry-pick、tag、submodule、worktree，以及多 Git root 的项目级调度。当前 Merge 的关键长尾也已收口：非保护本地源分支在干净完成或冲突解决后，按 Git Settings 的 `DELETE` / `PROPOSE` / `NOTHING` 策略处理；远程、保护分支和 revision-only merge 始终保留，跨 root 也复用同一策略。合并后删除分支的 PROPOSE 通知现在使用独立稳定 id，点击后会先清理原 Merge 通知及其持久化 semantic action，避免分支删除完成后留下可重复执行的陈旧动作。

下面列的是仍然真实存在的差距，不把已经实现的能力重复列为 TODO。

2026-08-26 Protected Branch root-scope 对照校正：参考 `GitProtectedBranchProvider` 的保护判断最终作用于具体 `GitRepository`，Arbor 之前却把 hosted branch protection 缓存和 Push force guard 当成主 root/项目级数据，多 root 项目的第二个 root 可能漏掉自己的 GitHub/GitLab/Bitbucket 保护规则。现在每个 canonical Git root 独立加载并同步缓存，multi-root Push dialog、`pushInRoot`、Push All Rust runner 和 custom refspec target 都使用所属 root 的规则；同步失败只保留该 root 的旧缓存，不会把其它 root 的保护规则交叉套用。新增 `GitProtectedBranchRulesTests.testMultiRootRemotePatternsDoNotCrossProtectRepositories` 与 `tests/multi_root.rs::multi_root_force_push_uses_only_the_owning_root_protection_rules`；GitProtectedBranchProvider 扩展点、原生通知/DataContext 生命周期和 UI automation 仍按排除平台边界保留 partial。

2026-08-26 Reflog 分页与行身份对照校正：参考 fork 的 `git4idea` 源码只提供 Reflog 数据/恢复相关的通用 Git plumbing，没有独立的 Reflog UI/action 实现，因此本轮不把“跨 root 批量恢复”臆造为参考 parity 要求。Arbor 现在按 root 使用 Rust `reflog_page(limit, offset)` 读取超过首屏 100 条记录，SwiftUI 提供 `Load Older Entries`，追加时按稳定记录身份去重并保留选区；刷新、切 root 和旧异步结果均受 generation/root/tab 守卫保护。剩余真实差距仍是 native Reflog action/DataContext/VcsNotifier 生命周期与 UI automation，以及参考 fork 未定义的跨 root 批量恢复语义。

2026-08-25 Branches Dashboard HEAD 比较对照校正：参考 `BranchesPairActionBase` 的 pair resolution，合成 HEAD 与一个分支被解析为“所选分支 vs 当前命名分支”，执行层不再把字面量 `HEAD` 传给比较器；HEAD + 当前分支、detached HEAD 和 unborn HEAD 在 action 层 fail-closed。普通两分支比较仍保持原选择顺序，跨 root、同名和 tag 选区继续禁用。剩余差距是原生 BranchesPairActionBase/DataContext/VcsNotifier、Changes Browser 生命周期与 UI automation。

2026-08-25 多 root VCS Log 分页对照补齐：聚合 Log 的每个 Git root 现在使用独立的 engine `after_id` 游标继续读取下一页，不再按“已加载数量 + N”从头重查后由 Swift 丢弃前缀；首屏缓存恢复也会恢复每个 root 的最后游标，跨 root 合并仍按 `(root, commit)` 去重并保持选择。多路径、日期、message、revision range 和 `follow` 状态继续由引擎统一过滤；剩余差距是 IntelliJ 原生 `VisiblePackRefresher` 异步协调、DataContext/action lifecycle 和 UI automation。

2026-08-25 VCS Log 父/子提交跳转对照补齐：参考 `GoToParentOrChildAction`，单父/单子直接跳转，多父通过选择弹窗展示每个父提交，多子由 Rust 在当前页之外沿全 refs 图解析所有直接子提交后展示选择弹窗；候选标签包含短 hash、摘要、作者和时间，aggregate Log 继续按 owning root 路由，异步结果校验 Log generation 与当前 selection。剩余差距是原生 graph row/action-group popup、`VisiblePackRefresher`/DataContext/VcsNotifier lifecycle 和 UI automation。

2026-08-25 VCS Log permanent-graph snapshot 对照补齐：单 root 与 multi-root aggregate Log 现在按 canonical root 持久化完整的已加载提交集合、查询指纹、refs token、续载游标和 has-more 状态；重启/重新打开时可恢复跨分页 graph 数据，page-size 变化不会误使快照失效，root/ref/filter 漂移会 fail-closed。graph snapshot 使用 Caches 目录中的原子磁盘文件并在 utility queue 写入，避免大仓库滚动时把完整历史重编码进 UserDefaults；旧 UserDefaults 格式仍可迁移读取。partial snapshot 从保存游标续载，complete snapshot 在 Refresh 时仍重新读取第一页并合并，避免把缓存当作 Git 权威；aggregate rows 继续按 `(root, commit)` 去重并保持每 root 的独立 cursor。Rust live graph 已补齐 engine-side 的 all-ref index；剩余差距是 IntelliJ `VcsLogManager`/`VisiblePackRefresher` 的原生异步协调、branch containment/graph options、按需元数据索引、DataContext/VcsNotifier action lifecycle 和 UI automation。

2026-08-25 Rust live permanent graph 对照补齐：每个打开的 Repository 现在维护一份 all-ref、root-scoped 的内存提交图与 object-id 索引，按 refs/HEAD/sort token 失效；默认 Log 的分页直接从同一图切片，Go to Child 复用同一 child adjacency index，refs 移动或 HEAD 切换会在下一次访问前重建。路径历史、revision range、message/date/author 过滤和 follow 仍走各自的 Git walk，避免混淆 reachability 语义；Swift 磁盘 snapshot 继续只承担重启恢复，Git fresh graph 仍是权威。新增小页连续读取和同一 Repository 句柄 ref 漂移回归。剩余差距已进一步收敛为 IntelliJ 原生 `VcsLogManager`/`VisiblePackRefresher` 的异步任务协调、filter graph options、索引级元数据按需加载，以及 DataContext/VcsNotifier action lifecycle 和 UI automation。

2026-08-25 PermanentGraph branch containment 对照补齐：live graph 现在从 local 与 remote-tracking ref tips 向父提交传播 branch names，新增 root-scoped `commitContainingBranches`；Log 的 Push Up To Commit 先用一次 containment 查询选择当前/其它 local branch，protected-remote 检查也一次查询 remote branch containment，不再为每个候选 branch 单独重做 reachability walk。tags 保持独立 decoration，不混入 branch contract。新增同时属于 local、remote-tracking 和单独 branch 的 DAG 回归；剩余差距是 IntelliJ 原生 branch-head filtered visible graph、异步缓存/失效协调和 UI lifecycle。

2026-08-25 filtered VisibleGraph lane 对照补齐：无 path 的 message、author、date、revision 和 No Merges 查询现在先保留完整 revision walk 的 graph context，再只发布匹配提交；分页 cursor 前的隐藏提交仍参与 lane 计算，下一页的 `lane` 与 `parent_lanes` 不会因过滤条件而断裂。新增隐藏 merge 一侧父链的 DAG 回归。剩余差距是完整 native `VisibleGraph` controller、branch-head filtering、真实 graph option（参考实现为 Base Normal/Bek、LinearBek、FirstParent）和 `VisiblePackRefresher` 的异步请求合并。

2026-08-25 filtered VisibleGraph query/续载对照补齐：无 path、无 follow、无左侧 revision range 的 Log 过滤请求现在优先复用同一 root 的 live `PermanentLogGraph`，在 graph 上完成选定 branch/revision heads 的可达性、author/message/date/No Merges 过滤，并用同一 object-id 游标继续请求下一页；Swift Log 的 Load More 不再因这些过滤器存在而提前禁用，多个同事件循环内的过滤变更由一次 coalesced refresh 处理。path、follow 和 revision range 仍明确保留 Git-walk 语义，不错误套用 permanent graph。剩余差距是参考 fork 的完整 native `VisibleGraph` controller、精确 branch-head lane/layout、Base Normal/Bek 等 exact graph option、`VisiblePackRefresher` 的 indexing/异步状态机，以及 DataContext/VcsNotifier/action lifecycle 和 UI automation。

2026-08-26 Bek/LinearBek graph option 对照补齐：参考 `PermanentGraph.Options.Base(Bek)`、`BekBranchCreator`、`BekBranchMerger` 和 `LinearBekController`，Arbor 的 Standard graph 不再把 gix `TopoOrder` 误当作 Bek；完整 permanent graph 现在按 branch layout 建立 Bek fragments，再按 IntelliJ 的 timestamp/restriction 规则合并，merge 后优先展示 incoming history，且所有 parent edges 继续满足 child-before-parent。Linear graph 复用同一 Bek row order，现有 SwiftUI LinearBek fragment collapse/expand 继续负责视觉边折叠；UI 菜单同步显示 `Normal (Off)`、`Standard (Bek)`、`Linear (LinearBek)`、`First Parent`，旧 raw value 保持兼容。剩余差距是 native graph controller/action controller、精确 branch-head filtered layout、完整 LinearBek dotted-edge/fragment 类型，以及 `VisiblePackRefresher`/DataContext/VcsNotifier/UI automation 生命周期。

2026-08-26 branch-head VisibleGraph 对照补齐：参考 `PermanentGraph.createVisibleGraph(options, headsOfVisibleBranches, matchedCommits)` 与 `BranchFilterController`，Arbor 的 permanent graph filtered query 现在先按选定 branch/revision heads 计算可达 context，再在该子图上重新投影 lanes，之后才应用 message/author/date/No Merges 匹配；未选 sibling branch 不再影响当前可见 lane，FirstParent 仍只保留第一父边，cursor continuation 复用同一 selected-head context。剩余差距是原生 `CollapsedGraph`/`GraphAction` 动态 graph answer、精确 dotted filter edges，以及 `VisiblePackRefresher`/DataContext/VcsNotifier/UI automation 生命周期。

2026-08-25 Project File Tree root identity 对照校正：文件树刷新现在按 canonical worktree path 判断 selected Git root，而不是按 display name；两个同名 Git root 切换时不会继续展示前一个仓库的懒加载目录。Copy Relative Path 入口同时拒绝绝对路径、`..` parent traversal 和空/非法端点，并对重复分隔符做稳定归一化；新增 root identity 与 clipboard boundary 回归测试。剩余差距仅是原生 FileSystemTree/CopyProvider/DataContext 生命周期和 UI automation。

2026-08-25 Update Project rebase-over-merge 对照补齐：参考 `GitRebaseOverMergeProblem` 与 `GitUpdateProcess`，Arbor 的 Update Project 在 Rebase 方法下先为每个 configured upstream fetch，再按 `base..current` 检查具有实际 first-parent 树差异的 merge commit。命中后显示 `Merge Instead` / `Rebase Anyway` / `Cancel` 三路决策；选择 Merge Instead 只把命中的 root 替换为 merge，其余 root 继续 rebase，且已 fetch 的 refs 直接复用于正式更新。选择的 root 方法会进入失败 Retry 的 Codable semantic action 并跨重启保留。剩余差距收敛为原生 DialogWrapper/DataContext/VcsNotifier 生命周期、原生 UI automation，以及更完整的 compound post-action 编排。

2026-08-25 `Git.CreateNewTag` 对照补齐：参考 `GitTagDialog` 的 existing-tag 校验与 `Force` 选项，Arbor 的 New Tag / Log commit tag 对话框现在允许用户显式选择 `Replace existing tag`。默认创建仍使用 `MustNotExist`；选中后 lightweight tag 通过原子 ref transaction 覆盖，annotated/signed tag 通过 `git tag --force` 覆盖，并新增 lightweight 与 annotated message/target 回归测试。无效 revision、签名失败或未勾选 force 的重复 tag 不会改变原有 tag，错误继续进入 FeedbackCenter。剩余差距收敛为原生 DialogWrapper/DataContext/VcsNotifier 生命周期和 UI automation，而不是 tag 覆盖功能本身。

2026-08-25 子模块 path-scoped Update 对照补齐：对照 `GitSubmoduleUpdater.isSaveNeeded()` 与 `doUpdate()`，SubmodulePanel 每个已初始化且状态可更新的子模块现在提供单行 `Update`；它从 superproject 执行 `git submodule update --recursive -- <path>`，不会先 Pull 父仓库。Rust updater 会按递归后代最深层优先保存 dirty worktree，并按项目 Git Settings 的 Stash/Shelf 策略在更新后逆序恢复；每个受影响 root 现在写入 durable `submodule-update` apply marker，正常恢复后清理，崩溃或恢复冲突则由现有启动扫描和 Git Roots conflict workbench 提供 `Resolve local changes` / `View saved changes…`；已有 Operation Log retry 继续携带 path、recursive 选项和稳定通知 identity。未初始化、missing、conflict、unknown 行 fail-closed，必须使用顶部带 init 的全局 Update。新增 nested submodule fixture 覆盖父仓库不变、stash/Shelf 恢复、path-scoped update 和恢复冲突 marker；剩余差距是 native VFS/permission/banner、原生 VcsNotifier/DataContext 生命周期和 UI automation。

2026-08-25 Log Changes Browser gitlink 选区对照补齐：对照 `GitDropSelectedChangesOperation.restoreChanges()` 的路径级恢复语义，Drop/Extract Selected Changes 现在允许把已选中的 submodule gitlink 当作一个 Git 路径改写；Drop 会把嵌套 worktree 同步到 first-parent 的 gitlink commit，Extract 保留“剩余变更提交 → 完整目标树新提交”的 gitlink 拓扑。父仓库 stash 构造也保留 gitlink，不再把嵌套目录当 blob 读写；Drop/Extract 在保存现场前检查递归 nested worktree，脏子模块 fail-closed，避免静默丢失本地修改；Update Project 的 ignored submodule paths 继续由父先更新、子后更新，避免父侧提前 checkout 尚未 fetch 的 gitlink。SwiftUI action gate 已同步放开 gitlink，恢复冲突现在写入 durable `history-rewrite` marker 并由 root conflict workbench 接管。新增真实初始化 submodule 的 Drop/Extract、dirty nested refusal、restore-conflict marker 回归。仍然不支持目录级选区、全选、无法安全重放的原生冲突对话框，以及完整 native VcsNotifier/DataContext/UI automation。

2026-08-25 Commit and Push 预览策略校正：对照 `GitPushAfterCommitDialog.showOrPush()`、`GitVcsSettings.shouldPreviewPushOnCommitAndPush()` 与 `previewProtectedOnly`，Arbor 现在提供全局和项目级三种策略：总是预览、仅保护分支预览、自动 Push；默认仍为总是预览。single-root 与 multi-root 都在提交成功后才执行第二阶段，并在 transport 前做只读 preflight：只有存在唯一可无歧义 remote 且当前 HEAD 附着在 branch 上时，自动策略才直接 Push；无 remote、多个未选择 remote、游离 HEAD 或空仓库都会回到显式 Push options。`protectedOnly` 使用当前项目的 protected-branch patterns，`automatic` 也不会隐式启用 force push。Commit 失败、partial commit 和取消不会启动 Push；Push rejected recovery 保留 “Commit completed; Push rejected” 上下文。剩余差距是 IntelliJ 原生 `VcsPushDialog`/`VcsNotifier` 生命周期、多 root 更深的 compound rollback/post-actions 与 UI automation。

2026-08-25 Git Tasks 进度面板对照校正：对照 IntelliJ `ProgressWindow`/状态栏任务入口，运行中的 Git 操作现在可从状态栏进入 Operations 工具窗的 `GitTasksView`；面板显示 operation name、Git transport phase/percentage、multi-root/batch completed/total、同一进程组取消句柄，以及最近完成的操作。Fetch、Pull、Push、Update Project、Merge、Rebase、Checkout、Reset 的多 root runner 还会发布当前 root、root path/name、已完成 root/总 root 和 completed/skipped/failed/paused state，状态栏保留当前 root 名称；嵌套 system-Git 命令结束后恢复外层 root 快照。Merge/Rebase 的 gix 阶段没有 Git stderr transport percentage，因此保持 indeterminate progress；历史详情仍进入共享 `OperationLogView`，不产生第二套状态源。剩余差距是重试策略、并发任务队列、其它自定义 runner 的完整 root 实时聚合，以及原生 ProgressWindow/VcsNotifier/DataContext 生命周期和 UI automation。

2026-08-25 Branches Popup repository-scope 交互校正：对照 `GitDefaultBranchesPopupStep.onChosen(RepositoryNode)`，multi-root Branches Popup 点击仓库节点现在进入明确的 repository-scoped 第二层模型；顶部显示当前仓库与“返回全部仓库”，返回时恢复进入前的 speed-search，Esc 在 scope 内先返回仓库列表、再次 Esc 才关闭整个 popup。失效 root、关闭 `Filter by Repository` 和键盘 Enter 复用同一退出/进入路径。剩余差距收敛为真正的原生 Swing nested popup、DataContext/action group 生命周期与 UI automation，不再把“点击仓库只改变同层过滤”列为已实现。

2026-08-25 Log `Highlight Cherry-Picked Commits` 语义校正：对照 `CherryPickedCommitsHighlighter.getStyle` 与 `HighlightCherryPickedCommitsAction`，高亮现在只接受完成的 branch-aware `git cherry` patch-equivalence 结果；比较进行中、结果为空或比较失败时不再退回 commit-message trailer，避免把无关提交误标为已 cherry-pick。multi-root 比较菜单同时显示已完成 root/总 root，旧 generation、source branch 或 Log generation 结果仍 fail-closed。剩余差距是 IntelliJ 原生进度/通知生命周期、索引级 comparator 优化与 UI automation。

2026-08-25 `Git.OpenExcludeFile` linked worktree 路径校正：对照 `OpenGitExcludeAction`，打开 repository-local exclude 时现在使用 Repository 暴露的真实 Git administrative directory，并解析 linked worktree 的 `commondir`，因此不会把 `.git/worktrees/<name>/info/exclude` 误当成公共 exclude 文件；普通仓库和异常/缺失 `commondir` 仍回退到当前 administrative directory。新增路径级回归测试。剩余差距是原生 `OpenFileDescriptor`/DataContext 生命周期与 UI automation。

2026-08-25 Log Branches dashboard selection action 校正：对照 `BranchesDashboardTreeController` 与 `BranchesTreeSelection.selectedBranchFilters`，`Filter Log` / `Navigate Log` 现在不再只响应普通单击；Cmd 多选和 Shift 范围选择也会立即执行当前选择模式。Filter 模式只把 local、remote、HEAD 转为 root-qualified branch filters，去重并排除 tag；tag 仍可在 Navigate 模式跳转。single-root 与 multi-root 面板共用同一语义。新增 root-qualified、多选、tag 排除回归测试。剩余差距是原生 `TreeSelection`/DataContext/action 生命周期与 UI automation。

2026-08-25 `Git.Rebase` action-update 校正：参考 `GitRebase.update()` 的 project-wide no-reentry 与 repository-state 边界，VCS 菜单 `Rebase…` 现在读取当前 root 与 `loadMultiRoots()` 返回的全部已发现 root；任一 root 进入 rebase operation state，或项目已有 multi-root rebase session 时隐藏并拒绝 action；若没有 `NORMAL/DETACHED` root 则保留入口但禁用。新增 secondary-root 与全 root busy 的 root-qualified action context 回归测试；state 刷新时序、原生 `ActionUpdateThread`/DataContext 生命周期与 UI automation 仍为 partial。

2026-08-25 `Git.Fetch` action-update 校正：参考 `GitFetch.update()`，Fetch、Fetch All、分支级 Fetch、Prune 和 Unshallow 现在共享显式的传输 busy boundary；执行中入口保留但禁用，VCS 菜单、Quick Actions、Branches Popup 与直接 handler 均 fail-closed，避免重复启动 Fetch 并覆盖当前反馈/认证状态。当前仍缺原生 `GitFetchSupport.isFetchRunning()` 的任务注册、完整 VcsNotifier/DataContext lifecycle 与 UI automation；本轮只收口产品范围内可观察的 action presentation 和安全边界。

2026-08-25 `Vcs.UpdateProject` action-update 校正：参考 `AbstractCommonUpdateAction`，Update Project 现在在任意后台 VCS operation 或 multi-root runner 进行时保留入口但禁用；VCS 菜单、通知 handler 与 options dialog 确认后的实际执行入口共享 fail-closed guard，避免重复启动 Update 覆盖当前恢复/反馈状态。原生 `VcsManager.isBackgroundVcsOperationRunning`、DataContext/VcsNotifier lifecycle 与 UI automation 仍为 partial。

2026-08-25 `Git.Pull` dialog 补齐：对照 `GitPull` / `GitPullDialog`，VCS 菜单的 Pull > Merge/Rebase 现在先选择 Git root、remote 和 remote-tracking branch，再以 `PullOptions` 执行；`ff-only`、`no-ff`、`squash`、`no-commit`、`no-verify` 的互斥组合和项目级持久化选项已接通，Fetch 按钮会刷新所选 root 的 remote refs。Pull dialog、确认入口和 selected-root runner 共用 no-reentry guard；selected secondary root 现在通过 root-local `pull` preservation marker 使用项目 Shelve/Stash 策略，成功自动恢复，冲突后由 Merge/Rebase Continue/Skip/Abort 完成恢复，并由项目级 conflict workbench 按 root 重建。仍是真实差距的是原生 DialogWrapper/VcsNotifier/DataContext 生命周期。

2026-08-25 `Git.Merge` action-update 校正：参考 `GitMerge.update()` 的 project-wide no-reentry 与 repository-state 边界，VCS 菜单 `Merge…` 现在读取当前 root 与 `loadMultiRoots()` 返回的全部已发现 root；任一 root 进入 merge operation state 时隐藏并拒绝 action；若没有 `NORMAL/DETACHED` root 则保留入口但禁用。分支弹窗、侧栏和 Rebase 的直接入口也增加当前 root operation guard，不能绕过 action presentation 启动新的写操作；secondary-root state 刷新时序、原生 `ActionUpdateThread`/DataContext 生命周期与 UI automation 仍为 partial。

2026-08-24 Compare Branches 游标分页校正：两侧 unique-commit pane 不再以“当前已加载数量 + 200”从 range 起点反复重查，而是把上一页最后一条提交作为 Rust log cursor，按每侧独立的 80/200 条页面继续读取。过滤条件、range、graph lane、去重、generation/root/filter stale guard 均保持不变；620 条历史的引擎回归验证单次请求不再受 500 条上限影响。剩余差距仍是 IntelliJ permanent VCS Log manager、native DataContext/action-group lifecycle 与 UI automation。

2026-08-24 Update Project 方法选择校正：参考 `GitVcsOptions.updateMethod`，项目 Git Settings 现在持久化 Merge/Rebase 选择，默认 Merge；Update Project（⌘T）和多 root 更新 runner 都读取该设置，显式 Pull > Merge/Rebase 仍保持独立。剩余差距是 IntelliJ 原生 `GitUpdateOptionsDialog`、DataContext/VcsNotifier lifecycle 与 UI automation。
2026-08-24 Update Project 保存策略校正：参考 `GitVcsSettings.saveChangesPolicy`，Project Git Settings 现在可以按项目覆盖全局 Shelf/Stash 选择；dirty Pull/Update preservation 以及现有 Rebase、Merge、Reset、Checkout 和 force-pushed update runner 都读取项目策略，未覆盖时继承全局设置。剩余差距是原生 GitVcsSettings/DataContext lifecycle、完整设置自动化和少数 native action surface。

2026-08-24 Log 多选历史改写校正：Reword/Squash 现在保留用户选择顺序去重，并在后台用 Git 可达性求出唯一共同最老选中提交作为 rebase 起点；非连续、反序选择不再因 Dictionary 顺序选到较新的起点而遗漏旧提交，非线性选择则 fail-closed。该修正覆盖多选 Reword/Squash 的准备阶段，不改变 Drop 的直接执行路径。

2026-08-24 Log 多选 root 改写补齐：选中初始提交的 Reword/Squash/Drop 现在先显示 IntelliJ 风格 Continue/Cancel 警告；Reword/Squash 使用真正的 `rebase --root` todo，Drop 也使用 root todo 执行并保留现有本地现场/Undo 边界。merge-preserving 和完整 VcsNotifier/UI automation 仍是独立长尾。

2026-08-25 Log root Reword 的 merge topology 补齐：非 HEAD root 现在先生成 `rebaseRootTodo(preserveMerges: true)`；当当前 root 历史包含 merge descendant 时，只把选中的 root 行改为 `reword`，再通过已有的 `rebaseRootWithTodoAndPolicyAndCancel` 执行，从而保留 merge parents、原生拓扑和项目级 Shelf/Stash 本地现场策略。无 merge descendant 的线性历史继续使用轻量 `rewordRootCommit`，HEAD amend 路径不变；新增 Swift todo-preparation 回归覆盖“只改 root 行、保留 merge 行”和缺失 root fail-closed。剩余差距是跨 root 原子通知/撤销、完整 in-memory 语义和原生 VcsNotifier/UI automation。

2026-08-23 多 root 结果树补齐一条横向缺口：通用 Fetch All、Pull All (Merge) 与 Pull All (Rebase) 完成后，会把 Rust 的逐 root `RootOperationResult` 映射为可持久化的 `FeedbackResultRow`，并挂到同一稳定 notification ID 的 Operation Log 条目；详情视图按执行顺序显示仓库名、root path、success/skipped/failed 状态和原始原因，旧历史缺少该字段时仍可兼容读取。该能力没有被扩大解释为完整 IntelliJ `UpdateInfoTree`：Push、Commit、Merge、Rebase、Shelf 等自定义 multi-root runner 尚未全部接入，原生 VcsNotifier/DataContext 生命周期和 UI automation 仍是差距。
2026-08-23 Apply Patch 入口对照校正：参考平台 `ApplyPatchFromClipboardAction`，VCS > Git 现在同时提供从文件和从剪贴板导入补丁；剪贴板来源先做文本/补丁路径识别，再进入与文件来源完全相同的 differentiated 文件/hunk 选择、目标 Changelist、base/path-strip、direct apply、冲突完成/回滚和 dirty-scope 刷新链路，不会绕过 review 直接写 worktree。剩余差距仍是完整 VFS/PSI FilenameIndex、Recently Deleted action/notification model 与原生 UI automation，而不是剪贴板入口本身。
2026-08-23 Shelf 批量结果树补齐：对照 `ShelveChangesManager.unshelveSilentlyAsynchronously`、`RestoreShelvedChange` 和 `MyShelveDeleteProvider` 的逐列表结果语义，active Shelf 的批量 Apply/Pop/Drop，以及 Recently Deleted 的批量 Restore/Permanently Delete，现在把每个选中 Shelf 的 success/failed/skipped、root scope、目标 Changelist、冲突或失败原因作为持久化 item rows 附到同一稳定 Operation Log/native notification；重启后结果树与 Retry/Undo action 仍共存。该改动只扩展 presentation snapshot，不把 item row 当作 Retry 安全依据；剩余仍是原生 ShelvedTreeModel/DataContext/DeleteProvider 生命周期、更细 VcsNotifier 分组和 UI automation。
2026-08-24 Shelf differentiated apply 继续补齐：revision-backed active/Recently Deleted Shelf 的用户可见 Unshelve、选中成员、hunk 选择、Changelist drop 与批量 Apply 现在进入逐文件 patch executor，Rust 返回成员级 `Success` / `Partial` / `AlreadyApplied` / `Skip` / `Failure` 聚合状态；普通失败成员恢复并留在 remainder/Recently Deleted，冲突持久化 worktree/index 快照，完成后只消费已应用或已解决冲突成员并恢复原始 index 边界。Swift 的单 Shelf、批量 Shelf、成员批处理和 Operation Log file-member children 使用结构化状态，不再从“没有抛错”推断成功。对照 IntelliJ `PatchApplier` 后，direct Apply Patch 已接入 `GitCancelHandle`：取消或取消后续 apply 会先恢复精确 worktree/index，再返回成员级 `Abort` 并在 Operation Log 显示 aborted；invalid patch 预检继续 fail-closed 且不创建恢复快照。MatchPatchPaths 的 VFS/FilenameIndex 生命周期、原生 ApplyPatchViewer/ShelvedTreeModel/DataContext、通知分组和 UI automation 仍是 partial。
2026-08-24 内部 preservation Shelf 恢复也完成了一轮 parity 收口：Smart Checkout、Checkout+Update、Pull/Update、Rebase 等保存本地改动的 revision-backed Shelf，现在在恢复阶段使用独立的 differentiated `git apply --3way` 策略；无冲突文件逐项恢复，普通失败保留完整临时 Shelf 以便重试，冲突继续落入持久化 resolver。内部 apply 会识别空 patch（例如父 root 只包含嵌套 Git root），并在 clean/冲突完成时恢复保存前 staged/unstaged index 边界；Smart Checkout、Pull/Update 和主要 Rebase/Checkout-with-Rebase 入口的 preservation Shelf 恢复现在接入 `GitCancelHandle`：取消会回滚当前 apply、保留 Shelf/临时 index snapshot，取消发生在保存之后但尚未开始 Git 操作时则恢复原始工作区；Pull Stash 恢复现在也支持开始前取消并保留 Stash，gix 变更开始后保持完整恢复；raw-todo/editor 已接入共享 native Git process cancellation。剩余差距是多 root native control-row/editor lifecycle、MatchPatchPaths 的 VFS/FilenameIndex lifecycle、原生 ApplyPatchViewer/ShelvedTreeModel/DataContext、通知分组和 UI automation。
2026-08-23 多 root 结果树继续扩展：Push All 及 Push 被拒绝后的 Update with Merge/Rebase recovery 现在也把每个 `RootOperationResult` 挂到对应稳定 notification ID 的 Operation Log 条目；Push 的 Retry、Force Push、Update recovery、View Commits 等 semantic actions 与结果树共存，结果树仍只是展示快照，不替代 root-scoped CAS/retry 安全上下文。Commit、Merge、Rebase、Shelf 等自定义 runner 尚未全部接入，仍不宣称完成 IntelliJ `UpdateInfoTree`、原生 VcsNotifier/DataContext 生命周期或 UI automation。
2026-08-23 多 root 结果树继续扩展：Commit All/Commit Selected 及 Commit checks failed 的可恢复终态现在也把每个 `RootOperationResult` 挂到稳定 commit notification ID 的 Operation Log 条目；Retry Failed Commits、Commit Anyway、Commit and Push、GPG 配置和 Reword actions 与结果树共存，结果树仍只是展示快照，不替代 root-scoped retry/签名安全上下文。Merge、Rebase、Shelf 等自定义 runner 尚未全部接入，仍不宣称完成 IntelliJ `UpdateInfoTree`、原生 VcsNotifier/DataContext 生命周期或 UI automation。
2026-08-23 多 root 结果树继续扩展：multi-root Merge 的成功、部分失败、冲突暂停和 Smart Merge 决策现在也把每个 `RootOperationResult` 挂到稳定的初始 Merge notification ID；Rollback Successful Roots 与 Delete-on-Merge 使用独立 ID，后续生命周期更新不会抹掉原始 Merge 结果树。结果树仍只是展示快照，不替代 merge rollback 的 expected-HEAD/CAS 安全上下文。Rebase、Shelf 等自定义 runner 尚未全部接入，仍不宣称完成 IntelliJ `UpdateInfoTree`、原生 VcsNotifier/DataContext 生命周期或 UI automation。
2026-08-23 多 root 结果树继续扩展：multi-root Rebase 的已有 session 状态现在也会在暂停、部分失败和完成终态映射为 root-qualified rows，并挂到稳定 Rebase notification ID；pending/paused/completed/failed root 会在 Operation Log 中保留同一 session 的可读状态。结果树仍只是展示快照，不替代 Rebase session、expected-HEAD、Stage-and-Retry 或 Undo 的安全上下文。Shelf 等自定义 runner 尚未全部接入，仍不宣称完成 IntelliJ `UpdateInfoTree`、原生 VcsNotifier/DataContext 生命周期或 UI automation。

2026-08-23 `.gitattributes` textconv 对照校正：Diff 预览在用户显式开启 Git external conversion 设置、且文件属性解析为 `diff=<driver>` 时，现在调用统一 Git runner 执行 `git diff --no-ext-diff --textconv`，支持普通/二进制 textconv 输出、空结果、10 秒超时和 Index↔Worktree 反向只读展示；同一契约已扩展到 revision↔revision、commit、rename 的双 object endpoint、revision-backed active/Recently Deleted Shelf、Stash 结构化文件预览，以及同路径和跨路径 rename 的 revision↔worktree 预览，并保留旧 FFI 包装的默认行为。跨路径 rename 通过临时 `GIT_INDEX_FILE` 映射旧 blob，真实 index/worktree 不变。默认仍不执行；`diff.<driver>.command` 不会被隐式调用，外部工具仅由单独的显式 External Diff 动作负责。剩余是 raw patch/export 仍保持原始补丁语义，以及大仓库转换结果缓存。

2026-08-25 Diff Viewer external difftool 对照校正：参考平台 `ExternalDiffTool` 的显式打开语义，当前 Diff Viewer 新增 `External Diff`，按 active two-side comparison 调用 `git difftool --no-prompt --tool <configured>`；`diff.tool` 优先，`diff.guitool` 作为回退，未配置时直接给出设置提示而不进入 Git 的首次交互式 tool picker。工作区↔index、index↔HEAD、HEAD↔worktree、反向 Local→Staged、rename 与 untracked `--no-index` 均通过独立 argv 和 `--` path separator 传递；运行中的 Git/difftool 进程可由 Diff Viewer 取消，取消会终止整个 process group，并受 Diff generation guard 保护。剩余差距是 IntelliJ 的按文件类型 ExternalDiffSettings、完整 DiffManager/DataContext lifecycle 与 UI automation；任意 `diff.<driver>.command` 仍不被隐式执行。

2026-08-23 Git Checkout action group 对照校正：参考 `GitCheckoutActionGroup`，Log 单提交右键现在把该提交上的非当前本地分支与 detached `Checkout Revision <short-hash>` 放入同一个 Checkout group；多个本地候选时展开分支列表，无候选时使用直接 revision action。分支和 revision 仍分别复用 root-qualified checkout 与 Smart/Force/Cancel recovery；无法解析 root、存在活动操作或 mutation 被禁止时 fail-closed。剩余差异是原生 DataContext/action-group 生命周期与 UI automation，不再是 Checkout group 缺失。

2026-08-23 Navigate Log 对照校正：参考 `NavigateLogToSelectedBranchAction`，分支 dashboard 导航现在先在所属 Git root 解析 branch HEAD，再让异步 Log 加载按完整 commit id 恢复选择；不再因提交时间排序、刷新或分页而误选日志第一页首行。若 HEAD 因当前过滤条件不可见，仍安全回退到首个可见提交；原生 action-group enablement、DataContext 生命周期和 UI automation 继续保持 partial。

2026-08-23 Git Log Command 对照校正：参考 `ShowGitLogCommandAction` 与 `GitLogCommandFilterer`，命令 Log 现在对当前可见 Git roots 分别执行并合并，跨 root 的相同 object ID 保持 root-qualified，且不绘制会制造错误父子关系的跨仓库 graph lane；无显式最大数量时按 500 条继续加载，`--max-count`/`-n`/数字短参数会停止继续收集；command、tab、root 和 visible-root 变化会丢弃旧结果。剩余差异是 IntelliJ 原生永久图/过滤器组件与 UI automation，不再是多 root 命令过滤或固定首屏上限缺失。

2026-08-23 Push All 通知生命周期校正：项目级 Push All 的终态现在继续更新初始 Push notification ID，即使结果包含 non-fast-forward 并附带 Update with Merge/Rebase；点击后启动的 Push recovery 才使用独立的 recovery notification ID。这样失败后的后续动作仍附着在原 Push 结果上，不会留下孤立的 Working/partial 历史项。Cherry-picked 高亮菜单也会显示 Compare Branches 的实际另一侧 target，并在未选择 source branch 时禁用启用开关，避免静默无效。

2026-08-23 Log Changes Browser Create Patch 对照校正：参考平台 `CreatePatchFromChangesAction`，Changes Browser 现在对选中的变更记录生成或复制 Patch，而不再只能导出整条 commit；按 commit/parent/root 分组执行 revision diff，rename 会同时传递 old/new path，混合 merge parent 或重复路径直接禁用，避免普通 Patch 文件丢失版本顺序。整条 commit 的原有导出入口仍保留；剩余差异是原生 Changes action/DataContext、DiffManager 与 UI automation。

2026-08-23 Diff Viewer Patch 对照校正：参考平台 `DiffViewerCreatePatchActionProvider`，状态 Diff 查看器现在提供 Create Patch / Copy Patch；工作区、暂存、Local→Staged 反向比较、untracked 以及任意两个 revision 均由独立 argv 调用 Git 原生 `diff` 生成补丁，rename 保留 old/new path，untracked 正确接受 `--no-index` 的退出码 1。剪贴板文本比较、三栏比较和 blame 没有完整 Git revision pair，因此动作明确禁用；剩余差异是原生 DiffManager action lifecycle 与 UI automation。

2026-08-23 VcsNotifier 原生分组校正：`toolWindow`/`silent` 反馈现在只保留在 Arbor 的 Git 工作区/Operation Log，不再误发 macOS banner；`standard` 使用无声音 banner，`important` 使用带声音 banner；同一 notification group 共享 macOS thread，而 stable notification ID 继续负责单个操作的替换。剩余差异收敛为系统通知权限、原生通知 action 生命周期和 UI automation，不再是通知组本身没有映射。

2026-08-23 原生通知 action 可恢复性校正：系统通知现在只暴露带 Codable semantic request 或已有明确标题 fallback 路由的 action；仅依赖当前进程闭包的 FeedbackCenter action 仍保留在 Arbor 的工作区/Operation Log，但不会生成重启后无效的原生通知按钮。过滤后的 action 顺序同时用于通知 category、持久化 userInfo 和当前进程 action 表，避免跨重启 fallback 与进程内闭包索引错位。剩余仍是系统权限、原生通知生命周期和 UI automation，而不是 action 可恢复性本身。

2026-08-23 Patch base 推导矩阵校正：`MatchPatchPaths.workWithNotExisting` 对“新文件及其末端目录尚不存在”的路径反向匹配已经由 `RebasedPatchFilenameIndex` + `discoverBaseMappings` 覆盖，并有同名候选回退 project root 的回归测试；矩阵该项改为 `verified-partial`。剩余是删除/失效候选、完整 VFS/PSI FilenameIndex 生命周期和 IDE 索引通知，不再是末端目录缺失时的基本 base/path-strip 推导缺失。

2026-08-23 歧义目录 rename 对照校正：`Review ambiguous Git moves` 现在按每个新端点提供一个选择控件；唯一候选默认选中，多候选默认 `Skip`，不再用可能同时选中多个旧端点的独立复选框。提交 Git Add/Remove 前还会强制旧端点与新端点一对一，避免同一文件被重复消费或把歧义猜测写进 index。剩余差异收敛为 IntelliJ 原生逐文件 operation-state、VFS permission/banner、精确 action history 与 UI automation。

2026-08-25 `Git.MainMenu.LocalChanges` 对照校正：参考 fork 的 `Git.MainMenu.LocalChanges` 明确注册 `ChangesView.Shelve`、`Vcs.Show.Shelf`、`Git.Stash`、`Git.Unstash`，而 Arbor 之前只有平铺的 Stash/Shelve/Apply Patch，且 Unstash 仅存在于 Quick Actions/分支弹窗。本轮新增 Local Changes 子菜单、Show Shelf 页签路由、VCS 菜单 Unstash，以及 selection-scoped `Revert Selected Changes…`；Revert 只接受当前 Commit/Stash、Diff 或 Project 的单个已跟踪、非冲突且存在于 HEAD 的选区，Shelf 页签激活时自动禁用，并在 Git operation 进行时禁用，复用从 HEAD 同时恢复 index/worktree 的实现。Apply Patch 保持与该 group 同级。同步补齐 `Git.ResolveConflicts`、`Git.CreateNewWorkingTree`/`Git.Show.WorkingTrees` 与 `Git.Configure.Remotes` 的主菜单直达入口，均复用已有状态模型。多选 ChangesView/DataContext 语义、原生 action lifecycle/UI automation 继续保留 partial。

2026-08-23 外部 VFS Git action lifecycle 校正：Add、staging-area empty-blob Add、Remove 和 case-only force move 现在共用一个执行 runner；失败反馈保留本次用户已确认的相对路径与 move 对，并通过同一稳定 notification ID 提供可持久化的 `Retry External Git Action`。Retry 会重新校验 root containment 与路径安全，再刷新所属 root；不会持久化未经确认的原始 watcher 事件。剩余是 IntelliJ 原生逐文件 operation-state、permission/banner、完整 action history 聚合与 UI automation。

## 2026-08-23 对照校正：当前真正缺少的能力
本轮还补齐了 aggregate 认证恢复：Push/Push recovery、Fetch/Pull 和 Update 的逐 root 认证错误现在沿用单 root 的分类规则，进入已有 GitHub token 配置入口；引擎返回 partial result 或在 Fetch/Pull 结果聚合前直接抛出认证异常时，都不再静默跳过认证恢复。Fetch/Pull 的 catastrophic failure 也会保留 root-scoped Retry action，并携带已存在的 Pull revision ranges。

2026-08-23 Submodule Add Undo 对照校正：参考 IntelliJ 的可恢复操作边界，SubmodulePanel 的 Add 成功后现在只在父 HEAD、`.gitmodules` 完整字节、160000 gitlink、子模块 clean checkout 和无 tracked/untracked/ignored nested 文件均未漂移时发布 root-scoped `Undo Submodule Add`。Undo 通过 Rust 原生 submodule deinit + index removal 恢复 pre-add `.gitmodules`，并把取消、失败或恢复不一致保留为可重试 semantic action；占用路径、后续 nested 文件、HEAD/gitlink/`.gitmodules` 漂移均 fail closed，不提供无条件删除。


本轮重新逐段阅读参考 fork 的 rebase/Shelf/submodule/VFS 实现，并把“参考实现确实存在的 Git 能力”与“IntelliJ 平台生命周期差异”分开。single-root 与 multi-root 的 native todo fallback 已补齐；Git Roots 的 Fetch/Pull 复合入口也已具备逐 root partial result、失败/取消重试和稳定 Operation Log history；当前仍有以下优先级：

2026-08-23 Log/status 持久化首屏缓存校正：single-root 与 aggregate multi-root Log 现在按 Git root 保存最近一次首屏结果；缓存记录包含 schema、规范化 root、完整过滤/分页 query fingerprint，以及 local/remote/tag/current-HEAD 的完整 tip refs token。重启或刷新时只有 root、查询和 refs 全部一致才先展示 snapshot，随后仍由 Rust fresh query 作为权威结果；任一校验失败、缓存损坏或 fresh 读取失败都会 fail-closed，并在已有 snapshot 时明确提示正在展示缓存历史。Commit workspace 同时按 Git root 保存 display-only status 快照（双维度 FileEntry + Changelist）；重启先展示缓存并显示刷新状态，fresh status 完成后立即覆盖，缓存不参与任何 Git 操作安全判断。Rust 已提供 root-scoped live all-ref graph/index；完整 IntelliJ `VcsLogManager`/`VisiblePackRefresher` lifecycle 仍未宣称完成。

2026-08-23 Shelf 根路由校正：Commit/Shelf 工作区有 Git root 选择器；secondary root 的 active/Recently Deleted Shelf 由所属 Repository 独立读取，raw patch、结构化文件 diff 预览和目标 Changelist 列表都绑定 root identity，并在 root/name/deleted-state 不一致时丢弃异步结果。Rename、整 Shelf Drop（含 root-scoped Undo）、Recently Deleted 整 Shelf Restore/Delete、整 Shelf Apply/Pop/Unshelve、成员级 Apply/Drop/永久删除、批量 DeleteProvider 与跨重启 Retry、target-Changelist Unshelve 对话框、Patch Import/Export、Clear Already Unshelved 已通过 selected-root mutation context 写入所属 Repository，并使用 root-scoped notification/semantic action；Conflict workbench 的 secondary status/完成/回滚已接线，但原生 DataContext/通知生命周期仍未完全对齐，完整非 primary Shelf parity 与 UI automation 仍是 partial。

本轮还修正了 Commit and Push 的部分成功通知生命周期：从“Push Committed Roots”进入 Push 时不再 expire 仍包含“Retry Failed Commits”的 Commit 通知；两套 root-scoped semantic action 现在可同时保留并跨重启恢复。普通 Push 仍按原规则清理已解决的 Commit 通知。

2026-08-24 Cleanup Branches 表格对照校正：参考实现的 Branch Name、Last Commit Date、Tracked Branch、Merged Status 四列现在在 SwiftUI 中保持独立列对齐；此前 tracking 分支被嵌在 Branch 单元格内，虽不影响删除安全性，却偏离了 IntelliJ 的表格交互模型。原生 JTable 的 CopyProvider/DataContext 生命周期和 UI automation 仍是独立长尾。

2026-08-24 Find Merged/Cleanup 扫描校正：参考实现使用最多 5 个 worker 并行比较候选；Arbor 现在将两个多 root 入口统一到最多 5 个 root 的有界批次扫描，完成结果按 root 输入顺序重排，失败 root 保留具体错误，取消在批次边界保留已完成结果；engine/API 同时硬排除 target 分支。当前仍未宣称 IntelliJ 的 VCS Log index fast/reliable comparator，仍使用 Git cherry patch-equivalence 作为语义兜底。

1. **P1：复合操作的统一后续动作。** 子模块 add/update/sync/deinit/remove、嵌套 Log、Push、credential/cancel、依赖顺序、gitlink 与嵌套提交范围/文件级联合 diff，以及 standalone Update 的 expected-HEAD Undo 已具备；Add/Deinit/Remove 现在仅在 parent HEAD、gitlink、`.gitmodules` 精确快照和 clean/空工作树边界内提供可持久化 expected-state Undo，状态漂移或后续文件会 fail closed；Git Roots Fetch/Pull、Push、Commit 和独立 SubmodulePanel 操作已具备 root-scoped/operation-scoped partial result、失败/取消 Retry 与 stable notification history。单 root Push 现在把 IntelliJ 的 `REJECTED_STALE_INFO` 作为 Rust 结构化错误分类，并在稳定通知中提供带 protected-branch 二次校验的 `Force Push Anyway`，同时保留 Push dialog 的 tag/hooks 参数穿过 Merge/Rebase recovery；项目级 Push All 的成功/部分成功通知现在按 local tip 与 tracked upstream tip 的 merge-base → local tip 范围提供可跨重启的 `View Commits`，首次发布、tag-only 或 unrelated-history root 没有安全旧边界时省略；项目级 Commit and Push 已补齐“先按 root 提交、再只推送实际成功 root”的后续动作与跨重启 Push action；仍缺非 Update 场景的 Submodule/Push/Commit 更深的 compound rollback/post-actions 与更完整的通知分组。
2026-08-23 Commit success post-action 校正：对照 `GitCommitSuccessNotificationRewordProvider`，single-root 与 multi-root Commit 的成功/partial feedback 现在附带 root-qualified `Reword Commit` semantic action；请求携带项目、Git root 与完整 commit id，重启后重新打开对应 root 的 Log 和现有 Reword dialog。执行前后都检查该 commit 仍是当前 root HEAD；root commit 进入已有的初始提交确认流程，HEAD 漂移、root 不可用或对象消失时 fail closed。Codable round-trip 与 FeedbackCenter/Operation Log reload 已覆盖；批量跨 root 原子 reword、原生 VcsNotifier 生命周期和 UI automation 仍是 partial。

2026-08-23 Reword 成功撤销校正：对照 `GitCommitEditingOperationResult.Complete` 与 `GitCommitEditingNotifications`，HEAD/Root Reword 成功通知现在附带 root-qualified `Undo Reword Commit` semantic action。上下文保存初始 HEAD、改写后的 expected HEAD 和 branch identity（detached 用空 branch），Undo 先拒绝活动 Git operation、HEAD/branch 漂移和 protected remote reachability，再通过 Rust `restore_head_ref_if_expected` 只恢复 ref，不触碰 index/worktree；成功后刷新所属 root，失败以同一稳定通知 ID fail closed。Rust 覆盖 staged/local scene 保留与二次 stale CAS 拒绝，Swift 覆盖 attached/detached Codable reload；跨 root 原子撤销、完整 native VcsNotifier 生命周期和 UI automation 仍是 partial。

2026-08-23 Rebase Undo 安全边界校正：对照 IntelliJ `GitCommitEditingOperationResult.checkUndoPossibility()`，现有单 root Rebase Undo 在改写开始前对显式 onto/upstream（包括普通 Pull/Rebase 解析出的 configured upstream）计算并持久化改写范围内最早的 changed commit，完成后 `reset --keep` 前增加活动 Git operation 检查、branch/expected HEAD CAS 与 protected remote reachability 检查；旧 payload、root rebase、无法解析共同祖先或 range 的场景仍通过 `merge-base(oldHead,newHead)` 保守回退到旧 HEAD。保护锚点会穿过 seed、Undo target、Codable semantic action 和重启恢复。失败会用同一稳定 notification ID 替换原 Undo action，避免继续暴露已失效动作；跨 root 原子 Undo 和完整 native VcsNotifier/UI automation 仍是 partial。

2026-08-23 Multi-root Rebase Undo 边界校正：现有 multi-root rebase 的每个 root 已有 expected-HEAD rollback，本轮在每个 root 开始改写前按 onto/upstream 记录最早 changed commit，并在 ref rollback 前增加 active Git operation 与 protected remote reachability 检查；旧 session 或无法解析范围的 root 仍使用 old/new HEAD 的保守 fallback。回滚启动、成功、部分失败均复用 multi-root 稳定 notification ID，部分失败只保留未完成 root 的 Undo semantic action。跨 root 仍是逐 root partial rollback，不宣称原子事务；完整 native VcsNotifier/DataContext/UI automation 仍是 partial。

2026-08-23 Git Roots Pull 后置动作校正：对照 `GitUpdateInfoAsLog`，`Pull All (Merge/Rebase)` 现在在操作前后按 root 捕获 HEAD，只为成功且未跳过、且确实推进的 root 生成 root-qualified `View Commits` semantic action；无 upstream、无共同祖先、首次发布、失败或 skipped root 不伪造范围。Pull 失败 root 的 Retry action 携带已有成功范围，重试后按 root 合并旧边界与新 tip，FeedbackCenter/Operation Log 重载仍保留该动作；Fetch All 不生成本地提交范围。更完整 native VcsNotifier/DataContext/UI automation 仍是 partial。

2026-08-23 Merge 后置动作校正：对照 `GitMergeAction.handleResult`，single-root Merge（fast-forward、no-ff、显式 finish）、Branches Popup 的 root-scoped Merge、多 root Merge，以及 Git Roots Continue 完成的 merge，现在按真实 before/after HEAD 提供 root-qualified `View Commits` semantic action；未完成、冲突、失败、skipped、已是最新和边界缺失的 root fail closed。该动作与 Delete branch action 并存；跨 root partial/Smart Merge 决策仍保留已完成 root 的范围，失败路径的 rollback action 只用于 partial operation recovery，不作为成功态 NOTHING 的额外后置动作，Operation Log 可恢复；真实 VcsNotifier/UpdateInfoTree、DataContext/action-group 和 UI automation 仍是 partial。

2026-08-23 Log Revert/Cherry-pick 恢复校正：对照 `GitApplyChangesProcess`、`GitApplyChangesNotificationsHandler` 与 native sequencer 的暂停语义，Log 多选现在在每个 Git root 独立持久化 session、root 顺序、operation、按 root 排序后的 commit IDs、初始 HEAD、Smart 保存策略、空提交策略和 published suffix 选项；旧版本单 root marker 会迁移为 legacy single-root session，不因 schema 升级丢失恢复入口。进程在 root 之间退出时，尚未执行的 root 仍保留自己的 semantic `Retry Revert`/`Retry Cherry-pick` action；重启后只有当该 root 仍无活动 Git operation、HEAD 与保存的初始 HEAD 完全一致且它是该 session 最早的 pending root 时才允许重放，HEAD 漂移、状态读取失败、活动 sequencer 或顺序越过都会 fail closed。冲突时继续沿用 Continue/Abort recovery；Abort 后保留安全的 Log retry，Continue 完成当前 root 后自动推进下一个 pending root，并在完成时清理对应 marker；单 root/multi-root 请求均可从 Operation Log 与 macOS native notification 重载。剩余差距是完整 native `GitApplyChangesNotificationsHandler` 分组、DataContext 生命周期以及 UI automation，不再是跨重启完全丢失 Log 引用或 Continue 后停在当前 root。

2. **P1（签名 UX）：GPG agent/pinentry 配置。** Arbor 已支持 GPG/SSH signing 配置、签名提交和签名状态读取；外部 pinentry 检测、`gpg-agent.conf` 备份/原子写入、agent reload 与 Settings 的 Configure/Retry 入口已具备。本轮新增可选 Arbor embedded pinentry helper：通过 launcher 配置 `gpg-agent`，由 Arbor executable 的 `--arbor-pinentry` 模式实现标准 stdin/stdout pinentry 协议、SETDESC/SETPROMPT/GETPIN/CONFIRM/BYE、原生 `NSSecureTextField` 密码输入、取消/错误返回；launcher 仅在短期 `PINENTRY_USER_DATA` 含 Arbor 会话令牌时把请求路由到 helper，其它 GPG 调用直接使用系统 pinentry，取消、协议错误或 helper 非零退出不会触发第二次 fallback。签名提交阶段由主进程创建 loopback listener，使用 Curve25519 + AES-GCM 与 helper 加密交换 passphrase。签名失败现在保留可跨重启的 Configure GPG Agent action；`gpg_agent_status` 能返回 GnuPG 不可用状态，Settings 提供官方安装入口并在状态未就绪时禁用配置写入。剩余差距收敛为远程开发传输、原生 DialogWrapper 生命周期、真实签名 GUI automation，以及完整 IntelliJ PinentryService 的 Java 兼容协议细节。

2026-08-22 embedded GPG pinentry 校正：对照参考 `git4idea/rt/src/git4idea/gpg/PinentryApp.java` 与 `GpgAgentConfigurator`，Arbor 现在不再把 embedded pinentry 作为 out-of-scope。Settings 的 `Use Arbor Embedded` 会在 Application Support 生成 0700 launcher；在存在系统 pinentry fallback 时，launcher 只对 Arbor 会话令牌调用 `Arbor --arbor-pinentry`，其它调用直接交给系统 pinentry。pinentry helper 不写日志、不持久化 passphrase，仅在独立进程的 `NSSecureTextField` 中短暂持有输入，并用 pinentry percent-escaped `D` response 返回给 GPG。非交互协议握手、UTF-8/百分号/换行转义和 shell path quoting 已有 XCTest，真实构建产物已通过 `GETINFO`/`BYE` stdin/stdout handshake；`GETPIN` 的真实 GUI 输入仍需人工 macOS signing flow 验收。

2026-08-23 GPG PinentryService 加密通道校正：签名 `commit`、`commit-and-push` 和 multi-root commit 现在只在操作期间启动短期 loopback listener，并由统一 Rust Git runner 注入 `PINENTRY_USER_DATA`；helper 使用临时 Curve25519 key agreement + AES-GCM 回传 passphrase，服务不可用时才回退独立 helper prompt，取消不会 fallback 成第二次 prompt；并发提交以引用计数保护 token 清理。2026-08-26 launcher 路由继续校正为仅对 Arbor 会话令牌调用 helper，普通 GPG 调用保留系统 pinentry，helper 非零退出不再触发二次 fallback。新增 endpoint/token 校验、加密 round-trip 与真实 shell 路由 XCTest；尚未宣称真实 GPG key 的 GUI signing flow、远程开发 socket 传输、DialogWrapper/UI automation 和完整 IntelliJ PinentryService Java 兼容协议细节完成。

2026-08-23 GPG 缺失引导与签名失败恢复校正：`gpg_agent_status` 在 `gpgconf` 不可用时返回 `available=false` 和可展示的 GnuPG home/config 路径，Settings 不再把缺失安装误显示为普通配置异常，并提供官方 GnuPG Downloads 入口；`Commit`、`Commit and Push`、multi-root Commit 和 signed Tag 的 GPG/pinentry 错误现在保留 root/project-scoped 的 Codable `Configure GPG Agent…` action，可从 FeedbackCenter/Operation Log 跨重启恢复；signed Tag 也在 `tagCreateWithOptions` 前启动短期 pinentry session。SSH signing 及普通远端错误不触发 GPG action；Rust classifier 与 Swift action/URL 覆盖单测，完整真实 signing GUI flow 仍需人工验收。

2026-08-23 single-root Push recovery 校正：对照 `GitPushResultNotification` 的 rejected Push 后续动作，标准 `doPush` 与单 root `Commit and Push` 现在不再用即时 `NSAlert` 丢失恢复上下文，而是用稳定 Push notification 发布可序列化的 `Update with Merge` / `Update with Rebase` action；普通当前分支 Push 也只在目标 remote 与 configured upstream 一致时按 merge-base → local tip 保留 `View Commits`，无 upstream、不同 remote、refspec、非当前分支或无共同祖先安全省略。action 保存 remote、目标分支、force/lease、upstream、tag/hooks 参数和该提交范围；重启后只在原 Git root 仍打开、仍检出原分支且 upstream 仍存在时执行，状态漂移会 fail closed。点击 recovery 后复用 root-scoped `Update → Push` compound runner，冲突、Retry 和后续 Push 不再串到通用 Pull/Push 的全局生命周期。项目级 Push/多 root atomic rollback、联合 diff 和原生 VcsNotifier 分组仍保持 partial。

2026-08-24 Push notification 分组与动作持久化校正：对照 `GroupedPushResult` / `GitPushResultNotification`，标准 `doPush` 与 root-scoped `pushInRoot` 的 stale-lease Force Push Anyway、Retry Push 不再只依赖 closure；现在保存 remote、branch、force/lease、refspec、tag/hooks 和 View Commits range 的 Codable `retryPush` action，重启后按 root 与当前 branch 校验再执行。所有 Push failure/rejection 反馈还提供 root/project-scoped `Show Details` semantic action，macOS 通知重载后可直接定位同一 Operation Log entry；nested Git root 不再被 Shelf allowlist 误拦。multi-root Push 现在把 rejection 与 authentication/permission 等 transport error 分成 warning/error，并按 IntelliJ 语义使用 important notification group；原生 `VcsNotifier` 的完整 repository result type、UpdateInfoTree 与 UI automation 仍是 partial。
2026-08-24 标准 Push 重试动作收口：主 root 的普通 transport/auth failure 现在与 nested root 共用持久化 `Retry Push`，non-fast-forward 的 `Update with Merge/Rebase` 通知也同时保留直接 Retry；重启后仍携带原 remote/branch/refspec/tag/hooks 与提交范围。Push retry 发现当前分支已漂移时的提示也修正为显示真实目标分支；完整 native notification/DataContext 生命周期仍是 partial。
2026-08-24 detached refspec Push 边界校正：root-scoped Push 与跨重启 `Retry Push` 不再因为 detached HEAD 没有 local branch 而拒绝非空 custom refspec；只有普通 branch Push 仍要求当前 branch。该边界与 IntelliJ 的 source/target refspec 模型一致，native Push dialog/DataContext 与 UI automation 仍是 partial。
3. **P2：歧义目录 rename 的逐文件恢复动作。** 可靠的单文件 rename，以及由唯一设备号+inode 证明的目录及其子项 rename，已配对并进入 Git move；多候选、身份缺失或无法证明旧路径的目录事件现在按未改变的相对后缀生成逐文件候选，并通过可滚动的 `Review ambiguous Git moves` 让用户明确选择后再执行 Add/Remove。每个新端点只有一个选择控件，多候选默认 `Skip`，最终还会校验旧/新端点一对一，不再自动猜测或重复消费旧端点；Add/Remove/force-move 失败后还可从同一稳定通知重试已确认集合。未匹配路径仍保守地只走新文件 staging 或完整 status reconciliation；剩余是 IntelliJ 原生逐文件 operation-state、VFS permission/banner、精确 action history 与 UI automation。
4. **P2：Shelf differentiated apply 与回收区 action 细节。** Shelf 主链路、Show Already Unshelved、Recently Deleted、成员级操作、批量恢复和跨重启 semantic action 已存在；本轮已补 Shelf/Apply Patch 成功、批量部分成功、冲突完成与精确回滚统一进入 root-scoped dirty-scope 消费，并刷新文件内容 token、staging model 和 index revision；新增 Shelf 相对路径的 root containment/dedup 校验，避免越界路径扩大刷新范围。剩余是完整回收列表 action model、更细通知/Undo 聚合、精确 FilenameIndex/VFS 生命周期和原生 UI automation。
5. **横切 P2：原生 DataContext/action-group/VcsNotifier/UI automation。** 这不是单一 Git 引擎功能缺失，而是大量已可用 action 的生命周期差异：跨 root 通知聚合、permission/banner、原生选择上下文、树组件 renderer 和自动化覆盖仍不完整。不能把它们写成“Branch/Log/Shelf 功能不存在”。

2026-08-22 operation recovery failure 校正：对照 `GitRebaseSkip`、`GitAbortOperationAction` 与 apply-changes 的失败通知路径，Arbor 的 Continue/Skip/Abort 命令失败后现在立即重新读取所属 root 的 `operation_state()` 和冲突集合，再发布 root-qualified Retry/Continue/Skip/Abort actions。这样 native Git 在失败过程中推进到下一暂停步骤、或冲突文件集合发生变化时，恢复栏与 Operation Log 不会继续使用点击前的旧 snapshot；Git 失败仍保留原生暂停元数据，用户可改选其它恢复动作。Rust 回归覆盖未解决冲突时 Cherry-pick、Revert、Rebase Continue 失败后状态仍可恢复；剩余差异是 IntelliJ 原生 notification/banner/UI automation，而非恢复语义本身。

本轮 raw todo 实现的边界是明确的：捕获和执行均由安装的 Git 原生 rebase 负责；SwiftUI 只编辑文本并驱动 Git 的 sequence/message editor。single-root 与 multi-root 均支持逐 root 捕获/编辑/执行 `label/reset/merge/exec/break/update-ref` 等控制行，reword/squash 消息编辑、Continue 后再次进入消息编辑、取消、局部修改保存与暂停恢复也有 Rust 回归覆盖；应用重启后若 native editor 仍在等待，multi-root recovery monitor 会重新发现 message request，并在 Git operation 结束后自停。剩余差距主要是跨 root 通知分组与 UI automation，而不是 raw todo 执行能力本身。

2026-08-22 SubmodulePanel action-history 校正：Add、Update（含 init/recursive/--remote）、Sync、Deinit、Remove、Set Branch 统一经过 durable `PersistedSubmoduleRetry`；失败或取消会保留完整参数、root scope 和 stable notification ID，Operation Log 重启后可重新执行同一 native Git 命令。Update 继续生成 expected-HEAD guarded 的 `Undo Submodule Update`；Deinit 在 clean gitlink、`.gitmodules` 精确快照和空/不存在工作树的条件下生成 `PersistedSubmoduleUndo`，通过父仓库更新恢复后再次验证 clean 状态，失败时保留 Retry Undo。Add 仍不提供无条件 rollback；Remove 现在只在 parent HEAD、`.gitmodules` 前后快照、gitlink、无未跟踪/ignored 文件且路径可安全占用的 expected-state 边界内提供 Undo，失败或状态漂移 fail closed 并保留 Retry Undo。

2026-08-22 submodule gitlink staging 校正：参考 `StagingAreaOperationAction` / `StagingAreaOperation` 对子模块节点先按 `submodule.parent` 分组、再在父仓库执行普通 Add/Reset 的语义，父仓库对已初始化且已存在的 160000 gitlink 现在可以 Stage/Unstage。Stage 只读取嵌套仓库的 HEAD 并更新父 index 的 gitlink，不会把嵌套工作树文件写入父仓库；Unstage 恢复父 HEAD 对应的 gitlink。未初始化、无 HEAD、普通目录或 index 条目缺失都会 fail-closed，不写入半成品 index。剩余差距仍是原生 DataContext/action lifecycle 与 UI automation，而不是 gitlink 写入语义。

2026-08-22 Add Commits to Remote Branch 生命周期校正：参考 `GitAddCommitToRemoteBranchOperation` 的 fetch → in-memory replay → Push dialog 顺序，Log 入口现在以稳定 notification ID 开始 FeedbackCenter 操作；detached tip 准备完成后先结束 Working 状态再打开 Push dialog，无变化、失败和取消均发布终态通知。取消不会再因 Task 提前 return 留下永久 Working… 或可取消状态；该操作仍保留单 root/线性提交限制，跨 root 统一通知编排与 UI automation 继续为 partial。

2026-08-22 Push compound recovery 生命周期校正：Push All 的 catastrophic failure、Push recovery 的 catastrophic failure，以及单 root `Update with Merge/Rebase → retry Push` 现在复用 project/root-scoped stable notification ID；这些路径都保留原始 remote/branch/refspec/tag/hooks/force 参数，并提供可序列化的 Retry Push / Retry Push Recovery action。单 root recovery 不再把 Update 成功、下一次 Push 和失败分别写成无关联的 Operation Log 项；跨 root 更细的 rollback、联合 diff 与完整 VcsNotifier 分组仍是后续 partial。

2026-08-22 multi-root Commit catastrophic failure 校正：Commit engine 在结果聚合前抛出异常或取消时，失败通知现在仍复用 Commit 的 stable notification ID，并持久化完整 Commit options、Commit and Push 标志、失败 root scope 与此前已成功提交 roots；Operation Log 可恢复 `Retry Failed Commits`，并在适用时保留 `Push Committed Roots`。这只补齐 catastrophic failure 的恢复语义，跨 root 原子 rollback 仍不安全且继续保持 partial。

2026-08-22 Submodule Changes 文件级 diff 校正：Changes Browser 的 gitlink 入口现在不止展示嵌套提交和文件名；点击 nested file change 会在所属子模块 repository 中按 old/new gitlink revision 读取两侧内容，支持 rename 的 old/new path、added/deleted 文件的空树侧、binary fallback，以及 side-by-side/unified diff。父仓库仍只负责 gitlink revision，嵌套仓库负责文件内容，避免 root 串线；非 Update 复合 rollback、完整通知历史和原生 UI automation 继续保持 partial。

2026-08-22 Push stale-lease 校正：参考 `GitPushNativeResult.isStaleInfo` 与 `GitPushResultNotification.ForcePushNotificationAction`，Rust 现在在 Git 原生进程已将该拒绝粗分为 non-fast-forward 时仍以原始输出优先识别 `stale info`/`stale lease`，导出 `PushFailureKind.StaleInfo`；单 root Push 和普通 Push 均在 root-qualified stable notification 中提供 `Force Push Anyway` 与 `Retry Push`，强推动作保留 remote/branch/refspec/tag/hooks/upstream，并重新执行 protected-branch guard。Push 的 Merge/Rebase recovery 同时保留 tag mode 和 skip-hooks，避免复合后续动作静默改变原始 Push 选择。多 root Push All 现在也提供 force/force-with-lease 选项，按 root 重新校验 protected branch，并对 stale lease roots 提供只作用于失败 root 的 `Force Push Anyway`；更深的 compound rollback、通知分组仍未完成。

2026-08-22 compound notification 校正：Update Project 的失败 root Retry 使用完成态 project notification ID，Checkout and Update/Checkout with Rebase 的重试复用同一 operation-scoped ID；FeedbackCenter 不再把重试过程额外留下不可执行的 `Working…` 历史项。该修正只收口 notification/session 生命周期，不改变失败 root scope、保存现场或回滚安全边界。

2026-08-22 Checkout and Update 复合 rollback 校正：参考 `GitCheckoutOperation` 在多 root 部分成功后保留 rollback proposal，Arbor 现在为 update 阶段已成功且未跳过的 root 生成精确 previous branch/HEAD、expected branch/HEAD 与 created-branch target，通知同时提供 `Retry Failed Checkout Roots` 和 `Rollback Successful Roots`。rollback 复用稳定 notification ID，成功、部分失败和 catastrophic failure 的反馈会替换同一 Operation Log/native notification；部分 rollback 只保留失败 targets 的 `Retry Checkout Rollback`。Force 模式和仍有 active merge/rebase operation 的 root 不生成不安全 rollback；跨 root atomic transaction 与联合 diff 仍保持 partial。

2026-08-22 Push recovery post-action 校正：参考 `GitPushOperation` 在 rejected Push 后执行 Update，再由 `GitPushResultNotification` 附加 received-commits action 的生命周期，多 root Push recovery 现在在开始 recovery 前保存待观察 roots 的 HEAD，完成后只为实际成功且 HEAD 前进的 root 生成 root-qualified `View Commits` semantic action；该 action 进入 stable Push recovery notification，能从 Operation Log/通知历史恢复。detached、skipped、failed 或未前进的 root 不会伪造提交范围。

2026-08-22 Push success notification 校正：参考 `GitPushResultNotification` 与 `GitUpdatedRanges` 的 received-commits action，项目级 Push All 现在在 transport 前解析每个 root 的 local tip/tracked upstream tip merge-base，并在成功/部分成功反馈中只为成功且未跳过的 root 生成 root-qualified `View Commits` semantic action；初次 publish、tag-only 或 unrelated-history root 不会伪造旧提交边界。该 action 使用 Push 的 stable notification ID，Operation Log/native notification 重载仍可用。

2026-08-22 root-scoped Push recovery post-action 校正：参考同一 `GitPushResultNotification` 生命周期，单 root（包括嵌套 submodule）在 `Update with Merge/Rebase` 成功后保存 update 前后的 HEAD；随后 Push 成功、失败、stale-lease 或再次拒绝的稳定通知都保留 root-qualified `View Commits` semantic action，第二次 Update 本身失败/冲突时也保留已有范围。Retry Push 与 Force Push Anyway 会继续携带该范围，重复 Update recovery 按 root 合并为最初 old revision 到最新 new tip，避免 root recovery 已经产生的提交在下一次 Push 反馈中丢失；未实际前进的 root 不生成空或伪造范围。

2026-08-22 compound rollback action 校正：FeedbackCenter 的 `expire` 现在会同时清除持久化 semantic actions 和 action titles，避免已结束的 recovery 在 Operation Log 中继续可点击；multi-root Merge rollback 和 Update/Submodule Update rollback 会接管稳定 rollback notification，Update 的旧 partial notification 在进入 rollback 前失效。expected-HEAD、branch identity 与 deepest-first rollback 边界保持不变。

2026-08-22 multi-root Commit and Push 校正：参考 `GitCommitAndPushExecutor` 的提交后推送语义，Git Roots 的 Commit dialog 新增 Commit and Push Selected。提交阶段仍按选中的 root 独立执行；只有真正创建 commit 的 root 会进入共享 Push options，clean/skipped/failed root 不会被误推送。部分提交同时保留 `Retry Failed Commits` 与 `Push Committed Roots` 两个 root-scoped semantic action；Push action 使用 Codable `pushAfterCommit` request，可从 Operation Log/native notification 重载，取消 Push 不会丢失已提交结果。

2026-08-22 Commit and Push partial-result 校正：参考 `GitCheckinEnvironment` / `GitStageCommitter` 仅在提交阶段无异常时启动 `GitPushAfterCommitDialog`，multi-root Commit and Push 现在也只有全量提交成功才自动打开 Push options。部分成功、提交前检查失败后取消 Commit Anyway，或普通 root failure 都不会隐式启动 Push；已成功 root 仍保留可跨重启的 `Push Committed Roots` semantic action，用户可显式继续推送。2026-08-23 单 root 也改为先 commit、成功后打开 Push options；commit failure 不进入 transport。

明确不列为当前缺口：Shelf 的 recycled 显示开关（已持久化并过滤）、multi-root preserve-merges 的 merge-row action 对齐（已修复并有回归）、项目级 Git executable override、自动 Fetch、以及已覆盖的 Submodule 基础命令链路。

2026-08-21 VCS action surface 校正：参考 `DvcsQuickListContentProvider` 与
`GitQuickListContentProvider` 的顺序，Arbor 新增可搜索的 `Quick Git Actions…` action palette。
它按 Commit/Repository/Workspace 分组，覆盖 Commit、Stage tracked、Branches/Push/Stash/Unstash、
Worktrees、Stage all、Copy branch、Resolve Conflicts 和 Unshallow，支持大小写与多词过滤、上下键
选择、Return 执行、Escape 关闭，并按 repository/shallow/current-branch/conflict 状态禁用不适用动作；
顶栏 `More Git Actions` 与 VCS > Git 菜单共用同一 `ArborVCSAction` 路由。
该面板现在由 `VCSQuickActionsPanelCoordinator` 承载为可复用的非模态 AppKit `NSPanel`，
不会阻塞主工作区，且关闭/重复打开时保持同一浮动窗口生命周期。
同时将 Show Log、Operation Log、Git Roots、Git Console 和 Refresh Git State 接入 VCS 菜单及
统一 action router。detached HEAD 下 Push/Pull 保持参考实现的 repository-level 可用性；Commit
仍要求本地改动，Commit and Push 额外要求当前分支。剩余差距是 IntelliJ 原生
`QuickSwitchSchemeAction`、DataContext 动态 action provider、QuickSwitch 的原生内容提供器语义
和 UI automation；当前不再只是静态菜单映射。

2026-08-21 Git 主菜单 enablement 校正：参考 `GitMainMenuActionGroup` / `GitMenu` 的上下文更新，
Arbor 新增 focused `ArborVCSActionContext`，让 VCS > Git 菜单按当前窗口的 repository、分支、
变更、remote、shallow 和冲突状态更新动作可用性。无仓库时 Git 动作统一禁用；Commit/Stage/Stash、
Push/Pull、Fetch/Unshallow、Resolve Conflicts 分别按真实前置条件禁用；detached HEAD 下 Push/Pull
仍按 repository-level 动作处理，Commit and Push 才要求当前分支。剩余差距仍是 IntelliJ 原生 action-group 的动态
selection/DataContext 生命周期、QuickSwitch provider 和 UI automation；当前不再只是静态菜单映射。

2026-08-21 VCS Log action-state 校正：参考 VCS Log action group 的 update 语义，Arbor 新增
`LogActionAvailability`，由 ContentView 将当前本地改动和 operation root 注入 Log 图表。Interactive
Rebase 与历史改写会在对应 root 有进行中操作时禁用；批量 rewrite/add-to-remote 会拒绝跨 Git root
选择，而 cherry-pick/revert 保持参考实现支持的跨 root 处理；Fixup/Squash 同时要求本地有改动。
参考 `VcsLogSingleCommitAction` 的 selection-size 规则，Checkout、Tag、Interactive Rebase、单提交
rewrite、Push Up to Commit 和 Undo 在多选时禁用。图表行菜单和 More Log Actions
共用这套纯值判断，并用单元测试覆盖 active-root、跨 root 和规范化路径边界。剩余差距仍是
IntelliJ 原生 VCS Log DataContext/action-group 生命周期、完整 operation 状态广播和 UI automation。

2026-08-21 Log commit branch action root routing 校正：参考
`GitCreateNewBranchFromCommitAction` 的 `selection -> commit.root -> repository` 链路，Arbor 的
“从提交创建分支”现在始终使用所选 `CommitInfo.repositoryPath` 对应的 Repository。aggregate Log
不再因为多 root 被拒绝，也不再把单提交动作错误扩展为所有 root；分支名校验、checkout、刷新和
反馈均绑定同一 root。多 root New Branch repository picker 继续只用于明确的项目级批量创建入口。

本轮对照 `GitNewBranchDialog` 与 `GitBranchCheckoutOperation` 补齐
`Overwrite existing branch` 语义：默认仍在提交前拒绝同名分支，只有明确勾选后才执行；非当前
分支使用 `git branch -f`，当前分支使用 `git switch -C`，保证 ref、HEAD、index 和工作树一起移动；若基点之外确有本地提交，
执行前再弹出丢弃提交确认。多 root 也已接入同一显式 reset 选项：逐 root 记录被覆盖前后的 branch tip，
部分成功回滚时先校验 branch tip/HEAD/current branch，再恢复旧 tip；如果用户在操作后改动了 ref，
该 root 会 fail closed，不会把新提交静默覆盖。部分成功后的 Rollback/Keep Partial 现在通过
FeedbackCenter、Operation Log 和稳定 native notification ID 暴露；rollback target 以 Codable
semantic action 跨重启恢复，失败 root 可单独 Retry。仍缺的是更细的 SwiftUI/UI automation 与
完整原生通知分组，而不是 rollback 状态本身。新 semantic rollback 若缺失操作后的 branch-tip
快照会直接 fail closed，不会退化成无条件删除或重置。

2026-08-21 aggregate Log commit inspector root routing 校正：参考 fork 的 hosted repository
reference action 会从选中的 commit 解析所属 Git repository。Arbor 的提交详情元数据现在也通过
`repositoryForCommit(commit)` 解析 Repository，并从该 root 读取 remotes；“在浏览器中打开”及
其它详情 fallback action 不再复用主 root 的 `repo`/remote。无法解析所属 root 时 fail-closed，
剪贴板 permalink 的专门 Swift UI 测试仍待补。

2026-08-21 Log commit ref action group 校正：参考 `GitSingleCommitActionGroup` 与
`GitLogBranchOperationsActionGroup`，Arbor 现在只对单提交选择动态读取该提交的 local branch、
remote branch 与 tag refs；当前 local branch 不再重复出现在操作组中，重复 ref 会去重并保持稳定排序。
`Branches` / `Tags` 子菜单提供 checkout、checkout as new branch、compare、working-tree diff、
checkout and update、checkout with rebase、merge、rebase，以及 local update/push/rename/delete、remote pull/delete、tag merge/delete；所有
写操作按 `commit.repositoryPath` 路由到提交所属 root，缺失 root 时 fail-closed。剩余差距是
IntelliJ 原生 `DataContext`/action-group 生命周期、完整 ref presentation comparator、通知细节和
UI automation，不再是提交行完全没有 ref-specific action group。

2026-08-21 Log Cherry-pick/Revert mixed-root routing 校正：参考 `GitApplyChangesProcess` 的
`DvcsUtil.groupCommitsByRoots()` 语义，Arbor 现在按规范化后的 `commit.repositoryPath` 将日志多选
分组，保留首次出现的 root 顺序与每个 root 内的选择顺序；Cherry-pick 在每个 root 内按日志历史顺序
重放，Revert 保持该 root 的选择顺序，并分别读取对应 root 的 remote/protected-branch 配置。某个
root 发生冲突时停止后续 root，恢复工作台绑定触发冲突的 root；Smart retry 只重试尚未开始的 root。
剩余差距是原生跨 root notification/action-history 的分组与 continuation 生命周期，不能把它们误记为
单 root 拒绝或主仓库串线问题。

2026-08-21 Merge 对话框校正：参考 `GitMergeDialog.validateBranchField()` 会在当前 HEAD
已经包含源 branch tip 时拒绝执行 Merge。Arbor 新增 `branch_list_merged_all()`，在打开对话框
后异步读取本地与 remote-tracking refs，对已合并 branch 即时显示提示并禁用 Merge；执行前
再次读取并校验，防止对话框打开后 HEAD 变化造成 stale no-op。任意 commit/revision 仍可继续
输入，cleanup 专用的 `branch_list_merged()` 继续保持“仅本地、排除当前分支”语义。

同日 multi-root Merge 也已按参考实现的 per-root `git branch --all --no-merged` 语义校正：
每个可选 Git root 独立读取 `branch_list_merged_all()`，仅在该 root 已确认合并时禁用对应行并从
默认全选中移除；读取失败的 root 保持可操作，由 Rust multi-root runner 在执行时返回安全的
already-up-to-date no-op。对话框 generation 会丢弃关闭或重开后的旧异步结果，执行入口还会
再次过滤已知的 no-op root。

2026-08-21 VCS Log 列校正：参考实现的 `VcsLogDefaultColumn.Root` 现在已在 Arbor 的 Log Columns 菜单中落地为 Root Names。它使用已有的 `CommitInfo.repositoryPath`，按行显示所属 Git root 的目录名，并在 tooltip 保留规范化完整路径；显隐、拖拽重排、宽度调整和 AppStorage 持久化均已接入。当前 Log 的真实剩余不是“没有 dynamic columns”，而是完整 IntelliJ dynamic/custom column extension point，以及对应的原生表格/UI automation 生命周期。

2026-08-21 VCS Log 签名列校正：参考 `GitCommitSignatureStatusProvider` / `GitCommitSignatureLoader` 已补入 Arbor。Commit Signature 列默认隐藏，可持久化显隐与重排，保持参考实现的固定宽度；Rust 通过单次 `git log --no-walk` 批量读取 `%G?/%GS/%GF`，SwiftUI 只为当前已加载行异步请求，按 `(root, commit)` 回填并丢弃过期代际；verified、bad、无签名、unknown 以及 expired/revoked/cannot-verify 原因均保留在状态/tooltip 中。剩余差距是 IntelliJ provider extension point、原生 JTable renderer/lifecycle 和 UI automation，不再是签名状态列本身缺失。

2026-08-21 VCS Log 复制 revision 校正：参考 `CopyRevisionNumberAction` 会将选中的 revision 按旧提交到新提交反转，并以空格连接，便于直接粘贴到 Git 命令；Arbor 的 `Copy Selected Revision IDs` 现已采用同一格式。Reflog 的单行复制仍保持只复制当前新 revision 的语义。

2026-08-21 Cleanup Branches 复制校正：参考 `CleanupBranchesDialog` 的 `CopyProvider` 按当前表格行顺序输出 `branch name<TAB>last commit date<TAB>tracked branch`；Arbor 的 Cleanup Branches 现在复用当前 root/排序下的可见行顺序生成同样的三列 payload。剩余差距收敛为 SwiftUI 行选择/原生 CopyProvider 生命周期与 UI automation，不再是复制内容格式本身。

2026-08-21 本地分支删除后续 action 校正：参考 `GitDeleteBranchOperation.notifySuccess()` 会在删除本地分支后，只有当它是该 remote branch 的唯一 tracking local branch、tracking ref 仍存在且远端分支未受保护时，提供删除 tracked remote branch 的 action。Arbor 现在在单 root 与 multi-root recovery sheet 中复用同一 eligibility 判定；远端删除按 root 执行并汇总 partial failure，成功 root 会移除该 action 但保留本地 Restore 上下文，保护分支和其它 tracking branch 不显示 action。Restore 与未合并提交的 View Commits 现在都发布项目级稳定 semantic action；每个 root 的精确 deleted tip/upstream、base branches 和 unmerged commit snapshot 可在 Operation Log 或 macOS 通知重载后重建对应 recovery view，Restore 只重试失败 root。剩余差距收敛为完整原生 VcsNotifier action 生命周期与 UI automation。

2026-08-22 分支删除 preview 进一步对齐 `GitDeleteBranchOperation`：当本地分支已经合入当前 HEAD、但仍未合入 configured tracking upstream 时，`View Commits` 现在按 `upstream..branch` 读取未合入提交；只有 upstream 已包含该 tip 时才回退到 HEAD-relative 检查。这样不会把“已合入当前分支但未推送/未合入 upstream”的风险错误显示为空。回归覆盖本地 upstream 与 fast-forward 当前 HEAD；剩余差距仍是原生 dialog/notification action 生命周期与 UI automation。

2026-08-22 多 root Rename Branch 回滚生命周期校正：参考 `GitBranchOperation` / `GitRenameBranchOperation` 的部分成功语义，Arbor 不再把成功 root 的回滚决定留在一次性的 modal `NSAlert` 中。重命名后现在保存每个 root 的新分支 tip、当前 branch identity 和原 upstream，Rollback/Keep Partial 通过稳定 notification ID 的 FeedbackCenter、Operation Log 和 Codable semantic action 跨重启恢复；回滚前同时要求旧名不存在、新名 tip 未变化、当前 branch identity 未变化，upstream 恢复失败只保留失败 root 供 Retry。仍缺原生 `DataContext`/`VcsNotifier` 生命周期与 UI automation，但不再是重启后无安全恢复入口。

2026-08-22 Branch Rename dialog 校正：参考 `GitRenameBranchAction` 使用的 `GitNewBranchDialog`，单 root Rename 不再直接使用无校验的 modal `NSAlert`；现在提供 SwiftUI Rename dialog、按 root 的 local/remote ref 冲突校验、Git ref-name 校验以及 `Unset upstream after rename` 选项。multi-root dialog 复用同一 local/remote 冲突规则，执行前再次读取 refs 做 stale-dialog 防护；解除 upstream 失败时会尝试把 branch rename 安全恢复为旧名。跨 root 的完整原生 dialog/DataContext 与 notification/UI automation 仍是 partial。

2026-08-22 多 root Branches Popup / Log dashboard Worktree action 校正：参考 `GitCreateWorkingTreeAction` 的单 repository 约束，主 Branches Popup 与 multi-root Log Branches dashboard 的 HEAD 当前分支、local branch 和 tag 现在都会把所属 `rootPath` 传入 New Working Tree 对话框；对话框中的 branch/worktree 占用校验、Repository 打开和创建动作均使用该 root，创建后刷新对应 root 的 snapshot，不会误落到 primary repository。这里保持 IntelliJ 的 repository-scoped 语义，不把多 root worktree 创建伪装成跨仓库批量事务；Log dashboard 的完整原生 action/DataContext lifecycle 与 UI automation 仍是 partial。

2026-08-22 Branches Popup action-update 校正：unborn Git root 的真实 `headId` 现在同时进入 single-root 与 multi-root Popup 的 `BranchDashboardReference`，因此 HEAD 和当前 local branch 的 `New Branch from HEAD` / `Checkout as New Branch` / `New Working Tree` 会保持可见但按 IntelliJ presentation 语义禁用，不再把 optimistic default 传到执行层；跨 root 同名 branch 的 action preview 与批量选择也复用该 root-scoped head state。Operation Log 现在持久化稳定 notification display id，重启后同一 VcsNotifier display id 会更新原历史行，`expire` 后不会误更新旧 recovery 记录。剩余仍是完整原生 DataContext/action lifecycle、permission/banner 和 UI automation。

2026-08-22 远程分支删除 transport 校正：参考 `GitDeleteRemoteBranchOperation` 的异步 push deletion 与 stale remote ref 幂等处理，`delete_remote_branch` 现在统一复用 credential broker、process-group cancellation 和远程已消失后的 prune；成功后本地 tracking ref 清理不再被紧随其后的取消打断。单 root Branches Popup、multi-root repository-scoped 删除、Log 多选和“删除已删除 local branch 的 tracking remote” recovery 均切换到同一 API；跨 root 仍保留“所有远程删除成功后才删除共同 local tracking branches”的 IntelliJ 顺序。剩余差距是专门 SwiftUI/UI automation、完整 VcsNotifier action history 和更细远程删除通知分组。

2026-08-21 Log Changes Browser Get Version 与 Apply/Revert 校正：参考 `GetVersionFromRepositoryActionProvider` 将 `SELECTED_CHANGES_IN_DETAILS` 作为批量 provider 交给 `GetVersionAction`，而 `RevertSelectedChangesAction` / `ApplySelectedChanges` 同样消费 Changes Browser 当前选中的全部变更；Arbor 现在保留当前 Changes 选区，一次确认后按选中记录所属 root/commit 逐项恢复 index 与 worktree，并汇总部分失败。Apply/Revert 现在支持同一 Git root 下跨多个 commit，以及跨多个 Git root 的选区；每个 root 的 commit/parent patch 按选区顺序逐批执行，遇到冲突停止后续批次并进入绑定触发 root 的可重启 direct-patch resolver；同一 merge commit 混合 parent 仍安全禁用，避免错误拼接 patch，跨 root 专属通知分组与更完整通知历史仍是剩余差距。

2026-08-21 Log Changes Browser parent action 校正：参考 `Vcs.Log.ChangesBrowser.Popup` 的 `ShowChangesFromParentsAction` 已移入 Arbor Changes Browser 自身菜单；切换会重新加载父提交差异，且仅单个 merge commit 展开所有 parent，多个提交选择继续使用各自 first parent，避免把多个 merge 的 parent graph 错误拼在一起。

2026-08-21 Log Changes Browser affected-path action 校正：参考 `ShowOnlyAffectedChangesAction` 依赖 Paths/structure filter；Arbor 现在提供 Paths 的原生文件/目录多选、root-qualified 树/编辑选择、清空入口，并在 Paths 非空时提供同名切换，按 owning Git root 的 repository-relative 文件或目录筛选 Changes Browser，保留 rename 的 old/new 两端。切换会清空不再可见的文件选区与 diff；仍缺 IntelliJ 原生 `VcsStructureChooser`/FileSystemTree renderer、DataContext action lifecycle 和 UI automation。

2026-08-21 Paths structure filter 校正：Paths 支持每行一个路径的多路径编辑、懒加载 Git root/目录/文件复选树、root-qualified selection、父目录折叠子路径、最多 100 个节点的 SelectionManager 选择上限、最近筛选组持久化与清空；Git Log 按 owning root 在一次引擎遍历中执行相同条件并取并集，Changes Browser 对多路径执行 OR 匹配；聚合 Log 还支持按当前 Log tab 切换 Git root 可见性并跨重启恢复。仍缺 IntelliJ 原生 `VcsStructureChooser`/FileSystemTree 的精确 renderer、DataContext/action lifecycle，以及 UI automation。

### 当前状态纠偏（2026-08-20）

本轮已把上文旧记录中仍标为缺失的三条底层能力推进到可验证实现：外部 VFS 事件现在同时保留逐文件 dirty ledger（pending → in-progress → processed）与压缩 dirty scope；rename parent 的非递归语义不会误覆盖子文件；watcher 合并事件不会丢失 `oldPath`。`VcsNotifier` 对齐现在有 tool-window、standard、important、silent 四类 presentation group，stable display ID 可替换并在 Git 状态结束时 expire；operation recovery 使用 important group。无法唯一配对的 rename 先做全量 status reconciliation；Git 能明确给出唯一 `oldPath`，或在非目录事件中恰好得到唯一 untracked 新端点与唯一 deleted 旧端点时走 Add+Remove；歧义目录事件现在生成候选并等待用户明确选择，未选端点仍保持保守，不猜测旧端点。

因此下面历史段落中“逐文件 dirty-state、VcsNotifier 分组、无法配对 rename 完整 action 生命周期仍缺”的表述已过时；当前真实剩余是：歧义目录 rename 已进入逐文件候选 review，但仍未完全复刻 IntelliJ 的 operation-state/history 与原生 VFS action 生命周期，所有业务通知尚未逐一迁移到精确 group/display-id 常量，以及完整原生权限/banner/UI automation 覆盖。

2026-08-21 生命周期校正：外部事件主流程现已真正使用 `retrieveScopes()` / `changesProcessed()`，刷新进行中到达的事件留在 pending，并在当前 root 批次完成后再消费；批次同时保存 worktree/metadata scope 与具体 dirty/rename 路径。后文若仍写“dirty-scope 生命周期未接入”或“只在测试模型中存在”，均属于本段之前的历史描述；当前该项不再列为缺口，剩余是持久化 VFS/PSI `FilenameIndex`、多 content-root 索引模型、原生 `ApplyPatchViewer` editor/action lifecycle、完整回收列表 action model，以及通知和权限/banner/UI automation 长尾。

2026-08-21 Shelf action 校正：Shelves 区已接入 SwiftUI `onDeleteCommand`，使用与 IntelliJ `MyShelveDeleteProvider` 相同的“整列表优先、成员按 Shelf 分组”选择计划；active/recycled 进入可恢复删除，Recently Deleted 整组或成员进入永久删除。2026-08-23 又将同一选择计划提升为统一 Shelf action context：根 Shelf 和跨 Shelf 子文件选择都从顶部菜单驱动 Apply/Pop/Drop、Unshelve、Restore 与永久删除，Recently Deleted 不再在分区内重复一套列表级菜单；active 子项在刷新后也会清理失效选择。跨多个成员组的 Apply/Unshelve、Drop 和 Recently Deleted 永久删除现在进入同一个串行 grouped runner，聚合 `completed/total` 进度、partial failure、仅失败组 Retry 与稳定通知；active member Drop 还聚合为一个保留原始时间戳的批量 Undo。当前仍是 partial：没有 IntelliJ 的 `DataContext`、binary wrapper/navigatable provider 和原生树编辑 action 生命周期，完整回收列表 action/display-id 分组和 UI automation 仍缺。

2026-08-21 Shelf Rename 校正：参考 `RenameShelvedChangeListAction` / `ShelveChangesViewManager.ShelveRenameTreeCellEditor` 后确认，Rename 只更新 `ShelvedChangeList.description`。Arbor 已新增 `Repository.shelve_set_description`，对 active 与 Recently Deleted 都只写 Shelf metadata，保留稳定 name/id/ref/patch；SwiftUI 同时提供 Rename 菜单、双击 inline editor、Enter/Escape 和 F2。仍缺 IntelliJ 原生 DataContext、tree-cell-editor/action lifecycle 与 UI automation。

Update/Pull 的 upstream 配置尾部也已补齐：多 root 中被跳过的 detached/no-upstream root 会在项目级反馈中提供 root-qualified 的 `Choose Upstream` 或 `Open Branches` 动作；submodule 跳过项不会误导用户去修改 detached 子模块，而继续由父仓库 updater 处理。单 root Pull 遇到 `NoUpstream` 或失效 tracking branch 时，反馈直接打开现有 upstream 选择器；multi-root 恢复现在从目标 root 读取 remote-tracking branches，再复用选择器并显示目标 root 名称，不再要求用户手填 `origin/...`。剩余差异是选择器仍是 Arbor 的 SwiftUI/input flow，而不是 IntelliJ 的 `FixTrackedBranchDialog`，以及 detached root 的 checkout 仍由独立 Branches action 完成。

Changes Browser 的 staging 对比动作已从“只有通用 Show Diff”推进到 IntelliJ 的四类入口：文件右键可按状态显示 `Local with Staged`、`Staged with Local`、`Staged with HEAD` 和 `Three Versions`；动作不会替换 Git Log，而是在 Commit/Stash preview 中调用真实 `staging_diff` 或 `staging_file_versions`。`Local with Staged` 与 `Staged with Local` 对照 fork 共用 `compareStagedWithLocal`，统一使用 staged → local 的 staging 坐标系，并在 hunk 上提供 Stage/Rollback；`Staged with HEAD` 使用 index → HEAD，并提供 Unstage hunk。Rust `StagingEntry` 现在额外输出 `head_present`、`staged_present`、`local_present`，SwiftUI 按这组事实决定版本查看/比较入口，因此 staged addition、staged deletion、rename 和 unstaged-only 文件不再靠 `ChangeKind` 猜测存在性。普通 staging diff preview 现在也按当前的 unstaged/staged 维度提供文件级 `Stage`、`Unstage` 与 `Revert`，每个 hunk header 还提供对应的 `Stage Hunk`、`Unstage Hunk`、`Rollback Hunk`；Rust 的 hunk rollback 只恢复 worktree 相对 index 的选中范围，保留部分暂存边界，并对新增文件正确删除。逐行选择现在同时支持删除侧 old line 与新增侧 new line，纯插入可直接逐行 Stage/Unstage。preview 会在每次可见 status/index 刷新后重读，即使路径和状态枚举未变；完整刷新以及 Stage/Unstage/intent-to-add 的增量状态提交都会推进同一 refresh token；每次读取用 path + generation 拦截过期结果。预览仍可直接进入当前维度的逐行操作，再返回普通 preview。仍然缺少原生 DiffManager 的完整 update/action lifecycle、GitIndexVirtualFile/VFS 生命周期和 UI automation。

2026-08-21 CFG-001 staging/checkout/diff 校正：普通 `stage`、`stage_lines`、`restore_unstaged_lines` 和冲突 `resolve_edited` 不再把工作区原始 CRLF 字节直接写入 index；它们共享 `text`/`eol`/`core.autocrlf` 的内建 clean normalization，partial staging/rollback 先在规范换行上选择 hunk，再按 checkout 规则写回工作区。branch/tree materialization 也按目标 `.gitattributes` 先写属性文件，再写同批内容文件，并用目标 tree 的临时 index 预检不支持的转换，确保 fail-closed 不留下半成品 worktree。`diff_file`、三层 staging diff、revision/worktree diff 与 Shelf local diff 使用同一套内建 canonicalization；`binary` 属性保留原始字节。现在新增显式设置开关：默认仍不执行自定义 clean/smudge filter 或非 UTF-8 `working-tree-encoding`，开启后通过临时 object store + system Git `hash-object`/`cat-file --filters` 执行，并统一受进程组超时保护；目标属性预检、暂存、checkout、resolve 和 attributes-aware diff 使用同一策略。剩余是外部转换的大仓库级缓存，以及按安全决策仍默认不执行的 external diff/merge driver，不再把 clean filter/encoding 执行本身列为缺口。

Staging 的版本查看入口也已补齐：Changes 文件右键现在按版本存在性显示 `Show Local Version` 与 `Show Staged Version`；后者通过 Rust `read_index_file` 读取真实 index blob，而不是把当前 worktree 内容冒充 staged。`FileContentView` 会按 Local/Index 选择对应的 `diff_file` 行变更、二进制和截断策略；当两侧都存在时，查看器顶部可直接在 Local/Staged 间切换，状态模型变化后只保留仍存在的版本并自动切换到有效侧；workspace 的每次可见 status/index 刷新都会递增 refresh token，查看器自动重新读取，旧的异步读取和 blame 结果也不会覆盖新代际。仍有明确差异：IntelliJ 的 `GitIndexVirtualFile`、caret 在 Local 与 Staged 间的行转移、原生编辑器导航和 UI automation 尚未复刻。

本轮对照 IntelliJ `GitQuickListContentProvider` 与 `GitUnstashDialog`：顶栏 Git 快捷动作的参考集合是
Branches、Push、Stash、Unstash、Worktrees、Stage、Copy Current Branch Name、Resolve Conflicts 和
Unshallow，Arbor 的 `More Git Actions` 已覆盖这组入口，并新增与工作区操作一致的 `Unstash Changes…`
对话框。该对话框已提供 stash 选择、View Diff、Drop、Clear、Apply/Pop、Restore staged state 和
Create Branch from Stash；但当前仍绑定窗口的活动 repository，尚未复刻 IntelliJ 对话框中的多 root
Git Root chooser。现已补齐 root-scoped 选择、异步 stash 列表/当前分支加载，以及 Apply/Pop/Drop/Clear/
View Diff/Create Branch 的 root 路由；该动作组仍因完整上下文 action model 与其它工作区长尾而保持 partial。

`Git.Stash.UnstashAs` 的分支创建入口也已进一步对齐：Create Branch from Stash 现在复用选中 Git root 的 `validate_branch_name`，输入阶段会阻止空白、非法 ref 名和已存在分支提交；输入分支名时自动锁定 Pop/Restore staged state，清空输入后两项状态会按 IntelliJ 行为复位。引擎仍使用真实 `git stash branch` 语义，UI automation、DialogWrapper 的原生焦点/help 生命周期和细粒度通知仍保持 partial。

本轮新增 Branches Dashboard 对照实现：多 root Log 分支树的单引用 action group 现在按
local/remote、当前分支、tracking、protected 和所属 root 计算；Checkout、Update、Merge、
Rebase、Push、Fetch、Upstream、Rename、Delete 均使用行所属 root 的操作入口。多 root
面板顶部 New Branch 改为使用 multi-root dialog，避免误落到当前窗口 repository。多选
local branch 现在补齐 IntelliJ 的 Compare Branches、Show Files Diff、Update Selected、Delete Selected：
Compare Branches 与 Show Files Diff 只在同一 root 的两个不同分支间出现；前者按两侧独有提交历史
比较，后者按 branch HEAD 展示文件差异；Update/Delete 按每个引用的 root/name 执行并汇总
partial result，成功删除保留逐 root 的精确恢复上下文。Log Branches dashboard 现在还按项目
持久化 IntelliJ 的 Navigate Log / Filter Log / Select Only 分支选择行为；仍未完成的是 remote/group selection
的更多跨 root action 统一菜单聚合以及 UI automation；本轮已补上 configured remote group
（包括没有 tracking branch 的 remote）的 root-qualified selection、单选 Edit/Remove Remote、
多选 Remove Remote 和 Configure Remotes 入口，且主 Branches Popup 与 Log dashboard 共用
这组 group-node action 语义。remote branch 多选的 Compare/Delete 已按
BranchInfo 语义接入，删除按 root/name 汇总 partial result，protected remote 会阻止批量删除。

2026-08-24 Compare Branches 行级 action 校正：参考 `GitCompareBranchesUi` 的两侧 VCS Log 行仍应保留普通 Git commit action group。Arbor 的双栏比较视图现在为两侧 unique commit 行提供 View Details、Checkout Revision、Reset Current Branch、Create Branch、Compare with Current、Interactive Rebase、Cherry-pick 和 Revert；这些入口统一复用现有 root-qualified Log handlers，Compare 会按选中 commit 的 owning root 读取当前分支，interactive-rebase 沿用现有可用性判断，merge commit Revert 禁用。仍缺完整 IntelliJ VCS Log 双窗的 filter/graph/action lifecycle 与 UI automation，但比较行不再只有点击选中这一种交互。

2026-08-24 Compare Branches filter parity：参考 `GitCompareBranchesUi` 为上下两个 `VcsLogPanel` 各自保留过滤器状态，Arbor 双栏 unique-commit pane 现在分别支持 Message/Hash、Author、Since、Until、Regex、Match Case 和 No Merges；日期沿用主 Log 的严格解析，hash 查询在对应 range 结果上按 commit ID 前缀过滤，异步结果会校验 branch、root 与 filter snapshot 后再发布。仍缺完整 VCS Log graph、IntelliJ permanent VCS Log 的原生分页/refresh lifecycle、独立 native DataContext/action group 与 UI automation；查询数量限制不再是 500 条硬上限。

本轮新增（2026-08-19）：进行中的 Merge/Rebase/Cherry-pick/Revert 现在使用统一的
`operationRecovery` Codable 请求承载 Continue/Skip/Abort/Open Recovery；错误反馈和项目
重开后的 operation state 会生成按 Git root 稳定分组的恢复通知，Operation Log 与 macOS
通知可跨重启恢复这些动作。请求执行前仍校验 project/root；通知指向非当前 root 时只
打开对应 root 的恢复工作台，不复用当前窗口的 `repo`。仍缺的是 IntelliJ 完整的
VcsNotifier 生命周期/通知分组、跨 root 的统一操作聚合，以及更丰富的 merge-topology
专用 action 语义。

本轮又对齐了 IntelliJ `GitMergeDialog` 的 options popup：单 root Merge 现在将
`--no-ff`/`--ff-only`/`--squash` 与 custom message、no-commit、no-verify、
allow-unrelated-histories 按同一兼容矩阵呈现，冲突选项会禁用；只有显式启用
custom message 才显示提交信息输入框，且策略/选项按标准化 project path 记忆。
multi-root Merge 现在也复用同一 popup 与选项参数；剩余差距收敛为跨 root 统一
DELETE/NOTHING 确认和 rollback action 聚合。

## P1：值得继续补齐的真实能力

2026-08-22 多 root Commit workflow 校正：Git Roots 的 `Commit All` 已从隐式 `WIP` 提交修正为显式提交工作流：先读取每个 root 的暂存/冲突状态，打开 root 选择与提交信息对话框，只对用户选中的 root 执行经过 trim、非空校验的提交信息，并按嵌套 root 依赖顺序提交；未选 root、无暂存变更 root 与冲突 root 会分别显示为 skipped/不可选，结果仍逐 root 汇总。引擎也拒绝未知 root 和空提交信息，回归测试验证只提交选中 root 且未选 root 的 index 保持不变。本轮又接入单 root Commit workspace 的内置身份/冲突检查、项目 before-commit 命令、author/committer 覆盖、sign-off、co-author、amend、template/recent-message 与 skip-hooks 选项；自定义检查失败或普通 partial failure 后，失败 root 会以携带完整提交选项的 Codable `Retry Failed Commits` semantic action 进入反馈历史/原生通知，重启后只重试失败 root，不重复已成功 root。仍缺跨 root atomic transaction、完整非模态通知历史分组和 UI automation。

2026-08-26 Commit identity scope 校正：参考 fork 的 `GitVcsOptions.isSetUserNameGlobally` 与 `GitCheckinHandlerFactory.setUserNameUnderProgress`，Arbor 的身份检查现在读取 Git effective config，不再只看 repository-local config；Git Identity sheet 按 project path 记忆 global/local 选择，global 模式只把 `user.name`/`user.email` 写入 global config 并清理当前 root 的同名 local override，signing 配置仍保持 local。单 root 身份缺失后保存成功会自动重试原提交，取消设置不会遗留 retry；multi-root 只要任一 root 缺身份，失败汇总会提供 root-safe、Codable 的 `Configure Git Identity…` action，可从 Operation Log/native notification 重启恢复后再执行原 Retry。Git identity 的 detached-rebase 特殊提示、原生 `DialogWrapper`/`VcsNotifier`/`DataContext` 生命周期和 UI automation 仍是 partial。

2026-08-26 Previous commit authors 校正：参考 fork 的 `GitVcsSettings.PREVIOUS_COMMIT_AUTHORS`（16 条、去重、MRU）与 `GitCommitOptions` author editor，Arbor 现在按标准化 project path 保存提交 author 历史，单 root、Commit and Push 与 multi-root Commit 都在启动实际提交前记录有效 author；Git Identity sheet 提供 Recent authors 菜单并只回填 author name/email，不覆盖 committer。空值不入历史，项目之间不串历史，超出 16 条时淘汰最旧项；原生 `CommitOptionsPanel`/workspace component 生命周期和 UI automation 仍为 partial。

2026-08-22 多 root Changes Browser 校正：Git Roots 的聚合 Changes Browser 现在不仅按 root 显示只读 diff，还提供 root-qualified 的单文件 Stage/Unstage、每个 root 的 Stage All/Unstage All 和 context-menu 入口；每个 mutation 都重新打开行所属 Repository，并在完成后刷新聚合状态，不能误写当前窗口的 primary repository。失败时四类 mutation 会把 root/path 与操作类型编码进 Codable `Retry Stage`/`Retry Unstage`/`Retry Stage All`/`Retry Unstage All` semantic action，写入 FeedbackCenter、Operation Log 和可替换的稳定通知 ID，重启后仍只重试对应 root。此前错误反馈中的字面量 `(rootPath)`/`(path)` 也已修正为实际值。剩余差距是 IntelliJ 原生 ChangesView/DiffManager action lifecycle、更完整的跨 root 统一 action history 和 UI automation。

2026-08-23 多 root Changes Browser 多选校正：项目级 Changes Browser 现在使用 macOS 多选绑定，提供跨 Git root 的 Stage Selected / Unstage Selected；每一行仍以 (rootPath, path) 作为独立身份，同名相对路径不会串仓。批处理按 root 稳定串行执行，某个文件失败不会阻止其它 root/文件，部分失败的 Retry semantic action 只携带未成功的 root-qualified 路径，并可跨重启恢复；旧的单路径 Retry payload 保持兼容。

2026-08-23 多 root Changes Browser 选中文件 Commit 校正：选中 staged 文件后可直接进入 Commit Changes 对话框，按 root 分组展示并保留 initial selection；Commit/Commit and Push 通过 root-qualified `MultiRootCommitSelection` 进入 Rust 临时 index，只有选中文件的 staged blob 被写入临时 index，未选中的 staged 文件、部分 staged 文件的 worktree 改动和其它 root 的 index 均保持不变。rename 会保留 old/new 两端，失败或取消时 Retry semantic action 只携带失败 root 的选中文件，并跨重启恢复完整 Commit options。剩余差距收敛为跨 root atomic transaction、IntelliJ 原生 ChangesView/DiffManager action lifecycle、更完整的统一 action history 和 UI automation。

### 1. Shelf 的完整 changelist 生命周期

参考实现用 `ShelveChangesManager` / `ShelvedChangeList` 管理 changelist 元数据、最近删除列表、列表级/文件级恢复和回收；Shelf tree 由 `ShelvedTreeModelBuilder` 构造两层 changelist → change 节点。

当前 Arbor 可以按 shelf 名称分组、预览、重命名、整组或成员级 unshelve/drop，并且已经有重启可恢复的三方冲突现场。`ShelveInfo` 现在还持久化 description、最近生命周期更新时间、`recycled`/`toDelete`/`deleted` 状态和 Recently Deleted 信息；整组 Unshelve 会进入可恢复的 recycled 状态，部分 Unshelve 会拆成“原 shelf 剩余成员 + 独立 recycled 副本”，删除会移动到独立的 `refs/shelved-deleted/*` 和 `.git/arbor-shelves-deleted`，UI 默认隐藏 recycled 并提供显示开关，读取时可将 pending delete 收敛为 deleted。Unshelve 对话框已持久化 IntelliJ 的 `Remove Applied Files from Shelf` 策略：关闭时应用后保留并回收到 recycled，开启时整组应用成员进入 Recently Deleted，部分应用成员拆成独立 deleted changelist；冲突完成路径也沿用同一策略。工作区 Unshelve 与明确的 Pop 已分开：前者默认保留 Shelf，后者才在成功应用后消费 Shelf。UI 可跨重启恢复或永久删除，读取回收区时会按 IntelliJ 的 7 天规则自动清理过期项。外部导入 patch 以独立文件存于 `.git/arbor-shelf-patches`，列表、预览、重命名、成员删除、回收区移动和重启恢复都保留原始 patch；Unshelve 时才做三方/clean apply，并可持久化冲突现场。

本轮还补上了 Changes Browser 的本地 Changelist 领域：`.git/arbor-changelists` 原子持久化列表顺序、默认/活动列表、路径归属和成员顺序；Rust API 与 SwiftUI 已接入创建、激活、重命名、删除后回到 Default、文件右键移动和拖拽到列表。Shelf 静默拖拽也会按源 Changelist 分拆生成多个 ShelvedChangeList；Shelf 成员现在可以跨列表拖拽或通过菜单移动，最后一个成员迁移后源列表进入 Recently Deleted；Shelf/成员拖入具体目标 Changelist 会直接 Unshelve 并按目标归属，冲突恢复快照也持久化该目标。新增的 Shelf lifecycle monitor 在项目打开时立即对所有 Git roots 收敛 pending delete，并每天协调清理 7 天前 Recently Deleted 条目。Restore/Drop 反馈 action 现在携带可 Codable 的 project/root/shelf 语义请求，Operation Log 与原生通知都能跨重启恢复并路由到匹配窗口，旧窗口或错误仓库会安全忽略；其它通用闭包 action 仍只在当前进程有效。仍没有：

本轮又对齐了 IntelliJ `GitChangesSaver.notifyLocalChangesAreNotRestored()` 的关键恢复入口：dirty Pull 在自动 Shelf 或 stash 恢复失败/产生恢复冲突时，FeedbackCenter 会提供可持久化的 `View saved changes…` action。该 action 携带 project/root、保存类型和稳定 Shelf 名称或 stash commit id；当前进程、原生通知和重启后的 Operation Log 都会打开 Commit/Shelf 区并直接加载对应 diff 预览。它覆盖了自动 Pull 这一已存在的非对话框来源，但不代表所有系统自动 Unshelve 来源都已覆盖。

本轮继续收紧了 Pull preserving process 的身份与恢复边界：自动 stash 不再按 `stash@{0}` 猜测，而是贯穿本次唯一 message，先解析精确 stash commit 再恢复；恢复统一带 `--index` 语义，保留 staged/unstaged 边界；保存阶段没有实际创建 stash 时不会误弹出已有用户 stash。成功恢复、stash pop 冲突、远程失败后的恢复冲突以及手动恢复入口都共用这条精确引用。

本轮又把同一条边界补到 Smart Checkout 及其多 root/Checkout and Update 共享 preserving helper：Stash 保存现在直接保留 `stash_save` 返回的 object ID，恢复按该 ID 执行并带 `--index`，不再依赖 `stash@{0}`。因此用户或后台任务在 checkout 期间新增 stash 时，不会把别人的 stash 误应用或删除；单 root 与多 root 的 staged/unstaged 恢复也保持一致。参考依据是 IntelliJ `GitStashChangesSaver` 保存每个 root 的 stash commit 并在恢复时使用该 root 的引用。

本轮再补齐保存现场失败后的 IntelliJ 交互尾部：Smart Checkout、root-scoped revision checkout、Checkout and Update 的 stash/Shelf 恢复冲突会提供可持久化的 `View saved changes…` action。Stash action 携带精确 object ID，Shelf action 携带精确 Shelf name，并始终携带 project/root；多 root preserving 通过操作前后的 per-root saved-artifact 集合确定新增对象，通知与 Operation Log 不再依赖当前选中的 Repository 或 stash index。重启后 action 会重新打开对应 root 的 Commit/Shelf 预览；冲突仍进入 root-specific resolver，保存现场不会因通知刷新而丢失。更完整的 provider/action grouping 仍属于 checkout 的 partial 长尾。

另外补上了 Pull 自身 merge/rebase 冲突后的尾部生命周期：用户 Continue 完成 Git operation 后，单 root 会自动恢复该次 Pull 的 Shelf/stash；恢复冲突进入同一个 Merge Revisions 工作台，stash 使用精确 index，Shelf 使用持久化 restore snapshot；恢复失败会保留 saved-changes 预览 action，不再把“Git operation 已完成”和“本地现场尚未恢复”混成一个成功状态。

2026-08-25 saved-changes action 校正：对照 IntelliJ `GitChangesSaver.notifyLocalChangesAreNotRestored`，Arbor 现在为单仓库 Rebase 的取消/失败/暂停以及启动后发现的 Rebase 保存标记提供准确的 root-qualified `View saved changes…`；Rust 从 Rebase 专用 marker 返回稳定的 stash object id 或 Shelf name，启动扫描不会把 Rebase 恢复误导为 Apply 冲突 resolver。仍缺完整原生 notification grouping、display-id/action lifecycle 与自动 Unshelve 的全部细节。

本轮还补上了 IntelliJ `RestoreShelvedChange` 的列表级交互：Recently Deleted 支持 Cmd 选择多个已删除 Shelf，并以一次 `Restore Selected` 或 `Delete Permanently Selected` 处理选中列表；恢复与永久删除逐项执行并报告 partial result，单项菜单入口保持不变。本轮进一步为两条批处理加入逐项 `completed/total` 进度、稳定 notification ID，以及只携带失败列表的 Codable `Retry Remaining Shelf Actions`；Restore 成功项保留反向 Drop action，重启后仍可路由到同一 root。

本轮又对齐了 IntelliJ `UnshelveWithDialogAction.unshelveMultipleShelveChangeLists()`：Shelf 区支持 Cmd 多选多个列表，先统一选择目标 Changelist 与 `Remove Applied Files from Shelf` 策略，再串行应用到同一目标；每个列表独立保留成功/失败结果，遇到冲突会暂停并持久化目标 Changelist 供恢复流程继续。单 Shelf 的文件级 patch 选择已覆盖，本轮再补文本 hunk 选择、binary/rename-only 文件级选择，以及部分 hunk 的 Recently Deleted/remainder 生命周期；其它非远程自动 Unshelve 来源已覆盖，剩余是 differentiated patch viewer 的细节和回收列表 action model。

本轮继续补上 IntelliJ `ChangesView.UnshelveSilently`：选中一个或多个 Shelf 后，Shelf 工具栏提供非对话框 `Unshelve Silently`，并绑定 `Ctrl-Alt-U`；它复用 `CREATE_CHANGELISTS_AUTOMATICALLY` 的逐 Shelf 目标策略，串行应用到同一 worktree，普通失败继续收集 partial result，冲突则暂停并保留可恢复目标。Recently Deleted 区现在也支持 exact selection 的静默 Unshelve：引擎直接从 deleted ref/patch apply，不先伪装 Restore；默认保留 deleted list，Remove Applied 开启时只移除已应用成员，整组应用后永久消费该 deleted list。删除列表下的文件成员也会展开，提供 `Unshelve Changes` / `Unshelve Changes and Remove` 直接入口，并支持 deleted patch 预览。批量 Apply/Pop/Unshelve 现在已有逐列表进度和 Retry Remaining semantic action，非远程系统来源已覆盖，剩余差距是 differentiated patch 内部进度和更完整的回收通知/撤销语义。

本轮继续对齐 IntelliJ `MyShelveDeleteProvider` 的成员级永久删除语义：Recently Deleted 中的文件成员右键现在提供 `Delete Permanently`，多选成员会合并为一次 path-scoped 删除；Rust 只从 deleted patch 中移除选中的 change chunks，未选成员继续保留，删除最后成员才清理整组 ref/patch/metadata。失败反馈带精确 project/root/Shelf/path 的 Codable Retry action，并可跨重启路由。

本轮补齐 Shelf 工具窗缺失的 IntelliJ `ApplyShelfAction` / `PopShelfAction`：每个 active Shelf 以及 active 多选都可直接 `Apply (Keep)` 或 `Pop (Apply and Remove)`，不再被迫进入 Unshelve 对话框或受 `Remove Applied Files` 默认设置影响。多选 Pop 按列表串行执行，普通失败保留后续列表，冲突立即暂停并复用持久化 Shelf restore snapshot 与 Merge Revisions；批量 action context 与逐列表进度已补齐，仍缺完整 `MatchPatchPaths` 候选排序细节和其它细粒度回收 action。

本轮继续对齐 IntelliJ `ShelveChangesManager.unshelveSilentlyAsynchronously` 的批量运行语义：多 Shelf Apply/Pop/Unshelve 在工具栏显示逐列表 `completed/total` 进度，并在 partial、失败或冲突结果中生成带 project/root、Shelf 列表、操作类型、目标 Changelist 和 Remove Applied 策略的 Codable `Retry Remaining Shelves` action；该 action 会进入操作历史和原生通知，重启后仍可路由回原仓库。其它非远程自动 Unshelve 来源已覆盖，剩余是完整回收列表 action model 与更细的 notification 分组。

本轮再补齐 IntelliJ `UnshelveChangesAction` / `UnshelveChangesAndRemoveAction` 的成员级非对话框入口：active Shelf 与 Recently Deleted tree 的单个文件成员右键，以及已选成员的列表菜单，现在可以直接 `Unshelve Changes`（保留来源列表）或 `Unshelve Changes and Remove`（只消费已应用成员）；原有 `Unshelve` 仍保留用于文件/hunk/目标 Changelist 对话框。两条入口共用 Rust 的路径选择、自动 Changelist、冲突快照和 Recently Deleted 生命周期；因此剩余的系统来源主要收敛为完整 `MatchPatchPaths` path-strip/context 匹配、更细的回收通知/撤销语义，以及参考实现中远程开发专属的 `ShelfRemoteActionExecutor`（按产品边界明确不纳入插件平台）。

2026-08-23 Shelf action context 校正：参考 fork 的 `ShelfTree.uiDataSnapshot`、`ShelveDeleteProvider`、`RestoreShelfAction` 和 `FrontendUnshelveAction`，父 Shelf 与选中成员必须从同一棵树的选择上下文派生。Arbor 现在复用 `shelfDeletePlan` 作为顶部 action menu 的选择计划：整 Shelf 选择屏蔽该 Shelf 的子项，跨 Shelf 子项按所属 Shelf 分组，active 与 Recently Deleted 分别提供 Apply/Pop/Drop、Unshelve、Restore 和永久删除；Recently Deleted 分区只负责展示，不再产生重复的列表级菜单。刷新后 active 与 deleted 两侧的成员选择都会按当前 patch 路径回收。跨多个成员组的成员级写操作现在由一个串行 runner 统一执行，反馈只发布一条稳定通知并提供 aggregate progress/failed-group Retry；active Drop 的 Recently Deleted 恢复也使用一个 timestamp-preserving batch Undo。剩余差距收敛为原生 DataContext/binary wrapper/navigatable provider、树编辑 lifecycle、完整回收列表 action/display-id 分组和 UI automation。
2026-08-24 Log Changes Browser merge-target rewrite 收口：对照参考 `GitDropSelectedChangesOperation.restoreChanges()` 使用 `commit~1` 的语义，Arbor 现在以 merge 的 first-parent tree 校验所选路径；Drop/Extract 重写目标 merge 时保留全部原始 parents，Extract 将改写后的 merge 作为剩余变更提交再生成完整树的新消息提交，目标后的线性与 merge descendants 都按 first-parent patch 重放并保持 parent 拓扑。Changes Browser 只有 first-parent merge diff 才开放该 action；gitlink、全选和无法安全重放的冲突仍 fail-closed，native Merge Dialog/VcsNotifier/UI automation 仍是剩余差距。

本轮同时补齐单 Shelf `UnshelveWithDialogAction` 的 patch 选择交互：对话框显示文件节点及文本 hunk，支持逐 hunk 选择、全选/清空、binary/rename-only 文件整体选择、目标 Changelist 与移除已应用文件策略；Rust 引擎按同一选择生成 apply patch，未选 hunk 不进入工作区，也不会从原 Shelf remainder 中误删。对话框现在增加文件级结构化 diff pane：revision-backed Shelf 可切换 side-by-side/unified，导入型 raw patch、binary 或缺少 base 时保留原始 patch 回退并展示原因；文件选择器支持 IntelliJ 风格目录展开/折叠、扁平切换及 Added/Deleted/Modified/Renamed 数量图例；imported patch 现在可以手动选择仓库内 base directory，并通过真实 `git apply --directory` + `-pN` 组合完成 IntelliJ 的 base/path-strip 映射；候选发现会对多个文件求交集，同时检查现有文件与目标父目录，并用 IntelliJ 对齐的逐 split-hunk 上下文信号（预期行号 ±100、最多 5 个片段）做候选排序；project-scoped recursive physical/VFS-like discovery 已覆盖 package descendants，新增文件的同分歧义会回退 project root，用户仍可从 Suggestions 手动调整 base 与 strip。imported Shelf 文件预览现在在隔离临时目录中复制当前 worktree 目标文件、按所选 base/strip 试应用 patch，再生成真实 Local → Applied Patch 的结构化 diff；Git 精确位置失败时会用同一隔离目录中的 context-aware patch fallback，因此本地额外行和可偏移应用会反映在预览中，无法 clean preview 时仍保留 raw patch。raw imported/hunk apply 现在还会逐文本 hunk 让 Git 正向/反向 check，跳过已应用 hunk，并按文件块逐一尝试剩余片段；普通失败块恢复到应用前快照并留在 Shelf remainder/Recently Deleted，成功块保留，整块已应用仍视为成功 no-op，冲突则暂停并保留可重启快照；binary、rename、copy、mode-only 和无法判定的片段继续走原有 apply/冲突路径。本轮又将外部监听升级为带具体路径的、去重的 worktree/Git metadata 事件，并让自动刷新按 scope 只失效可见状态或仓库元数据；纯 worktree 文件批次现在优先通过 Git pathspec 做 status 增量合并，目录、根路径、删除竞态和无法安全归一化的事件仍回退全量 status。当前仍与 `MatchPatchPaths` 有边界差异：root-scoped dirty-scope manager 已接入祖先路径压缩、30 项目录提升、递归父事件的嵌套 root 传播，以及 pending/in-progress/processed 生命周期；仍缺 FilenameIndex 过滤、ApplyPatchViewer 原生编辑器与生命周期 action/notification 细节，以及更细的 Recently Deleted action/notification model。

本轮又对齐了 IntelliJ `VcsApplicationSettings.CREATE_CHANGELISTS_AUTOMATICALLY`：设置默认关闭，开启后无显式 Changelist 目标的整组 Unshelve、成员级 Unshelve 和 Pop 会按 Shelf description 幂等创建/复用目标列表；冲突恢复也持久化这个目标。显式拖入目标 Changelist 继续优先，且自动归属只管理 Changes Browser 元数据，不改变 Git index/worktree。

本轮补上了 IntelliJ `ApplyPatchAction` 的独立入口：VCS > Git > Apply Patch… 读取普通 unified patch 或 Git patch，复用 differentiated 文件/hunk 选择器、目标 Changelist、base directory 与 `-pN` 映射；普通 `---`/`+++` 多文件 patch 现在也能独立拆分、选择并在 Rust apply 后保持正确的 mapped path。direct Apply Patch 不创建 Shelf 元数据，clean apply 直接结束；冲突则持久化 worktree/index 快照、实际生效的过滤后 patch 与 direct 标记，并进入独立命名的 Apply Patch 冲突工作台，完成或回滚后清理 direct restore 状态，重启后仍能恢复 patch 侧语义。冲突文件提供结果/只读 Patch 双栏编辑器，文件级/冲突块级操作明确区分“保留本地”和“应用补丁”；冲突工作台现在维护基于 `path#index` 的稳定 patch hunk 状态（Ready / Already Applied / Not Applied / Applied / Ignored），支持结果或 Patch 编辑器选区驱动的 `Apply Selected Changes` / `Ignore Selected Changes`、`Apply Non-Conflicts` 与 `Previous/Next Unresolved`，操作后实时重解析剩余 hunk、同步双栏滚动、Patch gutter 逐 hunk 的 Apply/Copy/Ignore 操作并显示本次会话处理数；applied、automatically applied、ignored 决策按 path#index 写入恢复快照，重启后恢复，Reset 清理当前文件决策。raw patch 现在也能生成结构化 `FileDiff` 预览；imported patch 文件预览会在隔离临时目录中按当前 worktree、base directory 与 `-pN` 试应用，再生成真实 Local → Applied Patch diff，Git 精确位置失败时保留 context-aware fallback，无法 preview 时仍回退 raw patch；候选发现会合并 Git index-backed path index 与 project-scoped recursive physical scan，覆盖 package descendants 中的 tracked/untracked 文件；新增文件的同分候选会回退 project root，文件树还会在提交前标出 base 缺失、目标已存在、path-strip 越界等不可应用项，并允许先调整映射。外部监听现已提供去重的具体路径事件并按 worktree/Git metadata 范围刷新；仍与 IntelliJ `ApplyPatchViewer` 有差异：基础 dirty-scope manager 已接入，但精确 RootDirtySet 增量分类、FilenameIndex 候选过滤，以及更细的 Recently Deleted action/notification model 仍缺。

本轮又补上 `MatchPatchPaths.workWithNotExisting` 的长尾：当新增文件的末端目录尚不存在时，会从已索引的中间目录/文件反推 repository base 与 `-pN`，例如 `community/platform/.../colors/New.java` 可得到 repository root + `-p2`，不再错误退回 `-p0`；该推导与多文件候选求交集、上下文排序共用同一候选模型。

外部变更同步又补上 ignore 规则的失效范围：根级或嵌套 `.gitignore` 修改现在放弃单路径 status 增量，触发该 Git root 的完整 status refresh，避免新增/删除 ignore 规则后其他 untracked/ignored 行保持陈旧；`.git/info/exclude` 仍由 Git metadata scope 触发同样的全量路径。Arbor 现在有 root-scoped dirty-scope manager，明确区分 pending、in-progress、processed，并提供 pack/belongsTo；本轮又接入逐文件 dirty ledger、祖先路径压缩、30 项目录提升和递归父事件的嵌套 root 传播。operation recovery 通知现在也按 root 追踪、按状态 fingerprint 去重，外部 metadata refresh 和嵌套 root 都能触发可恢复通知；歧义目录 rename 会进入逐文件候选 review，只有用户选中的新/旧端点才分别按 Add/Remove 设置执行；当前剩余是业务通知尚未全部迁移到精确 IntelliJ display-id，以及原生权限/banner/UI automation。

linked worktree 的 Git metadata 监听现在同时覆盖 worktree-specific Git directory 与 `commondir` 指向的 common Git directory：HEAD、index、operation markers 与 refs/tags/branches 的外部变化都会进入当前 root 的 metadata refresh；解析兼容 Git 生成的相对路径、空白和 CRLF。operation-state 的 root-scoped recovery notice 已随 metadata refresh 更新并在状态未变化时去重；仍未完全复刻 IntelliJ 的逐文件状态细分、原生 VFS permission/banner/UI automation 和全部外部设置驱动事件分类。

对照 IntelliJ `GitVFSListener` 后，本轮已补齐外部 VFS create/delete 的主要动作语义：Arbor 提供独立的 Add/Remove 设置（Ask、Perform silently、Do nothing），Ask 模式现在可在可滚动路径列表中逐文件选择；新增路径先以 Git status 过滤为真实 untracked，固定 staging area 下通过空 blob index API 保留 `AM`（staged 新增 + unstaged 实际内容）语义，删除路径只选择 tracked + deleted 并执行 `git rm --cached --ignore-unmatch -r --`；目录创建会展开到 status 子路径，ignored/modified 文件不会被误操作。watcher 现在通过唯一设备号+inode 配对可靠的文件、目录及目录子项 rename 旧/新端点，case-only move 使用与 IntelliJ 一致的 `git mv -f` 保留大小写和 move 语义；无法唯一配对时先做完整 status reconciliation，Git 提供唯一旧路径时执行 Add+Remove，且大小写变更会继续走独立的 force move，或非目录事件中的唯一 untracked 新路径与唯一 deleted 旧路径时执行 Add+Remove；目录事件若旧端点身份缺失或冲突，则按相对后缀生成旧/新文件候选，进入明确的 `Review ambiguous Git moves` 选择后才按 Add/Remove 设置执行，未选或未匹配的路径仍保守只走新端点 staging 并保留全量刷新。结构化 dirty-scope 已区分精确文件、递归目录、rename 父目录和全量回退；status/staging 模型现在保留 rename/copy 的 `oldPath` 并让三层版本与 `IndexToHead` diff 回溯 HEAD 旧端点；ContentView 现在按 root 合并 scope/path/rename origin 后再统一消费，`created + modified` 仍保留新建语义；重叠刷新会升级后续增量请求为全量，并只允许最新 ticket 发布 status、metadata 与错误，避免异步结果倒序覆盖；root-scoped dirty-scope manager 现在提供逐文件 pending/in-progress/processed ledger、pack、belongsTo、项目切换清理、祖先路径压缩、30 项目录提升和递归父事件的嵌套 root 传播；新增 root-scoped external-action ledger，按 IntelliJ StateProcessor 语义合并 pending create/delete/rename，等待可见 refresh 完成后逐 root 串行读取 status、确认并执行 Git action，后续事件不会与当前 action 并发；当前剩余是原生 VFS permission/banner/UI automation、完整 action history，以及业务通知尚未全部迁移到精确 IntelliJ display-id。

`MatchPatchPaths` 的候选源现在已经有显式 project-scoped provider：`RebasedPatchFilenameIndex` 合并物理项目文件、Git index-backed 路径和调用方注入的 virtual/index 路径，并在生成候选前应用 `RebasedPatchCandidateScope` 的 content/excluded 边界；默认排除 `.git` 及 Shelf resources，不再把排除规则写成 `.idea`、build 等猜测性黑名单。它仍不是 IntelliJ 的持久化 VFS/PSI `FilenameIndex`：多 content-root 项目模型、VFS dirty-scope 生命周期和完整 IDE 索引更新通知仍缺。

本轮还修正了 imported patch 的 path-strip 边界：标准 Git `a/`/`b/` 头下合法的 `-p0` 不再被规范化路径检查提前拒绝；Shelf 成员仍使用规范化路径，实际 apply、冲突路径和恢复快照使用 raw endpoint 后再按 `-pN` 截断。新增跨目录回归覆盖该 apply 结果。候选评分现在以纯 Swift 回归覆盖 IntelliJ `GenericPatchApplier.weightContextMatch(100,5)` 的核心计分边界；仍保留上段列出的 fragment、VFS dirty-scope 和原生 ApplyPatchViewer action/editor 生命周期差异。

- IntelliJ 非远程的非对话框 Unshelve action 来源、精细 action/notification 历史和全部列表级恢复语义；`Remove Applied Files from Shelf` 的整组/部分应用、冲突完成持久化策略、基础的 `recycled` / `toDelete` / `deleted` 状态机、重启收敛、description 保留、Restore 与过期清理已覆盖。Shelf 菜单现在还提供明确的 `Clear Already Unshelved` action，按生命周期 cutoff 永久清理 recycled 列表；Restore/Drop、Recently Deleted 批量操作、active Shelf 多选 Drop、Recently Deleted 成员级永久删除以及 dirty Pull 恢复失败的 `View saved changes…` action context 已覆盖。删除 active Shelf 或其成员后的通知现在提供可跨重启执行的 `Undo`，并恢复删除前的原始时间戳；active Shelf 多选 Drop 现在收敛为一个携带 name→timestamp 映射的批量 Undo action，失败项可重试；仍缺完整回收列表 action model 和更细的通知分组。整组、成员级直接 Unshelve、Apply/Pop、部分成员操作和冲突完成现在会在 FeedbackCenter 及操作历史提供对应恢复 action，Restore 成功后提供反向 Drop action。远程开发专属 `ShelfRemoteActionExecutor` 已按产品边界排除。
- revision-backed Shelf 的内部 preservation restore 与 imported raw patch/hunk apply 继续复用统一 `GitProgressState`；用户可见的 active/Recently Deleted Unshelve、选中成员和 Changelist drop 以及 Pull/Checkout/Update/Rebase 的 preservation Pop 均使用逐文件 patch executor，按文件块返回 applied/failed，普通失败成员恢复并保留在 Shelf remainder/Recently Deleted，成功成员保留或消费，冲突暂停并保留可重启快照，完成后恢复原始 index 边界；binary、rename、mode-only 和不确定片段继续走原有 apply/冲突路径。
- 2026-08-25 preservation Pop 边界校正：普通用户 `shelve_pop` 仍保留兼容的 legacy path；自动保存现场改走独立 `shelve_pop_preservation` / cancellable preservation API，即使旧版本或异常恢复造成 temporary index sidecar 缺失，也不会退回原子 tree-merge。新增无 sidecar 冲突回归，验证逐文件 apply、持久化 restore snapshot 和完成后生命周期。
- Shelf 与 local Changelist 之间更细的列表级恢复、撤销和通知语义。

当前已补上 Shelf 的 Import Patches… / Export Patch… action：导出保留 binary patch
元数据，导入只解析并持久化原始 patch，不修改当前 worktree/index，也不要求当前
HEAD 能立即应用；Unshelve/Pop 才尝试 Git three-way，缺少 blob 元数据时再
fallback 到 clean context apply，冲突进入可重启恢复的快照流程。Changes tree ->
Shelf 的拖拽入口会静默创建唯一命名的 shelf；Shelf -> Changes 的整组/成员拖拽可直接
落入指定目标 Changelist，并在冲突恢复后保留该归属。Shelf 菜单还提供显式的
`Clear Already Unshelved` action，按 cutoff 永久清理 recycled 列表。剩余是未覆盖的非对话框
Unshelve action 来源、完整的回收列表 action model 和更细的通知历史；直接生命周期操作的 Restore/Drop
以及 dirty Pull 恢复失败的 `View saved changes…` 通知 action 已接入；Recently Deleted 还支持多选后的批量 Restore/Delete Permanently。

Arbor 仍采用固定 staging area（不提供 IntelliJ 的 staging/changelist 模式切换）；local Changelist 现在只管理 Changes Browser 的归属，不改变 index/worktree。Shelf 常规 revision-backed 条目已经支持 Base/Shelved 与 Local/Shelved 的结构化差异；剩余差距集中在导入 patch 的 differentiated 内容模型、系统触发、回收 action/notification model，而不是 Git 合并算法。

证据：参考 `platform/vcs-impl/.../ShelveChangesManager.java`、`ShelvedTreeModelBuilder.kt`；当前 `arbor-engine/src/repo.rs` 的 Shelf 生命周期入口、`arbor-engine/src/shelve.rs` 的列表/元数据持久化、`Arbor/RepositoryIndexRevisionMonitor.swift` 的后台 lifecycle monitor、`Arbor/RebasedWorkspaceViews.swift` 的两层 Shelf tree。

### 1.1. Uncommit 的目标 Changelist 与 HEAD 边界

参考 `git4idea.reset.GitUncommitAction`，Uncommit 现在会在执行 soft reset 前展示最近 HEAD、变更数量和目标 Changelist，支持已有列表或 inline 新建；完成后按提交树差异把实际恢复路径归入目标列表，rename 会同时保留旧路径和新路径，并将原提交完整信息恢复到提交编辑区。多 root Log 会按选中提交解析所属 Git root，目标 Changelist 也只从该 root 读取和写回。

root commit、缺少父提交或引擎失败会被明确拦截并反馈；空提交仍允许撤销，结果是回到父提交且没有需要恢复的工作区路径。detached HEAD 现在与 IntelliJ 的 reset 语义一致，直接更新 detached `HEAD`，同时保留暂存状态。执行前后都校验预期 HEAD，避免对话框打开后提交已变化时误 reset；若提交已到达匹配保护规则的 remote-tracking branch，则在 chooser 前阻断；chooser 会复用同名列表、遵循自动创建设置并前置校验非法名称。Uncommit 成功后现在发布 root-qualified、expected HEAD/branch 保护的可持久化 `Undo Uncommit` action；Undo 只移动 ref，不重写 index/worktree，且跨重启仍能安全 fail closed。回归测试覆盖 root HEAD、普通 HEAD、空提交、detached HEAD、stale HEAD、Undo 后保留本地现场以及 branch identity 改变。仍没有完全对齐的部分是 chooser 的完整键盘焦点/help 生命周期，以及更细的原生通知撤销细节；当前实现不把这些边界误报为已完成。

### 2. Conflict resolver 的非模态工具窗与外部/可配置 merge tool 路径（核心已补齐）

参考实现的 `GitResolveConflictsAction` 进入 IDEA 内建三方 MergeTool，并由 `GitMergeProvider` 提供 ours/base/theirs 的 Git 内容和分支状态。Arbor 现在除了原有三栏/文件级 resolver、Accept Ours/Theirs/Both、mark resolved、reset 和统一 operation recovery queue 外，还已补齐：

- 读取 Git 的 `merge.tool` / `merge.guitool` 配置，并通过 `git mergetool --no-prompt` 使用 Git 原生 `$BASE/$LOCAL/$REMOTE/$MERGED` 合同；
- 冲突文件可从 `ConflictDetailView` 直接打开外部工具，工具退出后重新读取 index stages 和剩余冲突列表；
- 单 root 与 multi-root 的冲突工作台默认以右侧非模态面板打开；Close 只隐藏面板，不改变进行中的 operation 或 Shelf/Stash restore 状态，操作栏或冲突通知 action 可重新打开同一 resolver queue；原有独立 resolver surface 仍保留 compact=false 的大尺寸布局；
- 成功、工具非零退出、未配置工具和路径不再冲突均有明确结果/错误，multi-root 复用同一 root-scoped 入口。

设置编辑器和进程级取消/强制终止现在已补齐：冲突文件可直接打开仓库级 mergetool 设置，运行中的 Git/mergetool 会由同一进程组取消，且取消结果保持为独立的用户取消状态。剩余长尾收敛为跨 root 原子回滚、完整撤销/通知历史和更细的 toolwindow 偏好持久化，不再把 modal/non-modal 作为默认交互差异。

证据：参考 `plugins/git4idea/backend/src/actions/GitResolveConflictsAction.java`、`merge/GitMergeProvider.java`；当前 `arbor-engine/src/repo.rs` 的 `open_external_merge_tool`、`Arbor/ContentView.swift` 的 `ConflictDetailView` 与 `arbor-engine/tests/conflict_workspace.rs` 的外部工具回归。

### 3. Rebase 的复杂历史与通知撤销语义

线性 interactive rebase、preserve-merges 基础路径、autosquash、drop/extract selected changes 已有实现和 Rust 测试；真实 merge graph 的 side-branch action 映射（pick/drop/reword）以及 dirty tracked/untracked local scene 的保存、edit 暂停后 abort/continue 恢复也已有回归覆盖。仍有差距：

2026-08-23 结构化 Interactive Rebase 的 `squash` 行现在提供完整的最终提交信息编辑：空白时保持 Git/Arbor 原有的默认合并信息，填写后通过 `SquashWithMessage` 穿过线性对象重放、`--rebase-merges` native sequence editor、root/multi-root 执行以及暂停状态序列化；SwiftUI 的单 root 与 multi-root todo 行都提供多行编辑区。参考实现的 `GitInteractiveRebaseEditorHandler` 在 squash 后进入非结构化 commit-message editor，当前差距不再是默认 squash 消息不可编辑，而是 native control-row 的更广 structured presentation、通知分组和 UI automation。

2026-08-23 structured todo 编辑历史已对齐参考 `GitRebaseCommitsTableModel` 的核心行为：单 root 与 multi-root 每个 root 独立保留最多 10 个状态，action、排序、Reset、reword/squash message 都可 Undo/Redo；新操作会截断 redo 分支，连续编辑同一 commit message 会合并为一次历史项。剩余差距仍是 native control-row 的更广 structured presentation、完整通知分组和 UI automation。

2026-08-23 structured todo 的 Squash/Fixup 多选也已对齐参考 `GitRebaseTodoModel.unite()` 的核心交互：单 root 与 multi-root 都支持显式选择；非连续选择会重排到同一 group，Squash 生成首行 kept root 加末行 squash message，Fixup 生成后续 fixup 行，单选时使用前一个 kept root。merge-preserving 的 native control-row 选择仍 fail-closed 并回退 raw/native 路径，完整控制行编辑、通知分组和 UI automation 仍缺。

2026-08-23 structured todo 的多选移动已补齐参考 `MoveTableItemRunnable` 的关键语义：单 root 与 multi-root 会按 commit identity 逐行移动非连续选择，重排后仍选中原提交，而不是让旧的行号 selection 指向别的提交。当前仍未覆盖参考 Swing table 的完整拖拽手势、native control-row 的更广 structured presentation、通知分组和 UI automation。

2026-08-23 标准 structured single-root RebaseTodoEditorView 新增真实 row drag/drop：拖动单个或已选中的多个提交到目标行时，按提交 identity 保留组内顺序并恢复 selection；preserve-merges 行现在允许 non-merge 提交只在同一 native branch segment 内重排，merge anchor 与控制边界保持固定，跨边界移动 fail-closed；重排后的 structured todo 暂时禁用 squash/fixup，避免静态 ancestry 能力误导。剩余差距是拖放到行间空隙的完整 Swing drop target、native control-row 的更广 structured presentation、通知分组和 UI automation。

2026-08-23 取消语义已对齐参考 `GitInteractiveRebaseDialog.doCancelAction()`：structured single-root、multi-root 与 native todo 在有未保存修改时都会弹出 Discard Changes 确认，Keep Editing 保留当前编辑，Discard Changes 才关闭；未修改时直接取消。剩余差距仍是 native control-row 的更广 structured presentation、完整通知分组和 UI automation。

2026-08-23 structured single-root RebaseTodoEditorView 新增 IntelliJ 风格的详情分栏：选中一个或多个 todo 行后，Arbor 通过 `commit_info` 按 revision 直接读取提交详情，并在只读面板展示 metadata、changes 与 diff；详情面板不暴露 Log 的 mutation actions。直接读取 revision 避免选中较旧提交时受当前 VCS Log 分页边界影响。随后 multi-root 编辑器补齐 root-qualified 详情分栏：每个 root 独立缓存 Repository，单选/多选只在当前 root 内按 todo 顺序加载，加载错误单独显示，不会跨 root 复用同名 commit。native control-row 的更广 structured presentation、完整通知分组和 UI automation 仍为 partial。

2026-08-23 native todo fallback 新增实时结构化预览：raw editor 旁边按行识别 commit action 与 `label/reset/merge/exec/break/update-ref` control row，并对未知/格式不完整的行提供非阻断诊断；raw text 仍保持可编辑，Git 仍负责最终语法校验和执行。这补齐了控制行的可理解性，但不宣称已经把这些命令转换成 Arbor 的可重排结构化 action；native control-row 的完整 structured editing、通知分组和 UI automation 仍为 partial。
2026-08-23 native todo fallback 新增实时结构化预览：raw editor 旁边按行识别 commit action 与 `label/reset/merge/exec/break/update-ref` control row，并对未知/格式不完整的行提供非阻断诊断；raw text 仍保持可编辑，Git 仍负责最终语法校验和执行。这补齐了控制行的可理解性，但不宣称已经把这些命令转换成 Arbor 的可重排结构化 action；native control-row 的完整 structured editing、通知分组和 UI automation 仍为 partial。随后 structured todo editor 补齐 `GitRebaseCommandsDialog` 对等的只读 `Commands…` 窗口，single-root 与 multi-root 都按当前 todo 展示 action/hash/subject，且不改变编辑状态。
2026-08-23 structured todo editor 补齐行级 context menu：single-root 与 multi-root 均按 topology 对适用行提供 Pick/Reword/Edit/Squash/Fixup/Drop，并可打开 Commands…；merge row 只提供 Pick/Reword；若当前行属于多选，则沿用该多选，否则只作用于当前行，遇到 merge row 的不适用批量 action 会 fail-closed。preserve-merges 仅允许同一 branch segment 的连续 Squash/Fixup，跨 merge/topology 边界由 UI 与结构化 helper fail-closed；native control-row 的完整 structured editing、通知分组和 UI automation 仍为 partial。
2026-08-23 interactive rebase no-op 语义补齐：对照参考 `GitInteractiveRebaseEditorHandler.confirmNoopRebase()`，single-root 与 multi-root 在没有可编辑提交时不再静默禁用 Start Rebase，而是显示明确的 Continue/Cancel 确认；multi-root 只把成功加载且空 todo 的 root 视为 no-op，加载失败仍保持阻断。native control-row 的更广 structured presentation、通知分组和 UI automation 仍为 partial。

2026-08-23 native control-row 编辑补充：raw todo 结构化预览现在可直接编辑 `label/reset/merge/exec/update-ref` 的参数，更新严格限制在目标行并保留其它行、注释及原始 CRLF/LF 换行；`break` 继续显示为只读停顿行。该能力推进了 `GitInteractiveRebaseFile` 的 control-row 交互，但完整控制行重排/命令类型转换、通知分组和 UI automation 仍未完成。

- IntelliJ Rebase Dialog 的 branch/repository 选择已接入真实的 branch positional 参数；多 root 现按嵌套依赖逐仓库执行，并在统一确认窗口中为每个 root 加载、编辑独立 todo（action、reword message、顺序），返回成功/暂停/失败/未尝试的结构化 partial result。跨 root 的持久化 resume spec、重启后的 Resume/Retry、暂停 root 的 Continue/Skip/Abort、成功 root 的 expected-HEAD 保护回滚、root-scoped Stage-and-Retry 与全量完成后的 expected-HEAD 保护 Undo 已完成；本轮把失败/暂停/重启恢复通知中的 Resume、Retry、Open Recovery，以及部分完成后的 Rollback/Keep Partial、成功后的 Undo，全部改为携带 session/expected-HEAD 上下文的 Codable semantic action，并统一使用稳定 notification ID；完整通知历史分组仍未完成；`--root`、`--keep-empty`、`--update-refs` 已接入原生 interactive rebase，并由 SwiftUI 暴露；
- `--rebase-merges` 现在在 Log 选中 merge commit 时使用第一个 parent 作为 upstream，结构化编辑器按原生拓扑展开 non-merge 与只读 merge topology 行并保留 Git 的 label/reset/merge 控制行；non-merge 的 pick/reword/edit/drop 可改，同一 native branch segment 内的 non-merge 行可重排，merge anchor 与控制边界保持固定，重排后结构化动作收窄为 pick/reword/edit/drop；未重排时处于同一 branch segment 且紧跟父提交的行可安全选择 squash/fixup，前驱 action 被改成 drop 时 UI 会自动解除无效依赖，Rust 也会拒绝没有 kept predecessor 的 squash/fixup，跨 label/reset/merge 边界的组合由后端 fail-closed；merge 行仍不能改 action，执行前校验完整 native row 集合、固定 anchor、branch-segment row set 和按 commit id 的 action 映射，并将编辑后的 non-merge order 回写到 Git native pick slots。与参考 fork 的 `GitInteractiveRebaseFile` 对照，single-root 与 multi-root 现在都可按 branch 捕获、编辑并原样回写完整 native todo；reword/squash 的消息编辑也由 SwiftUI 驱动，Continue 后仍可继续编辑。剩余是更完整的 root 拓扑语义、通知分组和 UI automation，而不是 raw todo fallback 本身；
- 2026-08-22 修正 multi-root preserve-merges 的真实执行缺口：branch-scoped todo 现在直接由 Rust 按 native merge order 生成并包含可见 merge 行，不再从只含 non-merge 的 range 反推；multi-root 会保留每行 action，执行器再将 merge 行转换为受约束的 pick/reword override，并将 non-merge action 对齐到 Git sequence editor。merge 拓扑、side-branch drop/reword 与 merge message reword 均有回归；剩余差距是 native 控制行的跨 root 通知分组和 UI automation。
- 本轮补齐 Log 根提交入口：根提交不再因为没有 upstream 被禁用，SwiftUI 会打开标注为 repository root 的 todo；Rust 通过真正的 `git rebase -i --root` 执行，线性历史支持 root 行的 pick/reword/edit/squash/fixup/drop 与顺序调整，并沿用原生冲突/暂停恢复；Log 的 Fixup/Squash to Commit 在提交后也会走 root autosquash，merge target 则在入口处明确拒绝并引导到 merge-preserving interactive rebase。回归测试覆盖根提交出现在 todo、重排、root reword、最终历史顺序、root autosquash 和工作区干净；multi-root raw todo fallback 已补齐，剩余是通知/撤销长尾；
- Log 单/多选 Drop 已补齐单 repository 当前 checked-out 线性路径的直接确认与 Rust 显式 todo 执行；初始提交先显示 Continue/Cancel warning，再使用真正的 root todo 删除；`Confirm Drop Commits` 默认开启且可持久化关闭；branch 与 detached HEAD 都按参考 fork 进入同一确认/执行路径；非连续选择、配置化本地现场保存/恢复、protected branch 防护和 expected-HEAD Undo 已覆盖。成功后的 Undo 现在携带 initial/expected HEAD 与 branch identity（detached HEAD 使用空 branch）的 Codable semantic action，可从 Operation Log/native notification 重载，并在执行前再次做 CAS 校验。merge、分支外提交仍 fail-closed，且这是参考 fork 的 `GitDropLogAction` 单 repository / `checkHeadLinearHistory` 约束；因此 merge-preserving/multi-root 不属于该 action 的待补语义。仍缺完整 VcsNotifier 分组和 UI automation；
- Log Changes Browser 的 Drop/Extract Selected Changes action gate 已按参考实现修正：重命名变更与已初始化 clean submodule gitlink 允许进入操作（Rust 会展开 rename 旧/新路径并按 nested repository 边界物化），“选中全部变更”、目录级路径、脏/未初始化 gitlink 仍明确禁用；无法安全重放的冲突由引擎在执行/恢复阶段 fail-closed，而不是让 UI 猜测性放行或静默丢失本地现场。全部变更的判断使用提交完整变更集，而不是过滤后的可见行，避免启用 Log filter 后误报不可用。该条旧基线曾将 merge commit 一并禁用，2026-08-24 已由 first-parent merge-target rewrite 收口记录 supersede；merge descendant 的 parent topology 现已由对象级 DAG 重放保持，完整 VcsNotifier 分组和 UI automation 仍是剩余差距；2026-08-25 又修正 SwiftUI action gate，后端已支持的 gitlink 不再被前端静默排除。
- drop/extract 对目录级/全选路径、未初始化或脏 nested worktree、以及恢复冲突的完整语义；
- 单 root 已提供受保护的成功后 Undo、干净失败 Retry，以及 tracked-only continue 失败后的 Stage-and-Retry；本轮补齐暂停在 edit/conflict 后 Continue 或 Stage-and-Retry 完成的 Undo：暂停时保存初始 branch HEAD，完成时重新读取 branch/current HEAD，只有 branch 未切换、未启用 `--update-refs` 且 HEAD 确实变化才生成 Undo，并在执行时再次以 expected-HEAD 校验；主 Rebase、Log todo 和 autosquash 入口都会持久化 root-scoped pause seed，重启后重新读取 Git operation state，并通过 Codable semantic action 打开 recovery workbench；Abort、成功完成和 Undo 会清理 seed；多 root 也已提供 root-scoped Stage-and-Retry 与全量成功后的受保护 Undo；跨 root 的会话恢复和安全部分回滚已接入，剩余是完整通知分组及更广的 merge-topology action 语义；
- 单 root `Checkout with Rebase`、独立 multi-root root action 和 Branches Popup 的 `Rebase Current in Root` 也已纳入同一 root-scoped seed：暂停时通过 `Open Rebase Recovery` semantic action 重新进入对应 root，完成或非 rebase 失败清理 seed；其它跨 root rollback/action history 仍是长尾；
- multi-root Rebase Continue 因 tracked-only dirty 失败时，现在按 IntelliJ 的 `Stage-and-Retry` 语义只暂存 tracked 工作区改动并重试 Continue；动作携带 root path 与 rebase session ID，写入稳定的 multi-root rebase notification ID，FeedbackCenter 重载后仍能恢复并在执行前拒绝过期 session。untracked、ignored 或 conflicted 状态不会错误暴露该动作；完整 VcsNotifier 分组、native banner 生命周期和 UI automation 仍是长尾；
- 单 root 与多 root 已接入 IntelliJ `GitSaveChangesPolicy`：Settings 默认 Shelve、可切换 Stash；Pull、Checkout and Update、Checkout with Rebase、Rebase、Smart Checkout 与多 root Update/Smart Checkout/Checkout and Update 会按策略保存完整 tracked/untracked/ignored 现场，并持久化 staged/unstaged 的原始 index 边界。临时 Shelf 引用以 root snapshot 和 `.git/arbor-shelve-restore` 持久化，恢复冲突可在项目级 resolver 完成或回滚，重启后仍可发现；旧裸 stash object-id 状态仍兼容。剩余差距是更完整的跨 root rollback/action surface 与 IntelliJ provider 扩展，不再是保存策略缺失。
- 本轮收口单 root Pull/Update with Rebase 的暂停边界：Pull 进入 native rebase pause 时保存 root-scoped rebase seed，并通过 `Open Rebase Recovery` semantic action 跨重启重新进入对应 root；Pull 前自动创建的 Shelf/Stash 同时以精确 name/message 持久化，Continue 完成 rebase 后才恢复并清理 marker，恢复冲突、Abort 或进程重启均保留可执行恢复路径；成功恢复后仅在 expected-HEAD 未失效时提供 `Undo Rebase`。

这些是历史重写边界，不应通过扩大普通 rebase 的快捷路径来掩盖。

证据：当前 `docs/git-parity-decisions.md` 决策 9、11；`docs/git-parity-matrix.csv` 的 rebase 行。

### 4. Submodule 的完整远程/嵌套 root 交互

本轮状态校正：Update Project 的失败恢复已增加 `Rollback Updated Roots` semantic action。它保存每个实际前进成功 root 的 initial/expected HEAD 与 symbolic ref 身份，按 deepest-first 回滚，并为父仓库传递已独立处理的嵌套 gitlink 路径，避免 materializer 删除子仓库工作树；失败或取消留下的 stash/Shelf 不被回滚消费。Git Roots 同时新增按 root 分组的 Changes Browser，详情 diff 与 Stage/Unstage/Stage All/Unstage All 固定使用所属 Repository，避免嵌套仓库同名路径串线。该能力是 Arbor 的恢复增强，不等同于 IntelliJ 的跨 root atomic transaction；完整 action history、native notification 生命周期、原生 ChangesView lifecycle 和 UI automation 仍是剩余差距。

当前已覆盖 add/list/update/sync/deinit/remove、`--remote`、`.gitmodules` branch 配置、嵌套 Log、递归 clone，以及 detached submodule 的父 root 更新顺序；SubmodulePanel 和 Update Project 的 detached-submodule fetch 现在统一经 credential broker 运行，并可由全局 operation bar 取消，取消会杀掉嵌套 clone/fetch 的整个进程组；多 root Commit/Push 也已按最深层 submodule 到 superproject 的依赖顺序执行。Changes Browser 现在对 gitlink 提供 `Submodule Changes` 入口：同时展示父仓库旧/新 gitlink、当前 checkout、初始化/dirty 状态、old..new 提交范围和嵌套文件级 added/modified/deleted/renamed 列表；standalone Submodule Update 成功后只为实际移动的 child root 提供 expected-HEAD guarded、可跨重启的 `Undo Submodule Update`；Deinit 成功后在快照与状态满足安全条件时提供可跨重启的 `Undo Submodule Deinit`，并在恢复前拒绝非空工作树。仍缺：

- submodule remote URL/branch 已可在独立 root-scoped RemoteConfigDialog 编辑；剩余是更完整的展示模型与 IntelliJ 的同步通知细节；
- 子模块 Push 入口已复用 root-scoped Push dialog，并保留自身 remote/upstream/force/lease 语义；stale lease 拒绝现在提供带安全校验的 `Force Push Anyway` 与 Retry，non-fast-forward 还可对该 root 选择 Update with Merge/Rebase，更新冲突直接进入项目级 resolver 的 Resolve Conflicts；Git Roots 的 Push All 已改用带 credential broker/cancel 的专用聚合 API，按最深层 submodule 到 superproject 排序，失败/取消的 child 会让父仓库显式 skipped，并提供 Retry Failed Push Roots；项目级 NFF 结果现在提供 Merge/Rebase，按 IntelliJ 语义先更新全部项目 roots，再只重新 Push rejected roots；Push All 的 force/force-with-lease 选项会逐 root 应用，受保护分支在 Rust 引擎中阻断，stale lease roots 可单独 `Force Push Anyway`；`run_root_update_for_push_recovery` / `run_multi_root_push_recovery` 按最深层保存/恢复嵌套 submodule 与父 root 的本地现场，父 pull 忽略已保存的 gitlink 路径；剩余是更细的跨 root rollback 与通知历史；
- 子模块自身多 root Update 失败后的保存/恢复边界、依赖闭包与通知聚合已补齐：detached submodule 的本地现场先按最深层统一保存，只有 compound update 成功才批量恢复；父/子失败或取消时保留 stash/Shelf，并由 root-scoped recovery workbench 处理；selected retry 现在闭包包含 submodule 的父链与 submodule 后代，父 root 失败、子模块失败及级联 skipped 在同一 project-scoped Update notification 中按依赖组展示；独立 nested repository 仍保持 root 隔离。Update Project 失败后现在可对实际前进的成功 roots 执行 deepest-first、expected HEAD/ref guarded 的 `Rollback Updated Roots`，并跨重启保留 semantic action；更完整的联合 diff、atomic transaction 与 action history 仍缺；
- gitlink 变更与子模块工作区变更同时存在时，父 root rollback 已忽略由独立 child target 负责的 gitlink 路径，并用 tree-path overlap 保护父目录不误删 child worktree；child 的 stash/Shelf 仍保留。Changes Browser 的联合 diff、standalone Update Undo 与 Add/Deinit/Remove 的安全 expected-state Undo 已补齐；非 Update 复合动作的统一 rollback/retry 编排，以及完整通知历史仍缺。

证据：参考 `plugins/git4idea/backend/src/update/GitSubmoduleUpdater.kt`、`GitUpdateProcess.java` 与 `GitComplexSubmoduleTest.kt`；当前 [`Arbor/RebasedDialogs.swift:4773`](/Users/arix/src/Personal/new-p/Arbor/RebasedDialogs.swift:4773)、[`Arbor/LogSidebar.swift:1081`](/Users/arix/src/Personal/new-p/Arbor/LogSidebar.swift:1081)、[`Arbor/SubmoduleChangeView.swift:1`](/Users/arix/src/Personal/new-p/Arbor/SubmoduleChangeView.swift:1)、[`Arbor/WorkspaceOperations.swift:8287`](/Users/arix/src/Personal/new-p/Arbor/WorkspaceOperations.swift:8287)、[`Arbor/WorkspaceOperations.swift:10043`](/Users/arix/src/Personal/new-p/Arbor/WorkspaceOperations.swift:10043)、[`arbor-engine/src/roots.rs:3263`](/Users/arix/src/Personal/new-p/arbor-engine/src/roots.rs:3263)、[`arbor-engine/src/repo.rs:6501`](/Users/arix/src/Personal/new-p/arbor-engine/src/repo.rs:6501)、[`arbor-engine/tests/multi_root.rs:1584`](/Users/arix/src/Personal/new-p/arbor-engine/tests/multi_root.rs:1584)、[`arbor-engine/tests/longtail.rs:96`](/Users/arix/src/Personal/new-p/arbor-engine/tests/longtail.rs:96)。

### 5. Remote tag 的直接选择与删除入口（单 root + multi-root 核心已完成）

本轮补齐了 local tag 删除后的 recovery follow-up：单 root 与 multi-root 的“Delete on Remote”现在将删除本地时保存的 raw tag object id（lightweight 时等于 commit，annotated/signed 时区别于 peeled target）传给 `delete_remote_tag_with_auth_lease_and_cancel`，不会在 recovery 开始时重新读取并误删随后被他人改写的新 remote tag；remote 已不存在仍按 IntelliJ 的幂等语义处理；Feedback Center 的取消会停止后续 remote，并保留 recovery 上下文以便重试。直接 Remote Tags 列表入口原本已经使用同一 lease 保护 API。

单 root 现在可从 Branches Popup 进入独立的 Remote Tags 对话框，按 remote 直接读取 `ls-remote --tags`，区分 lightweight/annotated，显示 peeled target，并通过 credential broker 完成认证后的删除。multi-root Branches Popup 也提供跨 repository 聚合对话框：每个 row 保留 root/remote/tag 身份，支持搜索与逐项选择，逐 root 执行删除并汇总部分成功/失败；失败通知可重新打开该对话框。删除仍先读取远端对象 id，再以列表中的 object id 做本地前置一致性校验，并用 `--force-with-lease` 做最终竞态保护；这与 local tag 删除后的 recovery follow-up 是两条不同路径。

剩余差距收敛为完整 IntelliJ 细节：credential 设置的更细粒度编辑、更完整的非模态通知历史，以及完整 UI automation 仍未完全复刻；远程 tag 列表/删除已支持进程组取消，multi-root 取消后不会继续处理后续 root，并保留已完成的部分结果。

证据：参考 `GitDeleteRemoteTagOperation.java`；当前 `Arbor/RebasedDialogs.swift` 的 `MultiRootRemoteTagsDialogView`/`RemoteTagsDialogView`、`Arbor/ContentView.swift` 的 multi-root sheet、`arbor-engine/src/repo.rs` 的 `remote_tag_list_with_auth_and_cancel` 与 `delete_remote_tag_with_auth_lease_and_cancel`、`arbor-engine/tests/tags.rs` 的取消/stale-list lease 测试和 `Arbor/ArborTests/CompareSelectionTests.swift` 的聚合排序/过滤测试。

### 6. Git executable 的项目级 override 与认证设置边界

参考实现的 `GitVcsPanel`/`GitExecutableSelectorPanel` 明确区分两层设置：

- `GitVcsApplicationSettings.myPathToGit` 是应用默认值；
- `GitVcsSettings.pathToGit` 是当前项目的可选 override；
- Settings Apply 时，项目 override 存在就只写项目设置；取消 override 则回退应用默认，并触发 executable 变更通知和项目 dirty-scope 刷新。

本轮已补齐参考实现的核心项目级 executable 语义：`GitExecutableSettingsSection` 仍提供应用级 Browse/Test/Save/Reset；项目 Git Settings 新增可选 override，保存时按标准化 project path 持久化，关闭 override 可清除并继承应用默认。Rust 引擎为项目记录已发现的 Git roots，按最长 root 匹配 executable，并在每个打开的 `Repository` 上捕获 executable；Repository 锁内以 RAII scope 保护直接 system-Git fallback、`run(spec)`、remote/auth/stash/conflict 等调用，避免同一进程的双项目窗口互相覆盖。项目打开、单 root 和 multi-root root 发现路径都会重新注册 override，clone/initialize 等没有仓库上下文的入口继续使用应用默认。

仍可继续增强的不是上述核心缺口，而是参考实现之外的长尾：项目设置窗口对 override 的 UI automation、项目关闭后的 root 注册清理，以及新型后台调度器在同一 root 被多个项目注册时的更细粒度 operation context。目前已对真实配置路径和引擎调用路径完成测试，不再把“进程级单一 executable”列为现存缺口。

认证设置的对照结论需要单独区分：参考 `SSHConnectionSettings` 只持久化非敏感的 `user@host -> method` last-successful map；参考 fork 中没有找到 agent/helper 来源级成功方法的持久化或展示实现。Arbor 的 `SSHAuthenticationStore` 已覆盖该 map，并且仅在 askpass prompt 路径能确定方法时记录 `publickey/password`；agent/helper 的只读诊断和 local helper 编辑是额外能力，不应反过来作为 IntelliJ 基线缺口。仍可继续增强的是 SSH key 管理和认证诊断的细节，但它们不属于当前参考类的已证实必需行为。

2026-08-21 认证失败恢复校正：参考 `GitImplBase` 在完整认证模式下最多重试一次，并在失败后让认证器丢弃旧密码。Arbor 的 credential broker 现在也会在明确收到凭证 prompt 且结果为 `Authentication` 时重建一次 askpass 会话；重试 request 携带脱敏的 `previous_error`，Swift Keychain 命中仅限首次尝试，因此失效 token 不会在重试中静默循环。SSH host-key 明确拒绝不会走认证重试；403 Forbidden 也会归类为 Authentication。SSH passphrase 不再写入 Git remote credential Keychain 命名空间。剩余差距收敛为真实 sshd 端到端、agent/helper 来源级成功观测和原生认证对话框/UI automation。

证据：参考 `plugins/git4idea/backend/src/config/GitVcsPanel.kt`、`GitExecutableSelectorPanel.kt`、`GitVcsApplicationSettings.java`、`SSHConnectionSettings.java`；当前 [`Arbor/BeforeCommitSettingsView.swift:257`](/Users/arix/src/Personal/new-p/Arbor/BeforeCommitSettingsView.swift:257)、[`Arbor/DiagnosticsLogger.swift:391`](/Users/arix/src/Personal/new-p/Arbor/DiagnosticsLogger.swift:391)、[`Arbor/WorkspaceOperations.swift:248`](/Users/arix/src/Personal/new-p/Arbor/WorkspaceOperations.swift:248)、[`arbor-engine/src/gitprocess.rs:22`](/Users/arix/src/Personal/new-p/arbor-engine/src/gitprocess.rs:22)、[`arbor-engine/src/repo.rs:48`](/Users/arix/src/Personal/new-p/arbor-engine/src/repo.rs:48)、[`Arbor/CredentialAuth.swift:23`](/Users/arix/src/Personal/new-p/Arbor/CredentialAuth.swift:23)。

### 7. Incoming/outgoing 的自动 Fetch 策略

参考 `GitBranchIncomingOutgoingManager` 的 `FETCH` / `LS_REMOTE` 策略，Arbor 现在在 Git Settings 提供全局 incoming changes check 回退，并在单 root/multi-root Branches Popup 提供项目级 Git Settings。项目设置按标准化 project path 隔离，策略未覆盖时继承全局设置；项目激活或策略启用时立即执行第一次检查，之后默认每 20 分钟按所有已发现 Git root 的所有 remote 执行 broker-backed、可取消的 FETCH 或 LS_REMOTE，对应 IntelliJ 的 `git.update.incoming.info.time` Registry；Arbor 保留同等内部覆盖 key `arbor.git.incomingCheckIntervalMinutes.v1`，非法值回退 20 分钟。同一 root 的多个项目窗口由协调器避免后台操作互相重叠，FETCH 更新 remote-tracking refs，LS_REMOTE 只比较配置 upstream 的 live remote tip、不修改本地 refs，并提示未 Fetch 分支；root 初始化或 remote 枚举失败进入统一失败反馈，无 remote 的 root 保持静默；任一 remote 传输失败不会丢弃其它 root 的结果。手动 Fetch 成功后的建议计数与 Do Not Ask Again 状态也按项目保存。

本轮已补：项目/策略启用时第一次检查立即执行，后续默认保持 IntelliJ 对齐的 20 分钟间隔，并支持内部 interval key 的正值覆盖；Retry 通过新的 monitor generation 立即重跑一次，不依赖可在 SwiftUI 重建时重复触发的布尔标记。root 初始化、remote 枚举和 remote 传输失败都会进入统一失败反馈，无 remote 的 root 不制造噪声。轮询结果按 root/remote 稳定排序去重；incoming/error 使用项目稳定 notification ID 更新同一条 FeedbackCenter 历史；incoming 通知可直接 Fetch All，失败通知可 Retry Check/Fetch All；Fetch All 现在覆盖项目内全部 Git roots，并保留部分成功结果；带 notification ID 的 Git 反馈会进入 macOS `UNUserNotificationCenter`，使用相同 request ID 替换旧通知，支持 Fetch/Retry/Enable/Do Not Ask Again action；这四类 AutoFetch action 现在携带 project/root/root-scope 的 Codable semantic request，Operation Log 与原生通知重启后仍可执行。仍缺：专门的 timer/multi-root UI 自动化测试，以及 IntelliJ `VcsNotifier` 的完整 permission/banner 生命周期。

2026-08-27 后台认证模式对照补齐：参考 `GitBranchIncomingOutgoingManager` 的 `AuthenticationMode.NONE` 与已认证 remote 的 `SILENT` 选择，Auto Fetch 的 FETCH/LS_REMOTE 不再对每个 remote 无条件使用 interactive broker。首次检查使用 NONE，清空 credential helper 并关闭 terminal prompt；某个 remote 曾由 broker 成功认证后使用 SILENT，只允许复用已有安全凭证，缺失/失效凭证不会弹出认证对话框。Rust 将 `allowInteraction=false` 传递到 CredentialRequest，静默拒绝不分类为用户取消，且 SILENT 失败不做无意义的交互重试；显式 Fetch/Pull/Push/Clone 的 Interactive 认证保持不变。Rust `tests/auth.rs::silent_auth_never_classifies_missing_credential_as_user_cancel` 覆盖该边界。仍缺：原生 `VcsNotifier` permission/banner 生命周期、真实 agent/helper 来源选择的完整观测，以及专门的 timer/multi-root UI automation。

项目级 `GitFetchTagsMode` 也已接入同一条设置链：显式 Fetch、Fetch All、指定 remote branch、Pull、Checkout and Update、prune/unshallow、自动 Fetch，以及 Push rejected 后的 Merge/Rebase recovery 都使用项目选择的 `Git default` / `--prune-tags` / `--tags` / `--no-tags`；旧兼容 API 明确保持 Git default。剩余差距是设置窗口与这些复合操作的专门 UI automation，不是引擎参数未贯穿。

证据：参考 `plugins/git4idea/backend/src/branch/GitBranchIncomingOutgoingManager.java`、`plugins/git4idea/backend/src/config/GitVcsPanel.kt`、`plugins/git4idea/backend/src/fetch/GitAutoFetchNotificationsService.kt`；当前 [`Arbor/RepositoryIndexRevisionMonitor.swift`](/Users/arix/src/Personal/new-p/Arbor/RepositoryIndexRevisionMonitor.swift)、[`Arbor/DiagnosticsLogger.swift`](/Users/arix/src/Personal/new-p/Arbor/DiagnosticsLogger.swift)、[`arbor-engine/src/repo.rs`](/Users/arix/src/Personal/new-p/arbor-engine/src/repo.rs)、[`Arbor/WorkspaceOperations.swift`](/Users/arix/src/Personal/new-p/Arbor/WorkspaceOperations.swift) 和 [`Arbor/ContentView.swift`](/Users/arix/src/Personal/new-p/Arbor/ContentView.swift)。

### 8. 系统级 preserving process 的来源覆盖

参考实现的 `GitPreservingProcess` 并不是 Pull 专属工具。源码实际把同一套“保存本地变更 → 执行 Git 操作 → 自动恢复；恢复冲突则保留可恢复引用”接到 `GitUpdateProcess`、`GitCheckoutOperation`、`GitMergeOperation`、Smart `GitResetOperation`、force-pushed branch update、`GitPreservingExecutor`，以及 Cherry-pick/Revert 的 `GitApplyChangesProcess`。其中 Cherry-pick/Revert 不是无条件先保存，而是在检测到 local changes would be overwritten 后给出保存并重试入口；这仍然是 IntelliJ 的完整交互模型的一部分。

当前 Arbor 已覆盖 Pull、Update Project、Checkout/Checkout and Update、Rebase、Drop/Extract selected changes、Merge、Reset、force-pushed branch update，以及 Cherry-pick/Revert 的 preserving 路径。与上次基线相比，本轮已收口以下 P1 preserving 缺口：

- Cherry-pick / Revert：覆盖错误现在提供 IntelliJ 风格的 Smart/Cancel 决策对话框，按设置选择 Stash/Shelf 保存并重试；Continue/Abort 后自动恢复，恢复冲突进入同一 stash/Shelf 冲突工作台。
- Merge：已补 `LocalChangesWouldBeOverwritten` 的 affected-path 列表、Smart/Force/Cancel 对话框（Merge 无 Force）、单 root/multi-root Smart retry、按设置选择 Shelve/Stash、每 root 持久化 marker、Continue/Abort 自动恢复和恢复冲突工作台；multi-root Smart retry 现在只重试被本地改动阻塞的 root，并保留首轮其它 root 的 HEAD/conflict/rollback 结果，避免重复合并已成功 root；部分完成后的 Merge rollback 现在持久化 expected-HEAD guarded targets、pending merge state 和 branch context，接入 Operation Log/native notification 的 `Rollback Successful Roots` semantic action，rollback 部分失败时只重试剩余 root，Keep Partial/完成后会替换旧 action；合并后的本地分支动作已按参考实现支持 `DELETE` / `PROPOSE` / `NOTHING`，并对远程/保护/revision-only 场景做安全降级。
- Reset：已补 Hard/Keep 覆盖检测、affected-path Smart/Force/Cancel 对话框、Smart 保存→reset→恢复、恢复冲突入口、显式 Hard Force 分流，以及逐 root 的 multi-root Reset 结果聚合；aggregate Log 现在按 IntelliJ 的 one-commit-per-repository 语义为每个 root 携带独立 target，Smart/Force 重试只重试覆盖阻塞的 root，并按 root 合并回首轮其它成功/失败结果，避免结果面板丢失未重试 root。本轮又补齐 soft reset 的 root-scoped expected HEAD/branch 快照、ref-only rollback、部分成功逐 root CAS 拒绝与跨重启 semantic action；同时为 soft/mixed/keep/hard 建立包含 HEAD、index、tracked worktree、untracked/ignored 文件的完整恢复快照，Undo/Keep 均按 post-reset scene 做 CAS 校验，失败 root 可独立重试，用户 stash 栈不被内部快照污染。仍缺的是跨 root rollback 的更细 native notification 生命周期与 UI automation；Reset 引擎恢复语义本身不再是该缺口。
- force-pushed branch update：已补 fetch、线性本地提交 backup + oldest-first replay、merge commit 回退普通 Merge 更新、dirty scene 保存/恢复、单 root与跨 root Smart/Force/Cancel 决策，以及逐 root 的 multi-root 结果聚合；replay 不完整时后端明确保留并命名 backup branch，单 root/multi-root warning 提供打开 Branches 与经过现有确认流程的删除 action，backup 删除失败也会明确报告而不丢失恢复入口。
- Force-Pushed UpdateSession：引擎在 fetch 前捕获 upstream tip，并按 IntelliJ 的 `merge-base(local HEAD, old tracking)` 计算 UpdateSession range start，再统计收到的提交数与更新文件数；单 root 反馈显示这两个计数；multi-root 反馈汇总成功 root 的计数、保留 skipped/failed root 的逐项原因，并把所有成功 root 的 `range-start..new` 作为同一个 root-qualified 聚合 Log 的 `View Commits` action，语义请求可跨重启恢复。
- 跨重启恢复：所有 apply marker（merge/reset/cherry-pick/revert 及 force-pushed update 的 replay/fallback）会在项目刷新后重新扫描，并以可执行的 Resolve local changes action 打开对应 root 的冲突工作台。

因此“主要系统 Git 操作已完成 preserving”仍不能升级为“完全复刻 IntelliJ”。本轮又补齐了 Update Project / Retry Update 的 IntelliJ-style updated-files summary：对实际前进的每个 root 用保存的 revision range 计算 tree changes，通知同时显示 files 与 received commits；任一 range 无法解析时安全省略文件数，不伪造部分统计。剩余实质差距是更完整的 rollback 与统一后续 action model、native notification 的完整权限/banner 生命周期和 UI automation；UpdateSession 的跨 root Log/action 聚合已收口，但不代表其它 multi-root action surface 已完成。

证据：参考 `plugins/git4idea/backend/src/util/GitPreservingProcess.kt`、`update/GitUpdateProcess.java`、`branch/GitCheckoutOperation.java`、`branch/GitMergeOperation.java`、`reset/GitResetOperation.java`、`applyChanges/GitApplyChangesProcess.kt`、`actions/branch/GitForcePushedBranchUpdateAction.kt`；当前 `Arbor/WorkspaceOperations.swift` 的 `cherryPickCommitsFromLog`、`revertCommitsFromLog`、`doMerge`、`resetCommit` 与 `arbor-engine/src/repo.rs` 的对应直接入口。

### 2026-08-24：Changes Browser / File History 的文件级托管链接

参考 fork 的 `GlobalHostedGitRepositoryReferenceActionGroup` 会在提交行、文件历史和文件 revision 上统一提供 Open in Browser / Copy Link；当前 Arbor 此前只有提交级 permalink，Changes Browser 的文件行只能 Copy Path，属于实际缺失的 Git hosting action。

本轮新增 `Repository.permalinkForPath`：按 GitHub `blob`、GitLab `-/blob`、Bitbucket `src` 规则生成文件 revision 链接，并对 Git 文件名做 path-safe percent encoding；支持 HTTPS、SSH 和 SCP remote，未托管 remote、空路径或非法输入 fail-closed。Log Changes Browser 的选中行和行级 context menu 现在提供 Browse File in Browser / Copy File Link，按 `commit.repositoryPath` 解析所属 Git root，避免多仓库项目误用主仓库 remote；失败通过 FeedbackCenter 给出配置 remote 或刷新 root 的下一步。

仍未声称完成 IntelliJ 的完整 hosted reference action group：编辑器当前文件/行号链接、VCS History 原生 DataContext 和 UI automation 仍为 partial。

证据：参考 `plugins/git4idea/backend/src/remote/hosting/action/HostedGitRepositoryReferenceActionGroup.kt`、`GlobalHostedGitRepositoryReferenceActionGroup.kt`、`HostedGitRepositoryReferenceUtil.kt`；当前 `arbor-engine/src/repo.rs`、`Arbor/LogSidebar.swift`、`Arbor/WorkspaceOperations.swift`；测试 `arbor-engine/tests/hosting.rs` 与 `ArborTests/CompareSelectionTests.swift::testHostedFileRevisionTargetUsesParentForDeletedPaths`。

### 2026-08-24：Hosted reference action group 的多 remote 语义

参考 `HostedGitRepositoryReferenceActionGroup` 的 `references.size == 1` 直达、多个 reference 展开 popup 语义，当前 Arbor 已在 Commit Details、Log 提交行以及 Changes Browser / File History 文件行统一实现：没有可生成 permalink 的 remote 时隐藏入口；只有一个 supported remote 时直接打开或复制；多个 supported remote 时按 remote name 展开独立的 Open in Browser / Copy Link 子菜单。提交级和文件级动作都按所属 `repositoryPath` 解析 root，执行时使用用户选择的 remote，不再静默取第一个 remote；不支持的 remote 被过滤，失败仍通过 FeedbackCenter 给出恢复路径。

该增量用共享 presentation 判定和 `HostingProviderTests` 覆盖 0/1/多 remote 分支，并通过完整 `xcodebuild test` 验证。编辑器当前文件/行号链接、VCS History 原生 DataContext、原生 `VcsNotifier` action lifecycle 和 UI automation 仍为 partial。

证据：参考 `plugins/git4idea/backend/src/remote/hosting/action/HostedGitRepositoryReferenceActionGroup.kt`、`GlobalHostedGitRepositoryReferenceActionGroup.kt`；当前 `Arbor/HostingProvider.swift`、`Arbor/CommitDetailView.swift`、`Arbor/LogGraphView.swift`、`Arbor/LogSidebar.swift`、`Arbor/WorkspaceOperations.swift`；测试 `ArborTests/HostingProviderTests.swift::testHostedRemoteActionPresentationMatchesIntelliJGroupSemantics`。

### 2026-08-24：Pull Request / Merge Request remote 选择

审计发现旧 Branches 侧栏 `PR`、Log 的 `Open Pull Requests` 和 `Comment this commit` 都会在多个 remote 时静默使用第一个 remote。当前已统一修正：按提交所属 Git root 获取 remote，只保留可解析的 GitHub/GitLab/Bitbucket remote；一个 remote 直接执行，多个 remote 展开选择，选中的 remote 贯穿浏览器链接或评论 sheet。Rust `pr_url` 现在覆盖 GitHub/GitLab/Bitbucket 的 HTTPS/SSH/SCP remote、特殊字符 branch 编码和非法输入 fail-closed；provider 的 PR 列表路径也按 GitHub `/pulls`、GitLab `/-/merge_requests`、Bitbucket `/pull-requests` 区分。

失败路径通过 FeedbackCenter 提供刷新 root、选择其它 remote 或手动打开的下一步。API 创建 PR、token/账户选择、原生 hosting DataContext/action lifecycle 和 UI automation 仍为 partial。

证据：当前 `arbor-engine/src/repo.rs`、`Arbor/RepoSidebar.swift`、`Arbor/LogGraphView.swift`、`Arbor/HostingIntegration.swift`、`Arbor/HostingProvider.swift`；测试 `arbor-engine/tests/hosting.rs` 的 PR URL 回归与 `ArborTests/HostingProviderTests.swift` provider URL/presentation 回归。

### 2026-08-24：Push Tag remote 选择

参考 fork 的 `GitPushTagsActionGroup` 会为每个 configured remote 创建独立的 `GitPushTagActionWrapper`。此前 Arbor 的 Log Tags、单 root `Push All Tags`、multi-root `Push All Tags` 以及部分后端入口会静默取第一个 remote。当前已统一修正：单 remote 直达，多个 remote 展开逐 remote 菜单；后端只在显式选择或唯一 remote 时执行，remote 缺失、失效或多 remote 未选择时 fail-closed。单 tag 和批量 tag 仍使用既有 credential broker、取消句柄、结构化拒绝与非 force wildcard refspec。

证据：参考 `plugins/git4idea/backend/src/actions/tag/GitPushTagsActionGroup.kt`；当前 `Arbor/LogSidebar.swift`、`Arbor/RebasedDialogs.swift`、`Arbor/ContentView.swift`、`Arbor/WorkspaceOperations.swift`、`Arbor/HostingProvider.swift`；测试 `ArborTests/HostingProviderTests.swift::testRemoteResolutionNeverFallsThroughToFirstRemote`。原生 IntelliJ action wrapper/DataContext/VcsNotifier lifecycle、完整 UI automation 以及通用 Push action 的默认 remote 语义仍为 partial。

### 2026-08-24：通用 Push remote 选择

参考 fork 的 `GitPushBranchAction` 直接打开 `VcsPushDialog`，remote 由对话框中的 push target 决定，不由 action 静默取第一个 remote。当前 Arbor 已修正主工具栏入口：`Push` 先打开 `PushDialogView`；普通 Push 对话框在未提供明确 remote 时，仅对唯一 remote 自动选择，多 remote 保持空选择并禁用确认按钮；root-scoped Push 与 legacy `doPush` 执行层也只接受显式或唯一 remote，失效/缺失选择会 fail-closed。

证据：参考 `plugins/git4idea/backend/src/actions/branch/GitPushBranchAction.kt`；当前 `Arbor/ContentView.swift`、`Arbor/PushDialogView.swift`、`Arbor/WorkspaceOperations.swift`、`Arbor/HostingProvider.swift`；测试复用 `ArborTests/HostingProviderTests.swift::testRemoteResolutionNeverFallsThroughToFirstRemote`，并通过完整 macOS build/test 验证。Push dialog 的 native DataContext、完整 target discovery、VcsNotifier lifecycle 和 UI automation 仍为 partial。

### 2026-08-24：Remote Tags remote 选择

单 root 的 Remote Tags 页面同时负责远程 tag 浏览和删除；当前已复用同一 remote selection 规则：唯一 remote 自动选择，多 remote 保持空选择并要求明确选择，读取和删除都使用同一个 selected remote，不再把第一条 remote 当成隐式目标。自定义 SwiftUI 列表仍不是 IntelliJ 原生 remote-tag action/DataContext 生命周期的完整复刻。

证据：当前 `Arbor/RebasedDialogs.swift`、`Arbor/HostingProvider.swift`；测试复用 `ArborTests/HostingProviderTests.swift::testRemoteResolutionNeverFallsThroughToFirstRemote`，并通过完整 macOS build/test 验证。原生 action/DataContext、通知 lifecycle 和 UI automation 仍为 partial。

### 2026-08-24：Configure Remotes 初始选择

参考 fork 的 `GitConfigureRemotesDialog`，Remote 配置表初次打开不应把第一条 remote 当成用户选择；只有 DataContext 或用户明确选中 remote 时才允许 Edit/Remove。当前 Arbor 的单 root `RemoteConfigDialogView` 与 root-scoped remote config 入口已移除无选择时的 first-remote fallback；没有显式选择时保持空编辑状态，remote 被刷新或删除后也不会自动跳到另一条 remote。multi-root 聚合表继续要求 root-qualified remote selection。

证据：参考 `plugins/git4idea/backend/src/remote/GitConfigureRemotesDialog.kt`；当前 `Arbor/RebasedDialogs.swift`、`Arbor/WorkspaceOperations.swift`。URL/remote CRUD、认证校验和跨 root action 已有回归；原生 table selection/DataContext、VcsNotifier lifecycle 和 UI automation 仍为 partial。

### 2026-08-24：Fetch Full History remote 选择

参考 `GitFetchSupportImpl.getDefaultRemoteToFetch` 与 `GitUnshallowRepositoryAction`：单 remote 使用唯一 remote；多个 remote 优先当前分支 tracking remote，其次 `origin`，两者都不存在时不猜测。当前 Arbor 的 `doFetchUnshallow` 已采用同一规则，无法安全决定时给出 FeedbackCenter 恢复提示，不再使用 `remotes.first`。

证据：参考 `plugins/git4idea/backend/src/actions/GitUnshallowRepositoryAction.kt`、`plugins/git4idea/backend/src/fetch/GitFetchSupportImpl.kt`；当前 `Arbor/HostingProvider.swift` 的 `defaultFetchRemoteName`、`Arbor/WorkspaceOperations.swift`、`Arbor/ArborTests/HostingProviderTests.swift::testDefaultFetchRemoteUsesTrackingThenOriginWithoutGuessing`。原生后台任务通知和 UI automation 仍为 partial。

### 2026-08-24 Interactive Rebase edit-Amend parity
对照 IntelliJ 在 `edit` 暂停时仍保持 Commit 工作台可用的语义，Arbor 现在只在无冲突的 rebase edit 暂停开放 Amend；普通 Commit、Commit All、Commit and Push 仍保持禁用，冲突暂停继续由冲突 resolver 接管。对象级 Rust rebase Continue 会识别用户已经 Amend 的新 HEAD，校验它仍以暂停提交的原父集合为父、工作区没有覆盖当前 amended commit 的未提交内容，然后直接复用该提交继续剩余 todo，避免丢失新 message 或额外生成一条提交。未发生显式 Amend 的原有“用当前工作区生成 edit 提交”路径保持不变。新增 `arbor-engine/tests/rebase.rs::rebase_edit_amend_then_continue_reuses_amended_commit`（含 post-Amend dirty fail-closed）、`ArborTests/ReflogSelectionTests.swift::testRebaseEditPauseAllowsAmendOnlyWithoutConflicts`；剩余差异是 native Git/VcsNotifier/DataContext 生命周期、复杂 merge-topology action 和 UI automation。

## P2：交互模型仍有差异，但不阻塞 Git 主链路

本轮 Log 多根对齐：参考 `BranchesVcsLogUi` / `BranchesTreeSelection` 的 root-aware branch filter 语义，Arbor 现在可在 Log Branches dashboard 中 Cmd 选择不同 root 的分支并加载合并历史；Rust `CommitInfo` 携带 `repositoryPath`，Swift 图表、选择、Changes Browser 和 commit action 以 `(root, object id)` 区分相同 hash。聚合图表明确不绘制跨仓库 parent lane，避免将独立仓库误显示为一张 Git graph；写操作要求单 root 或明确阻止，避免把当前主仓库误用于嵌套 root。

- 本轮补齐 `Highlight Cherry-Picked Commits` 的聚合 root 语义：source branch 名称从当前聚合 root 汇总，后台比较逐 root 执行，target 使用各 root 当前分支；结果按 `(root, object id)` 回填 Log 图表，避免不同仓库的相同 hash 互相高亮。仍未声称完成 IntelliJ 的完整比较进度、取消、通知和 UI automation 生命周期。

- 本轮又补齐 Branches Dashboard 与主 Branches Popup 的 local/remote branch 多选 action：同 root 两个 branch 可分别执行 Compare Branches 与 Show Files Diff；前者展示两侧各自独有的提交历史，后者展示两个 branch HEAD 的文件差异；local branch 支持 Update Selected/Delete Selected，remote branch 支持 Delete Selected；批量写操作按 root/name 执行并汇总 partial result，protected remote 会禁用批量删除。configured remote/group node 现在支持 root-qualified Edit/Remove Remote、跨 root 多选 Remove Remote 和 Configure Remotes；多根与单根 Log Branches Dashboard 的单引用 action group 现在统一补齐 Checkout as New Branch、local branch 的 Checkout and Update、Checkout with Rebase，以及已绑定本地分支的 Pull/Pull with Rebase，均按所属 root 或当前 repository 路由；remote branch 按 fork 只提供 Checkout、Checkout with Rebase、Pull 与 Fetch，不再错误暴露 local-only 的 Checkout and Update；单根与多根 local/remote 分支现在也提供 IntelliJ 的 Show Diff with Working Tree，比较 reference 与 tracked 工作区并复用文件级 diff；单根 Log Branches 新增 Cmd/Shift 多选与 Compare/Update/Delete Selected。单根 remote 的 Checkout with Rebase 会先创建本地 branch 再 rebase 到当前分支。仍缺的是更统一的跨 root action 聚合和 UI automation，其它 tree action group 仍有长尾。
- 多 root 冲突完成后的 Delete-on-Merge 已聚合为一次跨 root、root-qualified semantic action：使用稳定 notification ID，Operation Log/native notification 可跨重启恢复，点击后仍复用一次确认和逐 root 删除/恢复结果；Merge rollback 的 root-scoped semantic action 已收口，但跨 root atomic rollback 仍不在产品边界内。
- 本轮补齐了主 Branches Popup 与多 root Popup 的 `Show Diff with Working Tree`、`Checkout as New Branch…` 以及 `Checkout with Rebase` 引用动作，并让 tag 引用进入 `Merge into Current…`；Log 单提交 ref action group 在无其它 branch ref 时也提供 `Rebase Current onto Selected Commit…`，调用时校验 detached HEAD 与当前分支可达性；local branch 的 `Checkout and Update` 保留，remote branch 不再暴露该 local-only action；Log Branches Dashboard 的同类动作继续保持 root-qualified。多选 tag 现在复用 IntelliJ `DeleteBranchAction` 的批量删除语义，按 root 执行并保留 Restore All / Delete on Remote 恢复入口。
- Log 行上下文菜单的 `Create Branch from Commit` / `Create Tag at Commit` 现在按参考 fork 的单提交 action update 规则处理：已有多选时保留菜单项但禁用；右键行尚未发布 selection 时把上下文行视为单提交；commit 没有可解析的 `repositoryPath` 时 fail-closed，避免把动作误路由到主仓库。纯逻辑测试覆盖单选、多选和 root 缺失。
- 本轮继续补齐 IntelliJ Branches Dashboard 的合成 `HEAD` 节点：单选 HEAD 只暴露 Filter Log、Show Diff with Working Tree、New Branch from HEAD 和单仓库 New Working Tree from HEAD；HEAD 与同 root branch 双选才暴露 Compare Branches / Show Files Diff，并明确隐藏 Favorite、Checkout、Update、Merge、Delete 等不适用于伪节点的引用写操作；单 root 与 multi-root Log dashboard 都保持 root-qualified selection identity。
- 全局 `Git.Fetch` 现在与 fork 的 `GitFetch.performFetch` 对齐：无 remote 参数时逐 root 抓取所有已配置 remote，并保留 remote 配置流程中显式 remote 的单 remote fetch 语义；Branch Popup 的单 remote-branch fetch 现在固定使用 `refs/heads/<branch>:refs/remotes/<remote>/<branch>`，不会被自定义 `remote.<name>.fetch` 映射降级，并兼容 `main`、`origin/main`、`refs/heads/main` 三种输入。
- Worktree action surface 现在补齐 IntelliJ `GitCreateWorkingTreeAction` 的单引用入口：单 root Branches Popup、单 root Log Branches dashboard、主 multi-root Branches Popup 和 multi-root Log dashboard 的 local branch/tag/HEAD 都会把选中 ref 带入新建工作树对话框；multi-root 入口携带所属 rootPath，并按该 root 做 branch/worktree 校验与创建；所有这些入口都支持直接检出来源引用或创建新分支。跨 root 混选仍不提供批量 worktree action。
- Log Branches dashboard 也补齐 `GitOpenExistingWorkingTreeForLocalBranchAction`：单 root local branch 仅在其它 linked worktree 已占用该分支时显示 Open Worktree，并按 root/path 打开新项目窗口；multi-root dashboard 隐藏该单仓库动作。
- tag 的 `GitPushTagsActionGroup` 现在按 fork 为多 remote 生成明确的 remote 子菜单；Branches Popup 与 Log Branches dashboard 不再静默使用第一个 remote，单 remote 仍保持直接 Push。
- 单 root Log Branches dashboard 的 local branch tracking 现在提供与 fork `GitTrackedBranchActionGroup` 对齐的 `Tracked Branch (origin/…)` 子菜单；其中的 remote ref actions 继续复用 root-qualified checkout/compare/diff/merge/rebase/pull/delete handlers，主 multi-root Branches Popup 与 multi-root Log dashboard 也提供 root-scoped New Working Tree；跨 root 混选仍按单仓库 action 边界禁用该动作。
- Branches Popup 与 Log Branches dashboard 现在按标准化 project path 持久化各自的目录组折叠状态；Branches Popup 的 local/remote/recent/tag 以及 Log dashboard 的 local/remote/tag 都按 section/root 做 prefix tree，并支持目录节点展开/折叠；搜索已支持大小写/变音符号不敏感、空格分词候选、分支组件前缀和模糊子序列匹配，并在单 root、多 root Branches Popup 与 Log dashboard 中提供最佳匹配选中、上下键移动、回车执行；Log dashboard 的 Show Tags 也按项目持久化，tag 单引用 action 对齐 Checkout、Merge、Show Diff with Working Tree、Delete、Push；Favorite 对齐 IntelliJ dashboard 工具栏动作，分支上下文菜单不再把它错误地当成单引用 action；新增 Fetch All、Compare with Current、Update Selected、Delete Selected 工具栏动作，并按 HEAD、remote group、跨 root selection 禁用不适用操作；顶部 New Branch 会把单选 branch/remote ref 作为基点，HEAD、多选和 remote group 回退到普通新分支入口；多 root 选中 identity 包含 rootPath，折叠目录中的隐藏叶节点不会进入键盘候选；单 root remote branch 也提供 `Compare with Current…`。多 root Log 已按所属 root 打开分支历史、比较、提交详情与主要变更动作；本轮新增多选分支的 root-scoped 聚合历史、root-qualified commit identity、按 commit root 路由 Changes Browser，以及失效 root 刷新收敛；嵌套 root 的 autosquash 因 Commit workspace 尚未 root-scoped 会明确阻止误操作；剩余差距是 IntelliJ 完整 tree action-group enablement/selection semantics、跨 root 写操作的统一 action 聚合及更完整的 UI 自动化覆盖。
- 本轮进一步对齐 tree action 的 presentation 状态：Update/Checkout with Update 在无 tracking 或 linked worktree 时保持可见但禁用；批量 Update 遇到 linked worktree 时禁用；同名或跨 root 的 Compare、当前/受保护引用的批量 Delete 保持可见但禁用，并由工具栏与上下文菜单共用同一 root-safe 状态模型。剩余差距收敛为其它 action 的细粒度描述、完整 selection semantics 与 UI automation。
- Log Branches dashboard 的分支选择行为已按项目持久化为 Navigate Log / Filter Log / Select Only，并同时覆盖鼠标点击与键盘 Enter；Log 与主 Branches Popup 的 Favorite 已按 project/root/ref identity 接入图标和 action；Show Tags 与 tag action 已接入单 root/multi-root dashboard；Show My Branches 已由 Rust 按 Git identity 与独占提交判定，并在单 root、多 root 中以可取消的异步加载结果筛选；仍缺完整 tree action-group enablement。
- Protected Branches 已按 IntelliJ `GitSharedSettings` 补上项目级本地正则与 hosted-rule 同步开关：项目 override 按标准化路径持久化，未设置时继承全局值，force-push、已发布保护检查和多 root push 都读取同一 effective 规则；仍缺 `GitProtectedBranchProvider` 扩展点以及 provider 对保护策略的更细粒度映射。
- Branch cleanup、Find merged branches、Reflog、Log Changes Browser 的行选择、动态列和完整上下文菜单仍比 IntelliJ 简化；Cleanup Branches 的复制 payload 已按参考实现对齐为表格行顺序的三列 tab-separated 内容，Log Changes Browser 的 Get Version 也已支持当前选区的多文件/多 commit/跨 root 批量恢复并汇总部分失败。Find merged branches 现在会按目标本地分支筛选可扫描 root，并使用与 IntelliJ `DeepComparator` 对齐的 `git cherry` patch-equivalence 语义，因此完整 cherry-picked patch series 也会被识别为 merged；同时保留 root 级失败原因，支持协作式取消并保留已完成 root 的部分结果，并可在独立的纯文本结果编辑器中查看/选择/复制包含 root 列表、扫描统计、错误数和耗时的完整报告；扫描结果现在写入受限 report store，并通过稳定 standard notification 提供可跨重启恢复的 `Open Report` semantic action。Reflog 现在在多 root Log 聚合切换时显式选择 root，独立刷新并保留仍存在的行选择，且补齐行级 Checkout/Reset/Create Branch/Compare/Rebase/Cherry-pick/Revert 上下文入口；Log/文件历史上下文现在补齐 Create Tag at Commit，并按提交所属 root 路由共享 Tag dialog；Log Changes Browser 的 Apply/Revert 已支持同一 Git root 下跨多个 commit 的选区，并按 commit/parent 分批执行；跨 root 专属通知与更完整的通知历史仍缺。FeedbackCenter 现在持久化安全的通知摘要、时间、状态和 action 文案；当前 session 仍可执行 Retry/Resolve/Restore 等 action，重启后只恢复具备 Codable semantic context 的 action，不能伪装成可执行闭包；IntelliJ 的完整通知分组和更广 action 恢复仍缺。
- 2026-08-24 Reflog tab 上下文收口：参考 VCS Log 的 root-qualified tab context，Arbor 的 `LogTabDescriptor` 现在单独持久化 Reflog root、focused entry 和 selected entry IDs，避免切换 Log tab 或恢复外部 Log 窗口时回退到主仓库；用户手动切换 Reflog root 会清空旧 root 的选区，刷新/恢复只通过当前 entry identity 保留仍存在的行；新字段使用 Optional，旧版外部 tab JSON 可继续解码。剩余仍是专属通知、跨 root 批量恢复和完整 Reflog action model。
- Update/Checkout and Update 的逐 root partial-result 已按 IntelliJ 顺序执行；Update Project 失败结果可精确 Retry Failed Roots，Checkout and Update / Checkout with Rebase 也可精确 Retry Failed Checkout Roots，不会重复已成功 root；普通 multi-root checkout 部分成功后的 `Rollback Successful Roots` 现在保存精确的 root target、previous branch/HEAD、checkout 后 expected branch/HEAD 和 created branch，并以 Codable semantic action + stable notification ID 跨重启恢复；Rust 回滚入口会在任何 reset/switch 前校验这组 expected state，若用户已切 branch 或产生新提交则拒绝覆盖；旧的无 expected state 持久化动作也会 fail closed。Update Project、Checkout and Update 的失败 root 重试，以及 Push All 的失败 root 重试和 Push non-fast-forward 的 Update with Merge/Rebase 现在也保存精确 root scope、checkout/update 参数、更新范围和策略，以 Codable semantic action + stable notification ID 跨重启恢复。仍缺的是更完整的 rollback、联合 diff 和跨 root 后续恢复编排，而不是跨 root 原子回滚。参考实现本身也不会把已成功 root 全部回滚。
- 外部 Log 独立窗口已接入：VCS 菜单和 Log 更多操作都使用共享的多选目录面板，按 IntelliJ `getGitRootsFromUser` 语义只接受实际 Git root，并将 project/root-qualified 请求传给独立 WindowGroup；窗口现在先异步验证项目 effective Git executable、发现 selected roots 并建立 Git provider session，session 持有 root-scoped repositories，随后由 `ExternalLogManager` 建立 Git provider descriptors、完成 manager 初始化并注册每个 SwiftUI Log tab，验证通过后才挂载 Log workspace，root 在选择后失效时 fail-closed；root identity 统一使用 symlink-resolved canonical path。窗口首次按所选 roots 聚合历史，仍提供不可误选空集的 root-scoped Git Roots 选择器，切换范围会丢弃旧聚合页并重新加载，窗口复用 root-aware 图、过滤、详情和上下文动作；外部窗口按 project/root scope 持久化 tabs、筛选、比较和 selection 状态，tab 增删/切换立即持久化，UI registry 拒绝重复/未知 tab，并在关闭 tab 后让异步结果 fail-closed；窗口现在以独立 session 观察 close/resize/move，关闭时取消查询、签名/详情/比较任务并释放 manager、provider session 与 root-scoped repositories，frame 按共享 dimension key 持久化且拒绝屏幕外/过小恢复。仍缺参考实现中完整 IntelliJ permanent graph/data manager，以及完整原生 VCS Log action/UI lifecycle。独立 Stash/Working Trees 工具窗仍按产品范围内嵌处理。
- 分支弹窗的 `filterByActionInPopup` 已按参考 `Git.Branches.List` 接入：单 root 与 multi-root 的 `Filter by Actions` 设置按 project path 持久化，进行中 rebase/merge/cherry-pick/revert action group、`New Branch…` 与 `Checkout Tag or Revision…` 会进入动作区、speed-search、上下键和 Enter 执行；关闭过滤时动作节点仍显示并可点击，但不进入动作键盘候选；multi-root action 显式携带 root，Cherry-pick 冲突时隐藏 Continue；fresh/unborn repository 的 New Branch disabled presentation 与原因已补齐，仍缺其它 action 的细粒度 presentation、完整 DataContext/selection lifecycle 与 UI automation。
- 2026-08-24 分支弹窗仓库搜索交互校正：对照 `GitBranchesTreeMultiRepoFilteringModel`，`Filter by Repository` 开启且输入 speed-search 后，仓库短名与 project-relative path 现在会作为 repository nodes 进入结果，并参与最佳匹配、上下键和 Enter；点击或 Enter 仓库节点会进入对应 root-scoped 过滤，顶部可清除范围。此前仅有的 repository Picker 不会命中仓库名称，已不再作为唯一入口；原生嵌套 repository popup、DataContext/action lifecycle、Log dashboard 复用和 UI automation 仍保持 partial。
- 主 Branches Popup 的 `git.branches.show.tags` 也已接入：单 root/multi-root 的 `Show Tags` 设置按 project path 持久化，并同时控制标签区与键盘候选；远程标签入口仍保持可用。剩余是完整 tag action presentation、通知历史和 UI automation。
- 多 root 聚合 Log 中的 `Add Commits to Remote Branch…` 现在按选中提交所属 root 读取 remote-tracking refs；跨 root 混选仍会安全阻止该单仓库动作。剩余差距是跨 root action 聚合、通知 action surface 与 UI automation。
- 外部变更事件现在还保留 `created/modified/removed/renamed` 类型；watcher 与 ContentView 会在去抖/交付窗口内按 root 合并 scope、路径、目录标记和 rename origin，`created + modified` 不会丢失新建语义；纯 worktree 批次会用 pathspec 增量刷新，并从同一 status 快照直接投影本地 Changelist，避免 Changelist 查询再次做全仓库 status。rename 因 FSEvents 未携带可靠旧/新路径配对会安全回退全量；root-scoped dirty-scope manager 已提供 pack/belongsTo、pending/in-progress/processed 生命周期、祖先路径压缩、30 项目录提升和递归父事件的嵌套 root 传播；歧义目录 rename 现在有按后缀生成候选、明确选择后按 Add/Remove 设置执行的路径，仍未完全复刻 IntelliJ 的逐文件 operation-state、原生 action/notification history 与 UI automation。

- 本轮补齐了多 root Update Project 的 IntelliJ `GitUpdateSession.showNotification()` 尾部：成功和 partial 状态使用 project-scoped stable display ID，并进入 `standard` VcsNotifier group；成功推进的 root 会由更新前后 HEAD 生成 root-qualified `PersistedLogRevisionRange`，通知提供可跨重启恢复的 `View Commits` action，打开单 root或聚合 Log。失败 root 的 Retry action 保持原有精确 scope，混合通知重启后保留可安全重建的 semantic actions，更新结果不会伪造未实际推进的 range；更完整的 post-update action group 与 native UI automation 仍是 partial。

## 不应继续作为缺口追踪的项目

- IDE 代码补全、重构、构建、运行配置和依赖完整代码模型的历史能力。
- Git 之外的 VCS。
- IntelliJ 插件平台和插件扩展机制。
- Local History；Git reflog 已覆盖 Git 层面的误操作找回。
- staging area 与 changelist 模式切换；当前产品决策是固定 staging area。若重新开放该选择，Shelf changelist 语义需要同步重做。

## 当前验证基线

- Rust：`cargo test --manifest-path arbor-engine/Cargo.toml --all-targets --quiet` 全量通过；本轮新增 text/eol/autocrlf staging clean、CRLF partial staging/restore、目标属性先写入的 branch checkout、目标 clean filter 预检不污染 worktree、revision/worktree canonical diff、binary 保留原始字节与 custom clean filter fail-closed 回归，并继续覆盖 Cherry-pick/Revert preserving、覆盖路径与外部 VFS Add/Remove 命令语义。
- Remote tag：`cargo test --manifest-path arbor-engine/Cargo.toml --test tags` 覆盖远程 lightweight/annotated 枚举与 lease-protected 删除；`conflict_workspace` 额外覆盖 mergetool 设置与进程组取消。
- Swift/macOS：2026-08-23 最终全量 `xcodebuild test` 执行 477 tests、0 failures；focused `CompareSelectionTests` 执行 258 tests、0 failures，包含本轮 interactive rebase native control-row argument editing、help popover、no-op confirmation、row context menu、preserve-merges 连续 branch segment unite 与 merge-row fail-closed 回归，以及此前的 Diff 入口切换、pinentry endpoint/token、Curve25519/AES-GCM、歧义目录 rename、Submodule expected-state Undo、GitVFSListener 外部变更回归。项目标准脚本 `./script/build_and_run.sh --verify` 也完成 Rust release、UniFFI 生成和 Xcode build。日志中仅有当前机器缺少 linkd/AppIntents 服务的系统级 warning，以及既有 Rust unused/dead-code warning。
- Swift/macOS：2026-08-25 当前代码的显式 result bundle `xcodebuild test` 执行 562 tests、0 failures、0 skipped，其中 `CompareSelectionTests` 316、`HostingProviderTests` 25；覆盖 permanent-graph snapshot round-trip、page-size-independent fingerprint、invalid completion/root/ref fail-closed、live containment action bridge，以及此前的 preserve-merges、merge anchor、multi-root session、root routing 和 action boundary 回归。Rust graph 还覆盖 all-ref live graph 的小页连续分页、同一 Repository 句柄 refs 漂移，以及 local/remote containing branches；`cargo test --all-targets`、`cargo fmt --check` 与 `./script/build_and_run.sh --verify` 均通过。
- Swift/macOS：2026-08-26 当前代码全量 `xcodebuild test -resultBundlePath /tmp/arbor-shelf-project-scoped-full.xcresult` 执行 585 tests、0 failures；新增覆盖 Shelf root-level、Recently Deleted lifecycle、member-group/file result tree、项目级 Show Already Unshelved 设置和 Clear Already Unshelved 稳定通知的重试累计/重载恢复。Rust `cargo test --workspace --all-targets` 全量通过（含 `shelve` 83 tests），`cargo fmt --check` 通过。`python3` CSV schema 校验为 397 rows、11 columns；`./script/build_and_run.sh --verify --project /Users/arix/src/Personal/new-p` 完成 release Rust/UniFFI、Xcode build 并确认 Arbor 进程运行。
- Swift/macOS：2026-08-28 当前代码全量 `xcodebuild test` 执行 670 tests、0 failures；本轮覆盖 stash identity、Pull/Update 恢复、multi-root resolver、外部 VFS 与既有 Git 交互回归，并新增旧版 Pull preservation marker 的 stash-ID 兼容解码断言。Rust `cargo test --workspace --all-targets` 全量通过（787 passed、0 failed、1 ignored），`cargo fmt --check` 通过；CSV schema 为 467 data rows + header、11 columns。`xcodebuild build` 与 `./script/build_and_run.sh --verify --project /Users/arix/src/Personal/new-p` 均完成 macOS 构建并确认真实 Arbor 进程运行。日志仅保留机器环境的 AppIntents metadata skipped warning。
- Swift/macOS：2026-08-26 Compare with Current 语义修正后再次全量 `xcodebuild test -resultBundlePath /tmp/arbor-log-current-workingtree-full.xcresult` 执行 592 tests、0 failures；focused `testLogCommitComparisonUsesSelectedRevisionAgainstWorkingTree` 通过。Rust `cargo fmt --check && cargo test --workspace --all-targets --quiet` 全量通过；CSV schema 校验为 401 rows、11 columns；`./script/build_and_run.sh --verify --project /Users/arix/src/Personal/new-p` 完成 release Rust/UniFFI、Xcode build 并确认 Arbor 进程运行。
- Merge source reference 绑定：UniFFI Swift API 已生成 `mergeSourceReference()`，用于重启后恢复冲突完成动作。
- i18n：本轮全量 i18n audit 扫描 1071 个 literals，zh-Hans 缺失 0 个；仍有 124 个 catalog key 缺失，主要集中在近期新增的 Branches、Apply Patch、Rebase Recovery 等入口，不能宣称文案审计已完全收口。

本轮又补齐独立 Direct Apply Patch 与 IntelliJ `PatchApplier.applyList` 的关键差异：导入 patch 现在按文件块独立尝试，成功块保留在工作区，普通失败块从持久化的应用前快照恢复并返回 `applied_paths` / `failed_paths`；SwiftUI 会把结果投影为成功或部分成功通知，并只把实际成功路径移动到目标 Changelist。真正的 Git 冲突仍保留原有 direct restore snapshot，进入可重启冲突工作台。相同的逐文件 apply 语义现在也覆盖 imported Shelf 的 raw/hunk Apply/Pop/Unshelve：成功成员保留并从 remainder/Recently Deleted 中按实际结果消费，普通失败成员保留，冲突中断并携带完整 Shelf restore snapshot。

2026-08-21 Apply Patch viewer lifecycle 校正：当前 Direct Apply Patch 冲突工作台已补齐 IntelliJ `ApplyPatchViewer` 的核心动作边界——结果/Patch 编辑器的多 change 选区批量 Apply/Ignore、统一 undo group、`Show Diff with Local` 等价的 Local → Result 预览，以及完成文件前对未决 patch change 的 Continue/Finish Anyway 确认；Reset 会清理并重新载入当前文件的持久化 hunk 决策。故“原生 editor/action lifecycle”不再作为这些具体动作的缺口，但精确的 IntelliJ Editor/DataContext、VFS/PSI FilenameIndex、多 content-root index、native notification/banner 与 UI automation 仍是 partial。

后续实现应优先按 P1 顺序推进，并在每项完成后同步 `docs/git-parity-matrix.csv`、`PRODUCT_CHECKLIST.md` 和对应 Rust/Swift 测试；不要把“参考实现存在但产品明确不纳入”的平台能力混入完成率分母。

2026-08-21 FilenameIndex 生命周期校正：Apply Patch/Unshelve 的候选索引现在按 Git root 与 content/excluded scope 持久化到应用设置，保存 Git index 路径 revision 和物理目录 revision；packed repository change 进入刷新链时会失效对应 root，多个显式 content root 会合并且嵌套 root 去重。该实现覆盖了当前产品所需的轻量 project filename provider，但不冒充完整 IntelliJ VFS/PSI；剩余差异是可配置的 IDE content-root/module 模型、原生索引通知和 UI automation。

2026-08-24 Compare Branches VCS Log graph parity：参考 `GitCompareBranchesUi` 为两个 `VcsLogPanel` 分别创建完整 Log table；Arbor 现在把两侧 unique-commit pane 接入共享 `LogGraphView`，保留独立过滤器，并提供 graph lanes、merge fragment interaction、Commit/Author/Date/Hash 列、横向/纵向滚动、Cmd/Shift 多选与完整 Log context action callbacks。比较查询现在首屏读取 80 条，每侧可独立 Load More，以上一页最后一条提交的 Rust cursor 继续读取并按 ID 去重；Refresh 会取消旧 task，并通过 generation、branch/root/filter snapshot 防止 stale result 覆盖。仍尚未具备 IntelliJ permanent VCS Log manager、native `VisiblePackRefresher`/DataContext/action-group lifecycle 与 UI automation。

2026-08-24 Compare Branches pane lifecycle parity：对照 `GitCompareBranchesUi` 的两个独立 `VcsLogUi`，Arbor 现在为 first/second pane 各自维护 Swift task、request generation、loading/error/hasMore 状态；每侧 filter 提交、Refresh 和 Load More 只刷新所属 pane，整组初始加载会并行启动两侧查询；一侧失败不会清空另一侧已加载的提交，刷新一侧也会保留另一侧的 selection。旧结果必须同时通过 compare context、pane request、branch/root 和该 pane filter snapshot 校验。剩余差异是 IntelliJ 原生 permanent manager、`VisiblePackRefresher`、native DataContext/action-group 生命周期和 UI automation。

2026-08-23 Rebase help parity：主 Rebase dialog 的 `--onto` 旁现在有可聚焦的 context-help 按钮；popover 展示 branch relationship diagram，并提供 `https://git-scm.com/docs/git-rebase` 外链，按参考 `GitRebaseHelpPopupPanel` 的可取消帮助入口实现。Native popup 的精确广告文本、主题图片资源和 UI automation 仍是 partial。

2026-08-24 native rebase/Pull recovery parity：raw-todo capture 与执行现在都通过共享 Git process runner，取消会终止 Git 及其子进程；如果 Git 已建立 native rebase 状态，保存的本地现场继续留在 Shelf/Stash 中供 Continue/Abort 恢复，尚未进入 rebase 的取消会恢复现场。Pull 的 Stash 自动恢复补上了同样的取消前边界：开始修改 worktree/index 前可取消并保留 Stash，gix 恢复一旦开始则完整结束，避免半恢复回滚；pending Pull restore 会按实际 Stash/Shelf 类型给出重试 action。新增 `arbor-engine/tests/rebase_options.rs::cancelled_raw_todo_rebase_kills_git_and_keeps_saved_scene_for_abort` 与 `arbor-engine/tests/stash.rs::cancelled_stash_pop_keeps_stash_and_worktree_before_restore`。剩余差距是多 root native control-row/editor lifecycle、原生 GitPreservingProcess/VcsNotifier/DataContext lifecycle，以及更细粒度的 UI automation。
2026-08-24 多 root native rebase cancellation parity：多 root Rebase 现在把同一个 `GitCancelHandle` 传递给每个按依赖顺序执行的 native raw-todo、structured 和 non-interactive rebase；取消会把当前 root 返回为 failed/paused recovery 状态，把尚未尝试的 root 返回为 skipped，不会把后续仓库误报为失败。已进入 Git rebase 状态的 root 保留 Continue/Skip/Abort 所需现场，尚未进入状态的取消仍恢复本地 scene；native todo capture 也支持同一取消边界。新增 `arbor-engine/tests/rebase_options.rs::cancelled_multi_root_raw_todo_keeps_active_root_recoverable_and_skips_later_roots`。剩余差距收敛为多 root native control-row/editor lifecycle、原生 GitPreservingProcess/VcsNotifier/DataContext lifecycle，以及更细粒度的 UI automation。
2026-08-24 native control-row editor parity：raw todo 的结构化预览现在不仅能编辑控制行参数，还能在 `label/reset/merge/exec/break/update-ref` 之间转换命令类型，并按原始行移动控制行；转换 `break` 会清空不适用参数，重排保持未知语法、注释、缩进和 CRLF/LF 换行不变，Git 仍负责最终拓扑/语法验证。single-root 与 multi-root 复用同一编辑器，因此两条入口都获得这组语义。剩余差距收敛为原生 popup/editor lifecycle、VcsNotifier/DataContext 分组和 UI automation。
2026-08-24 native notification category lifecycle parity：对照 IntelliJ `Notification.expire()` 的 display/action 清理，Arbor 在 stable notification ID 过期、反馈降级为 tool-window/silent，或同一 ID 更新为无可恢复 action 时，会同步移除对应 macOS `UNNotificationCategory`，保留其它通知的 category；Operation Log 历史仍保留，但系统不会继续显示已经失效的按钮。剩余差距是系统权限/permission-banner 生命周期、精确 native DataContext/action group 和 UI automation。
2026-08-24 native notification permission/banner lifecycle parity：Arbor 现在从 `UNNotificationSettings` 刷新授权与 alert 状态，覆盖首次请求、用户拒绝、系统设置关闭 banner、重新授权和应用重新激活；拒绝或 alert disabled 时在状态栏显示独立的可恢复提示，直接打开 macOS 通知设置，且不污染 Git Operation Log。剩余差距是系统原生 permission prompt/banner 的逐像素 UI automation、精确 native DataContext/action group 以及系统设置页是否可被测试宿主驱动。
2026-08-24 Quick Git Actions DataContext parity：`Commit Changes…` 现在读取与主 VCS 菜单相同的 staged/unstaged change context；clean worktree 时 action 显示但禁用，staged-only 仍可提交，避免 Quick List 与 IntelliJ `GitQuickListContentProvider` 的 enablement 分叉。剩余差距是其它 tree action 的完整 disabled presentation、原生 selection/DataContext 生命周期和 UI automation。
2026-08-24 Compare With / Show Files Diff patch parity：对照 `Git.Compare.With.Branch.Popup`、`Git.Compare.Selected` 与 Changes Browser 的选中变更动作，revision/tree compare 现在支持 `Create Patch…`。导出按所属 Git root 执行参数化 `git diff --binary --no-ext-diff`，分别覆盖 revision-to-revision 与 revision-to-working-tree，rename 同时保留旧/新路径，空输出和 Git 错误进入 FeedbackCenter。仍未宣称完整原生 Changes Browser action/DataContext 生命周期与 UI automation。

2026-08-24 external VFS ambiguous file rename parity：对照 `GitVFSListener` 的 Add/Remove action 边界，FSEvents 只提供新文件路径且状态扫描发现多个同 basename deleted candidates 时，Arbor 现在进入已有的 one-to-one move review picker；用户确认后才把新旧端点分别送入独立 Add/Remove 策略，跳过则不猜测旧端点，也不自动 staging 新文件。唯一配对、身份可证明 rename 与 ambiguous directory rename 保持原有路径；剩余差距是 native VFS operation-state、permission/banner、完整 action history 与 UI automation。

2026-08-24 operation abort confirmation parity：参考 `GitAbortOperationAction.confirmAbort()`，Commit workspace Recovery Bar 与跨重启 semantic Abort action 现在在 Merge/Rebase/Cherry-pick/Revert 四类操作共用同一 operation/repository warning confirmation；取消不会改变 Git operation state，确认后才进入原有 engine/system abort 与恢复刷新链。纯逻辑回归覆盖四类 operation 的标题、正文和确认按钮；仍缺原生 `VcsNotifier`/DataContext 生命周期及 UI automation。

2026-08-24 stash clear confirmation parity：参考 `GitStashOperations.clearStashesWithConfirmation`，顶层 Commit workspace、Branches Popup 的 primary-root `Clear All` 入口和 root-scoped Unstash 入口现在共用同一 root-scoped destructive confirmation model；取消发生在 `beginFeedbackOperation` 和 `stash_clear` 之前，不会产生操作记录或修改 stash 栈。纯逻辑回归覆盖 root 名称、空名称 fallback 和确认按钮。

2026-08-24 Create Branch from Stash retry parity：对照 `GitUnstashAsDialog` / `GitStashOperations.unstash`，失败的 `git stash branch` 现在保存 stash object id、原始 current branch/HEAD 与目标 branch，并通过 root-scoped stable notification ID 暴露可跨重启恢复的 `Retry Create Branch from Stash` semantic action；重试先重新定位 stash index，再检查原始状态、stash 仍存在且目标 branch 尚不存在，遇到冲突后已创建 branch 或其它状态漂移会 fail closed。原生 DialogWrapper/VcsNotifier/DataContext 生命周期与 UI automation 仍为 partial。

2026-08-24 Log Revert/Cherry-pick immediate retry parity：对照 `GitApplyChangesLocalChangesDetectedNotification` 与 `GitApplyChangesProcess`，Log Revert/Cherry-pick 在普通失败但未进入 sequencer 冲突态时，现在立即把已经保存的 root-scoped recovery marker 转为 `Retry Revert` / `Retry Cherry-pick` semantic action，并使用与重启恢复相同的 stable notification ID；原有 HEAD、pending-root 顺序、活动 operation 和冲突恢复门槛不变。跨应用恢复与 immediate action 已覆盖，剩余是原生 VcsNotifier/DataContext 生命周期、更完整多 root action 聚合和 UI automation。

2026-08-25 Log Revert/Cherry-pick local-change notification parity：继续对照 `GitApplyChangesLocalChangesDetectedNotification`，覆盖错误现在改为重要错误通知，不再只打开一次性 Smart 操作 modal；通知持久化 Git 报告的受影响路径并提供 `Show Files`，同时把同一 root/session/commit/initial HEAD recovery marker 切换为按已配置 Shelf/Stash 策略执行的 `Save and Retry Revert` / `Save and Retry Cherry-pick`。两种动作都通过 Codable semantic request 路由，重启后仍要求 marker 完全匹配、无活动 Git operation、HEAD 未漂移且处于最早 pending root；没有有效 marker 时保留原有 fail-closed Smart fallback。剩余是原生 VcsNotifier 的真实 changes diff 对话框、DataContext 生命周期、更完整多 root 通知聚合和 UI automation。

2026-08-24 Rebase Undo notification persistence parity：对照 `GitCommitEditingNotifications` / Rebase 成功通知的可执行 action，interactive/native/Drop Rebase、Branches Popup 的 secondary-root Rebase、Skip/Continue 结束、Pull Rebase 恢复以及 Shelf/Stash 恢复后的 `Undo Rebase` 现在统一使用已有的 Codable `undoRebase` semantic request，并绑定 root-scoped stable notification ID；重启后仍可从 Operation Log 恢复 action，执行时继续经过 expected-HEAD、branch、operation-state 和 protected-remote 校验。原生 VcsNotifier/DataContext 生命周期和 UI automation 仍为 partial。

2026-08-24 File History rename/merge parity：对照 `GitFileHistory` 的 rename-aware history 算法，Rust follow history 不再只依赖首父与 exact-blob 删除/新增配对；rewrite detection 现在覆盖“重命名同时修改内容”，路径状态按每个 commit 的 parent 分支传播，merge 两侧可以保留不同旧路径，并在分页 cursor 前重放路径状态。普通 File History 入口现在以 HEAD 为起点，`Show History for Revision` 仍以选中 revision 为起点。新增纯 rename、edited rename、merge-parent rename 与 follow pagination 回归；独立 File History tab、完整 native VCS history provider/action lifecycle 和 UI automation 仍不在当前 SwiftUI 产品边界内。

2026-08-24 File History 独立 tab 语义校正：对照平台 `Vcs.ShowTabbedFileHistory` 与 `FileHistorySessionPartner`，Changes/Log 的 Show History 现在创建或复用独立的 root-aware SwiftUI History tab，不再覆盖当前 Log tab；tab 持久化路径、起始 revision、follow、所属 Git root，切换后仍回到正确 nested repository，普通入口 HEAD 与 revision-specific 起点继续保持。该改动补齐了用户可见的独立会话交互，但仍不宣称 IntelliJ 原生 `VcsLogFileHistoryHandler`、`VcsHistoryProvider`、DataContext/action lifecycle 或 UI automation parity。

2026-08-24 Push All cumulative result parity：对照 `GitPushOperation` 在多次 push/update attempt 中保留累计 repository result map，Arbor 的 Retry Failed Push Roots / Force Push Anyway 现在只替换实际重试 root 的结果，首轮已成功 root 不再从 MultiRoot 面板或 Operation Log 结果树中消失；重试 semantic request 同时携带完整 root result rows，跨重启后仍能恢复同一结果树。Update with Merge/Rebase recovery 使用独立 notification scope，不把初始 Push rows 混入 recovery；真正跨 root rollback、联合 diff 和更复杂后续 action 编排仍保持 partial。新增 `ArborTests/HostingProviderTests.swift::testMultiRootPushRetryRowsRetainSuccessfulRootsAndReplaceRetriedRoots` 与 `ArborTests/CompareSelectionTests.swift::testMultiRootRetryActionRequestRoundTripsOperationAndRootScopes`。

2026-08-24 多选远程分支删除 tracking cleanup parity：对照 `GitDeleteRemoteBranchOperation`，Branches Popup/Log dashboard 的多选远程分支删除现在先按 remote branch 分组并一次询问共同 local tracking branches；只有该组所有选定 root 的远程删除成功后才删除本地 tracking 分支，逐 root failure/cancel 不会额外清理，force-delete 的本地 tracking 分支继续进入现有 Restore All recovery。新增 `ArborTests/HostingProviderTests.swift::testSelectedRemoteBranchDeleteGroupsStayRootQualified`；剩余是完整原生 VcsNotifier action history、远程 tag 同类通知分组和 SwiftUI UI automation。

2026-08-24 Drop/Extract selected changes Undo parity：参考 `GitCommitEditingOperationResult.Complete` 的完成态恢复边界，Log Changes Browser 的 Drop/Extract 成功后现在生成 root-qualified Codable `Undo Selected Changes` action；该 action 跨重启仍可恢复，执行前校验 operation state、精确 HEAD、symbolic branch 和 protected remote，再以 `reset --keep` 恢复原始历史。若工作区有本地修改，Undo 按项目配置使用 Stash/Shelf 保存并恢复 index、tracked、untracked 场景；HEAD 漂移、分支切换、发布保护或恢复冲突均 fail-closed。对象级 merge topology、submodule/all-selected、真实冲突对话框及 native VcsNotifier/DataContext/UI automation 仍是 partial。

2026-08-26 Drop/Extract selected changes directory-selection parity：参考 IntelliJ Changes Browser 对目录节点的 selection expansion，Log Changes Browser 目录行现在可直接选中其全部可见叶子变更；普通点击替换选择，Command 对整组增删，Shift 按可见行范围选择并包含该组，同时以全选/部分选中状态反馈。Drop/Extract 继续向 Rust 传递展开后的文件路径，all-selected、脏/未初始化 nested worktree、无法安全重放的冲突和 native Changes Browser/DataContext/VcsNotifier/UI automation 仍保持 partial。新增 `ArborTests/CompareSelectionTests.swift::testLogChangeDirectorySelectionReplacesAndTogglesTheWholeGroup`。

2026-08-24 Update Project Reset to Remote Branch parity：参考 `GitUpdateOptionsDialog.ResetToRemoteBranchAction` 与 `GitResetUpdater`，单仓库当前分支在存在 tracked upstream 时提供 VCS 菜单和工具栏 Update Options action；执行前确认本地 commit 将被远程 tip 覆盖，随后只 fetch 该 upstream，解析最新 remote tip 并复用 Smart Hard Reset、项目级 Shelf/Stash 保存策略和现有 Reset Recovery Undo/Keep。多 root、detached、无 upstream 和失效 upstream fail closed；原生 UpdateOptionsDialog/DataContext/VcsNotifier 生命周期与 UI automation 仍 partial。

2026-08-24 Update Project options dialog parity：参考平台 `UpdateOptionsDialog`、`GitUpdateConfigurable` 与 `GitUpdateOptionsPanel`，Update Project（⌘T）现在默认先打开项目级 SwiftUI options dialog；Merge/Rebase 选择在确认前只存在于 dialog draft，确认后才更新项目设置并执行，Cancel 不会泄漏选择；`Do not show this dialog again` 按项目持久化，单 root dialog 提供 Reset to Remote Branch action。原生 Swing DialogWrapper、DataContext/VcsNotifier 生命周期和 UI automation 仍 partial。

2026-08-25 多 root preserve-merges structured todo parity：多 root 结构化编辑现在把每个 root 的 visible commit ID order 与 action 一起持久化到 session/spec；Rust 按身份重建 todo，复用 merge anchor、branch segment 与 squash/fixup 合法性校验，再回写 Git native sequence-editor 的 non-merge slots。新增同一 branch segment 重排成功与跨 segment fail-closed 测试；当前剩余差距是 native control-row editor lifecycle、VcsNotifier/DataContext 分组和 UI automation，而不是 multi-root action/order 身份错配。
2026-08-24 Branches Popup unborn action presentation parity：参考 GitCreateNewBranchAction 的 isFresh 更新规则，单 root 与 multi-root Branches Popup 的顶层 New Branch… 以及 Action 搜索节点现在在没有可用 HEAD 时保持可见但禁用，并显示“Cannot create new branch in empty repository. Make initial commit first”原因；禁用 action 不进入上下键/Enter 的 keyboard candidates，Checkout Tag or Revision… 仍保持可用。新增 ArborTests/CompareSelectionTests.swift::testBranchPopupNewBranchActionIsVisibleButDisabledForUnbornRepositories；原生 action-group/DataContext 生命周期与 UI automation 仍 partial。

2026-08-25 Merge Delete-on-Merge 语义校正：对照 `GitBrancher.DeleteOnMergeOption` 与 `GitMergeOperation.notifySuccess`，single-root、root-scoped 和 multi-root Merge 现在只对非当前、非保护的本地 source branch 应用 DELETE/PROPOSE；multi-root PROPOSE 的持久化 semantic action 在执行时重新解析仍存在的 root-qualified 非当前分支，并以一个统一 destructive confirmation 进入逐 root 删除/恢复流程；取消或 root 已失效不会开始删除。Merge 后置删除只允许安全删除，若 branch 在 Merge 后重新出现未合并提交则 fail closed，不会复用普通删除流程自动 force-delete。NOTHING 成功后只发布成功与安全的 View Commits action，不再额外暴露 IntelliJ 没有的 Rollback Merge。剩余差距是原生 VcsNotifier/DataContext 生命周期、完整 post-merge action history 和 UI automation。

2026-08-25 文件级 Compare with Branch or Tag parity：对照 `GitCompareWithRefAction`，项目文件树文件上下文菜单现在提供 `Compare with Branch or Tag…`；选择器按最深匹配的 owning Git root 加载 local branches、remote-tracking branches 和 tags，root discovery 尚未完成时会按需刷新，选择后通过既有 `diff_revision_path_with_worktree_with_settings` 将 ref 文件与当前 worktree 文件送入 side-by-side/unified Diff。无差异、binary、ref 中不存在文件和异步失败均进入明确结果状态，不会回退到主 root 或把目录操作误当文件 diff。剩余差距收敛为 IntelliJ 原生 popup/DataContext/VcsNotifier 生命周期与 UI automation。

2026-08-25 目录级 Compare with Branch or Tag parity：继续对照 `GitCompareWithRefAction.getDiffChanges`，项目文件树目录上下文菜单现在提供 `Compare Directory with Branch or Tag…`；选择 ref 后由 Rust `tree_changes_with_worktree` 返回 Changes Browser 数据，SwiftUI 按选中目录过滤并保留 rename 的 old/new 两端，左侧列出 Added/Modified/Deleted/Renamed 文件，右侧复用现有 `TreeCompareDetailView` 查看逐文件 diff，并支持前后文件导航。无变更和目录 diff 错误分别显示明确状态；仍缺 IntelliJ 原生 Changes Browser/DataContext/VcsNotifier 生命周期与 UI automation。

2026-08-25 Branches Popup Compare with Current 语义校正：对照 `GitCompareWithBranchAction` 与独立的 `GitShowDiffWithRefAction`，单 root Branches Popup 的 `Compare with Current…` 现在进入现有 `.compareBranches` 双侧独有提交历史视图；`Show Diff with Working Tree` 继续进入 `.compare` 的 reference-vs-working-tree Changes Browser。此前该弹窗入口误把两者都路由为文件级 diff，已通过共享 view-mode 语义函数和 Swift 回归测试固定边界。原生 VCS Log action/DataContext 生命周期、Changes Browser 生命周期和 UI automation 仍为 partial。

2026-08-26 Compare Branches editor-tab lifecycle parity：对照 `GitBranchesUIHandler` 与 `GitCompareBranchesFilesManager`，`Compare with Current…`、`Compare Branches` 现在先保留当前 Log 上下文，再打开按 Git root 与比较范围标识的独立 Compare tab；重复打开同一 root/range 会切回已有 tab，比较页可独立切换、关闭，左右 pane 的过滤器也随 tab 保存，并沿用现有 Log tab 的恢复持久化。文件级 `Show Files Diff` 仍保持独立 `.compare` Changes Browser 语义，避免把两类 IntelliJ action 合并。仍缺 IntelliJ `VcsLogFile`/虚拟文件编辑器集成、native DataContext/action-group 生命周期与 UI automation。

2026-08-26 Branch file-diff tab lifecycle parity：对照 `GitShowDiffWithBranchPanel.showAsTab` 与 Branches Dashboard 的 `ShowArbitraryBranchesFileDiffAction`，`Show Files Diff` 和 `Show Diff with Working Tree` 现在也先保留当前 Log 上下文，再打开 root-qualified 的独立 file-diff tab；已提交范围与 Working Tree 比较使用不同 tab identity，重复打开同一 root/range/工作树模式会复用已有 tab，并接入现有 tab 恢复与 close/switch 生命周期。仍存在 IntelliJ 在 arbitrary branch pair 中使用 `CompareWithLocalDialog`、在 branch-vs-local 中使用 Changes Browser tool-window 原生 content 的呈现差异，以及 native Changes Browser action lifecycle/UI automation 长尾。

2026-08-26 LinearBek GraphAction 交互补齐：对照 `LinearBekController` 的 `MOUSE_CLICK`、`MOUSE_OVER`、`BUTTON_COLLAPSE`、`BUTTON_EXPAND` 动作边界，SwiftUI 现在以 `LinearBekGraphController` 统一维护全局折叠与逐 fragment 折叠两套状态；当全局 Collapse 关闭时，点击 merge 行、fragment 节点或可折叠边会真正生成 dotted continuation，点击 dotted edge/已折叠节点恢复 fragment；全局 Collapse 开启时保留逐 merge 展开状态，hover 与全局按钮动作也经过同一 typed controller。此前全局关闭状态下的折叠点击不会产生任何变化，已修复并覆盖 12 个 LinearBek graph tests。仍未宣称原生 `CollapsedGraph`/动态 `GraphAnswer` 的异步更新、完整 fragment highlight、VisiblePackRefresher、DataContext/VcsNotifier 生命周期或 UI automation parity。

2026-08-26 LinearBek Collapse/Expand 菜单动作补齐：对照 `Vcs.Log.CollapseAll`、`Vcs.Log.ExpandAll` 与 `GraphAction.BUTTON_COLLAPSE`/`BUTTON_EXPAND`，Log 菜单现在提供独立的 `Collapse All Graph` 与 `Expand All Graph` 动作；父级 `ContentView` 以单调递增的 command identity 把重复同类型命令送入 `LogGraphView`，子视图再通过既有 `LinearBekGraphController` 应用到当前全局或逐 fragment 状态，避免只改变持久化 toggle 或丢失连续重复命令。仍未宣称原生 action group/DataContext/VcsNotifier 生命周期、选项敏感的原生动作标题、动态 `CollapsedGraph`/`GraphAnswer` 生命周期、VisiblePackRefresher、完整 fragment highlight 或 UI automation parity。

2026-08-26 LinearBek fragment-wide hover parity：对照 fork 的 `LinearBekController.highlightNode`、`highlightEdge` 与 `CollapsedActionManager`，SwiftUI graph answer 现在返回完整 fragment 的选中行、normal edges 与 dotted edges，而不是只保存当前 pointer element；Canvas 会同时高亮递归 child fragments，折叠 dotted edge 会高亮两端节点，且 hover 离开事件按 hit-element 身份清理，避免相邻 target 的事件顺序误清除新高亮。仍未宣称原生 selected-node GraphAnswer、CollapsedGraph 隐藏节点生命周期、完整 graph selection keyboard/action group 或 UI automation parity。

2026-08-26 Changes Browser standalone diff parity：对照 fork 的 `ChangesBrowserBase` / `EditorTabPreview`，Log Changes Browser 的 `Show Diff` 不再只是重新选中当前行；preview 关闭时会打开独立的 root-aware diff sheet，双击和 Enter 复用同一 action，上下键从首/末可见文件开始移动并保持边界，binary diff 显示明确状态，异步加载按 change identity 丢弃过期结果。仍未宣称原生 `DiffManager`、`DataContext`、外部 diff tool、完整 action group 生命周期或 UI automation parity。

2026-08-26 Log Changes Browser Apply/Revert 通知边界 parity：对照 Changes Browser 的批量 patch action，Apply/Revert Selected Changes 现在按选中 Git roots 与方向生成稳定 notification identity；开始、跨 root 部分失败、direct-patch 冲突 resolver、完成/回滚及重启后恢复会复用同一条 root-qualified Operation Log 记录。完整原生 `VcsNotifier`/`DataContext` action lifecycle、通知级 diff action 聚合和 UI automation 仍保持 partial；纯逻辑覆盖 root 顺序无关与 Apply/Revert identity 分离。

2026-08-26 Operation recovery notification lifecycle parity：对照 fork 的 Continue/Skip/Abort recovery action boundary，通用 merge、rebase、cherry-pick、revert 恢复现在从动作开始到暂停、冲突、成功或失败都复用标准化 Git root 的 recovery notification ID；Continue 后的 stash restore conflict 也把同一 ID 带入完成/重试路径。带 Undo 的 rebase 完成结果仍切换到独立 Undo identity，避免把后置回滚动作与进行中的恢复状态混在一起。原生 `VcsNotifier`/`DataContext`/action lifecycle 和 UI automation 仍为 partial。

2026-08-26 Log Branches repository-grouping parity：对照 `Git.Log.Branches.GroupBy.Repository`，multi-root Log Branches dashboard 现在提供独立的 `Group by repository` 持久化开关；默认保持 repository sections，关闭后按 HEAD/LOCAL/REMOTE/TAGS ref-kind 组织并显示 repository context。所有 branch/tag/head 行仍使用 root-qualified selection、filter、navigation 和 action routing；为避免同名 refs 跨仓库误写，ref-kind 模式保守保留 root-qualified rows。IntelliJ shared RefInfo 的跨 repository 合并展示、完整 action-group/DataContext lifecycle 和 UI automation 仍保持 partial。新增 `ArborTests/CompareSelectionTests.swift::testLogBranchesRepositoryGroupingOnlyAppliesToMultiRootDashboard`。

2026-08-26 Shelf batch retry cumulative result parity：对照 fork 的 `UnshelveWithDialogAction.unshelveMultipleShelveChangeLists` 与 `ShelveChangesManager.unshelveSilentlyAsynchronously`，批量 Shelf action 现在为 Apply/Pop/Drop 建立稳定 root-qualified notification identity；Retry Remaining Shelves 只重跑未完成列表，但会保留已完成 item rows，按稳定 item id 更新重试项，并在终态与 Operation Log 重载后保持同一顺序。单项 Pop/Drop 从批量失败项继续时也复用该累计边界。仍未宣称完整 `ShelvedTreeModel`/`DataContext`、细粒度 `VcsNotifier` 分组、原生回收 action lifecycle 或 UI automation parity。

2026-08-26 Recently Deleted lifecycle retry parity：Restore Selected 与 Delete Permanently Selected 现在从 action 开始就使用稳定的 root-qualified lifecycle notification ID；批量部分失败后的 Retry Remaining Shelf Actions 只重跑失败列表，同时累计保留已完成 Shelf/file item rows，并在 Operation Log 重载后保持顺序。永久删除的语义重试会跳过第二次确认，初始用户动作仍要求明确确认。完整 `ShelvedTreeModel`/`DeleteProvider`/`DataContext` lifecycle、细粒度 Recently Deleted 通知分组和 UI automation 继续保持 partial。

2026-08-26 Shelf member-group retry parity：对照 fork 的 grouped Shelf selection 与串行 `ShelveChangesManager` action boundary，成员级 Apply/Drop/Delete 现在从 action 开始使用稳定的 root-qualified member-batch notification ID；每个 Shelf group 持久化一个 item，并展开到文件级结果。跨多个 Shelf 的选中成员新增统一目标 Changelist 对话，按同一目标串行应用并把目标写入 Retry Remaining Shelf Changes semantic action；已完成 group/file rows 按稳定 item ID 保留并更新，Operation Log 重载后继续保持同一顺序。完整 `ShelvedTreeModel`/`DataContext`/`DeleteProvider` lifecycle、原生 grouped Changes Browser selection、细粒度 `VcsNotifier` 分组和 UI automation 仍为 partial。

2026-08-26 Shelf project-state 与清理生命周期校正：对照 fork 的 `ShelveChangesManager.State.myShowRecycled` 与 `ShowHideRecycledAction`，`Show Already Unshelved` 现在按项目路径持久化并在项目切换时重新载入，不再通过全局 `@AppStorage` 在不同项目间泄漏；`Clear Already Unshelved` 从开始到空结果、成功或失败都复用同一个 root-qualified `shelf-metadata.clean` notification ID，Operation Log 连续执行会归并到同一条记录。原生 project workspace state、`ShelvedTreeModel`/`DataContext`/`VcsNotifier` 生命周期、回收结果树和 UI automation 仍保持 partial。

2026-08-26 Log Compare with Current 语义校正：对照 `GitLogDiffHandler.showDiffWithLocal`，Log、Reflog 以及 Compare Branches 两侧提交行的 `Compare with Current` 现在都使用“选中 revision ↔ 当前 Working Tree”语义，并复用 root-qualified 独立 file-diff tab；不再把当前 Log tab 改写为“当前分支 ↔ 选中提交”。仍存在 IntelliJ `CompareWithLocalDialog`/Changes Browser 原生 content、DataContext/action lifecycle 与 UI automation 的呈现差异。

2026-08-26 Shelf project-state 继续校正：对照 fork 的 `ShelveChangesManager.State.myRemoveFilesFromShelf`，`Remove Applied Files from Shelf` 现在按标准化 project path 持久化；普通 Unshelve、静默 Unshelve、Recently Deleted 和目标 Changelist 路径都读取当前项目的值，旧全局 key 不再影响新项目。仍存在 native `ShelvedTreeModel`/`DeleteProvider`/`DataContext`/`VcsNotifier` 生命周期及 UI automation 差异。

2026-08-26 Cherry-pick project-state 继续校正：对照 fork `GitVcsSettings` 中的 `isAddSuffixToCherryPicksOfPublishedCommits`，Project Git Settings 现在允许按项目覆盖已发布提交 Cherry-pick suffix；Log 批量操作在开始时捕获有效值并写入恢复上下文，项目无 override 时继续继承应用级设置。原生 `GitVcsSettings` workspace component、完整 `VcsNotifier`/`DataContext` 生命周期和 UI automation 仍保持 partial。
2026-08-26 Push tag project-state 继续校正：对照 fork `GitVcsOptions.pushTags`/`GitVcsSettings.getPushTagMode`，Project Git Settings 现在可按项目保存 All tags 或 Tags reachable from current branch；单 root、多 root 和 submodule Push 对话框读取同一 project default，单次操作仍可关闭 Push tags。原生 PushOptionsPanel/DataContext/VcsNotifier 生命周期和 UI automation 仍保持 partial。
2026-08-26 Push recovery project-state 继续校正：对照 fork `GitVcsOptions.isPushAutoUpdate`、`GitVcsSettings.autoUpdateIfPushRejected` 与 `GitPushOperation`，Project Git Settings 现在支持当前分支 non-fast-forward Push 被拒绝后的自动 Update-and-retry，并按项目 `Update method` 选择 Merge/Rebase；force push、custom refspec、非当前分支、无 upstream 和 force-with-lease rejection 均保持手动恢复。单 root、root-scoped 和 multi-root Push 路径共用同一资格判断。原生 `GitVcsSettings` workspace component、GitPushOperation dialog/do-not-ask/local-history 生命周期和 UI automation 仍保持 partial。
2026-08-26 Commit project-state 继续校正：对照 fork `GitVcsOptions.isSignOffCommit` 与 `GitCommitOptions`，Project Git Settings 现在按项目保存 `Signed-off-by` 默认值，单 root 与 multi-root Commit dialog 在项目切换时重新读取有效值；无项目 override 时兼容既有全局 identity 设置。原生 `GitVcsSettings` workspace component、完整 CommitOptionsPanel/DataContext 生命周期和 UI automation 仍保持 partial。
2026-08-26 `Git.Ignore.File` 多选与共同候选补齐：继续对照 fork `IgnoreFileActionGroup`/`IgnoreFileAction` 的 `EXACTLY_SELECTED_FILES` 语义，Changes 区域现在由工作区统一维护 Cmd-多选，选择可跨 staged/unstaged/change list 分组传播；Ignore file 候选对所有有候选的 unversioned 路径取祖先链交集，并保持首个非空候选列表的最近优先顺序；无候选路径在写入选定 ignore-file 时按 fork 语义过滤。Rust 新增批量 root 与指定 `.gitignore` 写入 API，先校验传入目标均在所选 ignore-file scope 内，再一次追加所有规则；全部路径无既有候选时先确认再按 fork 的 root `.gitignore` fallback。原生 ChangesView/DataContext/action lifecycle、通知细节和 UI automation 仍为 partial。
2026-08-26 Reset/ROOT_SYNC project-state 校正：对照 fork `GitVcsOptions.resetMode`、`GitVcsSettings.getResetMode`、`GitVcsSettings.rootSync` 与 `GitBranchesTreePopupTrackReposSynchronouslyAction`，Project Git Settings 现在按项目保存 Soft/Mixed/Hard/Keep 默认 Reset 模式及 `NOT_DECIDED`/`SYNC`/`DONT_SYNC` 三态 root action scope；Reset dialog 在当前项目加载对应默认值，并在单 root 与 multi-root 用户确认后保存最后选择，默认仍为 Mixed。Multi-root Branches Popup 的 Settings 菜单同步暴露该 scope，`SYNC`/`NOT_DECIDED` 显示同名 branch/tag/remote 的跨 root 快捷操作，`DONT_SYNC` 则隐藏快捷聚合但保留显式 root-qualified 多选，避免把“只操作当前 repository”误做成禁用全部多 root能力。原生 `GitNewResetDialog`/`DvcsSyncSettings` workspace component、首次同步提示、完整 affected-repository `DataContext` 路由和 UI automation 仍保持 partial。
2026-08-26 Commit warning checks gap 审计（已由后续实现 supersede）：当时记录的缺口已在同日的 Commit warning 主链路与 rebase 上下文校正中补齐；V1 仅保留原生 warning workspace、通知生命周期和 UI automation 作为 `verified-partial` 宿主边界。
2026-08-26 Commit warning 主链路补齐：继续对照 fork `GitCheckinHandlerFactory` 与 `GitVcsOptions.WARN_*`，Project Git Settings 现在按项目保存 CRLF、detached HEAD、大文件、Windows 不兼容文件名四类开关，并以 50 MB 为默认大文件阈值；Rust 新增可配置阈值、选定路径范围、Git LFS root 排除和 Windows 保留名/非法字符结果。单 root 与 multi-root Commit 在任何 Git 写入前统一收集 warning，按 root 展示，CRLF 提供设置 `core.autocrlf=input` 并提交，所有 warning 提供 Commit Anyway、Cancel 和每类项目级 Do-not-ask；新增 `ArborTests/CompareSelectionTests.swift::testCommitWarningSettingsAreProjectScopedAndDefaultToIntelliJValues` 与 `arbor-engine/tests/commit_checks.rs::configurable_large_file_limit_and_selected_paths_cover_bad_names`，Swift 599/599、Rust workspace 全量和 build/run 均通过。后续已由 rebase 上下文校正补掉 detached-rebase 分类残差，仍为 partial 的是原生 warning dialog/workspace/DataContext/VcsNotifier 生命周期和 UI automation。
2026-08-26 `Git.Ignore.File` 根文件创建确认补齐：对照 fork 的 `CreateNewIgnoreFileAction.confirmCreateIgnoreFile`，没有可用既有 `.gitignore` 时，Arbor 现在在写入前显示创建确认；确认后再次校验当前仓库 root 未切换，再调用 Rust root 批量写入。原生 ChangesView/DataContext/action lifecycle、通知细节和 UI automation 仍为 partial。

2026-08-26 linked worktree metadata root 校正：对照 fork 的 `GitRepositoryFiles`/`GitRepositoryUpdater`，`commondir` 现在只有在能解析为现存目录时才加入 metadata watcher；缺失、空值、失效路径或非目录文件会回退到 worktree-specific Git directory，`Edit .git/info/exclude` 也复用同一安全解析。剩余差距是完整原生 `VcsDirtyScope` 生命周期、operation-state 细分和 UI automation。
2026-08-26 Create Patch 配置交互补齐：对照 fork 的 `PatchWriter`/`UnifiedDiffWriter`，Log 选中变更、Compare 选中树变更和 Diff Viewer 现在共用 SwiftUI 配置对话框，支持 reverse、Copy to Clipboard，以及在所有 selected old/new endpoint 都位于其中时的仓库内 base directory；已有 command orientation 会被保留或按用户选择只翻转一次，Git 参数仍分离传递。单提交 Log patch 增加 IntelliJ 风格 `Subject: [PATCH]`/`---` header，多组 revision patch 统一收敛 LF 边界；完整 revision 导出因尚未预加载全量路径，安全地固定使用 repository root。剩余是原生 `PatchWriter` 的文件/encoding/common-parent 持久化、Changes action/DataContext/VcsNotifier lifecycle 和 UI automation。
2026-08-26 PatchWriter 编码与偏好持久化补齐：对照 fork `PatchWriter`/`CreatePatchConfigurationPanel`，Create Patch 现在提供 UTF-8、UTF-16、ISO-8859-1、Windows-1252；文件写出使用显式非 lossy `Data` 编码，剪贴板保持 Unicode 文本；encoding、Copy to Clipboard 和上次导出目录按 canonical Git root 持久化，Log、Compare、Diff Viewer 共用同一设置，取消 save panel 不保存本次选项。由于 Rust `GitCommandResult` 当前以 `String`/UTF-8-lossy 暴露 Git stdout，任意非 UTF-8 原始 diff 字节仍未完全保真；完整 `CharsetToolkit`/`EncodingProjectManager` 默认值、原生 dialog/action lifecycle 与 UI automation 仍为 partial。
2026-08-26 PatchWriter 原始 stdout 字节链路补齐：Rust Git runner 的普通与可取消路径同时保留 `stdout_bytes` 和用于 UI 的 Unicode `stdout`；Compare、Log、Diff Viewer 及多组 Log patch 文件写出直接走原始字节，只有有效 UTF-8 才转码到用户选择的目标编码，非法 UTF-8 选择 UTF-8 时逐字节保留，选择其它编码则 fail closed；剪贴板继续使用 Unicode 文本。剩余是未知源字符集到另一目标编码的安全推断、完整 `CharsetToolkit`/`EncodingProjectManager` 默认值、原生 PatchWriter/DataContext/VcsNotifier 生命周期和 UI automation。
