# 产品清单：IntelliJ 式 Git 客户端（Rust 引擎 + SwiftUI 客户端）

## V1 发布闸门（2026-08-29）

所有 in-scope Git 用户行为已完成并通过 Rust workspace、Swift/macOS 全量测试
和构建验证。`verified-partial` 仅表示 IntelliJ 原生 `DataContext`、
`VcsNotifier`、`DialogWrapper`、VFS/PSI 生命周期、Swing/UI automation 或
已记录的呈现差异；这些宿主能力不阻塞 V1。矩阵不再有未决功能性 `partial` 项，
跨 root 继续遵循逐 root partial-result 语义，不宣称跨 root 原子事务。

发布命令：`ARBOR_UNSIGNED=1 ./scripts/release.sh 1.0.1`（仅本地 QA）；生产
发布必须提供 Developer ID、完成 notarization、更新 appcast/Cask 校验和依赖
许可证清单。

本轮对齐 `Git.Show.Stash`（2026-08-28）：VCS > Git > Local Changes 增加 Show Stash，直接选择 Stash/Shelf 工作页；Unstash 继续保持恢复弹窗语义。

本轮补齐 `Git.Stash.UnstashAs`（2026-08-28）：单 stash 行菜单提供可选 branch、Pop 和恢复 staged state 的组合对话框；执行按稳定 stash ID 重新解析栈位置。

本轮补齐 `Git.Stash.Toggle.Split.Preview`（2026-08-28）：Stash 工作页提供默认开启且持久化的 split-preview toggle；关闭后显式 View Diff 仍可在独立预览 sheet 中查看。

本轮补齐 Stash 预览身份安全（2026-08-28）：预览按稳定 stash ID 路由，刷新/删除前置项后重新映射 stack index，目标消失则关闭过期预览。

本轮收口 Stash 操作身份安全（2026-08-28）：Commit/Stash 工作页、旧侧栏、Unstash/Unstash As、多 root 与冲突恢复链路直接传递 stash commit ID；缺少稳定 ID 或 Pull 唯一 message 时保留 stash 并失败，不再回退 `stash@{0}` 或旧 index。

本轮对齐显式 Git.Stash 对话框（2026-08-28）：增加 Git root/current branch 上下文与 `Keep index`，按所选 root 执行；Pull/Update 和 Stash Files 的额外现场选项保持独立。

本轮补齐 Git 初始化安全边界（2026-08-28）：初始化已有 Git worktree 或其子目录前必须确认，取消不启动操作。

本轮对齐 Git.Pull 主菜单交互（2026-08-28）：VCS > Git 现在是单一 `Pull…` action，直接进入可选择 Git root、remote、remote-tracking branch 和持久化 options 的 Pull dialog；Merge/Rebase 仍由 dialog option 与分支级动作提供。原生 GitPull/DialogWrapper/VcsNotifier lifecycle 和 UI automation 仍为 partial。

本轮补齐 New Branch fresh/unborn 边界（2026-08-28）：对照 fork `GitCreateNewBranchAction`，VCS > Git 的 `New Branch…` 在任一受影响 root 没有 HEAD 时保持可见但禁用，通知直达入口也会再次拒绝；Branches Popup 的既有禁用语义保持一致。原生 action/DataContext lifecycle 和 UI automation 仍为 partial。

本轮补齐 Find Merged 入口边界（2026-08-28）：对照 fork `FindMergedLocalBranchesAction`，single-root 与 multi-root Branches Popup 仅在存在两个以上 local branches 的 root 时启用 `Find Merged…`；既有扫描与报告逻辑不变。原生 action/DataContext lifecycle 和 UI automation 仍为 partial。

本轮补齐 Checkout and Update 调用时状态校验（2026-08-28）：单 root action 在切换分支前重新确认有效 tracking branch；过期状态 fail-closed，避免切换后跳过 update 却报告成功。原生 ActionData/DataContext/VcsNotifier lifecycle 和 UI automation 仍为 partial。

本轮补齐 Cleanup Branches 表格选择语义（2026-08-28）：对照 fork 的 `CleanupBranchesDialog`，表格行选中用于 Copy，Selected 列勾选用于 Delete；复制遵循当前可见排序行的 branch/date/tracked 三列格式，Filter 会清理隐藏行选择。原生 JTable/CopyProvider/DataContext 生命周期和 UI automation 仍为 partial。

本轮补齐 Git 文件上下文菜单（2026-08-28）：对照 fork 的 `Git.ContextMenu`，项目文件树现在提供 Checkin Files、Add、Compare、History、Annotate、Revert、Resolve Conflicts 和 Revert Resolved；Add/Revert 按 owning Git root 执行，目录递归 Add 与冲突目录聚合暂保持禁用。原生 VersionControlsGroup/DataContext/VcsNotifier 生命周期和 UI automation 仍为 partial。

本轮补齐 Show Current Revision（2026-08-28）：项目文件树文件右键菜单现在显示该文件最近提交的 revision、author、date 和完整 message；按最深 owning Git root 使用 `git log --all --follow -n1 -- <path>` 查询并支持 follow-renames，无历史、untracked、ignored、conflicted 文件 fail-closed。SwiftUI sheet 代替原生 popup，DataContext/ProgressManager/VcsNotifier lifecycle 和 UI automation 仍为 partial。

本轮补齐 Git 主菜单 Clone 入口（2026-08-27）：VCS > Git 现在直接打开与 File 菜单、空状态页共享的 `RebasedCloneDialog`，并保留递归 submodule 等已有 clone 选项。

本轮补齐 Git Reset Head 主菜单入口（2026-08-27）：VCS > Git 提供 `Reset Head…`，可选择 Git root、Validate 任意 revision expression，并选择 Soft/Mixed/Hard；执行复用已有 root-scoped Smart/Force、Undo/Keep 和 recovery 链路。原生 DialogWrapper/ProgressIndicator/VcsNotifier/DataContext lifecycle 仍为 partial。

本轮补齐 Git Revert Resolved 主菜单入口（2026-08-27）：VCS > Git 提供 selection-scoped `Revert Resolved`，仅当前选中路径属于 resolved-conflict ledger 时启用，复用既有冲突恢复 API。原生 DataContext 多选/VcsNotifier/UI automation 仍为 partial。

本轮补齐 Git.FileActions 主菜单入口（2026-08-27）：VCS > Git 在有显式文件/目录选区时提供 Checkin Files、Add、Annotate、Compare with HEAD、Compare with Selected Revision、Compare with Branch or Tag 和 Show File History；Add/Checkin 使用 owning Git root 与当前状态重新校验。History for Block、多选 DataContext、原生 VcsNotifier 生命周期和 UI automation 仍为 partial。

本轮补齐 Branches Popup Tag action parity（2026-08-27）：单 root/multi-root 非当前 Tag 右键菜单提供 Checkout 并路由既有 root-scoped checkout；当前 Tag 移除 branch-only New Working Tree/Rename，匹配 fork 的 Tag action 集合。原生 GitCheckoutAction/DataContext/VcsNotifier lifecycle、smart-checkout 细节和 UI automation 仍为 partial。

本轮补齐单 root Branches Popup 无 remote 的 Push 可达性（2026-08-27）：参考 fork `GitPushBranchAction`，无 configured remote 时点击本地分支 `Push…` 仍打开 Push dialog，明确提示配置 remote 并提供入口；`Commit and Push` 保留 commit-only fallback。原生 VcsPushDialog 空 remote presentation、VcsNotifier/DataContext lifecycle 与 UI automation 仍为 partial。

本轮补齐单 root Branches Popup 的分支级 Push（2026-08-27）：参考 fork `GitPushBranchAction`，本地分支（当前及非当前）action menu 现在提供 `Push…`，并将所选 branch 预填为 Push source；multi-root 分支 Push 保持 root-qualified。原生 VcsPushDialog/VcsNotifier/DataContext lifecycle 与 UI automation 仍为 partial。

本轮补齐 in-memory 历史改写取消语义（2026-08-27）：Log Drop/Interactive Rebase 的对象级 replay 现在消费同一 `GitCancelHandle`，在保存现场前及每个 replay step 前可取消，取消恢复原 HEAD 与本地 staged/unstaged/untracked scene；Log Drop 已切换到 cancellable API。原生 ProgressIndicator/ProgressWindow/DataContext lifecycle 与 UI automation 仍为 partial。

本轮校正多 root Log Revert/Cherry-pick Abort 语义（2026-08-27）：复合 Log 操作从当前 root Abort 后，现在清理整条 session 的当前及后续 root recovery marker，并撤销陈旧 Retry 通知；Continue 仍按 root 顺序推进。新增 session cancellation scope 测试；原生 VcsNotifier/DataContext lifecycle 与 UI automation 仍为 partial。

本轮补齐 Submodule Sync 面板入口（2026-08-27）：Operations > Submodules 现在提供 `Sync`，接入既有 root-scoped、可取消、可重试的递归 `git submodule sync` runner；此前引擎与恢复链路已有能力，但面板没有用户可见入口。原生 action-group/DataContext/VcsNotifier lifecycle 与 UI automation 仍为 partial。

本轮补齐 Git annotate options（2026-08-27）：参考 `GitToggleAnnotationOptionsActionProvider`/`GitAnnotationProvider`，Blame 默认忽略空白，并支持文件内移动、跨文件移动和 author/committer date 选择；FileContentView 与 DiffDetailView 共用可持久化的 Blame Options 菜单，Rust runner 真实传递 `-w`/`-M`/`-C`。原生 AnnotationGutter/FileAnnotation/DataContext 生命周期、受影响路径缓存和 UI automation 仍为 partial。

本轮补齐 Commit warning 顺序交互（2026-08-27）：参考 `GitCheckinHandlerFactory` 的有序 `CommitCheck` 与 `GitCrlfDialog`，单 root 与 multi-root 提交现在逐 warning category 展示 Commit Anyway/Cancel；CRLF 提供 Set `core.autocrlf` and Commit，每类 warning 独立支持 project-scoped Do-not-ask，同一提交内的重复 category 会合并。原生 DialogWrapper/CommitCheck/VcsNotifier/DataContext lifecycle、详情链接和 UI automation 仍为 partial。

本轮校正 Commit and Rebase autosquash 语义（2026-08-27）：对照 fork 的 `GitRebaseCheckinHandlerFactory`，Fixup/Squash 提交后的自动整合现在走 native `git rebase -i --autosquash`，Rust 只负责 target/range 校验；root target 传递 `--root`，取消、冲突暂停、本地现场恢复和 expected-HEAD Undo 保持不变。新增 native 普通/root autosquash 回归；Commit Executor/DialogWrapper、通知分组、DataContext lifecycle 与 UI automation 仍为 partial。

本轮补齐 IntelliJ in-memory commit editing registry 语义（2026-08-27）：新增默认开启的全局设置，并让 Log structured rebase 与直接 Drop Selected Commits 按条件选择后端；无 EDIT、非 merge-preserving 的 linear/root todo 走 Rust 对象级引擎，关闭设置、EDIT、保留 merge 拓扑及冲突 fallback 走 native Git interactive rebase，native action 映射覆盖 pick/drop/edit/reword/squash/fixup。in-memory 冲突会先安全恢复原 HEAD/本地现场，再自动重放完整 native todo；native 再次冲突时保留恢复状态。默认关闭的 `git.in.memory.interactive.rebase.debug.notify.errors` registry 及原生 VcsNotifier/DataContext/UI automation 仍为 partial。

本轮补齐 Auto Fetch/LS_REMOTE incoming branch state（2026-08-27）：参考 `GitBranchIncomingOutgoingManager`，monitor 现在按 Git root、remote、branch 发布带 checked-remote 身份的 incoming 快照；Branches Popup、multi-root Branches、分支按钮和状态栏会显示远端已有但尚未 fetch 的未知数量 `↓?`，后续空快照只清除已完成检查的 remote，失败或争用的 remote 保留旧状态，通知也随最终合并状态清理。该状态不参与 checkout、pull、push 或 upstream action availability；原生 VcsNotifier/permission/banner、完整 dashboard data model 与 UI automation 仍为 partial。

本轮补齐 Update Project 的全局未就绪前置检查（2026-08-27）：参考 `GitUpdateProcess.isUpdateNotReady()`，Rust 在 fetch/stash/pull 前统一检查所有 root 的进行中 Git 操作与未解决 index 冲突；阻塞 root 返回失败、其他 root 返回未执行，保证不会先更新一部分 root 再在后续 root 失败。Swift 将该结果归入 `Update Project unavailable`，结果行进入 Operation Log 并提供 Conflict Workbench；取消语义保持不变。原生 `GitUpdateExecutionProcess`/VcsNotifier/DataContext lifecycle 与 UI automation 仍为 partial。

本轮补齐 Git incoming/outgoing 高级可见性开关（2026-08-27）：参考 `git.update.incoming.outgoing.info`，全局设置现在默认开启并统一控制 Auto Fetch/LS_REMOTE monitor、Branches Popup 与状态栏的 incoming/outgoing 信息；关闭时保留原策略但停止检查、隐藏同步徽标并撤销旧的可操作通知，项目级设置提供 disabled 反馈。原生 `AdvancedSettingsPredicate`/`GitVcsSettings`/VcsNotifier/DataContext lifecycle 与 UI automation 仍为 partial。

本轮补齐 Log Changes Browser 的多 root commit identity（2026-08-27）：aggregate Log 的 Changes 分组现在按 `Git root + commit ID` 隔离，跨仓库相同 object ID 不会混合文件树或子模块请求；同名 root 在标题中显示完整路径以消除歧义。原生 VcsLog/ChangesBrowser/DataContext/VcsNotifier lifecycle 与 UI automation 仍为 partial。

本轮校正 Update Project 的全 skipped 结果（2026-08-27）：对照 `GitUpdateProcess.checkTrackedBranchesConfiguration()`，多 root Update Project 在所有 root 都 detached 或没有 tracked upstream 时现在发布 `Update Project unavailable` 错误，而不是误报 completed；结果行仍持久化到 Operation Log，并提供 root-scoped Choose Upstream / Open Branches 恢复入口。只有存在至少一个可更新 root 时，其他 root 才按 skipped partial 语义保留。原生 VcsNotifier/DataContext lifecycle 与 UI automation 仍为 partial。

本轮校正 Shelf 单项 action 的反馈语义（2026-08-27）：对照 `ApplyShelfAction` / `PopShelfAction`，单 Shelf 的 Apply (Keep)、Unshelve and Remove、Pop、Drop 现在分别写入对应的 Operation Log/进度标题，不再把 Apply 记录成 Pop、把 Pop 记录成 Unshelve；底层 differentiated apply/pop 与恢复边界不变。原生 VcsNotifier/DataContext 生命周期和 UI automation 仍为 partial。

本轮补齐 Shelf DeleteProvider 混合选择生命周期（2026-08-27）：active Shelf、active 成员、Recently Deleted Shelf 和 Recently Deleted 成员的 Cmd-多选 Delete 现在先形成一个 root-scoped `ShelfDeletePlan`，按 active list → active member → deleted list → deleted member 串行执行，并只发布一次进度/通知/最终快照；Undo 只包含成功移入 Recently Deleted 的 active 范围，Retry 通过 Codable 计划保留四类失败范围。原生 ShelvedChangesViewManager/DataContext/VcsNotifier 生命周期、完整回收 action model 和 UI automation 仍为 partial。

本轮补齐 Git Stage 三版本 diff 的交互暂存（2026-08-27）：参考 `GitStageThreeSideDiffAction` / `GitStageDiffUtil`，非冲突文件的三版本视图现在保留 HEAD/Staged/Worktree 总览，并可切换 HEAD→Staged 与 Staged→Local pairwise diff；对应 hunk 支持 Unstage、Stage、Rollback，复用 Rust partial-staging 引擎。完整 IntelliJ DiffManager 三栏对齐、原生 action/DataContext 生命周期和 UI automation 仍为 partial。

本轮补齐 Git Stage Local/Staged 比较的可写语义（2026-08-27）：参考 `GitStageCompareLocalWithStagedAction` / `GitStageCompareStagedWithLocalAction` 共用 `compareStagedWithLocal`，两种入口现在都使用 staged→local 的 staging 坐标系，并在 hunk 上提供 Stage/Rollback；`Staged with HEAD` 保留 Unstage hunk。完整 DiffManager action lifecycle 与 UI automation 仍为 partial。

本轮补齐 Git Stage 的 ignored 文件显示设置（2026-08-27）：对照 fork 的 `GitStageUiSettings`，`Show Ignored` 现在按标准化 project path 持久化，切换项目或重建 Commit 工作区会恢复各自设置，默认仍为显示；原生 GitStageUiSettings/DataContext 生命周期和 UI automation 仍为 partial。

本轮修复 multi-root Commit 的 CRLF 修复动作（2026-08-27）：多 root warning 对话框选择“Set core.autocrlf and Commit”后，现在会在任何 Git 写入前只执行一次 global `core.autocrlf=input`；配置写入失败按 IntelliJ 的非阻断语义继续提交，并让下一次提交继续显示告警。单 root 行为保持不变；原生 DialogWrapper/DataContext/VcsNotifier 生命周期和 UI automation 仍为 partial。

本轮补齐 HTTPS askpass 的认证会话语义（2026-08-26）：对照 fork 的 `GitHttpGuiAuthenticator`，Rust 会在同一认证轮次复用用户名提示中返回的密码，避免用户名/密码连续弹两次对话框；Swift 按完整远端 URL 记住非敏感用户名，认证失败只清除对应 host/user 的 Keychain secret，重试会话继续携带脱敏失败分类。SSH passphrase、host-key、agent/helper 和 hosting token 保持独立；真实 sshd/Keychain UI automation 仍是 partial。

