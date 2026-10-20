import Foundation
import SwiftUI

/// Git root 发现、聚合快照与批量更新事务。
@MainActor
final class MultiRootWorkspaceState: ObservableObject {
    /// REPO-001:多 root 发现与聚合结果
    @Published var roots: [GitRootInfo] = []
    /// Keep root discovery cancellable so startup and filesystem events cannot
    /// queue several repository-wide scans at once.
    @Published var loadTask: Task<Void, Never>?
    @Published var loadGeneration = 0
    @Published var loadNeedsRefresh = false
    @Published var loadCompletion: (() -> Void)?
    @Published var branchSnapshots: [GitRootBranchSnapshot] = []
    @Published var results: [RootOperationResult] = []
    @Published var changeGroups: [MultiRootChangeGroup] = []
    @Published var changesLoading = false
    @Published var changesError: String?
    @Published var changesGeneration = 0
    @Published var showChanges = false
    @Published var running = false
    /// Closes the small discovery window before Update Project can publish
    /// its ordinary multi-root runner state. It is deliberately separate from
    /// `multiRootRunning` so single-root Update does not appear as a multi-root
    /// result while roots are being discovered.
    @Published var updateDiscoveryRunning = false
    @Published var updateRebase = false
    /// Explicit per-root methods selected by the rebase-over-merge warning.
    /// A nil value means the project-wide method applies to every root.
    @Published var updateRebaseRootPaths: Set<String>?
    @Published var updateRetryAvailable = false
    @Published var checkoutUpdateRetryAvailable = false
    @Published var checkoutUpdateRetryContext: MultiRootCheckoutUpdateRetryContext?
}
