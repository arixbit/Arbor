import SwiftUI

extension Notification.Name {
    static let arborOpenProjectPanel = Notification.Name("arbor.openProjectPanel")
    static let arborInitProjectPanel = Notification.Name("arbor.initProjectPanel")
    static let arborCloneProjectDialog = Notification.Name("arbor.cloneProjectDialog")
    static let arborVCSAction = Notification.Name("arbor.vcsAction")
    static let arborOpenCommitDetail = Notification.Name("arbor.openCommitDetail")
    static let arborOpenMultiRootConflictResolver = Notification.Name("arbor.openMultiRootConflictResolver")
    static let arborRollbackMerge = Notification.Name("arbor.rollbackMerge")
    static let arborDeleteMergedBranch = Notification.Name("arbor.deleteMergedBranch")
}

private struct ArborRepositoryShallowKey: FocusedValueKey {
    typealias Value = Bool
}

private struct ArborRepositoryAvailableKey: FocusedValueKey {
    typealias Value = Bool
}

struct ArborVCSActionContext: Equatable {
    let hasRepository: Bool
    /// GitCreateNewBranchAction starts from HEAD and is disabled when any
    /// repository in the top-level action scope is still unborn.
    let allRepositoriesHaveHeadCommit: Bool
    let hasCurrentBranch: Bool
    let hasLocalChanges: Bool
    let hasUnstagedTrackedChanges: Bool
    let hasStagedChanges: Bool
    let hasConflicts: Bool
    let isShallowRepository: Bool
    let hasRemotes: Bool
    let hasFetchInProgress: Bool
    let hasBackgroundVCSOperation: Bool
    let projectPath: String?
    let hasMultipleGitRoots: Bool
    let hasProjectCommitChanges: Bool
    let hasTrackedUpstream: Bool
    let hasSingleGitRoot: Bool
    let hasRepositoryOperationInProgress: Bool
    let hasMergeInProgress: Bool
    let hasRebaseInProgress: Bool
    let hasNormalOrDetachedRepository: Bool
    /// The Changes Browser's Revert action is selection-scoped. Keep the
    /// selected path in the focused context so the main menu cannot silently
    /// fall back to the first dirty file in the repository.
    let selectedLocalChangePath: String?
    /// Git.RevertResolved is also selection-scoped. A resolved conflict path
    /// must be explicitly selected before the main-menu action is enabled.
    let selectedResolvedConflictPath: String?
    /// Git.FileActions is selection-scoped as well. Keep all presentation
    /// facts together so a main-menu action cannot fall back to an arbitrary
    /// dirty path or route a nested repository through the primary root.
    let selectedFileAction: ArborSelectedGitFileContext?

    init(
        hasRepository: Bool,
        allRepositoriesHaveHeadCommit: Bool = true,
        hasCurrentBranch: Bool,
        hasLocalChanges: Bool,
        hasUnstagedTrackedChanges: Bool,
        hasStagedChanges: Bool,
        hasConflicts: Bool,
        isShallowRepository: Bool,
        hasRemotes: Bool,
        hasFetchInProgress: Bool = false,
        hasBackgroundVCSOperation: Bool = false,
        projectPath: String? = nil,
        hasMultipleGitRoots: Bool = false,
        hasProjectCommitChanges: Bool = false,
        hasTrackedUpstream: Bool = false,
        hasSingleGitRoot: Bool = false,
        hasRepositoryOperationInProgress: Bool = false,
        hasMergeInProgress: Bool = false,
        hasRebaseInProgress: Bool = false,
        hasNormalOrDetachedRepository: Bool = true,
        selectedLocalChangePath: String? = nil,
        selectedResolvedConflictPath: String? = nil,
        selectedFileAction: ArborSelectedGitFileContext? = nil
    ) {
        self.hasRepository = hasRepository
        self.allRepositoriesHaveHeadCommit = allRepositoriesHaveHeadCommit
        self.hasCurrentBranch = hasCurrentBranch
        self.hasLocalChanges = hasLocalChanges
        self.hasUnstagedTrackedChanges = hasUnstagedTrackedChanges
        self.hasStagedChanges = hasStagedChanges
        self.hasConflicts = hasConflicts
        self.isShallowRepository = isShallowRepository
        self.hasRemotes = hasRemotes
        self.hasFetchInProgress = hasFetchInProgress
        self.hasBackgroundVCSOperation = hasBackgroundVCSOperation
        self.projectPath = projectPath
        self.hasMultipleGitRoots = hasMultipleGitRoots
        self.hasProjectCommitChanges = hasProjectCommitChanges
        self.hasTrackedUpstream = hasTrackedUpstream
        self.hasSingleGitRoot = hasSingleGitRoot
        self.hasRepositoryOperationInProgress = hasRepositoryOperationInProgress
        self.hasMergeInProgress = hasMergeInProgress
        self.hasRebaseInProgress = hasRebaseInProgress
        self.hasNormalOrDetachedRepository = hasNormalOrDetachedRepository
        self.selectedLocalChangePath = selectedLocalChangePath
        self.selectedResolvedConflictPath = selectedResolvedConflictPath
        self.selectedFileAction = selectedFileAction
    }
}

