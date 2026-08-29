# IntelliJ Git 能力复刻执行方案

状态：V1 scope closed (2026-08-29)

2026-08-28 `Git.Show.Stash`：已补齐主菜单 Show Stash 入口，复用 Commit/Stash 工作页的 tab 请求，并将 Local Changes 子菜单顺序对齐 fork；未把它错误实现为 Unstash 弹窗。

2026-08-28 `Git.Stash.UnstashAs`：已补齐单 stash 行的组合对话框，支持 Apply/Pop、恢复 staged state、创建分支和最终 branch name 校验；stash ID 在执行前重新映射为当前 stack index。

2026-08-28 `Git.Stash.Toggle.Split.Preview`：已补齐默认开启的应用级持久化 split-preview toggle；关闭时不自动挂载内嵌 stash diff，显式 View Diff 仍打开独立预览 sheet。

2026-08-28 Stash 预览身份：已将工作页预览从数值 stack index 改为稳定 stash ID，并在后台读取前按当前栈重新解析，避免刷新/删除前置 stash 后错位显示。

2026-08-28 `Git.Stash`：已补齐显式 Stash 的 root chooser/current branch 上下文与 `Keep index`，并让 secondary root 使用自身 Repository 执行；Pull/Update 的完整工作区保存仍走独立 API。

2026-08-28 Stash 操作身份收口：Commit/Stash 工作页、旧侧栏、Branches Popup、Unstash/Unstash As、Pull/Update、Checkout/Reset/Force-update 恢复、多 root Update 恢复以及 Diff/Preview 都以 stash commit ID 作为跨异步边界的对象身份，仅在调用引擎 index API 前按当前 stash 栈重新定位；冲突暂停、完成恢复和跨 root resolver 同样保存该 ID。缺少 ID 或 Pull 唯一 message 的旧恢复状态 fail-closed 并保留 stash，不再猜测数字位置。

目标：在不实现 IDE 补全、重构、构建能力，不引入其他 VCS，不实现插件平台的前提下，使 Arbor 达到 IntelliJ Git 核心能力的功能、交互模型和异常恢复行为等价。

基线：`/Users/arix/src/rebased/plugins/git4idea`

当前项目：`arbor-engine`（Rust）+ `Arbor`（SwiftUI）

2026-08-28 `Git.Init`：已补齐目录已属于 Git 时的重复初始化 warning/confirm，并覆盖选中子目录的 owning-root 识别。

2026-08-28 `Git.Pull` 主菜单交互对齐：VCS > Git 现在提供单一 `Pull…` action，点击后沿用已实现的 root/remote/remote-tracking branch/options dialog；不再要求用户先从菜单分叉选择 Merge 或 Rebase，默认策略从 dialog settings 恢复。原生 GitPull/DialogWrapper/DataContext/VcsNotifier lifecycle 和 UI automation 仍为 partial。

2026-08-28 `GitCreateNewBranchAction` fresh/unborn presentation 对齐：顶层 New Branch action 按所有受影响 Git roots 的 HEAD 状态更新；存在 unborn root 时保留可见性但禁用，并在 action handler 再次拒绝过期或绕过菜单的调用。原生 action/DataContext lifecycle 和 UI automation 仍为 partial。

2026-08-28 `FindMergedLocalBranchesAction` presentation 对齐：只有至少一个 Git root 拥有两个以上 local branches 时，single-root 与 multi-root Branches Popup 才启用 `Find Merged…`；扫描、取消和报告内容保持既有实现。原生 action/DataContext lifecycle 和 UI automation 仍为 partial。

2026-08-28 `Git.Checkout.Update` 调用时状态校验补齐：单 root 入口在异步 checkout 前重新确认有效 tracking branch；状态过期时不切换分支并提示刷新，保持 fork `GitCheckoutWithUpdateAction` 的 invocation-time guard 语义。原生 `ActionData`/`DataContext`/`VcsNotifier` lifecycle 和 UI automation 仍为 partial。

2026-08-28 Cleanup Branches 表格选择语义补齐：对照 fork `CleanupBranchesDialog`，Cleanup Branches 现在分离 JTable 行选中与删除勾选；Copy/⌘C 只取可见排序行，Filter 同步清理隐藏行选择。原生 JTable/CopyProvider/DataContext 生命周期和 UI automation 仍为 partial。

2026-08-28 Git 文件上下文菜单补齐：对照 fork `Git.ContextMenu`，项目文件树现在提供 Checkin Files、Add、Compare、History、Annotate、Revert、Resolve Conflicts 和 Revert Resolved；Add/Revert 执行前重新解析 owning Git root，目录递归 Add 与冲突目录聚合保持禁用，避免扩大 Git 操作语义。原生 VersionControlsGroup/DataContext/VcsNotifier lifecycle 和 UI automation 仍为 partial。

2026-08-28 `Show.Current.Revision` 入口补齐：项目文件树文件上下文菜单按最深 owning Git root 使用 `git log --all --follow -n1 -- <path>` 查询路径历史并展示 revision、author、date、message；无历史、untracked、ignored、conflicted 文件保持禁用/失败关闭。使用 SwiftUI metadata sheet 承载交互，原生 ShowBaseRevisionAction 的 notification/DataContext/ProgressManager/VcsNotifier lifecycle 与 UI automation 仍为 partial。

2026-08-27 Git 主菜单 Clone 入口补齐：对照 fork `Git.MainMenu` 的 `Git.Clone`，VCS > Git 现在直接打开已有 clone dialog；File 菜单和空状态页入口保持共享同一实现。clone 的原生 action/DataContext 生命周期仍不宣称完全一致。

2026-08-27 Git Reset Head 主菜单入口补齐：对照 `GitResetHead`/`GitResetDialog`，VCS > Git 现在支持 Git root 选择、任意 revision expression Validate 以及 Soft/Mixed/Hard；执行复用已有 reset recovery、Smart/Force 和 Undo/Keep。原生 DialogWrapper/ProgressIndicator/VcsNotifier/DataContext lifecycle 仍为 partial。

2026-08-27 Git Revert Resolved 主菜单入口补齐：对照 `GitRevertResolvedAction`，VCS > Git 增加 selection-scoped `Revert Resolved`，仅对明确选中的 resolved path 启用；执行复用既有冲突 ledger 和 root-scoped engine API。原生 DataContext 多选/VcsNotifier/UI automation 仍为 partial。

2026-08-27 Git.FileActions 主菜单 action group 补齐：VCS > Git 现在按显式选中文件/目录显示 Checkin Files、Add、Annotate、Compare with HEAD、Compare with Selected Revision、Compare with Branch or Tag 和 Show File History；写操作在执行前重新校验 owning Git root。History for Block、多选 DataContext、原生通知/动作生命周期和 UI automation 仍为 partial。

2026-08-27 Branches Popup Tag action parity 补齐：对照 fork `GitBranchesTreeActionsForSelectionTest`，单 root/multi-root 非当前 Tag 现在提供 Checkout，并使用既有 root-scoped tag checkout；当前 Tag 移除 branch-only New Working Tree/Rename。原生 GitCheckoutAction/DataContext/VcsNotifier lifecycle、smart-checkout 细节和 UI automation 仍为 partial。

2026-08-27 单 root Branches Popup 无 remote 的 Push 可达性补齐：对照 fork `GitPushBranchAction`，本地分支没有 configured remote 时仍打开 Push dialog，Push 模式显示明确的 Configure Remotes 路径；`Commit and Push` 继续保留无 remote 的 commit-only fallback。此前 `beginPushDialog` 静默 return，导致可见的 branch Push action 点击无反馈。原生 VcsPushDialog 空 remote presentation、VcsNotifier/DataContext lifecycle 与 UI automation 仍为 partial。

2026-08-27 单 root Branches Popup 分支 Push 入口补齐：对照 fork `GitPushBranchAction`，本地分支行现在提供 `Push…`，当前/非当前分支均把选中 branch 传给既有 Push dialog 作为 source；multi-root 路径继续使用 root-qualified dialog。此前单 root 仅有 `.push` action availability，却没有渲染对应菜单项。原生 VcsPushDialog/VcsNotifier/DataContext lifecycle 与 UI automation 仍为 partial。

2026-08-27 in-memory 历史改写取消语义补齐：对象级 Log Drop/Interactive Rebase 现在共享 `GitCancelHandle`，在保存现场前及每个 replay step 前检查取消；取消恢复原 HEAD 边界，保存现场包装器负责恢复 staged/unstaged/untracked scene。Log Drop 已接入 cancellable API；ProgressIndicator/ProgressWindow/DataContext lifecycle 与 UI automation 仍为 partial。

2026-08-27 多 root Log Revert/Cherry-pick Abort 语义校正：Abort 当前 root 时按 session + operation 清掉整条复合操作的 root-scoped recovery marker 与陈旧 Retry 通知，避免出现“已中止但后续 root 仍可 Retry”；Continue 的顺序推进保持不变。新增 session cancellation scope 回归测试；原生 VcsNotifier/DataContext lifecycle 与 UI automation 仍为 partial。

2026-08-27 Submodule Sync 面板入口补齐：对照 Git 的 submodule sync 能力，Operations > Submodules 现在提供明确的 `Sync` action，接入既有 root-scoped、可取消、可重试的 `git submodule sync --recursive` runner；此前 WorkspaceOperations 已有实现但没有可见面板入口。仍待对齐的是原生 action-group/DataContext/VcsNotifier lifecycle 和 UI automation。

2026-08-27 Git annotate options 对照补齐：参考 fork 的 `GitToggleAnnotationOptionsActionProvider` 与 `GitAnnotationProvider`，Blame 默认忽略空白，并支持按需检测文件内移动、跨文件移动和优先使用 committer date；FileContentView 与 DiffDetailView 共用持久化的 Blame Options 菜单，Rust HEAD/worktree 两条路径统一传递 `-w`/`-M`/`-C` 和日期选择。仍待对齐的是原生 AnnotationGutter/FileAnnotation/DataContext 生命周期、受影响路径缓存、系统编辑器 gutter 与 UI automation。

2026-08-27 Commit warning 顺序交互对照补齐：参考 `GitCheckinHandlerFactory` 的有序 `CommitCheck` 与 `GitCrlfDialog`，单 root 与 multi-root Commit 现在逐 warning category 显示 native modal decision；Commit Anyway/Cancel、CRLF 的 Set `core.autocrlf` and Commit、category-scoped Do-not-ask 和同一提交内的 duplicate suppression 已统一。仍待对齐的是原生 DialogWrapper/CommitCheck/VcsNotifier/DataContext lifecycle、详情链接和 UI automation。

2026-08-27 Auto Fetch 后台认证模式对照补齐：参考 `GitBranchIncomingOutgoingManager` 的 `AuthenticationMode.NONE` 与认证成功后的 `SILENT` 选择，后台 FETCH/LS_REMOTE 首次检查现在禁用 credential helper 和交互提示；broker 已成功认证的 remote 只静默复用 Keychain/安全凭证，缺失凭证不会弹 UI、不会被分类为用户取消，也不会进入交互重试。显式 Fetch/Pull/Push/Clone 继续使用 Interactive broker。剩余是原生 VcsNotifier permission/banner 生命周期、完整 agent/helper 来源语义和 UI automation。

2026-08-27 Commit and Rebase autosquash 语义校正：对照 fork 的 `GitRebaseCheckinHandlerFactory`，Fixup/Squash 提交后的自动整合现在由 native `git rebase -i --autosquash` 执行；Rust 只负责 target/range 校验，root target 传递 `--root`，现有取消、冲突暂停、本地现场恢复和 expected-HEAD Undo 保持不变。新增 native 普通/root autosquash 回归；通知分组、Commit Executor/DialogWrapper/DataContext lifecycle 与 UI automation 仍为 partial。

2026-08-27 IntelliJ in-memory commit editing registry 对照补齐：新增默认开启的全局 `git.in.memory.commit.editing.operations.enabled` 等价开关，并在 `WorkspaceOperations.startTodoRebase()` 与直接 Drop Selected Commits 入口真实决定后端；无 EDIT 且不保留 merge 拓扑时走 Rust in-memory rebase，设置关闭、EDIT、merge-preserving 或 conflict fallback 时走 native structured interactive rebase。in-memory conflict 会先 abort 并恢复原 HEAD/本地现场，再重放完整 native todo；native 再次冲突时进入既有原生恢复状态。当前默认关闭的 `git.in.memory.interactive.rebase.debug.notify.errors` registry、VcsNotifier/DataContext 生命周期和 UI automation 仍保持 partial。

2026-08-27 Auto Fetch/LS_REMOTE incoming state 对照补齐：`GitBranchIncomingOutgoingManager` 的 live remote 检查结果现在按 root/remote/branch 保留为带 checked-remote 身份的 Swift snapshot，供 Branches Popup、multi-root Branches、分支按钮和状态栏显示 `↓?`；每轮空 snapshot 只清除已完成检查 remote 的陈旧 incoming/error 状态，失败或争用 remote 不被误清除。该 snapshot 只改变可见性，不改变分支 action availability 或 transport；native VcsNotifier/permission/banner、完整 dashboard model 和 UI automation 仍保持 partial。