本轮校正 Find Merged 的多 root 目标分支边界（2026-08-26）：对照 IntelliJ `reposWithTarget`，不含目标本地分支的 Git root 只计入发现数，不参与比较也不制造 incomplete 错误；真正的 comparator 失败、取消、部分完成 root 与报告统计继续保留。无匹配结果时 UI 明确显示无可用 repository result。

本轮补齐 Compare Branches 的两侧方向设置（2026-08-26）：对照 fork 的 `CompareBranchesDiffPanel` 与 `SWAP_SIDES_IN_COMPARE_BRANCHES`，Branches 的 `Show Diff with Working Tree` 默认将当前工作树显示在左侧、选中分支显示在右侧；`Swap Sides` 会按项目持久化并反转 hunk 起点、行号和 Addition/Deletion 展示，tab 切换及异步刷新不会覆盖新方向。原生 CompareBranchesDiffPanel/ChangesBrowser/DataContext 生命周期和 UI automation 仍为 partial。

本轮校正 embedded GPG pinentry launcher 路由（2026-08-26）：对照 fork 的 `GpgAgentConfigurator`，launcher 在 `PINENTRY_USER_DATA` 带 Arbor 会话令牌时启动 `--arbor-pinentry`，带 `IJ_PINENTRY_ENTRYPOINT=` 时把远程 entrypoint 和原始参数安全转发，其它 GPG 调用直接使用检测到的系统 pinentry；取消、协议错误或 helper 非零退出不会再被 launcher 误判为第二次 fallback。新增真实 `/bin/sh` 路由测试；远程 entrypoint 的创建/生命周期由远程开发宿主负责，真实 GPG signing GUI automation 和原生 DialogWrapper 生命周期仍为 partial。

本轮校正 Shelf 树状态的项目边界（2026-08-26）：Shelves 展开、按目录分组和 Recently Deleted 展开现在按标准化 project path 持久化，切换项目不会把一个项目的树状态带到另一个项目；默认值仍为展开和按目录分组。Shelf 的完整回收 action model、细粒度通知生命周期和 UI automation 仍为 partial。

本轮补齐 secondary Shelf 的外部 metadata 刷新（2026-08-26）：当前选中的 secondary root 收到 `.git/arbor-shelves*` 对应的 `.gitMetadata` 事件后，会在 aggregate root refresh 后重新加载 Shelf、Recently Deleted 和 changelist snapshot，不再被已有缓存遮蔽；primary root、其它 root 和纯 worktree 事件不会误触发。IntelliJ 原生 `ShelveChangesManagerListener`/VcsNotifier/DataContext 生命周期仍为 partial。

本轮继续补齐 PatchWriter 原始字节链路（2026-08-26）：Rust Git runner 与 `GitCommandResult` 同时保留 stdout 原始字节和 Unicode 文本；Compare、Log、Diff Viewer 及多组 Log patch 文件导出直接使用原始字节，避免非 UTF-8 输出先经 replacement character 损坏；有效 UTF-8 仍按选择转码，无法安全推断源字符集时明确拒绝其它目标编码。剪贴板继续使用 Unicode 文本。原生 CharsetToolkit/EncodingProjectManager 默认值、PatchWriter dialog/action/DataContext/VcsNotifier 生命周期和 UI automation 仍为 partial。

本轮已补齐 `Git.Add` ignored-file 确认路径（2026-08-26）：Ignored Files 行的右键菜单新增 `Add to Git…`，确认后将当前文件内容显式加入 index；取消不改变 ignored 状态，Stage all 仍不会隐式加入 ignored 文件。原生 ScheduleForAdditionAction/ChangesView/DataContext 生命周期和 UI automation 仍为 partial。

本轮校正并补齐 `Git.Ignore.File`（2026-08-26）：Ignore 与 Exclude 仅对 `unstaged == untracked && staged == unchanged` 的文件显示；已有 `.gitignore` 候选按目标文件目录到 root 的祖先链收集，多个候选通过 `Ignore in…` 选择，并按所选文件目录写入相对规则；没有候选时按 IntelliJ 语义先确认，再创建/写入 root `.gitignore`。Changes 区域支持跨分组 Cmd-多选，候选取所有有候选路径的共同祖先交集，无候选路径按所选文件根过滤，并由 Rust 一次校验、批量写入规则；tracked、staged、ignored 文件不再展示误导动作。原生 action/DataContext 生命周期和 UI automation 仍为 partial。

本轮已补齐 `Git.Show.Stage` 主菜单可达性（2026-08-26）：VCS > Git 新增 `Show Staging Area`，使用当前 Git action context 做 root-aware enablement，进入现有固定双栏 Commit/Staging 工作区并退出 Shelf tab；不新增第二种 staging 模式。fork 原生 action-group/DataContext/tool-window focus 生命周期和 UI automation 仍为 partial。

本轮继续补齐（2026-08-26）：对照 fork `GitVcsOptions.resetMode`、`GitVcsSettings.rootSync` 与对应 Branch Popup 行为，Project Git Settings 现在按项目保存 Reset 默认模式（Soft/Mixed/Hard/Keep）以及 ROOT_SYNC 三态（Automatic/All roots/Selected repository）；Reset dialog 每次按当前项目恢复默认值，并在单 root 与 multi-root 确认后记住最后选择，默认保持 Mixed。Branch Popup Settings 可直接切换跨 root action scope：SYNC/NOT_DECIDED 保留同名分支、tag、remote 的跨 root 快捷动作，DONT_SYNC 隐藏这些快捷动作但保留显式多选。新增 `Arbor/ArborTests/CompareSelectionTests.swift::testResetModeSettingIsProjectScopedAndDefaultsToMixed` 与 `testRootSyncSettingIsProjectScopedAndDefaultsToNotDecided`；native GitNewResetDialog/DvcsSyncSettings/DataContext 生命周期、首次同步提示与 UI automation 仍为 partial。
本轮已补齐 Commit warning、Git identity 与 previous commit authors 主链路（2026-08-26）：Project Git Settings 按项目保存 CRLF、detached HEAD、大文件、Windows 不兼容文件名四类开关及默认 50 MB 阈值；Rust 支持阈值、选定路径范围、Git LFS root 排除和 effective Git config；提交身份缺失时可按项目选择全局 user.name/email 或 repository-local 配置，签名设置保持 local，单 root 保存后自动回到原提交动作，multi-root 失败通知提供 root-safe、可跨重启的身份设置入口；提交作者历史按项目隔离、MRU 排序并限制 16 条，可从 identity sheet 直接回填 author。单 root 与 multi-root Commit 在实际 Git 写入前统一显示 root-qualified warning，支持 CRLF 设置并提交、Commit Anyway、Cancel 与项目级 Do-not-ask。原生 workspace/DataContext/VcsNotifier 生命周期和 UI automation 仍为 partial。

本轮继续补齐 Commit warning 的 rebase 上下文（2026-08-26）：interactive rebase 不再误报 generic detached HEAD；非 interactive rebase 改为显示专用 rebase warning，并继续复用项目级 detached-head warning 设置。剩余 partial 仅包括原生 warning dialog/workspace/DataContext/VcsNotifier 生命周期及 UI automation。

本轮校正 Commit warning 的 CRLF 语义（2026-08-26）：对照 fork 的 `GitCrlfProblemsDetector`，`core.autocrlf=true/input` 时不再提示；显式 `text`、旧式 `crlf` 或 `binary` 属性声明的文件不再重复提示；属性解析失败按 fork 语义保守地不打扰用户。未改变已有项目级 warning 开关与 Commit Anyway/Cancel/设置 autocrlf 交互；原生 CRLF DialogWrapper、DataContext/VcsNotifier 生命周期和 UI automation 仍为 partial。

> 核心原则：**不是"做一个 git 客户端"，而是"用 Rust 重写 IntelliJ 的 git 能力全集"**——功能、交互模型、体验都要对齐。只是换一种语言干净地重构（拒绝 Rebased 的 fork 方式），但 IntelliJ 的 git 核心能力必须保留。
>
> 维护说明：本文档与 `DECISIONS.md`（决策记录）配套使用。改了方案先更新 `DECISIONS.md` 再改这里。
> 最后更新：2026-08-27

> 2026-08-26 对照校正：multi-root Rebase 的 Operation Log 结果树现在区分 paused root 的 partial 状态；Retry 开始前保留已完成/待处理 root 的累计结果，Rust 抛出操作级错误时重新挂回当前 session rows，首次执行不显示伪造的 pending rows。原生 VcsNotifier/DataContext/action lifecycle 和 UI automation 仍为 partial。

> 2026-08-26 对照校正：参考 fork 的 `main.toolbar.git.MergeRebase`，项目主工具栏新增 root-aware `GitMergeRebaseWidget`；在 Commit、Log、Branches 等工作区都能看到进行中的 Merge/Rebase/Cherry-pick/Revert，当前 root 可 Continue/Skip/Abort，冲突可进入 Resolve Conflicts，并可对已解决冲突执行 Revert Resolved；secondary root 先进入自身 Recovery context。原生 action-group/DataContext/VcsNotifier 生命周期和 UI automation 仍为 partial。

> 2026-08-26 对照校正：参考 `Git.Experimental.Branch.Popup.Actions`，单 root 与 multi-root Branches Popup 新增 `Commit Changes…` 顶层 action；支持动作区、speed-search、上下键/Enter 与无变更时的 disabled presentation，执行时进入现有 Commit workspace。固定 staging area 下合并 `CheckinProject` / `Git.Commit.Stage` 两个参考入口；原生 action-group/DataContext/focus lifecycle 和 UI automation 仍为 partial。

> 2026-08-26 对照校正：Git Roots 面板的 Pull All (Merge/Rebase) 现在与 Update Project 共用 preserving/update runner，统一 credential broker、取消、Fetch tag policy、Shelf/Stash 保存恢复、冲突恢复和 root-scoped retry；旧 Pull retry action 也按 root 只重试失败项。原生 VcsNotifier/DataContext 生命周期和 UI automation 仍为 partial。

> 2026-08-26 Merge rollback 结果树校正：multi-root rollback 的 expected-HEAD guarded semantic action 现在持久化每个 root 的成功/失败 `FeedbackResultRow`；Retry Remaining Rollback 携带累计 rows，只替换本轮重试 root，跨重启仍保留完整 compound result。跨 root atomic rollback 不属于 IntelliJ `GitMergeOperation` 语义；native notification/DataContext lifecycle 与 UI automation 仍为 partial。

> 2026-08-24 对照校正：Update Project 现在补齐单仓库 action-only 的 Reset to Remote Branch：仅在当前分支存在 tracked upstream 时启用，确认后先 fetch 再执行可恢复的 Smart Hard Reset；本地未提交现场按项目 Shelf/Stash 策略保存，完成通知提供 Undo/Keep。原生 UpdateOptionsDialog/DataContext/VcsNotifier 生命周期和 UI automation 仍是 partial。

> 2026-08-23 对照校正：Git Roots Pull All 已补齐按 root 捕获实际 HEAD 推进的可重启 View Commits 后置动作；失败 root 重试会合并已成功 root 的历史范围，Fetch 不伪造提交范围。

> 2026-08-23 对照校正：Merge 完成、冲突 Continue、Branches Popup root-scoped Merge 和 multi-root Merge 已补齐按真实 before/after HEAD 生成的可重启 View Commits 后置动作；未完成或无安全边界的 root fail closed，并保留 Delete/Rollback 主动作。

> 2026-08-23 对照校正：Log Revert/Cherry-pick 现在按 session 持久化 Git root 顺序、有序 commit IDs、初始 HEAD 和执行选项，旧版本单 root marker 可安全迁移；应用重启后只有最早 pending root 无活动 Git operation 且 HEAD 未漂移才显示可执行 Retry，Abort 保留安全重试，冲突 Continue 完成当前 root 后自动推进下一 root。原生通知分组、DataContext 生命周期和 UI automation 仍为 partial。

> 对照校正：IntelliJ 的多 root `Update Project` 本身按 root 顺序聚合 partial result，不做跨 root 总事务回滚；因此“跨 root 原子回滚”属于可选增强而不是 parity 缺口。本清单将重点放在 IntelliJ 实际存在的 root-scoped recovery、通知 action 和外部 merge tool 语义。

## 0. 定位与边界

| 项 | 内容 |
|---|---|
| **项目名（已定）** | **Arbor**（树的主枝干，git 主分支/主干开发隐喻） |
| **核心目标** | 完整复刻 IntelliJ 的 git 能力（功能 + 交互模型） |
| **架构（已定）** | Rust 引擎 + SwiftUI/TextKit 客户端（FFI / 进程间通信） |
| **i18n（已定）** | 最低支持中文（zh-Hans）+ 英文（en），后续可扩 zh-Hant 等 |
| **动机** | 拒绝 Rebased/IntelliJ fork 的臃肿源码树与合并包袱，要干净独立的实现 |
| **明确不做** | 不做 IDE（无补全/重构/构建）、不做 git 之外的 VCS、不做插件平台 |
| **法律基线** | v0.12 目标 MIT；发布前完成依赖许可证清单与人工/法律复核；避开 JetBrains 商标/图标/资产；Git 用 `gix` 或调用系统 git（避开 GPL 嵌入） |

## 1. 完整能力清单（按模块，标注难度/优先级）

### A. 工作区与状态 🟢
- [x] 单项目窗口模型：每个窗口只围绕一个项目
- [x] 文件夹选择器（NSOpenPanel）+ 窗口拖拽打开项目
- [x] 打开新项目时支持替换当前窗口 / 新窗口 / 取消
- [x] 最近项目入口（UserDefaults，最多 8 条）
- [x] 完整项目文件树（目录按需加载，隐藏文件显示但弱化）
- [x] Git 项目生命周期：初始化已有目录、从远程/本地 URL 克隆并自动打开
- [x] 只读文件查看：行号、tree-sitter 高亮、二进制提示、1 MiB 截断提示
- [x] 文件/目录状态着色与状态区分（modified / staged / added / deleted / conflicted / untracked；ignored 已采集并从 Changes 排除）
- [x] `.gitignore` 规则处理与展示（ignored 规则来源/行号/模式可在 Changes 中查看）
- [~] `.gitattributes` 处理与展示：Changes Diff 的 Attributes Inspector 展示 Git 实际解析的 text/eol/binary/diff/merge/filter/working-tree-encoding；普通暂存、partial staging、restore、resolve-edited、revision/worktree diff 与三层 staging diff 已按内建 text/eol/autocrlf 规则统一；branch/tree checkout 会按目标 `.gitattributes` 写入工作区行尾，并在真实 worktree 变更前预检目标转换；自定义 clean/smudge filter 与非 UTF-8 working-tree-encoding 默认关闭，显式设置后通过临时 object store + system Git 执行并受超时保护；同一显式设置现在也可在当前文件、revision↔revision、commit、rename 双 object endpoint、revision-backed Shelf、Stash、同路径和跨路径 rename 的 revision↔worktree 文件 Diff 预览中调用 `diff=<driver>` 的 textconv，跨路径 rename 使用隔离临时 index 映射旧 blob，解析 binary/textconv unified diff，并保留 Index↔Worktree 反向只读语义；隐式 external diff/merge driver 仍只读展示、不执行，显式 External Diff/External Merge 动作通过可取消的 Git process group 调用用户配置工具，raw patch/export 语义与大仓库转换缓存仍待补齐
- [x] 文件变更高亮（只读 FileContentView gutter 显示相对 HEAD 的新增/修改/删除行；编辑器实时 gutter 仍按范围决策排除）

### B. 提交 Commit 🟢
- [x] 提交面板：staged/unstaged/unversioned/ignored 分组、逐文件勾选；部分暂存文件同时呈现在 staged 与 unstaged
- [x] 提交信息编辑器：模板（commit.template）、最近提交信息、issue 链接
- [x] 提交信息 cleanup：gix/commit-tree 路径按 repository `commit.cleanup` 与 `core.commentChar` 对齐 IntelliJ 的 whitespace/scissors、verbatim、strip 语义；系统 Git 提交路径继续由 Git 原生处理
- [~] Changes 文件右键版本查看：已接入按状态显示的 Show Local Version / Show Staged Version，Staged 读取真实 Git index 并在只读查看器中按对应版本计算行变更；两侧存在时可直接切换，状态刷新后无效版本会自动切换且旧异步读取/blame 结果不会覆盖新内容；GitIndexVirtualFile、caret 转移、原生编辑器导航和 UI automation 仍待补齐
- [~] Unstash to New Branch：已对选中 Git root 的分支名做输入期 Git ref 校验，非法/已存在分支禁用提交；输入分支名时锁定 Pop 与 Restore staged state，清空后复位；失败后按 stash object id、原始 branch/HEAD 和目标分支状态提供 root-scoped 持久化 Retry；原生 DialogWrapper 焦点/help、VcsNotifier 生命周期和 UI automation 仍待补齐
- [x] **选择性/逐行暂存（partial / line-level staging）** 🟡
- [x] Amend（树=索引，父=HEAD 第一父）
- [x] hooks 执行 +「跳过 hooks」（等价 --no-verify）
- [~] 多作者提交、author/committer 分离、sign-off、GPG/SSH 签名：仓库级 signing 配置、一次性覆盖、签名验证与系统 pinentry 已接入；可选 Arbor embedded pinentry helper 仅在签名阶段的 `PINENTRY_USER_DATA` 会话令牌存在时通过短期加密 loopback session（Curve25519/AES-GCM）接管，普通 GPG 调用继续使用系统 pinentry，保留标准协议、原生安全输入与取消语义；真实 GPG signing flow、远程开发传输、原生 DialogWrapper/UI automation 仍待补齐
- [x] pre-commit / commit-msg 失败输出提示

