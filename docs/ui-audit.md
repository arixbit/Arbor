# UI 审计：快捷键、菜单启用条件、无障碍标签（Phase 5）

生成时间：2026-08-15。审计范围：Arbor SwiftUI 前端的快捷键绑定、菜单/按钮启用
条件、无障碍标签与中英文文案。

## 1. 快捷键对照（IntelliJ Git → Arbor）

| 功能 | IntelliJ | Arbor | 位置 |
|---|---|---|---|
| Update Project | ⌘T | ⌘T | ArborApp.swift / Toolbar |
| Commit | ⌘K | ⌘K | ArborApp.swift / Toolbar |
| Push | ⌘⇧K | ⌘⇧K | ArborApp.swift / Toolbar |
| Search Everywhere | Shift+Shift | ⌥⌘O | ArborApp.swift VCS 菜单 |
| Branches Popup | Ctrl+Shift+` | 工具栏分支按钮 | Toolbar principal |
| Pull (Merge / Rebase) | ⌘T 子选项 | VCS 菜单 Pull > Merge/Rebase | ArborApp.swift |

缺口记录：Branches Popup 无键盘绑定（IntelliJ macOS 也移除了该绑定）；commit
And Push 无快捷键（IntelliJ ⌥⌘K），已列入 parity-decisions 决策 15。

## 2. 菜单/按钮启用条件审计

| 控件 | 启用条件 | 实现 |
|---|---|---|
| Update / Push / Fetch | `repo != nil && !remotes.isEmpty` | Toolbar `.disabled` ✓ |
| Commit | `repo != nil`；操作进行中（operationState != nil）时禁用 | RebasedCommitWorkspace `.disabled` ✓ |
| Commit and Push | 同 Commit + `!amendMode && hasStaged && message 非空` | ✓ |
| Shelve | 操作进行中禁用 | ✓ |
| Complete Merge / Continue | 冲突全部解决后启用（conflictPaths.isEmpty） | MergeRevisionsDialog 非模态 resolver panel ✓ |
| Start Rebase（todo 编辑器） | 有 todo 时启用；空 interactive range 显示 no-op Continue/Cancel 确认；multi-root 空 todo 仅提示确认，加载失败仍禁用；`--onto` 旁提供上下文帮助 popover；native todo 预览可编辑 control-row 参数 | RebaseTodoEditorView / MultiRootRebaseTodoEditorView / RawRebaseTodoEditorView / RebasedRebaseDialog ✓ |
| Add remote | name/url 非空 | RemoteConfigDialogView ✓ |
| Set Branch（submodule） | branch 输入非空 | SubmodulePanel ✓ |
| Reset（面板） | mode=hard 红色警告 | RebasedResetDialog ✓ |

## 3. 无障碍标签审计

- 工具栏与行内图标按钮均有 `.help()`（悬停提示），macOS 会将其作为
  accessibilityLabel 的一部分暴露 ✓
- Changes 行：Toggle 使用 `.labelsHidden()` + 行内文本，辅助功能可聚焦文本 ✓
- 危险操作（Drop/Delete/Remove/Abort/Reset hard）使用
  `role: .destructive` 或红色提示 ✓
- 新增控件（Search Everywhere、SubmodulePanel、RemoteConfigDialog）均有
  可见文本标签，无纯图标无提示的控件 ✓
- 待改进：LogGraph 画布（Canvas）无 accessibility 元素（图形本身对
  辅助功能不可见，依赖右侧列表行）——记录为已知限制。

## 4. 中英文文案审计

- 引擎错误：全部结构化（无用户文案），Swift 层本地化 ✓（D7 原则）
- UI 文案：截至 2026-08-21，`scripts/i18n-audit.py` 扫描 1071 个字面量，
  **缺失 124 个 catalog key、未翻译 0 个**；新增 Git Attributes 设置文案已补齐
  zh-Hans，剩余缺口主要集中在近期新增的 Branches、Apply Patch、Rebase
  Recovery 等入口。
- Git 术语保留英文：rebase/squash/stash/cherry-pick/force-with-lease ✓

## 5. 长耗时操作与主线程

- 所有引擎调用均在 `Task.detached` 后台执行，主线程只做状态更新 ✓
- log 加载带 generation 取消：切换过滤条件后旧请求结果直接丢弃 ✓
- 大仓库分页：200 条/页 + after_id 游标 + loadMoreLog ✓
- 持久化缓存（跨进程 status/log cache）：未实现，标注为 Phase 5 已知
  限制（当前依赖 gix 增量计算 + UI 层 generation 取消）。
