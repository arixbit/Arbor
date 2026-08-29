# 范围决策记录 -- Arbor 对等 IntelliJ Git

> 交付物:Phase 0(git-parity matrix)配套决策清单。每个决策点给出可选项、当前建议与依据。
> "执行计划 1.2" 指 `INTELLIJ_GIT_PARITY_EXECUTION_PLAN.md` §1.2《明确不在范围内》,其原文排除项为:
> 1. IDE 代码补全、重构、构建、运行配置;2. Git 之外的 VCS;3. IntelliJ 插件平台和插件扩展机制;
> 4. 依赖完整代码模型的 Find Usages、重构感知历史;5. IntelliJ Local History(除非后续产品决策纳入)。

---

## 决策 1:Local History(本地历史)

- **决策点**:是否实现 IntelliJ Local History(独立于 Git 的文件快照/回滚)。
- **可选项**:A. 完全不做;B. 做"基于 reflog + 暂存快照"的轻量替代;C. 完整复刻。
- **当前建议**:A(默认不做)。git4idea 中 Local History 属平台能力(`intellij.platform.lvcs.impl` 依赖),不是 Git 插件动作;执行计划 1.2 第 5 条已明确排除,仅在产品决策后纳入。
- **依据**:执行计划 1.2 第 5 条。Arbor 已有 reflog 视图(`reflog()`,tests/reflog.rs)覆盖 Git 层面的"误操作找回"。

## 决策 2:Shelve 与 Stash 的关系

- **决策点**:git4idea 的 Shelve 是 IDE 私有 patch 机制(平台 `ChangesView.Shelve`/`Vcs.Show.Shelf`),与 git stash 并存。Arbor 已自研 `shelve()/shelve_unshelve()/shelve_pop()/shelve_drop()`(refs 实现,tests/shelve.rs)。需决定二者关系与 UI 形态。
- **可选项**:A. 保留双轨(IntelliJ 模式:shelve=路径级/stash=全量);B. 只留 stash(shelve 降级为"按路径 stash"的一种交互);C. 只留 shelve。
- **当前建议**:A。`RebasedCommitWorkspace` 已接入 Shelves 的 Preview/Unshelve/Drop，Preview 使用 shelf commit 的结构化 `FileDiff` 并支持 side-by-side/unified；Unshelve 对话框持久化 `Remove Applied Files from Shelf` 策略，默认保留并回收 Shelf，开启后把已应用成员移入 Recently Deleted，整组/部分及冲突完成路径一致；工作区 Unshelve 与明确 Pop 分开，Pop 在完成解决后才消费 shelf；冲突使用 parent/current worktree/shelf 三方合并并复用统一冲突工作台，应用前持久化 worktree/index 快照，支持重启后完成或精确回滚并保留 shelf；删除 shelf 或删除最后成员会进入可恢复的 Recently Deleted，并提供 Restore/Delete Permanently；Shelf 已持久化 `recycled`/`toDelete`/`deleted` 状态，重启读取可收敛 pending delete，UI 默认隐藏 recycled 并提供显示开关；Changes Browser 已有独立 local Changelist 的分组、路径归属和列表拖拽，Shelf 成员也可跨列表移动；Shelf 成员排序已按 IntelliJ 文件名优先 comparator 对齐；仍缺系统自动回收触发、完整回收 action model 和更细恢复/通知语义，继续按 partial 管理。
- **依据**:执行计划 1.3 已把 shelve 列入"已有较宽原语覆盖";差距只在 UI 接线(P1)。
- **子决策 2a:Stash 是否含 untracked 选项**。已落地：`RebasedStashDialog` 提供 Include untracked / Include ignored 复选框，统一调用 `stash_save_with_options`；pull/Update 的自动保护仍显式包含 untracked/ignored。
- **子决策 2b:按路径 stash(`Git.Stage.Stash.Files`)**。已补齐 `stash_save_paths(message, paths, include_untracked)`：Commit/Stash 变更文件右键打开可多选的 `RebasedStashFilesDialog`，默认勾选触发文件；tracked 的 staged/unstaged 现场与选中的 untracked 文件进入标准 Git stash，未选中路径保持在工作区。Shelve 仍保留为独立的命名 patch 双轨，不再作为 stash 的降级替代。
- **子决策 2c:dirty-change 保存策略**。参考 IntelliJ `GitVcsOptions.saveChangesPolicy`，Arbor Settings 默认 `Shelve`，可切换 `Stash`。单 root 与多 root 的 Pull/Update、Checkout and Update、Checkout with Rebase、Rebase 和 Smart Checkout 均传递该策略；临时 Shelf 额外持久化保存前的 index entries，恢复时保留 staged/unstaged 边界；Shelf 恢复使用持久化 `arbor-shelve-restore`，项目级 resolver 与重启恢复均可继续完成或回滚。旧 rebase 临时裸 stash id 仍兼容。跨 root 仍按 root 独立保存/恢复，不引入参考实现没有的原子事务回滚。