> 2026-08-23 Commit 成功/部分成功通知新增 root-qualified `Reword Commit` semantic action；Operation Log 重载后按项目/Git root/commit id 恢复，执行前重新校验当前 HEAD，root commit 复用初始提交确认，HEAD 漂移时 fail closed。

### C. 日志与历史 🟡
- [~] **Git log 图**：分支/tag/refs 图形化、泳道连线、提交节点（单选、⌘多选、⇧范围选择、分页、右键、父子导航、分支 dashboard、highlighter、独立 Log tab、批量 squash、直接确认并执行的线性 Drop、auto-squash commit、Uncommit、Revision Browser、Copy Link、Create Tag at Commit 已接入；Changes 浏览器的 Drop/Extract Selected Changes 已接入受限线性语义，并支持已初始化 clean submodule gitlink 的路径级改写与 nested worktree 同步；脏 nested worktree、目录/全选和不安全重放 fail-closed；Log 表头列重排/调宽已接入；Root Names 列已支持持久化显隐、重排、调宽并按聚合行显示所属 Git root；Commit Signature 列已按 IntelliJ `%G?/%GS/%GF` 语义异步加载并显示验证原因；完整 LinearBek fragment、其它 dynamic/custom columns 及少量 IntelliJ 专有 action 仍 TODO） 🟡
- [~] Log Branches dashboard 的 Navigate/Filter/Select Only 选择模式：single-root 与 multi-root 均支持 root-qualified branch/remote/HEAD 选择；Cmd 多选、Shift 范围选择现在会立即驱动当前模式，Filter 排除 tag 并去重；原生 TreeSelection/DataContext/action lifecycle 与 UI automation 仍待补齐
- [x] 过滤：起始 revision（分支）、作者、日期、路径、提交信息全文（含 body）
- [~] 提交详情 + 该提交的完整 diff（workspace 内嵌目录树、changes tree + diff preview；多选提交会显示多个详情卡并聚合 Changes；Changes Browser Apply/Revert 支持同一 Git root 下跨多个 commit 及跨 root 的已选文件，按 root/commit/parent 分批执行，混合 parent 安全退回单行；Show Diff 在 preview 关闭时仍打开独立 diff，双击/Enter 与上下键导航复用同一 action；原生 ChangesView/DiffManager/DataContext 生命周期与 UI automation 仍 partial）
- [~] 历史详情（HISTORY-001）：root commit 与空 tree 完整文件 diff、merge commit 双父选择、message body/committer/签名验证状态（Good/BAD）、Changes 右键 Show History（follow renames）、log 增量分页；Show History 现在创建/复用独立 root-aware SwiftUI History tab，但原生 VCS history provider/DataContext/action lifecycle 仍待补齐
- [~] 逐文件历史（per-file history）：Changes 文件上下文菜单直接进入独立 root-aware Log History tab，按 path + follow 展示并保留 HEAD/revision 起点（HISTORY-001）；完整 FileHistorySession/action presentation 仍待补齐
- [x] 比较任意两个提交 / 分支（文件列表 + side-by-side diff）；项目文件树文件右键已提供 `Compare with Branch or Tag…`，目录右键也可打开 `Compare Directory with Branch or Tag…`，按最深匹配的所属 Git root 选择 local/remote branch 或 tag 后查看当前 worktree 的文件 diff 或目录 Changes Browser
- [~] 从日志直接操作：cherry-pick、revert、从提交建分支、checkout/reset、Uncommit、Push Up to Commit、Browse Revision；clean 与冲突恢复路径已接入，aggregate Log 的 Reset 支持每个 Git root 选择一个独立 revision，部分 action model TODO
- [~] Reflog 时间线与 log 游标分页（多 root 聚合切换时显式选择 root，独立刷新/保留选择，首屏 100 条后可加载更早记录；Rust 使用 root-scoped offset 分页，SwiftUI 追加时按稳定记录 identity 去重，刷新/切 root/异步结果受 generation 保护；行级 Checkout/Reset/Create Branch/Compare/Rebase/Cherry-pick/Revert 已接入；Reflog root 与选中行按 Log tab root-qualified 持久化，切换 root 清理旧选区，恢复 tab 时丢弃已不存在的 entry；参考 fork 没有独立 Reflog UI，故不宣称跨 root 批量恢复；native action/DataContext/VcsNotifier 生命周期与 UI automation 仍 partial）

### D. Diff 与冲突合并 ⭐ 灵魂，最高优先级
- [x] side-by-side + unified 双模式，**word-level diff** 🟡
- [x] 完整 diff 行为（DIFF-001）：attributes-aware binary、CRLF 敏感/归一化、ignore-all-space/行尾空白/word diff 设置、staged/unstaged/commit/branch/clipboard 统一数据源
- [x] 比较任意版本 / 分支 / 与剪贴板；文件级 Branch/Tag 对比保留 no-diff、binary 和 ref 缺失文件的明确反馈
- [x] **三栏冲突解决：Local │ Result(可编辑) │ Remote，逐块接受/拒绝** 🔴（SwiftUI 路线，自己从零搭）
- [x] 自动应用非冲突块（auto-apply non-conflicts）
- [~] 统一冲突工作台（CONFLICT-001）：单 root 与 Git Roots 项目级冲突树均支持冲突列表、Cmd/Shift 多选批量 Accept Ours/Theirs、四方 diff、accept ours/theirs/both、manual edit/mark resolved、reset；项目级批量动作按 root 分组并逐文件继续，部分失败会保留失败项；项目级 resolver queue 已统一 operation、普通 unmerged files 与 stash restore，并支持当前 root 的 Continue/Skip/Abort；merge/rebase 及 Arbor 日志入口的 cherry-pick/revert 冲突均可进入；二进制冲突现在使用专用面板并按原始字节提供 Accept Ours/Theirs，避免进入文本编辑器；冲突文件已可调用 Git 配置的外部 merge tool，并在退出后重扫 index stages；仓库级 mergetool 设置编辑器、运行中进程组取消/强制终止已补齐；单 root 与 multi-root 默认使用可关闭、可从操作栏或冲突通知 action 重开的非模态右侧 resolver 面板；跨 root 原子事务回滚、撤销/通知历史和更细的 toolwindow 偏好仍按 TODO 管理
- [x] Base 视图开关、空格敏感性开关
- [x] 冲突块导航（上一条/下一条）

### E. 分支管理 🟢
- [~] 创建 / 切换 / 删除 / 重命名已接入；Rename dialog 已按 IntelliJ 校验 local/remote ref 冲突、Git ref-name、单 root upstream 解除以及执行前 stale refs，解除 upstream 失败会尝试恢复旧名；本地分支删除后的 Restore 与未合并提交 View Commits 已持久化为 root-qualified semantic action，跨 Operation Log/macOS 通知重载可重建 recovery view，Restore 按精确 deleted tip/upstream 恢复并只重试失败 root；多 root Rename 部分成功也保存新 branch tip/current branch/upstream 快照并提供跨重启 Rollback/Keep Partial/Retry；Operation Log 已持久化稳定 notification display id，重启后同一 display id 更新原历史项，expire 后不复用旧 recovery 索引；完整跨 root 原生 batch action/history 与 UI automation 仍待补齐（BRANCH-001）
- [~] 从 remote-tracking 分支检出本地跟踪分支 ✅；删除远程分支 UI 已接入，单 root / multi-root / Log 多选 / tracking recovery 删除统一使用 credential broker 与可取消 Git transport，远程已消失时按 IntelliJ 语义 prune stale tracking ref，专门 SwiftUI/UI automation 集成测试与完整通知 action history 仍缺（BRANCH-001）
- [x] 分支弹出面板（近期分支、快速切换）
- [x] Log Branches Dashboard 合成 HEAD 节点：HEAD 单选动作与 HEAD+branch 双选比较按 IntelliJ 语义启用，并按 root 隔离
- [x] Branches Popup / Log Branches Dashboard 引用动作补齐：local/remote/tag 的 `Show Diff with Working Tree` 均按所属 root 打开工作区差异，local/remote 支持 `Checkout as New Branch…`，remote 支持 `Checkout and Update` / `Checkout with Rebase`，local/tag/当前分支支持按所属 root 打开 `New Working Tree…`，tag 另支持 `Merge into Current…`；Log Dashboard 多选 tag 支持 root-qualified 批量删除，并保留 Restore All / Delete on Remote 恢复入口
- [~] Branches Popup 完善（BRANCH-001）：local/remote/tag/recent 分组与 checkout Smart/Force/Cancel 已统一接入；单 root 与多 root 的 Smart Checkout、Checkout and Update、Checkout with Rebase、Rebase、Update/Pull 已按 Settings 的 IntelliJ `Shelve`/`Stash` 保存策略保留完整 local scene，包含 staged/unstaged 边界，Shelf 恢复冲突可重启后完成或回滚；Git Roots 面板已提供多 root checkout/Smart/Force/Cancel 聚合，Branches Popup 已支持多 root 按 repository 分组、独立 repository picker、flat branch list、root 定向 checkout、非当前本地分支 Update/Pull/Pull with Rebase 与 Checkout and Update/Rebase，Checkout with Rebase 已纠正为 selected branch onto current 并接入 system rebase 恢复；per-root Push 对话框、Recent/Tags/Stashes/Shelves 数据与基础动作、local/remote Compare/Merge/Fetch/Pull/Checkout/Delete、per-root remote 配置、checkout 阶段补偿回滚、普通 checkout 部分成功后的 `Rollback Successful Roots` action（精确 root target、previous branch/HEAD、checkout 后 expected branch/HEAD 和 created branch，以 semantic action 跨重启恢复且执行前安全校验），以及项目级 operation/stash/unmerged/Shelf 冲突 resolver queue 和 Continue/Skip/Abort 已补齐；Branches Popup 的显示 Recent、按 Repository 过滤、multi-root repository 分组和按 Directory 的 local/remote/recent/tag prefix tree 现在按标准化 project path 持久化并在打开时恢复，目录节点支持展开/折叠且按 section/root 隔离；unborn root 的真实 headId 现在进入 HEAD/current local branch action-update，New Branch/Checkout as New Branch/New Working Tree 按 root 保持可见但禁用；IntelliJ 的逐 root partial-result 已对齐，Update Project 失败后的 `Rollback Updated Roots` 也已持久化 expected-HEAD guarded targets，并按 deepest-first 保持 gitlink 子仓库边界；完整联合 diff、跨 root atomic transaction、完整 tree filter/action model、Log dashboard 跨 root 复用与 provider 细节仍部分完成
- [x] 多 root Checkout and Update / Checkout with Rebase 失败恢复：Git Roots 面板提供 `Retry Failed Checkout Roots`，只重跑失败 root，保留已成功 root；当 update 阶段部分成功时，反馈同时提供 expected-HEAD guarded 的 `Rollback Successful Roots`，跨重启保留 rollback semantic action，rollback 部分失败可只重试剩余 targets；在 operation 或 Shelf/Stash 恢复未完成时隐藏重试入口
- [~] 比较分支、合并分支、删除已合并分支（Merge 使用 `branch_list_merged_all` 对齐 IntelliJ `git branch --all --no-merged`，cleanup 继续使用仅本地的 `branch_list_merged`，Cleanup 表格已按 Branch/Last Commit/Tracked Branch/Merged Status 独立列对齐；多 root Cleanup/Find Merged 状态计算现在按最多 5 个 root 有界并行且保持稳定 root 顺序，target 分支在 engine/API 边界硬排除；确认对话框；Find Merged 按目标本地分支跳过无关 root，保留 root 级失败原因，支持取消后保留已完成 root，并可在独立纯文本结果编辑器中查看/选择/复制包含扫描统计/错误数/耗时的完整报告；完整通知 action/history 仍待补齐，IntelliJ VCS Log index fast/reliable comparator 仍未宣称完成；Merge 单 root 与 multi-root 对话框已支持 Automatic/FF-only/no-ff/squash、custom message、no-commit、no-verify、allow-unrelated-histories，Modify options popup 按 IntelliJ 兼容矩阵禁用冲突组合并按项目记忆，参数贯穿每个 root；干净完成或冲突解决后对非保护本地源分支按 Git Settings 的 DELETE/PROPOSE/NOTHING 策略处理，NOTHING 成功后不额外暴露 IntelliJ 没有的回滚 action；跨 root PROPOSE 已统一为一次确认、root-qualified semantic action、稳定 native/history notification 和逐 root 恢复结果；跨 root atomic rollback 与更广 notification lifecycle/UI automation 仍待补齐）
- [x] 不切换当前分支，直接从本地或 remote-tracking 分支合并到当前分支；分支行显示 configured upstream 的 `↑ ahead / ↓ behind`

