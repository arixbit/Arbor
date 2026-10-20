import Foundation
import SwiftUI

/// 操作恢复、冲突解析与操作日志的窗口状态。
@MainActor
final class OperationRecoveryState: ObservableObject {
    /// OPS-001 统一操作状态（merge/rebase/cherry-pick/revert），Recovery Bar 数据源。
    @Published var operation: OperationState?
    /// 每个 Git root 最近一次已发布的 operation recovery 状态。外部 Git
    /// 操作会反复触发 metadata refresh，按 fingerprint 去重可避免同一
    /// 暂停操作不断重发通知，同时允许新冲突文件或操作阶段重新提示。
    @Published var notificationFingerprints: [String: String] = [:]
    /// Per-root persisted Log Revert/Cherry-pick recovery notices. This is
    /// separate from operation_state(): Git may have completed or never
    /// started the sequencer while the app was being terminated.
    @Published var resolvedConflictPaths: [String] = []
    @Published var feedback: String?
    @Published var viewMode: OperationsViewMode = .history
    @Published var logFocusNotificationID: String?
    @Published var consoleResult: GitCommandResult?
    @Published var smartOperationRequest: SmartOperationRequest?
    @Published var showConflictResolver = false
    /// The conflict dialog can be opened from the left Commit/Stash workspace
    /// while Git Log owns the right editor workspace. Keep its initial file
    /// independent from the main editor selection so opening the resolver does
    /// not replace the Log graph underneath it.
    @Published var initialPath: String?
    @Published var multiRootConflictGroups: [MultiRootConflictGroup] = []
    @Published var multiRootConflictBatchWorking = false
    @Published var multiRootConflictBatchError: String?
    /// 项目级统一冲突 resolver：一次维护所有 root 的 pending queue，
    /// 当前 root 的三栏编辑器由 active* 状态驱动。
    @Published var showMultiRootConflictResolver = false
    @Published var multiRootResolverRoots: [MultiRootConflictResolverRoot] = []
    @Published var multiRootResolverActiveRootPath: String?
    @Published var multiRootResolverActiveRepo: Repository?
    @Published var multiRootResolverActiveEntries: [FileEntry] = []
    @Published var multiRootResolverActiveInitialPath: String?
    @Published var multiRootResolverActiveKind: MultiRootConflictResolverKind?
    @Published var multiRootResolverWorking = false
    @Published var multiRootResolverError: String?
    @Published var multiRootResolverLoadGeneration = 0
}