## 决策 3:多 Git Root / 嵌套仓库

- **决策点**:git4idea 支持一个项目多仓库(分支弹窗按仓库过滤 `git.branches.popup.filter.by.repository`、日志分支面板按仓库分组等)。Arbor 仍以当前 root 作为主工作区上下文，但已在项目级入口提供多 root 聚合视图，不再把每个 root 的分支状态隐式合并。
- **可选项**:A. 单仓库模型,多仓库用多窗口/worktree 承接;B. 引入多 root 聚合(Update Project 聚合拉取、分支弹窗按 root 分组)。
- **当前状态**:采用 B 的有限落地：`MultiRootPanel` 已提供 Git Roots 发现、逐 root 状态、fetch/pull/push/commit 和 checkout 聚合；checkout 支持 Normal/Smart/Force/Cancel，Smart 跨 root 按 Settings 保存并逐 root 恢复现场，operation root 行已有 Continue/Skip/Abort。Branches Popup 已增加 `GitRootBranchSnapshot` 数据源，支持按 root 分组、独立 repository picker/flat filter、非当前本地分支 Update/Pull/Pull with Rebase、root-scoped Push dialog、Recent/Tags/Stashes/Shelves 数据和 root 定向 checkout；local/remote 分支的 Compare/Merge/Fetch/Pull/Checkout/Delete 及 root-specific stash/Shelf 冲突三栏工作台也已接入。`Vcs.UpdateProject`（⌘T）在多 root 项目中自动逐 root 更新 configured upstream，并按策略处理 dirty Shelf/Stash、认证、取消和逐 root 结果；Git Roots 冲突区现在按 root 聚合受影响路径，支持 Cmd/Shift 跨 root 多选批量 Accept Ours/Theirs，路径入口会路由到对应 root 的三栏工作台；Update 进入冲突后可按 root 打开三栏工作台，继续/跳过/终止后恢复临时 Shelf/Stash，Shelf 恢复冲突也能完成或回滚。临时保存以 root snapshot、Git stash 栈或命名 Shelf 作为持久化恢复记录，重启后刷新 Git Roots 会重新发现它，并在无进行中操作时提供 root-scoped Restore。参考 `GitUpdateProcess` 的顺序执行与逐 root 汇总语义，Arbor 不把非参考的跨 root 事务回滚列为 parity 要求；仍保持 partial 的原因是尚未实现更完整的跨 root action surface、通知语义和 IntelliJ provider 扩展。
- **依据**:git4idea 的 `GitBrancher`/`GitCheckoutOperation` 以 repositories 集合执行 checkout，并按 root 汇总受影响变更与失败结果；`GitUpdateProcess` 对所有 roots 顺序执行并逐 root 汇总。Arbor 已复刻数据边界、基本聚合调度、受影响路径索引和恢复保护；剩余入口需要完整的跨 root action model、统一 resolver/事务语义与 provider 扩展，不能由单仓库窗口状态隐式替代。

## 决策 4:Merge 高级选项与 preserve-merges rebase

- **决策点**:(a) git4idea Merge 对话框有 no-fast-forward / squash 选项,Arbor `merge()` 无参数;(b) `RebasedRebaseDialog` 有 "Preserve merge commits" 开关(引擎 `rebase_with_options(preserve_merges)`,tests/rebase_merges.rs),需确认默认值与命名。
- **可选项**:(a) A. 不加选项(走 fast-forward 默认);B. 对话框加 no-ff/squash 复选框。(b) A. 默认关闭(对齐 git 默认 --rebase-merges=no-rebase-cousins 语义由引擎定);B. 默认开启。
- **当前状态**:(a) 单 root 与 multi-root 的 GitMergeOption 核心集合已落地：Merge 对话框提供 Automatic（fast-forward 优先）、Fast-forward only、No fast-forward、Squash，以及 commit message、no-commit、no-verify、allow-unrelated-histories；`Modify options…` popup 按 IntelliJ 兼容矩阵禁用冲突组合，按项目记忆策略与选项，并将同一参数集传给每个 root；引擎持久化 merge mode/options，完成步骤分别创建双父或单父提交，并覆盖 fast-forward / already-up-to-date / diverged / conflict；multi-root PROPOSE 已统一一次 root-qualified 删除确认，rollback semantic action 和逐 root result tree 也已持久化。剩余差异是 native notification/DataContext 生命周期与 UI automation；跨 root atomic rollback 不属于 git4idea 的交互语义。(b) A(默认关闭),与 git4idea 交互一致。
- **依据**:执行计划 §1 验收口径第 2 条"操作的参数、默认值、确认流程与 IntelliJ Git 一致"。preserve-merges 已有实现与测试,决策仅在默认值。

