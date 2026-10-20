import SwiftUI
import AppKit


/// The linear rebase engine treats `onto` as an excluded base revision.
/// IntelliJ's "from here" action includes the selected commit, so a
/// single-parent commit must use its parent as the engine base. Root needs a
/// dedicated path; a merge commit uses its first parent as the upstream and
/// keeps Git's merge control lines in the native rebase flow.
func interactiveRebaseBaseRevision(for commit: CommitInfo) -> String? {
    commit.parentIds.first
}

/// A root commit is a valid upstream selection for `git rebase -i --root`;
/// the base-revision helper remains nil because root rebase has no upstream.
func isInteractiveRebaseAvailable(for commit: CommitInfo) -> Bool {
    commit.parentIds.isEmpty || interactiveRebaseBaseRevision(for: commit) != nil
}

/// Match IntelliJ's commit-editing availability before the action reaches the
/// rebase engine. A merge commit can only be reworded in place when it is the
/// current HEAD; squash/fixup/drop and batch editing require a linear commit.
func isLogRewriteActionAvailable(for commit: CommitInfo, action: RebaseTodoAction) -> Bool {
    switch action {
    case .reword:
        return commit.parentIds.count <= 1 || commit.isHead
    case .squash, .fixup, .drop:
        return commit.parentIds.count == 1
    case .pick, .edit:
        return false
    }
}

/// Log action updates keep repository boundaries and history-rewrite state
/// explicit. IntelliJ applies these rules while updating the VCS Log action
/// group, before a menu item is invoked; keeping the value model independent
/// of SwiftUI makes the same decision available to both Log menus.
struct LogActionAvailability: Equatable {
    let hasLocalChanges: Bool
    let activeOperationRootPath: String?
    let hasRemotes: Bool

    init(
        hasLocalChanges: Bool,
        activeOperationRootPath: String?,
        hasRemotes: Bool = true
    ) {
        self.hasLocalChanges = hasLocalChanges
        self.activeOperationRootPath = activeOperationRootPath
        self.hasRemotes = hasRemotes
    }

    static let permissive = LogActionAvailability(
        hasLocalChanges: true,
        activeOperationRootPath: nil
    )

    func allowsMutation(for commits: [CommitInfo]) -> Bool {
        allowsMutation(forRepositoryPaths: commits.map(\.repositoryPath))
    }

    func allowsSingleRootMutation(for commits: [CommitInfo]) -> Bool {
        allowsSingleRootMutation(forRepositoryPaths: commits.map(\.repositoryPath))
    }

    func allowsHistoryRewrite(for commits: [CommitInfo]) -> Bool {
        allowsHistoryRewrite(forRepositoryPaths: commits.map(\.repositoryPath))
    }

    func allowsSingleRootHistoryRewrite(for commits: [CommitInfo]) -> Bool {
        allowsSingleRootHistoryRewrite(forRepositoryPaths: commits.map(\.repositoryPath))
    }

    func allowsAddCommitsToRemote(for commits: [CommitInfo]) -> Bool {
        allowsAddCommitsToRemote(forRepositoryPaths: commits.map(\.repositoryPath))
    }

    func allowsMutation(forRepositoryPaths paths: [String?]) -> Bool {
        !paths.isEmpty
    }

    func allowsHistoryRewrite(forRepositoryPaths paths: [String?]) -> Bool {
        guard allowsMutation(forRepositoryPaths: paths) else { return false }
        guard let activeRoot = normalizedLogActionRootPath(activeOperationRootPath) else {
            return true
        }
        return !Set(paths.compactMap(normalizedLogActionRootPath)).contains(activeRoot)
    }

    func allowsSingleRootMutation(forRepositoryPaths paths: [String?]) -> Bool {
        guard !paths.isEmpty else { return false }
        let roots = Set(paths.compactMap(normalizedLogActionRootPath))
        guard roots.count <= 1 else { return false }
        return true
    }

    func allowsSingleRootHistoryRewrite(forRepositoryPaths paths: [String?]) -> Bool {
        guard allowsSingleRootMutation(forRepositoryPaths: paths) else { return false }
        return allowsHistoryRewrite(forRepositoryPaths: paths)
    }

    func allowsAddCommitsToRemote(forRepositoryPaths paths: [String?]) -> Bool {
        hasRemotes && allowsSingleRootMutation(forRepositoryPaths: paths)
    }
}

private func normalizedLogActionRootPath(_ rawPath: String?) -> String? {
    guard let rawPath, !rawPath.isEmpty else { return nil }
    return URL(fileURLWithPath: rawPath).standardizedFileURL.path
}

func areLogRewriteSelectionActionsAvailable(for commits: [CommitInfo]) -> Bool {
    commits.count >= 2 && commits.allSatisfy { $0.parentIds.count == 1 }
}

enum LogReferenceKind: String, Equatable {
    case local
    case remote
    case tag
}

struct LogReferenceActionTarget: Identifiable, Equatable {
    let kind: LogReferenceKind
    let name: String

    var id: String {
        "\(kind.rawValue):\(name)"
    }
}