### F. 远程操作 🟢
- [~] fetch / pull（Pull 现有 IntelliJ 风格 dialog，可选择 Git root、remote、remote-tracking branch，并持久化 merge/rebase strategy、no-commit 与 no-verify；项目级 `GitFetchTagsMode` 支持 Git default / prune tags / all tags / no tags；当前 root 与 selected secondary root 都按项目 Shelve/Stash 策略保存并恢复 dirty scene，冲突后 Continue/Skip/Abort 也按 root 闭环）/ push（force、单个/批量推 tag、push 对话框、rejected 分类与 Update/Publish 引导）；原生 Pull dialog/VcsNotifier 生命周期仍待补齐
- [~] Fetch action-update：对照 IntelliJ `GitFetch.update()`，Fetch、Fetch All、分支级 Fetch、Prune 与 Unshallow 在同一传输进行时保留入口但禁用；VCS 菜单、Quick Actions、Branches Popup 和直接 handler 共用 fail-closed busy guard，避免重复启动 Fetch；原生 `GitFetchSupport` 任务注册、VcsNotifier/DataContext lifecycle 与 UI automation 仍待补齐
- [~] Update Project action-update：对照 IntelliJ `AbstractCommonUpdateAction`，任意后台 VCS operation 或 multi-root runner 执行时保留 Update Project 入口但禁用；VCS 菜单、通知 handler 与 options dialog 确认后的执行入口共用 fail-closed guard，避免重复启动 Update；原生 `VcsManager.isBackgroundVcsOperationRunning`、DataContext/VcsNotifier lifecycle 与 UI automation 仍待补齐
- [~] Update Project（⌘T）现在按 IntelliJ `UpdateOptionsDialog` 先打开项目级 SwiftUI options dialog；Merge/Rebase 在确认前只保留为草稿，确认后才写入项目设置并执行；“Show this dialog next time”按项目保存；单 root 另提供 action-only 的 Reset to Remote Branch，按 tracked upstream 启用，确认后 fetch 并以项目 Shelf/Stash 策略执行可恢复的 Smart Hard Reset；单一 Pull action 进入独立 Pull dialog，可选择 root/remote/remote branch/options 并恢复默认 rebase，对 selected secondary root 使用 root-local preservation。原生 DialogWrapper/DataContext/VcsNotifier 生命周期与 UI automation 仍待补齐
- [~] Project Git Settings 现在可按 IntelliJ `GitVcsSettings.saveChangesPolicy` 为项目覆盖 Shelf/Stash 保存本地变更策略；dirty Pull/Update 与现有 Rebase/Merge/Reset/Checkout/force-pushed update runner 都读取项目策略，未覆盖时继承全局设置。原生 GitVcsSettings/DataContext 和完整 UI automation 仍待补齐
- [~] IntelliJ incoming/outgoing 自动 Fetch：全局 Git Settings 作为回退，单根/多根 Branches Popup 可进入项目级 Git Settings；项目/策略启用时立即执行第一次检查，之后默认每 20 分钟按所有 Git root/remote 执行 broker-backed、可取消的 FETCH 或 `LS_REMOTE`（对应 IntelliJ `git.update.incoming.info.time` Registry，Arbor 内部 key 为 `arbor.git.incomingCheckIntervalMinutes.v1`），FETCH 遵循项目级 `GitFetchTagsMode`；FETCH 更新 remote-tracking refs，LS_REMOTE 只检查配置 upstream 的 live remote tip 并提示未 Fetch 分支；root 初始化或 remote 枚举失败进入统一失败反馈，无 remote 的 root 保持静默；手动 Fetch 成功后的建议计数与 Do Not Ask Again 也按项目保存；本轮补齐 retry generation、root/remote 结果排序去重、项目稳定 notification ID 的应用内分组、macOS UserNotifications replacement、Fetch All/Retry/Enable/Do Not Ask Again action，Fetch All 覆盖全部 Git roots；上述四类 AutoFetch action 已用 Codable project/root/root-scope request 跨 Operation Log/macOS 通知重启恢复；完整 VcsNotifier permission/banner 生命周期与专门 timer/multi-root UI 测试仍缺
- [x] Remote 配置与高级传输（REMOTE-001）：Configure Remotes Dialog（URL/push URL/fetch+push refspec 编辑、添加/删除/重命名）、fetch all/prune/unshallow、force-with-lease（默认偏好可在 Git Settings 配置，拒绝分类 NonFastForward）、rejected push 后 update with merge/rebase 引导
- [~] Push recovery 后续动作：单 root（含嵌套 submodule）的 Update with Merge/Rebase → Push 会保留 update 前后 HEAD 的 root-qualified `View Commits` semantic action；普通当前分支 Push 也只在目标 remote 与 tracked upstream 一致时按 merge-base → local tip 提供 `View Commits`，无 upstream、不同 remote、refspec、非当前分支或无共同祖先安全省略；标准 Push 与 Commit-and-Push 的 rejected Push 现在也用稳定、可序列化的 Merge/Rebase action，并在 root/检出分支/upstream 漂移后 fail closed；点击 recovery 后复用 root-scoped Update → Push compound runner，冲突、Retry 和后续 Push 不再串到通用 Pull/Push 生命周期；Push 失败、stale-lease、Retry Push 与 Force Push Anyway 均继续携带该范围并可跨重启恢复；未前进 root 不伪造范围；完整 native VcsNotifier 生命周期、跨 root rollback/联合 diff 和 UI automation 仍待补齐
- [~] Git 安全设置：应用级 Git executable 可 Browse/Test/Save/Reset；项目 Git Settings 已支持按标准化 project path 持久化 executable override、继承/清除，Rust 按已注册 Git root 做最长匹配，并以 Repository 级运行时 scope 隔离双窗口与多 root 的 system-Git 调用；仓库级 SSH 设置可读写/清除并将 host-key policy（含 Ask）、known_hosts、identity、auth method 与 local credential helpers 编译进 system Git 配置，Git SSH Settings 显示 helper 名称与可用性，并提供只读 SSH agent 状态/身份数量探测；Ask 模式展示原生多行指纹并允许接受/拒绝，changed-host-key 会结构化分类并提供 SSH Settings 恢复入口，且持久化 prompt 认证成功的 `user@host -> publickey/password` 方式（可查看/清除）；`main`/`master`、本地正则及 Fetch 后同步的 GitHub protected-branch rules 阻止 force push；项目 Git Settings 可 override 本地保护正则与 hosted-rule 同步开关，未 override 时继承全局设置，远端规则按项目缓存且同步失败保留；GitProtectedBranchProvider 扩展和 provider 更细粒度映射仍待补齐。参考 `SSHConnectionSettings` 只要求 last-successful `user@host -> method` map，agent/helper 来源级成功观测不作为已证实的 IntelliJ 缺口
- [x] pull 使用 `branch.<local>.remote` + `branch.<local>.merge` 真解析 upstream（本地分支名可与远端不同）
- [~] pull merge 使用 fast-forward / merge-tree / 双父自动提交；Pull dialog 额外支持 ff-only/no-ff/squash/no-commit/no-verify；当前 root 与 selected secondary root 的 dirty scene 都可在成功或冲突后恢复；原生 DialogWrapper/VcsNotifier 生命周期仍待补齐
- [~] pull --rebase 复用 rebase 冲突暂停、continue、skip、abort 状态机；Pull dialog 支持显式选择 remote branch；当前 root 与 selected secondary root 的 dirty scene 都可在成功或恢复后回填；原生 Pull dialog 生命周期仍待补齐
- [x] dirty-tree pull 由 UI 编排按 Settings 的 `Shelve`/`Stash` 自动保存完整本地现场（tracked + untracked + ignored）→ pull → 三方恢复；无冲突自动合并，有冲突保留对应 Shelf/Stash 并进入 Merge Revisions；未跟踪文件不要求 Add/Commit；多 root Update/Checkout 聚合共享同一保存策略与 root-scoped recovery
- [~] 系统级 preserving process 来源覆盖：Pull、Update Project、Checkout/Checkout and Update、Rebase、Drop/Extract selected changes、Merge、Cherry-pick/Revert、Reset 与 force-pushed branch update 已接入保存→执行→恢复链路；Drop/Extract 的已初始化 clean submodule gitlink 现在按 nested repository 边界物化，脏 nested worktree 在保存前 fail-closed；Merge/Reset/Checkout/Cherry-pick/Revert/force-pushed update 已接入 affected-path Smart/Force/Cancel 决策（仅支持 Force 的操作显示 Force），按 root 保存/恢复并保留 marker；Merge 与 Reset 的 multi-root Smart retry 现在只重试实际被阻塞的 root，并保留其它 root 的逐 root 结果；soft/mixed/keep/hard Reset 都有完整 local-scene recovery snapshot，Undo/Keep 使用 expected HEAD/branch 与 post-scene CAS，semantic action 可跨重启恢复，部分 root 可独立重试且不改变用户 stash 栈；Merge 部分完成后的 rollback 现在持久化 expected-HEAD guarded targets、pending state、branch context 和 `Rollback Successful Roots` semantic action，部分失败只重试剩余 root；项目刷新后会为待恢复 apply marker 提供可执行 Resolve local changes action；force-pushed replay 失败会保留命名 backup branch，并在单 root/multi-root warning 提供 Branches 与安全删除 action；Force-Pushed UpdateSession 现在汇报 fetch 前后 upstream 的 received commit/file counts，单 root 可打开更新提交 Log，multi-root 汇总成功 root 并通过 root-qualified ranges 聚合 `View Commits` action，且语义请求可跨重启恢复。仍缺跨 root atomic rollback、更广后续 action model、native notification 生命周期与 UI automation
- [~] Commit and Push（⌥⌘K）：single-root 与 multi-root 都先完成 Commit，再按全局/项目级设置选择总是预览、仅保护分支预览或自动 Push；自动模式只在存在唯一可无歧义 remote 且当前 HEAD 附着 branch 时直接执行，多个 remote、无 remote、游离 HEAD、空仓库和 protected-only 目标回到显式 Push options；Commit 失败或 partial commit 不会启动 Push；原生 VcsPushDialog/VcsNotifier 生命周期、多 root 更深 compound rollback/post-actions 和 UI automation 仍待补齐
- [x] 无 staged 且存在 tracked 变更时提供显式 Commit All 确认；自动 stage tracked 后提交，untracked 不会被隐式纳入
- [x] 提交前检查命令列表（argv 执行、超时/输出上限、失败阻止、强制跳过）
- [~] Changes Browser staging 对比动作：文件右键已接入 Local with Staged、Staged with Local、Staged with HEAD 和 Three Versions；Local with Staged 与 Staged with Local 复用参考实现的 staged→local 坐标系，并在 hunk 上提供 Stage/Rollback，Staged with HEAD 提供 Unstage；Rust StagingEntry 已提供 HEAD/index/worktree 版本存在性，菜单按事实显示 staged addition/deletion、rename 和 unstaged-only 边界；普通 staging diff preview 已接入文件级 Stage、Unstage、Revert，以及每个 hunk 的 Stage Hunk、Unstage Hunk、Rollback Hunk；hunk rollback 保持 index 和部分暂存边界，对新增文件正确删除；逐行选择同时支持删除侧与新增侧，纯插入可直接逐行 Stage/Unstage；Local/Staged 版本查看器和 staging diff preview 会在 workspace status/index 刷新后重读，即使路径和状态枚举未变也会拒绝旧异步结果；预览仍可返回普通 preview；原生 DiffManager 完整 action lifecycle、GitIndexVirtualFile、caret 行转移、原生编辑器导航和 UI automation 仍待补齐
- [~] 内置提交检查（COMMIT-001）：Git 身份缺失/未解决冲突（阻塞 + 引导；身份支持项目级 global/local 选择，effective config 读取，单 root 自动重试与 multi-root 持久化设置 action）、previous commit authors 项目级 MRU 历史（最多 16 条，可回填 author）、detached HEAD/大文件/CRLF 混合/Windows 不兼容文件名（警告）；Git LFS root 排除；GPG/SSH signing 配置与 verification 展示；Amend/no-verify/sign-off 确认状态；失败重试不丢失 message 与选中。detached-rebase 特殊抑制及原生 workspace/DataContext/VcsNotifier/UI automation 仍 partial
- [x] GitHub PAT 凭证管理（macOS Keychain 存储、保存/清除/测试连接）
- [~] Git remote 认证代理（AUTH-001）：HTTPS username/token、SSH passphrase/password 与 host-key Ask 对话框、changed-host-key 专用失败分类/SSH Settings 恢复入口、Keychain 保存/禁用保存、取消分类为 Cancelled、错误凭证重试；clone/push/fetch/pull transport 已统一走 system Git，UI auth 入口接入 broker，Git SSH Settings 可编辑当前仓库 local credential helpers、显示 helper 可执行性，并可查看/清除 prompt 认证的 last-successful SSH method；新增只读 SSH agent 探测（socket 可达性与身份数量）；参考 fork 的 `SSHConnectionSettings` 本身只保存 last-successful map，agent/helper 来源级成功观测不作为当前基线缺口；SSH key 管理仍未纳入产品范围

### G. 交互式 Rebase 🟡
- [~] 统一进行中操作恢复 action：Merge/Rebase/Cherry-pick/Revert 的 Continue/Skip/Abort/Open Recovery 已使用 Codable project/root 请求与稳定 root notification ID；项目重开后可从 Operation Log/macOS 通知恢复，root 不匹配时只打开对应恢复工作台；VCS > Git 主菜单现在按 IntelliJ `Git.MainMenu.MergeActions`/`Git.MainMenu.RebaseActions` 暴露当前 root 的 Commit Merge、Abort、Continue、Skip，Branches Popup 仍保持 `Git.Ongoing.Rebase.Actions` 的边界；原生 action-group/DataContext/VcsNotifier 生命周期和 UI automation 仍 partial
- [~] GUI 操作：squash / reword / drop / edit / reorder（REBASE-001：todo 编辑器已接入；Log 支持单提交改写及多选 squash 预填 todo，选中初始提交的 Reword/Squash/Drop 会先显示 Continue/Cancel 并使用真正的 `rebase --root` todo，多选 Drop 已改为 IntelliJ 风格确认后直接执行线性显式 todo，并提供本地现场恢复与 expected-HEAD Undo；HEAD merge 允许 Reword 并保留双父，非 HEAD merge 的不适用改写动作按 IntelliJ 规则在菜单禁用；Log 从 merge commit 发起 rebase 时按 native 拓扑展示非 merge todo、保留 Git label/reset/merge 控制行并锁定排序，非 merge 行按 branch segment 能力开放 pick/reword/edit/drop 及安全的连续 squash/fixup，前驱被 drop 后依赖行不再暴露 squash/fixup 且执行器 fail-closed，跨控制行组合由后端拒绝；真实 merge graph 的 side-branch action 映射已覆盖，复杂 merge/root 长尾仍待补）
- [~] abort / continue；默认 first-parent rebase 跳过 merge，preserve-merges 使用原生 `--rebase-merges -i`，autosquash 可选；Rebase 对话框现在可切换非交互原生 Rebase，非交互模式保留 `--rebase-merges`、`--keep-empty`、`--update-refs`、`--autosquash` 选项语义，交互模式仍由 todo 编辑器驱动；`--root`、`--keep-empty`、`--update-refs` 已接入原生 rebase 并由 Rebase 对话框暴露，upstream/options 现在按项目持久化；dirty tracked/untracked local scene 会按 Settings 的 Shelve/Stash 策略自动保存并在成功或 edit 暂停后的 continue/abort 恢复；branch/repository selector 已使用真实 branch positional 参数；主 Rebase、Log todo 和 autosquash 入口会持久化单 root 暂停 seed，重启后可通过 semantic action 打开 recovery workbench；单 root 在 edit/conflict 暂停后 Continue 或 Stage-and-Retry 完成会生成受 expected-HEAD 保护的 Undo；多 root 已支持统一确认窗口中的 per-root 独立 todo 编辑或非交互逐 root 原生命令执行、依赖顺序执行与暂停/失败/未尝试汇总，且持久化 Resume/Retry、Continue/Skip/Abort、root-scoped Stage-and-Retry、部分完成后的 Rollback/Keep Partial 与全量成功后的 expected-HEAD 保护 Undo 已接入；preserve-merges 的 merge root 现在支持 pick/reword，同一 native branch segment 的 non-merge 行可重排，merge anchor/控制边界固定且重排后结构化动作收窄为 pick/reword/edit/drop；通知分组和更广的 merge-topology action 语义仍缺
- [~] Rebase 主 action-update：对照 IntelliJ `GitRebase.update()` 的 project-wide 状态，当前 root 或已发现 secondary root 的 rebase operation state，或 multi-root rebase session 活动时，VCS 菜单 `Rebase…` 隐藏并拒绝重复进入；若所有 root 都处于其它进行中 Git operation，则入口保留但禁用；干净仓库仍可用。state 刷新时序、原生 DataContext/action lifecycle 与 UI automation 仍待补齐
- 2026-08-25 说明：上方交互式 Rebase 历史描述中的“锁定排序”仅保留为旧记录；当前行为以本条及 parity matrix 为准：multi-root 也按 root 传递 commit identity，同一 native branch segment 可重排，merge anchor/控制边界固定，跨边界 fail-closed，重排后 squash/fixup 收窄。
- [~] Merge 主 action-update：对照 IntelliJ `GitMerge.update()` 的 project-wide 状态，当前 root 或已发现 secondary root 的 merge operation state 活动时，VCS 菜单 `Merge…` 隐藏并拒绝重复进入；若所有 root 都处于其它进行中 Git operation，则入口保留但禁用；干净 root 仍可用；分支弹窗、侧栏和 Rebase 直接入口增加当前 root operation guard。state 刷新时序、原生 DataContext/action lifecycle 与 UI automation 仍待补齐
- [x] Rebase 恢复入口补齐：单 root `Checkout with Rebase`、独立 multi-root root action 与 `Rebase Current in Root` 均持久化 root-scoped seed，暂停时提供可跨重启的 `Open Rebase Recovery`，完成/Abort/非 rebase 失败清理 seed
- [x] Pull/Update with Rebase 恢复入口补齐：暂停时持久化 root-scoped seed，并同步持久化 Pull 前精确 Shelf/Stash identity；重启后 Continue/Abort 与本地现场恢复仍走同一 root-scoped recovery，只有本地现场恢复成功才清理 marker 或提供安全 Undo
- [x] 线性 preserve-merges rebase 的 pick/drop/reword/squash/fixup/edit，以及真实 merge graph 的 pick/drop/reword/edit action 映射、同一 native branch segment 内的 non-merge row 重排、冲突暂停 → 冲突工作台解决 → continue / skip / abort（REBASE-001 + CONFLICT-001；merge anchor 与控制边界固定，跨边界或重排后的 squash/fixup 由结构化 todo 拒绝）

### H. Stash 与 Shelve 🟡
- [x] stash 全流程：存/列表/apply（保留）/pop（应用并删除）/drop
- [x] stash workspace（STASH-001）：clear、tracked/untracked/ignored 选项、show diff 预览、unstash-as 分支、外部修改后列表同步、apply 冲突进入恢复流程且 stash 保留
- [~] **shelve / unshelve（JetBrains 抽象，本地补丁存储）** ⚠️ 部分完成：创建、恢复、删除与 shelf patch 预览已有真实入口；Shelf 现在按 changelist 展开目录/文件成员，支持持久化目录分组、Cmd 多选、成员级 Unshelve/Drop，并在删除最后成员时清理 shelf；Shelf 成员排序已按 IntelliJ 文件名优先 comparator 对齐；Shelf 元数据已持久化 description、生命周期更新时间、`recycled`/`toDelete`/`deleted` 状态和 Recently Deleted 信息；整组 Unshelve 进入可恢复 recycled，部分 Unshelve 拆出独立 recycled changelist，重启读取会收敛 pending delete，UI 默认隐藏 recycled 并提供显示开关；Unshelve 对话框持久化 `Remove Applied Files from Shelf`，关闭时应用成员回收到 recycled，开启时整组/部分应用成员进入 Recently Deleted，冲突完成也保持该策略；工作区 Unshelve 默认保留 Shelf，明确 Pop 才在成功应用后消费 Shelf；项目打开立即、之后每日对所有 Git roots 协调收敛 pending delete 并清理 7 天前 Recently Deleted；删除 shelf 或删除最后一个成员会进入可跨重启恢复的 Recently Deleted，支持 Restore 与 Delete Permanently；active/Recently Deleted Shelf 的文件成员现在都可进入结构化 Base/Shelved 或 Local/Shelved View Diff，导入型 patch 明确回退 raw patch；删除通知新增可跨重启执行的 `Undo`，并恢复删除前的原始 Shelf 时间戳；多选 active Shelf 现在提供串行 Drop、逐项进度、partial failure Retry 和每个成功项的 Undo；跨 Shelf 成员 Apply/Unshelve、Drop 与 Recently Deleted 永久删除现在统一串行执行，聚合单通知、进度、失败组 Retry；active member Drop 还提供保留原始时间戳的批量 Undo；Unshelve/Pop 现在使用 parent/current worktree/shelf 三方合并，冲突写入标准 stages 并进入统一 Merge Revisions，Pop 只有完成解决后才删除 shelf；冲突应用前会持久化 worktree/index 快照，支持重启后恢复、完成或精确回滚，且回滚后保留 shelf；Git symlink、executable mode 与越界路径边界已覆盖；Shelf 已接入 Import Patches… / Export Patch…，导入以原始 patch 文件独立持久化，不要求当前 HEAD 立即匹配，Unshelve 时才做 three-way/clean apply；Changes tree -> Shelf 与 Shelf -> Changes 整组拖拽均已接线；本轮新增 `.git/arbor-changelists` 本地 Changelist，支持创建/激活/重命名/删除回 Default、成员移动和列表内拖拽，静默 Shelf 拖拽按源 Changelist 分拆，Shelf/成员可拖入具体目标 Changelist 直接 Unshelve，冲突恢复后保留目标归属；直接 Unshelve/Drop、部分成员操作和冲突完成会提供 Restore notification action，Restore 后提供反向 Drop；dirty Pull 自动保存的 Shelf/stash 恢复失败或产生恢复冲突时，FeedbackCenter、原生通知和重启后的 Operation Log 提供可执行的 `View saved changes…` 预览 action；Operation Log 现在跨重启保留安全摘要，Restore/Drop、Undo 删除与保存变更预览通过 Codable semantic action context 在历史和原生通知中可执行并按 project/root 隔离；2026-08-23 已将根 Shelf 与跨 Shelf 子文件选择提升为同一顶部 action context，并按 active/Recently Deleted 组装 Apply/Pop/Drop、Unshelve、Restore/永久删除；仍缺原生 DataContext/binary wrapper/navigatable provider、完整回收列表 action lifecycle、精细通知 display-id 分组与 UI automation（STASH-001）