## 决策 5:Staging Area 开关与"无 staged 时提交全部"

- **决策点**:git4idea 允许启用/禁用 staging area 视图(`Git.Stage.Enable/Disable`),并有 "ToggleCommitAll"(无 staged 时提交全部)。Arbor 固定双栏(staged-only 提交语义)。
- **可选项**:A. 固定双栏 + 恒 staged-only;B. 提供简化(单栏 changelist)模式切换;C. staged-only 但空 staged 时提示"是否 stage 全部再提交"。
- **当前状态**:A + C 已落地：保持双栏和 staged-only 默认语义；无 staged 且存在 tracked 变更时，Commit 工具窗显示显式 `Commit All` 确认路径，自动调用 `stage_tracked` 后提交，untracked 文件不会被隐式加入。不做模式切换；`Git.Stage.Enable/Disable` 在 CSV 中标 out-of-scope。
- **依据**:执行计划 1.2 第 3 条排除插件化/平台机制;staging 双栏是 Arbor 既定交互(现状 UI 即如此),保留单一模型降低维护面。

## 决策 6:冲突解决交互模型(模态对话框 vs 工具窗)

- **决策点**:git4idea 新版提供独立 conflicts 工具窗(registry `git.merge.conflicts.toolwindow`,默认 false 即对话框)。Arbor 用模态 sheet `MergeRevisionsDialogView`。
- **可选项**:A. 保持模态对话框(强制解决完再继续);B. 非模态工具窗(可暂时搁置冲突)。
- **当前建议**:A(模态)。与引擎的 merge/rebase 暂停状态机耦合最简单,且 IntelliJ 默认也是对话框模式。
- **依据**:执行计划 §1 验收第 3 条要求"冲突和中断状态都有可恢复的交互";模态可防止用户在未完成状态下误操作,后续若做 B 再评估。

## 决策 7:Smart Checkout(未提交变更时切换分支的引导)

- **决策点**:git4idea 切换分支遇未提交变更时展示受影响路径，并提供 Smart Checkout、Force Checkout、Cancel；Smart 路径是 stash → checkout → unstash，恢复冲突时保留现场并进入冲突工作台。
- **当前状态**:本地分支、Recent、remote-tracking 分支建本地分支、tag/detached revision 都复用三路交互。普通 checkout 仍是安全默认；Smart Checkout、Checkout and Update、Checkout with Rebase 按 Settings 中的 `Shelve`/`Stash` 保存完整 tracked/untracked/ignored 现场，恢复冲突进入统一工作台，临时 Shelf 的完成/回滚和 rebase marker 清理均已持久化；Force 只由确认后的 Force 按钮调用。Checkout with Rebase 仍按 IntelliJ 语义执行 `git rebase --autostash HEAD <selected-branch>` 的 native rebase 状态，但 local scene 由 Arbor policy-aware wrapper 管理。
- **边界**:Git Roots 面板和 multi-root Branches Popup 已做 root 级结果/分组/定向 checkout；复合 checkout/update 已支持 selected root/all roots、checkout 阶段 Normal/Smart 补偿回滚，以及 update 进入 merge/rebase 后保留 root 独立恢复状态。多 root roots 引擎现在共享单 root 的 Shelf/Stash policy、命名引用与 staged/unstaged 边界恢复；Shelf 冲突通过项目级 resolver 的 Complete/Abort 和重启后 root-scoped discovery 处理。跨 root 原子事务/统一回滚、完整跨 root 通知聚合，以及部分 submodule/remote 语义仍有差距。Update 已按 IntelliJ 的逐 root partial-result 语义保留已完成 root，不额外引入参考实现没有的事务级自动回滚。
- **依据**:执行计划 §1 验收第 3 条"失败、取消……都有可恢复的交互"；`tests/branch_workspace.rs` 覆盖自动恢复、恢复冲突、强制覆盖和无效目标回滚。

