# JetBrains GoLand Git 文档对齐审计

> 审计日期：2026-08-30<br>
> 官网版本：GoLand 2026.2 Help，15 个页面均标注最后更新于 2026-07-14<br>
> 本轮范围：基于本审计逐项补齐 Arbor 业务差异，并同步实现状态与剩余边界<br>
> 基准入口：[Git 集成](https://www.jetbrains.com/zh-cn/help/go/using-git-integration.html)

## 1. 审计方法与结论口径

本审计没有只阅读入口页或目录摘要。入口页下的 15 个 Git 页面被逐页打开，页面中的每个 `h2`/`h3` 功能段落被单独阅读并记录，共 122 个功能段落。官网交互是事实基准；Arbor 代码、测试和既有 parity matrix 只用于证明当前实现，不能反向改写官网要求。

本轮核对的是用户可见能力和关键失败/恢复语义。IntelliJ 平台内部的 `ActionSystem`、`DataContext`、`VcsNotifier`、`VFS/PSI` 生命周期只有在会造成真实用户行为差异时才记为缺口，不把类名或框架不同本身当作缺口。

状态定义：

| 状态 | 含义 |
| --- | --- |
| **对齐** | Arbor 已有等价的用户流程和结果；原生 IntelliJ 生命周期可能不同。 |
| **部分** | 核心流程可用，但官网同一功能点内仍有可见交互或语义差异。 |
| **缺口** | 官网有完整用户流程，Arbor 当前没有等价入口或结果。 |
| **决策差异** | Arbor 已明确选择不同产品模型，不是意外漏做。 |
| **平台边界** | 依赖完整 IDE 编辑器、PSI、运行配置或 Local History，已超出当前 Git 产品边界。 |
| **不适用** | Windows/WSL 等与 macOS 产品无关的流程。 |

优先级定义：

| 优先级 | 含义 |
| --- | --- |
| **P0** | 目标能力的主体不存在，不能声称该模块与 JetBrains 对齐。 |
| **P1** | 高频 Git 工作流有明显缺项或语义不一致。 |
| **P2** | 低频能力、交互完整性或平台增强项。 |

## 2. 总体结论

Arbor 的本地 Git 主链路已经较完整：分支、Fetch/Pull/Update、提交、暂存、Merge/Rebase/Cherry-pick、撤销、历史、Diff、Shelf/Stash、多 Git Root 和中断恢复均有真实实现。不能把它概括成“Git 功能未做完”。

本轮已关闭多项此前记录的高频差异：浅克隆、Push 提交级预览、普通冲突批量处理、Changelist V2、Shelf 位置迁移、PR/MR 详情工作台和 Blame 两个注解动作均已有实现与测试。当前最显著的不对齐分为三类：

1. **Hosting 仍是部分对齐**：PR/MR 已支持列表筛选、Overview/Timeline/Commits/Files、commit-scoped diff、checkout、Git Log、基础 review 和 merge/close；draft/pending review、多行/附件评论、request-review 管理和完整 capability/权限协商仍未完成。
2. **低频交互仍有差异**：Clone 尚无已登录托管仓库选择；Shelf 尚无 base 开关和 split/combined tab；Blame 列显示配置、GitLab Request Changes 等 provider 细节仍不完整。
3. **IDE 平台边界**：Arbor 当前文件查看器只读，因此编辑器 gutter 回滚/提交、History for Selection、Safe Delete/Find Usages、GoLand PSI/TODO/Run Configuration 提交检查不能按官网原样成立。

### 2.1 页面总览

| # | 官网页面 | 功能段落 | 当前判断 | 主要差异 |
| ---: | --- | ---: | --- | --- |
| 1 | 设置 Git 仓库 | 12 | 部分 | Shallow/depth 已对齐；仍缺托管仓库选择，项目 Trust/Safe Mode 属平台边界。 |
| 2 | 管理 Git 分支 | 16 | 基本对齐 | 主要剩余是原生 action/通知细节和 UI 自动化。 |
| 3 | 与远程仓库同步 | 4 | 基本对齐 | Fetch/Pull/Update/Update Info 均存在；高级间隔通过内部 key 配置。 |
| 4 | 提交并推送 | 14 | 部分 | Push 提交级文件/Diff 与多 root target 已对齐；编辑器内提交、IDE-aware checks 缺失，Staging 模式为明确产品差异。 |
| 5 | Merge/Rebase/Cherry-pick | 11 | 基本对齐 | 交互式 Rebase 的少数 merge-topology 细节仍为 partial。 |
| 6 | 解决冲突 | 3 | 部分 | 三栏工作台与普通冲突批量动作已对齐；LF/CRLF 专用 UI 仍是部分。 |
| 7 | 添加并跟踪文件 | 5 | 部分 | Add/Ignore/Remove 存在；编辑器 gutter 操作和 Safe Delete 属平台边界。 |
| 8 | 撤销更改 | 9 | 基本对齐 | Git 层撤销完整；Local History 不在本页且明确不做。 |
| 9 | Changelist | 4 | 部分 | V2 description、active 归属和 comment 传播已对齐；Track Context 无 task provider，统一 Move dialog 仍不完整。 |
| 10 | Shelf/Stash | 13 | 部分 | 位置迁移、创建 review、Unshelve comment 已对齐；base 开关、split/combined tab 和严格 untracked 语义仍有差异。 |
| 11 | 调查更改 | 15 | 部分 | Log/File History/Blame 与 Hide Author/Previous Revision 已对齐；注解列显隐和完整 Selection History 仍有差异。 |
| 12 | 编辑项目历史 | 6 | 基本对齐 | Reword/Amend/Squash/Drop/Extract 均有实现。 |
| 13 | 比较文件版本 | 4 | 基本对齐 | 结构化 Diff 完整；不是 IntelliJ 可编辑 DiffManager。 |
| 14 | GitHub Pull Requests | 3 | 部分 | 列表、详情、Timeline、commit/files、基础 review、merge/close 已有；draft、多行/附件评论、request reviewers 和完整权限协商仍缺。 |
| 15 | GitLab Merge Requests | 3 | 部分 | 详情、讨论、commit/files、comment/approve/revoke、merge/close 已有；Request Changes、draft/multi-line/attachment 和 pipeline/权限状态仍缺。 |
| **合计** |  | **122** |  |  |

## 3. 逐页、逐功能点核对

### 3.1 设置 Git 仓库（12）

来源：[set-up-a-git-repository.html](https://www.jetbrains.com/zh-cn/help/go/set-up-a-git-repository.html)

| # | 官网功能点 | 官网交互流程 | Arbor 当前实现与差异 | 结论 |
| ---: | --- | --- | --- | --- |
| 1 | 从远程主机检出项目（git clone） | 从 Git/VCS/欢迎页进入 Clone；输入 URL 或选托管服务；可 shallow + depth；Clone 后自动映射 root、递归 submodule，并进入 Trust/Safe Mode。 | URL、目标目录、目录名、递归 submodule、认证、shallow/depth、Clone 后打开项目和 `Fetch Full History` 已实现；仍缺托管仓库选择；Trust/Safe Mode 不存在。见 **G-01**。 | **部分/P1** |
| 2 | 将现有项目置于 Git 版本控制之下 | 对现有目录执行 Create Git Repository，并让 IDE 建立 VCS mapping。 | `initialize_repository`、目录选择、重复 root 提示和打开项目均存在。 | **对齐** |
| 3 | 将整个 项目 关联到单个 Git 存储库 | 选择项目根目录初始化 Git。 | 支持项目根 init 和自动重新加载。 | **对齐** |
| 4 | 将项目中的不同目录与不同的 Git 存储库关联 | 在 VCS Directory Mappings 中增加多个 Git root。 | 有 root discovery、Git Roots 面板和 multi-root 聚合操作；不是 JetBrains 的 mapping table 形态。 | **部分** |
| 5 | 将文件添加到本地仓库 | 在 Project/Commit 视图执行 Add；新增文件可按设置询问或自动加入；ignored 文件需确认 force add。 | stage/add、ignored force-add 确认、外部 VFS create policy 和多 root 路由已实现。 | **对齐** |
| 6 | 将文件排除在版本控制之外（忽略） | 只对 unversioned 文件提供 Ignore；支持 `.gitignore` 与 `.git/info/exclude`。 | 入口已限制到 unversioned；两类文件均可写入，并处理覆盖目标路径的候选 ignore 文件。 | **对齐** |
| 7 | 将文件添加到 .gitignore 或 .git/info/exclude | 从 Commit/Project 选择目标，选择具体 ignore 文件或 exclude。 | 已有 root-scoped 写入、候选 `.gitignore` 选择、规则安全校验。 | **对齐** |
| 8 | 添加远程仓库 | 无 remote 时从 Push 的 Define Remote，或从 Manage Remotes 添加。 | Push 空 remote 状态可进入 Configure Remotes；有增删改和连通性校验。 | **对齐** |
| 9 | 定义远程仓库 | 填 name/URL，可选择立即 fetch。 | Remote dialog 和 `ls-remote` 校验存在；Fetch 可从后续操作触发，交互不完全等同同一 checkbox。 | **部分/P2** |
| 10 | 添加第二个远程库 | Manage Remotes 中添加；Log/Push 中可编辑或删除。 | 单 root/multi-root remote 管理、分支面板编辑/删除均存在。 | **对齐** |
| 11 | 为 Git 远程仓库设置密码 | HTTPS/SSH 操作统一走 IDE 认证，并按密码策略保存。 | Askpass broker、Keychain、credential helper、SSH host key/identity 设置已接入远端操作。 | **对齐（macOS）** |
| 12 | 配置密码策略 | JetBrains 可选 Native Keychain、KeePass 或重启后忘记。 | macOS 使用 Keychain/credential helper；没有 KeePass 数据库或同构三选一。Native Keychain 是 macOS 合理默认，KeePass 属跨平台产品差异。 | **部分/P2** |

补充：官网关于 WSL/Windows Git 的段落对 macOS **不适用**；不能记为 Arbor 缺口。

### 3.2 管理 Git 分支（16）

来源：[manage-branches.html](https://www.jetbrains.com/zh-cn/help/go/manage-branches.html)

| # | 官网功能点 | 官网交互流程 | Arbor 当前实现与差异 | 结论 |
| ---: | --- | --- | --- | --- |
| 1 | 创建一个新分支 | 从 Branches popup 或 Log 创建，校验名称并决定是否 checkout。 | 单 root/multi-root popup、Log 创建、名称清理和 unborn HEAD guard 已实现。 | **对齐** |
| 2 | 从当前分支创建一个新分支 | New Branch，输入名称，选择 checkout。 | 已实现。 | **对齐** |
| 3 | 从所选分支创建新分支 | 选 local/remote branch 后 New Branch from Selected。 | 已实现；remote 会进入本地分支命名/跟踪流程。 | **对齐** |
| 4 | 从所选提交创建新分支 | Log 选 commit 后 New Branch。 | Log commit action 已实现。 | **对齐** |
| 5 | 重命名分支 | 当前/非当前本地分支 Rename；更新引用和 UI。 | 已实现并校验分支名；remote/tag 不错误暴露 Rename。 | **对齐** |
| 6 | 标记分支为收藏 | 在 Branches/Log 中 favorite/unfavorite，并持久化。 | 已实现。 | **对齐** |
| 7 | 分组分支 | 按目录、repository 分组；多 root 可筛选 repository。 | 单 root/multi-root 分组和 project-scoped 持久化已实现。 | **对齐** |
| 8 | 查看分支 (git-checkout) | 从 popup/Log 选择 local、remote、tag 或 revision。 | local/remote/tag/revision 均有 root-safe checkout。 | **对齐** |
| 9 | 将分支检出为新的本地分支 | remote branch → Checkout as New Local Branch，设置名称/跟踪。 | 已实现；同名本地分支和 reset 语义有显式处理。 | **对齐** |
| 10 | 在分支之间切换 | 干净现场直接切换；冲突本地改动时提供 Smart Checkout、Force Checkout、Cancel。 | 三路流程、Shelve/Stash 保存策略、恢复冲突和重启恢复均存在。 | **对齐** |
| 11 | 比较分支 | 从 popup/Log 进入提交差异或文件树差异。 | branch-vs-current、branch pair 和 tree/commitwise 结果均存在。 | **对齐** |
| 12 | 将某个分支与当前分支进行比较 | 显示各自独有提交和文件差异。 | 已实现。 | **对齐** |
| 13 | 将分支与工作树进行比较 | 以选中 branch 和当前 worktree 比较，并可交换方向。 | 已实现，方向设置按项目持久化。 | **对齐** |
| 14 | 列出一个分支中不包含在另一个分支中的所有提交 | 使用 two-dot/Compare 分支列表。 | 已实现 commitwise compare。 | **对齐** |
| 15 | 删除分支 | local/remote 分别确认；未合并提交可 View Commits、Force Delete、Restore。 | 删除预览、保护、未合并提交视图、恢复和 remote delete 均存在。 | **对齐** |
| 16 | 配置同步分支控制 | 多仓库可同步控制同名分支或按 repository 独立操作。 | 有项目级 sync control 和 root-qualified branch popup；原生 action enablement/通知生命周期不同。 | **部分** |

### 3.3 与远程 Git 仓库同步（4）

来源：[sync-with-a-remote-repository.html](https://www.jetbrains.com/zh-cn/help/go/sync-with-a-remote-repository.html)

| # | 官网功能点 | 官网交互流程 | Arbor 当前实现与差异 | 结论 |
| ---: | --- | --- | --- | --- |
| 1 | 获取变更 | Fetch 当前或全部 remote；Auto Fetch 更新 remote refs 和 incoming/outgoing 状态。 | Fetch/Fetch All、认证、取消、tag policy、incoming/outgoing badge 和多 root 调度已实现。间隔默认 20 分钟，并有内部 `arbor.git.incomingCheckIntervalMinutes.v1`，等价于 JetBrains Registry。 | **对齐** |
| 2 | 更新分支 | 更新当前或选定非当前分支；非当前分支只 fast-forward ref，不 checkout。 | 当前/非当前分流、认证和失败反馈已实现。 | **对齐** |
| 3 | 拉取更改 | Pull dialog 选择 remote/branch 和 merge/rebase/ff-only 等选项；处理本地改动、认证和冲突。 | `PullDialogView` 覆盖 remote/branch、merge/rebase、ff/no-ff/squash/no-commit/no-verify 等；保存/恢复现场和冲突恢复存在。 | **对齐** |
| 4 | 更新您的项目 | Update Project 遍历全部 Git roots，按配置 Merge/Rebase，显示 Update Info 和部分结果。 | 多 root readiness、逐 root 结果、retry、detached/upstream 提示、Update Info tab/path filter/auto-open 均存在。 | **对齐** |

注意：`Update Info` 不是缺口。当前实现见 `Arbor/ContentView.swift:517`、`Arbor/WorkspaceOperations.swift:4482` 和 `Arbor/DiagnosticsLogger.swift:490`。

### 3.4 提交并推送更改（14）

来源：[commit-and-push-changes.html](https://www.jetbrains.com/zh-cn/help/go/commit-and-push-changes.html)

| # | 官网功能点 | 官网交互流程 | Arbor 当前实现与差异 | 结论 |
| ---: | --- | --- | --- | --- |
| 1 | 设置您的 Git 用户名 | 未配置 identity 时提示；可设 local/global `user.name`/`user.email`。 | identity 检查、设置和 author/committer/signing UI 已实现。 | **对齐** |
| 2 | 在本地提交更改 | 选择 changes，填写 message，执行 before-commit checks，Commit/Commit and Push。 | staged-only commit、Commit All 显式确认、Amend、hooks、签名、author/committer、模板/最近消息、自定义 command 均存在；GoLand PSI/TODO/Run Configuration checks 不存在。见 **G-08**。 | **部分/P2** |
| 3 | 提交部分文件 | 在 changes tree 只选择目标文件。 | 文件级 stage/unstage 和选择提交已实现。 | **对齐** |
| 4 | 选择您想要提交的块和特定行 | Diff 中按 hunk/line include/exclude 或 Stage/Unstage。 | hunk/line Stage、Unstage、Rollback，三版本比较均存在。 | **对齐** |
| 5 | 从编辑器提交选定的更改 | 编辑器 gutter/选区直接提交 line/hunk。 | 当前 `FileContentView` 是只读 viewer；没有 live editor selection/gutter commit。见 **G-07**。 | **平台边界/P2** |
| 6 | 将更改放入不同的更改列表 | Move to Another Changelist，可新建列表、附 comment、设 active/track context。 | 路径移动、drag/drop、创建/激活/重命名/删除和 active 新变更归属已实现；统一 Move dialog、task context 仍缺，comment 以目标 description 追加。见 **G-05**。 | **部分/P1** |
| 7 | 自定义查看本地更改的方式 | group、flatten、show ignored、expand/collapse、preview 等。 | Changes Browser 有 changelist、目录、staged/unstaged、ignored、preview 和持久化设置；少数原生 tree action 不同。 | **部分** |
| 8 | 自定义提交工具窗口 | 切换 modal/non-modal commit、布局和选项。 | Arbor 固定 Commit/Staging workspace；主要提交能力可达，但没有 JetBrains 两套 commit UI。 | **决策差异** |
| 9 | 自定义 Diff Viewer 的行为 | side-by-side/unified、ignore whitespace、导航、编辑/接受变更等。 | 结构化 side-by-side/unified、whitespace、textconv、外部 diff 和 hunk actions 已实现；不是完整可编辑 DiffManager。 | **部分** |
| 10 | 使用 Git 暂存区提交更改 | Enable/Disable Staging Area；模式切换时保留 changelists。 | Arbor 固定双栏 staging area，不提供 Enable/Disable；这是 `git-parity-decisions.md` 的明确选择。见 **D-01**。 | **决策差异** |
| 11 | 准备提交的更改 | Stage/Unstage 文件、hunk、line，并检查 HEAD/Index/Worktree 三版本。 | 已实现。 | **对齐** |
| 12 | 将更改推送到远程存储库 | Push dialog 按 repository/commit 展示；选 commit 看 changed files/Diff；编辑 target；tag/force 选项。 | remote/target/refspec/upstream/tags/hooks/force-with-lease/保护分支、commit selection 驱动的 changed-files/Diff 和 multi-root target 编辑均存在；原生 staged graph/权限状态不完全同构。见 **G-03**。 | **部分/P1** |
| 13 | 如果推送被拒绝，请更新您的工作副本 | rejected push 后选择 Merge/Rebase Update，可应用到所有 repositories，并记住策略。 | rejected recovery、Merge/Rebase、View Commits、multi-root 结果和恢复动作已实现；原生对话框细节不同。 | **对齐** |
| 14 | 我什么时候需要使用force push？ | 只有改写远端历史时使用；protected branch 禁止；优先 force-with-lease。 | 默认 force-with-lease、显式 force、保护分支正则及 GitHub protection 同步已实现。 | **对齐** |

### 3.5 合并、变基或挑拣以应用更改（11）

来源：[apply-changes-from-one-branch-to-another.html](https://www.jetbrains.com/zh-cn/help/go/apply-changes-from-one-branch-to-another.html)

| # | 官网功能点 | 官网交互流程 | Arbor 当前实现与差异 | 结论 |
| ---: | --- | --- | --- | --- |
| 1 | 合并分支（章节） | 从 Branches/Log 选择 source，合并到 current；冲突时暂停并恢复。 | 入口、operation state、冲突工作台和 Continue/Abort 均存在。 | **对齐** |
| 2 | 合并分支（操作） | 支持 ff、ff-only、no-ff、squash、no-commit、message、no-verify、unrelated histories。 | `RebasedMergeDialog` 和 engine 已覆盖这些选项，multi-root 也传递同一组参数。 | **对齐** |
| 3 | 变基分支（git-rebase） | 当前分支 rebase 到目标，保存本地现场，冲突可 Continue/Skip/Abort。 | 已实现并持久化恢复状态。 | **对齐** |
| 4 | 将分支变基到另一个分支之上 | 选择 upstream/onto，按需要 preserve merges。 | 普通和 preserve-merges 路径存在。 | **对齐** |
| 5 | 通过执行交互式变基编辑 Git 历史记录 | todo 支持 pick/reword/edit/squash/fixup/drop 和排序。 | structured todo editor、拖拽、squash/fixup 组语义，以及 native control row 的编辑/移动均存在；剩余差异集中在原生弹窗/通知生命周期和复杂 merge topology 边界。 | **部分** |
| 6 | 编辑当前分支的历史 | 从 HEAD/Log 选择起点，打开 interactive rebase。 | 已实现。 | **对齐** |
| 7 | 编辑分支历史并将其集成到另一个分支 | 对另一分支进行 interactive rebase/onto，再整合。 | 有 root-aware rebase/onto；跨 root 通知和少数 merge topology 细节不同。 | **部分** |
| 8 | 挑选单独提交 | Log 选一个或多个 commit，按顺序 cherry-pick；冲突可恢复。 | 单/多提交、multi-root、Continue/Abort 和恢复均存在。 | **对齐** |
| 9 | 将提交应用到另一个分支 | 从源分支 Log 选择 commits，在目标分支 cherry-pick。 | 已实现。 | **对齐** |
| 10 | 应用单独更改 | 在 commit changes/Diff 中选择 changes 应用到工作树。 | selected changes apply/extract/revert 路径已实现。 | **对齐** |
| 11 | 应用独立文件 | 从 commit/file history 对单个文件执行 Get/Apply。 | 文件级 apply/get previous revision 已实现。 | **对齐** |

### 3.6 解决 Git 冲突（3）

来源：[resolve-conflicts.html](https://www.jetbrains.com/zh-cn/help/go/resolve-conflicts.html)

| # | 官网功能点 | 官网交互流程 | Arbor 当前实现与差异 | 结论 |
| ---: | --- | --- | --- | --- |
| 1 | 解决冲突 | 冲突列表中 Accept Yours/Theirs 或打开三栏 Merge Viewer；逐块接受、编辑结果、Apply/Continue。 | 统一三栏 editor、Accept Ours/Theirs/Both、逐块导航、Reset/Base、外部工具、binary 降级和 operation recovery 已实现。 | **对齐（核心）** |
| 2 | 提高效率的提示 | `Resolve All Simple Conflicts`；从左/右侧 `Apply All Non-conflicting Changes`；自动应用简单块。 | 普通 conflict toolbar 已提供 Resolve Simple、左右侧 Apply Non-conflicts 和安全块预览；binary/手工改写块会 fail-closed。见 **G-04**。 | **对齐** |
| 3 | 处理与 LF 和 CRLF 行结尾相关的冲突 | 用 IDE line separator 状态识别并避免把纯换行差异误当内容冲突。 | Commit CRLF checks 和 Git attribute 解析存在；冲突 viewer 没有完整 line-separator UI/normalize action。 | **部分/P2** |

### 3.7 将文件添加到 Git 并跟踪更改（5）

来源：[adding-files-to-version-control.html](https://www.jetbrains.com/zh-cn/help/go/adding-files-to-version-control.html)

| # | 官网功能点 | 官网交互流程 | Arbor 当前实现与差异 | 结论 |
| ---: | --- | --- | --- | --- |
| 1 | 将文件添加到 Git | Project/Commit/editor 中 Add；外部新增文件按设置询问/自动添加。 | stage/add、ignored confirmation、外部 VFS add policy 和多 root path ownership 均存在。 | **对齐** |
| 2 | 检查项目文件状态 | Project/Commit 颜色、状态和 changelist 展示。 | status model、badges、staged/unstaged/untracked/ignored/conflicted 分组存在。 | **对齐** |
| 3 | 在编辑器中跟踪文件的更改 | live gutter marker；点击看 diff，回滚 line/block，移动 changelist，stage/commit。 | 只读 viewer 有 line change marker，但无编辑、hover popup、line/block revert、move/commit。见 **G-07**。 | **平台边界/P2** |
| 4 | 检查文件状态 | 从 status 色彩、tooltip 和 Local Changes 识别状态。 | 已实现。 | **对齐** |
| 5 | 从仓库中删除文件 | Delete；Safe Delete 先 Find Usages，再决定删除。 | 普通 tracked remove、外部 delete policy 和恢复存在；Safe Delete/Find Usages 依赖 PSI，明确不在范围。见 **D-02**。 | **部分/平台边界** |

### 3.8 撤销 Git 仓库中的更改（9）

来源：[undo-changes.html](https://www.jetbrains.com/zh-cn/help/go/undo-changes.html)

| # | 官网功能点 | 官网交互流程 | Arbor 当前实现与差异 | 结论 |
| ---: | --- | --- | --- | --- |
| 1 | 撤销未提交的更改 | 对文件、hunk 或 lines 执行 Rollback/Revert，并确认不可恢复内容。 | 文件/hunk/line rollback、untracked 安全边界和 diff preview 已实现。 | **对齐** |
| 2 | 取消暂存文件 | 从 Staged 执行 Unstage 文件/hunk/line。 | 已实现。 | **对齐** |
| 3 | 撤销上一次提交 | Undo Commit/Uncommit，把提交内容放回 changelist/staging。 | 已实现并保护本地现场。 | **对齐** |
| 4 | 恢复已推送的提交 | 创建反向 revert commit，不改写已发布历史。 | Log Revert、批量顺序、冲突恢复已实现。 | **对齐** |
| 5 | 还原选定的更改 | 只 revert commit 中选中的文件/changes。 | Changes Browser 多选和 selected changes revert 已实现。 | **对齐** |
| 6 | 放弃提交 | 对未发布提交 Drop；有后继时重放，保护 dirty scene。 | Log Drop、线性/merge descendant 边界、保护分支和恢复 marker 已实现。 | **对齐** |
| 7 | 从提交中丢弃所选更改 | 改写目标 commit，移除选中的 paths，重放后继。 | object-level drop selected changes 已实现；复杂 submodule/merge 情况 fail-closed。 | **部分** |
| 8 | 将分支重置到特定提交 | Soft/Mixed/Hard/Keep reset 模式，危险模式确认。 | 四种 reset mode、dirty scene 策略、冲突/恢复和 multi-root result 已实现。 | **对齐** |
| 9 | 获取文件的先前修订版本 | File History 选 revision，Get/Checkout 文件版本。 | `RevisionBrowserView` 和 file revision restore 已实现。 | **对齐** |

### 3.9 将更改分组到 Changelist 中（4）

来源：[managing-changelists.html](https://www.jetbrains.com/zh-cn/help/go/managing-changelists.html)

| # | 官网功能点 | 官网交互流程 | Arbor 当前实现与差异 | 结论 |
| ---: | --- | --- | --- | --- |
| 1 | 创建一个新的变更列表 | 输入 name、可选 description；可设 active、Track Context。 | V2 metadata 已保存 description、active、track context/task identity 字段；Create dialog 支持 description/Set active，Track Context 无 task provider 时显示 unavailable。见 **G-05**。 | **部分/P1** |
| 2 | 设置活动变更列表 | 激活后，随后产生的新改动默认进入该列表；Track Context 可恢复 task/editor context。 | status/VFS observation ledger 会把首次出现的新路径归入 active；首次全量 snapshot 不搬动旧改动。真实 task/editor context provider 尚未实现。 | **部分/P2** |
| 3 | 在变更列表之间移动更改 | Move dialog 可选 existing/new list，填写 comment，set active/track context；也可 drag/drop。 | existing list 移动和 drag/drop 存在；统一 Move dialog 与独立 comment/history 字段缺失，Unshelve comment 以目标 description 追加。 | **部分/P1** |
| 4 | 删除变更列表 | 删除后处理成员迁移；Default 不能删；active 删除需重新选择。 | Default 保护、成员回 Default、active 回 Default，以及 V2 metadata 随列表删除已实现。 | **对齐** |

### 3.10 搁置或储存更改（13）

来源：[shelving-and-unshelving-changes.html](https://www.jetbrains.com/zh-cn/help/go/shelving-and-unshelving-changes.html)

| # | 官网功能点 | 官网交互流程 | Arbor 当前实现与差异 | 结论 |
| ---: | --- | --- | --- | --- |
| 1 | 暂存架 与 暂存 | Shelf 是 IDE patch，Stash 是 Git 对象；两者并存且语义不同。 | 自有 Shelf refs/patch + 原生 Git stash 双轨已实现。 | **对齐** |
| 2 | 合并存储和搁置选项卡 | 设置中可把 Shelf/Stash 合并到 Saved Patches，或分开。 | 当前是合并的 Saved Patches workspace；没有 split/merge tab 模式开关。 | **部分/P2** |
| 3 | 搁置和取消搁置更改 | Shelf 可重复应用；Unshelve 可选 target changelist、填写 comment、保留/移除已应用成员；冲突可恢复。 | Preview、Unshelve、Apply/Pop、目标 changelist、`Remove Applied Files from Shelf`、Unshelve comment、冲突和重启恢复均存在；comment 以目标 Changelist description 追加。 | **部分/P2** |
| 4 | 搁置变更 | Shelve dialog 默认全选，提供文件统计、Diff、restore/refresh/group/navigation，再创建 Shelf。 | 创建 dialog 已有 name、默认全选、文件统计和 Review Diff；仍缺完整 restore/refresh/group/navigation，同窗仍允许 untracked（行为超集）。见 **G-06**。 | **部分/P1** |
| 5 | 恢复变更 | Unshelve 选择文件/hunk和目标 changelist；可 silent apply，默认 Shelf 可保留。 | 文件/hunk、Diff、target list、keep/remove 和 conflict recovery 已实现；silent action surface 不完整。 | **部分/P2** |
| 6 | 舍弃搁置的更改 | Drop 后进入 Recently Deleted，可永久删除。 | Active → Recently Deleted、member delete、Delete Permanently、retry/restart 已实现。 | **对齐** |
| 7 | 恢复未搁置的更改 | Recently Deleted 中 Restore；过期回收。 | Restore、7 天 expiry 和 lifecycle task 已实现。 | **对齐** |
| 8 | 应用外部补丁 | Import patch，选择 base/path mapping，review 后 apply。 | file/clipboard import、raw patch 保存、base/path strip、preview 和 conflict recovery 已实现。 | **对齐** |
| 9 | 自动存储基准修订版 | 设置是否为分布式 VCS Shelf 保存 base revision，以改善三方应用。 | Shelf 内部始终保存 parent/base，结果接近“始终开启”；没有用户 toggle，记录为产品决策差异。见 **G-06**。 | **部分/P2** |
| 10 | 更改默认搁置位置 | 设置新的 Shelf directory，并选择是否迁移已有 Shelf。 | 已有 repository-scoped location setting、copy-verify migration、refs 保留和非迁移 fail-closed。见 **G-06**。 | **对齐** |
| 11 | 存储变更 | Stash dialog 输入 message，可 keep index、include untracked/ignored。 | 已实现。 | **对齐** |
| 12 | 保存更改到存储区域 | Save/Stash Silently 或按路径 stash，保留未选内容。 | full/path stash、keep index、include options 和静默 stash 已实现。 | **对齐** |
| 13 | 查看并应用存储的更改 | preview Diff；Apply/Pop；Unstash As new branch；Drop/Clear。 | Preview、Apply/Pop、Stash Branch、Drop/Clear、冲突恢复和稳定 stash ID 均存在。 | **对齐** |

### 3.11 调查 Git 仓库中的更改（15）

来源：[investigate-changes.html](https://www.jetbrains.com/zh-cn/help/go/investigate-changes.html)

| # | 官网功能点 | 官网交互流程 | Arbor 当前实现与差异 | 结论 |
| ---: | --- | --- | --- | --- |
| 1 | 查看项目历史 | 打开 Git Log，浏览图、refs、commits 和 changes。 | root-aware Log、graph、filters、commit inspector 和 changes browser 已实现。 | **对齐** |
| 2 | 浏览和搜索项目历史记录 | 按 branch、user、date、path、text/hash 搜索；定位 refs/commits。 | Log filters、path chooser、Search Everywhere refs/hash/message 和 multi-root identity 已实现。 | **对齐** |
| 3 | 查看项目在特定修订版的快照 | 选 commit 浏览该 tree 的文件内容。 | Revision Browser 已实现。 | **对齐** |
| 4 | 查看两个提交之间的差异 | 多选两个 commits 或选择 Compare，展示 commits/files/Diff。 | commit pair compare、root-qualified change groups 和 standalone diff 已实现。 | **对齐** |
| 5 | 查看文件历史 | File History 跟随 rename，独立 tab，查看 revision/diff。 | 独立 file-history Log tab、path filter 和 revision actions 已实现。 | **对齐** |
| 6 | 查看选定内容的历史记录 | 编辑器选中 lines/block，执行 History for Selection/Block。 | 当前没有可编辑 editor selection/history provider。见 **G-07**。 | **平台边界/P2** |
| 7 | 目录的历史记录审核 | 对目录显示影响它的 commits，并比较目录快照。 | directory path history/compare 入口存在；没有 JetBrains 完整 Directory History view 行为。 | **部分** |
| 8 | 审查本地和已提交文件版本之间的差异 | 从 Log/File History 将 revision 与 local worktree 比较。 | Compare with Current/Local、rename-aware revision-to-worktree diff 已实现。 | **对齐** |
| 9 | 查看更改是如何合并的 | 对 merge commit 查看 parents、选择 parent 比较和 changes。 | merge commit parent-aware history/diff 存在；原生 combined changes presentation 不完全一致。 | **部分** |
| 10 | 定位代码作者（使用 Git Blame 注释） | 在 editor gutter Annotate，点击行跳 commit。 | 只读 file/diff viewer 有 author/hash/date/line blame，并可打开 commit。 | **对齐（只读 viewer）** |
| 11 | 启用注解 | 文件 context/menu 中 Annotate。 | VCS 文件动作和 viewer Blame 切换均存在。 | **对齐** |
| 12 | 配置注释中显示的信息量 | 控制 author/date/hash 等列显示。 | Hide Author 已持久化并会收缩 author 列；完整的 author/date/hash/line 列显隐和排序设置仍缺。 | **部分/P2** |
| 13 | 配置注解选项 | Ignore Whitespaces、Detect Movements within/across files、commit date。 | 三类选项均已实现并立即刷新 blame。 | **对齐** |
| 14 | 隐藏更改的作者 | annotation context menu 中 Hide Author。 | Blame Options 已提供持久化 Hide Author，并真正移除 author 列宽。见 **G-09**。 | **对齐** |
| 15 | 注释上一版本 | 从某行/commit 对文件的 parent revision 重新 Annotate。 | 行 context menu 会按 first parent、rename-aware path 重新 Annotate，并显示当前 annotation revision，可返回 Working Tree。见 **G-09**。 | **对齐** |

### 3.12 编辑 Git 项目历史（6）

来源：[edit-project-history.html](https://www.jetbrains.com/zh-cn/help/go/edit-project-history.html)

| # | 官网功能点 | 官网交互流程 | Arbor 当前实现与差异 | 结论 |
| ---: | --- | --- | --- | --- |
| 1 | 编辑提交信息 | 未发布 commit 可 Reword；已发布历史需警告/force 策略。 | Log Reword、root/HEAD 特殊处理、保护分支检查已实现。 | **对齐** |
| 2 | 修订本地提交 | Amend staged changes/message，保持 author 或调整 metadata。 | Amend、identity/signing/hooks 和 staged semantics 已实现。 | **对齐** |
| 3 | 修改任何之前的提交 | Interactive rebase 中 Edit/Reword，继续完成后继重放。 | 已实现并有 recovery。 | **对齐** |
| 4 | 压缩提交 | Log 多选 Squash 或 todo squash/fixup，并编辑最终 message。 | 独立 squash message dialog 和 todo group semantics 已实现。 | **对齐** |
| 5 | 放弃提交 | Drop selected commit，重放后继并保护本地现场。 | 已实现。 | **对齐** |
| 6 | 提取所选更改 | 从历史 commit 取出所选 paths，重写原 commit，并将内容放回可提交状态。 | object-level Extract Selected Changes 已实现；复杂 topology/submodule fail-closed。 | **部分** |

### 3.13 使用差异查看器比较文件和文件夹版本（4）

来源：[comparing-file-versions.html](https://www.jetbrains.com/zh-cn/help/go/comparing-file-versions.html)

| # | 官网功能点 | 官网交互流程 | Arbor 当前实现与差异 | 结论 |
| ---: | --- | --- | --- | --- |
| 1 | 将已修改的文件与其 Git 仓库版本进行比较 | Compare with HEAD，展示 local 与 base。 | worktree/index/HEAD diff 和 file action 已实现。 | **对齐** |
| 2 | 将当前修订版的文件或文件夹与同一 Git 分支中的修订版进行比较 | File History 选择 revision，对比当前/另一 revision。 | revision browser/file history compare 已实现。 | **对齐** |
| 3 | 将文件或文件夹的当前修订版本与另一个 Git 分支或标签进行比较 | Compare with Branch or Tag，选择 ref 后展示文件/目录差异。 | reference picker、file/directory compare、rename-aware diff 已实现。 | **对齐** |
| 4 | 将本地更改与基准修订版本进行比较 | Show Diff/Compare with Base；staging 模式可看 HEAD/Index/Worktree。 | side-by-side/unified、三版本、binary/textconv/rename 和 hunk actions 已实现；完整可编辑 DiffManager 属平台差异。 | **部分** |

### 3.14 审核传入的 GitHub Pull Requests（3）

来源：[work-with-github-pull-requests.html](https://www.jetbrains.com/zh-cn/help/go/work-with-github-pull-requests.html)

| # | 官网功能点 | 官网交互流程 | Arbor 当前实现与差异 | 结论 |
| ---: | --- | --- | --- | --- |
| 1 | 管理传入的 pull requests | 按 status/author/assignee/reviewer/labels 筛选、排序、刷新；双击进入 Overview/Timeline；checkout incoming branch；Show in Git Log。 | Hosting workspace 已有上述筛选、Overview/Timeline、commit/files、checkout 和 Git Log；仓库列表仍没有已登录托管仓库选择。 | **部分/P1** |
| 2 | 审核 pull request | 按 commit 过滤 changes；review mode；文件/单行/多行评论；draft/pending comments；提交 Approve/Request Changes/Comment。 | 已有 commit-scoped files/diff 和 Comment/Approve/Request Changes review outcome；仍缺 draft/pending 生命周期、多行/附件评论和 outdated position。 | **部分/P1** |
| 3 | 合并或关闭传入的拉取请求 | Merge/Squash Merge/Rebase Merge/Close/Request Review，并显示检查与权限状态。 | GitHub merge/squash/rebase、Close 已接入；Request Review、checks/权限 capability negotiation 仍缺。 | **部分/P1** |

### 3.15 审查传入的 GitLab Merge Requests（3）

来源：[work-with-gitlab-merge-requests.html](https://www.jetbrains.com/zh-cn/help/go/work-with-gitlab-merge-requests.html)

| # | 官网功能点 | 官网交互流程 | Arbor 当前实现与差异 | 结论 |
| ---: | --- | --- | --- | --- |
| 1 | 管理传入的合并请求 | 按 status/author/assignee/reviewer/labels 筛选；Overview/Timeline；按 commit 过滤；checkout/show in log。 | Hosting workspace 已有筛选、Overview/Timeline、commit/files、checkout 和 Git Log。 | **部分/P1** |
| 2 | 对合并请求提供反馈 | review mode；文件/单行/多行评论、pending comments、mentions/attachments；Approve/Comment 和 Revoke Approval。 | GitLab discussions、Comment、Approve、Revoke Approval 已接入；Request Changes、draft/multi-line/attachment 和 mentions 仍缺。 | **部分/P1** |
| 3 | 合并或关闭传入的合并请求 | Merge/Squash、Close、Request Review，并处理 GitLab approval/pipeline 状态。 | GitLab Merge/Squash、Close 已接入；Request Review、pipeline/权限状态和完整 capability negotiation 仍缺。 | **部分/P1** |

## 4. 已实施内容与剩余差异

### G-01（P1）Clone 增加 Shallow Clone、Depth 和托管仓库选择

**官网行为**

Clone 对话框允许选择已登录的 hosting service，自动补全可克隆仓库；勾选 Shallow Clone 后填写正整数 depth。浅克隆完成后，主菜单可执行 Unshallow 获取完整历史。

**实施状态（已部分对齐）**

- `Arbor/RebasedDialogs.swift:6651` 的 Clone dialog 已增加 `Shallow clone` 和正整数 `Depth` 校验。
- `Arbor/WorkspaceOperations.swift:3821` 将 depth 传入 clone pipeline；engine 使用 argv 传递 `--depth`，并在创建目标目录前拒绝零值或非法值。
- `Arbor/RebasedWorkspaceViews.swift:1087`、`Arbor/WorkspaceOperations.swift:39485` 的浅仓库识别和 `Fetch Full History` 保持复用。
- `arbor-engine/tests/project_lifecycle.rs` 覆盖 depth 1 和 depth 0 的 clone/unshallow 生命周期。

**剩余差异**

- Clone dialog 仍只接受 URL，没有 JetBrains 的已登录 GitHub/GitLab 仓库选择和搜索。
- Project Trust/Safe Mode 仍属于 IDE 项目执行安全模型，不纳入 Git clone。

**验收状态**

depth 1 的 shallow clone、完整历史拉取、非法 depth fail-closed 和既有 submodule/普通 clone 回归测试均通过；托管仓库选择保留为后续 P1。

### G-02（P1，已部分对齐）建立完整的 GitHub PR / GitLab MR 审查工作台

**官网行为**

PR/MR 是站内完整工作流，不只是链接列表：筛选 → 打开详情/Timeline → 选择 commit/file → checkout 或 show in log → 行/多行评论与 draft review → Approve/Request Changes/Comment → Merge/Squash/Rebase/Close/Request Review。GitLab 还要求 approval revoke、discussion、attachment 和版本能力判断。

**实施状态**

- `Arbor/HostingModels.swift` 和 `Arbor/HostingClient.swift` 已建立 provider-neutral detail、participants、labels、commits、files、timeline、revision SHA、mergeability 和 capability contract。
- `Arbor/HostingViews.swift:223` 起已提供列表筛选（state/title/author/assignee/reviewer/label/branch）及 Overview、Timeline、Commits、Files detail workspace。
- 选择 commit 会按真实 commit ID 异步加载 changed files/diff；`Checkout Incoming Branch` 与 `Show in Git Log` 通过当前 root 的实际 remote/ref 路由。
- GitHub 已接入普通 issue comments、review outcome、merge/close 和 commit-scoped files；GitLab 已接入 discussions、comment/approve/revoke、merge/close 和 commit-scoped diff。
- `Arbor/ArborTests/GitHubClientTests.swift` 覆盖 detail、Timeline、revision SHA 和 commit-scoped files 的 URL contract。

**剩余差异**

- 仍没有 draft/pending review 生命周期、多行评论、附件、outdated position 重映射或 request-review 管理。
- GitHub/GitLab 的 capability 当前由 provider/响应字段映射，尚未完成按账户权限、仓库保护、pipeline/checks 和服务器版本的完整 negotiation；GitLab Request Changes 仍明确不可用。
- GitHub/GitLab 细粒度 action 的 provider contract tests、rate-limit/deleted-branch/outdated-line 恢复测试仍待补齐。

因此 G-02 从“缺口/P0”降为“部分/P1”，但不能宣称与 JetBrains 的完整 review 工作台等价。

### G-03（P1）补齐 Push 的提交级 Changed Files / Diff 和多 Root Target 编辑

**官网行为**

Push dialog 按 repository 展示待推送 commits；选择 commit 后右侧展示 changed files，选择文件后预览 Diff。用户可编辑单个 target branch，也可 `Edit All Targets`。Tags 支持 All / Current Branch，Push/Force Push 是明确动作选择。

**实施状态（已对齐核心流程）**

- `Arbor/PushDialogView.swift:64` 起保留 remote/branch/source/force/tags/hooks/refspec，并增加选中 commit 的 changed-files/Diff pane。
- commit preview 以真实 commit ID 调用 `commitDiff`/`commitFileDiffWithSettings`，异步回写前校验 selection，避免不同 commit 的结果串线。
- `MultiRootPushOptionsDialog` 已支持逐 root target 编辑和显式批量修改；root 使用各自的 repository/remote，不假定同名 remote 指向同一服务器。
- protected branch、force-with-lease、custom refspec、tag-only、hooks 和 rejected recovery 逻辑保持原路径。

**剩余差异**

JetBrains Push 的完整 staged commit graph、按文件/提交展开的所有原生操作和逐项权限/检查状态仍不是同构 UI；核心 changed-files/Diff、target 编辑和安全 push 语义已具备。

### G-04（P1，已对齐核心流程）普通冲突增加简单冲突和非冲突变更批量动作

**官网行为**

Merge Viewer 可一次解决所有 simple conflicts，并允许从左侧或右侧应用所有 non-conflicting changes；这些动作只处理可证明不冲突的块，不覆盖用户已编辑的结果。

**实施状态**

- `arbor-engine/src/conflict.rs:53` 起增加 `ConflictBatchPreview`、区间分类和批量 apply API；分类基于 base/ours/theirs，而非 UI 字符串替换。
- `Arbor/ContentView.swift:8418` 起普通冲突 toolbar 提供 `Resolve Simple`、左右侧 `Apply ... Non-conflicts` 和安全块统计；binary 冲突不提供文本批量动作。
- 批量动作只处理仍 unresolved 且 marker payload 未被手工改写的块，并复用现有 resolved ledger、undo snapshot 和恢复路径。
- `arbor-engine/tests/conflict_workspace.rs` 覆盖 preview/apply、手工修改保护和重启/继续语义。

**剩余差异**

LF/CRLF 的专用 line-separator UI 和 JetBrains 原生提示仍未同构；不影响 Git 冲突块的安全批量处理。

### G-05（P1，已部分对齐）补齐 Changelist 元数据和 Active 归属语义

**官网行为**

Changelist 有 name、description、active、track context；移动 change 时可选已有或新列表、填写 comment、设 active/track context。Active changelist 会接收之后产生的新改动。

**当前证据**

- `arbor-engine/src/changelist.rs:18`：`ChangeListInfo` 仍为稳定的轻量路径投影；V2 元数据另存 description、active、track context/task identity。
- `arbor-engine/src/changelist.rs:26`：V2 持久化列表保存 description、track context/task identity，并保留 active 状态。
- `arbor-engine/src/changelist.rs:310`：`observe_paths` 只把首次出现的新路径归入 active，首次全量 snapshot 不搬动旧改动。
- `arbor-engine/src/changelist.rs:410`：activate 会影响之后新出现的路径。
- `Arbor/WorkspaceOperations.swift:31559`：Create dialog 已支持 description 和 Set active；Track Context 无 task provider 时明确 unavailable。

**实施状态**

`observe_paths` 已在 VFS/status snapshot 之间维护“首次出现”事件：首次全量 snapshot 不搬动旧改动，之后新出现的路径才归属 active list；删除后重建会被识别为新 change。

**实施内容与剩余差异**

1. V2 metadata、V1 无损迁移和临时文件替换已落地；Create dialog 支持 description/Set active，Track Context 在无 task provider 时明确 unavailable。
2. 普通 Move/drag-drop、Shelf target 和删除/重命名复用同一 root-scoped identity；Unshelve comment 会追加到目标 Changelist description。
3. `arbor-engine/tests/changelist.rs` 已覆盖 V1/V2、active 新路径、metadata round-trip、腐坏 fail-closed 和生命周期语义。
4. 统一 Move dialog（新建列表、comment、track context 一次完成）和真实 task/editor context provider 仍未实现；comment 目前由调用方追加到目标 description。
5. Track Context 在 UI 中标记 unavailable，不能勾选后无效果。
6. 删除列表时迁移 assignment；Default 保护和 active 回退已实现。

**验收标准**

- 切换 active 后，新建/首次修改文件进入新 active；旧 change 不移动。
- app restart、external editor change、rename、delete/recreate、nested root 的路径 ledger 保持归属。
- V1 metadata 无损升级；中途写失败不破坏旧文件。
- create/move/delete/drag/drop 和 Shelf target changelist 使用同一 identity；move comment 以目标 description 形式可见。

### G-06（P1/P2，已部分对齐）Shelf 位置、Base 设置和创建 Review Dialog

**官网行为**

Shelf 创建前可在同一 dialog 查看统计/Diff、刷新/恢复和组织文件；设置可控制是否保存 base revision；用户可更改 Shelf directory，并选择迁移现有 Shelf。官网还把 unversioned 文件排除在普通 Shelf 之外。

**当前证据**

- `Arbor/RebasedDialogs.swift:6767`：创建 Shelf 已提供文件统计、默认全选、选择集合和 `Review Diff`。
- `Arbor/RebasedDialogs.swift:7453`：Unshelve/Apply Patch 已有较完整的 file/hunk tree、Diff、target changelist 和 base mapping。
- `arbor-engine/src/shelve.rs:54`：Shelf metadata 有 description/timestamp/lifecycle 状态。
- `arbor-engine/src/shelve.rs:276` 起：list/meta/patch 通过 repository-scoped location resolver 读取，位置可迁移。
- Shelf 内部已有 parent/base，当前效果接近 base setting 永远开启，但没有用户开关。

**实施状态与剩余差异**

1. location migration 已采用 copy-verify-then-switch，失败不写 marker；非迁移模式在旧 Shelf 存在时 fail-closed。`arbor-engine/tests/shelve.rs` 覆盖迁移、refs 保留和失败边界。
2. Unshelve comment 已接入目标 Changelist description；Shelf preview、Recently Deleted、Restore/Delete Permanently、partial hunk 和重启恢复保持 root-scoped。
3. Base revision 当前始终随 revision-backed Shelf 保存，没有 JetBrains 的可关闭开关；这是待明确的产品决策差异。当前 workspace 固定为合并的 Saved Patches，没有 split/combined tab toggle。
4. 普通 Shelf 仍允许 untracked 文件，属于已知行为超集；严格过滤与提示尚未实现。

**验收标准**

- 自定义位置创建/preview/unshelve/drop/recently-deleted/restart 全部读同一 storage。
- 含 active、deleted、recycled、imported raw patch 的迁移前后 ID、内容和 lifecycle 状态一致。
- 迁移过程强制终止后可重试或回滚，不出现半套 Shelf。
- base toggle 尚未实现，旧 Shelf 始终使用保存的 parent/base。
- create dialog 的选中集合与最终 Shelf paths 精确一致，Refresh 不丢合法选择。
- Unshelve comment 在成功、冲突完成和重启恢复后以目标 changelist description 形式保留。

### G-07（P2/平台边界）建立真正的可编辑文件模型后再做 Editor Git Workflow

**官网行为**

官网多处依赖 live IDE editor：gutter markers、line/block rollback、partial commit、move to changelist、inline commit、History for Selection/Block，以及 Safe Delete/Find Usages。

**当前证据**

- `Arbor/FileContentView.swift:116` 明确是“只读工作区文件查看器”。
- `Arbor/FileContentView.swift:219` 使用 `CodeLinesView` 展示文本。
- `Arbor/FileContentView.swift:490` 的 `CodeLinesView` 是行级 `Text`/ScrollView，而非 TextKit editor。

**建议边界**

不要为对齐菜单名称，在只读 viewer 上增加无法跟随实时编辑的伪 gutter action。正确顺序是：

1. 先决定 TextKit 2 / AppKit `NSTextView` editor model，建立 document identity、undo manager、selection/range 和 save/reload conflict。
2. 接入 VFS dirty scopes 和 Git line mapping，明确编辑缓冲区未保存时 Diff/Stage 的基准。
3. 再做 gutter popup、line/block rollback、Stage/Commit、move changelist。
4. History for Selection 需要 range → revision query，必须定义 rename、merge、line movement 和未保存文本边界。
5. Safe Delete/Find Usages 需要语言级 symbol/index；在没有 PSI/LSP usages provider 前保持 out-of-scope。

**验收标准**

- editor undo 与 Git rollback 是两个明确动作，不能互相破坏栈。
- 未保存、外部修改、branch checkout、reset、conflict restore 时有一致的 buffer policy。
- line mapping 在插入/删除、多字节文本、CRLF 后仍指向正确 hunk。
- UI automation 覆盖编辑 → marker → partial stage/rollback → save/refresh。

### G-08（P2/平台边界）明确 Commit Checks 的产品边界

**官网行为**

GoLand before-commit checks 包括 Reformat、Rearrange、Optimize Imports、Cleanup、Copyright、Go fmt、Code Analysis、TODO inspection、Run Configuration，并区分 commit 前后及失败确认。

**当前证据**

- `arbor-engine/src/checks.rs:100` 起是 Git-level checks：identity、conflict、detached/rebase、large file、CRLF、bad filename 等。
- `Arbor/BeforeCommitSettingsView.swift:1357` 提供无 shell 的自定义 argv commands。
- Git hooks、签名、author/committer 等已在 commit pipeline 中接入。

**结论和修复建议**

自定义 command 不等于 IDE-aware checks。当前执行计划明确排除完整代码模型、构建和 Run Configuration，因此本轮不建议伪造 `Reformat/TODO/Code Analysis` checkbox。

若后续纳入，应先定义独立的 `ProjectCheckProvider` 能力协议：语言工具链（首个可做 `gofmt`）、inspection profile、任务/运行配置、输入文件范围、可取消性、失败严重度和“仍然提交”确认。Git-level checks 继续保留，不塞进语言 provider。

**验收标准**

- UI 只展示当前项目真实可用的 provider，不出现无效果选项。
- check 使用本次 commit 的文件集合，而非无条件全项目扫描。
- cancelled/failed/warning 与 bypass 的审计记录明确；不会先部分修改文件后静默提交旧 index。

### G-09（P2，已对齐）补齐 Blame 的 Hide Author 和 Annotate Previous Revision

**实施状态**

- `Arbor/FileContentView.swift:393` 起 `Hide Author` 使用持久化 annotation setting，并真正收缩 author 列布局；现有 whitespace/movement/date 选项继续生效。
- 行 context menu 已增加 `Annotate Previous Revision`，调用 engine 的 first-parent、rename-aware blame；顶部显示 annotation revision，并可返回 Working Tree。
- `arbor-engine/tests/blame.rs` 覆盖 previous revision、rename path、worktree text 和 annotation options。

**剩余差异**

注解列的完整自定义显示/排序设置仍未实现；这属于 P2 交互差异，不再是 Hide Author 或 Previous Revision 的功能缺口。

## 5. 明确产品决策与非缺口

### D-01 固定 Staging Area

`docs/git-parity-decisions.md:41` 已决定保持固定双栏 staging area，并在无 staged changes 时提供显式 `Commit All`，不实现 `Git.Stage.Enable/Disable`。审计应继续把它记录为**决策差异**，不能写成意外遗漏。

如果未来改变决策，不能只加 toggle；必须一起重新定义 Changes Browser、Commit All、Changelist、Shelf 投影、设置迁移和提交语义。

### D-02 不实现完整 PSI/Local History

以下能力依赖完整 IDE 平台，现有范围明确排除：

- Safe Delete / Find Usages；
- PSI/TODO/inspection-aware commit checks；
- Run Configuration before commit；
- History for Selection/Block 的语义级追踪；
- IntelliJ Local History。

这些不是 Rust Git engine bug。若产品将它们纳入，应单独立项编辑器/代码模型/任务运行架构，不能挂在某个 Git action 上临时实现。

### D-03 macOS 平台差异

- WSL Git：不适用。
- Native Keychain：Arbor 已使用 macOS Keychain/credential helper，属于合理平台对齐。
- KeePass 数据库：官网跨平台选项，当前不属于 macOS Git 主链路的阻塞缺口。
- Project Trust/Safe Mode：属于 IDE 项目执行安全模型，不是 Git clone 本身。

### D-04 已有能力，禁止误判

后续评审或实现时，以下项不能再按“完全缺失”处理：

- Clone shallow/depth 与 `Fetch Full History` / unshallow 已实现；缺的是托管仓库选择。
- Update Info tab、root-qualified commit ranges、path filter、auto-open。
- Rejected Push 的 Merge/Rebase recovery。
- Smart Checkout 的 Shelf/Stash 保存、恢复冲突和重启恢复。
- Shelf 的 Recently Deleted、Restore/Delete Permanently、partial hunk apply、external patch import。
- Stash 的 keep-index、untracked/ignored、Apply/Pop/Branch/Drop/Clear 和 preview。
- Changelist 的 V2 metadata、active 新变更归属、create/rename/delete/activate/move/drag-drop 和 Unshelve comment 传播已实现；缺的是统一 Move dialog/task context。
- Blame 的 whitespace/movement/date、Hide Author 和 Previous Revision 已实现；缺的是完整列显示/排序设置。
- Auto Fetch 的 20 分钟 interval key；它是内部高级配置，不是硬编码不可调。

## 6. 后续实施顺序

本轮已完成 G-01、G-03、G-04、G-05、G-06、G-09，并完成 G-02 的 provider-neutral 基础工作台。后续仅针对剩余差异推进：

| 批次 | 范围 | 原因 |
| --- | --- | --- |
| 1 | G-02 review 完整化 | 先补 draft/pending、多行/附件、request reviewers 和 provider capability/权限 contract tests。 |
| 2 | G-01 hosted repository selector | 复用已有 hosting token/URL 模型，避免在 Clone 中重复认证管线。 |
| 3 | G-05 Move dialog/task context | 只有引入 task/editor context provider 后，才扩展独立 comment/history 语义。 |
| 4 | G-06 base toggle/tab split/untracked policy | 先冻结产品决策，再为 Shelf V2 增加可迁移的 optional base 或导航模式。 |
| 5 | G-07/G-08 平台能力 | 只有在产品决定建设编辑器/代码模型后启动。 |

## 7. 代码证据索引

| 能力 | 主要证据 |
| --- | --- |
| Clone / Unshallow | `Arbor/RebasedDialogs.swift:6651`；`Arbor/WorkspaceOperations.swift:3821`、`:39485`；`arbor-engine/src/repo.rs` clone depth；`arbor-engine/tests/project_lifecycle.rs` |
| Branches / Multi-root | `Arbor/RebasedDialogs.swift:1142`、`:13222`；`Arbor/WorkspaceOperations.swift:27786` |
| Pull / Update | `Arbor/PullDialogView.swift:98`；`Arbor/WorkspaceOperations.swift:19937`、`:39719` |
| Commit / Staging | `Arbor/RebasedWorkspaceViews.swift:1558`；`Arbor/DiffDetailView.swift:1099`；`Arbor/WorkspaceOperations.swift:11433` |
| Push | `Arbor/PushDialogView.swift:64`、`:315`、`:462`；`Arbor/WorkspaceOperations.swift:40695` |
| Merge / Rebase | `Arbor/RebasedDialogs.swift:4970`、`:5185`、`:10302`；`Arbor/WorkspaceOperations.swift:11908`、`:41119` |
| Conflict | `Arbor/ContentView.swift:8089`、`:8418`；`arbor-engine/src/conflict.rs:53`、`:246` |
| Changelist | `arbor-engine/src/changelist.rs:18`、`:310`、`:410`；`Arbor/WorkspaceOperations.swift:31559` |
| Shelf / Stash | `Arbor/RebasedDialogs.swift:6130`、`:6767`、`:6853`；`Arbor/RebasedWorkspaceViews.swift:1931`；`arbor-engine/src/shelve.rs:276`、`:367` |
| History / Diff | `Arbor/RevisionBrowserView.swift:15`；`Arbor/DiffDetailView.swift:275`；`Arbor/LogSidebar.swift:1483` |
| Read-only file / Blame | `Arbor/FileContentView.swift:116`、`:393`、`:440`、`:490`；`arbor-engine/tests/blame.rs` |
| Hosting | `Arbor/HostingClient.swift:3`；`Arbor/HostingModels.swift:230`；`Arbor/HostingViews.swift:223`、`:474`、`:700`；`Arbor/GitHubClient.swift:157`；`Arbor/GitLabClient.swift:143`；`Arbor/ArborTests/GitHubClientTests.swift:111` |
| Commit checks | `arbor-engine/src/checks.rs:100`；`Arbor/BeforeCommitSettingsView.swift:1357` |
| Update Info / Auto Fetch | `Arbor/ContentView.swift:517`；`Arbor/WorkspaceOperations.swift:4482`；`Arbor/DiagnosticsLogger.swift:490`；`Arbor/RepositoryIndexRevisionMonitor.swift:2480` |

既有文档的关系：

- `docs/git-parity-matrix.csv`：动作/测试证据台账，粒度比官网页面更细。
- `docs/git-parity-gap-report.md`：历史阶段性差距，不应替代本次官网逐页结论。
- `docs/git-parity-decisions.md`：产品取舍，本审计引用但不重写。
- `INTELLIJ_GIT_PARITY_EXECUTION_PLAN.md`：后续实施计划；本文件通过评审后再回写任务。

## 8. 覆盖校验

以下计数只包含每页正文的二级/三级功能段落，不包含页面标题和站点页头：

| 页面 | 已审计段落数 |
| --- | ---: |
| 设置 Git 仓库 | 12 |
| 管理 Git 分支 | 16 |
| 与远程 Git 仓库同步 | 4 |
| 提交并推送 | 14 |
| Merge/Rebase/Cherry-pick | 11 |
| 解决冲突 | 3 |
| 添加并跟踪文件 | 5 |
| 撤销更改 | 9 |
| Changelist | 4 |
| Shelf/Stash | 13 |
| 调查更改 | 15 |
| 编辑项目历史 | 6 |
| 比较文件版本 | 4 |
| GitHub PR | 3 |
| GitLab MR | 3 |
| **合计** | **122** |

## 9. 审计限制

1. 本轮是代码和文档审计，没有为 122 个段落逐一执行 UI 自动化；“对齐”表示已有代码/测试证据支持核心用户结果，不表示 SwiftUI 生命周期与 JetBrains 平台逐像素相同。
2. 官网会继续更新。开始实现前应记录页面版本或再次核对相关目标段落，避免按过期交互开发。
3. Hosting provider 的服务器版本、仓库权限和 API capability 会影响可用 action；G-02 必须以 capability negotiation 设计，不能只按当前测试账户硬编码。
4. 本文件没有修改 `docs/git-parity-matrix.csv` 的历史状态。用户确认范围后，再为批准实施的 gap 添加新的 action/test rows。
