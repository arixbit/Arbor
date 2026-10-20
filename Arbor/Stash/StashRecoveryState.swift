import Foundation
import SwiftUI

/// Stash 的恢复与冲突状态：多 root stash 冲突、pull 前后的本地现场保存。
///
/// 和 `StashWorkspaceState`（对话框与预览）分开：这些字段服务于 pull/update/
/// merge 的恢复链路，生命周期由「一次更新事务」界定，而不是用户在 Stash 页里
/// 的操作。
@MainActor
final class StashRecoveryState: ObservableObject {
    // MARK: - 多 root stash 冲突

    @Published var multiRootConflicts: [String: [String]] = [:]
    @Published var multiRootConflictIndexes: [String: Int] = [:]
    @Published var multiRootConflictIDs: [String: String] = [:]
    @Published var multiRootConflictPopModes: [String: Bool] = [:]
    @Published var multiRootUpdateStashedRoots: Set<String> = []

    // MARK: - 单 root 冲突收尾

    @Published var popConflictInProgress = false
    @Published var applyConflictInProgress = false
    @Published var pendingConflictNotificationID: String?
    /// Legacy stack position retained for compatibility with the multi-root
    /// resolver. Single-root conflict completion prefers the stable stash ID.
    @Published var pendingPopIndex: Int?
    /// Stable stash object identity retained while a pop restore is paused.
    /// The stash stack can be reordered while the conflict resolver is open.
    @Published var pendingPopID: String?

    // MARK: - Pull 现场保存 / 恢复

    @Published var pendingPullStashPop = false
    /// Stable identity for the temporary Pull stash. The message remains as
    /// a compatibility fallback for markers written by older builds.
    @Published var pendingPullStashID: String?
    @Published var pendingPullStashMessage: String?
    @Published var pendingPullShelfName: String?
}
