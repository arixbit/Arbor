import Foundation
import SwiftUI

/// Worktree 列表与目标 root 下的新建对话框。
@MainActor
final class WorktreeWorkspaceState: ObservableObject {
    @Published var worktrees: [WorktreeInfo] = []
    @Published var feedback: String?
    @Published var showCreateDialog = false
    /// Root selected by a Branches Popup worktree action. Keeping this
    /// separate from `repo` prevents a multi-root popup from silently
    /// creating the worktree in the primary repository.
    @Published var rootPath: String?
    @Published var reference = ""
    @Published var isTag = false
    @Published var path = ""
    @Published var branch = ""
}