/// The focused selection needed by IntelliJ's Git.FileActions group. The
/// booleans are computed from the same status model that renders the file
/// tree, while `owningRootPath` is resolved from the canonical project path.
/// Keeping this as a value type makes menu presentation testable without
/// constructing SwiftUI views.
struct ArborSelectedGitFileContext: Equatable {
    let path: String
    let rootRelativePath: String
    let isDirectory: Bool
    let owningRootPath: String
    let isPrimaryRoot: Bool
    let canCheckin: Bool
    let canAdd: Bool
    let canAnnotate: Bool
    let canCompareWithHead: Bool
    let canCompareWithSelectedRevision: Bool
}

/// Focused command context for the repository currently owning the live
/// operation state. ProjectCommands must not infer a recovery root from the
/// project-wide "some operation is active" booleans: in a multi-root project
/// that could route Continue/Abort to the wrong repository.
struct ArborVCSOperationContext: Equatable {
    let rootPath: String
    let kind: OperationKind
    let hasConflicts: Bool
}

private struct ArborVCSOperationContextKey: FocusedValueKey {
    typealias Value = ArborVCSOperationContext
}

private struct ArborVCSActionContextKey: FocusedValueKey {
    typealias Value = ArborVCSActionContext
}

extension FocusedValues {
    var arborRepositoryIsShallow: Bool? {
        get { self[ArborRepositoryShallowKey.self] }
        set { self[ArborRepositoryShallowKey.self] = newValue }
    }

    var arborRepositoryAvailable: Bool? {
        get { self[ArborRepositoryAvailableKey.self] }
        set { self[ArborRepositoryAvailableKey.self] = newValue }
    }

    var arborVCSActionContext: ArborVCSActionContext? {
        get { self[ArborVCSActionContextKey.self] }
        set { self[ArborVCSActionContextKey.self] = newValue }
    }

    var arborVCSOperationContext: ArborVCSOperationContext? {
        get { self[ArborVCSOperationContextKey.self] }
        set { self[ArborVCSOperationContextKey.self] = newValue }
    }
}

enum ArborVCSAction: String, CaseIterable, Hashable {
    case update
    case reset
    case resetToRemoteBranch
    case commit
    case commitAndPush
    case push
    case fetch
    case fetchAll
    case retryAutoFetch
    case enableAutoFetch
    case disableAutoFetchSuggestion
    case fetchPrune
    case fetchUnshallow
    case pull
    case pullMerge
    case pullRebase
    case showStagingArea
    case showShelf
    case showStash
    case revertSelectedChanges
    case branches
    case merge
    case rebase
    case stash
    case unstash
    case shelve
    case applyPatch
    case applyPatchFromClipboard
    case newBranch
    case newTag
    case configureRemotes
    case worktrees
    case stageTracked
    case stageAll
    case copyCurrentBranchName
    case resolveConflicts
    case revertResolved
    case searchEverywhere
    case showLog
    case showExternalLog
    case showOperations
    case showGitRoots
    case showGitConsole
    case gitLfs
    case gitHooks
    case refresh
    case quickActions
    case fileCheckin
    case fileAdd
    case fileAnnotate
    case fileCompareSameVersion
    case fileCompareSelectedRevision
    case fileCompareWithBranch
    case fileHistory
}