> VCS > Git > `Apply Patch…` 已接入 IntelliJ `ApplyPatchAction` 的独立 direct 模式：支持 Git patch 与普通 unified patch（含多文件）、文件/hunk differentiated 选择、base directory、`-pN` 和目标 Changelist；direct apply 不创建 Shelf，clean apply 完成后清理 restore snapshot，冲突会持久化过滤后的有效 patch 与 direct 标记，进入独立 Apply Patch 冲突工作台并支持重启恢复、完成/回滚；冲突文件提供结果/只读 Patch 双栏编辑器，文件级/冲突块级动作明确区分保留本地与应用补丁；冲突工作台维护基于 `path#index` 的稳定 patch hunk 状态，支持结果或 Patch 编辑器选区驱动的 `Apply Selected Changes` / `Ignore Selected Changes`、`Apply Non-Conflicts` 与 `Previous/Next Unresolved`，操作后实时重解析剩余 hunk、同步双栏滚动并提供 Patch gutter 逐 hunk 的 Apply/Copy/Ignore 操作，显示本次会话处理数；raw patch 已生成 side-by-side/unified `FileDiff` 预览，imported patch 预览现在在隔离临时目录中按当前 worktree、base directory 和 `-pN` 试应用，再生成真实的 Local → Applied Patch 内容（无法 clean preview 时保留 raw patch fallback）；候选合并 Git index-backed path index 与 project-scoped recursive physical scan，覆盖 package descendants 中的 tracked/untracked 文件；新增文件的同分候选回退 project root；文件树会提前标出 base 缺失、目标已存在和 path-strip 越界的不可应用项；多文件 direct apply 现在按文件块返回成功/失败 partial result，普通失败块回滚、成功块保留。仍与完整 `ApplyPatchViewer` 有差异：持久化 VFS/PSI FilenameIndex、多 content-root 索引模型、原生编辑器/action lifecycle 和更细的 Recently Deleted action/notification model 仍待补齐。

> 2026-08-23 Shelf/Apply Patch 刷新边界校正：成功、批量部分成功、冲突完成和精确回滚现在统一写入 root-qualified dirty scope，再由 packed pending/in-progress/processed 生命周期消费；刷新会同步文件内容 token、staging model 和 index revision。Shelf 相对路径与导入 Patch 的绝对路径在进入刷新前做 root containment、标准化和去重，越界路径被拒绝，不会扩大 status scope。完整回收列表 action model、精确 FilenameIndex/VFS index 更新通知和原生 UI automation 仍待补齐。

> 2026-08-23 多 root Shelf 根路由校正：Commit/Shelf 工作区提供 Git root 选择器；secondary root 的 active/Recently Deleted Shelf 从所属 Repository 独立加载，Shelf raw patch、结构化文件 diff、目标 Changelist 列表均携带 root identity，并用 root/name/deleted-state stale guard 丢弃过期结果。Rename、整 Shelf Drop（含 root-scoped Undo）、Recently Deleted 整 Shelf Restore/Delete、整 Shelf Apply/Pop/Unshelve、成员级 Apply/Drop/永久删除、批量 DeleteProvider 与跨重启 Retry、target-Changelist Unshelve 对话框、Patch Import/Export、Clear Already Unshelved 已通过 selected-root mutation context 写入所属 Repository，并使用 root-scoped notification/semantic action；冲突工作台的 secondary status/完成/回滚已接线但原生 DataContext/通知生命周期仍未完全对齐，不能宣称完整 secondary Shelf parity。

> Shelf 菜单新增 `Clear Already Unshelved`，按生命周期 cutoff 永久清理 recycled Shelf；项目打开立即与每日自动生命周期维护已接入，dirty Pull 恢复失败的 `View saved changes…` 已接入，完整回收列表 action model 和细粒度通知分组仍待补齐。远程开发专属 Shelf action 按产品边界排除，见 parity matrix。

> 当前候选索引校正（2026-08-21）：`RebasedPatchFilenameIndex` 已接入 imported/direct patch 的候选生成，合并物理项目文件、Git index-backed 路径和注入的 virtual/index 路径，并统一应用 content/excluded scope；外部 VFS 事件现在经过 IntelliJ 式 packed dirty-scope 生命周期，刷新期间新事件留在 pending，处理完成后才消费下一批。仍缺的是持久化 VFS/PSI index、多 content-root 模型、完整索引更新通知，不再把“没有 FilenameIndex provider”或“dirty-scope 生命周期未接入”作为现状描述。

> Recently Deleted 已支持 Cmd 多选后批量 `Restore Selected` 与 `Delete Permanently Selected`；每个列表独立执行并保留 partial result，单项菜单继续可用。本轮又补齐逐项 `completed/total` 进度、稳定 notification ID，以及只重试失败列表的 Codable `Retry Remaining Shelf Actions`；Restore 成功项保留反向 Drop action，重启后仍可路由到同一 root。active/member Shelf 删除通知新增恢复原始日期的 `Undo` action；active Shelf 多选 Drop 现在改为一个携带 name→timestamp 映射的批量 Undo action，失败项仍可 Retry；删除列表会展开文件成员，并提供 `Unshelve Changes` / `Unshelve Changes and Remove` 与 deleted patch 预览；剩余是更完整的回收通知分组。

> Recently Deleted 文件成员现在也支持 `Delete Permanently`：当前成员或同一 deleted Shelf 的已选成员可做 path-scoped 永久删除，未选 patch chunks 保留，最后成员才清理整个 deleted Shelf；raw patch 的成员边界只解析 UTF-8 header/path，未选中的非 UTF-8 payload 原样保留；失败会生成带 root/Shelf/path 的 Codable Retry action。

> Imported patch 的新增文件在末端目录尚未创建时，会从已存在的中间目录/文件推导 IntelliJ 兼容的 repository base 与 `-pN`，避免候选退回错误的 `-p0`。

> 外部 `.gitignore`（含嵌套 ignore 文件）修改现在会让该 Git root 做完整 status refresh，确保 ignored/untracked 可见性同步；`.git/info/exclude` 已随 Git metadata 变更走同一路径。GitVFSListener 的外部 create/delete 现在支持独立的 Ask、Perform silently、Do nothing 策略，并按真实 untracked/deleted 状态执行 Add/Remove；固定 staging area 的新增路径使用空 blob index，保持 IntelliJ 的 staged + unstaged 双侧语义；watcher 通过唯一设备号+inode 配对 rename 旧/新端点，case-only move 使用与 IntelliJ 一致的 `git mv -f`；FSEvents 缺少 old endpoint 的 arbitrary-basename 文件 rename 现在会以 Git clean-filtered blob ID 做唯一一对一身份匹配并执行 Add+Remove，重复/修改/失败/不安全或无法唯一配对时进入显式 basename review 或保守处理，不自动 Remove 旧端点。结构化 dirty-scope 已区分精确文件、递归目录和 rename 父目录；root-scoped manager 现在同时维护逐文件 pending/in-progress/processed ledger，支持 pack、belongsTo、祖先路径压缩、30 项目录提升、递归父事件的嵌套 root 传播与项目切换清理；external-action ledger 现在按 root 合并 pending 事件，等待可见 refresh 完成后串行执行 status/确认/Git action，避免连续外部事件并发写入；operation recovery notice 已覆盖主 root、嵌套 root 和外部 metadata refresh，并按 root/fingerprint 去重。当前剩余是原生 VFS permission-banner、完整 action history、modified-rename similarity/provenance 和 UI automation 长尾。

> linked worktree 的 watcher 现在同时监听 worktree-specific Git directory 与 `commondir` 指向的现存 common Git directory，确保 refs/tags/branches 的外部变化不会漏掉；缺失、空值、失效路径或非目录 `commondir` 会安全回退到 worktree-specific Git directory；外部事件现在按 root 合并 scope/path/rename origin 后统一刷新，`created + modified` 保留新建语义；重叠刷新由 `RepositoryRefreshGate` 升级后续增量请求为全量，并丢弃旧 ticket 的 status、metadata 和错误；root-scoped dirty-scope manager 已补齐逐文件 pending/in-progress/processed 消费边界、pack/belongsTo、项目切换清理、祖先路径压缩、30 项目录提升与递归父事件的嵌套 root 传播；operation recovery notice 已覆盖主 root、嵌套 root 和外部 metadata refresh，并按 root/fingerprint 去重；无法唯一配对 rename 时 Git 提供权威旧路径或唯一 clean-filtered blob identity 即可执行 Add+Remove，重复/修改/失败/不安全或无法唯一配对时仅保守 Add 新端点并保留全量 refresh。

> 对照 IntelliJ `GitVFSListener` 后确认：Arbor 已实现外部文件 create/delete 按设置自动 Add/Remove，固定 staging area 的新增使用空 blob index 保留 staged + unstaged 双侧语义，且会过滤 ignored、modified 与非 tracked 删除；目录事件会展开为 status 子路径；唯一身份可证明的 rename 会同时 dirty 两端，case-only move 会保留新大小写，无法配对时保持刷新兜底。结构化 dirty-scope 已区分精确文件、递归目录和 rename 父目录，并已接入祖先压缩、目录阈值提升、嵌套 root 传播和 packed pending/in-progress/processed 消费边界。`RebasedPatchFilenameIndex` 已作为 project-scoped provider 接入 imported/direct patch 候选，并合并物理、Git index-backed 与注入的 virtual/index 路径；当前仍缺持久化 VFS/PSI index、多 content-root 和索引更新通知。

> Shelf 区已支持 Cmd 多选多个 Shelf 后统一选择目标 Changelist，并按 IntelliJ 的 `Remove Applied Files from Shelf` 策略串行 Unshelve；成功、失败与冲突分别保留，冲突恢复会继续携带目标 Changelist。批量 Apply/Pop/Unshelve 已显示逐列表进度，并在 partial/失败/冲突结果提供可跨重启恢复的 `Retry Remaining Shelves`；常规 revision-backed Shelf 已补齐对话框内 Base/Shelved 结构化 side-by-side/unified 文件预览，导入型纯 patch、binary 或缺少 base 时明确回退 raw patch；文件选择器还支持目录展开/折叠、扁平切换和 Added/Deleted/Modified/Renamed 状态图例，imported patch 已支持 base directory + 真实 `-pN` path-strip 映射（包括保留 raw `a/`/`b/` 层级的 `-p0`）、候选交集发现，以及按预期行号 ±100、最多 5 个 split hunk 的 IntelliJ 对齐上下文排序；project-scoped recursive physical scan 已覆盖 package descendants 中的 tracked/untracked 文件，新增文件的同分候选回退 project root；imported Shelf 预览现在在隔离临时目录中把当前 worktree 作为左侧内容并试应用 patch，成功时展示真实 Local → Applied Patch diff，偏移应用也能反映本地额外行，失败时保留 raw patch fallback；Shelf/raw imported/hunk apply 现在按文件块逐一尝试，先用 Git 正向/反向 check 跳过已应用片段，普通失败块回滚、成功块保留，失败成员留在 Shelf remainder 或 Recently Deleted，冲突则暂停并保留可恢复快照；binary、rename、mode-only 和不确定片段继续走原有路径；独立 Direct Apply Patch 已按文件块返回成功/失败 partial result，普通失败块回滚、成功块保留，并只将成功路径移动到目标 Changelist；仍缺 VFS dirty-scope 生命周期、精确 FilenameIndex 过滤与完整回收 action model。
> revision-backed Shelf 的 Rust 三方合并与 imported raw/hunk apply 现在复用统一 `GitProgressState`：前者在 worktree overlay/tree materialization 的真实文件循环中发布文件级进度，后者逐文件块尝试并让普通失败成员留在 remainder/Recently Deleted，冲突暂停并保留恢复快照；binary、rename 和 mode-only 仍走各自的原有 apply/冲突路径。
> 单 hunk 应用与 `Remove Applied Files from Shelf` 现在共享 Rust 选择模型：未选 hunk 保留在原 Shelf remainder，已选 hunk 才进入工作区或 Recently Deleted；binary、rename-only、mode-only 变更按文件整体选择。

> Shelf 工具栏已补齐 IntelliJ `ChangesView.UnshelveSilently`：选中一个或多个 Shelf 后可用 `Unshelve Silently` 或 `Ctrl-Alt-U`，按自动 Changelist 设置逐项归属，不弹目标选择对话框，并复用 partial/conflict recovery。Recently Deleted 也支持 exact selection 的静默 Unshelve，直接 apply deleted ref/patch 并保持正确生命周期；批量 Apply/Pop/Unshelve 的逐列表进度与跨通知 Retry Remaining action 已接入，剩余是 VFS dirty-scope 生命周期、精确 FilenameIndex 过滤与完整回收列表 action model。

> 主 Shelf 工具窗已补齐 IntelliJ `ApplyShelfAction` / `PopShelfAction`：active Shelf 行和 active 多选均可直接 `Apply (Keep)` 或 `Pop (Apply and Remove)`；多选 Pop 串行执行并保留 partial result，冲突暂停后进入同一可恢复 resolver；批量 action context 与逐列表进度已接入。Pull/Checkout/Update/Rebase 等自动保存现场使用独立 preservation Pop，即使临时 index sidecar 缺失也保持逐文件 apply、冲突快照与完成语义；普通用户 Pop 仍保留兼容入口。导入 Patch 的 base directory、按 split hunk/行号窗口上下文候选排序与真实 `-pN` path-strip（含 `-p0` raw endpoint）已贯通 Rust、UniFFI 与 SwiftUI；纯 binary patch 还会优先 project base 再按最小 strip 选择；raw imported/hunk apply 已补逐 hunk 正向/反向 check 与已应用片段跳过；剩余是 VFS dirty-scope 生命周期、精确 FilenameIndex 过滤与回收列表 action model。

> Shelf 多列表 Apply/Pop/Unshelve 现在显示逐列表进度；partial、失败或冲突结果会提供可持久化的 `Retry Remaining Shelves` semantic action，携带 project/root、Shelf 列表、操作类型、目标 Changelist 和 Remove Applied 策略，操作历史与原生通知重启后仍可恢复。revision-backed apply 的真实文件级进度已接入统一 GitProgressState；导入 Patch 的 path-strip、IntelliJ 对齐的 split-hunk 上下文候选排序、递归 package 候选发现和已应用片段跳过已接入，剩余是 VFS dirty-scope 生命周期及完整回收列表 action model。

> Shelf 文件成员右键及已选成员的 Shelf 行菜单已对齐 IntelliJ `UnshelveChangesAction` / `UnshelveChangesAndRemoveAction`：可直接 `Unshelve Changes` 保留 Shelf，或 `Unshelve Changes and Remove` 只消费已应用成员；原有 `Unshelve` 对话框仍保留文件/hunk/目标 Changelist 选择。导入 Patch 的 base/path-strip 映射、split-hunk/行号窗口上下文候选排序和已应用片段跳过已贯通，纯 binary patch 也按 project base/最小 strip 决胜；成员 Drop 的 Undo action 还会携带被删除路径并可跨重启路由；剩余差距是 VFS dirty-scope 生命周期、精确 FilenameIndex 过滤与完整回收列表 action model。远程开发专属 `ShelfRemoteActionExecutor` 按“不做插件平台”边界排除。

> 2026-08-21 状态校正：上方历史条目中仍写“VFS dirty-scope 生命周期未接入”的表述已过时。当前外部事件主刷新链已使用 IntelliJ 式 `retrieveScopes()` / `changesProcessed()`，刷新期间新事件留在 pending，并在当前批次完成后再消费；当前真实剩余集中在持久化 VFS/PSI FilenameIndex、多 content-root 索引模型、原生 ApplyPatchViewer editor/action lifecycle、完整回收列表 action model、通知/权限/banner 与 UI automation 长尾。

> 2026-08-21 Shelf action 校正：Shelves 区现在接入 SwiftUI 原生 `onDeleteCommand`，按 IntelliJ `MyShelveDeleteProvider` 的选择优先级处理整 Shelf、跨 Shelf 成员、active/recycled 与 Recently Deleted；active 删除仍可通过已有 Undo 恢复，Recently Deleted 走永久删除。仍未完全复刻的是 IntelliJ 树的数据上下文、binary wrapper/navigatable provider、原生编辑器 action lifecycle 与更细的回收通知分组。

> 2026-08-21 Shelf Rename 校正：IntelliJ 的 `RenameShelvedChangeListAction` 编辑的是 Shelf 的 user-facing description，不改稳定 list name、object id、ref 或 patch 文件。Arbor 现在用独立 `shelve_set_description` metadata API 承接弹窗 Rename，并支持 active/Recently Deleted 行的双击编辑、Enter 提交、Escape 取消和 F2；旧的 identity-rename API 保留给兼容/导入流程，不再作为主 UI Rename 语义。原生 DataContext/tree-cell-editor/action lifecycle 与 UI automation 仍为 partial。

