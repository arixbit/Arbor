import Foundation
import SwiftUI

/// 分支列表与创建、重命名、删除、上游设置的工作区状态。
/// 对话框的 root 选择、仓库句柄和删除恢复上下文随窗口保留。
@MainActor
final class BranchWorkspaceState: ObservableObject {
    @Published var branches: [BranchInfo] = []
    @Published var remoteBranches: [RemoteBranchInfo] = []
    /// BRANCH-001 Recent 分组（HEAD reflog 最近检出）。
    @Published var recentBranches: [String] = []
    @Published var comparisons: [String: BranchCompare] = [:]
    @Published var syncStatuses: [SyncStatus] = []
    @Published var showPopover = false
    @Published var newName: String = ""
    /// A Log commit can belong to a non-primary Git root. Keep the branch
    /// dialog and its write operation pinned to that root instead of falling
    /// back to the window's primary repository.
    @Published var newRepositoryOverride: Repository?
    @Published var newDialogBranches: [BranchInfo] = []
    @Published var showNewDialog = false
    @Published var newDialogTitle = "New Branch"
    @Published var newBase = ""
    @Published var newCheckout = true
    @Published var newResetExisting = false
    @Published var newAfterCreateRebase = false
    @Published var renameOld: String = ""
    @Published var renameNew: String = ""
    @Published var showUpstreamDialog = false
    @Published var upstreamLocalBranch = ""
    @Published var multiRootUpstreamContext: MultiRootUpstreamContext?
    @Published var showMultiRootNewDialog = false
    @Published var multiRootNewName = ""
    @Published var multiRootNewBase = ""
    @Published var multiRootNewCheckout = true
    @Published var multiRootNewResetExisting = false
    @Published var multiRootExistingNames: [String: Set<String>] = [:]
    @Published var multiRootNewSelectedRootPaths: Set<String> = []
    @Published var showMultiRootRenameDialog = false
    @Published var multiRootRenameOldName = ""
    @Published var multiRootRenameNewName = ""
    @Published var multiRootRenameUnsetUpstream = false
    @Published var multiRootRenameSelectedRootPaths: Set<String> = []
    @Published var showRenameDialog = false
    @Published var renameRootPath = ""
    @Published var renameOldName = ""
    @Published var renameNewName = ""
    @Published var renameUnsetUpstream = false
    @Published var renameHasUpstream = false
    @Published var showMultiRootDeleteDialog = false
    @Published var multiRootDeleteName = ""
    @Published var multiRootDeleteSelectedRootPaths: Set<String> = []
    @Published var showMultiRootRemoteDeleteDialog = false
    @Published var multiRootRemoteDeleteName = ""
    @Published var multiRootRemoteDeleteSelectedRootPaths: Set<String> = []
    @Published var multiRootRemoteDeleteTracking = false
    @Published var deleteRecovery: BranchDeleteRecoveryContext?
    @Published var multiRootDeleteRecovery: MultiRootBranchDeleteRecoveryContext?
}
