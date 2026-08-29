# Git transport progress parity

## 已接入

- `arbor-engine/src/gitprocess.rs` 将 Git 的 `stderr` 传输输出按 `\r`/`\n` 分割，识别 `Receiving objects`、`Resolving deltas`、`Writing objects`、`Counting objects` 等百分比阶段。
- `GitProgressState` 通过 UniFFI 的 `git_progress_state()` 暴露当前 command category、phase、percentage、脱敏 detail，以及 multi-root 的当前 root、已完成 root/总 root 和 terminal state。
- `Arbor/FeedbackCenter.swift` 在已有 FeedbackCenter operation 生命周期内轮询快照；操作成功、失败、取消或启动失败都会清除快照。
- `Arbor/RebasedWorkspaceViews.swift` 在状态栏显示阶段和百分比，保留已有的进程组取消按钮；点击运行中的操作会打开 Operations 工具窗的 `GitTasksView`。
- `Arbor/FeedbackCenter.swift` 的 `GitTasksView` 显示当前操作、transport 百分比、multi-root/batch 进度、同一取消句柄和最近完成的操作；历史详情仍复用 `OperationLogView`，不复制第二套操作状态。
- Fetch、Pull、Push、Update Project、Merge、Rebase、Checkout、Reset 的多 root runner 还会发布当前 root 的 path/name、已完成 root/总 root 和 completed/skipped/failed/paused 状态；root 内真实 Git transport 的百分比仍覆盖主进度百分比，native rebase 的 `Rebasing (n/m)` 也会显示为百分比，gix Merge 与 object-level Rebase 则显示 indeterminate progress。嵌套 system-Git 命令结束后会恢复外层 root 快照，不会吞掉 terminal state。
- Native structured/branch-targeted/root/non-interactive rebase now uses the same `GitCommandSpec` runner as raw-todo rebase, so `GitCancelHandle` kills the Git process group and `FeedbackCenter` receives the same progress snapshot. If Git has already created `rebase-merge`/`rebase-apply`, cancellation preserves that recovery state for Continue/Skip/Abort.

## 证据

- Rust `gitprocess::tests::parses_git_transport_progress_lines`：remote 前缀、正常百分比、无进度文本和非法百分比。
- Rust `gitprocess::tests::progress_parser_handles_carriage_return_updates_and_split_chunks`：Git 的原地刷新和跨 pipe chunk 的半行。
- Rust `gitprocess::tests::parses_native_rebase_progress_lines`：native rebase 的 `Rebasing (n/m)`、0% 起点和超过总数的拒绝。
- `arbor-engine/tests/rebase_options.rs`、`rebase_todo.rs`、`rebase_merges.rs`、`multi_root.rs`：native structured/root/branch/non-interactive rebase 的成功、暂停、失败恢复和多 root 结果保持不变。
- `xcodebuild test -quiet -project Arbor/Arbor.xcodeproj -scheme Arbor -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`：SwiftUI/UniFFI 编译与测试通过。

## 尚未完成

- gix Merge 与 object-level Rebase 仍没有 Git transport 百分比；native rebase 已有 `Rebasing (n/m)`，但比 fork 的 ProgressIndicator 阶段/重试模型更粗。
- Git Tasks 面板已经覆盖当前运行任务的展开式反馈；其它自定义 runner 的完整 root 级实时聚合、重试策略和并发任务队列仍缺；这部分不能由单一 FeedbackCenter 快照推断完成。
- 仍有直接 `git_command().output()` 的调用点；它们遵守 Git executable，但不会产生细粒度进度事件，继续按 `docs/git-command-call-sites.md` 迁移。
