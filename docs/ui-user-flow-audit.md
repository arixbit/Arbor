# 临时仓库 UI 用户路径验收

日期：2026-10-25。源码基线：`a3fe006`，Arbor 1.0.24。

## 结果清单

| 分类 | 结论 |
| --- | --- |
| 已通过 | 三组 Git 路径均已通过真实界面操作，并用 Git 核对提交、索引、文件、分支和本地远端。部分暂存修复后专项通过。 |
| 已通过 | 中文冲突面板在 980×640 窗口内完成接受 Theirs → 标记已解决 → 完成 Merge；三栏标题显示中文。 |
| 已通过 | Rust 恢复相关测试 47 项、Swift 单元测试 736 项；最终应用构建和完整文案审计通过。验证时间边界见末尾。 |
| 已通过 | 最后追加的中文数量断言已复跑：`1 个冲突文件`、`已选择 1 项`和原生三栏标题通过，实际完成 Merge，Git 状态干净。 |
| 已通过 | 已取得同一临时仓库的 Arbor / Rebased 分支弹窗配对截图和 Rebased 控件树；窗口同宽，高度相差 25 pt。 |
| 操作受阻 | 用户要求先提交并推送现有代码，但本轮提交及推送执行请求被拒绝；没有生成新提交或推送。 |
| 操作受阻 | 分支弹窗底部动作已收进菜单，并补充长分支搜索、入口去重及 Merge 菜单回归用例；后续 UI 执行和仅编译请求均被拒绝，这部分尚未编译或实机复跑。 |
| 与 Rebased 行为不同 | 首次打开同一临时仓库，Rebased 1.1.13 要求确认项目可信，Arbor 直接进入工作区。本轮保留这一流程差异。 |
| 与 Rebased 行为不同 | Arbor 分支弹窗原有独立标题、说明和重复的底部按钮；Rebased 搜索位于最上方，操作和分支放在同一棵树中。详见同页截图和后续修改边界。 |

macOS 的 Enable UI Automation 身份验证已完成，后续用户路径测试正常运行。用户也已确认 Rebased 的 Trust Project，目标临时仓库已打开。

2026-10-26 审批排查：用户确认没有看到执行审批卡。当前任务为 `auto` 模式，提交、构建和 UI 执行请求在进程启动前返回 `rejected by user`，不能据此认定用户点击了拒绝。本机安装包中的命令审批处理器只向工具返回 `decision`，丢弃了具体拒绝理由。日志记录自动审批主服务返回 429 后备用模型成功响应，因此 429 尚不能确认为拒绝原因。等待用户在任务权限选择器中改为“默认权限”，再通过可见确认卡恢复执行；无需重做 macOS 身份验证或 Trust Project。

## 方法与范围

`ArborUIUserFlowUITests` 为每项测试建立独立临时工作区和本地 bare remote。文件修改由 fixture 注入；克隆、暂存、提交、Push、分支、冲突与恢复动作通过实际菜单和按钮执行。每步之后使用 Xcode 附带的真实 Git 核对结果。

Push/Fetch/Pull 的远端均为临时本地仓库，HTTPS/SSH 身份验证不在本轮覆盖内。项目本身尚未推送本批改动。临时仓库保留，日志输出 `USER_FLOW_FIXTURE` 和 `USER_FLOW_PASS`。

## 已通过的具体操作

| 用例 | 路径 | Git 核对 |
| --- | --- | --- |
| 01 | 打开/克隆 → 两处修改 → 只暂存一处 → 提交 → Push | index 和新提交仅含选中修改；另一处留在工作区；bare remote main 等于 HEAD。 |
| 02 | Fetch → Pull → 切分支 | Fetch 只更新 origin/main；Pull 更新 HEAD 和文件；切回 topic 后文件树正确。 |
| 03 | Merge → 冲突 → 接受 Theirs → 标记已解决 → 完成 | 双父提交、topic 内容、干净工作区。 |
| 04 | Merge 冲突 → 中止 → 确认 | 原 HEAD、原文件和干净状态恢复。 |
| 05 | Rebase → 冲突 → 解决 → 继续 | main 的新提交以 topic 为父提交，保留当前修改，工作区干净。 |
| 06 | Rebase 冲突 → 中止 → 确认 | 原 HEAD、main 和文件内容恢复。 |
| 07 | 历史 Diff → Cherry-pick → Revert → Mixed Reset | Diff 包含目标内容；反向提交删除目标文件；Reset 移动 HEAD、清空 index，保留本地文件。 |
| 08 | Stash 保存 → Pop 并恢复暂存状态 | stash 清空，原 staged/unstaged、index diff 和文件内容恢复。 |
| 09 | 两项目窗口分别操作菜单 | Stash 仅作用于当前项目；关闭第二窗口后首窗口菜单继续可用。 |
| 10 | 980×640 中文冲突工作台 | 主要按钮位于窗口内，实际完成 Merge；三栏标题跟随应用语言。 |
| Fixture | 创建与检查临时远端 | 初始状态干净，origin/main 与 HEAD 一致。 |