对照校正：`GitUpdateProcess` 对多个 Git root 逐个执行 updater 并汇总 partial result；跨 root 原子回滚不是 IntelliJ 的既有语义。Arbor 额外提供 expected-HEAD 保护的 Update Project rollback 作为恢复增强，但不把它当作 IntelliJ 的跨 root 原子事务；parity 验收仍优先核验每个 root 的恢复、通知 action、取消和外部 merge tool 边界。

2026-08-27 Git incoming/outgoing visibility gate 对照补齐：参考 `git.update.incoming.outgoing.info`，增加默认开启的全局开关；禁用时 effective strategy 为 NONE，monitor 停止，Branches Popup/状态栏同步徽标隐藏，旧的 incoming/error semantic notification 失效，重新启用后恢复已保存策略。项目级 picker 与全局开关遵循同一 disabled 语义；原生 AdvancedSettingsPredicate/GitVcsSettings/VcsNotifier/DataContext lifecycle 与 UI automation 仍为 partial。

2026-08-27 Update Project readiness 对照补齐：参考 `GitUpdateProcess.isUpdateNotReady()`，复合 Update 在 fetch、保存现场或整合任何 root 之前统一检查所有选中 root 的进行中 Git 操作与未解决 index 冲突；阻塞 root 返回失败，其余 root 返回未执行，Swift 进入 `Update Project unavailable` 与 Conflict Workbench 恢复流。与上一项全 skipped upstream/detached 检查合并后，Update Project 的就绪判定不再允许“先更新部分 root、再发现后续 root 不能更新”。

2026-08-26 `Git.Add` ignored-file confirmation 对照补齐：参考 fork `GitAdd.isStatusForAddition(IGNORED)` 与 `GitFileUtils.addPaths(..., containsIgnored)`，Arbor 的 Ignored Files 行现在提供 `Add to Git…`，用户确认后才调用 root-scoped staging primitive 写入 index；取消保持原 ignored 状态。该项补齐的是显式用户动作与安全确认，不改变默认 `Stage all`/普通 Stage 的 ignored 排除策略；原生 ChangesView/DataContext 生命周期和 UI automation 仍为 partial。

2026-08-26 Commit warning rebase 上下文对照补齐：参考 fork `GitDetachedRootCheckinHandler` 对 interactive rebase 的 suppress 与普通 rebase 的专用提示，Rust `commit_checks()` 新增结构化 `RebaseInProgress`；interactive rebase 不再误报 generic detached HEAD，非 interactive rebase 显示专用 warning，Swift 复用既有 project-scoped detached-head 开关。该项只修正 warning 分类与交互文案，不改变 Commit 的安全 gate；原生 warning dialog/VcsNotifier/DataContext 生命周期和 UI automation 仍 partial。

2026-08-26 `Git.Show.Stage` action reachability 对照补齐：fork 的 backend action 注册将 Staging Area 暴露为独立入口；Arbor 在 VCS > Git 增加 `Show Staging Area`，按当前 repository action context 启用，并进入现有固定 Commit/Staging workspace，Shelf tab 会被清除。该增量只补菜单可达性和 root-safe enablement，不引入独立 staging 模式；native action-group/DataContext/tool-window focus 生命周期与 UI automation 仍为 partial。

2026-08-26 Git 主菜单进行中操作 action group 对照补齐：参考 `Git.MainMenu.MergeActions`、`Git.MainMenu.RebaseActions` 和 `Git.Ongoing.Rebase.Actions`，`ProjectCommands` 现在从 focused `operation_state()` 读取当前 root，暴露 Merge 的 `Commit Merge`/`Abort Merge`、Rebase 的 Abort/Continue/Skip，以及 Cherry-pick/Revert 的恢复入口；所有 command 通过 Codable `operationRecovery` request 携带 project/root scope。Branches Popup 保持参考 action group 边界（Merge 只显示 Abort），顶部 `GitMergeRebaseWidget` 的 Merge action 改为 `Commit Merge`，冲突时按参考 action-update 禁用。原生 action-group/DataContext/VcsNotifier lifecycle 和 UI automation 仍为 partial。

2026-08-26 multi-root Rebase 结果树校正：`MultiRootRebaseSession` 的 paused root 在反馈边界映射为 partial；Retry 在稳定 notification ID 复用后先恢复已有累计 rows；engine 抛出操作级错误时也重新挂回当前 session tree，首次运行则不提前展示 pending rows。该项补齐了结果状态与生命周期语义，不改变 Rust Rebase 执行或跨 root 非原子边界；native VcsNotifier/DataContext/action-group 生命周期和 UI automation 仍保持 partial。

2026-08-23 对照校正：Log Revert/Cherry-pick 已补 ordered-session root-scoped durable recovery context；旧版本单 root marker 会迁移为 legacy single-root session。每个 root 在 mutation 前保存 root 顺序、有序 commit IDs、初始 HEAD、Smart 保存策略和 Cherry-pick 选项；重启后的 Retry 仅在它是最早 pending root、无活动 Git operation 且 HEAD 未漂移时执行，Abort 保留安全重试，冲突 Continue 完成当前 root 后自动推进下一 root。完整 GitApplyChangesNotificationsHandler 分组、DataContext 生命周期与 UI automation 仍列为 partial。

2026-08-23 多 root 结果反馈校正：通用 Fetch/Pull runner、Push All、Push recovery、Commit All/Commit Selected、multi-root Merge 及 multi-root Rebase 现在把逐 root `RootOperationResult` 映射为可 Codable 的 `FeedbackResultRow`，并在 Operation Log 详情中按执行顺序展示每个仓库的成功、跳过、失败、root path 与原因；初始 Merge、Push、Commit、Rebase 通知使用稳定 ID，rollback/delete-on-merge 仍保持独立生命周期。该增量仍不升级为所有 multi-root action 的统一 `UpdateInfoTree`；Shelf 等自定义 runner、原生 VcsNotifier 生命周期、DataContext/action-group 与 UI automation 仍保持 partial。

2026-08-24 native notification permission/banner 校正：`ArborNativeNotificationCenter` 现在通过 `UNNotificationSettings` 刷新 authorization 与 alert 状态，覆盖用户拒绝、系统设置关闭 banner、重新授权和应用重新激活；FeedbackCenter 在状态栏提供独立的 Open Notification Settings 恢复入口，不写入 Git Operation Log。剩余差距收敛为系统原生 permission prompt/banner 的精确 UI automation、native DataContext/action-group 以及系统设置页的测试驱动。

2026-08-24 Quick Git Actions DataContext 校正：`Commit Changes…` 现在与主 VCS 菜单共享 staged/unstaged Git changes 的 enablement；clean worktree 不再错误暴露可执行 Commit，staged-only 状态仍保持可用。该项收口一个具体 action-group enablement 差异，完整 SwiftUI selection/DataContext 生命周期与 UI automation 仍保持 partial。

2026-08-24 Hosting file revision 校正：参考 `GlobalHostedGitRepositoryReferenceActionGroup` 的文件 revision 路径已补齐。Rust 新增 GitHub/GitLab/Bitbucket 文件 permalink 与安全 path encoding；Log Changes Browser 的文件行和 File History 语境现在提供 Browse File in Browser / Copy File Link，并按 `commit.repositoryPath` 路由到正确 Git root。多 remote 的原生 DataContext/VcsNotifier action lifecycle、编辑器行号链接和 UI automation 仍保持 partial。

2026-08-24 Hosting action group 多 remote 校正：Commit Details、Log 提交行和文件 revision 入口现在共享 IntelliJ 的 0/1/多 remote presentation 语义；单个 supported remote 直达，多个 supported remote 按 remote name 展开 Open in Browser / Copy Link 子菜单，且提交级/文件级执行都使用 root-qualified 的选中 remote，不再隐式取第一个。该项通过 `HostingProviderTests` 的 presentation 回归和完整 `xcodebuild test` 验证；编辑器当前文件/行号链接、原生 VCS DataContext/VcsNotifier lifecycle 与 UI automation 仍保持 partial。

2026-08-24 Pull Request remote 校正：旧 Branches 侧栏、Log 的 Open Pull Requests 与 Comment this commit 现在按 root-qualified supported remote 执行，单 remote 直达、多 remote 展开选择；Rust `pr_url` 覆盖 GitHub/GitLab/Bitbucket HTTPS/SSH/SCP remote、branch 编码和 fail-closed，HostingProvider 的 PR 列表路径按 provider 区分。该项通过 hosting Rust 回归与完整 `xcodebuild test` 验证；API 创建 token/账户选择、原生 hosting DataContext/action lifecycle 和 UI automation 仍保持 partial。

2026-08-24 Push Tag remote 校正：参考 `GitPushTagsActionGroup` 为每个 configured remote 创建独立 wrapper 的语义，Log Tags、单 root/multi-root `Push All Tags` 现在单 remote 直达、多 remote 展开选择；`pushTag`、`pushAllTags` 及 root-scoped 后端只接受显式或唯一 remote，多 remote 未选择时 fail-closed，不再静默取第一个。保留 credential broker、取消句柄、结构化拒绝和非 force wildcard refspec；原生 action wrapper/DataContext/VcsNotifier lifecycle、完整 UI automation 与通用 Push 默认 remote 仍为 partial。

2026-08-24 通用 Push remote 校正：参考 `GitPushBranchAction` 打开 `VcsPushDialog` 的语义，主工具栏 Push 现在统一进入 `PushDialogView`；对话框只有在唯一 remote 时隐式初始化，多个 remote 不再预填第一个，未选择时禁用 Push；`pushInRoot` 与 legacy `doPush` 执行层也移除 first-remote fallback，仅接受显式或唯一 remote。Push dialog 的 native DataContext、target discovery、VcsNotifier lifecycle 与 UI automation 仍保持 partial。

2026-08-24 Remote Tags remote 校正：单 root Remote Tags 浏览/删除现在唯一 remote 自动选择，多 remote 不预填第一条并要求显式选择；读取和删除都使用同一 selected remote，避免远程 tag action 被错误路由。自定义 SwiftUI UI、原生 action/DataContext、通知 lifecycle 与 UI automation 仍保持 partial。

2026-08-24 Compare Branches 行级 action 校正：参考 `GitCompareBranchesUi` 的两侧 VCS Log，Arbor 双栏比较中的 unique commit 行现在拥有 View Details、Checkout、Reset、Create Branch、Compare、Interactive Rebase、Cherry-pick、Revert 上下文 actions，并统一复用现有 root-safe Log handlers；Compare 按选中 commit 的 owning root 读取当前分支，merge commit Revert 和不可用 Interactive Rebase 会禁用。完整 VCS Log filter/graph/action lifecycle 与 UI automation 仍为 partial。
2026-08-24 Compare Branches filter parity：两侧 unique-commit pane 现在各自支持 Message/Hash、Author、Since、Until、Regex、Match Case、No Merges；请求使用 `log_filtered_with_message_and_date_options_for_revisions`，hash 在对应 range 返回值上按 ID 前缀过滤，日期错误会 fail-closed，异步结果校验 branch/root/filter snapshot。完整 VCS Log graph、分页/refresh、native action/DataContext lifecycle 和 UI automation 仍为 partial，单次比较查询仍限制 500 条。
2026-08-24 Compare Branches pagination/refresh parity：两侧 pane 现在保留各自 loaded entries、hasMore 和 loading state；首屏读取 80 条，单侧 Load More 使用当前 loaded count + 200 的累积 revision-range 查询，仅投影新增且按 commit ID 去重；Refresh 会取消旧 task，generation 与 branch/root/filter snapshot 校验阻止 stale result 回写。由于 Rust log API 没有直接的 revision cursor，这是一层兼容分页投影，不声称 IntelliJ `VisiblePackRefresher`/permanent `VcsLogManager` 的原生生命周期；native DataContext/action-group lifecycle 和 UI automation 仍为 partial。
2026-08-24 Compare Branches pane task parity：两侧现在分别持有 task、request generation、loading/error/hasMore，pane filter、Refresh 与 Load More 均按 side 触发；初始 compare 会同时启动两个查询，side-specific filter/date error 不再清空另一 pane，旧 task 只有在 context、side request、branch/root 和本侧 filter snapshot 都匹配时才可发布。Swift 层已达到独立生命周期语义；Rust API 无 revision cursor，分页仍是累积查询 + 增量投影，不声称 IntelliJ `VisiblePackRefresher`/permanent `VcsLogManager` 原生实现；native DataContext/action-group lifecycle 和 UI automation 仍为 partial。

2026-08-24 Remote 配置/Unshallow remote 校正：`RemoteConfigDialogView` 与 root-scoped remote config 在无显式 selection 时不再默认编辑第一条 remote；参考 `GitFetchSupportImpl.getDefaultRemoteToFetch`，`Git.Unshallow` 现在单 remote 使用唯一 remote，多 remote 优先 tracking remote，再使用 `origin`，无法安全判断时 fail-closed 并反馈下一步。原生 table/DataContext selection、后台通知和 UI automation 仍保持 partial。
2026-08-24 Update Project 保存策略校正：参考 `GitVcsSettings.saveChangesPolicy`，Project Git Settings 现在可以按规范化 project path 覆盖全局 Shelf/Stash 选择；dirty Pull/Update 保存现场，以及现有 Rebase、Merge、Reset、Checkout、force-pushed update runner 都读取项目策略，未覆盖时继承全局设置。原生 GitVcsSettings/DataContext lifecycle 和完整设置自动化仍保持 partial。

