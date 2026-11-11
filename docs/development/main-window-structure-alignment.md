# Arbor 主页面结构对齐

本轮只调整面板和操作入口，不调整配色、字体或图形画法。参考为本机运行的
Rebased **1.1.13**，窗口 1642×1015；旧截图位于 `docs/images/baseline/`。

## 运行证据更正（2026-11-11）

通过 macOS Accessibility 读取 Rebased 主窗口，并在 Commit 工具栏回弯箭头上悬停：

- 项目菜单与分支菜单之间的按钮名称是 **Update Project... / Push…**。
  截图中的 ↙ / ↗ 不是前进/后退，因此保留 Arbor 的 Update / Push。
- 普通 Commit 模式的工具栏顺序是 **Refresh / Rollback… / Show Diff /
  Shelve Silently / View Options / Select Opened File in Changes View /
  Expand All / Collapse All**。回弯箭头是 Rollback，双向箭头是 Show Diff，
  不能把它们当成 Undo / Redo。右侧 Changes 工具栏同样暴露 Show Diff /
  Revert Selected Changes / View Options / Expand All / Collapse All。
- `docs/rebased-action-audit.md` 的 `Git.Stage.Toolbar` 是 staging 模式动作清单，
  不是旧截图中普通 Commit 工具栏的顺序。该文档已记录 Arbor 固定 staging 模式
  的产品决策；本轮保留该决策，移除 Arbor 插入的常驻次要动作。
- 活动栏顶部的控件名称是 Commit，截图图形确实是滑杆状图标；底部为 Terminal / Git。
  不把顶部 Commit 图标改成分支图标。
- ProjectFileTreeView 已使用 repositoryFileSymbol，Swift、Markdown、配置等文件
  已有不同类型图标；本轮只接入缺失的状态徽标。

## 本轮实现

| 项目 | 结果 |
| --- | --- |
| 顶栏右侧额外 ··· | 移除；已有 Git 动作继续从 VCS → Git 进入，补入托管评审、Stage 和复制分支名入口 |
| Commit 工具栏 | 保持 preview / refresh / stage tracked / stash / view options；Expand/Collapse 靠行尾；Stage all、Stage without content、New Changelist 移入标签条 Options |
| Commit 标签条 | Options 旁增加可直接点击的 Hide Commit Tool Window |
| Amend 计数 | N modified，统计去重的已跟踪改动；部分暂存只计一次，未跟踪和 ignored 不计 |
| Commit 页脚 | 常驻 Commit / Commit and Push…；条件性的 Commit All / Commit and Rebase 移入齿轮，保留原启用条件和确认流程 |
| 文件行尾 | 移除 Partial stage 按钮，操作保留在文件右键菜单 |
| Project 文件行 | 接入现有 StatusBadge；保持现有文件类型图标和状态索引 |
| 活动栏底部 | Terminal（操作日志）与 Git（提交历史）；More 菜单列出 Commit / Project / Git / Terminal / Operation Log |
| Changes 工具栏 | Show Diff / Revert Selected Changes / View Options / Expand All / Collapse All |
| Project 头部 | 新建文件或目录、定位打开的文件、展开选中目录、全部折叠、定位到 Changes、Options、Hide |
| Branches 竖条 | Log 左缘在面板收起时显示 Branches 竖条，点开展开完整面板。展开状态仍写入 arbor.log.branches.visible.v1，默认收起 |
| 首次详情 | 没有已保存的选中行时，Changes 与 Commit Details 保持空状态；刷新仍保留还在列表里的明确选择 |

## 已对齐，保持原样

Commit/Stash + 下方 Project + 中部 Log；无多余 Commit 标题行；628 pt 左栏；
Commit 高度默认 466 pt；Changes + 全选；默认隐藏 ignored；独立折叠的
Unversioned Files；单行 Log 过滤条；Author/Date 列；Stash 底部 Apply/Pop 与
顶部 Show Diff/Expand/Collapse。

## 随后补上的项

- Changes 与详情的默认比例按 Rebased 1.1.13 `MainFrame` 的 `vcs.log.details.splitter.proportion`（0.7）实现，分割条可双向拖动，并记住比例。
- Stash 工具栏增加 Group By，按目录折叠选中贮藏的文件清单。
- 1642×1015 的无障碍树基线已按这轮结构重写。

活动栏顶部仍是滑杆状 Commit 图标：运行中的 Rebased 1.1.13 也是这个图形，控件名称为 Commit。B 换肤不在这轮。

状态栏、IDE 通知、图线样式和 Commit 文件名着色均按原清单保留差异。

## 验证（2026-11-11）

`./scripts/ui-smoke.sh --no-build` 定向结果：

- `testChangesGroupingPreservesStagingAndPartialState` 通过（38 秒）。
- `testCommitStructureAndRelocatedActions` 通过（30 秒）。
- 此前 `test01DailyCommitClonePartialStageCommitPush` 通过（89 秒），覆盖右键 Partial stage。