func logReferenceRootPath(for commit: CommitInfo) -> String? {
    guard let rawPath = commit.repositoryPath,
          !rawPath.isEmpty else {
        return nil
    }
    return URL(fileURLWithPath: rawPath).standardizedFileURL.path
}

/// GitCreateNewBranchFromCommitAction and GitCreateTagAction both use
/// IntelliJ's single-commit log action contract. Keep the update rule pure so
/// row context menus and tests cannot accidentally enable either action for a
/// multi-selection or a commit without a resolvable Git root.
func isLogSingleCommitActionAvailable(
    selectionCount: Int,
    for commit: CommitInfo
) -> Bool {
    selectionCount == 1 && logReferenceRootPath(for: commit) != nil
}

/// IntelliJ exposes `GitRebaseOntoCommitAction` when the selected commit has
/// no other branch ref to operate on. Keep the cheap presentation checks here;
/// the action handler performs the authoritative reachability check before
/// starting a history rewrite.
func isLogRebaseOntoSelectedCommitAvailable(
    selectionCount: Int,
    for commit: CommitInfo,
    currentBranchName: String?
) -> Bool {
    selectionCount == 1
        && logReferenceRootPath(for: commit) != nil
        && !(currentBranchName?.isEmpty ?? true)
        && !commit.isHead
}

enum LogReferenceAction: Equatable {
    case checkout
    case checkoutAndUpdate
    case checkoutWithRebase
    case compare
    case showDiff
    case rebase
    case merge
    case update
    case push
    case pullMerge
    case pullRebase
    case rename
    case delete
}

/// IntelliJ's GitLogBranchOperationsActionGroup is ref-driven, not a static
/// list. Keep the target model independent from SwiftUI so selection rules
/// remain testable and aggregate Log cannot accidentally use another root.
func logReferenceActionTargets(
    for commit: CommitInfo,
    currentBranchName: String?
) -> [LogReferenceActionTarget] {
    func sortedUniqueNames(_ names: [String]) -> [String] {
        Set(names.filter { !$0.isEmpty })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    let local = sortedUniqueNames(commit.refs)
        .filter { $0 != currentBranchName }
        .map { LogReferenceActionTarget(kind: .local, name: $0) }
    let remote = sortedUniqueNames(commit.remoteRefs)
        .map { LogReferenceActionTarget(kind: .remote, name: $0) }
    let tags = sortedUniqueNames(commit.tagRefs)
        .map { LogReferenceActionTarget(kind: .tag, name: $0) }
    return local + remote + tags
}

/// `GitCheckoutActionGroup` only exposes local branches (excluding the
/// currently checked out branch) alongside the selected revision. Keep this
/// projection separate from the broader ref action group, which also contains
/// remote branches and tags with their own pull/merge/delete actions.
func logCheckoutBranchTargets(
    for commit: CommitInfo,
    currentBranchName: String?
) -> [LogReferenceActionTarget] {
    logReferenceActionTargets(for: commit, currentBranchName: currentBranchName)
        .filter { $0.kind == .local }
}

/// IntelliJ's Add Commits to Remote Branch action is a single-repository
/// linear-history action. Keep merge commits and mixed-root selections out of
/// the menu action itself instead of waiting for in-memory replay to fail.
func isAddCommitsToRemoteBranchAvailable(for commits: [CommitInfo]) -> Bool {
    guard !commits.isEmpty,
          commits.allSatisfy({ $0.parentIds.count <= 1 }) else {
        return false
    }
    let repositoryPaths = Set(commits.map { $0.repositoryPath ?? "" })
    return repositoryPaths.count == 1
}

/// Git cannot soft-reset a root commit to its parent. Keep the Log action
/// update consistent with the engine instead of showing a button that can
/// only fail after the user opens the workflow.
func isUncommitActionAvailable(for commit: CommitInfo) -> Bool {
    commit.isHead && !commit.parentIds.isEmpty
}

/// The reference VCS Log's Root column identifies the owning Git root in
/// aggregate history. Keep the cell compact while retaining the full path in
/// its tooltip for roots that share the same final directory name.
func logRepositoryDisplayPath(_ repositoryPath: String?) -> String {
    guard let repositoryPath, !repositoryPath.isEmpty else { return "" }
    return URL(fileURLWithPath: repositoryPath).standardizedFileURL.path
}

func logRepositoryDisplayName(_ repositoryPath: String?) -> String {
    let normalized = logRepositoryDisplayPath(repositoryPath)
    guard !normalized.isEmpty else { return "—" }
    let name = URL(fileURLWithPath: normalized).lastPathComponent
    return name.isEmpty ? normalized : name
}

/// Git Reset's Log action is one-commit-per-repository. An aggregate Log may
/// therefore select several commits, but never two revisions from the same
/// Git root in one operation.
func isResetSelectionAvailable(for commits: [CommitInfo]) -> Bool {
    guard !commits.isEmpty else { return false }
    let rootKeys = commits.map { $0.repositoryPath ?? "" }
    return Set(rootKeys).count == rootKeys.count
}