---

## 1. 验收口径

本方案不以“拥有一个同名 Rust 方法”或“有一个 SwiftUI 按钮”为完成标准，而以以下四项同时成立为准：

1. 用户可以从正确的入口触发操作。
2. 操作的参数、默认值、确认流程和结果展示与 IntelliJ Git 一致。
3. 成功、失败、认证、取消、冲突和中断状态都有可恢复的交互。
4. Rust 集成测试、SwiftUI UI 测试和真实 Git fixture 测试全部通过。

### 1.1 优先级定义

- **P0**：不完成就不能宣称 Git 能力完整，或可能导致用户无法恢复、认证失败、结果错误。
- **P1**：核心 Git 工作流明显不等价，影响高频使用。
- **P2**：长尾功能、复杂仓库体验、交互细节和可维护性。

### 1.2 明确不在范围内

- IDE 代码补全、重构、构建、运行配置
- Git 之外的 VCS
- IntelliJ 插件平台和插件扩展机制
- 依赖完整代码模型的 Find Usages、重构感知历史
- IntelliJ Local History，除非后续产品决策将其纳入 Arbor

### 1.3 当前基线判断

当前实现已有较宽的 Git 原语覆盖，包括 status、staging、diff、log、branch、remote、stash、shelve、merge、rebase、reset、revert、cherry-pick、tag、submodule、worktree 和 hosting 集成。

但下列能力仍是硬缺口或仍需收口：

- Git HTTPS/SSH 认证与凭证交互（基础 broker 已完成，IntelliJ 高级 SSH 认证持久化仍在补齐）
- external diff/merge driver 的显式执行、`.gitattributes` 转换的大仓库级缓存和少数 CRLF 长尾
- 多 Git Root / 嵌套仓库的完整复合 action、可写联合 diff 与通知历史（Git Roots 已提供 root-qualified 的聚合 Changes Browser，并补齐单文件/逐 root Stage、Unstage、Stage All、Unstage All；原生 ChangesView/DiffManager lifecycle、统一 action history 与 UI automation 仍缺）
- merge/rebase/cherry-pick/revert 恢复状态机的完整 UI automation、通知生命周期和所有长尾 action
- Interactive Rebase 和 Staging Area 的少数复杂交互细节（矩阵仍保持 partial）
- root commit、merge commit 和 file history 的少数展示/筛选长尾

---

## 2. 目标架构

### 2.1 Rust 引擎分层

建议把当前 `Repository` 中直接散落的 system Git 调用逐步收敛到以下边界：

```text
GitRuntime
├── GitInstallation / GitVersion
├── GitCommandProcess
│   ├── stdout/stderr streaming
│   ├── cancellation
│   ├── progress events
│   ├── askpass / credential callbacks
│   └── structured exit result
├── GitRepositoryManager
│   ├── root discovery
│   ├── nested repository policy
│   └── multi-root operation coordination
├── GitConfig / GitAttributes
├── GitIndex / StagingModel
├── GitOperationState
│   ├── merge
│   ├── rebase
│   ├── cherry-pick
│   └── revert
└── GitHistory / GitDiff / GitBlame
```

### 2.2 SwiftUI 交互层

SwiftUI 不应直接根据某个按钮的本地状态猜测 Git 状态，而应订阅 Rust 返回的统一状态模型：

```text
RepositorySnapshot
├── repositories[]
├── workingTreeStatus
├── indexStatus
├── operationState
├── remotes
├── branches
└── capabilities
```

UI 至少需要以下统一入口：

- Git 主菜单和快捷键
- Quick Git Actions 搜索/键盘面板（参考 `GitQuickListContentProvider`）
- Branches Popup
- Changes / Staging Workspace
- Log / File History
- Conflict Resolution Workspace
- Stash / Shelf Workspace
- Operation Recovery Bar
- Remote Configuration Dialog
- Git Settings / Authentication Settings

---

## 3. 分阶段执行路线

## Phase 0：建立可验收的 IntelliJ 行为矩阵

目标：先把“完整复刻”从口号变成逐项可验收的清单。

### 工作项

- [x] 从 `plugins/git4idea/backend/resources/intellij.vcs.git.backend.xml` 提取所有 Git action、group、settings、tool window 和 extension（含 shared/frontend XML 与 src 领域补充）。
- [x] 从 `plugins/git4idea/backend/src` 按领域建立功能目录（矩阵按 category 归类：commands、config、remote、index、rebase、merge、conflicts、stash、history、branch、push_fetch、workingTrees、submodule、settings）。
- [x] 将每个 IntelliJ 能力映射为 `engine API`、`SwiftUI 入口`、`成功路径`、`失败路径`、`测试` 五列（docs/git-parity-matrix.csv）。
- [x] 对每一项标记：已完成、部分完成、缺失、暂不支持、需要产品决策（clone 递归真实测试、Git Settings 入口与 force-with-lease 默认设置已补；剩余状态以 `docs/git-parity-matrix.csv` 为准）。
- [x] 删除或修正 `PRODUCT_CHECKLIST.md` 中没有用户可达入口或没有测试证据的 `[x]`（per-file history、reorder、fixup、shelve、分支删除/重命名、submodule 操作改为部分完成）。

### 交付物

- [x] `docs/git-parity-matrix.csv`：机器可维护的逐项矩阵（180 数据行）。
- [x] `docs/git-parity-actions.md`：用户可见动作和快捷键清单（8 分组 + 快捷键对照）。
- [x] `docs/git-parity-decisions.md`：所有范围决策和兼容性决策（15 项）。

### 完成标准

- [x] 每个 IntelliJ Git action 都有 Arbor 映射或明确的 out-of-scope 标记。
- [x] 每个“已完成”项目至少关联一个测试和一个可达 UI 入口（矩阵按此规则判级，仅引擎无 UI 一律 partial）。
- 不允许只以源文件存在作为完成证据。

---

## Phase 1：P0 基础设施和正确性

这是第一阶段开发闸门。Phase 1 未完成前，不进入大规模 UI 补齐。

### ENG-001：统一 Git 进程执行层（P0）

当前问题：clone/push 等操作直接调用 `Command::output()`，没有统一的进度、取消、交互输入和结构化错误。

实施内容：

- [x] 新增 `GitCommandProcess`（src/gitprocess.rs），统一封装 system Git 调用（gix 路径保留结构化错误，失败分类共用）。
- [x] 支持 stdout/stderr 流式事件（`GitStreamEvent` 回调逐块投递）。
- [x] 支持取消（进程组 SIGKILL，git/ssh/askpass 一并清理）、超时与子进程清理；重试策略未实现（标注）。
- [x] 统一输出 `GitProcessOutcome`：exit code、stdout、stderr、耗时、cancelled/timed_out、failure kind。
- [x] 记录当前配置 Git executable 的版本、命令类别、耗时和失败类别；`redact()` 与 `url_arg()` 保证 token/密码不进日志与错误。
- [x] 对命令参数做结构化建模（`GitCommandSpec` builder）；clone/push_inner/push_refspec 已迁移，剩余 44 处 system-Git 调用已统一经过 `git_command()`，继续迁移到完整流式/取消执行层见 docs/git-command-call-sites.md。
- [x] 应用级 Git executable 设置（Browse/Test/Save/Reset、启动时恢复、候选路径 `git --version` 校验）已接入；所有 system-Git 调用不再硬编码可执行文件。

验收：

- [~] fetch、push、clone、pull、rebase 可显示进度并可取消（system-Git transport 已统一到 GitCommandProcess；`git_progress_state` 解析 `\r` 刷新的传输阶段和 native rebase 的 `Rebasing (n/m)`，由 `FeedbackCenter`/状态栏显示阶段与百分比，且保留 auth/cancel 入口；native structured/branch/root/non-interactive rebase 已接入同一 runner，gix Merge 与 object-level Rebase 仍是 indeterminate，重试策略、gix 阶段细分和专用进度面板仍未完成，详见 `docs/git-progress-transport.md`）。
- [~] 取消后 transport 不残留 Git 子进程；native rebase 若已建立 Git state 则保留可恢复的 operation state，未建立 state 的取消才清理 support 并直接返回 `Cancelled`（进程组清理测试验证孙进程消亡；rebase recovery 由 Continue/Skip/Abort 接管）。
- [~] 所有远程操作的错误都能区分认证失败、网络失败、冲突、非 fast-forward 和用户取消（system-Git transport 已统一复用 `classify_failure`；merge/rebase 领域路径仍由 gix 错误模型处理，Swift 细粒度错误面板与重试策略仍部分完成）。

### AUTH-001：HTTPS/SSH 认证与凭证管理（P0）

基线参考：`GitHandlerAuthenticationManager`、`GitHttpAuthService`、`GitHttpGuiAuthenticator`、`SSHConnectionSettings`。

实施内容：

- [x] 实现 HTTPS username/token 交互对话框（CredentialDialogView + CredentialAuthController）。
- [~] 实现 SSH passphrase/password 交互（同对话框模式）；Git SSH Settings 已提供 repository-scoped host-key policy（含 Ask）、known_hosts、identity file、auth method 与 local `credential.helper` 多值编辑，并真实编译到 Git transport 配置；Ask 模式已接入多行 host-key 指纹 prompt 的接受/拒绝交互；changed-host-key 已结构化分类并可从错误详情打开 SSH Settings；prompt 认证成功后已持久化 `user@host -> publickey/password` 并可查看/清除；新增只读 `SSH_AUTH_SOCK`/`ssh-add -l` agent 状态探测与 helper 可执行性说明，但区分 agent/helper 来源的真实成功观测及 SSH key/agent 管理仍待补齐。
- [x] 接入 macOS Keychain（KeychainStore.gitCredential/setGitCredential/deleteGitCredential；对话框保存开关=禁用保存）。
- [x] 实现 `GIT_ASKPASS`/`SSH_ASKPASS` 桥（askpass 脚本 + 文件通道 + uniffi 回调接口，src/auth.rs）；认证失败会按 IntelliJ 语义最多重建一次 askpass 会话，携带脱敏 `previous_error`、跳过旧 Keychain 值，且 host-key 拒绝不误重试。
- [x] 支持 credential helper 的检测、可用性诊断与仓库级多值编辑（`credential_helpers` 汇总 local/user 配置并标记缺失 helper；Git SSH Settings 可刷新、替换、清除 local `credential.helper`，全局配置保持只读）。
- [x] 对齐 IntelliJ 应用级 `Use Git credential helper` 开关（默认关闭）；关闭时 broker transport 注入 `git -c credential.helper=`，打开时保留 Git 自身 helper 链，设置变更实时同步到已打开的项目窗口。
- [x] clone/push/fetch/pull transport 已统一走 system Git；clone/push/fetch/pull 的 UI auth 入口使用 broker，无 broker 的 engine 入口使用已配置的 system credential helper/SSH；pull 的 merge/rebase 仍由 Arbor 引擎状态机执行。
- [x] hosting provider API token 与 Git remote credential 分离建模（KeychainStore 双命名空间：`github:...` vs `git:host:user`）。

验收场景：

- [~] 首次 clone 弹登录（对话框接线完成）；Keychain 静默命中路径已实现，端到端「保存后不再询问」待 UI 自动化验证。
- [x] 错误 token 能重新输入（git 401 重试 → handler 再次调用，attempt 递增），不会无限重试（mock HTTP 测试覆盖）。
- [~] SSH 私钥带 passphrase 时能够完成 fetch/push（passphrase 提示解析、SSH_ASKPASS 桥、取消分类全部完成并经测试；真实 sshd 传输依赖运行环境,标注为环境限制）。
- [x] 用户取消认证时操作状态为 cancelled（EngineError::Cancelled + GitFailureKind::Cancelled，测试覆盖）。
- [x] 凭证不会出现在日志、错误提示或测试快照中（脱敏 + 断言测试）。

### REPO-001：多 Git Root / 嵌套仓库模型（P0，若产品不限制单 Root）

实施内容：

- [x] 新增 `discover_git_roots`（src/roots.rs），扫描项目目录下的 Git roots（向上发现 + 有界向下扫描）。
- [x] 明确 nested repository 策略：独立 root 或 submodule（.gitmodules 登记），嵌套仓库不再被父仓库吞掉。
- [x] `GitRootInfo` 返回每个 root 的 HEAD/dirty/operation；`GitRootBranchSnapshot` 返回每个 root 的 local/remote/sync/recent/tag/stash 快照，Swift 侧 Branches Popup 按 root 消费。
- [x] update/fetch/push/pull/commit 支持多 root 调度和逐 root 结果（`run_multi_root_operation` 提供基础批量操作；`run_multi_root_update` 额外提供认证/取消、dirty stash/restore 与 configured upstream 更新）。
- [x] UI 能显示部分成功、部分失败和待处理 root（MultiRootPanel 聚合视图:状态徽标/跳过/失败原因/dirty/操作中标记,逐 root 结果列表）。
- [x] checkout 支持多 root 统一执行（普通/Smart/Force；Smart 先跨 root 保存 tracked/untracked 现场再逐 root 恢复；失败与恢复冲突按 root 返回；普通模式部分成功保留已成功 root，并提供 `Rollback Successful Roots` action 恢复此前 branch/detached HEAD、删除本次创建的本地 branch）。