> 2026-08-21 Apply Patch viewer 校正：Direct Apply Patch 冲突工作台现在按 IntelliJ `ApplyPatchViewer` 的动作边界处理结果或 Patch 编辑器的多 hunk 选区，`Apply Selected Changes` / `Ignore Selected Changes` 会一次处理选中的多个 change，批量动作进入统一 undo group；新增 `Local Diff`（本地冲突阶段 → 当前结果）视图；文件标记已解决前若仍有未决 patch change，会明确提供继续编辑或强制完成选择。`Reset` 之后同步重新加载 hunk 状态。仍缺的是 IntelliJ 原生 VFS/PSI FilenameIndex、多 content-root 索引以及原生 notification/banner/UI automation 细节。

> dirty Pull 的临时 stash 恢复已按 IntelliJ preserving process 收紧：通过本次唯一 message 定位 stash，不再依赖 `stash@{0}`；恢复带 `--index` 以保留 staged/unstaged 边界；空保存不会误弹出用户已有 stash；Pull 成功、远程失败、恢复冲突和手动恢复共用精确 stash identity。

> Pull 自身 merge/rebase 冲突在 Continue 完成后会自动触发本地 Shelf/stash 恢复；恢复冲突进入同一 Merge Revisions 工作台，恢复失败保留可执行的 saved-changes 预览 action，避免把 Git operation 完成误报为本地现场也已恢复。

> 2026-08-25 saved-changes action 校正：单仓库 Rebase 的取消/失败/暂停以及启动后发现的 Rebase 保存标记现在都提供 root-qualified `View saved changes…`，Rust 返回准确的 stash object id 或 Shelf name；Apply-style marker 与 Rebase marker 共用预览动作，但启动扫描只对 Apply marker 提供冲突 resolver，避免错误引导。

> 2026-08-25 Update Project rebase-over-merge 对照补齐：Rebase 更新先为每个 root fetch，再只对 `base..current` 中含实际 first-parent 树差异的 merge commit 弹出 `Merge Instead` / `Rebase Anyway` / `Cancel`；Merge Instead 仅替换命中的 root，已 fetch refs 复用于正式更新，失败 Retry 的 root 方法跨重启保留。原生 DialogWrapper/DataContext/VcsNotifier 生命周期和 UI automation 仍是 partial。

> 已补齐 IntelliJ `CREATE_CHANGELISTS_AUTOMATICALLY` 语义：设置默认关闭；开启后，无显式目标的整组/成员级 Unshelve 与 Pop 会按 Shelf description 创建或复用 Changelist，冲突恢复后继续保留归属。

### I. 撤销与回滚 🟢
- [~] revert 提交、reset 到某提交、Uncommit；Uncommit 通过 HEAD 右键执行 soft reset，支持已有/inline 新建目标 Changelist、subject suggested name/自动创建设置、非法名称校验、提交路径归属（含 rename 两端）和原提交信息恢复；aggregate Log 按选中提交路由到所属 Git root；root HEAD 已在 action-update 阶段禁用，detached HEAD、protected remote branch 阻断与 stale HEAD CAS 均已接入；成功后提供 root-qualified、expected HEAD/branch 保护的可持久化 Undo Uncommit，且只移动 ref 不重写 index/worktree；更细 chooser 键盘焦点/help 与原生通知撤销细节仍是 TODO
- [~] reset soft / mixed / hard / keep 的统一选择面板；aggregate Log 已按每个 Git root 一个 selected revision 执行，Smart/Force 只重试覆盖阻塞的 root，并按原始 root 顺序保留首轮其它成功/失败结果，rollback/action model 与原生通知生命周期仍待补齐
- [x] 从 HEAD 或指定 revision 恢复单个文件（包括已删除文件；当前 UI 默认 HEAD）

### J. 标签与子模块 🟢
- 本轮子模块 parity 校正（2026-08-25）：SubmodulePanel 对已初始化且为 clean/modified 的行提供 path-scoped `Update`；Rust 从 superproject 执行 `git submodule update --recursive -- <path>`，按项目 Stash/Shelf 策略保存并恢复递归后代的 dirty worktree，且不 Pull 或改写父仓库。每个受影响 root 写入 durable `submodule-update` apply marker，正常恢复后清理，崩溃或恢复冲突由现有启动扫描和 Git Roots conflict workbench 提供 Resolve/View 操作。未初始化、missing、conflict、unknown 行 fail-closed；native VFS/permission/banner、VcsNotifier/DataContext lifecycle 与 UI automation 仍是 partial。
- [x] 轻量 / annotated / signed tag 创建、识别、删除、推送；New Tag 支持显式 Replace existing tag，默认仍拒绝覆盖已有 tag
- [~] 子模块 status 已加载展示；add/update/sync/deinit/remove UI 已接入，SubmodulePanel 可打开初始化嵌套仓库的独立 Log、root-scoped Push dialog（remote/upstream/force/lease/credential/cancel 不复用 superproject）与 RemoteConfigDialog（URL/push URL/refspec），并可设置 `.gitmodules` branch；clone 递归初始化已有真实集成测试；这些显式操作现在统一使用 credential broker 和进程组取消；Update Project 已按 IntelliJ root 边界递归发现并按父链处理 detached submodule（最深层优先保存现场，compound 成功后统一恢复 tracked/untracked 现场，父/子失败或取消时保留 stash/Shelf 供 root-scoped recovery）；子模块自身多 root Update 的失败 Retry 现在保留父链与 submodule 后代依赖闭包，父失败与级联 skipped 在同一 project-scoped notification 中聚合；多 root Commit/Push 与 Git Roots `Push All` 已按最深层 submodule 到 superproject 排序，专用 Push 聚合使用 credential/cancel、汇总逐 root partial result，child 失败/取消会阻止父 gitlink 提前发布并提供 `Retry Failed Push Roots`；Push 失败通知已提供 root-scoped Retry，non-fast-forward 可选择该 root 的 Update with Merge/Rebase，Git Roots Push All 也提供 Merge/Rebase 后重新 Push；这些失败 root/recovery actions 现在以 Codable semantic action + stable notification ID 跨重启恢复；项目级 recovery 按 IntelliJ 语义先更新全部项目 roots，再只重新 Push rejected roots；`run_root_update_for_push_recovery` / `run_multi_root_push_recovery` 已按最深层保存并恢复父 root 与嵌套 submodule 工作区，避免 gitlink 同步覆盖子模块现场，冲突可进入 Resolve Conflicts；Changes Browser gitlink 行现可直接打开 `Submodule Changes`，查看父级旧/新 gitlink、当前 checkout、初始化/dirty 状态、嵌套提交范围和 nested file 的 rename-aware old/new diff（支持 added/deleted 空树侧与 side-by-side/unified 视图）；Update Project 失败后的 `Rollback Updated Roots` 已补齐父/子 gitlink 联合回滚、expected-HEAD 防误覆盖、独立 root stash/Shelf 边界和跨重启 semantic action；完整联合 diff、跨 root atomic transaction 与完整后续 action 编排仍是 TODO（Phase 5 子模块收口）

### L. 高级 Git 工作区 🟡

- [~] 多选远程分支删除：Branches Popup/Log dashboard 已按 remote branch 分组询问共同 local tracking branches；仅在该组所有选定 root 的远程删除成功后清理本地分支，失败/取消保留逐 root 结果，force-delete 进入 Restore All；原生通知历史与 UI automation 仍待补齐

本轮状态校正：Update Project 失败后的 `Rollback Updated Roots` 已接入。它只回滚本次实际前进且仍处于 expected HEAD/ref 的成功 root，按 deepest-first 处理子模块，并让父仓库回滚忽略已独立处理的 gitlink 工作树；semantic action 可跨重启恢复。完整联合 diff、跨 root atomic transaction 和全量 action history 仍保持 partial/TODO。

本轮又补齐 Update/Pull 的 upstream 恢复动作：多 root skipped 的 detached/no-upstream root 按所属 root 提供 `Choose Upstream` 或 `Open Branches`，submodule skip 不会生成错误的用户引导；单 root Pull 的 `NoUpstream`/失效 tracking branch 直接提供 `Choose Upstream Branch`。multi-root 选择 upstream 时会从目标 root 读取 remote-tracking branches 并显示 root 名称，不再要求手填 refspec；选择器仍保留 Arbor 的 SwiftUI/input flow，与 IntelliJ `FixTrackedBranchDialog` 的完整交互有差异。
- [x] `git worktree`：列表、创建、打开、删除、强制删除、lock/unlock、prune、分支占用提示
- [x] Git Console：argv 命令、stdout/stderr、耗时、退出码和可折叠操作历史
- [x] Phase 5 长尾
- [x] 20 个场景级黄金测试
- [x] Push All 累计结果树：Retry Failed Push Roots / Force Push Anyway 只替换失败 root，保留首轮成功 root，并将完整结果行写入可跨重启的 semantic retry action；更深的跨 root rollback、联合 diff 和复合后续编排仍按 parity matrix 保持 partial
- [~] 多 root 调度与 Phase 5 长尾：`run_multi_root_operation` / `run_multi_root_push` / `run_multi_root_update` / `run_multi_root_update_selected_with_policy` / `run_multi_root_checkout` / `run_multi_root_checkout_and_update` / `MultiRootPanel` 已具备逐 root 结果、Update Project 与 Push All 聚合、失败 root 精确 Retry、root 定向复合 checkout/update 与 Smart/Force/Cancel；Push All 按 child-first 依赖顺序执行并在 submodule 失败/取消时阻止父 gitlink 发布；普通多 root checkout 部分成功按 IntelliJ 保留已成功 root，并提供 `Rollback Successful Roots`；Branches Popup 已有真实 repository picker/flat filter、非当前本地分支 Update/Pull、root-scoped Push dialog、Recent/Tags/Stashes/Shelves 基础动作、local/remote 分支动作、per-root remote config、operation/stash/Shelf conflict workbench；Git Roots 冲突区已按 root 聚合受影响路径，支持 Cmd/Shift 跨 root 多选并批量 Accept Ours/Theirs，项目级 resolver queue 已统一多个 root 的 operation/unmerged/stash/Shelf 恢复与 Continue/Skip/Abort；临时 Update stash/Shelf 已支持重启后重新发现与 root-scoped restore；update/push/checkout-update 已按 IntelliJ 逐 root partial-result 语义执行，Update Project 通知还会汇总 commit 数并按 reason 列出 skipped roots，失败 root Retry 与 Push/Checkout-Update recovery action 已按精确 scope/策略持久化并可跨重启执行，Rebase 的 Resume/Retry/Open Recovery、Rollback/Keep Partial、expected-HEAD Undo 也已持久化为语义 action，终态反馈不会被刷新任务覆盖；仍缺这些复合动作更完整的 rollback/联合 recovery surface、部分 submodule/remote 语义和完整端到端覆盖，均按 `docs/git-parity-matrix.csv` 保持 partial/TODO，不能用一条总 checklist 误标为完成
- [x] Stash branch、unstash-as-branch、stash diff、现有 conflict resolver；顶栏 Git 快捷动作已补 `Unstash Changes…` 对话框（Apply/Pop、Restore staged state、View Diff、Drop、Clear、Create Branch），多 root Git Root chooser 与 root-scoped action 路由已接入
- [x] status 单路径增量刷新、log 游标分页和后台任务
- [x] 三层 staging 模型（IDX-001）：HEAD/index/worktree 层级状态、三类比较、stage/unstage 全部/单文件/行级、二进制与 submodule 降级标记、rename/copy 保留 `oldPath` 来源、assume-unchanged/skip-worktree/intent-to-add 明确状态、index tracker（外部 Git 修改检测）、Ignore/Exclude 入口
- [~] 持久化 status/log cache、可取消底层 Git 进程、多仓库调度：Log 已补 root-scoped 的最近一次首屏持久化快照，并按 query fingerprint、branch/remote/tag/current-HEAD 的完整 tip refs token fail-closed 校验；status 已补 root-scoped display-only 快照（含双维度 FileEntry 与 Changelist），重启先展示并在 fresh status 完成后覆盖，绝不参与 Git 操作安全判断；完整永久 VCS Log index 与更完整调度仍 partial

### K. 托管平台集成 🟡
- [x] GitHub：PR 列表/状态/打开/创建
- [x] GitHub：Issue 列表/创建
- [x] GitHub：Review 行内评论
- [x] GitHub token 认证失败引导与设置入口
- [x] GitLab / Bitbucket API（PR/Issue/评论，PAT/app password）
- [x] HostingClient 统一模型与 provider 工厂
- [x] GitHub device flow OAuth（client ID 可配置、轮询、Keychain 写入）
- [x] 429 / GitHub 403 配额耗尽重试与 remaining 配额记录

### L. IntelliJ 式工作台布局 🟢
- [x] 左侧常驻懒加载项目树，点击文件路由到主区查看
- [x] 顶部工具栏一等入口：Update / Commit / Push / Fetch
- [x] ⌘T / ⌘K / ⌘⇧K 快捷键与当前分支弹出菜单
- [~] 左侧 Commit/Stash 工具窗 + 右侧 Log 编辑器工作区 + Operations 工具窗；分支从顶部弹出，旧四 Tab 侧栏移除。与 rebased 一致的 Log 嵌入布局已接通，完整 action model 仍按 P4 跟进。
- [x] 操作日志工具窗：可查看最近 Git 操作的结果、时间、耗时和详情；跨重启保留安全摘要与 action 文案；Restore/Drop 与 dirty Pull 的 `View saved changes…` 通过 Codable semantic action context 跨重启可执行并按 project/root 隔离，其它当前 session notification actions 仍保留闭包执行
- [x] 变更、提交、文件、日志选择统一路由到主区 diff / 查看 / 详情

## 2. JetBrains 特有抽象（设计决策点 ⚠️）

| 能力 | 说明 | 建议 |
|---|---|---|
| **Changelists（变更列表）** | JetBrains 自研的分组暂存抽象，和 git staging 语义有重叠 | 砍（用 git 原生 staging） |
| **Shelving（挂起）** | 本地补丁存储，非 git 功能 | 复刻（价值高） |
| **Local History（本地历史）** | JetBrains 自己的文件快照系统，不是 git | 单独评估（成本高，可后置） |

## 3. 代码模型集成层（明确取舍 🔴）

- [x] **内联 blame/annotate gutter**：FileContentView 对当前工作区内容显示作者、commit、时间和行号；点击已提交行跳转 Log/commit detail；未提交行不伪造提交链接
- [x] **语法高亮**（tree-sitter）→ 🟢 做，通用组件
- [x] 只读工作区文件查看（文件树与内容查看器）
- [ ] **重构感知历史 / Find Usages in history** → 🔴 **砍**（需完整代码模型，收益最低）

> 原则：**砍语义层，留交互层。**

## 4. i18n（中文 + 英文，已定）

- [x] 静态用户可见字符串集中进 **String Catalog（.xcstrings）**；动态插值文案迁移留后续
- [x] Base 语言 `en`，目标语言 `zh-Hans`（后续可加 `zh-Hant`）
- [x] **Rust 引擎保持语言中立**：引擎只输出结构化数据/错误码，所有文案在 Swift 层本地化
- [x] 日期/数字用系统格式（`Date.FormatStyle` / `.formatted()`）自动本地化
- [ ] 提交信息默认模板、菜单、快捷键标题全部本地化
- [x] TextKit 合并编辑器支持中文 IME 输入、CJK 换行（`byCharWrapping`）
- [ ] 中文 UI 中 git 术语惯例：rebase/squash/stash/cherry-pick 等保留英文（参考 JetBrains 做法）
- [ ] Xcode Export/Import Localizations（.xliff）工作流验证
- [x] 建立中英**术语表**（见 [I18N_TERMS.md](./I18N_TERMS.md)）

## 5. TextKit 选型结论（调研于 2026-08-13，重要，别忘）

- **macOS 13+ 的 `NSTextView` 默认就跑在 TextKit 2 上**——"新技术"是默认值，无需选择
- **铁律：绝不碰 `NSTextView.layoutManager`**——一旦触碰会**不可逆地**降级回 TextKit 1
- **TextKit 2 适合"在 NSTextView 壳子里用"，不适合"拿它自己造文本引擎"**（STTextView 作者称 dead end；CodeEdit/Runestone 已退回自写 CoreText）
- **行号 / 逐片段着色（diff 背景）**：2027 版系统将提供 `NSTextView` viewport 委托钩子——官方路线，等它
- **逃生门**：确有功能被 TextKit 2 卡死时，用 `NSTextView(usingTextLayoutManager: false)` **显式**降回 TextKit 1
- **绝不自写文本引擎**（CodeEdit 级团队数人年的工程）
- 大文档滚动问题主要影响百万行文件，git 客户端面对的源码文件通常几十到几千行，基本踩不到

## 6. 架构与技术栈

```
┌─ Rust 引擎 ────────────────────────────┐
│  gix（git 操作）/ diff 算法 / merge 算法 │
│  输出结构化数据（JSON/事件流），语言中立   │
└──────────────┬───────────────────────┘
               │  FFI / IPC
┌──────────────▼───────────────────────┐
│  SwiftUI + TextKit 客户端               │
│  3-way 合并界面：自己从零搭（NSTextView）│
│  TextKit 2 引擎（默认）+ 2027 viewport 钩子│
│  i18n：String Catalog（en + zh-Hans）  │
└──────────────────────────────────────┘
```

**MVP 切片顺序（防范围膨胀）**：
1. 第一批：状态面板 + 提交 + side-by-side diff
2. 第二批：log 图 + 逐文件历史 + 回滚
3. 第三批：**三栏冲突合并** + stash + 分支管理
4. 第四批：交互式 rebase + 远程 + 托管集成

## 7. 风险登记