## 决策 8:保护分支与 force-with-lease

- **决策点**:git4idea 有 protected branches 配置(`Git4Idea.gitProtectedBranchProvider` 扩展点)且 push 默认 force-with-lease(registry 默认 true)。Arbor 保留显式 force 选择，并将 lease 默认值持久化到应用级 Git Settings。
- **可选项**:A. 不做保护,force 需手动勾选即可;B. 实现 --force-with-lease 默认 + 可配置保护分支列表;C. 仅 force-with-lease。
- **当前状态**:已实现高频安全面。Push 对话框和操作层默认保护 `main`/`master`，Settings 可编辑逐行正则，custom refspec 也检查目标分支；force 仍要求显式勾选，且默认走 `--force-with-lease`。Log 单提交/多提交历史改写现在也会检查提交是否仍在当前 HEAD 线、是否已发布到受保护 remote；HEAD 的初始提交先显示警告。用户可在 Settings 关闭默认 lease，或在当前 Push 对话框为单次操作关闭；普通 push 永不自动变为 force。Fetch 成功后 GitHub provider 通过 GraphQL 分页读取 branch protection mask，按 IntelliJ `PatternUtil.convertToRegex` 规则转换并作为额外保护合并；远端规则按项目路径缓存，API 失败时保留最后已知规则，不能因网络问题削弱保护。与 IntelliJ 的 provider 扩展点、多 remote/root 聚合和非 GitHub provider discovery 仍有差距。
- **依据**:执行计划 §1 验收第 1 条 P0 定义"可能导致用户无法恢复、结果错误"——裸 force 覆盖远端属此类风险；远端规则同步失败时 fail-closed 保留缓存，避免把 provider 暂时不可用误判为“没有保护”。

## 决策 9:交互式 Rebase todo 编辑器形态

- **决策点**:git4idea 的 interactive rebase 在日志内编辑 todo 列表(pick/reword/edit/drop/squash,`Git.Interactive.Rebase` + editor handler)。Arbor 引擎已支持逐条 actions，当前 UI 已接入 `RebaseTodoEditorView`，日志单选/多选快捷入口、root 的真正 `--root` todo、HEAD/root Reword 独立消息对话框和多选 Squash 独立完整消息对话框也已接入；preserve-merges 的 merge root 现在允许通过原生 `merge -c <commit>` 重写消息，但 label/reset/merge 拓扑、跨 root 通知/撤销和更广的 merge descendant 语义仍按 partial 保留。
- **落地项**:通用 `RebasedRebaseDialog` 已内嵌 todo 列表（每行下拉 pick/reword/edit/drop/squash/fixup + 上移下移）；日志单选/多选右键入口已触发同一编辑器，HEAD Reword 另走独立消息对话框。
- **当前建议**:保留 A 作为通用 Interactive Rebase 编辑器；日志 Squash 使用独立消息对话框后转换为 reword+fixup，避免把完整合并消息丢给 Git 默认拼接。
- **依据**:执行计划 1.3 将"Interactive Rebase 的完整交互模型"列为硬缺口；当前剩余项已转为独立 squash message dialog、merge-preserving descendant/root 控制行、Commit and Rebase executor 和通知/撤销细节。Fixup/Squash 的 Commit workspace 现在可显式选择普通提交或提交后自动执行 autosquash rebase。

## 决策 10:HTTPS/SSH 认证与凭证交互范围