验收：

- [x] 一个项目包含两个 Git root 时，状态、提交和 push 不会互相污染（测试覆盖）。
- [x] 一个 root 冲突时，其他 root 的结果仍可查看（逐 root dirty/operation 上报测试）。
- [x] nested repository 不会被父仓库错误扫描为普通文件（独立 root 上报测试）。

当前校正：Git Roots 的 `Commit All` 已改为显式 root 选择与提交信息对话框，不再以隐藏的 `WIP` 消息提交所有 root；引擎拒绝空消息/未知 root，按嵌套依赖顺序提交，并返回未选、干净、冲突 root 的逐 root skipped/failed 结果。多 root 对话框现已对齐单 root Commit workspace 的内置身份/冲突检查、项目 before-commit 命令、author/committer 覆盖、sign-off、co-author、amend、template/recent-message 与 skip-hooks 选项；自定义检查失败时可按失败 root 显式 `Commit Anyway` 重试；仍缺跨 root atomic transaction、非模态通知历史和 UI automation，继续标记为 partial。

如果产品决定严格限制“一窗口一个 Git root”，必须在产品文档和打开流程中显式阻止多 root，并将该项标记为正式范围决策。

### CFG-001：Git Config、Attributes 和 CRLF（P0）

实施内容：

- [x] 解析 repository、global、system 三层 Git config，并标注来源（`git config --list --show-origin --show-scope -z`）。
- [x] 支持 `git check-attr` 结果建模（text/eol/binary/diff/merge/filter/working-tree-encoding）。
- [x] 支持 `filter`、`diff`、`merge`、`text`、`eol`、`working-tree-encoding` 等影响文件行为的属性（check-attr 全量覆盖）。
- [~] 实现 CRLF 检测与和 diff/staging 一致的行为（`effective_line_endings` 合成入库/检出方向；内建 text/eol/autocrlf clean 已接入普通暂存、partial staging、restore/resolve-edited 与 tree materialization checkout；目标树中的 `.gitattributes` 会先于同批文件生效；checkout 会用目标 tree 的临时 index 预检不支持的转换，失败不修改真实 worktree；custom filter 与非 UTF-8 `working-tree-encoding` 默认按安全边界关闭，显式开启后通过临时 object store + system Git `hash-object`/`cat-file --filters` 执行，并受统一超时/进程组保护）。
- [x] 明确 custom diff driver 和 merge driver 的执行边界及安全策略（决策 16：默认不执行,只读属性展示;显式启用为 P2,见 parity-decisions）。
- [~] diff 已接入 attributes（binary 优先判定 + CRLF 设置）；Diff Attributes Inspector 已接入并展示 check-attr 与有效换行结果；普通/partial staging、restore、resolve-edited、revision/worktree diff 与三层 staging diff 现在共享内建 clean normalization，避免 CRLF 原始字节制造伪变更；tree materialization checkout 也共享内建 checkout conversion；显式开启外部转换后，diff/staging/checkout/resolve 通过同一 system-Git conversion path 处理 custom filter 与非 UTF-8 encoding；external diff/merge driver 仍按安全决策不执行，大仓库级转换缓存仍待补齐。

验收：

- [x] `.gitattributes` 改变 diff driver 后，Arbor 与命令行 Git 结果一致（check-attr 读取同一事实，测试覆盖）。
- [x] `core.autocrlf`、`text`、`eol` 场景下 diff 和暂存结果一致（引擎层有效行为合成 + 内建 clean normalization + 端到端入库验证）。
- [x] branch/tree checkout、restore 与 revision/worktree diff 在 CRLF 和目标 `.gitattributes` 同批变更场景下保持一致（测试覆盖目标属性先写入、checkout 行尾与 canonical diff matching）。
- [x] attributes 无法解析时有明确提示，不静默退化为错误结果（记录数不匹配即报错）。

### OPS-001：Git 操作状态和恢复状态机（P0）

需要统一识别：

- `MERGE_HEAD`
- `CHERRY_PICK_HEAD`
- `REVERT_HEAD`
- `rebase-merge`
- `rebase-apply`
- unresolved index entries

实施内容：

- [x] 新增 `GitOperationState`（src/opstate.rs）：kind/origin/backend/conflicts/onto/进度，识别真实 git 状态文件与引擎自管状态。
- [x] 实现 merge continue/abort（引擎自管状态 + 系统 MERGE_HEAD 双路径）。
- [x] 实现 rebase continue/abort/skip（引擎自管状态 + 系统 rebase 双路径）。
- [x] 实现 cherry-pick continue/abort（系统 CHERRY_PICK_HEAD 状态）。
- [x] 实现 revert continue/abort（系统 REVERT_HEAD 状态）。
- [x] UI 顶部显示持久化 Operation Recovery Bar（OperationRecoveryBar 订阅 `operation_state()`，两种 tab 均可见）。
- [x] 禁止在危险状态下显示会破坏当前操作的普通按钮（Commit / Commit and Push / Shelve 在操作进行中禁用）。
- [x] 操作状态变更后自动刷新 status、index、conflict 和 log（恢复动作成功后 refreshAll 重载 operation_state/status/log）。

验收：

- [x] 每种中断状态都能通过 UI 完成、跳过或中止（Recovery Bar：merge/rebase/cherry-pick/revert 的 continue/skip/abort 全部接线）。
- [x] 应用重启后仍能恢复正确状态（重开仓库后检测 + abort 测试通过）。
- [x] 任何恢复动作失败时，用户仍可继续选择其他恢复动作（失败保留状态文件，测试覆盖）。

### Phase 1 闸门

- [x] 认证、取消和失败路径全部有 Rust 测试（askpass mock 全流程 + Cancelled 分类 + 失败分类断言）。
- [x] 真实临时 Git 仓库覆盖 merge/rebase/cherry-pick/revert 的中断恢复（tests/opstate.rs 11 个 + golden_scenarios）。
- [~] P0 场景通过引擎行为测试（254 个,含 P0 全部场景）;XCUITest 自动化未建立（环境限制,见测试方案 5.2）。
- [x] P0 未完成前，不得宣称“Git 工作流完整”（P0 引擎能力全部完成并经测试,此警示条目解除）。

---

## Phase 2：Staging、Conflict 和 Interactive Rebase

本轮外部 operation-state 对齐补充：恢复通知现在按 Git root 维护状态 fingerprint，主 root、嵌套 root 和外部 Git metadata refresh 都能发布 Continue/Skip/Abort/Open Recovery；同一状态不会重复通知，冲突文件或 rebase 步骤变化会替换原通知，操作结束会清理该 root 的去重状态。当前对齐状态与真实剩余差异见下方 2026-08-20 纠偏记录。

2026-08-20 纠偏：逐文件 dirty ledger 已接入 pending/in-progress/processed refresh 生命周期；非递归 rename parent、watcher `oldPath` 保留和嵌套 root dirty 传播已有回归测试。FeedbackCenter 已实现 tool-window/standard/important/silent 四类 VcsNotifier presentation group、stable display ID replacement/expire；operation recovery 使用 important group。未配对 rename 现在先做完整 status reconciliation，Git 能提供唯一 `oldPath` 时走 Add+Remove；FSEvents 没有 old endpoint 时，Git clean-filter 后的唯一 blob identity 也可在新旧候选间提供足够证据执行 Add+Remove。重复内容、修改内容、查询失败或无法唯一配对时只保守 Add 新端点并保留全量 refresh。当前仍缺相同内容无关来源时更强的 VFS provenance、业务通知逐一迁移到精确 IntelliJ display-id 常量，以及原生 permission prompt/banner 的精确 UI automation。

本轮 VFS action 执行层进一步对齐：case-only rename 现在直接执行 `git mv -f -- old new`，保留 IntelliJ `GitVFSListener.executeForceMove` 的 worktree + index move 语义；普通 create/delete 与可靠 rename 的状态过滤和安全刷新边界不变。

### IDX-001：完整 Index / Staging Workspace（P1）

实施内容：

- [x] 建立 `HEAD`、index、worktree 三层明确数据模型（src/stagingmodel.rs：StagingModel/StagingEntry，层级状态 + 标志位）；StagingEntry 额外输出 `head_present`、`staged_present`、`local_present`，Changes Browser 按事实数据启用版本动作。
- [x] 支持 local ↔ staged、staged ↔ HEAD、local ↔ HEAD 三类比较（DiffMode::WorktreeToHead 新增 + staging_diff 单文件三层）；Changes Browser 的 Local with Staged / Staged with Local / Staged with HEAD 入口保留参考实现的左右方向，Local → Staged 使用只读反向数据源。
- [x] 支持 stage/unstage 单文件（已有）、全部文件（stage_all/unstage_all 新增）、选中行/选中 hunk（stage_lines/unstage_lines 已有）；逐行选择同时支持 old/new 两侧，纯插入也可操作；普通 staging diff preview 可直接进入当前 Unstaged/Staged 维度的逐行 Stage/Unstage，并在 hunk header 执行 Stage Hunk / Unstage Hunk；未暂存维度还支持只恢复 worktree 相对 index 的 Rollback Hunk，并返回普通预览。
- [~] 二进制与 submodule 在模型层标记并在 UI 降级展示（BIN 徽标 + 二进制 diff 空 hunks）；rename/copy 现在保留 status 的 `oldPath`（对应 IntelliJ `GitFileStatus.origPath`）并在 Changes 行展示来源；无法获得权威旧路径的 VFS rename 仍不猜测旧端点。
- [x] 为 index 变化建立 tracker（IndexRevision mtime+size + index_changed_since，外部 git add 检测测试通过）。
- [x] 对 ignored、untracked、assume-unchanged、skip-worktree、intent-to-add 提供明确状态（模型 flags + index 扫描，测试覆盖）。
- [x] 增加“Add to Git / Ignore / Exclude”入口（add_to_gitignore / exclude_path + Changes 行右键菜单）。

验收：

- [x] 任意暂存组合提交后的 tree 与命令行 Git 一致（既有 staging 测试 + stage_all/unstage_all roundtrip 测试）。
- [x] 行级暂存不会丢失换行、编码或未选中内容（既有 tests/staging.rs 回归保持全绿）。
- [~] 外部变更同步已覆盖每个发现 Git root 的递归 FSEvents、真实 Git 管理目录（含 linked worktree）监听；linked worktree 会同时监听 worktree-specific Git directory 与 `commondir` 指向的 common Git directory，并保留 750ms `IndexRevision` 轮询作为 `index.lock -> index` 原子替换兜底；事件经 350ms 去抖后携带 root-qualified 规范化、去重路径，ContentView 再按 root 合并 scope/path/rename origin 后统一消费，`created + modified` 保留新建语义；纯 worktree 文件批次优先通过 Git pathspec 做 status 增量合并，祖先覆盖路径会按 RootDirtySet 语义压缩，30 项目录提升为递归目录，目录/根路径/删除竞态回退全量；watcher 通过唯一设备号+inode 配对可靠 rename 的旧/新端点，双端进入 status pathspec 与 dirty scope，无法唯一配对时回退全量；同一 status 快照现在直接投影 Changes Browser Changelist，避免增量事件再次触发全仓库 status；重叠刷新由 `RepositoryRefreshGate` 将后续增量请求升级为全量，并只允许最新 ticket 发布 status、metadata 和错误；递归父事件会传播到嵌套 root，root-scoped dirty-scope manager 补齐逐文件 pending/in-progress/processed ledger、pack、belongsTo 与项目切换清理；主 root 刷新 Commit 状态，非主 root 刷新 Roots/Branches/冲突/聚合 Log 快照；新增/删除/可靠 rename 已接入 GitVFSListener 的 Add/Remove 策略及真实状态过滤；身份缺失的 arbitrary-basename 文件 rename 现在会用唯一 Git clean-filtered blob identity 做一对一 Add+Remove，重复/修改/失败/不安全或无法唯一配对时仍只对 basename 候选提供显式 review，无法证明时不自动 Remove 旧端点。当前剩余是原生 VFS permission/banner、完整 action history、modified-rename similarity/provenance 和业务通知精确 IntelliJ display-id 长尾。
- [~] 对照 `GitVFSListener` 的外部 create/delete/move 语义：新增/删除已按独立 Add/Remove 设置自动确认或静默执行，固定 staging area 的新增使用空 blob index 以保留 `AM` 双侧语义，删除使用 `git rm --cached --ignore-unmatch -r`，目录事件会展开到 status 子路径；可靠 rename 会路由新旧两端，case-only move 执行与 IntelliJ 一致的 `git mv -f -- old new`；结构化 dirty-scope 已区分精确文件、递归目录、rename 父目录和全量回退，并接入逐文件 ledger、祖先压缩、30 项目录提升与嵌套 root 传播；无法唯一配对 rename 时先做完整 status reconciliation，Git 提供唯一 oldPath 或 filesystem identity 时才自动 Add+Remove；身份缺失但 basename 有候选时进入 one-to-one review，否则只保守 Add 新端点并保留全量 refresh。
- [~] 对照 `MatchPatchPaths` 的 `FilenameIndex` 候选边界：当前物理递归扫描 + Git index 合并已覆盖常见 tracked/untracked/package descendants，但仍缺 project content/excluded scope 与 Shelf-resources 过滤；禁止用猜测性的目录黑名单代替真实 scope 模型。

