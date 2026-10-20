import Foundation
import SwiftUI

/// Rebase 草稿、todo 编辑、进行中会话、重试与撤销上下文。
@MainActor
final class RebaseWorkspaceState: ObservableObject {
    @Published var paused = false
    @Published var todoItems: [RebaseTodoItem] = []
    @Published var todoOnto = ""
    @Published var todoPreserveMerges = false
    @Published var todoRoot = false
    @Published var rawTodoText = ""
    @Published var pauseReason: RebasePauseReason?
    @Published var conflicts: [String] = []
    @Published var onto: String = ""
    @Published var branch: String = ""
    @Published var rootPath: String = ""
    @Published var range: [CommitInfo] = []
    @Published var actions: [RebaseAction] = []
    @Published var rangeGeneration = 0
    @Published var interactive = false
    @Published var preserveMerges = false
    @Published var autoSquash = false
    @Published var keepEmpty = false
    @Published var updateRefs = false
    @Published var root = false
    @Published var applyToAllRoots = false
    @Published var multiRootDrafts: [MultiRootRebaseTodoDraft] = []
    @Published var multiRootSession: MultiRootRebaseSession?
    @Published var multiRootRollbackContext: MultiRootRebaseRollbackContext?
    @Published var retryContext: RebaseRetryContext?
    @Published var undoSeed: RebaseUndoSeed?
    @Published var undoTarget: RebaseUndoTarget?
    @Published var feedback: String?
    /// REBASE-001 todo 编辑器状态
    @Published var showTodoEditor = false
    /// Native Git todo fallback.  This keeps label/reset/merge/exec and any
    /// future Git commands as editable text instead of forcing them through
    /// the structured six-action model.
    @Published var showRawTodoEditor = false
    @Published var showRawMessageEditor = false
    @Published var rawMessageText = ""
    @Published var rawMessageRepository: Repository?
    /// Log HEAD Reword uses Git's `--amend --only` path so staged changes stay staged.
    /// Log Fixup/Squash keeps IntelliJ's optional Commit and Rebase executor
    /// available until the generated commit is created.
    @Published var pendingAutoSquash: PendingAutoSquashRebase?
    @Published var showActionDialog = false
    @Published var showMultiRootEditor = false
    @Published var multiRootRawTodoContext: MultiRootRawTodoContext?
    @Published var multiRootRawTodoText = ""
}