| 风险 | 应对 |
|---|---|
| 范围膨胀（"完整复刻"是巨大工程） | 严格按 MVP 切片走 |
| 三栏冲突界面最难（SwiftUI 路线已确认自建） | 放第三批，先攒引擎与 diff 基础 |
| 大仓库性能（log/diff） | 引擎增量 + 惰性加载（参考 Zed git log 分块思路） |
| 专利/商标（低概率） | 启动前专利检索；名字、图标完全自造 |
| 双语言翻译质量 | String Catalog + 术语表，git 术语保留英文 |
| 误碰 layoutManager 导致降级 TextKit 1 | 代码规范 + code review 铁律 |

## 8. 待定项

- [x] 项目命名 → **Arbor**（2026-08-13 定；曾考虑 Graft，因"贪污"次含义否决）
- [ ] GitHub 仓库名（建议 `graft`，发布前查一下是否被占用）
- [ ] 图标/视觉资产设计（完全自造，可以用"嫁接/树枝"意象）
- [ ] Rust 引擎与 Swift 的通信方式（FFI vs 子进程 IPC）具体定夺 → 已倾向 uniffi 0.32
- [ ] 许可证（v0.12 目标 MIT，待依赖审计与发布前复核）
- [ ] 是否 `git init` 纳入版本管理（防丢失/可回滚）

## 9. v0.12 发布基线

- [x] AppIcon Asset Catalog：macOS 16/32/128/256/512 的 1x/2x 资源
- [x] MIT `LICENSE`、`README.md`、`CHANGELOG.md`、`RELEASE.md`
- [x] 本地 unsigned archive / DMG / ZIP / SHA256 发布脚本，并明确不等同于公证
- [x] JSONL rolling diagnostics、日志导出、用户确认后的报告问题 URL
- [ ] Sparkle 2.x 正式 SPM 接入、EdDSA 公钥与 staging feed（需要外部密钥/依赖确认）
- [ ] Developer ID 签名、公证、staple、`spctl` 验收（需要 Apple Developer 账号）
- [ ] 真实 GitHub Release 与 Homebrew Cask tap（需要外部仓库与固定产物 URL）
- [ ] 依赖许可证逐项人工/法律复核（见 `DEPENDENCY_LICENSES.md`）

## 10. v0.13 体验重构验收

- [x] UI 侧栏四个图标 tab：状态 / 文件 / 日志 / 分支
- [x] 状态列表分为未暂存 / 未跟踪 / 已暂存 / 已忽略四组
- [x] 工具栏提供打开项目、刷新、暂存全部、提交
- [x] 空态覆盖无项目、无选择和无变更场景
- [x] Diff 内容顶部对齐，hunk 头使用紧凑 pill 样式
- [x] Design.swift 统一间距、圆角、字体和语义色 token
- [x] Settings 窗口保留诊断入口并预留 v0.14 更新检查区

## 11. v0.14 Rebased 页面级复刻进度

页面基准：本机 Rebased 实际窗口截图；功能对齐前冻结 UI 创新。

- [x] P1 主窗口：隐藏标题栏、深色顶部栏、左侧工具栏、主区、状态栏
- [x] P2 Project 工具窗：常驻左侧、目录懒加载、文件点击路由到主区
- [x] P3 Commit 工具窗：Commit/Shelf 页签、Changes 分组、勾选暂存、提交信息、Amend、Commit / Commit and Push
- [~] P4 Git Log 编辑器工作区：graph 左、changes/details 右的 nested splitter、过滤、提交详情和内嵌 diff 已接通；单选/⌘多选/⇧范围选择、详情/预览显隐与方向、引用密度、作者日期列、父子提交导航、补丁、highlighter、分支 dashboard、multi-root Log Branches 的 repository/ref-kind grouping、批量历史改写、Changes 浏览器 Drop/Extract Selected Changes（受限线性语义）、独立 Log tab 和按 tab 持久化的 Regex/Match Case 文本过滤已接入；Log 表头列重排/调宽已接入；完整 LinearBek fragment、动态列扩展、完整过滤 action model 及少量 IntelliJ 专有 action 仍 TODO
- [x] P5 状态栏：当前分支、Git 状态、变更数、仓库路径、HEAD 短 id
- [x] P6 Branches：顶部分支弹出 + 左侧 Branches 工具窗，复用 checkout / merge / rebase / stash / remote 操作；同名本地分支支持跨 root Merge 选择、冲突继续、致命失败停止及成功 root 回滚/保留部分结果
- [x] P7 顶部工具栏：Update / Commit / Push / Fetch / Refresh
- [x] P8 Merge Revisions：对话框化三栏冲突页，并在 Commit 工作区提供完成 Merge / Continue Rebase 入口
- [x] P9 Push：保留并接入现有 Push 对话框
- [~] P10 VCS 菜单：Git 子菜单入口，路由到同一套工具窗动作；已新增 Quick Git Actions…（⌘⌥Q）搜索/键盘执行面板，覆盖 Commit/Stage tracked 与 GitQuickListContentProvider 的 Git-specific actions，并按仓库状态禁用不可用项；面板使用可复用的非模态 NSPanel，不阻塞主工作区；主菜单新增 focused `ArborVCSActionContext`，按 repository/current branch/local changes/remotes/shallow/conflicts 动态禁用不适用的 Commit/Stage/Stash/Push/Pull/Fetch/Unshallow/Resolve Conflicts 动作；VCS > Git > Local Changes 现按 IntelliJ 分组提供 Show Shelf、Revert Selected Changes、Shelve、Stash、Unstash，Show Shelf 会切到 Shelf 页签，Revert 只针对当前 Commit/Stash、Diff 或 Project 选择的单个已跟踪、非冲突且存在于 HEAD 的文件，Shelf 页签激活或 Git 操作进行时禁用，Apply Patch 保持为同级入口；同时提供 Resolve Conflicts、Worktrees、Configure Remotes、Show Log、Operation Log、Git Roots、Git Console、Refresh Git State 入口；原生多选 ChangesView/DataContext 生命周期、QuickSwitchSchemeAction/provider 语义和 UI automation 仍缺
- [~] P11 Log 右键菜单：clean cherry-pick / revert / checkout / reset / compare / Uncommit / auto-squash / Push Up to Commit / Browse Revision / Copy Link，以及 Changes 浏览器 Drop/Extract Selected Changes 已有；历史改写的 merge commit 可用性已按 IntelliJ 规则约束（HEAD 仅 Reword，其他 merge 改写动作禁用），Log action context 现在按 active operation root 约束 Interactive Rebase/历史改写、按跨 root 规则约束批量 rewrite/add-to-remote，并保留 cherry-pick/revert 的跨 root 语义；日志多选的 Cherry-pick/Revert 现在按 commit.repositoryPath 分组逐 root 执行，保留 root/选择顺序，并使用各 root 自己的 remote/protected-branch 配置；冲突停止后续 root 并绑定对应 root 的恢复工作台；参考 VcsLogSingleCommitAction 的 selection-size 规则，Tag/Checkout/Interactive Rebase/单提交 rewrite/Push Up/Undo 多选禁用；从提交创建分支、提交详情 hosting permalink，以及提交行动态 Branches/Tags ref action group 现在都按 commit.repositoryPath 路由，即使 aggregate Log 也不会误用主仓库；完整 VCS Log DataContext/action-group 生命周期仍 TODO
- [x] P12 New Branch / Tag / Stash / Shelve / Settings：逐页按 Rebased 截图收敛
- [~] P12b Remote Tags：单 root 与 multi-root Branches Popup 已支持远程 tag 直接列表、认证、root-qualified 选择、partial-result 汇总、列表 object-id lease-protected 删除，以及列表/删除过程的进程组取消和取消后的批处理停止；剩余为完整非模态通知历史与 UI automation

## 12. v0.16 操作反馈与远程可见性

本轮继续补齐（2026-08-24）：Interactive Rebase 在 `edit` 暂停时现在按 IntelliJ 语义允许 Commit 工作台只执行 Amend；有冲突时仍强制进入 resolver，普通 Commit/Commit All/Push 不会绕过 operation guard。Rust Continue 会复用已 Amend 的暂停提交、保留新 message，并对当前 amended commit 的 post-Amend dirty 状态 fail-closed，避免生成重复提交或覆盖本地修改。新增 `arbor-engine/tests/rebase.rs::rebase_edit_amend_then_continue_reuses_amended_commit` 与 `ArborTests/ReflogSelectionTests.swift::testRebaseEditPauseAllowsAmendOnlyWithoutConflicts`。

- [x] FeedbackCenter：操作开始时状态栏显示 spinner + 操作名
- [x] Git Tasks：运行中的状态栏操作可进入 Operations 工具窗，显示 transport/batch 进度、同一取消句柄和最近完成操作；Fetch/Pull/Push/Update Project/Merge/Rebase/Checkout/Reset 的多 root runner 还显示当前 root 与 completed/total roots，嵌套 system-Git 结束后恢复外层 root 快照，Merge/Rebase 的 gix 阶段保持 indeterminate；详情继续复用 Operation Log，重试策略、并发队列、其它 runner 的完整 root 聚合及原生 ProgressWindow lifecycle 仍为 partial
- [x] 操作完成后状态栏保留结果，成功 toast 3 秒自动消失，warning/error 保留
- [x] toast / 状态栏提供详情入口；错误包含可执行的下一步建议
- [x] pull / push / fetch / commit / merge / rebase / stash / shelve 结果接入统一反馈通道
- [x] Rust 返回 remote-tracking refs、configured-upstream ahead/behind 和 tracking 缺失状态
- [x] Fetch/Pull 缺少 Git committer 身份时使用仅内存 fallback，不因 reflog 写入失败；Update/Fetch/Push 成功或失败都会结束全局操作状态
- [x] Log refs 按 local（橙）、tag（绿）、remote（蓝）分色
- [x] Branches popover 增加 REMOTE BRANCHES 区域；状态栏和分支行显示 ↑ahead / ↓behind；本地/远程分支均可 Merge into Current
- [x] 新增 `remote_refs.rs`、`sync_status.rs`、`pull_errors.rs` 回归测试；remote refs 覆盖无 committer 身份的 fetch
- [x] Pull/checkout/merge/rebase 物化支持文件↔目录类型变化；blob 读取统一校验对象类型，避免 tree 被当成 blob
- [x] dirty Pull 对已跟踪和未跟踪修改做三方恢复；远程覆盖未跟踪路径时自动临时保存并重试，不要求 Add/Commit；stash 恢复冲突保留 stash 并进入解决流程
- [ ] 手动验收：点击 Update / Push / Fetch，确认“进行中 → 结果”连续可见

本轮继续补齐（2026-08-24）：Reflog root、focused entry 与 selected entry IDs 现在按 `LogTabDescriptor` 持久化；切换 Reflog root 会清空旧 root 选区，恢复旧 tab/刷新时只保留当前仍存在的 entry，加载竞态不会覆盖 pending selection；新字段为 Optional，旧外部 Log tab JSON 继续可解码。专属通知、跨 root 批量恢复与完整 Reflog action model 仍 partial。

2026-08-21 FilenameIndex 生命周期校正：Apply Patch/Unshelve 的候选索引现在按 root + content/excluded scope 持久化到应用设置，记录 indexed-path revision 与物理目录 modification revision；重开对话框可复用有效快照，GitVFS packed change 事件会在刷新前失效对应 root，多个显式 content root 会合并且嵌套 root 去重。该实现是 Arbor 的轻量 project filename index，不伪装成完整 IntelliJ VFS/PSI；仍缺用户可配置的 IDE content-root/module 模型、原生 index notification/UI automation。

2026-08-22 GitVFSListener 歧义目录 rename 校正：旧端点缺失或身份冲突的目录事件现在按未改变的相对后缀生成逐文件 old/new 候选，并通过可滚动的 `Review ambiguous Git moves` 让用户明确选择；仅选中的新端点和旧端点分别遵循独立 Add/Remove 设置，未选或未匹配路径仍保守 staging。此前“无法自动 Remove 旧端点”的描述仅表示不会猜测性执行，当前实现已补齐明确确认后的 Add/Remove 闭环；剩余是原生逐文件 operation-state、VFS permission/banner、完整 action history 与 UI automation。

本轮验证（2026-08-23）：全量 Swift `xcodebuild test` 执行 412 tests、0 failures；`cargo fmt --check` 与串行 `cargo test --all-targets` 通过（仅既有明确性能门禁 ignored）；`./script/build_and_run.sh --verify` 完成 Rust release、UniFFI、Xcode build。

本轮验证（2026-08-21）：全量 `cargo test --manifest-path arbor-engine/Cargo.toml --all-targets --quiet`、全量 `xcodebuild test`、`./script/build_and_run.sh --verify` 均通过；后者完成 Rust release/UniFFI 生成、Xcode Debug build 并成功启动验证。当前 i18n audit 扫描 1071 个 literals，124 个 catalog key 仍缺失，zh-Hans 缺失 0 个；XCUITest/像素级视觉验收仍未做，不能把未直接读取到的窗口画面当作视觉证据。

本轮校正（2026-08-24）：macOS native notification permission/banner 生命周期现在通过 `UNNotificationSettings` 刷新授权与 alert 状态；用户拒绝或关闭 alert 时，状态栏提供独立的 Open Notification Settings 恢复入口，重新授权或应用重新激活后清除提示，且不改写 Git Operation Log。Quick Git Actions 的 Commit 现在与主 VCS 菜单共享 `hasLocalChanges` enablement，clean worktree 禁用、staged-only 仍可用。focused/full `xcodebuild test`、`cargo test --all-targets --quiet`、`cargo fmt --check` 与 `./script/build_and_run.sh --verify` 均通过；parity matrix 当前为 324 条数据记录，状态统计为 completed 95、verified-partial 121、partial 99、out-of-scope 9。系统原生 permission prompt/banner 的精确 UI automation、其它 tree action 的完整 native DataContext/action-group 与系统设置页驱动仍为 partial。

本轮补齐（2026-08-24）：参考 IntelliJ hosted reference action group，Log Changes Browser / File History 的文件 revision 现在提供 Browse File in Browser 与 Copy File Link；Rust permalink 支持 GitHub/GitLab/Bitbucket 的 blob 路径、HTTPS/SSH/SCP remote 和特殊字符路径安全编码，操作按 `commit.repositoryPath` 使用所属 Git root，删除文件链接自动回退到对应 parent revision。`arbor-engine/tests/hosting.rs` 两项回归测试与 Swift `testHostedFileRevisionTargetUsesParentForDeletedPaths` 通过；`xcodebuild test/build`、`cargo fmt --check` 与 `./script/build_and_run.sh --verify` 通过。多 remote 的原生 DataContext/VcsNotifier action lifecycle、编辑器行号链接和 UI automation 仍是 partial。

本轮继续补齐（2026-08-24）：Commit Details、Log 提交行和文件 revision 的 hosted reference action 现在统一按 IntelliJ 的 0/1/多 supported remote 语义展示；单 remote 直达，多 remote 展开 Open in Browser / Copy Link 子菜单，提交级与文件级都使用所属 Git root 和用户选择的 remote，不再隐式取第一个。新增 `HostingProviderTests.testHostedRemoteActionPresentationMatchesIntelliJGroupSemantics`，完整 `xcodebuild test` 通过；编辑器当前文件/行号、原生 DataContext/VcsNotifier lifecycle 与 UI automation 仍为 partial。parity matrix 当前为 325 条数据记录，状态统计为 completed 95、verified-partial 122、partial 99、out-of-scope 9。

本轮继续补齐（2026-08-24）：旧 Branches 侧栏 PR、Log 的 Open Pull Requests 与 Comment this commit 现在按 root-qualified supported remote 选择；单 remote 直达，多 remote 展开，Rust `pr_url` 支持 GitHub/GitLab/Bitbucket HTTPS/SSH/SCP、branch 特殊字符编码和非法输入 fail-closed，provider PR 列表路径也已区分。新增 `arbor-engine/tests/hosting.rs` 两项 PR URL 回归及 GitLab/Bitbucket provider URL 断言，完整 `xcodebuild test` 通过；API 创建 token/账户选择、原生 hosting DataContext/action lifecycle 与 UI automation 仍为 partial。parity matrix 当前为 326 条数据记录，状态统计为 completed 95、verified-partial 123、partial 99、out-of-scope 9。

本轮继续补齐（2026-08-24）：参考 `GitPushTagsActionGroup` 的 per-remote wrapper，Log Tags、单 root/multi-root `Push All Tags` 现在单 remote 直达、多 remote 展开选择；`pushTag`、`pushAllTags` 及 root-scoped tag push backend 在多 remote 未显式选择时 fail-closed，不再静默使用第一个 remote。新增 `testRemoteResolutionNeverFallsThroughToFirstRemote`，完整 `xcodebuild test`、`cargo test --all-targets --quiet`、`cargo fmt --check` 与 `./script/build_and_run.sh --verify` 通过。原生 action wrapper/DataContext/VcsNotifier lifecycle、完整 UI automation 与通用 Push 默认 remote 仍为 partial。parity matrix 当前为 327 条数据记录，状态统计为 completed 95、verified-partial 124、partial 99、out-of-scope 9。

本轮继续补齐（2026-08-24）：参考 `GitPushBranchAction` 先打开 `VcsPushDialog` 的语义，主工具栏 Push 不再直接执行第一个 remote，而是统一进入 `PushDialogView`；普通 Push 与 root-scoped Push 在唯一 remote 时可初始化，多个 remote 不预填且未选择时禁用确认，`doPush`/`pushInRoot` 执行层移除 first-remote fallback。完整 `xcodebuild test`、`cargo fmt --check` 与 `./script/build_and_run.sh --verify` 通过；Push dialog 的 native DataContext、target discovery、VcsNotifier lifecycle 与 UI automation 仍为 partial。parity matrix 当前为 328 条数据记录，状态统计为 completed 95、verified-partial 125、partial 99、out-of-scope 9。