### CONFLICT-001：冲突工作台（P1）

实施内容：

- [x] 将冲突列表、四方 diff、操作状态和恢复命令统一到一个工作台（conflict_workspace()：操作类别 + 冲突文件列表 + 三方内容/块/二进制标记；UI 复用 MergeRevisionsDialog 统一入口）。
- [x] 支持 base/local/result/remote 的同步滚动和块级操作（ConflictFile 四方内容 + ConflictDetailView 编辑器 + 逐块 accept）。
- [x] 支持 accept ours/theirs/both（accept_conflict 文件级，二进制安全）、manual edit + mark resolved（resolve_edited）、reset（reset_conflict 从 stages 重建 marker）。
- [x] 增加 binary conflict 的明确提示（workspace 二进制标记 + 空 blocks + reset 明确报错；accept 走 raw bytes 路径）。
- [x] 支持从 merge、rebase、cherry-pick、revert 进入同一工作台（operation 来自 opstate；对话框按 kind 切换模式）。
- [x] 外部 merge tool 路径：冲突文件可调用 Git 配置的 `merge.tool` / `merge.guitool`，运行 `git mergetool --no-prompt` 后重新读取 index stages 与剩余冲突；未配置、工具失败和非冲突路径均返回明确错误；冲突文件可直接编辑仓库级 mergetool 选择，运行中的 Git/mergetool 可取消并清理进程组；非模态 toolwindow 仍是交互长尾。

验收：

- [x] 解决一个文件后立即从冲突列表移除并刷新 index 状态（accept/resolve 后 workspace 列表即不含该文件，测试覆盖）。
- [x] 解决全部文件后展示对应的 continue 操作（对话框 primary 按钮在 conflictPaths 为空时启用，按操作 kind 路由）。
- [x] 应用重启后仍能恢复冲突现场（重开仓库后 workspace/accept 测试覆盖；reset 可从 stages 重建现场）。

### REBASE-001：Interactive Rebase 完整交互（P1）

实施内容：

- [x] rebase todo 使用显式模型（RebaseTodo/RebaseTodoItem，src/rebasetodo.rs），顺序与 action 是执行权威（rebase_with_todo 按 todo 顺序重放）。
- [x] 支持拖拽排序（标准 structured single-root 表现为真实 row drag/drop，落点按 commit identity 重排；上下移按钮和测试验证拓扑跟随 todo 顺序仍保留）；单 root 与 multi-root 的多选移动按 commit identity 逐行上/下移并恢复 selection，批量选择与批量 action（RebaseTodoEditorView 多选 + Apply to Selected）保持 IntelliJ entry 语义；Squash/Fixup 批量操作按 IntelliJ `unite` 语义将非连续选择重排为一个 group（单选时吸附到前一个 kept root）；单 root 与 multi-root 编辑器提供按打开时 snapshot 恢复原始 todo 的 Reset，multi-root 按 root 独立保存和恢复 action/order/message；两种编辑器均提供与 IntelliJ `GitRebaseCommitsTableModel` 对齐的 10 状态 Undo/Redo，连续编辑同一提交信息会合并为一次历史操作。
- [x] action 完整支持 pick、reword（可带新 message）、edit（暂停 amend）、squash、fixup、drop（batch 测试覆盖全集合）。
- [x] 对齐 IntelliJ 修改后取消语义：structured single-root、multi-root 与 native todo 在 todo 有改动时弹出 Discard Changes 确认；未修改时直接取消，保留 Keep Editing/Discard Changes 两个明确选择。
- [x] structured single-root RebaseTodoEditorView 增加 IntelliJ 风格的详情分栏：多选 todo 行驱动按 revision 直接加载 CommitInfo，并在只读面板展示提交元数据、变更列表和 diff；详情面板隐藏 Log mutation actions。multi-root 编辑器也提供 root-qualified 的详情分栏：每个 root 独立加载 Repository，选中 root 的单选/多选 commit 按该 root 的 todo 顺序展示，跨 root 同 ID 不会串库。
- [x] native todo fallback 增加实时结构化预览：commit rows 与 `label/reset/merge/exec/break/update-ref` control rows 分色展示，未知或格式不完整的行只给出非阻断诊断；raw text 仍是编辑权威，Git 仍是执行和最终语法校验权威。
- [~] native todo control-row 增加结构化编辑：`label/reset/merge/exec/break/update-ref` 可从预览直接更新参数、转换命令类型并按原始行上下移动，保留其它行、注释、未知语法和 CRLF/LF 换行；`break` 转换会清空不适用参数，Git 仍负责最终语法/拓扑校验。对照 fork `GitRebaseTodoModel.Type.NonUnite.UpdateRef` 后，preserve-merges structured/multi-root 的 reordered pick 现在会带着连续 `update-ref` block 一起进入 native sequence editor，避免引用落到错误提交；但 `UPDATE_REF` 尚未成为 structured editor 的可见非提交 row，原生 popup/editor lifecycle、跨 root 通知分组和 UI automation 仍缺。
- [x] 补齐 `GitRebaseCommandsDialog` 对等入口与 todo 行上下文操作：single-root 与 multi-root structured todo editor 均提供只读 `Commands…` 窗口，按当前 root 的 todo 顺序展示 Git action command、commit hash 和 subject；每个适用的 todo 行提供 Pick/Reword/Edit/Squash/Fixup/Drop 与 Commands… 的 context menu，merge topology 行只暴露 Pick/Reword，保留当前多选的 IntelliJ 语义；帮助窗口不修改主编辑器的 selection/history/execution 状态。preserve-merges 下仅开放同一 branch segment 的连续 Squash/Fixup，跨 topology 边界 fail-closed。
- [x] 支持 autosquash 预览（rebase_todo(auto_squash) 生成时吸附 fixup!/squash! 到目标后，squash 在前；编辑器可手工修正）。
- [~] 支持从 Log 选中提交后发起（单父提交使用选中提交的 parent 作为排除基点；多选 Drop 已按 IntelliJ 直接确认语义执行显式 drop todo，并沿用 protected branch、local-scene 保存/恢复与 expected-HEAD Undo；Squash/Reword 仍进入 todo/editor；root 现在进入真正的 `git rebase -i --root` todo，支持 root 行的 action、重排与 reword；通用 Rebase dialog 的 root 模式允许省略 onto，并可选传递 `--onto` 新基址；HEAD merge 允许仅改消息并保留双父；preserve-merges 的 merge root 现在也可通过 `merge -c <commit>` 改消息；同一 branch segment 内的连续 squash/fixup 已开放，前驱被 drop 时 UI 会自动恢复依赖行为且 Rust fail-closed，跨 label/reset/merge 边界的组合由后端拒绝；HEAD/Root Reword 成功后现有通知提供 protected-remote 与 expected-HEAD/branch 守卫的 ref-only Undo，并保留 staged/local scene；完整控制行编辑、跨 root 原子通知/撤销与 UI automation 仍缺）。
- [x] 支持 preserve-merges 的真实 Git 场景（rebase_with_todo preserve 走系统 --rebase-merges；测试含 merge 提交历史、真实 side-branch 的 drop/reword 映射、squash/fixup/edit，以及 dirty local scene 的保存与 abort 恢复）。
- [~] 对齐 IntelliJ Rebase Dialog：`--root`、`--keep-empty`、`--update-refs` 已通过受控原生 rebase 接入并由 SwiftUI 参数链覆盖；对话框已提供可选 interactive 开关，非交互模式直接走 Git 原生命令并保留 `--rebase-merges`/`--keep-empty`/`--update-refs`/`--autosquash` 语义，交互模式仍走 todo 编辑器；branch/repository selector 已接入真实分支范围与 positional branch 执行；无提交可编辑时 single-root 与 multi-root 现在对齐 IntelliJ `confirmNoopRebase()`，先给出明确 Continue/Cancel 确认而不是直接禁用 Start；多 root 已按依赖顺序在统一窗口编辑每 root 独立 todo，或在非交互模式逐 root 执行原生命令，并覆盖暂停/失败/未尝试结果；跨 root 持久化 resume spec、重启 Resume/Retry、Continue/Skip/Abort 和 expected-HEAD 保护回滚已接入；单 root 已提供受保护的 Undo、干净失败 Retry、tracked-only continue 失败后的 Stage-and-Retry；跨 root Continue 因 tracked-only dirty 失败时现在提供带 root/session scope 的 Codable Stage-and-Retry action，写入稳定 multi-root rebase notification ID 并可从 Operation Log/重启后恢复；完整通知分组和更广的通知历史语义仍缺。
- [x] 补齐 Rebase 主对话框 `--onto` 上下文帮助：可聚焦帮助按钮打开可取消 popover，显示分支关系示意并提供 Git 官方 rebase 文档链接；URL 与入口行为有 Swift 专测。参考实现为 `GitRebaseDialog.createOntoHelpButton()` + `GitRebaseHelpPopupPanel`。
- [x] Rebase 对话框范围由引擎统一提供：默认模式复用 first-parent action range，preserve-merges 模式使用完整拓扑中的非 merge actions；onto 或 preserve-merges 改变会使已加载范围失效，generation 校验会丢弃过期异步结果，避免 UI 从普通 Log 推导出错误 todo（`rebase_range` + `tests/rebase_merges.rs`）。
- [x] 对 todo 生成、autosquash 预览、重排、批量 action、校验、冲突暂停 + continue/skip/abort、真实 merge graph action 映射与 dirty local restore 增加回归测试（tests/rebase_todo.rs / tests/rebase_merges.rs）。

验收：

- [x] UI 排序结果与最终 commit 拓扑一致（重排测试断言 log 顺序 == todo 顺序）。
- [x] fixup 不打开多余 message 编辑（fixup 测试断言最终 message 保持目标）；squash 正确合并 message（batch 测试断言 squash 并入 reworded 提交）。
- [~] rebase 中断后可从 Recovery Bar（OPS-001）与 Merge Revisions 冲突工作台恢复；Log/Changes 入口待 UI-001 收口。

---

## Phase 3：Remote、Stash/Shelve 和 Branch 交互

### REMOTE-001：Remote 配置与高级传输（P1）

实施内容：

- [x] 实现 Configure Remotes Dialog（RemoteConfigDialogView：远程列表 + URL/push URL/refspec 编辑 + 添加/删除/重命名；Push 对话框入口）。
- [x] 支持 remote URL、push URL、fetch refspec、push refspec 的编辑（remote_set_url/set_push_url/set_refspecs，RemoteInfo 全量字段）。
- [x] 支持 fetch all（逐 remote 结果）、prune（fetch_prune）、unshallow（fetch_unshallow）；remote HEAD 沿用 remote_branch_list。
- [x] force-with-lease（push_force_with_lease，默认偏好已与 IntelliJ registry 对齐并可在 Git Settings 配置，拒绝时分类 NonFastForward）、自定义 refspec（push_refspec 已有）；标准 Push 对话框与项目级 Push All 均补齐 IntelliJ 的 Push tags（All / Current Branch，对应 `--tags` / `--follow-tags`）与 Run git hooks（`--no-verify`）选项，认证/取消/force-with-lease/custom refspec 路径均保留；Push All 的失败重试与 Merge/Rebase recovery 会继续携带同一 options。
- [x] GitHub protected-branch discovery：Fetch 成功后通过 GraphQL 分页读取规则，按 IntelliJ PatternUtil mask 语义转换为正则，与本地保护规则合并；远端规则按项目缓存，API 失败保留最后已知保护。
- [x] rejected push 后提供 update with merge/rebase（offerPushRecovery 已有，错误分类 + 上下文保留；本次补齐 stale info 分类）。
- [x] 指定远程分支 Fetch：单 root 与多 root 均通过显式 `refs/heads/<branch>:refs/remotes/<remote>/<branch>` branch-specific refspec 只更新选中 remote-tracking ref；支持 `main`、`origin/main` 与 `refs/heads/main` 输入，认证/取消路径复用统一 Git process。
- [x] 项目级 `GitFetchTagsMode`：设置提供 Git default / Fetch and prune tags / Fetch all tags / Do not fetch tags，并贯穿显式 Fetch、Fetch All、指定 remote branch、Pull、Checkout and Update、显式 prune/unshallow、自动 Fetch，以及 Push rejected 后的 Merge/Rebase recovery；兼容旧 Rust API 保持 Git default。
- [~] 对齐 internal `Git.AddCommitToRemoteBranch`：日志单/多选提交后先 fetch 目标 remote branch，在 Rust 对象层顺序 replay 并跳过已存在变更；不移动当前 HEAD/工作区，生成 detached tip 后复用认证、lease 和 protected-branch guard 的 Push 对话框；Log action 现在在 update 阶段禁用跨 root/merge commit 选择，成功、无变更和失败反馈使用 root-scoped stable notification ID；仍缺更完整的跨 root 统一通知编排与 SwiftUI UI automation。
- [~] 统一认证（AUTH-001 broker 已接 clone/push/fetch/pull；显式操作使用 Interactive，Auto Fetch/LS_REMOTE 已按 remote 对齐 NONE → SILENT 的后台认证选择；Git SSH Settings 可管理 local credential helper，并可做只读 SSH agent 状态探测）；进度/取消事件通道与重试策略未接（ENG-001 部分完成项），agent/helper 来源级成功观测仍不可见。

