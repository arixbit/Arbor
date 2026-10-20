import Foundation
import SwiftUI

/// Merge 对话框选项、多 root 回滚和冲突收尾上下文。
@MainActor
final class MergeWorkspaceState: ObservableObject {
    @Published var branch: String = ""
    @Published var mergedBranches: Set<String> = []
    @Published var dialogGeneration = 0
    @Published var strategyRaw = MergeStrategyChoice.automatic.rawValue
    @Published var commitMessage = ""
    @Published var useCustomCommitMessage = false
    @Published var noCommit = false
    @Published var noVerify = false
    @Published var allowUnrelatedHistories = false
    @Published var feedback: String?
    @Published var inProgress = false
    /// Source local branch captured by an engine merge. Kept until the
    /// explicit finish path completes so Delete-on-Merge survives conflict
    /// resolution in the current app session.
    @Published var pendingDeleteBranch: String?
    /// ORIG_HEAD fallback covers a merge resumed after the view was recreated;
    /// the in-memory value is preferred while this session owns the boundary.
    @Published var initialHead: String?
    @Published var showActionDialog = false
    @Published var showMultiRootDialog = false
    @Published var multiRootBranchName = ""
    @Published var multiRootSelectedRootPaths: Set<String> = []
    @Published var multiRootMergedBranchesByRoot: [String: Set<String>] = [:]
    @Published var multiRootDialogGeneration = 0
    @Published var multiRootRollbackContext: MultiRootMergeRollbackContext?
}