主套件结果为 10/11；唯一失败项是部分暂存按钮位于横向滚动区域外。修复后用例 01 专项为 1/1，克隆、部分暂存、提交、Push 的全部 Git 断言通过。以上 11 项均有通过记录，证据来自主套件及专项复跑。

## 按影响修复

1. **Merge 中止留下冲突标记。** 原实现只重建 index，未恢复文件。现在先刷新 gix index 的文件 stat，再用 `git reset --merge <ours>` 同步恢复；回归验证冲突文件复原、合并新增文件删除、无关 tracked 修改及 untracked 文件保留。
2. **Rebase 继续启动命令行编辑器。** 保留已有消息编辑脚本；无脚本时设置 `GIT_EDITOR=true` 接受已有消息。回归刻意设置 `core.editor=false`，仍能继续且保持提交消息。
3. **AppKit 启动窗口的 VCS 菜单禁用。** 菜单上下文绑定实际 key window，通知携带目标项目路径；两项目窗口测试核对作用目标。
4. **部分暂存受侧栏宽度限制。** 复用 Diff 编辑器打开弹窗，主暂存按钮固定在横向滚动区外。900 pt 宽弹窗验证选中行、按钮边界、index、提交及 Push。
5. **File 菜单重复、Pull 默认分支错误。** 项目入口使用系统 File 命令组；Pull 复用正确的远端前缀解析。
6. **中文冲突面板溢出。** 浮层尺寸随窗口收缩；单 root 隐去重复 root 列；次要工具可横向滚动，标记已解决、完成和中止保持可见。
7. **分支弹窗列表被重复按钮挤压。** 新修改去掉底部重复的 Commit / New Branch / Checkout 入口，其余底部操作收入 `Actions` 菜单，保持已有回调和禁用条件。新增 UI 用例验证列表首屏、长分支搜索及菜单实际打开 Merge；编译和执行请求被拒绝，尚未验证这次修改。

Reset 测试等待 HEAD、index 和恢复快照全部就绪后再核对结果，避免将生成快照时的临时暂存误判为最终状态。输入测试改为直接键入，避免其他应用更新共享剪贴板影响输入。

## 多语言与布局

新增 93 个 catalog key，补齐 2 个既有数量条目的中文。审计扩大到 Picker、Section、GroupBox、ProgressView、alert、confirmationDialog、navigationTitle，以及原生界面使用的 `localizedArborString`。

最终审计：扫描 1,623 处字面量；未登记 key 0，缺 zh-Hans 0，硬编码中文 0。93 个新增和 2 个修改条目在 catalog、翻译补充文件、最终构建资源中全部一致。该审计覆盖常用 API 的静态文案；动态文案仍需结合页面检查。

原生三栏标题显式使用应用所选语言的资源 bundle；语言更新只更新标题，保留结果编辑内容。截图还发现动态数量、顶部操作标题和恢复提示采用不同语言来源，已针对这些位置补齐。最终应用中的 zh-Hans 资源已核对数量、结果标题、安全合并统计和恢复提示。最后新增的数量 UI 断言已通过；最新截图确认顶部操作标题、安全合并统计和底部恢复提示均显示中文。

![部分暂存：选中第一处、保留第二处](images/ui-user-flow-audit/partial-stage.png)

![980×640 中文冲突面板](images/ui-user-flow-audit/conflict-zh-hans-980.png)

中文截图已更新为最后一次通过的专项结果，包含新增数量和恢复提示翻译。

## 分支弹窗 UI 对照

共享 fixture 为 `.build/UISmoke/branch-comparison-fixture`，包含长分支 `feature/localization-audit-with-a-deliberately-long-branch-name`。用户确认 Trust Project 后，已取得双方分支弹窗截图。

窗口实测：Arbor 为 1642×1015，Rebased 为 1642×1040；Rebased 高度无法通过本轮拖拽调整到目标值。`osascript` 设置窗口尺寸因未获辅助访问而失败（`-1719`）。因此只对照同宽窗口内的弹窗结构，不声称双方完整窗口逐像素一致。两应用当前分别使用深色和浅色主题，本轮也不比较配色。