验收：

- [x] 修改 remote 配置后立即反映在 Push Dialog（保存后 loadRemotes 刷新）；Branches Popup 共用同一 remotes 状态。
- [x] force push 默认使用 force-with-lease；force 与 force-with-lease 仍是独立 API，设置和 Push 对话框均可显式关闭 lease，fixture 测试验证 lease 拒绝远程更新。
- [x] 多 remote、多 push URL 和 tracking branch 场景有测试（fetch_all 双 remote、pushurl 读写、push rejected 分类）。
- [x] multi-root Merge 对话框按 Git root 独立读取已合并分支；已合并 root 禁用且不进入默认全选，关闭/重开会丢弃旧异步结果，执行入口再次过滤已知 no-op root。

### STASH-001：Stash / Shelve Workspace（P1）

实施内容：

- [x] Recently Deleted 的 raw patch 成员列表与 path-scoped 永久删除只解析 UTF-8 header/path，按字节边界裁剪 selected member，未选中的非 UTF-8 payload 原样保留；非法 header/path 或无法建立成员边界时 fail-closed 且不部分写入。raw apply、结构化预览、binary provider 与原生 delete-provider lifecycle 仍按各自边界保留。

- [x] `MatchPatchPaths.workWithNotExisting` 长尾已对齐：新增文件的末端目录不存在时，从已索引的中间目录/文件反向匹配推导 repository base 与 `-pN`，并与多文件候选交集、上下文排序共用候选模型。
- [~] Shelve 按钮已接入真实 shelve 对话框；Shelf patch Preview 已接入 Saved Patches 工作区并支持按文件的结构化 FileDiff 与 side-by-side/unified 切换，Shelf Rename 已接入并保持自有 ref 与列表文件一致；Shelf 列表现在保留 `ShelvedChangeList -> ShelvedChange` 两层成员模型并持久化顶层展开/目录分组状态，成员行支持 Cmd 多选、只应用或删除选中成员，Shelf 成员排序按 IntelliJ 文件名优先 comparator 对齐，删除 shelf 或删除最后成员会进入可恢复的 Recently Deleted，支持 Restore/Delete Permanently；Recently Deleted 文件成员也支持 path-scoped `Delete Permanently`，未选 patch chunks 保留，最后成员才清理 deleted Shelf；失败可跨重启 Retry；Shelf 元数据已持久化 description、生命周期更新时间、`recycled`/`toDelete`/`deleted` 三态和 Recently Deleted 状态，整组/部分 Unshelve 支持持久化 `Remove Applied Files from Shelf` 策略：默认保留并回收，开启后将已应用成员移入 Recently Deleted，冲突完成沿用该策略；工作区 Unshelve 与明确 Pop 分开，Pop 只在成功完成后消费 shelf；重启读取会收敛 pending delete，UI 默认隐藏 recycled 并提供显示开关，读取回收区时按 7 天规则自动过期；Import Patches… / Export Patch… 已接入，导入以独立 raw patch 文件持久化，脱离当前 HEAD，Unshelve 时才做 three-way/clean apply 并支持持久化冲突回滚；Changes tree -> Shelf 与 Shelf -> Changes 整组拖拽均已接线；`.git/arbor-changelists` 已接入 local Changelist 创建/激活/重命名/删除回 Default、成员移动与列表拖拽，静默 Shelf 拖拽按源 Changelist 分拆，Shelf 成员支持跨列表移动；仍缺系统自动回收触发、完整回收 action model 与更细恢复/撤销/通知语义（DIFF-001/IDX-001）。
- [~] Uncommit 已补齐目标 Changelist 选择：执行前展示 HEAD 与变更数量，支持已有或 inline 新建列表；subject suggested name、自动创建设置和非法名称校验已接入；soft reset 后按提交树差异把路径（含 rename 的旧/新两端）归入所选列表，恢复原提交信息并与 Changes Browser 刷新联动；aggregate Log 会按选中提交路由到所属 Git root；root HEAD 已在 action-update 阶段禁用；detached HEAD 通过直接更新 HEAD 支持，已发布到 protected remote branch 的提交在 chooser 前阻断，并以 expected HEAD CAS 防止过期对话框误操作；仍缺 chooser 的完整键盘焦点/help 生命周期和更细通知/撤销语义。
- [x] 建立统一 Stash Content Provider（stash_list/walk_stash_chain 单一数据源；外部 git stash 后列表同步测试）。
- [x] 支持 stash save/apply/pop/drop/clear/show diff/branch（unstash-as = stash_branch，测试覆盖）。
- [x] 支持 tracked/untracked/ignored 选项（stash_save_with_options；对话框三选项，ignored 隐含 untracked）。
- [~] 列表刷新（refreshAll + 外部同步测试）、预览（stash/shelf 均支持按文件结构化 side-by-side/unified 与 patch fallback）、恢复失败与冲突恢复（StashApplyConflict + 保留 stash + UI finishStashPopConflict 流程）。

验收：

- [x] stash 后工作区/index/untracked/ignored 状态与 Git 一致（save 重置 + 选项测试）。
- [x] apply 冲突进入冲突流程且 stash 保留（HEAD 前进后 apply 冲突测试）；pop/unstash-as 复用同一 merge 路径。
- [x] 所有入口（Branches Popover Stashes 区、对话框）共用 stashes 状态；外部修改后 refreshAll 同步。

### BRANCH-001：Branches Popup 和 Working Trees（P1/P2）

实施内容：

- [x] 完善 local、remote、tag、recent 分组（Popover 新增 RECENT/TAGS 区；incoming/outgoing 徽标沿用 sync_status 的 ahead/behind）。
- [x] Branches Popup TAGS 区支持单个 Push Tag 与 Push All Tags；单 tag 也通过 credential broker、取消句柄和结构化 PushRejected 路径执行，Push All Tags 按 root 使用非 force wildcard refspec，认证/取消和远端拒绝均有结构化反馈。
- [x] Merge 对话框按 IntelliJ `GitMergeDialog.validateBranchField()` 校验本地与 remote-tracking 源 branch 是否已经合并进当前 HEAD；已合并 refs 在 UI 中提示并禁用 Merge，执行前再次读取 `branch_list_merged_all()` 防止对话框打开后的 HEAD 变化造成 stale no-op；任意 commit/revision 仍可输入，cleanup 继续使用仅本地的 `branch_list_merged()`。
- [~] 补齐 checkout with update、checkout with rebase（分支菜单新增；Update 在 checkout 后按 selected branch 的 upstream 同步，Rebase 按 IntelliJ 语义将 selected branch rebase 到当前分支）；compare/merge/rebase/pull/push 已有；Merge/Merge into Current 在干净完成或冲突解决后对非保护本地源分支按 Git Settings 的 DELETE/PROPOSE/NOTHING 处理，PROPOSE 的多 root action 在执行前统一一次确认并重新解析仍有效的非当前本地分支，NOTHING 成功后不额外暴露 IntelliJ 没有的回滚 action；同名本地分支的多 root Merge 已按 IntelliJ 顺序执行，单 root/multi-root Modify options popup 的策略与选项贯穿每个 root，冲突继续后续 root、致命失败停止，并提供成功 root 回滚/保留部分结果；多 root 复合入口已按 IntelliJ 顺序只更新成功切换的 root，并支持 selected root/all roots；多 root Branches Popup 的非当前本地分支已单独走 `rebase_branch_on_current`；完整 VcsNotifier/DataContext/action history 生命周期和 UI automation 仍待补齐。
- [x] 对齐 `GitVcsSettings.rootSync` / `DvcsSyncSettings`：Project Git Settings 按标准化 project path 持久化 `NOT_DECIDED`、`SYNC`、`DONT_SYNC` 三态；Multi-root Branches Popup 的 Settings 菜单可切换跨 root action scope，`SYNC`/`NOT_DECIDED` 显示同名 branch/tag/remote 的跨 root 快捷动作，`DONT_SYNC` 隐藏快捷聚合但保留显式 root-qualified 多选。原生首次同步提示、完整 affected-repository DataContext 路由和 UI automation 仍为 partial。
- [~] 补齐 checkout Smart/Force/Cancel（本地/Recent/远程建分支/tag/detached 均统一受影响路径、按 IntelliJ `GitSaveChangesPolicy` 选择 Shelve/Stash、恢复冲突进入工作台、失败回滚）；单 root Checkout and Update、Checkout with Rebase、Pull 和 Rebase 已复用该策略与持久化 Shelf 恢复；Smart Checkout 的 Stash preserving 已按本次保存返回的 object ID + `--index` 恢复，单 root 与多 root 不再依赖 `stash@{0}`；stash/Shelf 恢复冲突现在提供携带 project/root 与精确 saved-artifact identity 的 `View saved changes…` semantic action，root-scoped revision checkout 与多 root Checkout/Checkout and Update 也不会回退到当前 Repository；Checkout and Update 的 normal checkout 阶段已有补偿回滚，普通多 root checkout 部分成功则按 IntelliJ 保留已成功 root，并提供 `Rollback Successful Roots` action，Force 保留显式破坏性语义；多 root roots 引擎的临时 Update stash 可从 Git stash 栈重建 reopen recovery，update 按 IntelliJ 的逐 root partial-result 语义保留已完成 root，跨 root Shelve/provider 细节仍待收口。
- [~] 支持 branch/tag rename/delete（已有）+ tracking branch 设置（branch_set_upstream/unset_upstream 新增，fixture 测试）；未合并分支强删前显示真实提交列表，正常/强制删除后均可恢复精确 tip/upstream；本地分支删除后按唯一 live tracker、tracking ref 存在和保护规则提供 Delete Tracked Remote action，单 root 与 multi-root 都保留本地 Restore 上下文并汇总远端 partial failure；local tag 删除保存完整 peeled target，并可从单 root 或多 root recovery action 按 remote 使用 lease-protected 删除；已补 IntelliJ 多 root branch/tag rename/delete 的 repository picker、取消 upstream 选项、逐 root force-delete、Restore All 与部分成功 rollback；远程分支多 root 删除已补共同 tracking branch 选项，并按 IntelliJ 顺序在所有远程删除成功后才清理 tracking；单 root 与 multi-root 已补 Remote Tags 直接列表、认证、root-qualified 选择、partial-result 汇总、列表 object-id lease 校验，以及列表/删除过程取消和取消后停止剩余批处理；剩余是完整非模态通知历史和 UI automation 细节。
- [~] 对齐 `FindMergedLocalBranchesAction`：Branches Popup、Log 分支面板和多 root Popup 均可打开独立查找 sheet；按目标分支/名称前缀只读计算，结果按 Git root 分组并可复制；改动输入会使旧结果失效。独立纯文本报告保留 root 级错误、扫描统计和耗时，并通过稳定 standard notification 提供可持久化的 `Open Report` semantic action，跨重启可恢复报告。仍与 IntelliJ 原生文本编辑器、通知折叠/历史和 UI automation 有差异。
- [x] 对齐 IntelliJ `GitCheckoutFromInputAction`：Branches Popup 支持输入 branch、tag、remote branch 或 commit/revision；单 root 按引用类型复用 checkout 恢复状态机，多 root 复用聚合 Smart/Force/Cancel checkout。
- [x] worktree list/open/remove/lock/unlock/prune UI 已有（WorktreePanel 全接线，引擎 API + 测试已有）。
- [x] 对齐 IntelliJ `GitOpenExistingWorkingTreeForLocalBranchAction`：单 root 与多 root Branches Popup 对被其他 linked worktree 占用的本地分支显示 `Open Worktree…`，按 branch 精确定位并以新项目窗口打开。
- [~] 多 root 分支聚合数据源已测试（各 root 分支及 recent/tag/stash 不互相污染）；Branches Popup 已按 root 分组、支持独立 repository picker/flat filter、root 定向 checkout、非当前本地分支 Update/Pull/Pull with Rebase、root-scoped Push dialog、Recent/Tags/Stashes 基础动作、local/remote Compare/Merge/Fetch/Pull/Checkout/Delete、per-root remote config、Checkout and Update/Rebase 与 recovery；普通 checkout 部分成功保留已成功 root，并可用 `Rollback Successful Roots` 恢复此前 HEAD；Git Roots 面板已汇总 checkout 与 update/fetch/push/pull/commit 结果，并已接入项目级 resolver queue，统一 operation/unmerged/stash 冲突与 Continue/Skip/Abort；临时 Update stash 已支持从 Git stash 栈重建 reopen recovery，update 已对齐参考实现的逐 root partial result，Update Project 失败时对实际前进的成功 roots 提供 deepest-first、expected-HEAD guarded 的 `Rollback Updated Roots`，并对父 gitlink 忽略已独立处理的嵌套 root；Git Roots 现在可打开按 root 分组的 Changes Browser，详情 diff 与 Stage/Unstage/Stage All/Unstage All 固定路由到所属 Repository，并以 root-qualified identity 隔离同名路径；跨 root atomic transaction、更广的 action history、原生 ChangesView lifecycle 和 UI automation 仍缺，冲突文件的外部 merge tool 已在 root workbench 可用。