- **决策点**:git4idea 有 askpass/HTTP 凭证服务、SSH 配置、GPG pinentry(`GitHttpAuthService`、`SSHConnectionSettings`、`gpg.agent.configuration`)。Arbor 已有 HTTPS/SSH askpass broker，并新增仓库级结构化 SSH 设置；host-key policy（含 Ask）、known_hosts、identity file、auth method 与 local `credential.helper` 多值配置会编译进 system Git transport，clone/fetch/pull/push 已统一经过 system Git askpass；Git SSH Settings 现在提供 helper 的 local 编辑、repository/user 可用性诊断，以及只读 `SSH_AUTH_SOCK`/`ssh-add -l` agent 状态探测；Ask 模式会保留多行原生 prompt 并让 SwiftUI 展示指纹、明确接受或拒绝；changed-host-key 已由 system Git 输出结构化分类，错误详情可直接打开 SSH Settings；应用级 Git executable 已可验证、持久化并作用于全部 system-Git 调用；prompt 认证成功后按 `user@host` 持久化 `publickey/password` 方式并支持查看/清除。仍未覆盖 agent/helper 来源级成功观测与 SSH executable/key 管理。
- **可选项**:A. 依赖系统 git 凭证(osxkeychain/ssh-agent),Arbor 不介入;B. 实现内置 askpass(用户名/密码/token 弹窗 + Keychain);C. 全套(含 SSH 可执行配置)。
- **当前建议**: credential helper 已在 Git SSH Settings 提供 repository-local 多值编辑、清除与可用性诊断；应用级 `Use Git credential helper` 默认关闭时，broker transport 会用命令级 `credential.helper=` 复刻 IntelliJ 的认证接管语义，打开时保留 Git helper 链；SSH structured settings 已作为 repository-scoped transport configuration 落地，Ask/changed-host-key 交互、prompt 认证的 last-successful persistence 与只读 agent 状态探测已接入；GPG agent 配置与 embedded pinentry 的核心 loopback 加密通道已接入，仍缺 agent/helper 来源级成功观测、SSH executable chooser、agent/key generation、远程开发传输和真实 signing UI automation。
- **依据**:执行计划 1.3 硬缺口第一条。参考 fork 的 PinentryService/PinentryApp 核心交互已在 Arbor 用系统 pinentry 配置、标准 helper 协议和 Swift CryptoKit 通道实现；不把远程开发专属传输或 IntelliJ 原生 DialogWrapper 生命周期误记为 Git 引擎缺失。

## 决策 11:in-memory rebase 类 IDE 特有能力(Drop/Extract Selected Changes)

- **决策点**:`Git.Drop.Selected.Changes`、`Git.InMemory.Extract.Selected.Changes`(丢弃/提取所选提交的部分变更)依赖提交内的变更树选择和历史重写。
- **当前状态**:已实现可验证的对象级基础链路：Changes 浏览器支持 Cmd/Shift 多选；Drop 恢复选中路径到父树并重放线性后继；Extract 生成“剩余变更”提交和新消息的完整树提交。merge target 以 first-parent diff 为基线并保留全部原始 parents；Rust 测试覆盖目标为 HEAD、含线性后继、merge target、staged/unstaged/untracked 本地现场、失败恢复和全选拒绝。
- **明确限制**:当前操作前后通过临时 stash + 保存基准树三方合并复刻 IntelliJ `GitPreservingProcess` 的保存/恢复边界，恢复冲突会保留 stash 并写入 root-scoped `history-rewrite` marker；rename 已强制启用检测并按旧/新路径成对处理；目标及其后继 merge descendant 现在按 first-parent patch 重放并保留 parent 拓扑，无法安全重放时 fail-closed；已初始化且干净的 submodule gitlink 可按 Git 边界改写并同步 nested worktree，仍拒绝 all-selected、目录路径、脏/未初始化 nested worktree；尚无 IntelliJ Merge Dialog 级原生恢复 UI。
- **后续收口**:submodule/gitlink 现场语义与恢复冲突 marker 已补齐；若要从 partial 提升到 completed，下一步应把 Drop/Extract 的恢复冲突接入更细的 native notification/action lifecycle，再补原生工作台级 Swift UI automation。

## 决策 12:子模块(submodule)能力范围

- **决策点**:引擎已有 `submodule_add/update/sync/remove/list`，当前 UI 已接入操作 > Submodules；核心 add/list/update/deinit/sync/remove 已有本地集成测试，clone 递归选项也有独立测试。
- **可选项**:A. 接线现有 UI + 补集成测试(P1);B. 只保留 clone 递归与状态展示;C. 全部移除。
- **当前状态**:已采用 A 的 clone 递归子集：Clone 对话框与 Git Settings 均默认递归初始化子模块，选择值按用户偏好持久化，并有真实本地 submodule clone 回归测试；仓库内子模块状态展示与 add/update/sync/deinit/remove 核心链路已验证。由于仍缺 IntelliJ 的子模块 root 编排、子模块 diff 与更完整的 detached/remote 更新交互，子模块整体继续按 partial 保留。本地 URL add 只在用户明确发起 add 时为该次命令显式开启 file transport，远程 URL 保持 Git 默认策略。
- **依据**:执行计划 1.3 未把 submodule 列入硬缺口但 §1.1 P1 覆盖"高频使用"场景(克隆含子模块项目)。

## 决策 13:外部 Log 窗口与独立 Stash/Working Trees 工具窗