![Arbor 分支弹窗：当前基线](images/ui-user-flow-audit/arbor-branch-popup.png)

![Rebased 分支弹窗：同仓库对照](images/ui-user-flow-audit/rebased-branch-popup.png)

| 项目 | Arbor 截图基线 | Rebased 1.1.13 |
| --- | --- | --- |
| 弹窗尺寸 | 默认 350×560，来自源码设置 | 375×353，来自无障碍树 |
| 顶部 | 独立 Branches 标题、搜索框、说明文字 | 搜索框与 Fetch / Settings 同行 |
| 主要操作 | ACTIONS 列表和底部按钮重复 | Commit、New Branch、Checkout 各一个列表入口 |
| 列表空间 | 底部常驻按钮占用较多高度，首屏分支很少 | 树视口 305 pt，行高 24 pt；Recent 下可见多行，Local 可折叠 |

已按影响写好最小修改：保留现有搜索及分支树，删除底部三处重复入口，将剩余底部动作收入 `Actions` 菜单。这部分尚未通过编译或 UI 验收，上方 Arbor 截图仍为修改前基线。

仍需复跑：底部精简后的列表空间、长分支搜索与截断、Actions → Merge → Cancel、中文分支弹窗。标题、搜索框位置、默认尺寸和目录树样式尚未逐项对齐。

## 交付前对抗审查

按最容易产生错误结果的顺序复查：

1. **恢复丢失无关修改。** Merge 回归同时核对 tracked 编辑、untracked 文件和合并新增路径；16 项 merge 测试通过。
2. **Rebase 改消息或依赖外部编辑器。** `core.editor=false` 回归通过，并额外核对原提交消息；9 项 rebase 测试通过。
3. **按钮存在但点击无效。** 部分暂存增加弹窗边界断言，以真实 index、提交、Push 核对执行结果；中文页以完成 Merge 验证可达性。
4. **菜单作用于错误项目。** 两窗口分别 Stash，另一仓库保持原状态，并验证关窗后首窗口继续工作。
5. **新布局破坏入口或结论超出证据。** 静态核对底部移除的三项仍在顶部 action 列表，其余操作保留原回调和禁用条件；实机回归请求和编译请求被拒绝，明确保留未验证状态。配对截图记录实际窗口高度和主题差异；临时远端 Push 验收与项目本身推送分别记录。

## 验证记录与复跑入口

- Rust：先通过 cargo fmt --check；merge 16、rebase 9、reset 19、user_journeys 3，合计 47 项通过。新增原消息断言后的 rebase 单项再次通过。
- Swift：736 项单元测试通过，时间在最后的部分暂存按钮及少量文案调整之前；之后应用重新构建成功，部分暂存 UI 专项通过。以上均早于本次分支底部布局修改。
- 主 UI：`build/user-flow-audit/final-journeys/20261025-215720.xcresult`。
- 日常提交修复后：`build/user-flow-audit/daily-final/20261025-220355.xcresult`。
- 最终中文专项 1/1：`build/user-flow-audit/chinese-final/20261025-222600.xcresult`。
- Swift：`build/user-flow-audit/swift-unit-tests.xcresult`。
- 分支弹窗配对截图 1/1：`build/user-flow-audit/branch-parity-captured/20261025-223253.xcresult`，尚未包含新的底部菜单布局。
- 导出截图、无障碍树和清单保留在 `build/user-flow-audit/`。
- 最后追加的中文数量 UI 断言已执行通过；恢复提示同时经过最新截图核对。

```sh
cargo fmt --manifest-path arbor-engine/Cargo.toml --check
cargo test --manifest-path arbor-engine/Cargo.toml --test merge --test rebase --test reset --test user_journeys
python3 scripts/i18n-audit.py
./scripts/ui-smoke.sh --only ArborUIUserFlowUITests --report build/user-flow-audit/results
```

中文新增断言和 Rebased 分支配对截图已完成。按用户最新要求，接续顺序为：恢复执行审批后先提交并推送现有代码（保留分支新布局尚未编译和实机验收的说明），再完成分支布局构建和回归，更新 Arbor 配对截图、补查中文分支弹窗。

```sh
./scripts/ui-smoke.sh --only ArborUIVisualCaptureUITests/testBranchPopupReferencesAndActionsStayReachable --report build/user-flow-audit/branch-layout-final
./scripts/ui-smoke.sh --no-build --only ArborUIVisualCaptureUITests/testCaptureBranchPopupParity --report build/user-flow-audit/branch-parity-final
```