- [x] 对齐 Update Project 通知尾部：成功/partial 使用 project-scoped stable display ID 与 `standard` VcsNotifier group；更新前后 HEAD 只为实际推进且成功的 root 生成 root-qualified `PersistedLogRevisionRange`，通知提供可跨重启恢复的 `View Commits` semantic action，并路由到单 root 或聚合 Log；失败 root Retry 继续保留精确 root scope；submodule 失败组会把父失败、子模块失败及级联 skipped 合并展示，Retry 闭包同时覆盖父链与 submodule 后代。
- [x] 对齐 `GitUpdateInfoAsLog.findOrCreateLogUi()` 的 View Commits tab 语义：保存当前 Log context，按 root-qualified before/after ranges 复用同范围 `Update Info` tab 或创建独立 tab；普通 Log 不再被覆盖，multi-root aggregate filters 随 tab 保存并兼容旧 external Log tab 状态。
- [x] 对齐 `GitVcsPanel.updateProjectInfoFilter()` 的 Update Info path filter 语义：Project Git Settings 按 project path 保存 root-qualified 路径选择；新建或编辑 Update Info tab 时应用并回写该设置，空值显示所有更新路径，ordinary Log filter 不受影响。
- [x] 对齐 `git.update.info.auto.open.enabled`：全局设置默认自动打开 Update Info；Update Project 的单 root、多 root、partial result 与失败 root Retry 在收到非空提交范围时打开专用 tab，关闭后保留当前 Log 并继续提供 `View Commits` 通知 action；共享 `GitUpdateInfoAsLog` 的 Push/Force-push update ranges 也接入该开关，普通 Pull 与其它非更新恢复流程不继承该上下文。

---

## Phase 4：History、Diff、Blame 和 Commit UX

### HISTORY-001：Commit Details 和 File History（P1）

实施内容：

- [x] Root commit 与空 tree 比较，显示完整文件列表（commit_diff 对无父提交用 empty tree，changes 全量 Added；UI 移除 root 占位）。
- [x] Merge commit 支持 parent 选择（commit_diff parent_index 0/1/多父，UI Parent picker；fixture 验证双父差异）；combined diff 策略标注为后续（DIFF 收口）。
- [x] CommitInfo 增加完整 message body、committer、author、签名和 verification 状态（message_body/committer_name/email/has_signature；verification 走 commit_signature_status）。
- [x] 增加真正的 File History 入口（Changes 行右键 Show History → Log 视图 + follow 过滤；follow renames 由 log(follow=true) 驱动）。
- [x] 对齐 Changes Browser 的核心文件动作（Show Diff、Show File History、Show History for Revision、Show File at Revision、Get Version、Copy Path、Create Patch、Compare with Local、Compare Before with Local、Edit Source、Apply Selected Changes、Revert Selected Changes）；Compare with Local 由 revision blob 与当前 worktree 的独立引擎 diff 支撑，Edit Source 委托 macOS 默认文件关联；Apply/Revert 通过 binary-capable patch 只修改 worktree，支持同一 Git root 下跨多个 commit 及跨 root 的选区，并按 root/commit/parent 分批执行，冲突停止后续批次并进入绑定触发 root 的 direct-patch resolver；同一 merge commit 混合 parent 安全禁用；Get Version 经过确认后同时恢复 index 与 working tree。
- [x] 接入 ChangesFilterer 对等交互：Filter By 的 Moved without changes 使用 tree 层 blob identity，Non-important 使用忽略空白后的统一 FileDiff（无 IDE 语言 ignored-ranges 时 fail-open），并显示过滤期间的 Not filtered 与完成后的 Filtered out 分组；Changes Browser 的列排序仍保持 partial。
- [x] 支持 follow renames（log follow=true 跨 rename 测试）与 path history；copy detection 沿用 status 的 copy 检测。
- [~] log 增量加载已有（after_id 分页 + loadMoreLog，测试验证跨页一致无重叠）；持久化 index/cache 未做（Phase 5）。
- [x] Blame 行可跳转到对应 commit detail（blame 行点击 → Log 视图选中该提交）。

验收：

- [x] root、merge（parent 选择）、rename（follow）、binary、无换行（body 解析）均有 fixture 测试（tests/history.rs，7 个）。
- [~] follow 行为与 git log 一致（rename 提交匹配语义经测试对齐）；差异提示机制未单独实现。
- [x] 大仓库滚动加载不阻塞主线程（log 在后台 Task + 分页；onReachedEnd 增量加载既有）。

### DIFF-001：完整 Diff 行为（P1）

实施内容：

- [x] 接入 attributes（binary 属性优先于 NUL 嗅探）与 CRLF（crlf_sensitive 设置，比较前标记/归一化）；diff driver 执行边界待决策（CFG-001 决策项）。
- [x] 支持 staged/unstaged/commit/branch/working tree 多种来源（WorktreeToIndex/IndexToHead/WorktreeToHead/diff_commits/diff_with_text 同一 FileDiff 模型）。
- [x] 支持 whitespace（行尾）、ignore-all-space（-w）、word diff（spans）设置（DiffSettings + diff_file_with_settings + UI 开关）。
- [x] 支持 rename（tree 层 Renamed）、binary（attributes + NUL）、submodule（commit 模式条目）diff（fixture 测试）。
- [x] 统一数据源（所有来源产出同一 FileDiff；side-by-side/unified 双模式 UI 既有；clipboard 走 diff_with_text；partial staging 用同一 hunk 模型）。
- [x] Changes Browser 的 Compare with Local / Compare Before with Local 使用 revision↔worktree 的统一 FileDiff，覆盖文本修改和 worktree 删除语义，并用 source+row 校验隔离异步结果。
- [x] Changes Browser 的 Non-important 过滤复用 `commit_file_diff(ignoreWhitespace: true)`，二进制变更 fail-open 保留；过滤失败按 IntelliJ 语义 fail-open。

### COMMIT-001：Commit 检查和签名（P1）

实施内容：

- [x] 接入 Git username/email（身份缺失阻塞+引导；effective Git config、项目级 global/local 选择、单 root 保存后自动重试、multi-root 持久化设置 action）、detached HEAD、unresolved conflict（阻塞）、CRLF、large file 检查（commit_checks 结构化输出）。
- [x] 支持 GPG/SSH signing 配置（signing_config 读取 commit.gpgsign/gpg.format/signingkey；身份设置 UI 已有）与 verification 展示（commit_signature_status + 详情页徽标，HISTORY-001）。
- [x] Amend/no-verify/sign-off/author/committer override 已有（commit_with_options + Swift amendMode/skipHooks/identitySignOff 状态）；previous commit authors 已按 project path 保存 16 条 MRU，并可从 Git Identity sheet 回填 author。
- [x] gix/commit-tree 提交路径按参考 `GitCommitMessageFormatter` 应用 repository `commit.cleanup` 与 `core.commentChar`（whitespace/scissors、verbatim、strip、自定义 comment prefix）；系统 Git `commit_with_options` 路径保持原生 cleanup。
- [x] Commit/Commit and Push 失败可重试不丢失 message 与选中（成功才清空 commitMessage；失败路径保留 entries/selection；内置检查失败引导修正）。

---

## Phase 5：长尾功能、性能和交互收口

- [x] Git Ignore 与 .git/info/exclude：快捷忽略（右键 Ignore/Exclude 已接入）、ignored rule 展示（ignored_rules 来源标注）、.gitignore 编辑入口（右键 Edit .gitignore 打开编辑器）。
- [~] submodule 递归/init/--remote update（submodule_update_with_options）、deinit、branch 配置（set_branch 写 `.gitmodules`）、dirty 状态（SubmoduleInfo.dirty + UI 徽标）、冲突状态（U 前缀解析）；SubmodulePanel 已补嵌套仓库 Log 与未初始化错误边界，并对 Add/Deinit/Remove 提供 parent HEAD、gitlink、`.gitmodules` 和 clean worktree 保护的 expected-state Undo；Update Project 已补 IntelliJ 风格 detached-submodule updater（递归发现最近父仓库，最深层优先保存现场，父 root 更新 gitlink，compound 成功后统一恢复 tracked/untracked 现场，父/子失败或取消时保留 stash/Shelf）；子模块自身多 root Update 失败后的 Retry 已按父链与 submodule 后代依赖闭包执行，父失败和级联 skipped 在同一 project-scoped notification 中聚合；多 root Commit/Push 已按最深层 submodule 到 superproject 排序；Update Project 失败后的 `Rollback Updated Roots` 已支持父/子 gitlink 联合恢复、expected-HEAD CAS、独立 root stash/Shelf 保留和跨重启 semantic action；完整 remote/branch 展示、联合 diff、跨 root atomic transaction 与完整后续 action history 仍待实现。
- [x] tag create（New Tag 对话框，含对已有 tag 的显式 Force 覆盖）/ delete / rename（tag_rename）/ 单个与批量 push 的完整 UI（BranchesPopover TAGS 右键菜单与 Push All Tags）；默认创建仍保持 MustNotExist，annotated/signed force 复用系统 `git tag --force`。
- [x] log context menu 补齐（View Details/Create Branch/Cherry-pick/Revert/Checkout/Reset/Compare/Interactive Rebase/Open PR/Comment + Copy Commit ID/Message）。
- [x] Search Everywhere（⌥⌘O）：分支快速检出 + Git 动作搜索（VCS 菜单通知驱动）。
- [~] log 加载取消行为（generation 丢弃过期结果）+ 分页游标完成；跨进程持久化缓存未实现（已知限制，依赖 gix 增量计算）。
- [x] VCS Log 文本过滤已补齐 Regex / Match Case action 语义；选项按 Log tab 持久化，非法正则在引擎侧结构化报错，旧普通包含过滤 API 保持兼容。
- [x] 所有长耗时操作均在 Task.detached 后台执行（审计确认，见 docs/ui-audit.md）。
- [~] 审计持续进行（docs/ui-audit.md）：i18n 当前扫描 1071 个字面量，zh-Hans 缺失 0 个，但仍有 124 个 catalog key 缺失；快捷键对照表、启用条件逐项核对和无障碍标签核对已完成。

---

## 4. 建议的任务拆分和依赖关系

| ID | 工作包 | 优先级 | 依赖 | 主要交付物 |
|---|---|---:|---|---|
| GIT-001 | IntelliJ action/behavior parity matrix | P0 | 无 | 全量映射表、范围决策 |
| ENG-001 | Git process runtime | P0 | GIT-001 | 流式输出、取消、结构化错误 |
| AUTH-001 | HTTPS/SSH credential broker | P0 | ENG-001 | Keychain、askpass、认证 UI |
| REPO-001 | Multi-root repository manager | P0 | ENG-001 | roots、聚合状态、多 root 调度 |
| CFG-001 | Git config/attributes/CRLF | P0 | ENG-001 | attributes 与换行一致性 |
| OPS-001 | Operation state/recovery | P0 | ENG-001、REPO-001 | continue/skip/abort 状态机 |
| IDX-001 | Index/staging workspace | P1 | CFG-001、OPS-001 | 三层 diff、partial staging |
| CONFLICT-001 | Conflict workspace | P1 | IDX-001、OPS-001 | 四方 diff、恢复入口 |
| REBASE-001 | Interactive rebase UI | P1 | OPS-001、HISTORY-001 | reorder、fixup、todo |
| REMOTE-001 | Remote configuration/push | P1 | AUTH-001、ENG-001 | remote dialog、高级 push |
| STASH-001 | Stash/shelve workspace | P1 | IDX-001、CONFLICT-001 | preview、apply、unstash-as |
| HISTORY-001 | Log/file history/commit details | P1 | CFG-001 | root/merge/file history |
| DIFF-001 | Full diff behavior | P1 | CFG-001、IDX-001 | attributes-aware diff |
| COMMIT-001 | Commit checks/signing | P1 | AUTH-001、CFG-001 | checks、signature |
| UI-001 | Menu/popup/action parity | P1 | 上述引擎能力 | 可达入口、快捷键、启用条件 |
| TEST-001 | Scenario and UI test matrix | P0 | GIT-001 | fixture、Rust、XCUITest |

开发顺序应遵循依赖关系，不要先扩展 SwiftUI 按钮数量，再回头补 operation state、认证和 index 模型。

---

## 5. 测试方案

### 5.1 Rust 单元和集成测试