func isArborVCSActionEnabled(
    _ action: ArborVCSAction,
    in context: ArborVCSActionContext?
) -> Bool {
    guard let context else { return false }

    switch action {
    case .searchEverywhere:
        return context.hasRepository
    case .update:
        return context.hasRepository && !context.hasBackgroundVCSOperation
    case .showLog, .showOperations, .showGitRoots, .showGitConsole, .gitLfs, .gitHooks, .showStagingArea, .showShelf, .showStash, .refresh,
         .branches, .stash, .unstash, .shelve, .applyPatch,
         .newTag, .configureRemotes, .worktrees:
        return context.hasRepository
    case .newBranch:
        return context.hasRepository && context.allRepositoriesHaveHeadCommit
    case .revertSelectedChanges:
        return context.hasRepository
            && context.selectedLocalChangePath != nil
            && !context.hasBackgroundVCSOperation
            && !context.hasRepositoryOperationInProgress
    case .merge:
        return context.hasRepository
            && !context.hasMergeInProgress
            && context.hasNormalOrDetachedRepository
    case .rebase:
        return context.hasRepository
            && !context.hasRebaseInProgress
            && context.hasNormalOrDetachedRepository
    case .reset:
        return context.hasRepository
            && !context.hasBackgroundVCSOperation
            && !context.hasRepositoryOperationInProgress
            && context.hasNormalOrDetachedRepository
    case .resetToRemoteBranch:
        return context.hasRepository
            && context.hasCurrentBranch
            && context.hasSingleGitRoot
            && context.hasTrackedUpstream
    case .applyPatchFromClipboard:
        return context.hasRepository
    case .showExternalLog:
        return context.hasRepository && context.projectPath != nil
    case .commit:
        return context.hasRepository && context.hasLocalChanges
    case .commitAndPush:
        return context.hasRepository
            && (
                context.hasCurrentBranch && context.hasLocalChanges
                    || (context.hasMultipleGitRoots && context.hasProjectCommitChanges)
            )
    case .push:
        return context.hasRepository
    case .pull, .pullMerge, .pullRebase:
        return context.hasRepository
            && !context.hasBackgroundVCSOperation
            && !context.hasRepositoryOperationInProgress
    case .fetch, .fetchAll, .fetchPrune:
        return context.hasRepository
            && context.hasRemotes
            && !context.hasFetchInProgress
    case .retryAutoFetch, .enableAutoFetch, .disableAutoFetchSuggestion:
        return context.hasRepository
    case .fetchUnshallow:
        return context.hasRepository
            && context.isShallowRepository
            && !context.hasFetchInProgress
    case .stageTracked:
        return context.hasRepository && context.hasUnstagedTrackedChanges
    case .stageAll:
        return context.hasRepository && context.hasLocalChanges
    case .copyCurrentBranchName:
        return context.hasRepository && context.hasCurrentBranch
    case .resolveConflicts:
        return context.hasRepository && context.hasConflicts
    case .revertResolved:
        return context.hasRepository
            && context.selectedResolvedConflictPath != nil
            && !context.hasBackgroundVCSOperation
            && !context.hasRepositoryOperationInProgress
    case .fileCheckin:
        return context.hasRepository
            && context.selectedFileAction?.canCheckin == true
            && !context.hasBackgroundVCSOperation
            && !context.hasRepositoryOperationInProgress
    case .fileAdd:
        return context.hasRepository
            && context.selectedFileAction?.canAdd == true
            && !context.hasBackgroundVCSOperation
            && !context.hasRepositoryOperationInProgress
    case .fileAnnotate:
        return context.hasRepository
            && context.selectedFileAction?.canAnnotate == true
            && !context.hasBackgroundVCSOperation
    case .fileCompareSameVersion:
        return context.hasRepository
            && context.selectedFileAction?.canCompareWithHead == true
    case .fileCompareSelectedRevision:
        return context.hasRepository
            && context.selectedFileAction?.canCompareWithSelectedRevision == true
    case .fileCompareWithBranch:
        return context.hasRepository && context.selectedFileAction != nil
    case .fileHistory:
        return context.hasRepository
            && context.selectedFileAction?.isDirectory == false
    case .quickActions:
        return context.hasRepository
    }
}