本轮继续补齐（2026-08-24）：Remote 配置对话框与 root-scoped remote config 在没有明确 selection 时不再自动编辑第一个 remote；`Git.Unshallow` 的 remote 选择按参考实现改为单 remote 唯一选择、多 remote 优先当前 tracking remote 再优先 `origin`，无法安全判断时 fail-closed 并给出 FeedbackCenter 提示。新增 `testDefaultFetchRemoteUsesTrackingThenOriginWithoutGuessing`，完整 `xcodebuild test`、`cargo test --all-targets --quiet`、`cargo fmt --check` 与 `./script/build_and_run.sh --verify` 通过；原生 table/DataContext、后台通知 lifecycle 与 UI automation 仍为 partial。parity matrix 当前为 330 条数据记录，状态统计为 completed 95、verified-partial 127、partial 99、out-of-scope 9。

本轮继续补齐（2026-08-24）：单 root Remote Tags 浏览/删除不再在多 remote 时默认第一条 remote；唯一 remote 自动选择，多 remote 要求明确选择，读取和删除共享同一 remote selection。复用 `testRemoteResolutionNeverFallsThroughToFirstRemote` 的安全解析覆盖，完整 `xcodebuild test`、`cargo test --all-targets --quiet`、`cargo fmt --check` 与 `./script/build_and_run.sh --verify` 通过；原生 action/DataContext、通知 lifecycle 与 UI automation 仍为 partial。parity matrix 当前为 331 条数据记录，状态统计为 completed 95、verified-partial 128、partial 99、out-of-scope 9。

本轮继续补齐（2026-08-24）：Compare Branches 双栏比较的两侧 unique commit 行现在提供 View Details、Checkout、Reset、Create Branch、Compare、Interactive Rebase、Cherry-pick、Revert 上下文 actions，且沿用现有 root-safe Log handler；Compare 按选中 commit 的 owning root 读取当前分支，merge commit Revert 与不可用 Interactive Rebase 会禁用。`xcodebuild test` 通过；完整 IntelliJ VCS Log filter/graph/action lifecycle 与 UI automation 仍为 partial。parity matrix 当前为 332 条数据记录，状态统计为 completed 95、verified-partial 129、partial 99、out-of-scope 9。

本轮继续补齐（2026-08-24）：Compare Branches 两侧 unique-commit pane 现在分别支持 Message/Hash、Author、Since、Until、Regex、Match Case、No Merges；请求使用 revision-range log filter API，hash 按对应 range 结果过滤，日期输入严格校验，异步结果按 branch/root/filter snapshot 防 stale。比较查询不再受 500 条硬上限限制。
本轮继续补齐（2026-08-24）：Compare Branches 两侧 unique-commit pane 已接入共享 `LogGraphView`，提供 graph lanes、merge fragment 交互、Commit/Author/Date/Hash 列、双向滚动、Cmd/Shift 多选与完整 Log context action callbacks；独立 per-pane filters 和 root-safe action 路由保持不变。首屏 80 条、每侧 Load More 200 条，分页以 Rust revision cursor 从上一页末尾继续读取，Refresh 会取消旧 task 并做 generation/branch/root/filter stale guard。完整 IntelliJ permanent VCS Log manager、独立 native task lifecycle、native DataContext/action-group lifecycle 与 UI automation 仍为 partial。
本轮继续补齐（2026-08-24）：Compare Branches 的分页/刷新状态已接入双栏 LogGraphView：两侧分别维护 hasMore、loading 和 entries，单侧 Load More 不会重置另一侧；比较入口切换和 project reset 会清理旧分页状态。分页现在使用 Rust revision cursor，按上一页最后一条提交继续读取，不再重复构造整个已加载前缀，也不再受 500 条数量上限影响；仍不声称 IntelliJ `VisiblePackRefresher` 的原生生命周期。新增 620 条历史的 limit/cursor 回归测试；完整 `xcodebuild test`、`cargo test --all-targets --quiet`、`cargo fmt --check` 与 `./script/build_and_run.sh --verify` 通过。
本轮继续补齐（2026-08-24）：Compare Branches pane 生命周期现在按 first/second 完全隔离 task、request generation、loading/error/hasMore；两侧初始查询同时启动，单侧 filter/Refresh/Load More 只刷新所属 pane，一侧日期错误或请求失败不会清空另一侧，刷新一侧会保留另一侧 selection。新增 selection 保留测试；完整 `xcodebuild test`、`cargo test --all-targets --quiet`、`cargo fmt --check` 与 `./script/build_and_run.sh --verify` 通过。原生 permanent VCS Log/VisiblePackRefresher、DataContext/action-group lifecycle 和 UI automation 仍为 partial。parity matrix 当前为 336 条数据记录，状态统计为 completed 95、verified-partial 133、partial 99、out-of-scope 9。
本轮继续补齐（2026-08-24）：Compare With / Show Files Diff 新增 `Create Patch…`，按 owning Git root 用参数化 `git diff --binary --no-ext-diff` 导出选中变更；revision-to-revision、revision-to-working-tree、rename 双路径与空输出失败边界已覆盖，focused `CompareSelectionTests` 通过。完整 IntelliJ Changes Browser action/DataContext lifecycle 与 UI automation 仍为 partial；parity matrix 当前为 337 条数据记录，状态统计为 completed 95、verified-partial 134、partial 99、out-of-scope 9。
本轮继续补齐（2026-08-24）：外部 VFS 文件重命名在 watcher 缺失 old endpoint 且存在多个同 basename deleted candidates 时，现在弹出 one-to-one move review；只有用户确认的 old→new 才按独立 Add/Remove 策略执行，跳过不猜测旧端点。新增 `testExternalVCSActionPathsReconcileUnpairedRenamesWithoutGuessing` 覆盖多候选路径，focused Xcode 测试通过；native VFS operation-state、permission/banner、action history 与 UI automation 仍为 partial。parity matrix 当前为 338 条数据记录，状态统计为 completed 95、verified-partial 135、partial 99、out-of-scope 9。
本轮继续补齐（2026-08-24）：Log Changes Browser 的 Drop/Extract Selected Changes 现在按 IntelliJ `commit~1` 语义支持 first-parent merge target；Drop 保留 merge 的全部 parents 并重放线性 descendants，Extract 保留改写后的 merge 后再生成完整树的新消息提交；second-parent/混合 parent 视图、目标后的 merge descendant、gitlink、全选仍 fail-closed。新增 `drop_selected_changes_preserves_merge_target_parents_and_replays_descendants`、`extract_selected_changes_preserves_merge_target_before_new_commit` 与 first-parent Swift gate 测试；完整 `xcodebuild test`、`cargo test --all-targets --quiet`、`cargo fmt --check` 和 `./script/build_and_run.sh --verify` 均通过。native Merge Dialog/VcsNotifier lifecycle 与 UI automation 仍为 partial；parity matrix 当前为 339 条数据记录，状态统计为 completed 95、verified-partial 136、partial 99、out-of-scope 9。
本轮继续补齐（2026-08-24）：Drop/Extract Selected Changes 的对象级重写现在从线性 first-parent 重放扩展为后继 DAG 重放；目标后的 merge descendants 保留全部原始 parents，并按 first-parent patch 应用到重写后的 parent tree，无法安全应用时 fail-closed。新增 Drop/Extract merge-descendant topology 回归；`cargo test --test log_selected_changes`、`xcodebuild test` focused/full、`cargo fmt --check` 与 `./script/build_and_run.sh --verify` 均通过。submodule/all-selected、真实冲突恢复工作台、native VcsNotifier lifecycle 与 UI automation 仍为 partial；parity matrix 当前为 339 条数据记录，状态统计为 completed 95、verified-partial 136、partial 99、out-of-scope 9。

本轮继续补齐（2026-08-24）：Drop/Extract Selected Changes 成功后的完成态现在提供 root-qualified、可跨重启恢复的 `Undo Selected Changes` semantic action；Undo 执行前校验 Git operation state、精确 HEAD、symbolic branch 与 protected remote，并按项目 Stash/Shelf 策略保存本地现场后用 `reset --keep` 恢复原始历史。新增 Rust 的 tip/本地 index 场景与 stale HEAD 拒绝回归、Swift semantic action round-trip 测试；`cargo test --test log_selected_changes`、`cargo fmt --check`、UniFFI regeneration 与 `./script/build_and_run.sh --verify` 已通过。submodule/all-selected、恢复冲突对话框、native VcsNotifier/DataContext lifecycle 与 UI automation 仍为 partial；parity matrix 当前为 346 条数据记录，状态统计为 completed 94、verified-partial 149、partial 94、out-of-scope 9。
本轮继续补齐（2026-08-24）：外部 VFS 文件重命名在 watcher 缺失 old endpoint 且存在多个同 basename deleted candidates 时，现在弹出 one-to-one move review；只有用户确认的 old→new 才按独立 Add/Remove 策略执行，跳过不猜测旧端点。新增 `testExternalVCSActionPathsReconcileUnpairedRenamesWithoutGuessing` 覆盖多候选路径，focused Xcode 测试通过；native VFS operation-state、permission/banner、action history 与 UI automation 仍为 partial。

本轮继续补齐（2026-08-24）：Merge/Rebase/Cherry-pick/Revert 恢复栏与跨重启 semantic Abort action 现在统一先显示 operation/repository warning confirmation，再执行 abort；四类 operation 的 confirmation 文案映射由 `OperationRecoveryTests.testOperationAbortConfirmationNamesEveryGitOperation` 覆盖。原生 VcsNotifier/DataContext、permission/banner 与 UI automation 仍为 partial。

本轮继续补齐（2026-08-24）：File History 的 follow 算法现在覆盖编辑后 rename 与 merge parent 路径传播；不同 parent 保留各自路径状态，分页在 cursor 前重放状态，避免历史在 rename 或分页处截断。新增 `arbor-engine/tests/history.rs` 三项回归并通过 `cargo test --test history --quiet`；Show History 现在创建/复用独立 root-aware SwiftUI History tab，完整 native VCS history provider/action lifecycle 与 UI automation 仍为 partial。

本轮继续补齐（2026-08-24）：普通 File History 入口现在显式从 `HEAD` 开始，避免路径过滤误纳入未合并 branch refs；Show History for Revision 继续以选中 revision 为起点。普通 Log 入口和用户手动 revision filter 不受影响；全量 Rust/Swift/build verify 已通过。

本轮继续补齐（2026-08-24）：File History 入口现在创建/复用独立 root-aware SwiftUI History tab，持久化路径、起始 revision、follow 与所属 Git root；切换 tab 不会把 nested repository 的历史查询回落到 primary root。新增 `testFileHistoryLogTabIsRootQualifiedAndStartsAtRequestedRevision` 与旧 external tab 缺字段兼容性回归；`xcodebuild test`、`cargo test --all-targets --quiet`、`cargo fmt --check` 和 `./script/build_and_run.sh --verify` 均通过。完整 native VCS history provider/DataContext/action lifecycle 与 UI automation 仍为 partial；parity matrix 当前为 345 条数据记录，状态统计为 completed 94、verified-partial 148、partial 94、out-of-scope 9。

本轮继续补齐（2026-08-24）：多 root Push 及 Update with Merge/Rebase recovery 现在持久化并合并 root-qualified View Commits 范围；部分成功后的 Retry 会保留先前成功 root 的旧边界，并把后续成功 root 追加到同一 Operation Log action，跨重启仍可恢复。跨 root rollback、联合 diff、完整 native notification lifecycle 与 UI automation 仍为 partial。

本轮继续补齐（2026-08-24）：对照 GitCreateNewBranchAction 的 fresh/unborn 更新规则，Branches Popup 的单 root 与 multi-root 顶层 New Branch… 以及 Action 搜索节点现在保持可见但在无 HEAD 时禁用，并显示“必须先完成 initial commit”的原因；禁用项不会进入上下键/Enter 候选，Checkout Tag or Revision… 不受影响。原生 action-group/DataContext lifecycle 与 UI automation 仍为 partial。

本轮继续补齐（2026-08-24）：对照 `GitBranchesTreeMultiRepoFilteringModel`，multi-root Branches Popup 的 `Filter by Repository` 现在把仓库短名与 project-relative path 加入 speed-search 结果，支持最佳匹配、上下键与 Enter；点击或 Enter 仓库节点会进入对应 root-scoped 过滤，顶部可清除范围。新增 repository search/keyboard 回归；原生 nested repository popup、DataContext/action lifecycle 与 UI automation 仍为 partial。

本轮继续补齐（2026-08-25）：对照 `GitCompareWithBranchAction` 与 `GitShowDiffWithRefAction`，单 root Branches Popup 的 `Compare with Current…` 现在进入提交历史双栏比较，`Show Diff with Working Tree` 保持 reference-vs-working-tree 文件差异；修复此前将前者误路由到文件级 Diff 的交互语义错位。原生 VCS Log/Changes Browser action lifecycle 与 UI automation 仍为 partial。

本轮继续补齐（2026-08-26）：Log Changes Browser 目录选择 parity：对照 IntelliJ Changes Browser 的目录节点选择展开语义，目录行现在可直接选中其全部可见叶子变更；普通点击替换选择，Command 对整组增删，Shift 按可见行范围选择并包含该组，并显示全选/部分选中状态，Drop/Extract 会沿用展开后的文件路径执行。all-selected、脏/未初始化 nested worktree、无法安全重放的冲突以及 native Changes Browser/DataContext/VcsNotifier/UI automation 仍保持 partial；新增 `ArborTests/CompareSelectionTests.swift::testLogChangeDirectorySelectionReplacesAndTogglesTheWholeGroup`，focused `CompareSelectionTests` 执行 323 tests、0 failures。

本轮继续补齐（2026-08-26）：对照 `GitLogDiffHandler.showDiffWithLocal`、`GitBranchesUIHandler` 与 `GitCompareBranchesFilesManager`，Log、Reflog 以及 Compare Branches 两侧提交行的 `Compare with Current…` 现在使用“选中 revision ↔ 当前 Working Tree”语义，保留当前 Log 上下文并打开/复用 root-qualified 独立 file-diff tab；Compare Branches 与 Show Files Diff 仍保持历史比较和文件比较两种独立交互。新增 `ArborTests/CompareSelectionTests.swift::testLogCommitComparisonUsesSelectedRevisionAgainstWorkingTree`，focused/full Swift、Rust 全量与 build/run 均通过；IntelliJ 原生 CompareWithLocalDialog/Changes Browser/VcsLogFile/DataContext 生命周期和 UI automation 仍为 partial。

本轮继续补齐（2026-08-26）：对照 fork 的 `ShelveChangesManager.State.myRemoveFilesFromShelf`，`Remove Applied Files from Shelf` 现在按标准化 project path 持久化；普通 Unshelve、静默 Unshelve、Recently Deleted 和目标 Changelist 路径都读取当前项目值，旧全局 key 不再泄漏。新增 `ArborTests/CompareSelectionTests.swift::testShelfRemoveAppliedSettingIsProjectScoped`；native Shelf/DataContext/VcsNotifier 生命周期与 UI automation 仍为 partial。

本轮继续补齐（2026-08-26）：对照 fork `GitVcsSettings` 的 `isAddSuffixToCherryPicksOfPublishedCommits`，Project Git Settings 现在支持按项目覆盖已发布提交 Cherry-pick suffix；Log/Recovery 操作捕获有效值，未设置项目 override 时继承应用级设置。新增 `ArborTests/CompareSelectionTests.swift::testCherryPickPublishedSuffixSettingIsProjectScopedWithGlobalFallback`；native GitVcsSettings workspace component、VcsNotifier/DataContext 生命周期与 UI automation 仍为 partial。
本轮继续补齐（2026-08-26）：对照 fork `GitVcsOptions.pushTags`，Project Git Settings 现在支持按项目保存 Push tags 默认模式（All tags / Current Branch）；单 root、多 root、submodule Push 对话框统一读取，单次操作仍可关闭。新增 `ArborTests/CompareSelectionTests.swift::testPushTagModeSettingIsProjectScopedAndDefaultsToOff`；native PushOptionsPanel/DataContext/VcsNotifier 生命周期与 UI automation 仍为 partial。
本轮继续补齐（2026-08-26）：对照 fork `GitVcsOptions.isPushAutoUpdate`，Project Git Settings 现在支持当前分支 Push 被 non-fast-forward 拒绝时按项目 Update method 自动 Merge/Rebase 后重试；force/custom refspec/非当前分支/无 upstream/force-with-lease 仍不自动更新，单 root、root-scoped、multi-root 统一走安全资格判断。新增 `ArborTests/CompareSelectionTests.swift::testPushAutoUpdateSettingIsProjectScopedAndGuarded`；native GitPushOperation dialog、do-not-ask、local-history 与 UI automation 仍为 partial。
本轮继续补齐（2026-08-26）：对照 fork `GitVcsOptions.isSignOffCommit` 与 `GitCommitOptions`，Project Git Settings 现在按项目保存 `Signed-off-by` 默认值，单 root 与 multi-root Commit dialog 在项目切换时重新读取；无项目 override 时兼容既有全局 identity 设置。新增 `ArborTests/CompareSelectionTests.swift::testSignOffCommitSettingIsProjectScopedWithGlobalFallback`；native GitVcsSettings/CommitOptionsPanel/DataContext 生命周期与 UI automation 仍为 partial。