- [~] 每个 GitCommandProcess failure kind 都有测试（Authentication/Network/NonFastForward/Conflict/RepositoryNotFound/Hook/Lock/Cancelled/Timeout 已覆盖；Permission/Divergent 等边界 kind 未逐一断言）。
- [x] 使用临时 Git fixture 测试真实 repository state（246 个测试全部基于 tempfile + 系统 git fixture）。
- [x] 覆盖 HTTPS/SSH 认证与 credential helper 检测（mock HTTP + askpass 桥全流程；remote_config 覆盖本地 helper 与 shell helper 排除）。
- [~] 覆盖 attributes、CRLF（tests/attributes.rs + diff_behavior.rs）；Attributes Inspector 已有可达 UI；filter/diff driver/merge driver 只做事实读取，不执行外部命令（按 CFG-001 安全决策）。
- [x] 覆盖 root commit、merge commit、rename、binary、submodule（tests/history.rs + staging_model.rs + diff_behavior.rs）。
- [x] 覆盖 merge/rebase/cherry-pick/revert 的 continue/skip/abort（tests/opstate.rs + rebase_todo.rs + golden_scenarios.rs）。
- [x] 覆盖多 root 与 nested repository（tests/roots.rs + multi_root.rs + golden_scenarios.rs）；跨 root 调度部分失败、checkout Smart 恢复冲突按 root 隔离并有回归测试。

### 5.2 SwiftUI UI 测试

- [x] Git 菜单和 Branches Popup 的入口可发现且启用条件正确（代码审计:ArborApp Commands + ui-audit.md 启用条件逐项核对;XCUITest 未建,见已知限制）。
- [x] Changes Workspace 的 stage/unstage/partial stage 状态正确（引擎行为测试 tests/staging.rs + staging_model.rs;UI 接线经构建验证）。
- [x] 认证对话框支持首次登录、错误重试、取消和保存凭证（mock HTTP + askpass 全流程测试;Keychain 保存/取消分类引擎断言）。
- [x] 冲突工作台支持解决、标记完成、继续和中止（tests/conflict_workspace.rs + opstate.rs 行为测试）。
- [x] rebase todo 支持排序、fixup、squash、drop、continue、skip、abort（tests/rebase_todo.rs + opstate.rs）。
- [~] Root commit、merge commit、file history、stash preview 有行为测试（tests/history.rs + stash_workspace.rs）;UI 快照未建（XCUITest 已知限制）。

### 5.3 场景级黄金测试

至少建立以下场景，每个场景同时检查 Git tree、index、工作区、UI 状态和最终错误分类：

1. HTTPS 私有仓库首次 clone（mock HTTP 401→200 认证流,askpass 桥全流程）。
2. SSH 私钥带 passphrase 的 push（passphrase 提示解析 + 认证取消分类覆盖；真实 sshd 依赖标注为环境限制）。
3. 认证取消和错误凭证重试（attempt 递增 + Cancelled 分类）。
4. attributes 改变后的 text/binary diff（binary 属性优先于 NUL）。
5. CRLF 与无换行文件（敏感/归一化 + 无尾换行无伪影）。
6. root commit 查看和 diff（空 tree 完整文件列表）。
7. merge commit 双 parent 查看（parent 选择 diff 互补）。
8. merge 冲突、continue、abort（abort 恢复现场 + continue 双父提交）。
9. rebase 冲突、continue、skip、abort（skip 丢弃当前步）。
10. cherry-pick 冲突、continue、abort。
11. revert 冲突、continue、abort。
12. interactive rebase reorder/fixup/squash/drop（todo 顺序 = 拓扑）。
13. 部分行暂存后提交（tree 内容与所选行一致）。
14. binary 文件和 rename 的 staging。
15. stash apply/pop 冲突（HEAD 前进后 apply 冲突,stash 保留）。
16. unstash-as 创建分支（分支创建 + 弹出 stash）。
17. force-with-lease 失败（拒绝 + NonFastForward 分类 + 远程未覆盖）。
18. rejected push 后 merge/rebase update（分类 → fetch+pull → push 成功）。
19. 两个 Git roots 的提交和 push（各自远程互不污染）。
20. 应用在 Git 操作中退出后重新打开（重开仓库恢复冲突现场）。

---

## 6. 每个功能的 Definition of Done

一个功能只有满足以下条件才能从“部分完成”改为“完成”：

- [x] 有 IntelliJ 基线映射项（parity matrix 逐项映射）。
- [x] 有 Rust engine API 或明确复用的 command API（全部功能经 uniffi API 暴露）。
- [x] 有可达的 SwiftUI 入口（parity matrix 的 swiftui_entry 列逐项核对）。
- [x] 有成功、失败、取消和恢复路径（各工作包测试覆盖）。
- [x] 有错误分类和用户可理解的提示（EngineError/失败分类结构化）。
- [x] 有至少一个真实 Git fixture 测试（254 个测试全部基于真实 fixture）。
- [~] 关键 UI 有行为测试（引擎行为 + UI 接线构建验证）;XCUITest 未建立（环境限制）。
- [x] 不会阻塞主线程（全部引擎调用在 Task.detached,审计见 docs/ui-audit.md）。
- [~] 快捷键和启用条件已完成审计；zh-Hans 翻译缺失为 0，但 i18n 仍有 124 个 catalog key 缺失（见 ui-audit.md）。
- [x] 文档和 parity matrix 已更新。

以下情况不得标记为完成：

- 只有 engine 方法，没有 UI 入口。
- 只有按钮，没有真实 action。
- 只能成功，不能处理失败或冲突。
- 通过 generic error 掩盖认证、取消或操作状态。
- 只在当前测试 fixture 通过，没有边界测试。

---

## 7. 里程碑和发布闸门

### M0：可验收基线

- [x] parity matrix 完成。
- [x] 所有范围决策完成。
- [x] checklist 中的虚假完成项修正。

### M1：P0 Safe Git Core

- [x] Git process runtime 完成。
- [~] HTTPS/SSH 认证基础链完成（HTTPS 全流程；SSH passphrase/password 与 Ask host-key 多行指纹提示及取消/接受/拒绝分类完成；changed-host-key 已结构化分类并提供 SSH Settings 恢复入口；repository-scoped host-key/auth/known_hosts/identity 设置与 local credential helper 编辑已通过 system Git 生效；prompt 认证的 last-successful method persistence 与只读 SSH agent 状态探测已接入，但 agent/helper 来源级成功观测、SSH key 管理与真实 sshd 端到端仍待补齐，环境限制已标注）。
- [x] attributes/CRLF 完成。
- [x] operation recovery 完成。
- [~] 多 root 发现/聚合/隔离已完成（含 Git Roots 面板 checkout 与 Smart/Force/Cancel/recovery、Branches Popup 按 root 分组/独立 repository picker/flat filter/定向 checkout/非当前分支 Update-Pull/root-scoped Push dialog/Recent-Tag-Stash 基础动作/Checkout and Update、Merge/Rebase/Set-Unset Upstream/Rename/Delete/Compare、per-root remote config、⌘T 自动逐 root 更新）；Checkout and Update 的 checkout 阶段补偿回滚、普通 checkout 部分成功后的 `Rollback Successful Roots`、operation/stash conflict workbench、项目级 resolver queue 与临时 Update stash 的 reopen recovery 已闭合，update 已对齐参考实现的逐 root partial-result 语义，终态反馈不会被刷新任务覆盖；Update/其他复合动作更完整的 rollback/action surface 仍未闭合，冲突文件的外部 merge tool 已在 root workbench 可用。

### M2：Core Interaction Parity

- [x] Staging Workspace 完成。
- [x] Conflict Workspace 完成。
- [~] Interactive Rebase 主链完成；root todo 已接入 Log，preserve-merges 的 merge root message reword 与同一 branch segment 内的连续 squash/fixup 已接入，通用 Rebase dialog 另有非交互原生模式；但 merge descendant 的完整控制行编辑、跨 root 通知/撤销与 UI automation 仍缺。
- [x] Root/Merge/File History 完成。

### M3：Remote and Workspace Parity

- [x] Remote Configuration 完成。
- [~] Stash/Shelve Workspace 部分完成（stash 主流程与 stash/shelf patch 预览已接入；Shelf 已支持按 changelist 展开目录/文件成员、持久化目录分组、按文件的结构化 FileDiff 与 side-by-side/unified 切换、成员级 Unshelve/Drop；stash/shelf 成员冲突对话框和更完整的通知语义仍待收口）。
- [~] Branches Popup 和 Working Trees 部分完成（单 root 入口与 Git Roots 聚合已接入；多 root Branches Popup 已有 root 分组/独立 repository picker/flat filter/定向 checkout/非当前分支 Update-Pull/root-scoped Push dialog/Recent-Tag-Stash 基础动作/Checkout and Update/recovery、Merge/Rebase/Set-Unset Upstream/Rename/Delete/Compare，以及对被 linked worktree 占用的本地分支提供 `Open Worktree…`；per-root remote 配置、stash/operation/unmerged 冲突可进入项目级 resolver queue，恢复条与失败反馈可直接触发 Resolve Conflicts；临时 Update stash 支持 reopen 后发现与恢复；update 已对齐逐 root partial-result 语义，终态反馈不会被刷新任务覆盖；IntelliJ 实际存在的 rollback/action surface 仍缺，冲突文件的外部 merge tool 已可用）。

### M4：IntelliJ Git Parity Candidate

- [~] 所有 P0/P1 项目关闭（SSH 真实传输已具备可作用于 system Git 的 advanced settings，Ask/changed-host-key 交互、prompt 认证的 last-successful method 与只读 agent 状态探测已接入；仍缺 agent/helper 来源级成功观测、SSH key 管理、REPO-001 完整 per-root Branches action、跨 root update 的原子事务/通知编排，见 parity-decisions）。
- [x] P2 项目有明确完成、延期或 out-of-scope 决策。
- [x] 20 个黄金场景全部通过（tests/golden_scenarios.rs 21 个测试 + 既有场景测试）。
- [~] Rust 全量测试并全绿、SwiftUI `build-for-testing` 与 102 个 Swift 测试通过；UI 自动化（XCUITest）与性能基准未建立（已知限制,行为测试已覆盖 5.2 各条）。
- [x] parity matrix 中不存在“未验证的已完成”（矩阵判级规则:仅引擎无 UI 一律 partial）。

---

## 8. 第一周立即执行清单

- [x] 创建 `docs/git-parity-matrix.csv` 并导入 IntelliJ action 清单（179 行）。
- [x] 创建 `GitCommandProcess` 的接口草案和 mock runner（gitprocess.rs 实现 + 13 个单元测试）。
- [x] 记录当前所有 system-Git 调用点，并按 clone/fetch/pull/push/merge/rebase 分类；44 处调用已统一使用 `git_command()`（docs/git-command-call-sites.md）。
- [x] 设计 `GitOperationState` 和恢复 action API（opstate.rs 实现 + 11 个集成测试）。
- [x] 设计 Rust ↔ SwiftUI credential broker 接口，不先绑定具体 Keychain UI（docs/auth-credential-broker.md）。
- [x] 建立 attributes/CRLF fixture 仓库（tests/attributes.rs，9 个测试）。
- [~] 为多 root 建立最小 fixture（tests/roots.rs）；root commit / merge commit fixture 由 HISTORY-001 补齐。
- [x] 将 `RebasedWorkspaceViews.swift` 中的三个空操作按钮改为明确的 disabled 状态或接入任务（Shelve 接真实对话框；Preview/Add Changelist 显式 disabled + 原因提示）。
- [x] 将 `PRODUCT_CHECKLIST.md` 中 per-file history、reorder、fixup、shelve 等项目改为“部分完成”（并修正分支删除/重命名、submodule 等无入口项）。

第一阶段的完成标准不是新增更多按钮，而是让认证、Git 结果正确性和中断恢复变得可靠。只有完成这一层，后续 UI parity 工作才不会建立在错误或不可恢复的 Git 状态之上。

本轮继续补齐（2026-08-24）：Compare Branches 的两侧 unique-commit pane 现在复用完整 `LogGraphView`，接入 graph lanes、merge fragment 交互、Commit/Author/Date/Hash 列、横向/纵向滚动、Cmd/Shift 多选和现有 Log context action callbacks；两侧 filter 状态仍独立，且 root-safe action 路由保持不变。完整 IntelliJ permanent VCS Log manager、独立分页/refresh lifecycle、native DataContext/action-group lifecycle 与 UI automation 仍为 partial；单次比较查询仍限制 500 条。
2026-08-24 Compare Tree patch action：Compare With / Show Files Diff 的 selected changes 现在可导出 portable patch；revision、working tree 和 pathspec 作为独立 Git 参数传递，root-scoped Repository 执行，rename 旧路径保留，失败/空输出 fail-closed。剩余 native Changes Browser action/DataContext 生命周期与 UI automation 仍为 partial。
2026-08-24 external VFS file rename review：FSEvents 缺少 old endpoint 且存在多个同 basename deleted candidates 时，现复用 ambiguous move picker 让用户显式选择 old→new；选择结果按独立 Add/Remove settings 执行，跳过时保守保持未处理。唯一配对和 identity-backed rename 不变，native VFS operation-state、permission/banner、action history 与 UI automation 仍为 partial。