/// Resolve the focused Changes Browser selection for the main-menu Revert
/// action. The order mirrors the visible workspaces: Commit/Stash preview,
/// diff selection, then Project selection. A path is only eligible when it is
/// a tracked, non-conflicted change; untracked and ignored files require a
/// different destructive action and must not be deleted by Revert.
func arborSelectedRevertPath(
    entries: [FileEntry],
    candidates: [String?],
    headPresentByPath: [String: Bool]? = nil
) -> String? {
    for path in candidates.compactMap({ $0 }) {
        guard let entry = entries.first(where: { $0.path == path }) else { continue }
        if let headPresentByPath, headPresentByPath[path] != true { continue }
        let hasTrackedChange = [entry.staged, entry.unstaged].contains {
            $0 != .unchanged
                && $0 != .ignored
                && $0 != .untracked
                && $0 != .conflicted
        }
        guard hasTrackedChange,
              entry.staged != .conflicted,
              entry.unstaged != .conflicted,
              entry.staged != .ignored,
              entry.unstaged != .ignored,
              entry.unstaged != .untracked else { continue }
        return path
    }
    return nil
}

/// Match IntelliJ's `AbstractCommonUpdateAction` boundary. Update Project is
/// disabled while any background VCS operation owns the transport/feedback
/// lane, including multi-root runners whose progress is tracked separately.
func isArborBackgroundVCSOperationInProgress(
    feedbackIsRunning: Bool,
    multiRootIsRunning: Bool
) -> Bool {
    feedbackIsRunning || multiRootIsRunning
}

/// Match IntelliJ's `GitFetch.update()` busy boundary. Fetch, prune, branch
/// fetch, and unshallow all use the same Git transport lane, so a second
/// fetch action must remain visible but disabled until the first one ends.
func isArborFetchInProgress(
    isRunning: Bool,
    operationName: String?
) -> Bool {
    guard isRunning, let operationName else { return false }
    let normalized = operationName.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.hasPrefix("Fetch") || normalized == "Prune remote branches"
}

/// Match IntelliJ's project-wide rebase guard: a rebase in any discovered
/// Git root hides the project-level Rebase action, even when another root is
/// currently selected in the window.
func isArborRebaseInProgress(
    currentOperation: OperationKind?,
    roots: [GitRootInfo],
    hasMultiRootSession: Bool
) -> Bool {
    currentOperation == .rebase
        || hasMultiRootSession
        || roots.contains { $0.operation == .rebase }
}

/// Match IntelliJ's project-wide merge guard: a merge in any discovered Git
/// root hides the project-level Merge action, even when another root is
/// currently selected in the window.
func isArborMergeInProgress(
    currentOperation: OperationKind?,
    roots: [GitRootInfo]
) -> Bool {
    currentOperation == .merge
        || roots.contains { $0.operation == .merge }
}

/// Match IntelliJ's `NORMAL`/`DETACHED` repository filter for Rebase. The
/// selected root's live operation state wins over a potentially older root
/// discovery snapshot; other roots use their project-wide snapshot state.
func hasArborNormalOrDetachedRepository(
    currentOperation: OperationKind?,
    currentRootPath: String?,
    roots: [GitRootInfo]
) -> Bool {
    guard !roots.isEmpty else { return currentOperation == nil }
    let normalizedCurrentRoot = currentRootPath.map(canonicalExternalLogPath)
    return roots.contains { root in
        if let normalizedCurrentRoot,
           canonicalExternalLogPath(root.path) == normalizedCurrentRoot {
            return currentOperation == nil
        }
        return root.operation == nil
    }
}

/// Match IntelliJ's presentation boundary for actions that cannot be
/// reopened while their own repository operation is active.
func isArborVCSActionVisible(
    _ action: ArborVCSAction,
    in context: ArborVCSActionContext?
) -> Bool {
    guard let context else {
        return action != .merge && action != .rebase
    }
    switch action {
    case .merge:
        return context.hasRepository && !context.hasMergeInProgress
    case .rebase:
        return context.hasRepository && !context.hasRebaseInProgress
    default:
        return true
    }
}