- **决策点**:git4idea 支持外部 log 窗口(`Git.Log`)、独立 Stash tab(`Git.Show.Stash`)。Arbor 将 Log 同时提供内嵌日志工具窗与独立窗口，Stash/Worktrees 继续内嵌(分支弹窗 STASHES 区、操作 > Worktrees)。
- **可选项**:A. 维持内嵌;B. 提供可弹出独立窗口。
- **当前状态**:外部 Log 已按 B 实现独立窗口；Stash/Working Trees 继续采用 A 的内嵌工具窗。
- **依据**:用户当前目标明确要求完整复刻 IntelliJ Git 能力与交互模型，不能再把 `Git.Log` 外部窗口作为产品决策排除；实现先复用已验证的 Log workspace，剩余 provider 生命周期和外部 root 选择器继续按 partial 跟踪。

## 决策 14:internal / registry 动作与 IDE 杂项能力

- **决策点**:git4idea 一批 `internal="true"` 动作(`Git.Cleanup.Branches`、`Git.FindMergedLocalBranches`、`Git.Log.Show.Command`、`TestGitHttpLoginDialogAction`、`git.update.force.pushed.branch`、`Git.AddCommitToRemoteBranch`)及编辑器类能力(commit 消息补全、ignore 语法高亮、编辑器实时 gutter、`CopyPathFromRepositoryRootProvider`)；Arbor 另外纳入了不依赖 IDE 代码模型的只读文件查看器 annotate。
- **可选项**:A. 全部排除;B. 挑选少量对 Arbor 有价值的(Copy Path、Cleanup Branches)纳入 P2。
- **当前建议**:A(默认排除),B 中仅 "复制仓库相对路径" 值得纳入 P2。
- **依据**:internal 调试动作服务于 JetBrains 内部;补全/ignore 语法高亮/编辑器实时 gutter 落在执行计划 1.2 第 1 条(IDE 补全)与第 4 条(代码模型)排除范围；Arbor 仍纳入不依赖代码模型的只读 FileContentView change-highlighting 与 annotate：前者复用 Worktree↔HEAD diff 显示行级新增/修改/删除标记，后者只依赖 Git blame 元数据。

## 决策 15:Branches 弹窗快捷键

- **决策点**:IntelliJ `Git.Branches` 默认 ctrl+shift+`(macOS keymap 显式移除该键,实际 mac 用户多绑定 ⌥⇧`)。Arbor 需要一个稳定且不与系统冲突的 macOS 快捷键。
- **可选项**:A. 绑定 ⌥⇧B 或 ⌘⇧B;B. 不绑定(顶栏常驻分支按钮已可达)。
- **当前状态**:采用 A，Arbor 在 VCS > Git > Branches… 绑定 `⌘⇧B`，与顶栏分支按钮共用同一 `postVCS(.branches)` 入口。
- **依据**:执行计划 §1 验收第 1 条"用户可以从正确的入口触发";高频入口应有键盘路径。Arbor 已对齐 ⌘T/⌘K/⌘⇧K,此项补齐后快捷键面即覆盖 IntelliJ 高频项。

---

### 与 CSV 状态的联动

上述决策中,当前标记为 `partial` 且**依赖后续设计或测试才能收口**的行:多 root 相关(决策 3)、复合 checkout 后 pull/rebase 冲突编排与 Shelve/provider 细节(决策 7)、保护分支 provider/remote discovery(决策 8)、Drop/Extract 的 merge-preserving、submodule 与恢复冲突 UI(决策 11)、日志 graph sort 的 collapsed LinearBek controller 与列/动作长尾、Squash/Drop 的通知撤销细节(决策 9)、SSH agent/helper 来源级成功与 key 管理细节(决策 10)。本地/远程/tag/revision checkout 的基础恢复链已统一，不再把它记录为“无 smart checkout 引导”。其余长尾项继续在 CSV notes 中标注 P2，不阻塞当前 Git 工作区交互。

## 16. custom diff / merge driver 执行边界（CFG-001 收口）

**决策点**：`.gitattributes` 的 diff/merge driver 是否由 Arbor 执行。
**决策**：**默认不执行**。diff driver（textconv/command）可能执行任意命令，
引擎只读取并展示 driver 名称（check-attr 已提供，Diff Attributes Inspector 已接线），diff 内容始终用引擎自身
的行级计算；merge driver 同理，冲突一律走引擎三方合并。仅在「设置中显式
启用 external drivers」后（P2，未排期）才考虑执行，且必须限制在仓库
workdir 内、带超时与输出上限。
**依据**：安全策略优先于等价性；IntelliJ 对 external diff/merge 也是
显式配置项而非默认行为。
