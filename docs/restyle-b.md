# B 方案换肤：执行记录与令牌表

B 方案（Linear 式极简、深浅双色）的落地记录。原则只有一条：**结构不动，只换皮肤**。
面板位置、入口顺序、操作流程、快捷键、文案含义全部保持现状；改的是颜色、间距、
圆角、边框和层级。

令牌的代码定义在 `Arbor/Theme.swift`，校验在 `Arbor/ArborTests/ThemeTokensTests.swift`。
本文档只记录「表里定死的数值」和「已经做到哪一步」，改调色改前者、追进度改后者。

## 一、面板与文件对照

步骤 0 的成果。行动手前先确认归属文件，别在错误的文件里换色。

| 面板 | 实现位置 |
| --- | --- |
| 1 · 顶栏 | `Arbor/Panels/Panels+Core.swift` → `RebasedTopBar` |
| 2 · 左侧导航与活动栏 | `Arbor/Panels/Panels+Core.swift` → `RebasedActivityRail`；侧栏容器 `Arbor/MainWindow/ContentView+ToolWindows.swift` → `workspaceSidebar` |
| 3 · Log 提交列表 | `Arbor/Log/Log+ContentView.Log.swift`、`Arbor/Log/Log+ContentView.Columns.swift`；分支图 `Arbor/Log/LinearBekGraph.swift`、`Arbor/LogGraphView.swift` |
| 4 · 右侧提交详情 | `Arbor/CommitDetailView.swift`；文件树 `Arbor/ProjectFileTreeView.swift` |
| 5 · Commit / Stash | `Arbor/Panels/Panels+Commit.swift`、`Arbor/Panels/Panels+Staging.swift`、`Arbor/Stash/` |
| 6 · Diff | `Arbor/UnifiedDiffView.swift`、`Arbor/Log/Log+Diff.swift`、`Arbor/Log/Log+DiffToolbar.swift` |
| 7 · 状态栏 | `Arbor/Panels/Panels+Project.swift` → `RebasedStatusBar` |

窗口与入口：`Arbor/ContentView.swift`（`arbor.appearance` 三档开关在 131–132 行，
应用点在 `preferredAppearance`）。

## 二、颜色债务：口径要先改

原计划写的是「全局搜索写死的十六进制色值」。实际搜下来主页面 Swift 代码里没有
hex 字面值（全仓仅 `Monitoring/RepositoryExternalVCSSnapshots.swift` 4 处，与 UI 无关），
照原来的口径会得出「已经清零」的错误结论。

真正的债务是**语义色字面值**（`Color.red`、`Color.primary.opacity(0.12)`、
`.foregroundStyle(.secondary)` 这类），共 222 处，集中在：

| 文件 | 处数 |
| --- | --- |
| `Panels/Panels+Core.swift` | 20 |
| `Panels/Panels+Commit.swift` | 16 |
| `Dialogs/Dialogs+MultiRootBranchesPopover.swift` | 16 |
| `Dialogs/Dialogs+BranchesPopover.swift` | 13 |
| `LogGraphView.swift` | 11 |
| `Log/Log+MultiRootBranchesPanel.swift` | 10 |
| `Log/Log+BranchesPanel.swift` | 8 |
| `PushDialogView.swift` | 8 |
| `Lfs/LfsPanelView.swift` | 6 |

清零检查以此为准：某个面板改完后，该文件里不应再出现语义色字面值，除非能说明
为什么它是例外（例如系统语义色的 `Divider`、编辑器内部着色）。

## 三、令牌表

深浅两套共用同一批名字，只换取值。代码里的名字就是下表的左列（`Theme.Palette.*`）。

| 令牌 | 深色 | 亮色 | 用在哪 |
| --- | --- | --- | --- |
| `window` | `#08090A` | `#FBFBFA` | 窗口与主区底色 |
| `surface` | `#131417` | `#F4F4F2` | 搜索框、输入框、次按钮 |
| `surfaceInset` | `#0C0D0F` | `#FFFFFF` | Diff 与代码区，与窗口拉开半档 |
| `ink` | `#F7F8F8` | `#17181A` | 主文字、选中态文字 |
| `inkSecondary` | `#8A8F98` | `#6E7278` | 作者、文件说明 |
| `inkTertiary` | `#62666D` | `#9AA0A8` | 时间、哈希、分组标题 |
| `border` | 白 7% | 黑 7% | 头发丝边框与分隔线 |
| `accent` | `#5E6AD2` | `#5E6AD2` | 全应用唯一强调色 |
| `accentInk` | `#9BA3F0` | `#4C57B8` | 分支 / 版本胶囊文字 |
| `selectionFill` | accent 13% | accent 9% | 选中行填充 |
| `selectionStroke` | accent 35% | accent 32% | 选中行内描边 |
| `navSelection` | 白 6% | 黑 5.5% | 侧栏导航选中 |
| `rowHover` | 白 3% | 黑 3% | 列表悬停 |
| `addition` | `#3FB27F` | `#3FB27F` | 增行数、Diff 新增 |
| `deletion` | `#E5484D` | `#E5484D` | 删行数、Diff 删除 |
| `additionFill` | 绿 12% | 绿 10% | Diff 新增行底色 |
| `deletionFill` | 红 12% | 红 10% | Diff 删除行底色 |
| `primaryFill` | `#F7F8F8` | `#17181A` | 主按钮填充（两种模式下反相） |
| `primaryInk` | `#08090A` | `#F7F8F8` | 主按钮文字 |

尺寸、间距、圆角（两种模式完全一致）：

| 项目 | 取值 |
| --- | --- |
| 顶栏高 | 52 |
| 侧栏导航行高 | 34 |
| 搜索框高 | 32 |
| 按钮高 | 36 |
| Log 行内边距 | 9 / 10 |
| 面板内边距 | 18 / 20 |
| 增删比例条高 | 3 |
| 圆角（导航行 / 行·按钮·输入框 / 窗口） | 7 / 8 / 12 |
| 选中描边宽 | 1 |
| 禁用与加载态 | 透明度 50% |

字号：正文 13.5、标题 14、分组标题与等宽哈希 11.5、分组标题字距 0.6。

## 四、进度

| 期 | 内容 | 状态 |
| --- | --- | --- |
| 第一期 | 步骤 0 基线盘点、步骤 1 令牌层、步骤 2 深浅切换 | 完成 |
| 第二期 | 面板 1–3：顶栏、侧栏、Log 列表 | 未开始 |
| 第三期 | 面板 4–7：详情、Commit / Stash、Diff、状态栏 | 未开始 |

第一期动到的文件：

| 文件 | 改动 |
| --- | --- |
| `Arbor/Theme.swift` | 新增：B 令牌表、尺寸常量、字号常量、三档外观取值映射 |
| `Arbor/ArborTests/ThemeTokensTests.swift` | 新增：13 项令牌校验 |
| `Arbor/ContentView.swift` | `preferredAppearance` 改走 `Theme.preferredColorScheme(forOverride:)`（取值语义不变） |
| `Arbor/project.yml` | 注册新文件 |

第一期故意没做的事：**没有把任何一份令牌接到视图上**。所以这一步跑完，界面和改动前
应该逐像素一致——令牌只是被定义、被测试钉住，还没被消费。

验收方式：

- `xcodebuild test` 全绿（756 个用例，其中 13 个是本轮新增）。
- `scripts/i18n-audit.py`、`scripts/audit-user-surface.py` 两个 CI 审计全绿。
- 三档外观的取值映射有单测（`testAppearanceSettingKeepsItsThreeStates`）。
  外观开关本身仍是 `arbor.appearance` 这个 defaults 键，没有新增设置入口；
  手动验收可用 `defaults write com.arbor.app arbor.appearance -string dark`（或 `light`）
  后重启，恢复跟随系统就把值清空。

## 五、待定

- ~~**字体**~~（已定）：按令牌表统一到系统字体 SF Pro。`Design.Typography.interface()`
  改为 `.system(size:weight:)`，默认字号取令牌的正文 13.5；Inter 的 otf 仍留在包里
  但不再被引用。Diff 的代码字体按令牌表保持现状（`Typography.code` 未动）。
  验证：三个快照基线不变（几何差异小于 1pt），行高与过滤条布局的既有测试全过，
  视觉基线图已按新字体重拍。
- **分支图配色**：原计划要求「未选中中性灰阶、选中行节点用窗口底色描点」，而现状
  `Design.Colors.graphPalette` 是紫青多色分配。这是行为可见的改动，需要单独确认，
  不混在换肤里顺手改。
- **基线截图**：原计划要求改版前在深色下截图存档。仓库已有 `scripts/ui-snapshot.sh`
  与 `docs/visual-baseline.md`，第一次跑面板 1 时补上深色基线图。
