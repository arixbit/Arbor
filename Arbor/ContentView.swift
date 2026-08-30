import SwiftUI
import AppKit

private func firstConflictedPath(in entries: [FileEntry]) -> String? {
    for entry in entries {
        let stagedIsConflict = entry.staged == .conflicted
        let unstagedIsConflict = entry.unstaged == .conflicted
        if stagedIsConflict || unstagedIsConflict {
            return entry.path
        }
    }
    return nil
}

// Arbor 主界面：左侧常驻项目树，上下可折叠、可拖动的 IntelliJ 风格工具窗，
// 主区只负责展示当前上下文（文件、变更、提交或冲突）。引擎调用同步阻塞，
// 所有耗时操作仍由 WorkspaceOperations 放到后台 Task。

enum ToolWindowMode: String, CaseIterable, Identifiable {
    case commit
    case log
    case operations

    var id: String { rawValue }
    var title: String {
        switch self {
        case .commit: "提交"
        case .log: "日志"
        case .operations: "操作"
        }
    }
    var systemImage: String {
        switch self {
        case .commit: "checkmark.circle"
        case .log: "clock"
        case .operations: "list.bullet.rectangle"
        }
    }
}

enum LogViewMode: String, CaseIterable, Identifiable, Codable {
    case graph
    case command
    case compare
    case compareBranches
    case tags
    case reflog
    var id: String { rawValue }
}

/// IntelliJ keeps committed-revision comparison separate from a revision
/// versus working-tree diff, even though both are launched from branch UI.
func branchComparisonLogViewMode(workingTreeDiff: Bool) -> LogViewMode {
    workingTreeDiff ? .compare : .compareBranches
}

/// VCS Log uses the repository root together with the object id as the row
/// identity when several Git roots are shown in one graph. Keep the same
/// identity for async decorations such as cherry-picked highlighting.
func logCommitDisplayIdentity(repositoryPath: String?, id: String, aggregate: Bool) -> String {
    guard aggregate,
          let repositoryPath,
          !repositoryPath.isEmpty else {
        return id
    }
    return "\(repositoryPath)\u{1f}\(id)"
}

/// An async cherry-picked comparison may finish after the Log branch, root,
/// or highlighting toggle has changed. Only apply a result that still belongs
/// to the active comparison generation and source branch.
func isCurrentCherryPickedComparison(
    highlightingEnabled: Bool,
    currentComparisonGeneration: Int,
    resultComparisonGeneration: Int,
    currentLogGeneration: Int,
    resultLogGeneration: Int,
    currentSourceBranch: String,
    resultSourceBranch: String
) -> Bool {
    highlightingEnabled
        && currentComparisonGeneration == resultComparisonGeneration
        && currentLogGeneration == resultLogGeneration
        && currentSourceBranch == resultSourceBranch
}

/// IntelliJ's Compare Branches Log uses the range's exclusive side as the
/// cherry-pick target. The ordinary Log uses the repository's current branch.
func cherryPickTargetBranch(
    mode: LogViewMode,
    sourceBranch: String,
    firstBranch: String,
    secondBranch: String,
    currentBranch: String?
) -> String {
    let source = sourceBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    let first = firstBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    let second = secondBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    if mode == .compareBranches {
        if source == first, !second.isEmpty { return second }
        if source == second, !first.isEmpty { return first }
    }
    let current = currentBranch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return current.isEmpty ? "HEAD" : current
}

func cherryPickHighlightEnabledAfterSourceChange(
    sourceBranch: String,
    currentlyEnabled: Bool
) -> Bool {
    currentlyEnabled
        && !sourceBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// IntelliJ's cherry-picked highlighter only decorates commits after its
/// branch-aware comparison succeeds. A pending, empty, or failed comparison
/// must not fall back to commit-message trailers, which can mark unrelated
/// commits as picked.
func isCherryPickedCommitHighlighted(
    highlightingEnabled: Bool,
    comparisonReady: Bool,
    identity: String,
    highlightedCommitIDs: Set<String>
) -> Bool {
    highlightingEnabled
        && comparisonReady
        && highlightedCommitIDs.contains(identity)
}

/// The reference highlighter starts comparison only for repositories that
/// actually expose the selected source branch. Missing branches in other
/// roots are skipped rather than reported as failed comparisons.
func cherryPickSourceBranchExists(
    _ sourceBranch: String,
    localBranchNames: [String],
    remoteBranchNames: [String]
) -> Bool {
    let source = sourceBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !source.isEmpty else { return false }
    return localBranchNames.contains(source) || remoteBranchNames.contains(source)
}

enum BranchComparisonSide: String, Sendable {
    case first
    case second
}

/// Filters applied independently to the two VCS Log panes in Compare
/// Branches. The reference creates two log UIs from the same range filter;
/// each UI can then refine its own visible commit set.
struct BranchComparisonFilter: Codable, Equatable, Sendable {
    var message = ""
    var author = ""
    var since = ""
    var until = ""
    var messageRegex = false
    var messageMatchCase = false
    var noMerges = false
}

func branchComparisonFilterDateError(
    _ filter: BranchComparisonFilter,
    side: BranchComparisonSide
) -> String? {
    let sideLabel = side == .first ? "左侧" : "右侧"
    let since = filter.since.trimmingCharacters(in: .whitespacesAndNewlines)
    let until = filter.until.trimmingCharacters(in: .whitespacesAndNewlines)
    if !since.isEmpty, parseLogDate(since) == nil {
        return "\(sideLabel) Since 必须是 YYYY-MM-DD、YYYY-MM-DD HH:mm 或 Unix seconds"
    }
    if !until.isEmpty, parseLogDate(until) == nil {
        return "\(sideLabel) Until 必须是 YYYY-MM-DD、YYYY-MM-DD HH:mm 或 Unix seconds"
    }
    return nil
}

/// Synchronize the shared active commit with one comparison pane without
/// destroying that pane's Cmd/Shift multi-selection.
func branchComparisonGraphSelection(
    current: Set<String>,
    selectedID: String?,
    validIDs: Set<String>
) -> Set<String>? {
    guard let selectedID, validIDs.contains(selectedID) else { return nil }
    return current.contains(selectedID) ? current : [selectedID]
}

func branchComparisonHasMore(
    returnedCount: Int,
    requestedLimit: Int,
    isHashQuery: Bool
) -> Bool {
    !isHashQuery && returnedCount >= requestedLimit
}

func branchComparisonNewEntries(
    returned: [CommitInfo],
    existingIDs: Set<String>
) -> [CommitInfo] {
    var seen = existingIDs
    return returned
        .filter { seen.insert($0.id).inserted }
}

func branchComparisonSelectionAfterRefresh(
    selectedID: String?,
    firstIDs: [String],
    secondIDs: [String]
) -> (id: String?, side: BranchComparisonSide) {
    let firstIDSet = Set(firstIDs)
    let secondIDSet = Set(secondIDs)
    if let selectedID, firstIDSet.contains(selectedID) {
        return (selectedID, .first)
    }
    if let selectedID, secondIDSet.contains(selectedID) {
        return (selectedID, .second)
    }
    if let firstID = firstIDs.first {
        return (firstID, .first)
    }
    if let secondID = secondIDs.first {
        return (secondID, .second)
    }
    return (nil, .first)
}

func comparePatchGitArguments(
    rev1: String,
    rev2: String,
    comparesWithWorkingTree: Bool,
    paths: [String]
) -> [String] {
    var arguments = ["--binary", "--no-ext-diff", rev1]
    if !comparesWithWorkingTree {
        arguments.append(rev2)
    }
    arguments.append("--")
    arguments.append(contentsOf: paths)
    return arguments
}

enum LogBranchSelectionAction: String, CaseIterable, Identifiable {
    case navigate
    case filter
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .navigate: "Navigate Log"
        case .filter: "Filter Log"
        case .none: "Select Only"
        }
    }
}

enum LogGraphSortChoice: String, CaseIterable, Identifiable {
    case byCommitDate
    case topologically
    case linearizeMerges
    case firstParent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .byCommitDate: "Normal (Off)"
        case .topologically: "Standard (Bek)"
        case .linearizeMerges: "Linear (LinearBek)"
        case .firstParent: "First Parent"
        }
    }

    var engineValue: LogGraphSortMode {
        switch self {
        case .byCommitDate: .byCommitDate
        case .topologically: .topologically
        case .linearizeMerges: .linearizeMerges
        case .firstParent: .firstParent
        }
    }
}

enum AutoSquashCommitKind: Equatable, Sendable {
    case fixup
    case squash

    var prefix: String {
        switch self {
        case .fixup: "fixup"
        case .squash: "squash"
        }
    }

    var title: String {
        switch self {
        case .fixup: "Fixup"
        case .squash: "Squash"
        }
    }
}

struct PendingAutoSquashRebase: Equatable, Sendable {
    let targetID: String
    let onto: String
    let kind: AutoSquashCommitKind
    let root: Bool
}

struct PendingInitialCommitRewrite {
    let commits: [CommitInfo]
    let action: RebaseTodoAction
}

struct RebaseRetryContext {
    let repositoryPath: String
    let branch: String
    let onto: String
    let actions: [RebaseAction]
    let interactive: Bool
    let preserveMerges: Bool
    let autoSquash: Bool
    let keepEmpty: Bool
    let updateRefs: Bool
    let root: Bool
}

struct RebaseUndoSeed: Codable, Equatable, Sendable {
    let repositoryPath: String
    let branch: String
    let initialHead: String
    let updateRefs: Bool
    /// The oldest commit in the exact pre-rebase range, when the operation
    /// supplied or resolved an upstream/onto revision. Older persisted seeds
    /// may leave this nil and use the conservative old/new HEAD fallback.
    let protectionCommitID: String?

    init(
        repositoryPath: String,
        branch: String,
        initialHead: String,
        updateRefs: Bool,
        protectionCommitID: String? = nil
    ) {
        self.repositoryPath = repositoryPath
        self.branch = branch
        self.initialHead = initialHead
        self.updateRefs = updateRefs
        self.protectionCommitID = protectionCommitID
    }
}

struct RebaseUndoTarget: Codable, Equatable, Sendable {
    let repositoryPath: String
    let branch: String
    let initialHead: String
    let expectedHead: String
    let protectionCommitID: String?

    init(
        repositoryPath: String,
        branch: String,
        initialHead: String,
        expectedHead: String,
        protectionCommitID: String? = nil
    ) {
        self.repositoryPath = repositoryPath
        self.branch = branch
        self.initialHead = initialHead
        self.expectedHead = expectedHead
        self.protectionCommitID = protectionCommitID
    }
}

/// Expected-state context for undoing a successful Log Drop/Extract rewrite.
/// Unlike a plain ref move, the rewrite changes commit trees, so the undo
/// restores the complete branch tip with `reset --keep` and refuses stale
/// notifications using both HEAD and symbolic-branch identity.
struct LogSelectedChangesUndoTarget: Codable, Equatable, Sendable {
    let repositoryPath: String
    let branch: String
    let initialHead: String
    let expectedHead: String
}

/// Persisted form of a rebase action. UniFFI enums are intentionally kept out
/// of the on-disk model so an interrupted multi-root session can be restored
/// without depending on generated Swift enum Codable conformance.
enum PersistedRebaseActionKind: String, Codable, Equatable, Sendable {
    case pick
    case drop
    case reword
    case squash
    case fixup
    case edit
}

struct PersistedRebaseAction: Codable, Equatable, Sendable {
    let kind: PersistedRebaseActionKind
    let message: String?

    init(action: RebaseAction) {
        switch action {
        case .pick:
            kind = .pick
            message = nil
        case .drop:
            kind = .drop
            message = nil
        case let .reword(message: message):
            kind = .reword
            self.message = message
        case .squash:
            kind = .squash
            message = nil
        case let .squashWithMessage(message: message):
            kind = .squash
            self.message = message
        case .fixup:
            kind = .fixup
            message = nil
        case .edit:
            kind = .edit
            message = nil
        }
    }

    func makeAction() -> RebaseAction {
        switch kind {
        case .pick: return .pick
        case .drop: return .drop
        case .reword: return .reword(message: message ?? "")
        case .squash:
            if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .squashWithMessage(message: message)
            }
            return .squash
        case .fixup: return .fixup
        case .edit: return .edit
        }
    }
}

enum MultiRootRebaseSessionState: String, Codable, Equatable, Sendable {
    case pending
    case completed
    case paused
    case failed
    case aborted
}

struct MultiRootRebaseSessionRoot: Codable, Equatable, Identifiable, Sendable {
    let rootPath: String
    let displayName: String
    let branch: String
    let onto: String
    let actions: [PersistedRebaseAction]
    /// Visible structured todo order for preserve-merges. Optional keeps
    /// previously persisted partial sessions decodable.
    let orderedCommitIds: [String]?
    /// Optional raw native todo for this repository. Native todo text is
    /// repository-specific and must survive a partial multi-root retry.
    let rawTodo: String?
    let preserveMerges: Bool
    let autoSquash: Bool
    let keepEmpty: Bool
    let updateRefs: Bool
    let root: Bool
    /// Persist the policy with the batch so a relaunch cannot silently switch
    /// an in-flight rebase from Shelf to Stash (or vice versa).
    let savePolicyRaw: String?
    /// Captured before the root starts rewriting history. Older persisted
    /// sessions may leave this nil and use the conservative fallback.
    var protectionCommitID: String? = nil
    var state: MultiRootRebaseSessionState
    var initialHead: String?
    var expectedHead: String?
    var initialBranch: String?
    var message: String

    var id: String { rootPath }

    func makeSpec() -> MultiRootRebaseSpec {
        MultiRootRebaseSpec(
            rootPath: rootPath,
            branch: branch,
            onto: onto,
            actions: actions.map { $0.makeAction() },
            orderedCommitIds: orderedCommitIds ?? [],
            rawTodo: rawTodo,
            preserveMerges: preserveMerges,
            autoSquash: autoSquash,
            keepEmpty: keepEmpty,
            updateRefs: updateRefs,
            root: root,
            interactive: !actions.isEmpty,
            savePolicy: savePolicyRaw == GitLocalChangesSavePolicyChoice.shelve.rawValue
                ? .shelve
                : .stash
        )
    }
}

struct MultiRootRebaseSession: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let projectPath: String
    var roots: [MultiRootRebaseSessionRoot]

    init(projectPath: String, roots: [MultiRootRebaseSessionRoot]) {
        self.id = UUID()
        self.projectPath = projectPath
        self.roots = roots
    }
}

struct LogTabDescriptor: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String = "Log"
    /// A tab can retain a root-qualified Log context even when the root is the
    /// primary repository. Optional keeps older persisted external tabs
    /// decodable.
    var rootPath: String?
    /// Non-nil marks a dedicated File History tab. It lets the tab lifecycle
    /// reuse an existing history session instead of duplicating it.
    var historyPath: String?
    /// Non-nil marks IntelliJ's dedicated Update Info Log tab. The ranges
    /// remain root-qualified so switching tabs cannot turn a multi-root update
    /// into a primary-repository-only query.
    var updateInfoRanges: [PersistedLogRevisionRange]?
    /// Aggregate Log filters belong to the tab that created them. Optional
    /// fields preserve older persisted external tabs while allowing Update
    /// Info and ordinary multi-root tabs to switch without leaking state.
    var aggregateBranchFilters: [LogRootBranchFilter]?
    var aggregateRevisionRanges: [PersistedLogRevisionRange]?
    var aggregateRootPaths: [String]?
    var viewMode: LogViewMode = .graph
    var startRevision = ""
    var startRevisions: [String] = []
    var pathFilter = ""
    var pathSelections: [LogPathFilterSelection] = []
    var visibleRootPathsRaw = ""
    var authorFilter = ""
    var messageFilter = ""
    var messageRegex = false
    var messageMatchCase = false
    var sinceText = ""
    var untilText = ""
    var commandFilter = ""
    var follow = false
    var graphSortModeRaw = LogGraphSortChoice.byCommitDate.rawValue
    var compareRevision1 = ""
    var compareRevision2 = ""
    var compareRepositoryPath: String?
    var compareWithWorkingTree = false
    /// Compare panes are separate VcsLog UIs in IntelliJ. Keep their filters
    /// tab-local so opening or switching a comparison cannot leak predicates
    /// from another branch pair.
    var compareFirstFilter: BranchComparisonFilter?
    var compareSecondFilter: BranchComparisonFilter?
    var selection: String?
    var selectedIDs: Set<String> = []
    /// Reflog is a root-scoped view rather than an aggregate Log filter. Keep
    /// its repository and selection separate so switching tabs cannot silently
    /// move the Reflog to the primary root. Optional fields preserve decoding
    /// of tabs persisted before Reflog context became tab-local.
    var reflogRootPath: String?
    var reflogSelection: String?
    var reflogSelectedIDs: [String]?
}

/// Build the persisted state for IntelliJ's tabbed File History entry point.
/// The path remains root-qualified so opening the same relative path from a
/// nested Git root cannot silently query the primary repository.
func makeFileHistoryLogTab(
    path: String,
    startRevision: String,
    rootPath: String?
) -> LogTabDescriptor {
    let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedRevision = startRevision.trimmingCharacters(in: .whitespacesAndNewlines)
    let effectiveRevision = normalizedRevision.isEmpty ? "HEAD" : normalizedRevision
    let normalizedRoot = rootPath
        .map(canonicalExternalLogPath)
        .flatMap { $0.isEmpty ? nil : $0 }
    let fileName = URL(fileURLWithPath: normalizedPath).lastPathComponent
    var tab = LogTabDescriptor()
    tab.title = "History: \(fileName.isEmpty ? normalizedPath : fileName)"
    tab.rootPath = normalizedRoot
    tab.historyPath = normalizedPath
    tab.viewMode = .graph
    tab.startRevision = effectiveRevision
    tab.startRevisions = [effectiveRevision]
    tab.pathFilter = normalizedPath
    tab.pathSelections = [
        LogPathFilterSelection(rootPath: normalizedRoot, path: normalizedPath)
    ]
    tab.follow = true
    return tab
}

/// Build the dedicated Log tab used by IntelliJ's Update Info notification.
/// Reusing this shape for Update, Pull, Push recovery, and Merge keeps the
/// View Commits action root-qualified without replacing the user's ordinary
/// Log tab.
func makeUpdateInfoLogTab(
    ranges: [PersistedLogRevisionRange],
    title: String = "Update Info"
) -> LogTabDescriptor {
    var tab = LogTabDescriptor()
    tab.title = title
    tab.rootPath = ranges.count == 1 ? ranges[0].rootPath : nil
    tab.updateInfoRanges = ranges
    tab.aggregateRevisionRanges = ranges
    return tab
}

/// Build the dedicated Log tab used by IntelliJ's Compare Branches editor.
/// Keep the compared refs and owning root in the tab itself so switching tabs
/// cannot silently reuse the last comparison context.
func makeBranchComparisonLogTab(
    first: String,
    second: String,
    rootPath: String?
) -> LogTabDescriptor {
    let normalizedFirst = first.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedSecond = second.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedRoot = rootPath
        .map(canonicalExternalLogPath)
        .flatMap { $0.isEmpty ? nil : $0 }
    var tab = LogTabDescriptor()
    tab.title = "Compare: \(normalizedFirst) ↔ \(normalizedSecond)"
    tab.rootPath = normalizedRoot
    tab.viewMode = .compareBranches
    tab.compareRevision1 = normalizedFirst
    tab.compareRevision2 = normalizedSecond
    tab.compareRepositoryPath = normalizedRoot
    tab.compareWithWorkingTree = false
    return tab
}

/// Build the dedicated Log tab used by IntelliJ's Changes Browser branch diff
/// entry points. Committed revision comparison and revision-vs-working-tree
/// comparison share the file tree, but remain separate tab identities.
func makeTreeComparisonLogTab(
    first: String,
    second: String,
    rootPath: String?,
    comparesWithWorkingTree: Bool
) -> LogTabDescriptor {
    let normalizedFirst = first.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedSecond = second.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedRoot = rootPath
        .map(canonicalExternalLogPath)
        .flatMap { $0.isEmpty ? nil : $0 }
    var tab = LogTabDescriptor()
    tab.title = comparesWithWorkingTree
        ? "Diff: \(normalizedFirst) ↔ Working Tree"
        : "Diff: \(normalizedFirst) ↔ \(normalizedSecond)"
    tab.rootPath = normalizedRoot
    tab.viewMode = .compare
    tab.compareRevision1 = normalizedFirst
    tab.compareRevision2 = normalizedSecond
    tab.compareRepositoryPath = normalizedRoot
    tab.compareWithWorkingTree = comparesWithWorkingTree
    return tab
}

struct ExternalLogTabsState: Codable, Equatable {
    var tabs: [LogTabDescriptor]
    var activeTabID: UUID?

    func sanitized() -> ExternalLogTabsState {
        var seen = Set<UUID>()
        let uniqueTabs = tabs.filter { seen.insert($0.id).inserted }
        let activeID = activeTabID.flatMap { id in
            uniqueTabs.contains(where: { $0.id == id }) ? id : nil
        } ?? uniqueTabs.first?.id
        return ExternalLogTabsState(tabs: uniqueTabs, activeTabID: activeID)
    }
}

enum ExternalLogTabsStore {
    private static let keyPrefix = "arbor.externalLog.tabs.v1."

    static func key(projectPath: String, rootPaths: Set<String>) -> String {
        let roots = normalizedLogRootPaths(Array(rootPaths)).joined(separator: "\u{1f}")
        return keyPrefix + canonicalExternalLogPath(projectPath) + "\u{1e}" + roots
    }

    static func load(projectPath: String, rootPaths: Set<String>) -> ExternalLogTabsState? {
        load(key: key(projectPath: projectPath, rootPaths: rootPaths))
    }

    static func load(key: String) -> ExternalLogTabsState? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ExternalLogTabsState.self, from: data)
    }

    static func save(
        _ state: ExternalLogTabsState,
        projectPath: String,
        rootPaths: Set<String>
    ) {
        save(state, key: key(projectPath: projectPath, rootPaths: rootPaths))
    }

    static func save(_ state: ExternalLogTabsState, key: String) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// IntelliJ's structure filter keeps each FilePath tied to its owning Git
/// root. A bare relative path is retained as a compatibility form for paths
/// entered manually and applies to every selected root.
struct LogPathFilterSelection: Codable, Equatable, Hashable, Sendable, Identifiable {
    let rootPath: String?
    let path: String

    var id: String {
        "\(rootPath ?? "")\u{1f}\(path)"
    }
}

/// A repository handle used by the lazy VCS structure chooser. It is kept out
/// of LogPathFilterSelection so persisted filter state never captures a live
/// FFI object.
struct LogPathChooserRoot: Identifiable {
    let path: String
    let repository: Repository

    var id: String { path }

    var displayName: String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }
}

/// A branch filter keeps the owning Git root attached to the ref. IntelliJ's
/// multi-root VCS Log treats two equal branch names in different roots as
/// different navigations and filters; a bare branch name cannot represent
/// that distinction.
struct LogRootBranchFilter: Codable, Equatable, Hashable, Sendable {
    let rootPath: String
    let branch: String
}

/// A root-qualified revision range used by update-session history actions.
/// This is separate from branch dashboard filters so a range opened from a
/// notification cannot be mistaken for a branch name by the UI.
struct LogRootRevisionRange: Equatable, Hashable, Sendable {
    let rootPath: String
    let oldRevision: String
    let newRevision: String

    init(rootPath: String, oldRevision: String, newRevision: String) {
        self.rootPath = rootPath
        self.oldRevision = oldRevision
        self.newRevision = newRevision
    }

    init(_ persisted: PersistedLogRevisionRange) {
        rootPath = persisted.rootPath
        oldRevision = persisted.oldRevision
        newRevision = persisted.newRevision
    }

    var persisted: PersistedLogRevisionRange {
        PersistedLogRevisionRange(
            rootPath: rootPath,
            oldRevision: oldRevision,
            newRevision: newRevision
        )
    }
}

struct MultiRootPushContext: Identifiable {
    let id = UUID()
    let rootPath: String
    let remotes: [RemoteInfo]
    let branches: [BranchInfo]
    let commits: [CommitInfo]
    let defaultRemote: String?
    let defaultBranch: String?
    let currentHasUpstream: Bool
    let protectedBranchPatterns: [String]
    let defaultPushTagMode: PushDialogTagMode?
}

struct MultiRootCheckoutUpdateRetryContext {
    let reference: String
    let selectedRootPaths: [String]
    let detach: Bool
    let rebase: Bool
    let mode: MultiRootCheckoutMode
}

struct MultiRootPushRetryContext {
    let rootPaths: [String]
    let recoveryRebase: Bool?
    let recoveryUpdateRootPaths: [String]?
    let tagMode: PushDialogTagMode?
    let skipHooks: Bool
    let force: Bool
    let forceWithLease: Bool
    let viewCommitRanges: [PersistedLogRevisionRange]
    let resultRows: [FeedbackResultRow]

    init(
        rootPaths: [String],
        recoveryRebase: Bool? = nil,
        recoveryUpdateRootPaths: [String]? = nil,
        tagMode: PushDialogTagMode? = nil,
        skipHooks: Bool = false,
        force: Bool = false,
        forceWithLease: Bool = false,
        viewCommitRanges: [PersistedLogRevisionRange] = [],
        resultRows: [FeedbackResultRow] = []
    ) {
        self.rootPaths = rootPaths
        self.recoveryRebase = recoveryRebase
        self.recoveryUpdateRootPaths = recoveryUpdateRootPaths
        self.tagMode = tagMode
        self.skipHooks = skipHooks
        self.force = force
        self.forceWithLease = forceWithLease
        self.viewCommitRanges = viewCommitRanges
        self.resultRows = resultRows
    }
}

struct AddCommitsToRemoteBranchContext: Identifiable {
    let commits: [CommitInfo]
    let remoteBranches: [RemoteBranchInfo]

    var id: String {
        "add-commits-to-remote:\(commits.map(\.id).joined(separator: ","))"
    }
}

/// Returns the single Git root that owns a Log selection. Aggregate Log
/// actions must use this identity before reading root-scoped remotes or
/// opening a write dialog; a raw commit hash is not sufficient when two roots
/// contain the same object id.
func logCommitSelectionRepositoryPath(_ commits: [CommitInfo]) -> String? {
    guard let first = commits.first,
          let repositoryPath = first.repositoryPath,
          !repositoryPath.isEmpty,
          commits.allSatisfy({ $0.repositoryPath == repositoryPath }) else {
        return nil
    }
    return repositoryPath
}

struct LogCommitRootBatch {
    let rootPath: String
    let commits: [CommitInfo]
}

/// IntelliJ's GitApplyChangesProcess groups a Log selection by owning Git
/// root before applying Cherry-pick/Revert. Preserve first-seen root order and
/// the Log UI order within each root so aggregate history never collapses
/// equal object IDs or sends a commit to the wrong repository.
func logCommitRootBatches(_ commits: [CommitInfo]) -> [LogCommitRootBatch] {
    var batches: [LogCommitRootBatch] = []
    var indexByRoot: [String: Int] = [:]
    for commit in commits {
        guard let rootPath = logReferenceRootPath(for: commit) else { continue }
        if let index = indexByRoot[rootPath] {
            batches[index] = LogCommitRootBatch(
                rootPath: rootPath,
                commits: batches[index].commits + [commit]
            )
        } else {
            indexByRoot[rootPath] = batches.count
            batches.append(LogCommitRootBatch(rootPath: rootPath, commits: [commit]))
        }
    }
    return batches
}

struct MultiRootRemoteConfigContext: Identifiable {
    let rootPath: String
    let remotes: [RemoteInfo]

    var id: String { rootPath }
}

struct MultiRootUpstreamContext: Identifiable {
    let rootPath: String
    let displayName: String
    let localBranch: String
    let remoteBranches: [RemoteBranchInfo]
    let currentUpstream: String?

    var id: String { "\(rootPath):\(localBranch)" }
}

struct BranchDeleteRecoveryContext: Identifiable {
    let repo: Repository
    let preview: BranchDeletePreview
    let rootPath: String?
    let trackedRemoteBranch: String?

    init(
        repo: Repository,
        preview: BranchDeletePreview,
        rootPath: String?,
        trackedRemoteBranch: String? = nil
    ) {
        self.repo = repo
        self.preview = preview
        self.rootPath = rootPath
        self.trackedRemoteBranch = trackedRemoteBranch
    }

    var id: String {
        "\(rootPath ?? "current"):\(preview.branchName):\(preview.tipId)"
    }
}

struct MultiRootBranchDeleteRecoveryContext: Identifiable {
    let branchName: String
    let contexts: [BranchDeleteRecoveryContext]

    var id: String {
        "multi-root:\(branchName):\(contexts.map(\.id).joined(separator: "|"))"
    }
}

struct MultiRootMergeRollbackTarget: Identifiable {
    let rootPath: String
    let displayName: String
    let initialHead: String
    let expectedHead: String
    let operationPending: Bool

    var id: String { "\(rootPath):\(initialHead):\(expectedHead)" }
}

struct MultiRootMergeRollbackContext: Identifiable {
    let branchName: String
    let targets: [MultiRootMergeRollbackTarget]
    let failures: [String]
    let pendingRootPath: String?

    var id: String {
        "multi-root-merge:\(branchName):\(targets.map(\.id).joined(separator: "|")):\(pendingRootPath ?? "")"
    }
}

/// The IntelliJ Smart Operation dialog is a decision point, not a transient
/// warning: it shows the exact paths Git reported and keeps Smart/Force/Cancel
/// mutually exclusive until the user chooses one.
struct SmartOperationRequest: Identifiable {
    let id = UUID()
    let operationTitle: String
    let smartButtonTitle: String
    let forceButtonTitle: String?
    let paths: [String]
    let detail: String?
    let localChangesSavePolicy: GitLocalChangesSavePolicyChoice
    let onSmart: () -> Void
    let onForce: (() -> Void)?
}

struct RebasedApplyPatchRequest: Identifiable {
    let id = UUID()
    let fileName: String
    let patch: String
    let paths: [String]
}

/// The file encodings exposed by IntelliJ's Create Patch configuration panel.
/// Clipboard output stays a native Swift String; this choice only controls
/// bytes written to a patch file.
enum PatchExportEncodingChoice: String, CaseIterable, Identifiable, Sendable {
    case utf8 = "utf-8"
    case utf16 = "utf-16"
    case isoLatin1 = "iso-8859-1"
    case windows1252 = "windows-1252"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf16: "UTF-16"
        case .isoLatin1: "ISO-8859-1"
        case .windows1252: "Windows-1252"
        }
    }

    var stringEncoding: String.Encoding {
        switch self {
        case .utf8: .utf8
        case .utf16: .utf16
        case .isoLatin1: .isoLatin1
        case .windows1252: .windowsCP1252
        }
    }
}

/// Project-scoped Create Patch preferences. IntelliJ remembers the clipboard
/// choice and patch destination while the encoding defaults to the project
/// charset; scoping all three to the canonical Git root avoids leaking a
/// path or charset choice between unrelated projects.
enum PatchExportSettings {
    private static let keyPrefix = "arbor.git.patchExport.project.v1:"

    private static func key(for repositoryRootPath: String, suffix: String) -> String {
        let normalized = URL(fileURLWithPath: repositoryRootPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let data = normalized.data(using: .utf8) ?? Data()
        return "\(keyPrefix)\(data.base64EncodedString()):\(suffix)"
    }

    static func encoding(
        for repositoryRootPath: String,
        defaults: UserDefaults = .standard
    ) -> PatchExportEncodingChoice {
        guard let raw = defaults.string(forKey: key(for: repositoryRootPath, suffix: "encoding")),
              let choice = PatchExportEncodingChoice(rawValue: raw) else {
            return .utf8
        }
        return choice
    }

    static func copyToClipboard(
        for repositoryRootPath: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: key(for: repositoryRootPath, suffix: "clipboard"))
    }

    static func lastDirectory(
        for repositoryRootPath: String,
        defaults: UserDefaults = .standard
    ) -> URL? {
        guard let raw = defaults.string(forKey: key(for: repositoryRootPath, suffix: "directory")),
              !raw.isEmpty else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: raw, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    static func save(
        _ options: PatchExportOptions,
        for repositoryRootPath: String,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(options.encoding.rawValue, forKey: key(for: repositoryRootPath, suffix: "encoding"))
        defaults.set(options.copyToClipboard, forKey: key(for: repositoryRootPath, suffix: "clipboard"))
    }

    static func saveDestination(
        _ destination: URL,
        for repositoryRootPath: String,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(
            destination.deletingLastPathComponent().standardizedFileURL.path,
            forKey: key(for: repositoryRootPath, suffix: "directory")
        )
    }
}

/// Configuration shared by every user-facing Create Patch entry point.
/// `baseDirectory` is an absolute directory selected inside the owning Git
/// root; nil means the repository root. `reverse` reverses the comparison
/// currently represented by the action, rather than assuming a particular
/// Git command orientation.
struct PatchExportOptions: Equatable, Sendable {
    let baseDirectory: String?
    let reverse: Bool
    let copyToClipboard: Bool
    let encoding: PatchExportEncodingChoice
}

/// The dialog is deliberately decoupled from a Repository so the UI can be
/// reused by Log, Compare, and Diff Viewer without moving Git work onto the
/// main actor. The callback is invoked only after the user confirms options.
struct PatchExportRequest: Identifiable {
    let id = UUID()
    let title: String
    let defaultFileName: String
    let repositoryRootPath: String
    let paths: [String]
    let allowsBaseDirectory: Bool
    let initialCopyToClipboard: Bool
    let initialEncoding: PatchExportEncodingChoice
    let onExport: (PatchExportOptions) -> Void
}

func choosePatchExportDestination(
    defaultFileName: String,
    repositoryRootPath: String
) -> URL? {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = defaultFileName
    panel.allowedContentTypes = [.plainText]
    panel.canCreateDirectories = true
    panel.prompt = "Create Patch"
    panel.directoryURL = PatchExportSettings.lastDirectory(for: repositoryRootPath)
    guard panel.runModal() == .OK else { return nil }
    if let url = panel.url {
        PatchExportSettings.saveDestination(url, for: repositoryRootPath)
    }
    return panel.url
}

func patchExportData(
    _ patch: String,
    encoding: PatchExportEncodingChoice
) throws -> Data {
    guard let data = patch.data(using: encoding.stringEncoding, allowLossyConversion: false) else {
        throw NSError(
            domain: "Arbor.Git",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The patch contains characters that cannot be represented as \(encoding.title)."
            ]
        )
    }
    return data
}

/// Converts valid UTF-8 Git output to the selected patch encoding. If Git
/// returned non-UTF-8 bytes, only UTF-8 output is safe without guessing the
/// source charset; preserve those bytes verbatim instead of silently replacing
/// them. Callers can still present `GitCommandResult.stdout` as lossy Unicode
/// text for the clipboard/UI path.
func patchExportData(
    _ rawPatch: Data,
    encoding: PatchExportEncodingChoice
) throws -> Data {
    guard let patch = String(data: rawPatch, encoding: .utf8) else {
        guard encoding == .utf8 else {
            throw NSError(
                domain: "Arbor.Git",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The patch contains characters that cannot be represented as \(encoding.title)."
                ]
            )
        }
        return rawPatch
    }
    return try patchExportData(patch, encoding: encoding)
}

/// Returns the repository-relative base used by Git's `--relative` option.
/// IntelliJ's patch builder requires every selected path to be relative to
/// the chosen base; rejecting an unsafe base prevents Git from silently
/// excluding changes outside that directory.
func patchExportBaseDirectoryRelativePath(
    repositoryRootPath: String,
    baseDirectory: String?,
    paths: [String]
) -> String? {
    let root = URL(fileURLWithPath: repositoryRootPath)
        .resolvingSymlinksInPath()
        .standardizedFileURL
    guard let baseDirectory,
          !baseDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }

    let base = URL(fileURLWithPath: baseDirectory)
        .resolvingSymlinksInPath()
        .standardizedFileURL
    guard base.path == root.path || base.path.hasPrefix(root.path + "/") else {
        return nil
    }
    guard paths.allSatisfy({ path in
        guard let relative = normalizedRepositoryRelativePath(path) else { return false }
        let absolute = root.appendingPathComponent(relative).standardizedFileURL
        return absolute.path == base.path || absolute.path.hasPrefix(base.path + "/")
    }) else {
        return nil
    }
    guard base.path != root.path else { return nil }
    return String(base.path.dropFirst(root.path.count + 1))
}

func patchExportBaseDirectoryIsValid(
    repositoryRootPath: String,
    baseDirectory: String?,
    paths: [String]
) -> Bool {
    guard let baseDirectory,
          !baseDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return true
    }
    let root = URL(fileURLWithPath: repositoryRootPath)
        .resolvingSymlinksInPath()
        .standardizedFileURL
    let base = URL(fileURLWithPath: baseDirectory)
        .resolvingSymlinksInPath()
        .standardizedFileURL
    guard base.path == root.path || base.path.hasPrefix(root.path + "/") else {
        return false
    }
    guard !paths.isEmpty else { return base.path == root.path }
    return paths.allSatisfy { path in
        guard let relative = normalizedRepositoryRelativePath(path) else { return false }
        let absolute = root.appendingPathComponent(relative).standardizedFileURL
        return absolute.path == base.path || absolute.path.hasPrefix(base.path + "/")
    }
}

/// Applies export-only options while preserving the base command's existing
/// orientation (for example Diff Viewer's index-to-worktree command already
/// contains `--reverse`). Options are inserted before `--`, so pathspecs
/// remain data and never become Git options.
func patchExportGitArguments(
    baseArguments: [String],
    repositoryRootPath: String,
    paths: [String],
    options: PatchExportOptions
) -> [String]? {
    guard patchExportBaseDirectoryIsValid(
        repositoryRootPath: repositoryRootPath,
        baseDirectory: options.baseDirectory,
        paths: paths
    ) else {
        return nil
    }

    let separatorIndex = baseArguments.firstIndex(of: "--") ?? baseArguments.endIndex
    let prefix = Array(baseArguments[..<separatorIndex])
    let suffix = Array(baseArguments[separatorIndex...])
    let hasBaseReverse = prefix.contains { $0 == "--reverse" || $0 == "-R" }
    var normalizedPrefix = prefix.filter { $0 != "--reverse" && $0 != "-R" }
    if hasBaseReverse != options.reverse {
        normalizedPrefix.append("--reverse")
    }
    if let base = patchExportBaseDirectoryRelativePath(
        repositoryRootPath: repositoryRootPath,
        baseDirectory: options.baseDirectory,
        paths: paths
    ) {
        normalizedPrefix.append("--relative=\(base)")
    }
    return normalizedPrefix + suffix
}

/// Git normally terminates a patch with LF. Normalize each independently
/// generated member before concatenating so a multi-commit export has one
/// unambiguous boundary and never gains accidental blank records.
func joinedGitPatchParts(_ parts: [String]) -> String {
    let nonEmpty = parts.filter { !$0.isEmpty }
    guard !nonEmpty.isEmpty else { return "" }
    return nonEmpty.map { part in
        part.trimmingCharacters(in: .newlines)
    }.joined(separator: "\n") + "\n"
}

/// The byte-preserving counterpart used when several Git commands contribute
/// one exported patch. Only trailing line separators are normalized; all
/// other bytes remain untouched.
func joinedGitPatchData(_ parts: [Data]) -> Data {
    let nonEmpty = parts.filter { !$0.isEmpty }
    guard !nonEmpty.isEmpty else { return Data() }

    var result = Data()
    for part in nonEmpty {
        var bytes = Array(part)
        while let last = bytes.last, last == 0x0A || last == 0x0D {
            bytes.removeLast()
        }
        result.append(contentsOf: bytes)
        result.append(UInt8(0x0A))
    }
    return result
}

/// Adds the optional IntelliJ-style commit header without round-tripping the
/// Git body through a lossy String conversion.
func patchExportData(
    _ rawPatch: Data,
    commitMessage: String?,
    encoding: PatchExportEncodingChoice
) throws -> Data {
    guard let commitMessage else {
        return try patchExportData(rawPatch, encoding: encoding)
    }
    let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else {
        return try patchExportData(rawPatch, encoding: encoding)
    }
    let header = try patchExportData(
        "Subject: [PATCH] \(message)\n---\n",
        encoding: encoding
    )
    var output = Data()
    output.append(header)
    output.append(try patchExportData(rawPatch, encoding: encoding))
    return output
}

/// Matches IntelliJ UnifiedDiffWriter's optional commit-message header for a
/// single revision patch. Git's diff body remains untouched, including binary
/// patch records and Unix line separators.
func patchTextWithCommitMessage(_ patch: String, commitMessage: String?) -> String {
    guard let commitMessage else { return patch }
    let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else { return patch }
    return "Subject: [PATCH] \(message)\n---\n\(patch)"
}

/// A file-level compare request is pinned to the Git root that owns the
/// selected project-tree row.  The window can contain several Git roots, so
/// resolving the path later through the primary repository would be unsafe.
struct FileReferenceComparisonRequest: Identifiable {
    let repo: Repository
    let path: String
    let isDirectory: Bool
    let mode: FileReferenceComparisonMode

    var id: String { "\(repo.workdir() ?? ""): \(path):\(mode.rawValue)" }
}

/// A current-revision description is pinned to the Git root that resolved
/// the project-tree path. The request must not fall back to the active Log
/// repository when a nested Git root owns the selected file.
struct CurrentRevisionRequest: Identifiable {
    let repo: Repository
    let path: String
    let commit: CommitInfo

    var id: String { "\(repo.workdir() ?? ""): \(path):\(commit.id)" }
}

/// A read-only file comparison keeps the owning Git root and the requested
/// engine mode together. This prevents a nested project-tree file from being
/// rendered through the primary repository after the async root lookup.
struct FileTreeDiffRequest: Identifiable {
    let repo: Repository
    let entry: FileEntry
    let initialMode: DiffMode

    var id: String { "\(repo.workdir() ?? ""):\(entry.path):\(initialMode)" }
}

struct MultiRootRebaseRollbackTarget: Identifiable {
    let rootPath: String
    let displayName: String
    let initialHead: String
    let expectedHead: String
    let branch: String
    let protectionCommitID: String?

    init(
        rootPath: String,
        displayName: String,
        initialHead: String,
        expectedHead: String,
        branch: String,
        protectionCommitID: String? = nil
    ) {
        self.rootPath = rootPath
        self.displayName = displayName
        self.initialHead = initialHead
        self.expectedHead = expectedHead
        self.branch = branch
        self.protectionCommitID = protectionCommitID
    }

    var id: String { "\(rootPath):\(initialHead):\(expectedHead)" }
}

struct MultiRootRebaseRollbackContext: Identifiable {
    let sessionID: UUID
    let branch: String
    let targets: [MultiRootRebaseRollbackTarget]
    let failures: [String]

    var id: String {
        "multi-root-rebase:\(sessionID.uuidString):\(targets.map(\.id).joined(separator: "|"))"
    }
}

private struct MultiRootMergePresentationModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var selectedRootPaths: Set<String>
    @Binding var strategy: MergeStrategyChoice
    @Binding var commitMessage: String
    @Binding var useCustomCommitMessage: Bool
    @Binding var noCommit: Bool
    @Binding var noVerify: Bool
    @Binding var allowUnrelatedHistories: Bool
    @Binding var rollbackContext: MultiRootMergeRollbackContext?
    let branchName: String
    let snapshots: [GitRootBranchSnapshot]
    let mergedBranchesByRoot: [String: Set<String>]
    let onMerge: () -> Void
    let onCancel: () -> Void
    let onRollback: ([MultiRootMergeRollbackTarget]) -> Void
    let onKeep: (MultiRootMergeRollbackContext) -> Void
    let onDone: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                RebasedMultiRootMergeDialog(
                    branchName: branchName,
                    selectedRootPaths: $selectedRootPaths,
                    strategy: $strategy,
                    commitMessage: $commitMessage,
                    useCustomCommitMessage: $useCustomCommitMessage,
                    noCommit: $noCommit,
                    noVerify: $noVerify,
                    allowUnrelatedHistories: $allowUnrelatedHistories,
                    snapshots: snapshots,
                    mergedBranchesByRoot: mergedBranchesByRoot,
                    onMerge: onMerge,
                    onCancel: onCancel
                )
            }
            .sheet(item: $rollbackContext) { context in
                RebasedMultiRootMergeRollbackView(
                    branchName: context.branchName,
                    targets: context.targets,
                    failures: context.failures,
                    onRollback: { onRollback(context.targets) },
                    onKeep: { onKeep(context) },
                    onDone: onDone
                )
            }
    }
}

struct TagDeleteRecoveryContext: Identifiable {
    let repo: Repository
    let tag: TagInfo
    let rootPath: String?

    var remotes: [RemoteInfo] {
        (try? repo.remoteList()) ?? []
    }

    var id: String { "\(rootPath ?? "current"):\(tag.name):\(tag.id)" }
}

struct MultiRootTagDeleteRecoveryContext: Identifiable {
    let tagName: String
    let contexts: [TagDeleteRecoveryContext]

    var id: String {
        "multi-root-tags:\(tagName):\(contexts.map(\.id).joined(separator: "|"))"
    }
}

struct MultiRootRemoteConfigRoot: Identifiable {
    let rootPath: String
    let displayName: String
    let relativePath: String
    let remotes: [RemoteInfo]

    var id: String { rootPath }
}

struct MultiRootRemoteConfigAggregateContext: Identifiable {
    let roots: [MultiRootRemoteConfigRoot]

    var id: String { "multi-root-remotes" }
}

struct BranchCleanupSelection: Hashable {
    let rootPath: String
    let branchName: String
}

struct BranchCleanupRoot: Identifiable {
    let rootPath: String
    let displayName: String
    let relativePath: String
    let branches: [BranchInfo]
    let trackingByBranch: [String: String]
    let mergedBranches: Set<String>
    let calculatedTarget: String?
    let calculatedPrefix: String?
    let calculationError: String?

    init(
        rootPath: String,
        displayName: String,
        relativePath: String,
        branches: [BranchInfo],
        trackingByBranch: [String: String],
        mergedBranches: Set<String>,
        calculatedTarget: String?,
        calculatedPrefix: String?,
        calculationError: String? = nil
    ) {
        self.rootPath = rootPath
        self.displayName = displayName
        self.relativePath = relativePath
        self.branches = branches
        self.trackingByBranch = trackingByBranch
        self.mergedBranches = mergedBranches
        self.calculatedTarget = calculatedTarget
        self.calculatedPrefix = calculatedPrefix
        self.calculationError = calculationError
    }

    var id: String { rootPath }
}

/// Aggregate facts from the Find Merged report. Keeping this separate from
/// branch rows prevents a failed root from looking like a successful empty
/// result.
struct FindMergedScanSummary: Equatable {
    let targetBranch: String
    let prefix: String
    let repositoriesDiscovered: Int
    let repositoriesScanned: Int
    let candidateBranchesChecked: Int
    let mergedBranchesFound: Int
    let errors: [String]
    let elapsedMilliseconds: Int64
    let isCancelled: Bool

    var errorsCount: Int { errors.count }
}

/// A Find Merged result is a read-only document, but IntelliJ exposes it from
/// the operation notification after the scan has finished. Persist the
/// document itself so that a semantic "Open Report" action remains useful
/// after Arbor is relaunched, instead of silently starting a different scan.
struct PersistedFindMergedReport: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let projectPath: String
    let targetBranch: String
    let prefix: String
    let report: String
    let createdAt: Date
}

enum FindMergedReportStore {
    private static let defaultsKey = "arbor.findMergedReports.v1"
    private static let maximumReports = 32

    static func save(
        _ report: PersistedFindMergedReport,
        defaults: UserDefaults = .standard
    ) {
        var reports = loadAll(defaults: defaults)
        reports[report.id] = report
        let retained = reports.values
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(maximumReports)
        let encoded = Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func load(
        id: String,
        defaults: UserDefaults = .standard
    ) -> PersistedFindMergedReport? {
        loadAll(defaults: defaults)[id]
    }

    private static func loadAll(
        defaults: UserDefaults
    ) -> [String: PersistedFindMergedReport] {
        guard let data = defaults.data(forKey: defaultsKey),
              let reports = try? JSONDecoder().decode(
                  [String: PersistedFindMergedReport].self,
                  from: data
              ) else {
            return [:]
        }
        return reports
    }
}

/// A Changes Browser row must carry its owning Git root. The same relative
/// path is a different file when two nested repositories both contain, for
/// example, `README.md`.
struct MultiRootChangeSelection: Hashable, Sendable {
    let rootPath: String
    let path: String
    let oldPath: String?

    init(rootPath: String, path: String, oldPath: String? = nil) {
        self.rootPath = rootPath
        self.path = path
        self.oldPath = oldPath
    }

    var id: String { "\(rootPath)\u{1f}\(path)" }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rootPath == rhs.rootPath && lhs.path == rhs.path
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(rootPath)
        hasher.combine(path)
    }
}

struct MultiRootChangeGroup: Identifiable {
    let rootPath: String
    let displayName: String
    let relativePath: String
    let repository: Repository
    let entries: [FileEntry]

    var id: String { rootPath }

    var changedEntries: [FileEntry] {
        entries.filter {
            $0.staged != .unchanged
                || ($0.unstaged != .unchanged && $0.unstaged != .ignored)
        }
    }
}

/// The project-level Commit workflow exposes only commit-eligible staged
/// paths, while retaining conflict/no-staged state for explicit feedback.
struct MultiRootCommitGroup: Identifiable {
    let rootPath: String
    let displayName: String
    let relativePath: String
    let stagedPaths: [String]
    let stagedEntries: [MultiRootChangeSelection]
    let conflictedPaths: [String]
    let hasHead: Bool

    var id: String { rootPath }
    func canCommit(amend: Bool) -> Bool {
        conflictedPaths.isEmpty && (!stagedPaths.isEmpty || (amend && hasHead))
    }

    init(changeGroup: MultiRootChangeGroup) {
        rootPath = changeGroup.rootPath
        displayName = changeGroup.displayName
        relativePath = changeGroup.relativePath
        hasHead = changeGroup.repository.headCommitId() != nil
        stagedPaths = changeGroup.entries
            .filter {
                $0.staged != .unchanged
                    && $0.staged != .conflicted
                    && $0.staged != .ignored
            }
            .map(\.path)
            .sorted()
        stagedEntries = changeGroup.entries
            .filter {
                $0.staged != .unchanged
                    && $0.staged != .conflicted
                    && $0.staged != .ignored
            }
            .map {
                MultiRootChangeSelection(
                    rootPath: changeGroup.rootPath,
                    path: $0.path,
                    oldPath: $0.oldPath
                )
            }
            .sorted { $0.path < $1.path }
        conflictedPaths = changeGroup.entries
            .filter { $0.staged == .conflicted || $0.unstaged == .conflicted }
            .map(\.path)
            .sorted()
    }
}

enum OperationsViewMode: String, CaseIterable, Identifiable {
    case tasks
    case history
    case console
    case worktrees
    case submodules
    case roots

    var id: String { rawValue }
    var title: String {
        switch self {
        case .tasks: "任务"
        case .history: "操作历史"
        case .console: "Git Console"
        case .worktrees: "Worktrees"
        case .submodules: "Submodules"
        case .roots: "Git Roots"
        }
    }
}

struct BeforeCommitCommand: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var command: String
    var args: [String]

    var display: String {
        ([command] + args).joined(separator: " ")
    }
}

/// Root-scoped Shelf data used by the Commit workspace. The primary root is
/// still backed by the live workspace state; secondary roots keep their own
/// read/preview snapshot so a visible Shelf can never be mistaken for the
/// primary repository's Shelf.
struct ShelfRootSnapshot {
    let rootPath: String
    let shelves: [ShelveInfo]
    let deletedShelves: [ShelveInfo]
    let changeLists: [ChangeListInfo]

    init(
        rootPath: String,
        shelves: [ShelveInfo],
        deletedShelves: [ShelveInfo],
        changeLists: [ChangeListInfo] = []
    ) {
        self.rootPath = rootPath
        self.shelves = shelves
        self.deletedShelves = deletedShelves
        self.changeLists = changeLists
    }
}

struct ContentView: View {
    @Environment(\.openWindow) var openWindow
    let externalLogWindow: Bool
    let initialExternalLogRootPaths: Set<String>
    let externalLogProviderSession: ExternalLogProviderSession?
    let externalLogUIManager: ExternalLogManager?
    let externalLogTabsPersistenceKey: String?
    @StateObject var feedbackCenter = FeedbackCenter()
    @StateObject var credentialAuth = CredentialAuthController()
    @State var projectPath: String?
    @State var projectRepo: Repository?
    @State var path: String = ""
    @State var toolWindowMode: ToolWindowMode = .commit
    // ContentView is also hosted by the AppKit fallback window used when a
    // repository path is passed on the command line. SceneStorage is only
    // valid inside a SwiftUI Scene and causes repeated runtime warnings (and
    // unstable bindings) in that path. AppStorage keeps the same user-facing
    // persistence while remaining valid for both scene and AppKit hosting.
    @AppStorage("arbor.toolWindowExpanded") var toolWindowExpanded = true
    // Rebased opens the Project tool window as a compact bar; expanding it is
    // an explicit user action. Use a versioned key so the old default=true
    // cannot keep reopening a large tree below the Commit/Stash workspace.
    @AppStorage("arbor.projectPanelExpanded.v2") var projectPanelExpanded = false
    @AppStorage("arbor.toolWindowHeight") var toolWindowHeight: Double = 320
    // The reference workspace uses a ~470pt Commit/Stash column at a
    // 1640pt window width, with the Log editor occupying the remaining area.
    // Rebased keeps Commit/Stash in the left tool-window column while Git Log
    // occupies the editor workspace on the right. The reference frame is
    // roughly 470pt / 1170pt at a 1640pt window width.
    // 460pt subview + the 12pt native divider gives the ~472pt visible column.
    @AppStorage("arbor.workspaceSidebarWidth.v10") var savedWorkspaceSidebarWidth: Double = 460
    // The Log editor has its own graph/details splitter. Its graph/table side
    // is the dominant column in the reference frame; the details inspector is
    // the narrower right-hand column.
    // 748pt subview + the 12pt native divider leaves the ~358pt inspector.
    @AppStorage("arbor.logGraphWidth.v5") var savedLogGraphWidth: Double = 748
    // These are the same three persistent Log presentation properties exposed
    // by rebased's VcsLog UI actions. They are deliberately state, not layout
    // hacks: changing them must not reload or replace the selected commit.
    @AppStorage("arbor.log.showDetails.v1") var logShowDetails = true
    @AppStorage("arbor.log.showDiffPreview.v1") var logShowDiffPreview = true
    @AppStorage("arbor.log.diffPreviewVertical.v1") var logDiffPreviewVertical = false
    @AppStorage("arbor.log.compactReferences.v2") var logCompactReferences = true
    @AppStorage("arbor.log.commitColumns.v1") var logShowCommitColumns = false
    @AppStorage("arbor.log.authorColumn.v1") var logShowAuthorColumn = false
    @AppStorage("arbor.log.dateColumn.v1") var logShowDateColumn = false
    @AppStorage("arbor.log.hashColumn.v1") var logShowHashColumn = false
    @AppStorage("arbor.log.rootColumn.v1") var logShowRootColumn = false
    @AppStorage("arbor.log.signatureColumn.v1") var logShowSignatureColumn = false
    @AppStorage("arbor.log.columnOrder.v1") var logColumnOrderRaw = LogColumnLayout.defaultOrder.map(\.rawValue).joined(separator: ",")
    @AppStorage("arbor.log.columnWidths.v1") var logColumnWidthsRaw = ""
    // These mirror the graph actions exposed by VcsLogComponents. The first
    // three are presentation-only toggles that can be honored by the current
    // graph model; branch dashboard and session tabs are modeled locally so
    // changing presentation settings never resets the active history query.
    // VcsLogApplicationSettings defaults tag-name rendering to off. Branch,
    // HEAD and remote references are always part of the commit row.
    @AppStorage("arbor.log.showTagNames.v1") var logShowTagNames = false
    @AppStorage("arbor.log.alignLabels.v1") var logAlignLabels = false
    @AppStorage("arbor.log.showLongEdges.v1") var logShowLongEdges = true
    @AppStorage("arbor.log.collapseGraph.v1") var logCollapseGraph = false
    @State var logGraphCommand: LinearBekGraphCommand?
    @AppStorage("arbor.log.noMerges.v1") var logNoMerges = false
    @AppStorage("arbor.log.branches.visible.v1") var logBranchesVisible = false
    @State var logBranchesGroupByDirectory = GitBranchesPopupSettings.defaultGroupByDirectory
    @State var logBranchesGroupByRepository = GitBranchesPopupSettings.defaultGroupByRepository
    @State var logBranchesSelectionActionRaw = LogBranchSelectionAction.navigate.rawValue
    @State var logBranchesShowOnlyMy = false
    @State var logMyBranchIDs: Set<String> = []
    @State var logShowMyTask: Task<Void, Never>?
    @State var isLoadingMyBranches = false
    @AppStorage("arbor.log.highlightCherryPicked.v1") var logHighlightCherryPicked = false
    @AppStorage("arbor.log.highlightCherryPicked.branch.v1") var logCherryPickCompareBranch = ""
    @State var logCherryPickComparisonTask: Task<Void, Never>?
    @State var logCherryPickComparisonCancelHandle: GitCancelHandle?
    @State var logCherryPickComparisonInProgress = false
    @State var logCherryPickComparisonGeneration = 0
    @State var logCherryPickComparisonCompletedRoots = 0
    @State var logCherryPickComparisonTotalRoots = 0
    /// Global fallback for IntelliJ's project-level FETCH/LS_REMOTE
    /// incoming-change strategy. Project overrides are loaded below by the
    /// normalized project path, so one window never changes another project.
    @AppStorage("arbor.git.autoFetch.v1") var gitAutoFetch = false
    @AppStorage(GitIncomingOutgoingInfoSettings.key)
    var incomingOutgoingInfoEnabled = GitIncomingOutgoingInfoSettings.defaultValue
    /// Custom Git clean/smudge filters are executable repository config. The
    /// engine keeps them disabled unless the user explicitly opts in from
    /// Settings, matching the fail-closed default used by IntelliJ's safety
    /// boundary for external Git tools.
    @AppStorage("arbor.git.externalConversion.v1") var gitExternalConversionEnabled = false
    @AppStorage(GitIncomingCheckStrategy.userDefaultsKey)
    var incomingCheckStrategyRaw = GitIncomingCheckStrategy.none.rawValue
    @AppStorage(GitProtectedBranchRules.userDefaultsKey)
    var globalProtectedBranchPatterns = GitProtectedBranchRules.defaultPatterns
    @AppStorage(GitProtectedBranchRules.synchronizeKey)
    var globalProtectedBranchSynchronize = GitProtectedBranchRules.defaultSynchronize
    @State var projectProtectedBranchPatterns: String?
    @State var projectProtectedBranchSynchronize: Bool?
    @State var projectIncomingCheckStrategyRaw: String?
    @State var projectFetchTagsMode: GitFetchTagsModeChoice = .default
    @State var projectUpdateMethod: GitUpdateMethodChoice = .merge
    @State var showProjectGitSettings = false
    @State var showUpdateProjectOptions = false
    @AppStorage("arbor.log.showChangesFromParents.v1") var logShowChangesFromParents = false
    @AppStorage("arbor.log.showOnlyAffectedChanges.v1") var logShowOnlyAffectedChanges = false
    @State var autoFetchFailureFingerprint: String?
    @State var autoFetchIncomingFingerprint: String?
    @State var autoFetchIncomingBranches: Set<GitIncomingBranch> = []
    /// Each retry creates a new task generation. The monitor always performs
    /// its first check immediately, matching IntelliJ when a strategy is
    /// enabled or a project is activated.
    @State var autoFetchRunGeneration = 0
    var repo: Repository? {
        projectRepo
    }

    var searchEverywhereGitRoots: [SearchEverywhereGitRoot] {
        if !multiRootBranchSnapshots.isEmpty {
            return multiRootBranchSnapshots.map { snapshot in
                SearchEverywhereGitRoot(
                    rootPath: snapshot.rootPath,
                    displayName: snapshot.displayName,
                    relativePath: snapshot.relativePath,
                    branches: snapshot.branches,
                    remoteBranches: snapshot.remoteBranches,
                    tags: snapshot.tags
                )
            }
        }
        guard let repositoryPath = repo?.workdir(), !repositoryPath.isEmpty else {
            return []
        }
        let displayName = URL(fileURLWithPath: repositoryPath).lastPathComponent
        return [SearchEverywhereGitRoot(
            rootPath: repositoryPath,
            displayName: displayName.isEmpty ? repositoryPath : displayName,
            relativePath: ".",
            branches: branches,
            remoteBranches: remoteBranches,
            tags: tags
        )]
    }

    var newWorktreeRepository: Repository? {
        guard let rootPath = newWorktreeRootPath, !rootPath.isEmpty else {
            return repo
        }
        return try? openRepository(path: rootPath)
    }

    var newWorktreeBranches: [BranchInfo] {
        guard let rootPath = newWorktreeRootPath,
              let snapshot = multiRootBranchSnapshots.first(where: { $0.rootPath == rootPath }) else {
            return branches
        }
        return snapshot.branches
    }

    var newWorktreeWorktrees: [WorktreeInfo] {
        guard let rootPath = newWorktreeRootPath,
              let snapshot = multiRootBranchSnapshots.first(where: { $0.rootPath == rootPath }) else {
            return worktrees
        }
        return snapshot.worktrees
    }

    var logRepository: Repository? {
        if let selectedCommit,
           let selectedRepository = logRepository(for: selectedCommit) {
            return selectedRepository
        }
        if isLogRootQualified {
            return nil
        }
        if logActiveRootPath != nil {
            return logActiveRepo
        }
        return logActiveRepo ?? repo
    }

    var isLogAggregate: Bool {
        !logAggregateBranchFilters.isEmpty
            || !logAggregateRevisionRanges.isEmpty
            || !logAggregateRootPaths.isEmpty
    }

    var isLogRootQualified: Bool {
        isLogAggregate || (logViewMode == .command && logCommandIsAggregate)
    }

    var availableReflogRootPaths: [String] {
        var paths: [String] = []
        if let primary = repo?.workdir(), !primary.isEmpty {
            paths.append(primary)
        }
        paths.append(contentsOf: multiRoots.map(\.path))
        if let active = logActiveRootPath, !active.isEmpty {
            paths.append(active)
        }
        return Array(Set(paths)).sorted()
    }

    var primaryShelfRootPath: String? {
        if let workdir = repo?.workdir(), !workdir.isEmpty {
            return canonicalExternalLogPath(workdir)
        }
        if let projectPath, !projectPath.isEmpty {
            return canonicalExternalLogPath(projectPath)
        }
        return nil
    }

    var availableShelfRoots: [GitRootInfo] {
        guard multiRoots.count > 1 else { return [] }
        let primary = primaryShelfRootPath
        return multiRoots.sorted { lhs, rhs in
            let lhsIsPrimary = canonicalExternalLogPath(lhs.path) == primary
            let rhsIsPrimary = canonicalExternalLogPath(rhs.path) == primary
            if lhsIsPrimary != rhsIsPrimary { return lhsIsPrimary }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }

    var activeShelfRootPath: String? {
        if let shelfRootPath, !shelfRootPath.isEmpty {
            return canonicalExternalLogPath(shelfRootPath)
        }
        return primaryShelfRootPath
    }

    var isShelfRootReadOnly: Bool {
        !shelfRootSelectionIsPrimary(
            selectedRootPath: shelfRootPath,
            primaryRootPath: primaryShelfRootPath
        )
    }

    var canApplyShelfWorktree: Bool {
        !shelfRootLoading
            && shelfRootError == nil
            && activeShelfRootPath != nil
            && activeShelfRepository != nil
    }

    var canMutateShelfMetadata: Bool {
        canApplyShelfWorktree
    }

    var activeShelfSnapshot: ShelfRootSnapshot? {
        guard let rootPath = activeShelfRootPath,
              !shelfRootSelectionIsPrimary(
                  selectedRootPath: rootPath,
                  primaryRootPath: primaryShelfRootPath
              ) else { return nil }
        return shelfRootSnapshots[rootPath]
            ?? multiRootBranchSnapshots.first(where: {
                canonicalExternalLogPath($0.rootPath) == rootPath
            }).map {
                ShelfRootSnapshot(
                    rootPath: rootPath,
                    shelves: $0.shelves,
                    deletedShelves: []
                )
            }
    }

    var activeShelfList: [ShelveInfo] {
        guard let activeRoot = activeShelfRootPath,
              !shelfRootSelectionIsPrimary(
                  selectedRootPath: activeRoot,
                  primaryRootPath: primaryShelfRootPath
              ) else { return shelves }
        return activeShelfSnapshot?.shelves ?? []
    }

    var activeShelfChangeLists: [ChangeListInfo] {
        guard let activeRoot = activeShelfRootPath,
              !shelfRootSelectionIsPrimary(
                  selectedRootPath: activeRoot,
                  primaryRootPath: primaryShelfRootPath
              ) else { return changeLists }
        return activeShelfSnapshot?.changeLists ?? []
    }

    var activeDeletedShelfList: [ShelveInfo] {
        guard let activeRoot = activeShelfRootPath,
              !shelfRootSelectionIsPrimary(
                  selectedRootPath: activeRoot,
                  primaryRootPath: primaryShelfRootPath
              ) else { return deletedShelves }
        return activeShelfSnapshot?.deletedShelves ?? []
    }

    var activeShelfRepository: Repository? {
        guard let rootPath = activeShelfRootPath else { return repo }
        if shelfRootSelectionIsPrimary(
            selectedRootPath: rootPath,
            primaryRootPath: primaryShelfRootPath
        ) { return repo }
        return shelfRootRepository
    }

    var reflogRootTitle: String {
        guard let path = reflogRootPath, !path.isEmpty else { return "Repository" }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    var reflogRepository: Repository? {
        reflogRootRepo ?? (isLogAggregate ? nil : logRepository)
    }

    /// Graph selection is root-qualified only for an aggregate multi-root
    /// Log. Single-root behavior keeps the existing short-id-compatible
    /// selection model, while aggregate history cannot safely use a raw hash.
    func logCommitIdentity(_ commit: CommitInfo) -> String {
        logCommitIdentity(repositoryPath: commit.repositoryPath, id: commit.id)
    }

    func logCommitIdentity(repositoryPath: String?, id: String) -> String {
        logCommitDisplayIdentity(
            repositoryPath: repositoryPath,
            id: id,
            aggregate: isLogRootQualified
        )
    }

    func logRepository(for commit: CommitInfo) -> Repository? {
        guard let repositoryPath = commit.repositoryPath,
              !repositoryPath.isEmpty else {
            return logActiveRepo ?? repo
        }
        if let aggregateRepository = logAggregateRepositories[repositoryPath] {
            return aggregateRepository
        }
        if logActiveRootPath == repositoryPath {
            return logActiveRepo
        }
        if repo?.workdir() == repositoryPath {
            return repo
        }
        return try? openRepository(path: repositoryPath)
    }

    /// Mirrors IntelliJ's HostedGitRepositoryReference action group: only
    /// remotes that can produce a commit web reference participate, and the
    /// selected commit's repository path decides which root owns the remote.
    func hostedRemotesForCommit(_ commit: CommitInfo) -> [RemoteInfo] {
        guard let repository = logRepository(for: commit) else { return [] }
        return (try? repository.remoteList())?.filter { remote in
            repository.permalink(remoteUrl: remote.url, commitId: commit.id) != nil
        } ?? []
    }

    /// The Log "Open Pull Requests" action is a hosted reference action too,
    /// but it targets the provider's PR list rather than a commit permalink.
    /// Keep its remote candidates root-qualified and filter unsupported hosts.
    func pullRequestRemotesForCommit(_ commit: CommitInfo) -> [RemoteInfo] {
        guard let repository = logRepository(for: commit) else { return [] }
        return (try? repository.remoteList())?.filter { remote in
            HostingProvider.parse(remoteURL: remote.url) != nil
        } ?? []
    }

    func commentRemotesForCommit(_ commit: CommitInfo) -> [RemoteInfo] {
        pullRequestRemotesForCommit(commit)
    }

    func logRepository(for commits: [CommitInfo]) -> Repository? {
        guard let first = commits.first else { return nil }
        guard logCommitSelectionRepositoryPath(commits) != nil else { return nil }
        return logRepository(for: first)
    }

    func currentLogBranchName(for commit: CommitInfo) -> String? {
        guard let repository = logRepository(for: commit) else { return nil }
        return (try? repository.branchList())?.first(where: \.isCurrent)?.name
    }

    var activeLogBranches: [BranchInfo] {
        logActiveRootPath == nil ? branches : logActiveBranches
    }

    var activeLogRemoteBranches: [RemoteBranchInfo] {
        logActiveRootPath == nil ? remoteBranches : logActiveRemoteBranches
    }

    var activeLogRemotes: [RemoteInfo] {
        logActiveRootPath == nil ? remotes : logActiveRemotes
    }

    /// Include repository identity so a project restored before its
    /// repository finishes loading starts the monitor when the repo arrives,
    /// and a linked worktree switch replaces the watched Git directory.
    var repositoryIndexMonitorID: String {
        "\(projectPath ?? "")|\(repo?.gitDir() ?? "closed")"
    }

    var autoFetchRootPaths: [String] {
        mergedAutoFetchRootPaths(
            primary: repo?.workdir(),
            discovered: multiRoots.map(\.path)
        )
    }

    var autoFetchMonitorID: String {
        "\(repositoryIndexMonitorID)|\(autoFetchRootPaths.joined(separator: "|"))|\(incomingCheckStrategy.rawValue)|tags-\(fetchTagsMode)|run-\(autoFetchRunGeneration)"
    }

    var shelfLifecycleMonitorID: String {
        "\(repositoryIndexMonitorID)|\(autoFetchRootPaths.joined(separator: "|"))"
    }

    var autoFetchNotificationIDPrefix: String {
        let identity = projectPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "no-project"
        return "git.fetch.\(identity)"
    }

    var protectedBranchPatterns: String {
        projectProtectedBranchPatterns ?? globalProtectedBranchPatterns
    }

    var protectedBranchSynchronize: Bool {
        projectProtectedBranchSynchronize ?? globalProtectedBranchSynchronize
    }

    var incomingCheckStrategy: GitIncomingCheckStrategy {
        guard incomingOutgoingInfoEnabled else { return .none }
        if let projectIncomingCheckStrategyRaw {
            return GitIncomingCheckStrategy(rawValue: projectIncomingCheckStrategyRaw) ?? .none
        }
        return resolveGitIncomingCheckStrategy(
            storedRawValue: UserDefaults.standard.object(forKey: GitIncomingCheckStrategy.userDefaultsKey) == nil
                ? nil
                : incomingCheckStrategyRaw,
            legacyAutoFetch: gitAutoFetch
        )
    }

    var fetchTagsMode: FetchTagsMode {
        projectFetchTagsMode.engineValue
    }
    @State var entries: [FileEntry] = []
    @State var changeLists: [ChangeListInfo] = []
    @State var refreshGate = RepositoryRefreshGate()
    @State var repositoryChangeBatch = RepositoryChangeBatch()
    @State var repositoryExternalVCSActionManager = RepositoryExternalVCSActionManager()
    @State var repositoryDirtyScopeManager = RepositoryDirtyScopeManager()
    @State var repositoryDirtyFileManager = RepositoryDirtyFileManager()
    @State var repositoryChangeDeliveryTask: Task<Void, Never>?
    @State var ignoredRules: [IgnoreRuleInfo] = []
    @State var headId: String?
    @State var loadError: String?
    @State var isLoading = false
    @State var isShowingCachedStatusSnapshot = false
    @State var commitMessage: String = ""
    @State var commitFeedback: String?
    @State var amendMode = false
    @State var recentMessages: [String] = []
    @State var selection: String?
    @State var fileSelection: String?
    @State var fileSelectionVersion: FileContentVersion = .local
    /// Monotonic request used by the Project file-tree Annotate action. The
    /// file viewer owns the blame task; the parent only selects the path and
    /// asks the viewer to enter its existing Code/Blame mode.
    @State var fileContentBlameRequestID = 0
    @State var fileTreeDiffRequest: FileTreeDiffRequest?
    @State var fileReferenceComparisonRequest: FileReferenceComparisonRequest?
    @State var currentRevisionRequest: CurrentRevisionRequest?
    /// Commit workspace preview stays inside the left Stage panel, matching
    /// rebased's split diff preview; it must not replace the right Log editor.
    @State var commitPreviewPath: String?
    @State var commitPreviewVisible = false
    @State var commitPreviewMode: StagingPreviewMode = .unstaged
    @State var commitPreviewComparisonMode: DiffMode?
    @State var commitPreviewThreeVersions = false
    @State var pendingProjectPath: String?
    @State var showProjectSwitchAlert = false
    @State var showCloneDialog = false
    @State var cloneURL = ""
    @State var cloneParentDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    @State var cloneDirectoryName = ""
    // IntelliJ's git.clone.recurse.submodules advanced setting defaults to
    // true; persist the same preference instead of resetting it per dialog.
    @AppStorage(GitCloneSettings.recurseSubmodulesKey)
    var cloneRecursiveSubmodules = GitCloneSettings.defaultRecurseSubmodules
    /// 逐行暂存入口：侧栏「逐行」点击后选中文件并让 diff 视图进入选择模式
    @State var selectionModePath: String?
    // 日志模式
    @State var logEntries: [CommitInfo] = []
    @State var logCommandEntries: [CommitInfo] = []
    @State var logCommandIsAggregate = false
    @State var hasMoreLogCommand = true
    @State var logTabs: [LogTabDescriptor] = [LogTabDescriptor()]
    @State var activeLogTabID: UUID?
    @State var logSelection: String?
    /// IntelliJ shows an action-group popup when a commit has multiple
    /// parents or children. Keep the resolved records separate from the
    /// paged graph so the popup can include commits outside the viewport.
    @State var pendingLogNavigationCommits: [CommitInfo] = []
    @State var isLogNavigationChoicePresented = false
    @State var logNavigationChoosesParent = false
    @State var pendingLogNavigationSelection: String?
    @State var pendingLogNavigationGeneration: Int?
    /// IntelliJ's graph table is a real multi-selection table. Keep the
    /// active row in `logSelection` for the details panel, while this set
    /// preserves Cmd/Shift selections for toolbar and future batch actions.
    @State var logSelectedIDs: Set<String> = []
    @State var logPathFilter: String = ""
    @State var logPathFilterSelections: [LogPathFilterSelection] = []
    @State var logVisibleRootPathsRaw: String = ""
    @AppStorage("arbor.log.recentPathFilters.v1") var logRecentPathFiltersRaw = ""
    @AppStorage("arbor.log.visibleRootPaths.v1") var logVisibleRootPathsPersistedRaw = ""
    @State var isLogPathsEditorPresented = false
    @State var logPathsEditorText = ""
    @State var isLogPathsTreeChooserPresented = false
    @State var logPathsTreeChooserRoots: [LogPathChooserRoot] = []
    @State var logPathsTreeChooserSelections: Set<LogPathFilterSelection> = []
    /// Phase 5:log 加载代际计数——切换条件后旧请求结果直接丢弃(取消行为)。
    @State var logGeneration: Int = 0
    /// Keep the active history request cancellable. Generation checks protect
    /// state correctness; cancelling the task also prevents superseded log
    /// loads from competing for CPU while the user changes filters or panes.
    @State var logLoadTask: Task<Void, Never>?
    /// Coalesce several filter/control mutations arriving in one main-actor
    /// turn before starting the expensive VisibleGraph refresh.
    @State var logRefreshTask: Task<Void, Never>?
    @State var logSignatureLoadTask: Task<Void, Never>?
    @State var logSignatureGeneration: Int = 0
    @State var logSignatureStatuses: [String: CommitSignatureInfo] = [:]
    @State var logSignatureLoadingIDs: Set<String> = []
    @State var logSignatureFailedIDs: Set<String> = []
    @State var logCommandTask: Task<Void, Never>?
    /// A commit referenced by a notification or reflog may not be in the
    /// currently visible history page. Keep that detail record separate from
    /// the paged graph so the inspector never falls back to an empty pane.
    @State var logDetailCommit: CommitInfo?
    @State var reflogDetailCommit: CommitInfo?
    @State var reflogDetailCommits: [CommitInfo] = []
    @State var revisionBrowserCommit: CommitInfo?
    @State var revisionBrowserPath: String?
    @State var showRevisionBrowser = false
    @State var logDetailLoadTask: Task<Void, Never>?
    @State var reflogDetailLoadTask: Task<Void, Never>?
    @State var compareLoadTask: Task<Void, Never>?
    @State var isLoadingLog = false
    @State var isShowingCachedLogSnapshot = false
    /// REPO-001:多 root 发现与聚合结果
    @State var multiRoots: [GitRootInfo] = []
    @State var multiRootBranchSnapshots: [GitRootBranchSnapshot] = []
    @State var multiRootResults: [RootOperationResult] = []
    @State var multiRootChangeGroups: [MultiRootChangeGroup] = []
    @State var multiRootChangesLoading = false
    @State var multiRootChangesError: String?
    @State var multiRootChangesGeneration = 0
    @State var showMultiRootChanges = false
    @State var showMultiRootCommitDialog = false
    @State var multiRootCommitMessage = ""
    @State var multiRootCommitRecentMessages: [String] = []
    @State var multiRootCommitAmendMode = false
    @State var multiRootCommitSkipHooks = false
    @State var multiRootCommitAuthorName = ""
    @State var multiRootCommitAuthorEmail = ""
    @State var multiRootCommitCommitterName = ""
    @State var multiRootCommitCommitterEmail = ""
    @State var multiRootCommitSignOff = false
    @State var multiRootCommitCoAuthors = ""
    @State var multiRootCommitSelectedPaths: [MultiRootChangeSelection]?
    @State var multiRootUpstreamContext: MultiRootUpstreamContext?
    @State var multiRootConflictGroups: [MultiRootConflictGroup] = []
    @State var multiRootConflictBatchWorking = false
    @State var multiRootConflictBatchError: String?
    @State var showMultiRootNewBranchDialog = false
    @State var multiRootNewBranchName = ""
    @State var multiRootNewBranchBase = ""
    @State var multiRootNewBranchCheckout = true
    @State var multiRootNewBranchResetExisting = false
    @State var multiRootExistingBranchNames: [String: Set<String>] = [:]
    @State var multiRootSelectedRootPaths: Set<String> = []
    @State var showMultiRootRenameBranchDialog = false
    @State var multiRootRenameOldName = ""
    @State var multiRootRenameNewName = ""
    @State var multiRootRenameUnsetUpstream = false
    @State var multiRootRenameSelectedRootPaths: Set<String> = []
    @State var showSingleRootRenameBranchDialog = false
    @State var singleRootRenameRootPath = ""
    @State var singleRootRenameOldName = ""
    @State var singleRootRenameNewName = ""
    @State var singleRootRenameUnsetUpstream = false
    @State var singleRootRenameHasUpstream = false
    @State var showMultiRootDeleteBranchDialog = false
    @State var multiRootDeleteBranchName = ""
    @State var multiRootDeleteSelectedRootPaths: Set<String> = []
    @State var showMultiRootMergeDialog = false
    @State var multiRootMergeBranchName = ""
    @State var multiRootMergeSelectedRootPaths: Set<String> = []
    @State var multiRootMergeMergedBranchesByRoot: [String: Set<String>] = [:]
    @State var multiRootMergeDialogGeneration = 0
    @State var multiRootMergeRollbackContext: MultiRootMergeRollbackContext?
    @State var showMultiRootDeleteTagDialog = false
    @State var multiRootDeleteTagName = ""
    @State var multiRootDeleteTagSelectedRootPaths: Set<String> = []
    @State var showMultiRootRemoteDeleteDialog = false
    @State var multiRootRemoteDeleteBranchName = ""
    @State var multiRootRemoteDeleteSelectedRootPaths: Set<String> = []
    @State var multiRootRemoteDeleteTracking = false
    @State var multiRootRunning = false
    /// Closes the small discovery window before Update Project can publish
    /// its ordinary multi-root runner state. It is deliberately separate from
    /// `multiRootRunning` so single-root Update does not appear as a multi-root
    /// result while roots are being discovered.
    @State var updateProjectDiscoveryRunning = false
    @State var multiRootUpdateRebase = false
    /// Explicit per-root methods selected by the rebase-over-merge warning.
    /// A nil value means the project-wide method applies to every root.
    @State var multiRootUpdateRebaseRootPaths: Set<String>?
    @State var multiRootUpdateRetryAvailable = false
    @State var multiRootCheckoutUpdateRetryAvailable = false
    @State var multiRootCheckoutUpdateRetryContext: MultiRootCheckoutUpdateRetryContext?
    @State var multiRootPushRetryContext: MultiRootPushRetryContext?
    @State var multiRootStashConflicts: [String: [String]] = [:]
    @State var multiRootStashConflictIndexes: [String: Int] = [:]
    @State var multiRootStashConflictIDs: [String: String] = [:]
    @State var multiRootStashConflictPopModes: [String: Bool] = [:]
    /// 项目级统一冲突 resolver：一次维护所有 root 的 pending queue，
    /// 当前 root 的三栏编辑器由 active* 状态驱动。
    @State var showMultiRootConflictResolver = false
    @State var multiRootResolverRoots: [MultiRootConflictResolverRoot] = []
    @State var multiRootResolverActiveRootPath: String?
    @State var multiRootResolverActiveRepo: Repository?
    @State var multiRootResolverActiveEntries: [FileEntry] = []
    @State var multiRootResolverActiveInitialPath: String?
    @State var multiRootResolverActiveKind: MultiRootConflictResolverKind?
    @State var multiRootResolverWorking = false
    @State var multiRootResolverError: String?
    @State var multiRootResolverLoadGeneration = 0
    @State var multiRootUpdateStashedRoots: Set<String> = []
    @State var logFollow = false
    @State var logGraphSortModeRaw = LogGraphSortChoice.byCommitDate.rawValue
    @State var logViewMode: LogViewMode = .graph
    @State var logCommandFilter = ""
    @State var logCommandError: String?
    @State var logCommandGeneration = 0
    @State var isLoadingLogCommand = false
    @State var logStartRevision: String = ""
    @State var logStartRevisions: Set<String> = []
    /// The Log dashboard may be scoped to a nested Git root without changing
    /// the project's primary repository context used by Commit/Status panes.
    @State var logActiveRootPath: String?
    @State var logActiveRepo: Repository?
    @State var logActiveBranches: [BranchInfo] = []
    @State var logActiveRemoteBranches: [RemoteBranchInfo] = []
    @State var logActiveRemotes: [RemoteInfo] = []
    @State var logAggregateBranchFilters: [LogRootBranchFilter] = []
    @State var logAggregateRevisionRanges: [LogRootRevisionRange] = []
    /// External Git Log windows can aggregate all or a selected subset of the
    /// project's discovered Git roots. An empty set means the selector has
    /// not been initialized yet (or discovery currently has no roots).
    @State var logAggregateRootPaths: Set<String> = []
    @State var externalLogRootSelectionInitialized = false
    @State var externalLogRootRequestConsumed = false
    @State var externalLogAggregateLoadStarted = false
    @State var externalLogSessionDisposed = false
    @State var logAggregateRepositories: [String: Repository] = [:]
    @State var logAggregateLoadedCounts: [String: Int] = [:]
    /// Each aggregate-log root owns an independent engine pagination cursor.
    /// Keeping this separate from the merged row count prevents a later page
    /// from re-querying the entire root history just to discard its prefix.
    @State var logAggregatePageCursors: [String: String] = [:]
    @State var showLogRevisionFilterAlert = false
    @State var logRevisionFilterInput = ""
    @State var logAuthorFilter: String = ""
    @State var logMessageFilter: String = ""
    @State var logMessageRegex = false
    @State var logMessageMatchCase = false
    @State var logSinceText: String = ""
    @State var logUntilText: String = ""
    @State var logCherryPickedCommitIDs: Set<String> = []
    @State var logCherryPickComparisonReady = false
    @State var compareRev1: String = ""
    @State var compareRev2: String = ""
    @State var compareRepositoryPath: String?
    @State var compareWithWorkingTree = false
    @State var activeCompareRepo: Repository?
    @State var treeChanges: [TreeChange] = []
    @State var compareSelection: String?
    @State var compareSelectedPaths: Set<String> = []
    @State var compareError: String?
    @State var branchCompareFirstEntries: [CommitInfo] = []
    @State var branchCompareSecondEntries: [CommitInfo] = []
    @State var branchCompareFirstFilter = BranchComparisonFilter()
    @State var branchCompareSecondFilter = BranchComparisonFilter()
    @State var branchCompareSelectionID: String?
    @State var branchCompareSelectionSide: BranchComparisonSide = .first
    @State var isLoadingBranchComparison = false
    @State var branchCompareFirstLoading = false
    @State var branchCompareSecondLoading = false
    @State var branchCompareFirstHasMore = false
    @State var branchCompareSecondHasMore = false
    @State var branchCompareGeneration = 0
    @State var branchCompareFirstRequestGeneration = 0
    @State var branchCompareSecondRequestGeneration = 0
    @State var branchCompareFirstLoadTask: Task<Void, Never>?
    @State var branchCompareSecondLoadTask: Task<Void, Never>?
    @State var branchCompareFirstError: String?
    @State var branchCompareSecondError: String?
    @State var branchCompareError: String?
    @State var reflogEntries: [ReflogEntry] = []
    @State var reflogSelection: String?
    @State var reflogSelectedIDs: Set<String> = []
    /// Reflog is a repository-local history. Keep its root separate from the
    /// aggregate VCS Log filters so switching from a multi-root graph cannot
    /// leave the Reflog panel showing an unrelated or stale repository.
    @State var reflogRootPath: String?
    @State var reflogRootRepo: Repository?
    @State var reflogLoadTask: Task<Void, Never>?
    @State var reflogLoadMoreTask: Task<Void, Never>?
    @State var reflogGeneration = 0
    @State var reflogHasMore = false
    @State var isLoadingMoreReflog = false
    @State var logPageCursor: String?
    @State var isLoadingMoreLog = false
    @State var hasMoreLog = true
    @State var rebasePaused = false
    /// OPS-001 统一操作状态（merge/rebase/cherry-pick/revert），Recovery Bar 数据源。
    @State var operationState: OperationState?
    /// 每个 Git root 最近一次已发布的 operation recovery 状态。外部 Git
    /// 操作会反复触发 metadata refresh，按 fingerprint 去重可避免同一
    /// 暂停操作不断重发通知，同时允许新冲突文件或操作阶段重新提示。
    @State var operationRecoveryNotificationFingerprints: [String: String] = [:]
    /// Per-root persisted Log Revert/Cherry-pick recovery notices. This is
    /// separate from operation_state(): Git may have completed or never
    /// started the sequencer while the app was being terminated.
    @State var logApplyRecoveryNotificationFingerprints: [String: String] = [:]
    @State var resolvedConflictPaths: [String] = []
    @State var operationFeedback: String?
    /// REBASE-001 todo 编辑器状态
    @State var showRebaseTodoEditor = false
    @State var rebaseTodoItems: [RebaseTodoItem] = []
    @State var rebaseTodoOnto = ""
    @State var rebaseTodoPreserveMerges = false
    @State var rebaseTodoRoot = false
    /// Native Git todo fallback.  This keeps label/reset/merge/exec and any
    /// future Git commands as editable text instead of forcing them through
    /// the structured six-action model.
    @State var showRawRebaseTodoEditor = false
    @State var rebaseRawTodoText = ""
    @State var showRawRebaseMessageEditor = false
    @State var rawRebaseMessageText = ""
    @State var rawRebaseMessageRepository: Repository?
    /// Log HEAD Reword uses Git's `--amend --only` path so staged changes stay staged.
    @State var showLogRewordDialog = false
    @State var logRewordCommit: CommitInfo?
    @State var logRewordMessage = ""
    @State var logRewordUsesRootRebase = false
    @State var showLogSquashDialog = false
    @State var logSquashMessage = ""
    @State var logSquashIndexes: [Int] = []
    @State var logSquashSummaries: [String] = []
    /// Log Fixup/Squash keeps IntelliJ's optional Commit and Rebase executor
    /// available until the generated commit is created.
    @State var pendingAutoSquashRebase: PendingAutoSquashRebase?
    /// IntelliJ warns before editing the initial commit instead of silently
    /// rejecting the action.
    @State var showInitialCommitRewordAlert = false
    @State var pendingInitialCommitReword: CommitInfo?
    @State var showInitialCommitRewriteAlert = false
    @State var pendingInitialCommitRewrite: PendingInitialCommitRewrite?
    /// IDX-001 三层 staging 模型（二进制徽标/忽略入口数据源）。
    @State var stagingModel: StagingModel?
    /// index tracker：外部 Git 修改 index 后提示刷新。
    @State var lastIndexRevision: IndexRevision?
    /// Invalidates read-only version viewers and staging diff previews after
    /// any visible status refresh, including worktree-only changes where the
    /// index did not change.
    @State var fileContentRefreshToken = 0
    @State var rebasePauseReason: RebasePauseReason?
    @State var rebaseConflicts: [String] = []
    @State var logError: String?
    // 分支模式
    @State var mergeBranch: String = ""
    @State var mergeMergedBranches: Set<String> = []
    @State var mergeDialogGeneration = 0
    @State var mergeStrategyRaw = MergeStrategyChoice.automatic.rawValue
    @AppStorage(GitDeleteOnMergeOption.key) var mergeDeleteOnMergeRaw = GitDeleteOnMergeOption.defaultOption.rawValue
    @State var mergeCommitMessage = ""
    @State var mergeUseCustomCommitMessage = false
    @State var mergeNoCommit = false
    @State var mergeNoVerify = false
    @State var mergeAllowUnrelatedHistories = false
    @State var mergeFeedback: String?
    @State var newBranchName: String = ""
    /// A Log commit can belong to a non-primary Git root. Keep the branch
    /// dialog and its write operation pinned to that root instead of falling
    /// back to the window's primary repository.
    @State var newBranchRepositoryOverride: Repository?
    @State var newBranchDialogBranches: [BranchInfo] = []
    @State var renameOld: String = ""
    @State var renameNew: String = ""
    @State var branches: [BranchInfo] = []
    @State var branchComparisons: [String: BranchCompare] = [:]
    @State var stashMessage: String = ""
    @State var stashKeepIndex = false
    @State var stashRootPath: String?
    @State var stashCurrentBranch = ""
    @State var stashRootLoading = false
    @State var shelveName: String = ""
    @State var shelves: [ShelveInfo] = []
    @State var deletedShelves: [ShelveInfo] = []
    /// Monotonic request used by VCS > Git > Local Changes > Show Shelf/Stash.
    /// RebasedCommitWorkspace owns the tab state, so the request crosses the
    /// workspace boundary without making the parent duplicate that state.
    @State var shelfTabRequestID = 0
    @State var isShelfWorkspaceTabActive = false
    @State var shelfRootPath: String?
    @State var shelfRootSnapshots: [String: ShelfRootSnapshot] = [:]
    @State var shelfRootRepository: Repository?
    @State var shelfRootLoading = false
    @State var shelfRootError: String?
    @State var shelfRootLoadGeneration = 0
    @State var stashes: [StashInfo] = []
    @State var unstashRootPath: String?
    @State var unstashStashes: [StashInfo] = []
    @State var unstashCurrentBranch = ""
    @State var unstashRootLoading = false
    // 远程
    @State var remotes: [RemoteInfo] = []
    @State var isShallowRepository = false
    @State var remoteBranches: [RemoteBranchInfo] = []
    /// BRANCH-001 Recent 分组（HEAD reflog 最近检出）。
    @State var recentBranches: [String] = []
    @State var syncStatuses: [SyncStatus] = []
    @State var pushForce = false
    @State var remoteProtectedBranchPatterns: [String] = []
    /// Hosted protection is repository-scoped. Keep it separate from the
    /// primary root's legacy presentation state so a multi-root push cannot
    /// accidentally use another repository's cached rules.
    @State var remoteProtectedBranchPatternsByRoot: [String: [String]] = [:]
    @State var remoteName: String = ""
    @State var remoteUrl: String = ""
    /// REMOTE-001 Configure Remotes Dialog 状态
    @State var showSearchEverywhere = false
    @StateObject var vcsQuickActionsPanel = VCSQuickActionsPanelCoordinator()
    @State var searchEverywhereQuery = ""
    @State var showRemoteConfigDialog = false
    @State var remotePushUrl: String = ""
    @State var remoteFetchRefspec: String = ""
    @State var remotePushRefspec: String = ""
    @State var multiRootRemoteConfigContext: MultiRootRemoteConfigContext?
    @State var multiRootRemoteConfigAggregateContext: MultiRootRemoteConfigAggregateContext?
    @StateObject var branchCleanupWindow = BranchCleanupWindowCoordinator()
    @State var branchCleanupGeneration = 0
    @State var showFindMergedBranchesDialog = false
    @State var findMergedBranchesRoots: [BranchCleanupRoot] = []
    @State var findMergedTargetBranch = ""
    @State var findMergedPrefix = ""
    @State var findMergedRunning = false
    @State var findMergedHasCalculated = false
    @State var findMergedSummary: FindMergedScanSummary?
    @State var findMergedGeneration = 0
    @State var findMergedTask: Task<Void, Never>?
    @State var findMergedReportID: String?
    @State var findMergedReportText = ""
    @State var showFindMergedReport = false
    @State var multiRootRemoteName: String = ""
    @State var multiRootRemoteURL: String = ""
    @State var multiRootRemotePushURL: String = ""
    @State var multiRootRemoteFetchRefspec: String = ""
    @State var multiRootRemotePushRefspec: String = ""
    // 变基
    @State var rebaseOnto: String = ""
    @State var rebaseBranch: String = ""
    @State var rebaseRootPath: String = ""
    @State var rebaseRange: [CommitInfo] = []
    @State var rebaseActions: [RebaseAction] = []
    @State var rebaseRangeGeneration = 0
    @State var rebaseInteractive = false
    @State var rebasePreserveMerges = false
    @State var rebaseAutoSquash = false
    @State var rebaseKeepEmpty = false
    @State var rebaseUpdateRefs = false
    @State var rebaseRoot = false
    @State var rebaseApplyToAllRoots = false
    @State var showMultiRootRebaseEditor = false
    @State var multiRootRebaseDrafts: [MultiRootRebaseTodoDraft] = []
    @State var multiRootRawTodoContext: MultiRootRawTodoContext?
    @State var multiRootRawTodoText = ""
    @State var multiRootRebaseSession: MultiRootRebaseSession?
    @State var multiRootRebaseRollbackContext: MultiRootRebaseRollbackContext?
    @State var rebaseRetryContext: RebaseRetryContext?
    @State var rebaseUndoSeed: RebaseUndoSeed?
    @State var rebaseUndoTarget: RebaseUndoTarget?
    @State var rebaseFeedback: String?
    @State var tags: [TagInfo] = []
    @State var tagName: String = ""
    @State var tagAt: String = ""
    @State var tagMessage: String = ""
    @State var tagSignKey: String = ""
    @State var tagAnnotated = false
    @State var tagForce = false
    @State var tagFeedback: String?
    @State var tagRepositoryOverride: Repository?
    @State var submoduleUrl: String = ""
    @State var submodulePath: String = ""
    @State var submodules: [SubmoduleInfo] = []
    @State var submoduleFeedback: String?
    @State var showSubmoduleLog = false
    @State var submoduleLogPath = ""
    @State var submoduleLogEntries: [CommitInfo] = []
    @State var submoduleLogError: String?
    @State var stashDiffText: String?
    @State var stashDiffStashID: String?
    @State var stashDiffRootPath: String?
    @State var showStashDiff = false
    @State var stashPreviewStashID: String?
    @State var stashPreviewText: String?
    @State var showStashPreview = false
    @State var shelfPreviewName: String?
    @State var shelfPreviewIsDeleted = false
    @State var shelfPreviewText: String?
    @State var showShelfPreview = false
    @State var shelfPreviewRootPath: String?
    @State var worktrees: [WorktreeInfo] = []
    @State var worktreeFeedback: String?
    @State var showNewWorktreeDialog = false
    /// Root selected by a Branches Popup worktree action. Keeping this
    /// separate from `repo` prevents a multi-root popup from silently
    /// creating the worktree in the primary repository.
    @State var newWorktreeRootPath: String?
    @State var newWorktreeReference = ""
    @State var newWorktreeIsTag = false
    @State var newWorktreePath = ""
    @State var newWorktreeBranch = ""
    @State var operationsViewMode: OperationsViewMode = .history
    @State var operationLogFocusNotificationID: String?
    @State var consoleResult: GitCommandResult?
    @State var skipHooks = false
    @State var beforeCommitCommands: [BeforeCommitCommand] = []
    @State var showBeforeCommitSettings = false
    @State var showIdentitySettings = false
    @State var pendingIdentityCommitRetry = false
    @State var showGpgAgentSettings = false
    @State var showGitSSHSettings = false
    @State var gitSSHCommand = ""
    @State var gitSSHKnownHostsFile = ""
    @State var gitSSHIdentityFile = ""
    @State var gitSSHHostKeyPolicy: SshHostKeyPolicy = .strict
    @State var gitSSHAuthMethod: SshAuthMethod = .auto
    @State var gitCredentialHelperConfig = ""
    @State var gitCredentialHelpers: [CredentialHelperInfo] = []
    @State var gitSSHAgentDiagnostics: SshAgentDiagnostics?
    @State var lastSuccessfulSSHAuthentications: [SSHAuthenticationRecord] = []
    @State var identityName = ""
    @State var identityEmail = ""
    @State var identitySetNameEmailGlobally = GitIdentityScopeSettings.defaultSetNameEmailGlobally
    @State var identitySigningKey = ""
    @State var identitySigningFormat = "gpg"
    @State var identitySignCommits = false
    @State var identityAuthorName = ""
    @State var identityAuthorEmail = ""
    @State var identityRecentAuthors: [String] = []
    @State var identityCommitterName = ""
    @State var identityCommitterEmail = ""
    @State var identitySignOff = false
    @State var identityCoAuthors = ""
    @State var showPushDialog = false
    @State var showMultiRootPushOptions = false
    @State var multiRootPushOptionsRootPaths: [String]?
    @State var multiRootPushOptionsFromCommit = false
    @State var multiRootPushContext: MultiRootPushContext?
    @State var addCommitsToRemoteBranchContext: AddCommitsToRemoteBranchContext?
    @State var pushDialogMode: PushDialogMode = .push
    /// IntelliJ's Commit and Push executor commits first and opens the Push
    /// options only after the commit succeeds. Keep that intent out of the
    /// push dialog so a failed commit can never publish anything.
    @State var pendingCommitAndPush = false
    @State var pushDialogRefspec: String?
    @State var pushDialogRemote: String?
    @State var pushDialogBranch: String?
    @State var pushDialogSourceRevision: String?
    @State var pushFeedback: String?
    @State var mergeInProgress = false
    /// Source local branch captured by an engine merge. Kept until the
    /// explicit finish path completes so Delete-on-Merge survives conflict
    /// resolution in the current app session.
    @State var pendingMergeDeleteBranch: String?
    /// ORIG_HEAD fallback covers a merge resumed after the view was recreated;
    /// the in-memory value is preferred while this session owns the boundary.
    @State var mergeInitialHead: String?
    @State var stashPopConflictInProgress = false
    @State var stashApplyConflictInProgress = false
    @State var shelveConflictInProgress = false
    @State var shelveConflictIsPop = false
    @State var shelveConflictIsDirectPatch = false
    @State var pendingShelveConflictName: String?
    @State var pendingShelveConflictRepository: Repository?
    @State var pendingShelveConflictChangeList: String?
    @State var pendingShelveConflictPatch: String?
    @State var pendingShelveConflictNotificationID: String?
    @State var pendingStashConflictNotificationID: String?
    /// Legacy stack position retained for compatibility with the multi-root
    /// resolver. Single-root conflict completion prefers the stable stash ID.
    @State var pendingStashPopIndex: Int?
    /// Stable stash object identity retained while a pop restore is paused.
    /// The stash stack can be reordered while the conflict resolver is open.
    @State var pendingStashPopID: String?
    @State var pendingPullStashPop = false
    /// Stable identity for the temporary Pull stash. The message remains as
    /// a compatibility fallback for markers written by older builds.
    @State var pendingPullStashID: String?
    @State var pendingPullStashMessage: String?
    @State var pendingPullShelfName: String?
    @State var showHostingSettings = false
    @State var showHostingAuthPrompt = false
    @State var reviewCommentCommit: CommitInfo?
    @State var reviewCommentRepository: HostingRepository?
    @State var showReviewComment = false
    // Rebased 页面级弹出与对话框
    @State var showBranchesPopover = false
    @State var showUpstreamDialog = false
    @State var upstreamLocalBranch = ""
    @State var showNewBranchDialog = false
    @State var newBranchDialogTitle = "New Branch"
    @State var newBranchBase = ""
    @State var newBranchCheckout = true
    @State var newBranchResetExisting = false
    @State var newBranchAfterCreateRebase = false
    @State var showMergeActionDialog = false
    @State var showRebaseActionDialog = false
    @State var showPullDialog = false
    @State var pullDialogSnapshots: [GitRootBranchSnapshot] = []
    @State var pullDialogRebase = false
    @State var pullDialogGeneration = 0
    @State var showStashDialog = false
    @State var showUnstashDialog = false
    @State var showUnstashAsDialog = false
    @State var unstashAsStashID: String?
    @State var showStashFilesDialog = false
    @State var uncommitRequest: RebasedUncommitRequest?
    @State var stashFilesInitialPaths: Set<String> = []
    @State var stashFilesMessage = ""
    @State var showNewTagDialog = false
    @State var showRemoteTagsDialog = false
    @State var showMultiRootRemoteTagsDialog = false
    @State var showShelveDialog = false
    @State var pendingApplyPatch: RebasedApplyPatchRequest?
    @State var patchExportRequest: PatchExportRequest?
    @State var pendingIgnoreFileCreation: IgnoreFileCreationRequest?
    @State var showResetDialog = false
    @State var resetTargetCommit: CommitInfo?
    @State var resetTargetCommits: [CommitInfo] = []
    @State var resetMode: ResetMode = .mixed
    @State var showHeadResetDialog = false
    @State var headResetRootPath = ""
    @State var headResetTarget = "HEAD"
    @State var headResetMode: ResetMode = .mixed
    @State var smartOperationRequest: SmartOperationRequest?
    @State var showMergeRevisionsDialog = false
    /// The conflict dialog can be opened from the left Commit/Stash workspace
    /// while Git Log owns the right editor workspace. Keep its initial file
    /// independent from the main editor selection so opening the resolver does
    /// not replace the Log graph underneath it.
    @State var mergeInitialPath: String?
    @State var feedbackDetailMessage: FeedbackMessage?
    @State var branchDeleteRecovery: BranchDeleteRecoveryContext?
    @State var multiRootBranchDeleteRecovery: MultiRootBranchDeleteRecoveryContext?
    @State var tagDeleteRecovery: TagDeleteRecoveryContext?
    @State var multiRootTagDeleteRecovery: MultiRootTagDeleteRecoveryContext?

    init(
        projectPath: String? = nil,
        initialToolWindowMode: ToolWindowMode = .commit,
        externalLogWindow: Bool = false,
        initialExternalLogRootPaths: [String] = [],
        externalLogProviderSession: ExternalLogProviderSession? = nil,
        externalLogUIManager: ExternalLogManager? = nil
    ) {
        self.externalLogWindow = externalLogWindow
        self.externalLogProviderSession = externalLogProviderSession
        self.externalLogUIManager = externalLogUIManager
        let normalizedInitialExternalLogRoots = Set(normalizedLogRootPaths(initialExternalLogRootPaths))
        self.initialExternalLogRootPaths = normalizedInitialExternalLogRoots
        _logAggregateRootPaths = State(initialValue: self.initialExternalLogRootPaths)
        _logAggregateRepositories = State(
            initialValue: externalLogUIManager?.repositories(
                for: Array(normalizedInitialExternalLogRoots)
            ) ?? externalLogProviderSession?.repositories(
                for: Array(normalizedInitialExternalLogRoots)
            ) ?? [:]
        )
        _externalLogRootSelectionInitialized = State(
            initialValue: externalLogWindow && !self.initialExternalLogRootPaths.isEmpty
        )
        _externalLogSessionDisposed = State(initialValue: false)
        // Rebased reopens the most recent project instead of dropping the
        // user into an empty welcome surface on every launch. An explicit
        // command-line project remains authoritative; otherwise choose the
        // first recent directory that still exists.
        let recoveredPath = projectPath ?? Self.recentProjectPath()
        self.externalLogTabsPersistenceKey = externalLogWindow
            ? recoveredPath.map {
                ExternalLogTabsStore.key(
                    projectPath: $0,
                    rootPaths: normalizedInitialExternalLogRoots
                )
            }
            : nil

        var restoredExternalTabs: [LogTabDescriptor] = []
        var restoredExternalActiveTabID: UUID?
        if externalLogWindow, let recoveredPath,
           let state = ExternalLogTabsStore.load(
               projectPath: recoveredPath,
               rootPaths: normalizedInitialExternalLogRoots
           ) {
            let sanitizedState = state.sanitized()
            restoredExternalTabs = sanitizedState.tabs
            restoredExternalActiveTabID = sanitizedState.activeTabID
        }
        if restoredExternalTabs.isEmpty {
            restoredExternalTabs = [LogTabDescriptor()]
        }
        let restoredActiveTabID = restoredExternalActiveTabID.flatMap { id in
            restoredExternalTabs.contains(where: { $0.id == id }) ? id : nil
        } ?? restoredExternalTabs[0].id
        if externalLogWindow {
            restoredExternalTabs.forEach { _ = externalLogUIManager?.registerUI($0.id) }
        }
        _logTabs = State(initialValue: externalLogWindow ? restoredExternalTabs : [LogTabDescriptor()])
        _activeLogTabID = State(initialValue: externalLogWindow ? restoredActiveTabID : nil)
        _projectPath = State(initialValue: recoveredPath)
        _path = State(initialValue: recoveredPath ?? "")
        _logBranchesSelectionActionRaw = State(initialValue: GitBranchesPopupSettings.stringValue(
            GitBranchesPopupSettings.logSelectionActionKey,
            for: recoveredPath
        ))
        _logBranchesGroupByDirectory = State(initialValue: GitBranchesPopupSettings.value(
            GitBranchesPopupSettings.groupByDirectoryKey,
            for: recoveredPath
        ))
        _logBranchesGroupByRepository = State(initialValue: GitBranchesPopupSettings.value(
            GitBranchesPopupSettings.groupByRepositoryKey,
            for: recoveredPath
        ))
        let rememberedMode = UserDefaults.standard.string(forKey: "arbor.toolWindowMode")
            .flatMap(ToolWindowMode.init(rawValue:))
        // --log is an explicit launch request; otherwise restore the last
        // workspace so reopening a project returns to the same Git surface.
        _toolWindowMode = State(initialValue: initialToolWindowMode == .log ? .log : (rememberedMode ?? initialToolWindowMode))
    }

    // Kept internal so the AppKit/WindowGroup lifecycle recovery can repeat
    // the same valid-repository selection after state restoration.
    static func recentProjectPath() -> String? {
        let paths = UserDefaults.standard.stringArray(forKey: "lastOpenedPaths") ?? []
        let gitDirectories = paths.filter { candidate in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return false
            }
            // A recent folder is not automatically a Git project. Rebased
            // restores the last usable VCS workspace; reopening an arbitrary
            // source folder here would send the user back to the empty-state
            // shell with no log, branches, or Commit workspace data.
            var isGitMarkerDirectory: ObjCBool = false
            let gitMarker = URL(fileURLWithPath: candidate)
                .appendingPathComponent(".git")
                .path
            return FileManager.default.fileExists(
                atPath: gitMarker,
                isDirectory: &isGitMarkerDirectory
            )
        }

        return gitDirectories.first
    }

    var hasStaged: Bool { entries.contains { $0.staged != .unchanged } }
    var hasLocalChanges: Bool {
        entries.contains {
            $0.staged != .unchanged || $0.unstaged != .unchanged
        }
    }
    /// 未暂存组：unstaged 维度有变更（含冲突文件，冲突显示在 unstaged 维度）
    var unstagedEntries: [FileEntry] {
        entries.filter {
            $0.unstaged != .unchanged
                && $0.unstaged != .untracked
                && $0.unstaged != .ignored
        }
    }
    var untrackedEntries: [FileEntry] {
        entries.filter { $0.unstaged == .untracked }
    }
    /// Rebased-style pull preserves the complete local workspace, including
    /// files that Git has not started tracking yet.
    var hasTrackedChanges: Bool {
        entries.contains {
            $0.staged != .unchanged
                || ($0.unstaged != .unchanged
                    && $0.unstaged != .untracked
                    && $0.unstaged != .ignored)
        }
    }
    /// Local-only files are also preserved by the pull workflow. This keeps
    /// the operation entirely automatic instead of waiting for the engine to
    /// discover a remote path collision after the pull has already started.
    var hasUntrackedOrIgnoredFiles: Bool {
        entries.contains { $0.unstaged == .untracked || $0.unstaged == .ignored }
    }
    /// 已暂存组：staged 维度有变更
    var stagedEntries: [FileEntry] { entries.filter { $0.staged != .unchanged } }
    var selectedEntry: FileEntry? {
        guard let selection else { return nil }
        return entries.first { $0.path == selection }
    }
    var selectedEntryIsConflicted: Bool {
        guard let selectedEntry else { return false }
        return selectedEntry.staged == .conflicted || selectedEntry.unstaged == .conflicted
    }
    var selectedLocalChangePath: String? {
        // `restore --source HEAD --staged --worktree` is only valid when the
        // selected path exists in HEAD. Until the asynchronous staging model
        // has supplied that fact, keep the destructive main-menu action off.
        guard !isShelfWorkspaceTabActive, stagingModel != nil else { return nil }
        return arborSelectedRevertPath(
            entries: entries,
            candidates: [commitPreviewPath, selection, fileSelection],
            headPresentByPath: stagingPresenceByPath.mapValues(\.head)
        )
    }
    var selectedWorkspacePath: String? {
        guard !isShelfWorkspaceTabActive else { return nil }
        return [commitPreviewPath, selection, fileSelection]
            .compactMap { $0 }
            .first { !$0.isEmpty }
    }
    var selectedFileActionContext: ArborSelectedGitFileContext? {
        guard let selectedPath = selectedWorkspacePath,
              let normalizedPath = normalizedRepositoryRelativePath(selectedPath),
              let primaryRootPath = repo?.workdir(),
              !primaryRootPath.isEmpty else { return nil }

        let isDirectory: Bool
        if selectedPath == fileSelection, let projectPath {
            var directory = ObjCBool(false)
            _ = FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: projectPath)
                    .appendingPathComponent(normalizedPath)
                    .path,
                isDirectory: &directory
            )
            isDirectory = directory.boolValue
        } else {
            isDirectory = false
        }

        let roots: [GitRootInfo]
        if !multiRoots.isEmpty {
            roots = multiRoots
        } else {
            roots = [GitRootInfo(
                path: primaryRootPath,
                displayName: URL(fileURLWithPath: primaryRootPath).lastPathComponent,
                relativePath: ".",
                isSubmodule: false,
                headBranch: currentBranchName,
                headId: headId,
                dirty: hasLocalChanges,
                operation: operationState?.kind
            )]
        }
        guard let target = fileReferenceComparisonTarget(
            path: normalizedPath,
            primaryRootPath: primaryRootPath,
            roots: roots
        ) else { return nil }

        let matchingEntries = entries.filter { $0.path == normalizedPath }
        let statuses = matchingEntries.flatMap { [$0.staged, $0.unstaged] }
        let hasConflict = statuses.contains(.conflicted)
        let hasIgnored = statuses.contains(.ignored)
        let hasChange = statuses.contains {
            $0 != .unchanged && $0 != .ignored
        }
        let hasUntracked = matchingEntries.contains { $0.unstaged == .untracked }
        let isPrimaryRoot = canonicalExternalLogPath(target.rootPath)
            == canonicalExternalLogPath(primaryRootPath)

        return ArborSelectedGitFileContext(
            path: normalizedPath,
            rootRelativePath: target.relativePath,
            isDirectory: isDirectory,
            owningRootPath: target.rootPath,
            isPrimaryRoot: isPrimaryRoot,
            canCheckin: isPrimaryRoot && !isDirectory && hasChange && !hasConflict,
            canAdd: !isDirectory && hasUntracked && !hasIgnored && !hasConflict,
            canAnnotate: isPrimaryRoot
                && !isDirectory
                && projectFileTreeCanAnnotate(path: normalizedPath, entries: entries),
            canCompareWithHead: !isDirectory
                && projectFileTreeCanCompareWithSameVersion(
                    path: normalizedPath,
                    entries: entries
                ),
            canCompareWithSelectedRevision: !isDirectory
                && projectFileTreeCanCompareWithSelectedRevision(
                    path: normalizedPath,
                    isDirectory: false,
                    entries: entries
                )
        )
    }
    var selectedCommit: CommitInfo? {
        guard let logSelection else { return nil }
        let visibleEntries = logViewMode == .command ? logCommandEntries : logEntries
        return visibleEntries.first {
            let identity = logCommitIdentity($0)
            return identity == logSelection
                || identity.hasPrefix(logSelection)
                || logSelection.hasPrefix(identity)
        }
            ?? (logDetailCommit.map {
                let identity = logCommitIdentity($0)
                return identity == logSelection
                    || identity.hasPrefix(logSelection)
                    || logSelection.hasPrefix(identity) ? $0 : nil
            } ?? nil)
    }
    var selectedTreeChange: TreeChange? {
        guard let compareSelection else { return nil }
        return treeChanges.first { $0.path == compareSelection }
    }
    var selectedTreeChanges: [TreeChange] {
        orderedCompareSelection(changes: treeChanges, selectedPaths: compareSelectedPaths)
    }
    var selectedBranchComparisonCommit: CommitInfo? {
        let commits = branchCompareSelectionSide == .first
            ? branchCompareFirstEntries
            : branchCompareSecondEntries
        return commits.first { $0.id == branchCompareSelectionID }
    }
    var selectedReflogEntry: ReflogEntry? {
        guard let reflogSelection else { return nil }
        return reflogEntries.first { reflogEntryIdentifier($0) == reflogSelection }
    }
    var selectedReflogEntries: [ReflogEntry] {
        orderedReflogSelection(entries: reflogEntries, selectedIDs: reflogSelectedIDs)
    }
    var selectedReflogCommits: [CommitInfo] {
        if !reflogDetailCommits.isEmpty {
            return reflogDetailCommits
        }
        var seen = Set<String>()
        return selectedReflogEntries.compactMap { entry in
            guard let commit = logEntries.first(where: {
                $0.id == entry.newId || $0.id.hasPrefix(entry.newId) || entry.newId.hasPrefix($0.id)
            }), seen.insert(commit.id).inserted else { return nil }
            return commit
        }
    }
    var selectedReflogCommit: CommitInfo? {
        selectedReflogCommits.first
    }

    func reflogCommit(for entry: ReflogEntry) -> CommitInfo? {
        let matches: (CommitInfo) -> Bool = { commit in
            commit.id == entry.newId
                || commit.id.hasPrefix(entry.newId)
                || entry.newId.hasPrefix(commit.id)
        }
        return reflogDetailCommits.first(where: matches)
            ?? reflogDetailCommit.flatMap { matches($0) ? $0 : nil }
            ?? logEntries.first(where: matches)
    }

    var hostingRepositories: [HostingRepository] {
        hostingRepositories(for: remotes)
    }

    var hostingRepository: HostingRepository? {
        hostingRepositories.first
    }

    var effectiveProtectedBranchPatterns: [String] {
        effectiveProtectedBranchPatterns(forRootPath: nil)
    }

    func effectiveProtectedBranchPatterns(forRootPath rootPath: String?) -> [String] {
        let cachedPatterns = GitProtectedBranchRules.remotePatterns(
            forRootPath: rootPath,
            primaryPatterns: remoteProtectedBranchPatterns,
            patternsByRoot: remoteProtectedBranchPatternsByRoot
        )
        let remotePatterns: [String] = {
            guard let rootPath,
                  !remoteProtectedBranchPatternsByRoot.keys.contains(
                    canonicalExternalLogPath(rootPath)
                  ) else {
                return cachedPatterns
            }
            let key = canonicalExternalLogPath(rootPath)
            return GitProtectedBranchRules.loadRemotePatterns(for: key)
        }()
        return GitProtectedBranchRules.combinedPatterns(
            localRawValue: protectedBranchPatterns,
            remotePatterns: remotePatterns,
            synchronize: protectedBranchSynchronize
        )
    }

    var mergeDeleteOnMergeOption: GitDeleteOnMergeOption {
        GitDeleteOnMergeOption(rawValue: mergeDeleteOnMergeRaw)
            ?? GitDeleteOnMergeOption.defaultOption
    }

    var currentSyncStatus: SyncStatus? {
        syncStatuses.first(where: { $0.branch == currentBranchName })
    }

    var currentBranchHasUnfetchedIncoming: Bool {
        hasUnfetchedIncomingBranch(
            rootPath: repo?.workdir() ?? projectPath,
            branch: currentBranchName,
            in: autoFetchIncomingBranches
        )
    }

    private var multiRootMergePresentedView: some View {
        mainView
            .modifier(
                MultiRootMergePresentationModifier(
                    isPresented: $showMultiRootMergeDialog,
                    selectedRootPaths: $multiRootMergeSelectedRootPaths,
                    strategy: Binding(
                        get: { MergeStrategyChoice(rawValue: mergeStrategyRaw) ?? .automatic },
                        set: { mergeStrategyRaw = $0.rawValue }
                    ),
                    commitMessage: $mergeCommitMessage,
                    useCustomCommitMessage: $mergeUseCustomCommitMessage,
                    noCommit: $mergeNoCommit,
                    noVerify: $mergeNoVerify,
                    allowUnrelatedHistories: $mergeAllowUnrelatedHistories,
                    rollbackContext: $multiRootMergeRollbackContext,
                    branchName: multiRootMergeBranchName,
                    snapshots: multiRootBranchSnapshots,
                    mergedBranchesByRoot: multiRootMergeMergedBranchesByRoot,
                    onMerge: startMultiRootMergeFromDialog,
                    onCancel: dismissMultiRootMergeDialog,
                    onRollback: { targets in rollbackMultiRootMerge(targets) },
                    onKeep: keepMultiRootMergePartial,
                    onDone: dismissMultiRootMergeRollback
                )
            )
            .onReceive(
                NotificationCenter.default.publisher(for: .arborDeleteMergedBranch),
                perform: handleMergeDeleteNotification
            )
    }

    private var repositoryIndexMonitoredView: some View {
        multiRootMergePresentedView
        .background {
            RepositoryIndexRevisionMonitor(
                repo: repo,
                repositoryID: "\(repositoryIndexMonitorID)|\(autoFetchRootPaths.joined(separator: "|"))",
                rootPaths: autoFetchRootPaths,
                onChanged: handleRepositoryChange
            )
        }
    }

    private var workspaceLifecycleView: some View {
        repositoryIndexMonitoredView
        .background {
            let expectedGitDir = repo?.gitDir()
            let expectedMonitorID = autoFetchMonitorID
            GitAutoFetchMonitor(
                rootPaths: autoFetchRootPaths,
                repositoryID: autoFetchMonitorID,
                broker: credentialAuth.broker,
                strategy: feedbackCenter.isRunning ? .none : incomingCheckStrategy,
                tagMode: fetchTagsMode,
                onUpdated: { updatedRefs in
                    guard !updatedRefs.isEmpty,
                          self.repo?.gitDir() == expectedGitDir,
                          self.autoFetchMonitorID == expectedMonitorID else { return }
                    autoFetchIncomingFingerprint = nil
                    autoFetchFailureFingerprint = nil
                    DiagnosticsLogger.shared.record(
                        operation: "auto-fetch",
                        repositoryPath: projectPath,
                        code: "updated-\(updatedRefs.count)-refs"
                    )
                    loadRepoData(includeComparisons: false)
                    loadMultiRoots()
                    refreshAll(showFeedback: false)
                },
                onUnfetched: { snapshot in
                    guard self.repo?.gitDir() == expectedGitDir,
                          self.autoFetchMonitorID == expectedMonitorID else { return }
                    autoFetchIncomingBranches = applyingAutoFetchIncomingSnapshot(
                        snapshot,
                        to: autoFetchIncomingBranches
                    )
                    guard !autoFetchIncomingBranches.isEmpty else {
                        feedbackCenter.expire(notificationID: "\(autoFetchNotificationIDPrefix).incoming")
                        autoFetchIncomingFingerprint = nil
                        return
                    }
                    let displayValues = groupedAutoFetchIncomingBranches(
                        Array(autoFetchIncomingBranches)
                    ).map(\.displayValue)
                    let fingerprint = autoFetchNotificationFingerprint(displayValues)
                    guard fingerprint != autoFetchIncomingFingerprint else { return }
                    autoFetchIncomingFingerprint = fingerprint
                    feedbackCenter.warning(
                        "Incoming changes available",
                        detail: displayValues.joined(separator: "\n"),
                        nextStep: "Run Fetch to update the local remote-tracking refs.",
                        additionalActions: [
                            self.autoFetchRecoveryFeedbackAction(
                                .fetchAll,
                                rootPaths: self.autoFetchRootPaths
                            )
                        ],
                        notificationID: "\(autoFetchNotificationIDPrefix).incoming",
                        localized: false
                    )
                },
                onFailure: { failures in
                    guard self.repo?.gitDir() == expectedGitDir,
                          self.autoFetchMonitorID == expectedMonitorID else { return }
                    guard !failures.isEmpty else {
                        feedbackCenter.expire(notificationID: "\(autoFetchNotificationIDPrefix).error")
                        autoFetchFailureFingerprint = nil
                        return
                    }
                    let fingerprint = autoFetchNotificationFingerprint(failures)
                    guard fingerprint != autoFetchFailureFingerprint else { return }
                    autoFetchFailureFingerprint = fingerprint
                    let retryAction = self.autoFetchRecoveryFeedbackAction(
                        .retryCheck,
                        rootPaths: self.autoFetchRootPaths
                    )
                    let fetchAction = self.autoFetchRecoveryFeedbackAction(
                        .fetchAll,
                        rootPaths: self.autoFetchRootPaths
                    )
                    feedbackCenter.warning(
                        incomingCheckStrategy == .fetch
                            ? "Auto-fetch failed"
                            : "Incoming changes check failed",
                        detail: failures.joined(separator: "\n"),
                        nextStep: "Check the remote and authentication settings, then retry.",
                        additionalActions: incomingCheckStrategy == .fetch
                            ? [retryAction]
                            : [retryAction, fetchAction],
                        notificationID: "\(autoFetchNotificationIDPrefix).error",
                        localized: false
                    )
                }
            )
        }
        .background {
            GitShelfLifecycleMonitor(
                rootPaths: autoFetchRootPaths,
                repositoryID: shelfLifecycleMonitorID
            )
        }
        .onChange(of: autoFetchMonitorID) { _, _ in
            autoFetchFailureFingerprint = nil
            autoFetchIncomingFingerprint = nil
            autoFetchIncomingBranches = []
        }
        .onChange(of: incomingOutgoingInfoEnabled) { _, enabled in
            guard !enabled else { return }
            feedbackCenter.expire(notificationID: "\(autoFetchNotificationIDPrefix).incoming")
            feedbackCenter.expire(notificationID: "\(autoFetchNotificationIDPrefix).error")
            autoFetchFailureFingerprint = nil
            autoFetchIncomingFingerprint = nil
            autoFetchIncomingBranches = []
        }
        .onAppear {
            setExternalConversionEnabled(enabled: gitExternalConversionEnabled)
            applyExternalConversionSetting()
        }
        .onChange(of: gitExternalConversionEnabled) { _, enabled in
            setExternalConversionEnabled(enabled: enabled)
            applyExternalConversionSetting()
            refreshAll(showFeedback: false)
        }
        .focusedValue(\.arborRepositoryIsShallow, projectRepo == nil ? nil : isShallowRepository)
        .focusedValue(\.arborRepositoryAvailable, repo != nil)
        .focusedValue(\.arborVCSActionContext, vcsActionContext)
        .focusedValue(
            \.arborVCSOperationContext,
            operationState.flatMap { state in
                repo?.workdir().map {
                    ArborVCSOperationContext(
                        rootPath: $0,
                        kind: state.kind,
                        hasConflicts: !state.conflictedFiles.isEmpty
                    )
                }
            }
        )
        .background {
            if externalLogWindow {
                ExternalLogWindowLifecycleView(onClosed: disposeExternalLogSession)
            }
        }
        .onDisappear {
            vcsQuickActionsPanel.close()
            if externalLogWindow {
                disposeExternalLogSession()
            }
        }
    }

    var body: some View {
        workspaceLifecycleView
        // 后半段修饰符链（拆分以降低单表达式类型检查复杂度）
        .overlay(alignment: .trailing) {
            conflictResolverOverlays
        }
        .sheet(isPresented: $showRevisionBrowser) {
            if let repo = logRepository, let commit = revisionBrowserCommit {
                RevisionBrowserView(
                    repo: repo,
                    revision: commit.id,
                    commitTitle: commit.summary,
                    initialPath: revisionBrowserPath
                )
            }
        }
        .sheet(item: $fileReferenceComparisonRequest) { request in
            FileReferenceComparisonView(
                repo: request.repo,
                path: request.path,
                isDirectory: request.isDirectory,
                mode: request.mode,
                onClose: { fileReferenceComparisonRequest = nil }
            )
        }
        .sheet(item: $currentRevisionRequest) { request in
            CurrentRevisionView(
                path: request.path,
                commit: request.commit,
                onClose: { currentRevisionRequest = nil }
            )
        }
        .sheet(isPresented: $showSubmoduleLog) {
            SubmoduleLogView(
                path: submoduleLogPath,
                commits: submoduleLogEntries,
                error: submoduleLogError,
                onClose: { showSubmoduleLog = false }
            )
        }
        .sheet(item: $branchDeleteRecovery) { context in
            BranchDeleteRecoveryView(
                preview: context.preview,
                rootPath: context.rootPath,
                trackedRemoteBranch: context.trackedRemoteBranch,
                onRestore: {
                    restoreDeletedBranch(context)
                },
                onDeleteTrackedRemote: {
                    deleteTrackedRemoteBranch(context)
                },
                onDone: {
                    branchDeleteRecovery = nil
                }
            )
        }
        .sheet(item: $multiRootBranchDeleteRecovery) { context in
            RebasedMultiRootBranchDeleteRecoveryView(
                branchName: context.branchName,
                contexts: context.contexts,
                onRestore: {
                    restoreDeletedBranches(context.contexts)
                },
                onDeleteTrackedRemote: { remoteBranch in
                    deleteTrackedRemoteBranch(remoteBranch, contexts: context.contexts)
                },
                onDone: {
                    multiRootBranchDeleteRecovery = nil
                }
            )
        }
        .sheet(item: $tagDeleteRecovery) { context in
            TagDeleteRecoveryView(
                tag: context.tag,
                rootPath: context.rootPath,
                remotes: context.remotes,
                onRestore: {
                    restoreDeletedTag(context)
                },
                onDeleteRemote: {
                    deleteRemoteTagFromRecovery(context)
                },
                onDone: {
                    tagDeleteRecovery = nil
                }
            )
        }
        .sheet(isPresented: $showRemoteTagsDialog) {
            if let repo {
                RemoteTagsDialogView(
                    repo: repo,
                    broker: credentialAuth.broker,
                    remotes: remotes,
                    onDeleted: { remote, tag in
                        feedbackCenter.success("Remote tag deleted", detail: "\(remote)/\(tag)")
                        refreshAll(showFeedback: false)
                    },
                    onDone: {
                        showRemoteTagsDialog = false
                    }
                )
            } else {
                ProgressView()
                    .frame(width: 640, height: 500)
            }
        }
        .sheet(isPresented: $showMultiRootRemoteTagsDialog) {
            MultiRootRemoteTagsDialogView(
                roots: multiRoots,
                broker: credentialAuth.broker,
                onResult: { successes, failures, cancelled in
                    loadMultiRoots()
                    refreshAll(showFeedback: false)
                    if cancelled {
                        feedbackCenter.warning(
                            "Remote tag deletion canceled",
                            detail: "Deleted \(successes.count) before cancellation; remaining selections were kept."
                        )
                    } else if failures.isEmpty {
                        feedbackCenter.success(
                            "Remote tags deleted",
                            detail: successes.joined(separator: " | ")
                        )
                    } else {
                        feedbackCenter.warning(
                            "Remote tag deletion partially completed",
                            detail: "Deleted \(successes.count); failed \(failures.count)",
                            actionTitle: "Open Remote Tags",
                            action: { showMultiRootRemoteTagsDialog = true }
                        )
                    }
                },
                onDone: {
                    showMultiRootRemoteTagsDialog = false
                }
            )
        }
        .sheet(item: $multiRootTagDeleteRecovery) { context in
            RebasedMultiRootTagDeleteRecoveryView(
                tagName: context.tagName,
                contexts: context.contexts,
                onRestore: {
                    restoreDeletedTags(context.contexts)
                },
                onDeleteRemote: {
                    deleteRemoteTagsFromRecovery(context.contexts)
                },
                onDone: {
                    multiRootTagDeleteRecovery = nil
                }
            )
        }
        .sheet(isPresented: $showFindMergedBranchesDialog, onDismiss: dismissFindMergedBranches) {
            FindMergedBranchesDialogView(
                roots: findMergedBranchesRoots,
                projectName: projectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "",
                targetBranch: $findMergedTargetBranch,
                prefix: $findMergedPrefix,
                isRunning: findMergedRunning,
                hasCalculated: findMergedHasCalculated,
                summary: findMergedSummary,
                onCalculate: calculateFindMergedBranches,
                onOpenReport: openFindMergedReport,
                onCopy: copyFindMergedBranches,
                onDone: dismissFindMergedBranches,
                onCancel: cancelFindMergedBranches
            )
        }
        .sheet(isPresented: $showFindMergedReport) {
            FindMergedReportEditorView(report: findMergedReportText)
        }
        .sheet(isPresented: $showMultiRootChanges) {
            MultiRootChangesBrowser(
                groups: multiRootChangeGroups,
                isLoading: multiRootChangesLoading,
                error: multiRootChangesError,
                onRefresh: loadMultiRootChanges,
                onStage: stageMultiRootPath,
                onUnstage: unstageMultiRootPath,
                onStageSelected: stageMultiRootPaths,
                onUnstageSelected: unstageMultiRootPaths,
                onCommitSelected: { selectedChanges in
                    showMultiRootChanges = false
                    DispatchQueue.main.async {
                        openMultiRootCommitDialog(selectedChanges)
                    }
                },
                onStageAll: stageAllMultiRootPath,
                onUnstageAll: unstageAllMultiRootPath
            )
        }
        .sheet(isPresented: $showMultiRootCommitDialog) {
            MultiRootCommitDialogView(
                groups: multiRootChangeGroups.map(MultiRootCommitGroup.init(changeGroup:)),
                isLoading: multiRootChangesLoading,
                error: multiRootChangesError,
                recentMessages: multiRootCommitRecentMessages,
                onTemplate: loadMultiRootCommitTemplate,
                onBeforeCommitSettings: { showBeforeCommitSettings = true },
                onIdentitySettings: { showIdentitySettings = true },
                message: $multiRootCommitMessage,
                amendMode: $multiRootCommitAmendMode,
                skipHooks: $multiRootCommitSkipHooks,
                authorName: $multiRootCommitAuthorName,
                authorEmail: $multiRootCommitAuthorEmail,
                committerName: $multiRootCommitCommitterName,
                committerEmail: $multiRootCommitCommitterEmail,
                signOff: $multiRootCommitSignOff,
                coAuthors: $multiRootCommitCoAuthors,
                selectedChanges: multiRootCommitSelectedPaths,
                onCommit: commitMultiRootSelectedRoots,
                onCommitAndPush: commitAndPushMultiRootSelectedRoots,
                onCommitSelectedChanges: commitMultiRootSelectedChanges,
                onCommitAndPushSelectedChanges: commitAndPushMultiRootSelectedChanges,
                onCancel: { showMultiRootCommitDialog = false }
            )
        }
        .onChange(of: showMergeRevisionsDialog) { _, isPresented in
            if !isPresented { mergeInitialPath = nil }
        }
        .alert("打开另一个项目？", isPresented: $showProjectSwitchAlert) {
            Button("替换当前窗口") { replacePendingProject() }
            Button("新窗口") {
                openWindow(id: "project", value: pendingProjectPath)
                pendingProjectPath = nil
            }
            Button("取消", role: .cancel) { pendingProjectPath = nil }
        } message: {
            Text("当前窗口正在显示 \(projectRepo?.displayName() ?? "一个项目")。选择如何打开新项目。")
        }
        .alert("Create .gitignore?", isPresented: Binding(
            get: { pendingIgnoreFileCreation != nil },
            set: { isPresented in
                if !isPresented { pendingIgnoreFileCreation = nil }
            }
        )) {
            Button("Create") {
                confirmPendingIgnoreFileCreation()
            }
            Button("Cancel", role: .cancel) {
                pendingIgnoreFileCreation = nil
            }
        } message: {
            if let request = pendingIgnoreFileCreation {
                Text(
                    "No suitable .gitignore exists in the repository root. "
                        + "Create one and ignore \(request.paths.count) selected "
                        + (request.paths.count == 1 ? "path" : "paths") + "?"
                )
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleProjectDrop)
        .onAppear {
            handleContentViewAppearAndLoadRoots()
        }
        .onChange(of: branchCleanupWindow.action) { _, action in
            handleBranchCleanupAction(action)
        }
        .sheet(isPresented: $credentialAuth.isPresented) {
            CredentialDialogView(controller: credentialAuth)
        }
        .sheet(item: $multiRootRemoteConfigAggregateContext) { context in
            MultiRootRemoteConfigDialogView(
                roots: context.roots,
                onAdd: { rootPath, name, url, fetchAfterAdd, completion in
                    addRemoteInRoot(
                        rootPath: rootPath,
                        name: name,
                        url: url,
                        fetchAfterAdd: fetchAfterAdd,
                        completion: completion
                    )
                },
                onEdit: { rootPath, oldName, name, url, pushURL, fetchRefspec, pushRefspec, fetchAfterEdit, completion in
                    updateRemoteInRoot(
                        rootPath: rootPath,
                        oldName: oldName,
                        name: name,
                        url: url,
                        pushURL: pushURL,
                        fetchRefspec: fetchRefspec,
                        pushRefspec: pushRefspec,
                        fetchAfterUpdate: fetchAfterEdit,
                        completion: completion
                    )
                },
                onRemove: { rootPath, name in
                    removeRemoteInRoot(rootPath: rootPath, name: name)
                },
                onRefresh: loadMultiRootRemoteConfigAggregate,
                onCancel: {
                    multiRootRemoteConfigAggregateContext = nil
                }
            )
        }
        .sheet(isPresented: $showRemoteConfigDialog) {
            remoteConfigSheet
        }
        .sheet(isPresented: $showUpstreamDialog) {
            SetUpstreamDialogView(
                localBranch: upstreamLocalBranch,
                remoteBranches: remoteBranches,
                currentUpstream: syncStatuses.first {
                    $0.branch == upstreamLocalBranch && $0.trackingExists
                }?.upstream,
                onCancel: { showUpstreamDialog = false },
                onSave: saveUpstreamFromDialog
            )
        }
        .sheet(item: $multiRootUpstreamContext) { context in
            SetUpstreamDialogView(
                localBranch: context.localBranch,
                remoteBranches: context.remoteBranches,
                currentUpstream: context.currentUpstream,
                repositoryName: context.displayName,
                onCancel: { multiRootUpstreamContext = nil },
                onSave: { upstream in
                    multiRootUpstreamContext = nil
                    setBranchUpstreamInRoot(
                        rootPath: context.rootPath,
                        branch: context.localBranch,
                        upstream: upstream,
                        requireCurrentBranch: true
                    )
                }
            )
        }
        .sheet(isPresented: $showRebaseTodoEditor) {
            rebaseTodoSheet
        }
        .sheet(isPresented: $showRawRebaseTodoEditor) {
            rebaseRawTodoSheet
        }
        .sheet(isPresented: $showRawRebaseMessageEditor) {
            RawRebaseMessageEditorView(
                message: $rawRebaseMessageText,
                onSave: submitRawRebaseMessage,
                onCancel: cancelRawRebaseMessage
            )
        }
        .sheet(isPresented: $showLogRewordDialog) {
            if let commit = logRewordCommit {
                LogRewordDialogView(
                    commit: commit,
                    message: $logRewordMessage,
                    onCancel: {
                        showLogRewordDialog = false
                        logRewordCommit = nil
                        logRewordUsesRootRebase = false
                    },
                    onConfirm: submitLogHeadReword
                )
            }
        }
        .sheet(isPresented: $showLogSquashDialog) {
            LogSquashDialogView(
                commitSummaries: logSquashSummaries,
                message: $logSquashMessage,
                onCancel: {
                    showLogSquashDialog = false
                    logSquashIndexes = []
                    logSquashSummaries = []
                },
                onConfirm: submitLogSquash
            )
        }
        .alert("Rewrite Initial Commit?", isPresented: $showInitialCommitRewordAlert) {
            Button("Continue") {
                confirmInitialCommitReword()
            }
            Button("Cancel", role: .cancel) {
                pendingInitialCommitReword = nil
                logRewordCommit = nil
                logRewordUsesRootRebase = false
            }
        } message: {
            Text("The initial commit has no parent. Continue with this history rewrite?")
        }
        .alert("Rewrite Initial Commit?", isPresented: $showInitialCommitRewriteAlert) {
            Button("Continue") {
                confirmInitialCommitRewrite()
            }
            Button("Cancel", role: .cancel) {
                pendingInitialCommitRewrite = nil
            }
        } message: {
            Text("The selected history includes the initial commit. Continue with this history rewrite?")
        }
        .onReceive(NotificationCenter.default.publisher(for: .arborOpenProjectPanel)) { _ in
            showOpenPanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .arborInitProjectPanel)) { _ in
            showInitializePanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .arborCloneProjectDialog)) { _ in
            showCloneDialog = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .arborOpenCommitDetail)) { notification in
            guard let id = notification.object as? String else { return }
            toolWindowMode = .log
            toolWindowExpanded = true
            projectPanelExpanded = false
            logViewMode = .graph
            // A commit-detail notification can originate from the Commit
            // workspace (for example, Show History on a changed file). The
            // Log editor owns this context after the hand-off; leaving the
            // old staging/file selection alive makes mainContext render a
            // diff viewer over the Log workspace and looks like the history
            // page disappeared.
            selection = nil
            fileSelection = nil
            selectionModePath = nil
            commitPreviewPath = nil
            commitPreviewVisible = false
            commitPreviewThreeVersions = false
            logSelection = id
            logSelectedIDs = [id]
            loadCommitDetailsIfNeeded(id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .arborOpenMultiRootConflictResolver)) { notification in
            openMultiRootConflictResolver(
                preferredRootPath: notification.userInfo?["rootPath"] as? String,
                preferredPath: notification.userInfo?["path"] as? String
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .arborRollbackMerge)) { notification in
            guard let request = notification.object as? MergeRollbackRequest else { return }
            rollbackMerge(request)
        }
        .onReceive(NotificationCenter.default.publisher(for: .arborVCSAction)) { notification in
            handleArborVCSActionNotification(notification)
        }
        .sheet(isPresented: $showSearchEverywhere) {
            SearchEverywhereView(
                roots: searchEverywhereGitRoots,
                query: $searchEverywhereQuery,
                onSelect: { item in
                    showSearchEverywhere = false
                    searchEverywhereQuery = ""
                    switch item.kind {
                    case .localBranch, .remoteBranch, .tag:
                        navigateLogToBranch(rootPath: item.rootPath, branch: item.revision)
                    case .commitByHash, .commitByMessage:
                        navigateLogToRevision(rootPath: item.rootPath, revision: item.revision)
                    }
                },
                onCancel: {
                    showSearchEverywhere = false
                    searchEverywhereQuery = ""
                }
            )
        }
    }

    func presentVCSQuickActionsPanel() {
        let hasUnstagedChanges = entries.contains {
            $0.unstaged != .unchanged
                && $0.unstaged != .ignored
                && $0.unstaged != .conflicted
        }
        vcsQuickActionsPanel.present(
            items: vcsQuickActionItems(
                isShallowRepository: isShallowRepository,
                hasCurrentBranch: hasCurrentBranch,
                hasConflicts: hasConflicts,
                hasUnstagedTrackedChanges: vcsActionContext.hasUnstagedTrackedChanges,
                hasUnstagedChanges: hasUnstagedChanges,
                hasRepository: repo != nil,
                hasCommitChanges: vcsActionContext.hasLocalChanges,
                hasFetchInProgress: vcsActionContext.hasFetchInProgress
            ),
            onAction: { action in
                NotificationCenter.default.post(
                    name: .arborVCSAction,
                    object: action.rawValue
                )
            }
        )
    }

    private var hasCurrentBranch: Bool {
        branches.contains { $0.isCurrent }
    }

    private var hasConflicts: Bool {
        entries.contains {
            $0.staged == .conflicted || $0.unstaged == .conflicted
        }
    }

    var vcsActionContext: ArborVCSActionContext {
        let hasLocalChanges = entries.contains {
            ($0.staged != .unchanged && $0.staged != .ignored)
                || ($0.unstaged != .unchanged && $0.unstaged != .ignored)
        }
        let hasUnstagedTrackedChanges = entries.contains {
            $0.unstaged != .unchanged
                && $0.unstaged != .untracked
                && $0.unstaged != .ignored
                && $0.unstaged != .conflicted
        }
        let hasStagedChanges = entries.contains {
            $0.staged != .unchanged && $0.staged != .ignored
        }
        let hasProjectCommitChanges = multiRootChangeGroups.contains { group in
            group.entries.contains {
                $0.staged != .unchanged
                    && $0.staged != .ignored
                    && $0.staged != .conflicted
            }
        }
        let allRepositoriesHaveHeadCommit: Bool
        if multiRoots.isEmpty {
            allRepositoriesHaveHeadCommit = headId != nil
        } else {
            allRepositoriesHaveHeadCommit = multiRoots.allSatisfy { $0.headId != nil }
        }
        return ArborVCSActionContext(
            hasRepository: repo != nil,
            allRepositoriesHaveHeadCommit: allRepositoriesHaveHeadCommit,
            hasCurrentBranch: hasCurrentBranch,
            hasLocalChanges: hasLocalChanges,
            hasUnstagedTrackedChanges: hasUnstagedTrackedChanges,
            hasStagedChanges: hasStagedChanges,
            hasConflicts: hasConflicts,
            isShallowRepository: isShallowRepository,
            hasRemotes: !remotes.isEmpty,
            hasFetchInProgress: isArborFetchInProgress(
                isRunning: feedbackCenter.isRunning,
                operationName: feedbackCenter.operationName
            ),
            hasBackgroundVCSOperation: isArborBackgroundVCSOperationInProgress(
                feedbackIsRunning: feedbackCenter.isRunning,
                multiRootIsRunning: multiRootRunning || updateProjectDiscoveryRunning
            ),
            projectPath: projectPath,
            hasMultipleGitRoots: multiRoots.count > 1,
            hasProjectCommitChanges: hasProjectCommitChanges || hasStagedChanges,
            hasTrackedUpstream: currentSyncStatus.map {
                $0.trackingExists && !$0.upstream.isEmpty
            } ?? false,
            hasSingleGitRoot: multiRoots.count == 1,
            hasRepositoryOperationInProgress: operationState != nil
                || multiRoots.contains { $0.operation != nil },
            hasMergeInProgress: isArborMergeInProgress(
                currentOperation: operationState?.kind,
                roots: multiRoots
            ),
            hasRebaseInProgress: isArborRebaseInProgress(
                currentOperation: operationState?.kind,
                roots: multiRoots,
                hasMultiRootSession: multiRootRebaseSession != nil
            ),
            hasNormalOrDetachedRepository: hasArborNormalOrDetachedRepository(
                currentOperation: operationState?.kind,
                currentRootPath: repo?.workdir(),
                roots: multiRoots
            ),
            selectedLocalChangePath: selectedLocalChangePath,
            selectedResolvedConflictPath: selectedWorkspacePath.flatMap {
                resolvedConflictPaths.contains($0) ? $0 : nil
            },
            selectedFileAction: selectedFileActionContext
        )
    }

    var resetHeadRootOptions: [GitRootInfo] {
        if !multiRoots.isEmpty {
            return multiRoots.filter { $0.operation == nil }
        }
        guard let rootPath = repo?.workdir(), !rootPath.isEmpty else { return [] }
        return [GitRootInfo(
            path: rootPath,
            displayName: URL(fileURLWithPath: rootPath).lastPathComponent,
            relativePath: ".",
            isSubmodule: false,
            headBranch: branches.first(where: { $0.isCurrent })?.name,
            headId: nil,
            dirty: entries.contains {
                $0.staged != .unchanged || $0.unstaged != .unchanged
            },
            operation: operationState?.kind
        )]
    }

    var stashRootOptions: [GitRootInfo] {
        if !multiRoots.isEmpty {
            return multiRoots
        }
        return resetHeadRootOptions
    }

    private func applyExternalConversionSetting() {
        _ = try? repo?.setExternalConversionEnabled(enabled: gitExternalConversionEnabled)
    }

    /// 主内容（VStack 及其前置修饰符）。
    @ViewBuilder
    private var mainView: some View {
        if externalLogWindow {
            logWorkspace
                .frame(minWidth: 980, minHeight: 540)
                .background(Design.Colors.canvas)
        } else {
            fullMainView
        }
    }

    private var fullMainView: some View {
        VStack(spacing: 0) {
            RebasedTopBar(
                // Keep the requested/recovered project identity visible while
                // the repository is opening. Showing the generic Arbor shell
                // during that interval makes a valid project launch look like
                // the welcome page and differs from rebased's project window.
                projectName: projectRepo?.displayName()
                    ?? projectPath.map { URL(fileURLWithPath: $0).lastPathComponent }
                    ?? "Arbor",
                projectPath: projectPath,
                currentBranch: currentBranchName,
                hasRepository: repo != nil,
                isLoading: isLoading || feedbackCenter.isRunning,
                onOpenProject: showOpenPanel,
                onRefresh: refreshAll,
                onUpdate: { doPull(nil, rebase: false) },
                onCommit: {
                    toolWindowMode = .commit
                    toolWindowExpanded = true
                },
                onPush: { beginPushDialog() },
                onFetch: { doFetch(nil) },
                isShallowRepository: isShallowRepository,
                hasCurrentBranch: branches.contains { $0.isCurrent },
                hasConflicts: entries.contains {
                    $0.staged == .conflicted || $0.unstaged == .conflicted
                },
                onQuickAction: { action in
                    NotificationCenter.default.post(
                        name: .arborVCSAction,
                        object: action.rawValue
                    )
                },
                onSearch: {
                    searchEverywhereQuery = ""
                    showSearchEverywhere = true
                },
                recentProjects: loadRecentPaths(),
                onOpenRecent: requestOpenProject,
                operationItems: gitMergeRebaseWidgetItems(
                    currentRootPath: repo?.workdir(),
                    currentOperation: operationState?.kind,
                    roots: multiRoots
                ),
                currentOperationState: operationState,
                resolvedConflictPaths: resolvedConflictPaths,
                onRevertResolved: revertResolvedPath,
                onOperationAction: { action, rootPath in
                    handleVCSActionRequest(
                        ArborVCSActionRequest(
                            kind: .operationRecovery,
                            projectPath: projectPath,
                            rootPath: rootPath,
                            shelfName: "",
                            operationRecoveryAction: action
                        )
                    )
                }
            ) {
                branchPopup
            }

            WorkspaceSplitLayout(
                persistedSidebarWidth: $savedWorkspaceSidebarWidth,
                selectedToolWindow: toolWindowMode,
                // Rebased keeps the selected Git tool window on the left and
                // opens Git Log in the editor workspace on the right. Log is
                // therefore a second workspace, not a replacement for the
                // Commit/Stash column.
                sidebarVisible: true,
                onSelectToolWindow: { mode in
                    toolWindowMode = mode
                    toolWindowExpanded = true
                    if mode == .log {
                        projectPanelExpanded = false
                        // Git Log is an editor-like workspace, not a narrow
                        // tool-window table. Clear file context so the main
                        // workspace can own the history graph and inspector.
                        selection = nil
                        fileSelection = nil
                        selectionModePath = nil
                        logViewMode = .graph
                        loadLog()
                    }
                },
                onOpenProject: toggleProjectToolWindow
            ) {
                workspaceSidebar
            } mainContent: {
                mainContext
            }

            RebasedStatusBar(
                branch: currentBranchName,
                headID: headId,
                changedCount: entries.filter {
                    $0.staged != .unchanged
                        || ($0.unstaged != .unchanged && $0.unstaged != .ignored)
                }.count,
                projectPath: projectPath,
                onBranch: { showBranchesPopover = true },
                feedbackCenter: feedbackCenter,
                syncStatus: currentSyncStatus,
                hasUnfetchedIncoming: currentBranchHasUnfetchedIncoming,
                onOperationLog: {
                    operationsViewMode = feedbackCenter.isRunning ? .tasks : .history
                    toolWindowMode = .operations
                    toolWindowExpanded = true
                },
                onCancelOperation: feedbackCenter.cancel,
                onFeedbackDetails: { feedbackDetailMessage = $0 }
            )
        }
        .frame(minWidth: 980, minHeight: 540)
        .background(Design.Colors.canvas)
        .onChange(of: toolWindowMode, initial: false) { _, mode in
            UserDefaults.standard.set(mode.rawValue, forKey: "arbor.toolWindowMode")
            // A log-first launch deliberately skips the expensive worktree
            // status scan. Start it when the user actually opens Commit.
            if mode == .commit {
                refreshAll()
            } else if mode != .log {
                // Do not let a history scan continue while another tool
                // window owns the main workspace.
                logRefreshTask?.cancel()
                logRefreshTask = nil
                logLoadTask?.cancel()
                logLoadTask = nil
                logGeneration += 1
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let toast = feedbackCenter.toast {
                FeedbackToastView(
                    message: toast,
                    onDetails: { feedbackDetailMessage = toast },
                    onDismiss: feedbackCenter.dismissToast
                )
                .padding(.trailing, 18)
                .padding(.bottom, 42)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .sheet(item: $feedbackDetailMessage) { message in
            FeedbackDetailView(
                message: message,
                onDismiss: { feedbackDetailMessage = nil },
                onOpenSSHSettings: {
                    feedbackDetailMessage = nil
                    loadGitSSHSettings()
                }
            )
        }
        .alert("GitHub authentication failed", isPresented: $showHostingAuthPrompt) {
            Button("Configure GitHub token") { showHostingSettings = true }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Configure a GitHub token in Settings, then retry the git operation.")
        }
        .sheet(isPresented: $showHostingSettings) {
            if let hostingRepository {
                HostingSettingsView(repository: hostingRepository)
            } else {
                Text("No supported hosting remote is configured.")
                    .padding(24)
            }
        }
        .sheet(isPresented: $showReviewComment) {
            if let commit = reviewCommentCommit,
               let repository = reviewCommentRepository ?? hostingRepository {
                ReviewCommentSheet(
                    repository: repository,
                    commitID: commit.id,
                    client: HostingClientFactory.make(for: repository)
                )
        }
    }
        .sheet(item: $addCommitsToRemoteBranchContext) { context in
            RebasedRemoteBranchSelectionDialog(
                commits: context.commits,
                remoteBranches: context.remoteBranches,
                onCancel: { addCommitsToRemoteBranchContext = nil },
                onSelect: { remoteBranch in
                    addCommitsToRemoteBranchContext = nil
                    prepareAddCommitsToRemoteBranch(remoteBranch, commits: context.commits)
                }
            )
        }
        .sheet(isPresented: $showMultiRootPushOptions) {
            MultiRootPushOptionsDialog(
                onCancel: {
                    showMultiRootPushOptions = false
                    multiRootPushOptionsRootPaths = nil
                    multiRootPushOptionsFromCommit = false
                },
                onPush: { tagMode, skipHooks, force, forceWithLease in
                    let rootPaths = multiRootPushOptionsRootPaths
                    let fromCommit = multiRootPushOptionsFromCommit
                    showMultiRootPushOptions = false
                    multiRootPushOptionsRootPaths = nil
                    multiRootPushOptionsFromCommit = false
                    runMultiRootPush(
                        selectedRootPaths: rootPaths,
                        tagMode: tagMode,
                        skipHooks: skipHooks,
                        force: force,
                        forceWithLease: forceWithLease,
                        fromCommit: fromCommit
                    )
                }
            )
        }
        .sheet(isPresented: $showPushDialog) {
            PushDialogView(
                remotes: remotes,
                branches: branches,
                commits: logEntries,
                mode: pushDialogMode,
                defaultRemote: pushDialogRemote,
                defaultBranch: (pushDialogMode == .pushUpToCommit
                    || pushDialogMode == .addCommitsToRemoteBranch)
                    ? pushDialogBranch
                    : (pushDialogBranch ?? branches.first(where: { $0.isCurrent })?.name),
                defaultSourceRevision: pushDialogSourceRevision,
                currentHasUpstream: currentSyncStatus?.trackingExists ?? false,
                protectedBranchPatterns: effectiveProtectedBranchPatterns,
                defaultRefspec: pushDialogRefspec,
                defaultPushTagMode: GitPushTagSettings.projectTagMode(for: projectPath),
                onCancel: {
                    showPushDialog = false
                    pushDialogRefspec = nil
                    pushDialogRemote = nil
                    pushDialogBranch = nil
                    pushDialogSourceRevision = nil
                },
                onPush: { remote, branch, force, setUpstream, forceWithLease, refspec, tagMode, skipHooks in
                    showPushDialog = false
                    pushDialogRefspec = nil
                    pushDialogRemote = nil
                    pushDialogBranch = nil
                    pushDialogSourceRevision = nil
                    if pushDialogMode == .commitAndPush {
                        commitAndPush(
                            remote: remote,
                            branch: branch,
                            force: force,
                            forceWithLease: forceWithLease,
                            setUpstream: setUpstream
                        )
                    } else {
                        doPush(
                            remote,
                            branch: branch,
                            force: force,
                            forceWithLease: forceWithLease,
                            setUpstream: setUpstream,
                            refspec: refspec,
                            tagMode: tagMode,
                            skipHooks: skipHooks
                        )
                    }
                },
                onConfigureRemotes: {
                    showPushDialog = false
                    beginConfigureRemotes()
                },
                onConfigureSSH: {
                    showPushDialog = false
                    loadGitSSHSettings()
                }
            )
        }
        .sheet(item: $multiRootPushContext) { context in
            PushDialogView(
                remotes: context.remotes,
                branches: context.branches,
                commits: context.commits,
                mode: .push,
                defaultRemote: context.defaultRemote,
                defaultBranch: context.defaultBranch,
                currentHasUpstream: context.currentHasUpstream,
                protectedBranchPatterns: context.protectedBranchPatterns,
                defaultRefspec: nil,
                defaultPushTagMode: context.defaultPushTagMode,
                onCancel: {
                    multiRootPushContext = nil
                },
                onPush: { remote, branch, force, setUpstream, forceWithLease, refspec, tagMode, skipHooks in
                    multiRootPushContext = nil
                    pushInRoot(
                        rootPath: context.rootPath,
                        remote: remote,
                        branch: branch,
                        force: force,
                        forceWithLease: forceWithLease,
                        setUpstream: setUpstream,
                        refspec: refspec,
                        tagMode: tagMode,
                        skipHooks: skipHooks
                    )
                },
                onConfigureRemotes: {
                    multiRootPushContext = nil
                    DispatchQueue.main.async {
                        beginMultiRootRemoteConfig(rootPath: context.rootPath)
                    }
                },
                onConfigureSSH: {},
                showsConfigurationActions: true,
                showsSSHConfigurationAction: false
            )
        }
        .sheet(item: $multiRootRemoteConfigContext) { context in
            RemoteConfigDialogView(
                remotes: context.remotes,
                name: $multiRootRemoteName,
                url: $multiRootRemoteURL,
                pushUrl: $multiRootRemotePushURL,
                fetchRefspec: $multiRootRemoteFetchRefspec,
                pushRefspec: $multiRootRemotePushRefspec,
                initialSelectedName: multiRootRemoteName,
                onAdd: { fetchAfterAdd in
                    addRemoteInRoot(rootPath: context.rootPath, fetchAfterAdd: fetchAfterAdd)
                },
                onRemove: { name in
                    removeRemoteInRoot(rootPath: context.rootPath, name: name)
                },
                onRename: { old, new in
                    renameRemoteInRoot(rootPath: context.rootPath, old: old, new: new)
                },
                onSave: {
                    saveRemoteConfigInRoot(rootPath: context.rootPath)
                },
                onCancel: {
                    multiRootRemoteConfigContext = nil
                },
                onRefresh: {
                    loadMultiRootRemoteConfig(rootPath: context.rootPath)
                }
            )
        }
        .sheet(isPresented: $showBeforeCommitSettings) {
            beforeCommitSettingsSheet
        }
        .sheet(isPresented: $showProjectGitSettings) {
            if let projectPath {
                ProjectGitIncomingChangesSettingsView(
                    projectPath: projectPath,
                    rootPaths: GitExecutableSettings.registeredRoots(
                        projectPath: projectPath,
                        repositoryRoot: repo?.workdir(),
                        discoveredRoots: multiRoots.map(\.path)
                    ),
                    onSaved: {
                        if let repo {
                            _ = try? repo.setGitExecutableOverride(
                                path: GitExecutableSettings.projectOverride(for: projectPath)
                            )
                        }
                        projectIncomingCheckStrategyRaw = GitIncomingCheckStrategySettings.projectRawValue(
                            for: projectPath
                        )
                        projectFetchTagsMode = GitFetchTagsSettings.mode(for: projectPath)
                        projectUpdateMethod = GitUpdateMethodSettings.method(for: projectPath)
                    }
                )
            } else {
                Text("Open a Git project before changing project Git settings.")
                    .padding(24)
            }
        }
        .sheet(isPresented: $showUpdateProjectOptions) {
            if let projectPath {
                UpdateProjectOptionsDialogView(
                    projectPath: projectPath,
                    rootCount: max(1, multiRoots.count),
                    initialUpdateMethod: projectUpdateMethod,
                    showsResetAction: multiRoots.count == 1,
                    onUpdate: { method, shouldShowNextTime in
                        projectUpdateMethod = method
                        GitUpdateMethodSettings.save(method, for: projectPath)
                        GitUpdateOptionsDialogSettings.saveShouldShow(
                            shouldShowNextTime,
                            for: projectPath
                        )
                        showUpdateProjectOptions = false
                        executeMultiRootUpdate(rebase: method == .rebase)
                    },
                    onResetToRemote: {
                        showUpdateProjectOptions = false
                        DispatchQueue.main.async {
                            resetCurrentBranchToRemote()
                        }
                    },
                    onCancel: {
                        showUpdateProjectOptions = false
                    }
                )
            } else {
                Text("Open a Git project before updating it.")
                    .padding(24)
            }
        }
        .sheet(isPresented: $showIdentitySettings) {
            GitIdentitySettingsView(
                name: $identityName,
                email: $identityEmail,
                setNameEmailGlobally: $identitySetNameEmailGlobally,
                signingKey: $identitySigningKey,
                signingFormat: $identitySigningFormat,
                signCommits: $identitySignCommits,
                authorName: $identityAuthorName,
                authorEmail: $identityAuthorEmail,
                committerName: $identityCommitterName,
                committerEmail: $identityCommitterEmail,
                signOff: $identitySignOff,
                coAuthors: $identityCoAuthors,
                recentAuthors: identityRecentAuthors,
                onSelectRecentAuthor: { author in
                    guard let parsed = GitCommitAuthorHistorySettings.parse(author) else { return }
                    identityAuthorName = parsed.name
                    identityAuthorEmail = parsed.email
                },
                onSave: { setGitIdentity(); showIdentitySettings = false },
                onCancel: {
                    pendingIdentityCommitRetry = false
                    showIdentitySettings = false
                },
                onGpgAgent: {
                    showIdentitySettings = false
                    DispatchQueue.main.async { showGpgAgentSettings = true }
                }
            )
        }
        .sheet(isPresented: $showGpgAgentSettings) {
            GpgAgentSettingsView()
        }
        .onChange(of: showIdentitySettings) { _, isPresented in
            if isPresented {
                identitySetNameEmailGlobally = GitIdentityScopeSettings.setNameEmailGlobally(
                    for: projectPath
                )
                identityRecentAuthors = GitCommitAuthorHistorySettings.authors(for: projectPath)
            }
            if !isPresented && showMultiRootCommitDialog {
                syncMultiRootCommitIdentityDraftFromSettings()
            }
        }
        .sheet(isPresented: $showGitSSHSettings) {
            GitSSHSettingsView(
                command: $gitSSHCommand,
                knownHostsFile: $gitSSHKnownHostsFile,
                identityFile: $gitSSHIdentityFile,
                hostKeyPolicy: $gitSSHHostKeyPolicy,
                authMethod: $gitSSHAuthMethod,
                credentialHelperConfig: $gitCredentialHelperConfig,
                credentialHelpers: gitCredentialHelpers,
                onRefreshCredentialHelpers: loadGitCredentialHelpers,
                sshAgentDiagnostics: gitSSHAgentDiagnostics,
                onRefreshSSHAgentDiagnostics: loadGitSSHAgentDiagnostics,
                lastSuccessfulAuthentications: lastSuccessfulSSHAuthentications,
                onClearLastSuccessfulAuthentications: {
                    credentialAuth.clearSSHAuthenticationRecords()
                    lastSuccessfulSSHAuthentications = []
                },
                onSave: { saveGitSSHSettings(); showGitSSHSettings = false },
                onCancel: { showGitSSHSettings = false }
            )
        }
        .sheet(isPresented: $showStashDiff) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Stash Diff").font(.title3.weight(.semibold))
                ScrollView {
                    Text(stashDiffText ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
                HStack {
                    Spacer()
                    Button("Done") {
                        showStashDiff = false
                        stashDiffText = nil
                        stashDiffStashID = nil
                        stashDiffRootPath = nil
                    }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
            .frame(minWidth: 700, minHeight: 460)
        }
        .sheet(isPresented: $showNewBranchDialog) {
            RebasedNewBranchDialog(
                title: newBranchDialogTitle,
                name: $newBranchName,
                baseRevision: $newBranchBase,
                checkout: $newBranchCheckout,
                resetExisting: $newBranchResetExisting,
                validateName: { value in
                    guard let branchRepo = newBranchRepositoryOverride ?? repo else { return nil }
                    do {
                        try branchRepo.validateBranchName(name: value)
                        return nil
                    } catch {
                        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if newBranchResetExisting,
                           newBranchDialogBranches.contains(where: { $0.name == normalized }) {
                            return nil
                        }
                        return errorMessage(error)
                    }
                },
                branches: newBranchDialogBranches,
                onCreate: {
                    let base = newBranchBase.trimmingCharacters(in: .whitespacesAndNewlines)
                    if newBranchAfterCreateRebase {
                        branchCreateAndRebase(
                            at: base.isEmpty ? nil : base,
                            reset: newBranchResetExisting,
                            repository: newBranchRepositoryOverride
                        )
                    } else {
                        branchCreate(
                            at: base.isEmpty ? nil : base,
                            checkout: newBranchCheckout,
                            reset: newBranchResetExisting,
                            repository: newBranchRepositoryOverride
                        )
                    }
                    dismissNewBranchDialog()
                },
                onCancel: dismissNewBranchDialog
            )
        }
        .sheet(isPresented: $showNewWorktreeDialog) {
            RebasedNewWorktreeDialog(
                rootPath: newWorktreeRootPath ?? repo?.workdir(),
                reference: newWorktreeReference,
                isTag: newWorktreeIsTag,
                occupiedBranches: Set(newWorktreeWorktrees.map(\.branch).filter { !$0.isEmpty }),
                validateBranchName: { value in
                    guard let targetRepo = newWorktreeRepository else { return nil }
                    do {
                        try targetRepo.validateBranchName(name: value)
                        if newWorktreeBranches.contains(where: { $0.name == value }) {
                            return "该分支已存在。"
                        }
                        return nil
                    } catch {
                        return errorMessage(error)
                    }
                },
                path: $newWorktreePath,
                branch: $newWorktreeBranch,
                onCreate: { path, branch in
                    createWorktree(
                        path: path,
                        branch: branch,
                        revision: newWorktreeReference,
                        rootPath: newWorktreeRootPath
                    )
                    dismissNewWorktreeDialog()
                },
                onCancel: dismissNewWorktreeDialog
            )
        }
        .sheet(isPresented: $showMultiRootNewBranchDialog) {
            RebasedMultiRootNewBranchDialog(
                name: $multiRootNewBranchName,
                baseRevision: $multiRootNewBranchBase,
                checkout: $multiRootNewBranchCheckout,
                resetExisting: $multiRootNewBranchResetExisting,
                selectedRootPaths: $multiRootSelectedRootPaths,
                roots: multiRoots,
                existingBranchNames: multiRootExistingBranchNames,
                validateName: { value in
                    let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !candidate.isEmpty else { return nil }
                    let selectedPaths = multiRootSelectedRootPaths.isEmpty
                        ? multiRoots.map(\.path)
                        : Array(multiRootSelectedRootPaths)
                    for rootPath in selectedPaths {
                        let exists = multiRootExistingBranchNames[rootPath]?.contains(candidate) == true
                        if multiRootNewBranchResetExisting && exists {
                            continue
                        }
                        guard let rootRepo = try? openRepository(path: rootPath) else { continue }
                        do {
                            try rootRepo.validateBranchName(name: candidate)
                        } catch {
                            return errorMessage(error)
                        }
                    }
                    return nil
                },
                onCreate: {
                    createMultiRootBranch(
                        name: multiRootNewBranchName,
                        baseRevision: multiRootNewBranchBase,
                        checkout: multiRootNewBranchCheckout,
                        reset: multiRootNewBranchResetExisting,
                        selectedRootPaths: multiRootSelectedRootPaths
                    )
                    dismissMultiRootNewBranchDialog()
                },
                onCancel: dismissMultiRootNewBranchDialog
            )
        }
        .sheet(isPresented: $showMultiRootRenameBranchDialog) {
            RebasedMultiRootRenameBranchDialog(
                oldName: multiRootRenameOldName,
                newName: $multiRootRenameNewName,
                unsetUpstream: $multiRootRenameUnsetUpstream,
                selectedRootPaths: $multiRootRenameSelectedRootPaths,
                snapshots: multiRootBranchSnapshots,
                validateName: validateMultiRootRenameName,
                onRename: {
                    renameMultiRootBranch(
                        oldName: multiRootRenameOldName,
                        newName: multiRootRenameNewName,
                        unsetUpstream: multiRootRenameUnsetUpstream,
                        selectedRootPaths: multiRootRenameSelectedRootPaths
                    )
                },
                onCancel: dismissMultiRootRenameBranchDialog
            )
        }
        .sheet(isPresented: $showSingleRootRenameBranchDialog) {
            RebasedSingleRootRenameBranchDialog(
                oldName: singleRootRenameOldName,
                newName: $singleRootRenameNewName,
                unsetUpstream: $singleRootRenameUnsetUpstream,
                hasUpstream: singleRootRenameHasUpstream,
                validateName: { value in
                    validateSingleRootRenameName(
                        rootPath: singleRootRenameRootPath,
                        oldName: singleRootRenameOldName,
                        value: value
                    )
                },
                onRename: {
                    renameBranchInRoot(
                        rootPath: singleRootRenameRootPath,
                        oldName: singleRootRenameOldName,
                        newName: singleRootRenameNewName,
                        unsetUpstream: singleRootRenameUnsetUpstream
                    )
                },
                onCancel: dismissSingleRootRenameBranchDialog
            )
        }
        .sheet(isPresented: $showMultiRootDeleteBranchDialog) {
            RebasedMultiRootDeleteBranchDialog(
                branchName: multiRootDeleteBranchName,
                selectedRootPaths: $multiRootDeleteSelectedRootPaths,
                snapshots: multiRootBranchSnapshots,
                onDelete: {
                    deleteMultiRootBranch(
                        name: multiRootDeleteBranchName,
                        selectedRootPaths: multiRootDeleteSelectedRootPaths
                    )
                },
                onCancel: dismissMultiRootDeleteBranchDialog
            )
        }
        .sheet(isPresented: $showMultiRootDeleteTagDialog) {
            RebasedMultiRootDeleteTagDialog(
                tagName: multiRootDeleteTagName,
                selectedRootPaths: $multiRootDeleteTagSelectedRootPaths,
                snapshots: multiRootBranchSnapshots,
                onDelete: {
                    deleteMultiRootTag(
                        name: multiRootDeleteTagName,
                        selectedRootPaths: multiRootDeleteTagSelectedRootPaths
                    )
                },
                onCancel: dismissMultiRootDeleteTagDialog
            )
        }
        .sheet(isPresented: $showMultiRootRemoteDeleteDialog) {
            RebasedMultiRootRemoteDeleteBranchDialog(
                remoteBranch: multiRootRemoteDeleteBranchName,
                selectedRootPaths: $multiRootRemoteDeleteSelectedRootPaths,
                deleteTracking: $multiRootRemoteDeleteTracking,
                snapshots: multiRootBranchSnapshots,
                onDelete: {
                    deleteMultiRootRemoteBranch(
                        remoteBranch: multiRootRemoteDeleteBranchName,
                        deleteTracking: multiRootRemoteDeleteTracking,
                        selectedRootPaths: multiRootRemoteDeleteSelectedRootPaths
                    )
                },
                onCancel: dismissMultiRootRemoteDeleteDialog
            )
        }
        .sheet(isPresented: $showMergeActionDialog) {
            RebasedMergeDialog(
                branch: $mergeBranch,
                strategy: Binding(
                    get: { MergeStrategyChoice(rawValue: mergeStrategyRaw) ?? .automatic },
                    set: { mergeStrategyRaw = $0.rawValue }
                ),
                commitMessage: $mergeCommitMessage,
                useCustomCommitMessage: $mergeUseCustomCommitMessage,
                noCommit: $mergeNoCommit,
                noVerify: $mergeNoVerify,
                allowUnrelatedHistories: $mergeAllowUnrelatedHistories,
                branches: branches,
                mergedBranches: mergeMergedBranches,
                onMerge: {
                    showMergeActionDialog = false
                    doMerge()
                },
                onCancel: { showMergeActionDialog = false }
            )
        }
        .sheet(isPresented: $showPullDialog) {
            PullDialogView(
                snapshots: pullDialogSnapshots,
                defaultRootPath: repo?.workdir() ?? multiRoots.first?.path,
                defaultRebase: pullDialogRebase,
                initialOptions: GitPullDialogSettingsStore.load(for: projectPath).options,
                blockedRootPaths: Set(
                    multiRoots
                        .filter { $0.operation != nil }
                        .map { canonicalExternalLogPath($0.path) }
                ).union(
                    operationState != nil
                        ? Set([repo?.workdir()].compactMap { $0 }.map(canonicalExternalLogPath))
                        : []
                ),
                fetchInProgress: isArborFetchInProgress(
                    isRunning: feedbackCenter.isRunning,
                    operationName: feedbackCenter.operationName
                ),
                onCancel: {
                    showPullDialog = false
                    pullDialogSnapshots = []
                },
                onPull: { selection in
                    showPullDialog = false
                    pullDialogSnapshots = []
                    savePullDialogSettings(selection.options)
                    executePullDialogSelection(selection)
                },
                onFetch: fetchPullDialogRemote
            )
        }
        .sheet(isPresented: $showRebaseActionDialog) {
            RebasedRebaseDialog(
                onto: $rebaseOnto,
                branch: $rebaseBranch,
                repositoryPath: $rebaseRootPath,
                interactive: $rebaseInteractive,
                preserveMerges: $rebasePreserveMerges,
                autoSquash: $rebaseAutoSquash,
                keepEmpty: $rebaseKeepEmpty,
                updateRefs: $rebaseUpdateRefs,
                root: $rebaseRoot,
                applyToAllRepositories: $rebaseApplyToAllRoots,
                rangeCount: rebaseRange.count,
                repositories: rebaseRepositories,
                branches: rebaseBranchOptions,
                onLoadRange: loadRebaseRange,
                onRangeInputsChanged: invalidateLoadedRebaseRange,
                onRepositoryChanged: selectRebaseRepository,
                onStart: {
                    showRebaseActionDialog = false
                    saveRebaseDialogSettings()
                    if rebaseApplyToAllRoots {
                        if rebaseInteractive {
                            prepareMultiRootRebaseEditor()
                        } else {
                            doMultiRootRebase(drafts: nil)
                        }
                    } else {
                        doRebase()
                    }
                },
                onCancel: { showRebaseActionDialog = false }
            )
        }
        .sheet(isPresented: $showMultiRootRebaseEditor) {
            MultiRootRebaseTodoEditorView(
                onto: rebaseOnto,
                branch: rebaseBranch,
                drafts: $multiRootRebaseDrafts,
                preserveMerges: rebasePreserveMerges,
                autoSquash: rebaseAutoSquash,
                keepEmpty: rebaseKeepEmpty,
                updateRefs: rebaseUpdateRefs,
                root: rebaseRoot,
                onStart: {
                    showMultiRootRebaseEditor = false
                    doMultiRootRebase(drafts: multiRootRebaseDrafts)
                },
                onCancel: {
                    showMultiRootRebaseEditor = false
                    multiRootRebaseDrafts = []
                },
                onOpenRawTodo: prepareMultiRootRawTodoEditor
            )
        }
        .sheet(item: $multiRootRawTodoContext) { context in
            RawRebaseTodoEditorView(
                onto: context.onto,
                text: $multiRootRawTodoText,
                preserveMerges: context.preserveMerges,
                root: context.root,
                onStart: { finishMultiRootRawTodoEditor(context) },
                onCancel: {
                    multiRootRawTodoContext = nil
                    multiRootRawTodoText = ""
                }
            )
        }
        .sheet(item: $multiRootRebaseRollbackContext) { context in
            RebasedMultiRootRebaseRollbackView(
                branch: context.branch,
                targets: context.targets,
                failures: context.failures,
                onRollback: {
                    rollbackMultiRootRebase(context.targets)
                },
                onKeep: {
                    keepMultiRootRebasePartial(context)
                },
                onDone: {
                    multiRootRebaseRollbackContext = nil
                }
            )
        }
        .sheet(isPresented: $showStashDialog) {
            RebasedStashDialog(
                roots: stashRootOptions,
                selectedRootPath: $stashRootPath,
                currentBranch: $stashCurrentBranch,
                isLoadingRoot: $stashRootLoading,
                message: $stashMessage,
                keepIndex: $stashKeepIndex,
                onSelectRoot: selectStashRoot,
                onSave: {
                    showStashDialog = false
                    stashSave(rootPath: stashRootPath)
                },
                onCancel: { showStashDialog = false }
            )
        }
        .sheet(isPresented: $showUnstashDialog) {
            RebasedUnstashDialog(
                roots: multiRoots,
                selectedRootPath: unstashRootPath,
                isLoadingRoot: unstashRootLoading,
                stashes: unstashStashes,
                currentBranch: unstashCurrentBranch,
                onSelectRoot: selectUnstashRoot,
                validateBranchName: { rootPath, value in
                    guard let rootRepo = try? openRepository(path: rootPath) else { return nil }
                    do {
                        try rootRepo.validateBranchName(name: value)
                        return nil
                    } catch {
                        return errorMessage(error)
                    }
                },
                onApply: { rootPath, stashID, restoreIndex in
                    showUnstashDialog = false
                    if useRootScopedUnstashActions {
                        applyStashInRoot(rootPath: rootPath, stashID: stashID, restoreIndex: restoreIndex)
                    } else {
                        stashApply(stashID: stashID, restoreIndex: restoreIndex)
                    }
                },
                onPop: { rootPath, stashID, restoreIndex in
                    showUnstashDialog = false
                    if useRootScopedUnstashActions {
                        popStashInRoot(rootPath: rootPath, stashID: stashID, restoreIndex: restoreIndex)
                    } else {
                        stashPop(stashID: stashID, restoreIndex: restoreIndex)
                    }
                },
                onStashBranch: { rootPath, stashID, branch in
                    showUnstashDialog = false
                    if useRootScopedUnstashActions {
                        stashBranchInRoot(rootPath: rootPath, stashID: stashID, branch: branch)
                    } else {
                        stashBranch(stashID: stashID, branch: branch)
                    }
                },
                onViewDiff: { rootPath, stashID in
                    if useRootScopedUnstashActions {
                        showStashDiffInRoot(rootPath: rootPath, stashID: stashID)
                    } else {
                        showStashPreviewFor(stashID: stashID)
                    }
                },
                onDrop: { rootPath, stashID in
                    if useRootScopedUnstashActions {
                        dropStashInRootConfirmed(rootPath: rootPath, stashID: stashID)
                    } else {
                        stashDrop(stashID: stashID)
                    }
                },
                onClear: { rootPath in
                    if useRootScopedUnstashActions {
                        clearStashesInRootConfirmed(rootPath: rootPath)
                    } else {
                        stashClearAll()
                    }
                },
                onCancel: { showUnstashDialog = false }
            )
        }
        .sheet(isPresented: $showUnstashAsDialog) {
            if let stash = stashes.first(where: { $0.id == unstashAsStashID }) {
                RebasedUnstashAsDialog(
                    stash: stash,
                    currentBranch: currentBranchName,
                    validateBranchName: { value in
                        guard let repo else { return nil }
                        do {
                            try repo.validateBranchName(name: value)
                            return nil
                        } catch {
                            return errorMessage(error)
                        }
                    },
                    onApply: { restoreIndex in
                        showUnstashAsDialog = false
                        unstashAsStashID = nil
                        stashApply(stashID: stash.id, restoreIndex: restoreIndex)
                    },
                    onPop: { restoreIndex in
                        showUnstashAsDialog = false
                        unstashAsStashID = nil
                        stashPop(stashID: stash.id, restoreIndex: restoreIndex)
                    },
                    onStashBranch: { branch in
                        showUnstashAsDialog = false
                        unstashAsStashID = nil
                        stashBranch(stashID: stash.id, branch: branch)
                    },
                    onCancel: {
                        showUnstashAsDialog = false
                        unstashAsStashID = nil
                    }
                )
            } else {
                Color.clear
                    .onAppear {
                        showUnstashAsDialog = false
                        unstashAsStashID = nil
                    }
            }
        }
        .sheet(isPresented: $showStashFilesDialog) {
            RebasedStashFilesDialog(
                message: $stashFilesMessage,
                entries: entries.filter {
                    $0.unstaged != .ignored &&
                    $0.unstaged != .conflicted &&
                    $0.staged != .conflicted
                },
                initialPaths: stashFilesInitialPaths,
                onStash: { paths in
                    showStashFilesDialog = false
                    stashSelectedFiles(paths)
                },
                onCancel: { showStashFilesDialog = false }
            )
        }
        .sheet(isPresented: $showCloneDialog) {
            RebasedCloneDialog(
                url: $cloneURL,
                parentDirectory: $cloneParentDirectory,
                directoryName: $cloneDirectoryName,
                recursiveSubmodules: $cloneRecursiveSubmodules,
                onChooseParent: chooseCloneParentDirectory,
                onClone: cloneRepositoryFromDialog,
                onCancel: { showCloneDialog = false }
            )
        }
        .sheet(isPresented: $showNewTagDialog) {
            RebasedTagDialog(
                name: $tagName,
                revision: $tagAt,
                message: $tagMessage,
                signKey: $tagSignKey,
                annotated: $tagAnnotated,
                force: $tagForce,
                onCreate: {
                    showNewTagDialog = false
                    createTag()
                },
                onCancel: {
                    showNewTagDialog = false
                    tagRepositoryOverride = nil
                    tagForce = false
                }
            )
        }
        .sheet(isPresented: $showShelveDialog) {
            RebasedShelveDialog(
                name: $shelveName,
                entries: entries,
                onShelve: { paths in
                    showShelveDialog = false
                    doShelve(paths: paths)
                },
                onCancel: { showShelveDialog = false }
            )
        }
        .sheet(item: $pendingApplyPatch) { request in
            if let repo {
                RebasedUnshelveDialog(
                    name: request.fileName,
                    paths: request.paths,
                    initialPaths: request.paths,
                    changeLists: changeLists,
                    repo: repo,
                    patchText: request.patch,
                    removeAppliedFilesFromShelf: .constant(false),
                    onUnshelve: { _, _, _, _, _, _ in },
                    onApplyPatch: { paths, selections, targetName, basePath, pathStrip in
                        pendingApplyPatch = nil
                        applyImportedPatch(
                            fileName: request.fileName,
                            patch: request.patch,
                            paths: paths,
                            selections: selections,
                            targetName: targetName,
                            basePath: basePath,
                            pathStrip: pathStrip
                        )
                    },
                    onCancel: { pendingApplyPatch = nil }
                )
            }
        }
        .sheet(item: $patchExportRequest) { request in
            RebasedPatchExportDialog(
                request: request,
                onExport: { options in
                    patchExportRequest = nil
                    DispatchQueue.main.async {
                        request.onExport(options)
                    }
                },
                onCancel: { patchExportRequest = nil }
            )
        }
        .sheet(isPresented: $showHeadResetDialog) {
            RebasedHeadResetDialog(
                roots: resetHeadRootOptions,
                selectedRootPath: $headResetRootPath,
                target: $headResetTarget,
                mode: $headResetMode,
                onValidate: { target, rootPath in
                    validateResetHeadTarget(target, rootPath: rootPath)
                },
                onReset: {
                    showHeadResetDialog = false
                    resetHead(
                        rootPath: headResetRootPath,
                        target: headResetTarget,
                        mode: headResetMode
                    )
                },
                onCancel: { showHeadResetDialog = false }
            )
        }
        .sheet(isPresented: $showResetDialog) {
            if let resetTargetCommit {
                RebasedResetDialog(
                    commit: resetTargetCommit,
                    targetCommits: resetTargetCommits,
                    mode: $resetMode,
                    onReset: {
                        showResetDialog = false
                        if resetTargetCommits.count > 1 {
                            resetCommitsAcrossRoots(resetTargetCommits, mode: resetMode)
                        } else {
                            resetCommit(resetTargetCommit, mode: resetMode)
                        }
                    },
                    onCancel: { showResetDialog = false },
                    multiRootResetAvailable: resetTargetCommits.count > 1,
                    onResetAcrossRoots: { mode in
                        showResetDialog = false
                        resetCommitsAcrossRoots(resetTargetCommits, mode: mode)
                    }
                )
            }
        }
        .sheet(item: $uncommitRequest) { request in
            RebasedUncommitDialog(
                request: request,
                onUncommit: { targetName in
                    uncommitRequest = nil
                    performUncommit(request, targetName: targetName)
                },
                onCancel: { uncommitRequest = nil }
            )
        }
        .sheet(item: $smartOperationRequest) { request in
            RebasedSmartOperationDialog(
                request: request,
                onSmart: {
                    smartOperationRequest = nil
                    request.onSmart()
                },
                onForce: {
                    smartOperationRequest = nil
                    request.onForce?()
                },
                onCancel: {
                    smartOperationRequest = nil
                    feedbackCenter.warning(
                        "Git operation cancelled",
                        detail: "Local changes were kept."
                    )
                }
            )
        }
    }

    @ViewBuilder
    private var beforeCommitSettingsSheet: some View {
        BeforeCommitSettingsView(
            commands: $beforeCommitCommands,
            onIdentity: { showIdentitySettings = true }
        )
    }

    private func selectChangedFile(_ path: String) {
        commitPreviewPath = path
        commitPreviewComparisonMode = nil
        commitPreviewThreeVersions = false
        selectionModePath = nil
        selection = nil
        fileSelection = nil
        // GitStagePanel separates selection from the Show Diff Preview action.
        // Changing a row updates an already-open preview, but does not
        // silently reopen a preview the user explicitly hid.
    }

    private func previewChangedFile(_ path: String) {
        // GitStagePanel reserves double-click/Enter for Open Source. Arbor has
        // no IDE editor. When Log owns the editor workspace, preserve that
        // workspace and keep the source action inside the Commit/Stash side
        // instead of replacing the selected history with a file viewer.
        if toolWindowMode == .log {
            commitPreviewPath = path
            commitPreviewComparisonMode = nil
            commitPreviewThreeVersions = false
            fileSelectionVersion = .local
            selectionModePath = nil
            selection = nil
            fileSelection = nil
            commitPreviewVisible = true
            feedbackCenter.warning(
                "Open Source is not an IDE editor",
                detail: "The Commit/Stash preview remains open so Git Log is not replaced.",
                nextStep: "Use the single-click diff or open the file from Project."
            )
            return
        }
        commitPreviewPath = nil
        commitPreviewComparisonMode = nil
        commitPreviewThreeVersions = false
        selection = nil
        selectionModePath = nil
        fileSelection = path
        fileSelectionVersion = .local
        commitPreviewVisible = false
    }

    private func previewFirstChangedFile() {
        if commitPreviewVisible {
            commitPreviewVisible = false
            commitPreviewThreeVersions = false
            return
        }
        commitPreviewPath = entries.first(where: {
            $0.staged != .unchanged
                || ($0.unstaged != .unchanged && $0.unstaged != .ignored)
        })?.path
        commitPreviewComparisonMode = nil
        commitPreviewThreeVersions = false
        commitPreviewVisible = true
    }

    private func showCommitDiffPreview(_ path: String) {
        // This is the stage-tree equivalent of Git.Stage.Tree.Menu's
        // Diff.ShowDiff action. It deliberately does not enter the editor
        // file-selection path: when Log is active, the right workspace must
        // remain the graph/details inspector and the diff belongs beside the
        // Commit/Stash tree on the left.
        commitPreviewPath = path
        commitPreviewComparisonMode = nil
        commitPreviewMode = .unstaged
        commitPreviewThreeVersions = false
        selectionModePath = nil
        selection = nil
        fileSelection = nil
        commitPreviewVisible = true
    }

    private func showCommitStagedDiffPreview(_ path: String) {
        commitPreviewPath = path
        commitPreviewComparisonMode = nil
        commitPreviewMode = .staged
        commitPreviewThreeVersions = false
        selectionModePath = nil
        selection = nil
        fileSelection = nil
        commitPreviewVisible = true
    }

    private func showCommitLocalStagedDiffPreview(_ path: String) {
        commitPreviewPath = path
        commitPreviewComparisonMode = stagingComparisonDiffMode(for: .localWithStaged)
        commitPreviewMode = .unstaged
        commitPreviewThreeVersions = false
        selectionModePath = nil
        selection = nil
        fileSelection = nil
        commitPreviewVisible = true
    }

    private func showCommitThreeVersionsPreview(_ path: String) {
        commitPreviewPath = path
        commitPreviewComparisonMode = nil
        commitPreviewThreeVersions = true
        selectionModePath = nil
        selection = nil
        fileSelection = nil
        commitPreviewVisible = true
    }

    private func showCommitLocalVersion(_ path: String) {
        showCommitFileVersion(path, version: .local)
    }

    private func showCommitStagedVersion(_ path: String) {
        showCommitFileVersion(path, version: .staged)
    }

    private func showCommitFileVersion(_ path: String, version: FileContentVersion) {
        commitPreviewPath = nil
        commitPreviewComparisonMode = nil
        commitPreviewVisible = false
        commitPreviewThreeVersions = false
        fileTreeDiffRequest = nil
        selection = nil
        selectionModePath = nil
        fileSelectionVersion = version
        fileSelection = path
    }

    func annotateProjectFile(_ path: String) {
        guard let normalizedPath = normalizedRepositoryRelativePath(path) else { return }
        toolWindowMode = .commit
        fileTreeDiffRequest = nil
        selection = nil
        selectionModePath = nil
        logSelection = nil
        fileSelectionVersion = .local
        fileSelection = normalizedPath
        fileContentBlameRequestID &+= 1
    }

    func openFirstConflictFromAction() {
        guard let conflictedPath = firstConflictedPath(in: entries) else { return }
        openConflictFromStage(conflictedPath)
    }

    private func openConflictFromStage(_ path: String) {
        // The resolver is a sheet over the current workspace. In Log mode the
        // right editor must remain the Log graph, so pass the initial file via
        // a dedicated dialog context instead of the global editor selection.
        mergeInitialPath = path
        if toolWindowMode != .log { selection = path }
        fileSelection = nil
        selectionModePath = nil
        commitPreviewPath = nil
        commitPreviewComparisonMode = nil
        commitPreviewVisible = false
        commitPreviewThreeVersions = false
        showMergeRevisionsDialog = true
    }

    @ViewBuilder
    private var activeToolWindowContent: some View {
        switch toolWindowMode {
        case .commit, .log:
            RebasedCommitWorkspace(
                projectPath: projectPath,
                repo: repo,
                repositoryWorkdir: repo?.workdir(),
                shelfRepo: activeShelfRepository,
                entries: entries,
                changeLists: changeLists,
                untrackedEntries: untrackedEntries,
                ignoredRules: ignoredRules,
                stashes: stashes,
                shelves: activeShelfList,
                deletedShelves: activeDeletedShelfList,
                shelfChangeLists: activeShelfChangeLists,
                showShelfRequestID: shelfTabRequestID,
                onWorkspaceTabChange: { isShelfWorkspaceTabActive = $0 },
                shelfRootPath: activeShelfRootPath,
                shelfRootOptions: availableShelfRoots,
                selectedShelfRootPath: activeShelfRootPath ?? "",
                isShelfRootReadOnly: isShelfRootReadOnly,
                canMutateShelfMetadata: canMutateShelfMetadata,
                canApplyShelfWorktree: canApplyShelfWorktree,
                isShelfRootLoading: shelfRootLoading,
                shelfRootError: shelfRootError,
                onShelfRootChange: setShelfRoot,
                isLoading: isLoading,
                isShowingCachedStatusSnapshot: isShowingCachedStatusSnapshot,
                hasStaged: hasStaged,
                commitFeedback: commitFeedback,
                operationState: operationState,
                operationFeedback: operationFeedback,
                binaryPaths: stagingBinaryPaths,
                stagingPresence: stagingPresenceByPath,
                refreshToken: fileContentRefreshToken,
                recentMessages: recentMessages,
                commitMessage: $commitMessage,
                amendMode: $amendMode,
                skipHooks: $skipHooks,
                onStage: stagePath,
                onStageWithoutContent: stageWithoutContent,
                onStageWithoutContentAll: stageWithoutContentAll,
                onUnstage: unstagePath,
                onPartial: partialMode,
                onSelect: selectChangedFile,
                onPreviewPath: previewChangedFile,
                onShowDiffPath: showCommitDiffPreview,
                onShowLocalStagedDiffPath: showCommitLocalStagedDiffPreview,
                onShowLocalVersionPath: showCommitLocalVersion,
                onShowStagedVersionPath: showCommitStagedVersion,
                onShowStagedDiffPath: showCommitStagedDiffPreview,
                onShowThreeVersionsPath: showCommitThreeVersionsPreview,
                previewMode: $commitPreviewMode,
                comparisonMode: commitPreviewComparisonMode,
                showThreeVersions: $commitPreviewThreeVersions,
                previewPath: $commitPreviewPath,
                isPreviewVisible: $commitPreviewVisible,
                selectionModePath: $selectionModePath,
                onRestore: { path in restoreFileFromHead(path) },
                onRevertUnstaged: revertUnstagedPath,
                onRefresh: refreshAll,
                onStageAll: stageAll,
                onStageEverything: stageEverything,
                onCreateChangeList: createChangeList,
                onRenameChangeList: renameChangeList,
                onDeleteChangeList: deleteChangeList,
                onActivateChangeList: activateChangeList,
                onMovePathsToChangeList: movePathsToChangeList,
                onTemplate: loadTemplate,
                onBeforeCommitSettings: { showBeforeCommitSettings = true },
                onCommit: { doCommit() },
                onCommitAll: commitAllTrackedChanges,
                onCommitAndRebase: { doCommit(rebaseAfterCommit: true) },
                autoSquashCommitKind: pendingAutoSquashRebase?.kind,
                onCommitAndPush: beginCommitAndPush,
                onOperationContinue: doOperationContinue,
                onOperationSkip: doOperationSkip,
                onOperationAbort: doOperationAbort,
                onOpenConflictResolver: openActiveOperationConflictResolver,
                onShelve: { showShelveDialog = true },
                onShelvePaths: shelveDraggedPaths,
                onImportShelve: { rootPath in
                    importShelvePatches(rootPath: rootPath)
                },
                onPreview: previewFirstChangedFile,
                onStash: presentStashDialog,
                onStashPaths: { paths in showStashFiles(paths: paths) },
                onStashSilently: stashSilently,
                onApplyStash: { stashID, restoreIndex in stashApply(stashID: stashID, restoreIndex: restoreIndex) },
                onPopStash: { stashID, restoreIndex in stashPop(stashID: stashID, restoreIndex: restoreIndex) },
                onDropStash: stashDrop(stashID:),
                onStashBranch: stashBranch(stashID:),
                onUnstashAs: presentUnstashAsDialog,
                onStashDiffPreview: showStashPreviewFor(stashID:),
                stashDiffText: stashPreviewText,
                stashPreviewStashID: $stashPreviewStashID,
                isStashPreviewVisible: $showStashPreview,
                onStashClear: stashClearAll,
                onShelveDiffPreview: showShelvePreviewFor,
                shelfDiffText: shelfPreviewText,
                shelfPreviewName: $shelfPreviewName,
                shelfPreviewIsDeleted: $shelfPreviewIsDeleted,
                isShelfPreviewVisible: $showShelfPreview,
                onRenameShelve: { name, description in
                    renameShelve(
                        name,
                        currentDescription: description,
                        rootPath: activeShelfRootPath
                    )
                },
                onRenameShelveDescription: { name, description in
                    renameShelveDescription(
                        name,
                        description,
                        rootPath: activeShelfRootPath
                    )
                },
                onExportShelve: { name in
                    exportShelve(name, rootPath: activeShelfRootPath)
                },
                onUnshelve: { name in
                    doShelveUnshelve(name, rootPath: activeShelfRootPath)
                },
                onUnshelveWithOptions: { name, removeApplied in
                    doShelveUnshelve(
                        name,
                        removeApplied: removeApplied,
                        rootPath: activeShelfRootPath
                    )
                },
                onUnshelvePathsWithOptions: { name, paths, removeApplied in
                    doShelveUnshelvePaths(
                        name,
                        paths,
                        removeApplied: removeApplied,
                        rootPath: activeShelfRootPath
                    )
                },
                onUnshelvePathGroupsWithOptions: { groups, removeApplied, sourceIsDeleted in
                    doShelveUnshelvePathGroups(
                        groups,
                        removeApplied: removeApplied,
                        sourceIsDeleted: sourceIsDeleted,
                        rootPath: activeShelfRootPath
                    )
                },
                onUnshelveSelectionsWithOptions: { name, selections, removeApplied in
                    doShelveUnshelveSelections(
                        name,
                        selections: selections,
                        removeApplied: removeApplied,
                        rootPath: activeShelfRootPath
                    )
                },
                onUnshelvePathsWithBase: { name, paths, removeApplied, basePath, pathStrip in
                    doShelveUnshelvePaths(
                        name,
                        paths,
                        removeApplied: removeApplied,
                        basePath: basePath,
                        pathStrip: pathStrip,
                        rootPath: activeShelfRootPath
                    )
                },
                onUnshelveSelectionsWithBase: { name, selections, removeApplied, basePath, pathStrip in
                    doShelveUnshelveSelections(
                        name,
                        selections: selections,
                        removeApplied: removeApplied,
                        basePath: basePath,
                        pathStrip: pathStrip,
                        rootPath: activeShelfRootPath
                    )
                },
                onUnshelveShelvesIntoChangeList: { names, targetName, removeApplied in
                    doShelveUnshelveShelvesIntoChangeList(
                        names,
                        targetName: targetName,
                        removeApplied: removeApplied,
                        rootPath: activeShelfRootPath
                    )
                },
                onUnshelvePathGroupsIntoChangeList: { groups, targetName, removeApplied in
                    doShelveUnshelvePathGroupsIntoChangeList(
                        groups,
                        targetName: targetName,
                        removeApplied: removeApplied,
                        rootPath: activeShelfRootPath
                    )
                },
                onUnshelveShelvesSilently: { names, removeApplied in
                    doShelveUnshelveSilently(
                        names,
                        removeApplied: removeApplied,
                        rootPath: activeShelfRootPath
                    )
                },
                onUnshelveDeletedShelvesSilently: { names, removeApplied in
                    doShelveUnshelveSilently(
                        names,
                        removeApplied: removeApplied,
                        rootPath: activeShelfRootPath
                    )
                },
                onUnshelveDeletedPathsWithOptions: { name, paths, removeApplied in
                    doShelveUnshelvePaths(
                        name,
                        paths,
                        removeApplied: removeApplied,
                        sourceIsDeleted: true,
                        rootPath: activeShelfRootPath
                    )
                },
                onPopShelve: { name in
                    doShelvePop(name, rootPath: activeShelfRootPath)
                },
                onPopShelves: { names in
                    doShelvePopShelves(names, rootPath: activeShelfRootPath)
                },
                onUnshelveIntoChangeList: { name, paths, targetName in
                    doShelveUnshelveIntoChangeList(
                        name,
                        paths: paths,
                        targetName: targetName,
                        rootPath: activeShelfRootPath
                    )
                },
                onUnshelveSelectionsIntoChangeList: { name, selections, targetName, removeApplied in
                    doShelveUnshelveIntoChangeList(
                        name,
                        paths: nil,
                        selections: selections,
                        targetName: targetName,
                        removeApplied: removeApplied,
                        rootPath: activeShelfRootPath
                    )
                },
                onUnshelveIntoChangeListWithBase: { name, paths, targetName, removeApplied, basePath, pathStrip in
                    doShelveUnshelveIntoChangeList(
                        name,
                        paths: paths,
                        targetName: targetName,
                        removeApplied: removeApplied,
                        basePath: basePath,
                        pathStrip: pathStrip,
                        rootPath: activeShelfRootPath
                    )
                },
                onUnshelveSelectionsIntoChangeListWithBase: { name, selections, targetName, removeApplied, basePath, pathStrip in
                    doShelveUnshelveIntoChangeList(
                        name,
                        paths: nil,
                        selections: selections,
                        targetName: targetName,
                        removeApplied: removeApplied,
                        basePath: basePath,
                        pathStrip: pathStrip,
                        rootPath: activeShelfRootPath
                    )
                },
                onCleanRecycledShelves: {
                    cleanRecycledShelves(rootPath: activeShelfRootPath)
                },
                onDropShelve: { name in
                    doShelveDrop(name, rootPath: activeShelfRootPath)
                },
                onDropShelves: { names in
                    doShelveDropShelves(names, rootPath: activeShelfRootPath)
                },
                onDropShelvePaths: { name, paths in
                    doShelveDropPaths(name, paths, rootPath: activeShelfRootPath)
                },
                onDropShelvePathGroups: { groups in
                    doShelveDropPathGroups(groups, rootPath: activeShelfRootPath)
                },
                onMoveShelfPaths: { sourceName, targetName, paths in
                    moveShelfPaths(
                        sourceName,
                        targetName,
                        paths,
                        rootPath: activeShelfRootPath
                    )
                },
                onRestoreDeletedShelve: { name in
                    restoreDeletedShelve(name, rootPath: activeShelfRootPath)
                },
                onDeleteDeletedShelve: { name in
                    deleteDeletedShelve(name, rootPath: activeShelfRootPath)
                },
                onDeleteDeletedShelfPaths: { name, paths in
                    doShelveDeleteDeletedPaths(name, paths, rootPath: activeShelfRootPath)
                },
                onDeleteDeletedShelfPathGroups: { groups in
                    doShelveDeleteDeletedPathGroups(groups, rootPath: activeShelfRootPath)
                },
                onRestoreDeletedShelves: { names in
                    restoreDeletedShelves(names, rootPath: activeShelfRootPath)
                },
                onDeleteDeletedShelves: { names, confirm in
                    deleteDeletedShelves(
                        names,
                        confirm: confirm,
                        rootPath: activeShelfRootPath
                    )
                },
                onDeleteShelfPlan: { plan in
                    deleteShelfPlan(plan, rootPath: activeShelfRootPath)
                },
                onIgnore: { paths, ignoreFilePath in
                    ignorePaths(paths, ignoreFilePath: ignoreFilePath)
                },
                onExclude: { paths in
                    paths.forEach(excludePathFromRepo)
                },
                onOpenConflict: openConflictFromStage,
                resolvedConflictPaths: resolvedConflictPaths,
                onRevertResolved: revertResolvedPath,
                onShowHistory: { path in showFileHistory(path) },
                onEditGitignore: editGitignore,
                onEditGitExclude: editGitExclude
            )
        case .operations:
            VStack(spacing: 0) {
                Picker("操作视图", selection: $operationsViewMode) {
                    ForEach(OperationsViewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider()
                switch operationsViewMode {
                case .tasks:
                    GitTasksView(
                        feedbackCenter: feedbackCenter,
                        focusNotificationID: $operationLogFocusNotificationID,
                        onOpenHistory: { operationsViewMode = .history }
                    )
                case .history:
                    OperationLogView(
                        feedbackCenter: feedbackCenter,
                        focusNotificationID: $operationLogFocusNotificationID
                    )
                case .console:
                    GitConsoleView(
                        result: consoleResult,
                        onRun: runGitConsole,
                        onClear: { consoleResult = nil }
                    )
                case .roots:
                    MultiRootPanel(
                        roots: multiRoots,
                        results: multiRootResults,
                        conflictGroups: multiRootConflictGroups,
                        isRunning: multiRootRunning,
                        canRetryFailedUpdate: multiRootUpdateRetryAvailable,
                        canRetryFailedCheckoutUpdate: multiRootCheckoutUpdateRetryAvailable,
                        canRetryFailedPush: multiRootPushRetryContext != nil,
                        onOperation: { op in executeMultiRootOperation(op, message: nil) },
                        onCommitAll: { openMultiRootCommitDialog() },
                        onCheckout: { reference, detach in
                            executeMultiRootCheckout(reference: reference, detach: detach)
                        },
                        onRecovery: { rootPath, action in
                            executeMultiRootRecovery(rootPath: rootPath, action: action)
                        },
                        onRetryFailedUpdate: { retryMultiRootUpdateFailedRoots() },
                        onRetryFailedCheckoutUpdate: { retryMultiRootCheckoutAndUpdateFailedRoots() },
                        onRetryFailedPush: { retryMultiRootPushFailedRoots() },
                        onResolveOperationConflict: openMultiRootOperationConflict,
                        onAcceptConflicts: { targets, pick in
                            acceptMultiRootConflicts(targets, pick: pick)
                        },
                        conflictBatchWorking: multiRootConflictBatchWorking,
                        conflictBatchError: multiRootConflictBatchError,
                        stashConflicts: multiRootStashConflicts,
                        onResolveStashConflict: openMultiRootStashConflict,
                        updateStashRoots: multiRootUpdateStashedRoots,
                        onRestoreUpdateStash: restoreMultiRootUpdateStash,
                        onRefresh: { loadMultiRoots() },
                        onShowChanges: openMultiRootChanges
                    )
                case .submodules:
                    SubmodulePanel(
                        submodules: submodules,
                        feedback: submoduleFeedback,
                        onAdd: submoduleAdd,
                        onUpdate: submoduleUpdate,
                        onSync: submoduleSync,
                        onUpdatePath: submoduleUpdatePath,
                        onUpdateOptions: submoduleUpdateWithOptions,
                        onDeinit: submoduleDeinit,
                        onRemove: submoduleRemove,
                        onSetBranch: submoduleSetBranch,
                        onLog: openSubmoduleLog,
                        onPush: beginSubmodulePushDialog,
                        onConfigureRemotes: beginSubmoduleRemoteConfig,
                        onRefresh: refreshAll
                    )
                case .worktrees:
                    WorktreePanel(
                        worktrees: worktrees,
                        feedback: worktreeFeedback,
                        onRefresh: loadWorktrees,
                        onCreate: { path, branch, revision in
                            createWorktree(path: path, branch: branch, revision: revision)
                        },
                        onOpen: { openWindow(value: $0) },
                        onRemove: removeWorktree,
                        onLock: lockWorktree,
                        onUnlock: unlockWorktree,
                        onPrune: pruneWorktrees
                    )
                }
            }
        }
    }

    private var workspaceSidebar: some View {
        GeometryReader { proxy in
            let panelHeight = proxy.size.height
            let headerHeight: CGFloat = 32
            let resizeHandleHeight: CGFloat = 7
            let minimumToolHeight: CGFloat = 220
            let minimumProjectHeight: CGFloat = 140
            let bothExpanded = toolWindowExpanded && projectPanelExpanded
            let separatorHeight = bothExpanded ? resizeHandleHeight : 1
            let maximumToolHeight = max(
                minimumToolHeight,
                panelHeight - headerHeight - separatorHeight - minimumProjectHeight
            )
            let expandedToolHeight = min(
                max(CGFloat(toolWindowHeight), minimumToolHeight),
                maximumToolHeight
            )
            let toolPanelHeight: CGFloat = {
                if !toolWindowExpanded { return headerHeight }
                if projectPanelExpanded { return expandedToolHeight }
                return max(headerHeight, panelHeight - headerHeight - separatorHeight)
            }()
            let projectPanelHeight: CGFloat = {
                if !projectPanelExpanded { return headerHeight }
                if toolWindowExpanded {
                    return max(headerHeight, panelHeight - toolPanelHeight - separatorHeight)
                }
                return max(headerHeight, panelHeight - headerHeight - separatorHeight)
            }()

            VStack(spacing: 0) {
            if !projectPanelExpanded {
                // GitStagePanel/OperationLogView own their own first row
                // (Commit/Stash or the operations tabs). Rebased does not
                // add a second generic tool-window title above that row;
                // doing so shifts the entire left workspace down and makes
                // the Commit/Stash surface structurally different.
                if toolWindowExpanded || toolWindowMode == .log {
                    activeToolWindowContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    WorkspacePanelHeader(
                        title: LocalizedStringKey(toolWindowMode.title),
                        systemImage: toolWindowMode.systemImage,
                        isExpanded: false,
                        onToggle: {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                toolWindowExpanded = true
                            }
                        }
                    )
                }
            } else if toolWindowMode == .log {
                // The activity-rail folder is the Project tool-window
                // switch in Rebased. Keep the Log workspace on the right,
                // while replacing the left Commit/Stash surface with the
                // project tree until the folder button is pressed again.
                VStack(spacing: 0) {
                    WorkspacePanelHeader(
                        title: "Project",
                        systemImage: "folder",
                        isExpanded: true,
                        onToggle: { projectPanelExpanded = false },
                        trailing: AnyView(
                            HStack(spacing: 8) {
                                Button(action: showOpenPanel) {
                                    Image(systemName: "folder.badge.plus")
                                }
                                .buttonStyle(.plain)
                                .help("打开项目")
                                if repo != nil {
                                    Button(action: { if let repo { showInFinder(repo) } }) {
                                        Image(systemName: "arrow.up.forward.app")
                                    }
                                    .buttonStyle(.plain)
                                    .help("在 Finder 中显示项目根目录")
                                }
                            }
                        )
                    )
                    ProjectTreePane(
                        repo: repo,
                        projectPath: projectPath,
                        headId: headId,
                        entries: entries,
                        selection: Binding(
                            get: { fileSelection },
                            set: { value in
                                fileTreeDiffRequest = nil
                                fileSelection = value
                                fileSelectionVersion = .local
                                if value != nil {
                                    selection = nil
                                    selectionModePath = nil
                                    logSelection = nil
                                }
                            }
                        ),
                        onOpen: showOpenPanel,
                        onReveal: { if let repo { showInFinder(repo) } },
                        onCopyPath: copyRepositoryRelativePath,
                        onCompareWithReference: openFileReferenceComparison,
                        onCompareWithSameVersion: openFileSameVersionComparison,
                        onCompareWithSelectedRevision: openFileSelectedRevisionComparison,
                        onShowFileHistory: { path in
                            showFileHistory(path, rootPath: repo?.workdir())
                        },
                        onShowCurrentRevision: showCurrentRevision,
                        onAnnotate: annotateProjectFile,
                        onCheckin: beginFileCheckin,
                        onAdd: stageProjectTreePath,
                        onRevert: restoreProjectTreePath,
                        onResolveConflicts: openConflictFromStage,
                        resolvedConflictPaths: resolvedConflictPaths,
                        onRevertResolved: revertResolvedPath,
                        showHeader: false
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                    WorkspacePanelHeader(
                        title: LocalizedStringKey(toolWindowMode.title),
                        systemImage: toolWindowMode.systemImage,
                        isExpanded: toolWindowExpanded,
                        onToggle: {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                toolWindowExpanded.toggle()
                            }
                        }
                    )
                    if toolWindowExpanded {
                        activeToolWindowContent
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: toolPanelHeight)

                if bothExpanded {
                    WorkspacePanelResizeHandle(
                        topHeight: $toolWindowHeight,
                        minimumTopHeight: Double(minimumToolHeight),
                        maximumTopHeight: Double(maximumToolHeight)
                    )
                } else {
                    Divider()
                }

                VStack(spacing: 0) {
                    WorkspacePanelHeader(
                        title: "Project",
                        systemImage: "folder",
                        isExpanded: projectPanelExpanded,
                        onToggle: {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                projectPanelExpanded.toggle()
                            }
                        },
                        trailing: AnyView(
                            HStack(spacing: 8) {
                                Button(action: showOpenPanel) {
                                    Image(systemName: "folder.badge.plus")
                                }
                                .buttonStyle(.plain)
                                .help("打开项目")
                                if repo != nil {
                                    Button(action: { if let repo { showInFinder(repo) } }) {
                                        Image(systemName: "arrow.up.forward.app")
                                    }
                                    .buttonStyle(.plain)
                                    .help("在 Finder 中显示项目根目录")
                                }
                            }
                        )
                    )
                    if projectPanelExpanded {
                        ProjectTreePane(
                            repo: repo,
                            projectPath: projectPath,
                            headId: headId,
                            entries: entries,
                            selection: Binding(
                            get: { fileSelection },
                            set: { value in
                                fileTreeDiffRequest = nil
                                fileSelection = value
                                fileSelectionVersion = .local
                                if value != nil {
                                        selection = nil
                                        selectionModePath = nil
                                        logSelection = nil
                                    }
                                }
                            ),
                            onOpen: showOpenPanel,
                            onReveal: { if let repo { showInFinder(repo) } },
                            onCopyPath: copyRepositoryRelativePath,
                            onCompareWithReference: openFileReferenceComparison,
                            onCompareWithSameVersion: openFileSameVersionComparison,
                            onCompareWithSelectedRevision: openFileSelectedRevisionComparison,
                            onShowFileHistory: { path in
                                showFileHistory(path, rootPath: repo?.workdir())
                            },
                            onShowCurrentRevision: showCurrentRevision,
                            onAnnotate: annotateProjectFile,
                            onCheckin: beginFileCheckin,
                            onAdd: stageProjectTreePath,
                            onRevert: restoreProjectTreePath,
                            onResolveConflicts: openConflictFromStage,
                            resolvedConflictPaths: resolvedConflictPaths,
                            onRevertResolved: revertResolvedPath,
                            showHeader: false
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    }
                    .frame(height: projectPanelHeight)

                    Spacer(minLength: 0)
                }
            }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func toggleProjectToolWindow() {
        if toolWindowMode == .log {
            projectPanelExpanded.toggle()
        } else {
            projectPanelExpanded = true
        }
    }

    @ViewBuilder
    private var mainContext: some View {
        if let loadError, projectRepo == nil {
            ProjectLoadErrorView(
                message: loadError,
                onRetry: {
                    guard let projectPath else {
                        showOpenPanel()
                        return
                    }
                    openProjectPath(projectPath)
                },
                onOpen: showOpenPanel
            )
        } else if projectRepo == nil {
            ProjectEmptyStateView(
                recentPaths: loadRecentPaths(),
                onOpen: showOpenPanel,
                onInit: showInitializePanel,
                onClone: { showCloneDialog = true },
                onSelect: requestOpenProject
            )
        } else if toolWindowMode == .log {
            // Git Log is an editor workspace. A stale file selection (most
            // commonly a conflicted path left by the Commit tool window) must
            // never replace the graph/details workspace with Merge Revisions.
            // Rebased keeps the staging workbench on the left and the Log
            // editor on the right until the user explicitly opens the
            // resolver from that workbench.
            logWorkspace
        } else if selectedEntryIsConflicted {
            VStack(spacing: 12) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.orange)
                Text("冲突文件已进入 Merge Revisions")
                    .foregroundStyle(.secondary)
                Button("打开 Merge Revisions…") { showMergeRevisionsDialog = true }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let fileTreeDiffRequest,
                  selection == nil,
                  selectionModePath == nil,
                  fileSelection == nil {
            DiffDetailView(
                repo: fileTreeDiffRequest.repo,
                entry: fileTreeDiffRequest.entry,
                onChanged: { },
                selectionModePath: nil,
                initialMode: fileTreeDiffRequest.initialMode,
                refreshToken: fileContentRefreshToken
            )
        } else if selection != nil || selectionModePath != nil {
            DiffDetailView(
                repo: repo,
                entry: selectedEntry,
                onChanged: refreshAll,
                selectionModePath: selectionModePath,
                refreshToken: fileContentRefreshToken
            )
        } else if let fileSelection {
            let versionOptions = fileContentVersionOptions
            let effectiveVersion = resolvedFileContentVersion(
                current: fileSelectionVersion,
                available: versionOptions
            ) ?? fileSelectionVersion
            FileContentView(
                repo: repo,
                path: fileSelection,
                version: effectiveVersion,
                availableVersions: versionOptions,
                onVersionChange: { fileSelectionVersion = $0 },
                onShowFileHistory: { path in
                    showFileHistory(path, rootPath: repo?.workdir())
                },
                blameRequestID: fileContentBlameRequestID,
                refreshToken: fileContentRefreshToken
            )
            .onAppear {
                if effectiveVersion != fileSelectionVersion {
                    fileSelectionVersion = effectiveVersion
                }
            }
            .onChange(of: versionOptions) { _, updatedOptions in
                guard let resolved = resolvedFileContentVersion(
                    current: fileSelectionVersion,
                    available: updatedOptions
                ) else { return }
                if resolved != fileSelectionVersion {
                    fileSelectionVersion = resolved
                }
            }
        } else {
            VStack(spacing: Design.Spacing.md) {
                Image(systemName: "rectangle.center.inset.filled")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Design.Colors.accent)
                Text("从左侧项目树或底部工具窗选择上下文")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ToolbarContentBuilder
    private var projectToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Menu {
                Button("打开项目…", action: showOpenPanel)
                Button("初始化 Git 仓库…", action: showInitializePanel)
                Button("克隆 Git 仓库…") { showCloneDialog = true }
                let recent = loadRecentPaths()
                if !recent.isEmpty {
                    Divider()
                    ForEach(recent, id: \.self) { recentPath in
                        Button(URL(fileURLWithPath: recentPath).lastPathComponent) {
                            requestOpenProject(recentPath)
                        }
                    }
                }
            } label: {
                Label("项目", systemImage: "folder.badge.gearshape")
            }
            .help("打开项目")

            Button(action: refreshAll) {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(repo == nil || isLoading)
            .help("刷新状态")
        }
        ToolbarItem(placement: .principal) {
            branchPopup
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Update", systemImage: "arrow.down.circle") {
                requestUpdateProject()
            }
            .keyboardShortcut("t", modifiers: [.command])
            .disabled(repo == nil)
            .help("Update / pull (⌘T)")
            Menu {
                Button("Reset to Remote Branch…") {
                    resetCurrentBranchToRemote()
                }
                .disabled(!isArborVCSActionEnabled(.resetToRemoteBranch, in: vcsActionContext))
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help("Update options")
            Button("提交", systemImage: "checkmark.circle") {
                toolWindowMode = .commit
                toolWindowExpanded = true
            }
            .keyboardShortcut("k", modifiers: [.command])
            .disabled(repo == nil)
            .help("打开提交工具窗 (⌘K)")
            Button("Push", systemImage: "arrow.up.circle") {
                beginPushDialog()
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(repo == nil || remotes.isEmpty)
            .help("Push (⌘⇧K)")
            Button("Fetch", systemImage: "arrow.triangle.2.circlepath") {
                doFetch(nil)
            }
            .disabled(repo == nil || remotes.isEmpty)
            .help("Fetch")
        }
    }

    var currentBranchName: String {
        branches.first(where: { $0.isCurrent })?.name ?? "（无分支）"
    }

    private var hasAnyMultiRootCommitChanges: Bool {
        multiRootChangeGroups.contains { !$0.changedEntries.isEmpty }
    }

    private func openCommitWorkspaceFromBranchPopup() {
        showBranchesPopover = false
        toolWindowMode = .commit
        toolWindowExpanded = true
        projectPanelExpanded = false
    }

    /// The top-level Unstash dialog must switch to the root-qualified
    /// operations once the project has more than one discovered repository.
    /// A single-root window keeps the existing stash conflict surface.
    var useRootScopedUnstashActions: Bool {
        multiRoots.count > 1
    }

    var rebaseRepositories: [GitRootInfo] {
        multiRoots.count > 1 ? multiRoots : []
    }

    var rebaseBranchOptions: [BranchInfo] {
        guard let snapshot = multiRootBranchSnapshots.first(where: {
            $0.rootPath == rebaseRootPath
        }) else {
            return branches
        }
        return snapshot.branches
    }

    @ViewBuilder
    private var branchPopup: some View {
        Button {
            loadRepoData()
            if multiRoots.count > 1 {
                // The Branches Popup action group needs a current project-wide
                // status snapshot to update Commit Changes enablement. Do not
                // leave a stale empty multi-root snapshot looking clean.
                loadMultiRootChanges()
            }
            showBranchesPopover = true
        } label: {
            HStack(spacing: 7) {
                Label(currentBranchName, systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
                if incomingOutgoingInfoEnabled,
                   let sync = currentSyncStatus, sync.trackingExists,
                   sync.ahead > 0 || sync.behind > 0 {
                    HStack(spacing: 3) {
                        if sync.ahead > 0 {
                            Image(systemName: "arrow.up")
                            Text("\(sync.ahead)")
                        }
                        if sync.behind > 0 {
                            Image(systemName: "arrow.down")
                            Text("\(sync.behind)")
                        }
                        if currentBranchHasUnfetchedIncoming {
                            Image(systemName: "arrow.down")
                            Text("?")
                        }
                    }
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(sync.behind > 0 ? .blue : .green)
                } else if incomingOutgoingInfoEnabled, currentBranchHasUnfetchedIncoming {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down")
                        Text("?")
                    }
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.blue)
                    .help("Remote has incoming commits not fetched locally")
                }
            }
        }
        .buttonStyle(.borderless)
        .disabled(repo == nil)
        .help("Branches: checkout / pull / push / fetch / merge / rebase / stash")
        .popover(isPresented: $showBranchesPopover, arrowEdge: .bottom) {
            if multiRoots.count > 1 && !multiRootBranchSnapshots.isEmpty {
                MultiRootBranchesPopover(
                    projectPath: projectPath,
                    protectedBranchPatterns: effectiveProtectedBranchPatterns,
                    snapshots: multiRootBranchSnapshots,
                    incomingBranches: autoFetchIncomingBranches,
                    operationContexts: multiRoots.compactMap { root in
                        guard let kind = root.operation else { return nil }
                        return BranchPopupOperationContext(
                            rootPath: root.path,
                            displayName: root.displayName,
                            relativePath: root.relativePath,
                            kind: kind,
                            hasConflicts: multiRootConflictGroups.contains {
                                $0.rootPath == root.path && !$0.paths.isEmpty
                            }
                        )
                    },
                    onOperationAction: { rootPath, action in
                        handleVCSActionRequest(
                            ArborVCSActionRequest(
                                kind: .operationRecovery,
                                projectPath: projectPath,
                                rootPath: rootPath,
                                shelfName: "",
                                operationRecoveryAction: action.recoveryAction
                            )
                        )
                    },
                    onCommitChanges: {
                        showBranchesPopover = false
                        openMultiRootCommitDialog()
                    },
                    hasCommitChanges: hasAnyMultiRootCommitChanges,
                    onNewBranch: {
                        presentMultiRootNewBranchDialog()
                        showBranchesPopover = false
                    },
                    onFindMerged: {
                        beginFindMergedBranches()
                        showBranchesPopover = false
                    },
                    onRemoteTags: {
                        showBranchesPopover = false
                        showMultiRootRemoteTagsDialog = true
                    },
                    onCheckout: { rootPath, reference, isRemote in
                        checkoutBranchInRoot(
                            rootPath: rootPath,
                            reference: reference,
                            isRemote: isRemote
                        )
                        showBranchesPopover = false
                    },
                    onCheckoutAsNewBranch: { rootPath, reference, isRemote in
                        presentMultiRootNewBranchFromReference(
                            rootPath: rootPath,
                            reference: reference,
                            isRemote: isRemote
                        )
                    },
                    onCheckoutAndUpdate: { rootPath, reference, _, rebase in
                        executeMultiRootCheckoutAndUpdate(
                            reference: reference,
                            rootPath: rootPath,
                            detach: false,
                            rebase: rebase
                        )
                        showBranchesPopover = false
                    },
                    onCheckoutWithRebase: { rootPath, reference, isRemote in
                        if isRemote {
                            presentNewBranchFromReference(
                                reference,
                                isRemote: true,
                                afterCreateRebase: true,
                                rootPath: rootPath
                            )
                        } else {
                            executeMultiRootCheckoutWithRebase(
                                rootPath: rootPath,
                                branch: reference
                            )
                        }
                        showBranchesPopover = false
                    },
                    onCheckoutRecent: { rootPath, name in
                        checkoutRecentBranchInRoot(rootPath: rootPath, name: name)
                        showBranchesPopover = false
                    },
                    onCheckoutTag: { rootPath, name in
                        checkoutTagInRoot(rootPath: rootPath, name: name)
                        showBranchesPopover = false
                    },
                    onDeleteTag: { rootPath, name in
                        deleteTagInRoot(rootPath: rootPath, name: name)
                    },
                    onDeleteTagAcrossRoots: { name in
                        presentMultiRootDeleteTagDialog(name: name)
                        showBranchesPopover = false
                    },
                    onRenameTag: { rootPath, name in
                        renameTagInRoot(rootPath: rootPath, name: name)
                    },
                    onPushTag: { rootPath, name in
                        pushTagInRoot(rootPath: rootPath, name: name)
                    },
                    onPushTagToRemote: { rootPath, name, remote in
                        pushTagInRoot(rootPath: rootPath, name: name, remote: remote)
                    },
                    onShowDiffWithWorkingTree: { rootPath, name in
                        showBranchDiffWithWorkingTree(rootPath: rootPath, branch: name)
                    },
                    onPushAllTags: { rootPath, remote in
                        pushAllTagsInRoot(rootPath: rootPath, remote: remote)
                    },
                    onApplyStash: { rootPath, stashID, restoreIndex in
                        applyStashInRoot(rootPath: rootPath, stashID: stashID, restoreIndex: restoreIndex)
                    },
                    onPopStash: { rootPath, stashID, restoreIndex in
                        popStashInRoot(rootPath: rootPath, stashID: stashID, restoreIndex: restoreIndex)
                    },
                    onDropStash: { rootPath, stashID in
                        dropStashInRoot(rootPath: rootPath, stashID: stashID)
                    },
                    onStashBranch: { rootPath, stashID in
                        stashBranchInRoot(rootPath: rootPath, stashID: stashID)
                    },
                    onStashDiff: { rootPath, stashID in
                        showStashDiffInRoot(rootPath: rootPath, stashID: stashID)
                    },
                    onStashClear: { rootPath in
                        clearStashesInRoot(rootPath: rootPath)
                    },
                    onUpdateBranch: { rootPath, branch in
                        updateBranchInRoot(rootPath: rootPath, branch: branch)
                        showBranchesPopover = false
                    },
                    onForcePushedUpdate: { rootPath, branch in
                        updateForcePushedBranchInRoot(rootPath: rootPath, branch: branch)
                        showBranchesPopover = false
                    },
                    onForcePushedUpdateAcrossRoots: { branch in
                        updateForcePushedBranchAcrossRoots(branch)
                        showBranchesPopover = false
                    },
                    onPullBranch: { rootPath, branch, rebase in
                        pullBranchInRoot(rootPath: rootPath, branch: branch, rebase: rebase)
                        showBranchesPopover = false
                    },
                    onPullRemoteBranch: { rootPath, branch, rebase in
                        pullRemoteBranchInRoot(
                            rootPath: rootPath,
                            remoteBranch: branch,
                            rebase: rebase
                        )
                        showBranchesPopover = false
                    },
                    onDeleteRemote: { rootPath, branch in
                        deleteRemoteBranchInRoot(rootPath: rootPath, branch: branch)
                        showBranchesPopover = false
                    },
                    onDeleteRemoteAcrossRoots: { branch in
                        presentMultiRootRemoteDeleteDialog(branch: branch)
                        showBranchesPopover = false
                    },
                    onMerge: { rootPath, branch in
                        mergeBranchInRoot(rootPath: rootPath, branch: branch)
                        showBranchesPopover = false
                    },
                    onMergeAcrossRoots: presentMultiRootMergeFromPopup,
                    onRebase: { rootPath, branch in
                        rebaseCurrentInRoot(rootPath: rootPath, onto: branch)
                        showBranchesPopover = false
                    },
                    onCompare: { rootPath, branch in
                        compareBranchInRoot(rootPath: rootPath, branch: branch)
                        showBranchesPopover = false
                    },
                    onCompareSelected: { selection in
                        guard selection.count == 2,
                              let first = selection.first,
                              selection.allSatisfy({ $0.rootPath == first.rootPath }) else { return }
                        compareBranchesCommitWiseInRoot(
                            rootPath: first.rootPath,
                            first: first.name,
                            second: selection[1].name
                        )
                        showBranchesPopover = false
                    },
                    onCompareSelectedFiles: { selection in
                        guard selection.count == 2,
                              let first = selection.first,
                              selection.allSatisfy({ $0.rootPath == first.rootPath }) else { return }
                        compareBranchesInRoot(
                            rootPath: first.rootPath,
                            first: first.name,
                            second: selection[1].name
                        )
                        showBranchesPopover = false
                    },
                    onUpdateSelected: { selection in
                        updateSelectedBranchesInRoots(selection)
                        showBranchesPopover = false
                    },
                    onDeleteSelected: { selection in
                        deleteSelectedBranchesInRoots(selection)
                        showBranchesPopover = false
                    },
                    onPushDialog: { rootPath, branch in
                        beginMultiRootPushDialog(rootPath: rootPath, branch: branch)
                        showBranchesPopover = false
                    },
                    onEditRemote: { rootPath, name in
                        beginMultiRootRemoteConfig(rootPath: rootPath, selectedRemote: name)
                        showBranchesPopover = false
                    },
                    onRemoveRemote: { rootPath, name in
                        removeRemoteInRoot(rootPath: rootPath, name: name)
                    },
                    onRemoveRemoteSelected: { groups in
                        removeSelectedRemotesInRoots(groups)
                    },
                    onConfigureRemotes: {
                        beginConfigureRemotes()
                    },
                    onSetUpstream: { rootPath, branch in
                        setBranchUpstreamInRoot(rootPath: rootPath, branch: branch)
                        showBranchesPopover = false
                    },
                    onUnsetUpstream: { rootPath, branch in
                        unsetBranchUpstreamInRoot(rootPath: rootPath, branch: branch)
                        showBranchesPopover = false
                    },
                    onRenameBranch: { rootPath, branch in
                        renameBranchInRoot(rootPath: rootPath, oldName: branch)
                        showBranchesPopover = false
                    },
                    onRenameBranchAcrossRoots: { name in
                        presentMultiRootRenameBranchDialog(name: name)
                        showBranchesPopover = false
                    },
                    onDeleteBranchAcrossRoots: { name in
                        presentMultiRootDeleteBranchDialog(name: name)
                        showBranchesPopover = false
                    },
                    onDeleteBranch: { rootPath, branch in
                        deleteBranchInRoot(rootPath: rootPath, name: branch)
                        showBranchesPopover = false
                    },
                    onCheckoutReference: { rootPath in
                        checkoutReferenceFromInput(rootPath: rootPath)
                    },
                    onOpenWorktree: { path in
                        showBranchesPopover = false
                        openWindow(value: path)
                    },
                    onCreateWorktreeFromReference: { rootPath, reference, isTag in
                        showBranchesPopover = false
                        presentNewWorktreeFromReference(
                            reference,
                            isTag: isTag,
                            rootPath: rootPath
                        )
                    },
                    onProjectGitSettings: {
                        showBranchesPopover = false
                        showProjectGitSettings = true
                    },
                    onCancel: { showBranchesPopover = false }
                )
            } else {
                RebasedBranchesPopover(
                projectPath: projectPath,
                branches: branches,
                remoteBranches: remoteBranches,
                recentBranches: recentBranches,
                tags: tags,
                comparisons: branchComparisons,
                syncStatuses: syncStatuses,
                incomingBranches: autoFetchIncomingBranches,
                stashes: stashes,
                worktrees: worktrees,
                hasRemote: !remotes.isEmpty,
                protectedBranchPatterns: effectiveProtectedBranchPatterns,
                isShallow: isShallowRepository,
                hasHeadCommit: headId != nil,
                hasCommitChanges: vcsActionContext.hasLocalChanges,
                onCheckout: switchBranch,
                onRenameBranch: renameBranchFromPopup,
                onDeleteBranch: deleteBranchFromPopup,
                onCheckoutRecent: checkoutRecentBranch,
                onCheckoutTag: checkoutTag,
                onCheckoutAsNewBranch: { reference, isRemote in
                    presentNewBranchFromReference(reference, isRemote: isRemote)
                },
                onDeleteTag: tagDelete,
                onRenameTag: { old in
                    let alert = NSAlert()
                    alert.messageText = "Rename Tag"
                    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
                    field.stringValue = old
                    alert.accessoryView = field
                    alert.addButton(withTitle: "Rename")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        tagRename(old, field.stringValue)
                    }
                },
                onPushTag: { tag in tagPushToRemote(tag) },
                tagPushRemotes: remotes.map(\.name),
                onPushTagToRemote: { tag, remote in
                    tagPushToRemote(tag, remote: remote)
                },
                onShowDiffWithWorkingTree: { branch in
                    showBranchDiffWithWorkingTree(rootPath: nil, branch: branch)
                },
                onPushAllTags: { remote in
                    pushAllTagsToRemote(remote: remote)
                },
                onRemoteTags: {
                    showBranchesPopover = false
                    showRemoteTagsDialog = true
                },
                onCheckoutAndUpdate: { branch, rebase in checkoutAndUpdate(branch, rebase: rebase) },
                onUpdateBranch: updateSelectedBranch,
                onPushBranch: { branch in beginPushDialog(branch: branch) },
                onForcePushedUpdate: updateForcePushedBranch,
                onPullRemoteBranch: { branch, rebase in pullRemoteBranch(branch, rebase: rebase) },
                onCheckoutRemote: checkoutRemoteBranch,
                onCheckoutRemoteWithRebase: { branch in
                    presentNewBranchFromReference(
                        branch.name,
                        isRemote: true,
                        afterCreateRebase: true
                    )
                },
                onDeleteRemote: deleteRemoteBranch,
                onNewBranch: { presentNewBranchDialog() },
                onCommitChanges: openCommitWorkspaceFromBranchPopup,
                onFindMerged: {
                    beginFindMergedBranches()
                    showBranchesPopover = false
                },
                onCheckoutReference: checkoutReferenceFromInput,
                onOpenWorktree: { path in
                    showBranchesPopover = false
                    openWindow(value: path)
                },
                onCreateWorktreeFromReference: { reference, isTag in
                    showBranchesPopover = false
                    presentNewWorktreeFromReference(reference, isTag: isTag)
                },
                onCompare: compareBranchFromPopup,
                onMerge: openMergeDialog,
                onRebase: openRebaseDialog,
                onStash: presentStashDialog,
                onApplyStash: { stashID, restoreIndex in stashApply(stashID: stashID, restoreIndex: restoreIndex) },
                onPopStash: { stashID, restoreIndex in stashPop(stashID: stashID, restoreIndex: restoreIndex) },
                onDropStash: stashDrop(stashID:),
                onStashBranch: stashBranch(stashID:),
                onStashDiff: showStashDiffFor(stashID:),
                onStashClear: stashClearAll,
                onNewTag: beginNewTagDialog,
                onShelve: { showShelveDialog = true },
                onUpdate: { doPull(nil, rebase: $0) },
                onPush: { beginPushDialog() },
                onFetch: { doFetch(nil) },
                onRefresh: { loadRepoData() },
                onConfigureRemotes: beginConfigureRemotes,
                onProjectGitSettings: {
                    showBranchesPopover = false
                    showProjectGitSettings = true
                },
                onFetchAll: { doFetchAll() },
                onFetchPrune: doFetchPrune,
                onFetchUnshallow: doFetchUnshallow,
                onSetUpstream: { branch in
                    upstreamLocalBranch = branch
                    showUpstreamDialog = true
                },
                onUnsetUpstream: unsetBranchUpstream,
                operationState: operationState,
                onOperationContinue: {
                    doOperationContinue()
                    showBranchesPopover = false
                },
                onOperationSkip: {
                    doOperationSkip()
                    showBranchesPopover = false
                },
                onOperationAbort: {
                    doOperationAbort()
                    showBranchesPopover = false
                }
                )
            }
        }
    }

    private var remoteConfigSheet: some View {
        Group {
            if repo != nil {
                RemoteConfigDialogView(
                    remotes: remotes,
                    name: $remoteName,
                    url: $remoteUrl,
                    pushUrl: $remotePushUrl,
                    fetchRefspec: $remoteFetchRefspec,
                    pushRefspec: $remotePushRefspec,
                    initialSelectedName: nil,
                    onAdd: remoteAdd,
                    onRemove: remoteRemove,
                    onRename: remoteRename,
                    onSave: saveRemoteConfig,
                    onCancel: { showRemoteConfigDialog = false },
                    onRefresh: loadRemotes
                )
            }
        }
    }

    private func saveUpstreamFromDialog(_ upstream: String) {
        let branch = upstreamLocalBranch
        showUpstreamDialog = false
        setBranchUpstream(branch, upstream: upstream)
    }

    private var rebaseTodoSheet: some View {
        Group {
            if let repo {
                RebaseTodoEditorView(
                    repo: repo,
                    onto: rebaseTodoOnto,
                    items: $rebaseTodoItems,
                    preserveMerges: rebaseTodoPreserveMerges,
                    root: rebaseTodoRoot,
                    onStart: startTodoRebase,
                    onOpenRawTodo: prepareRawRebaseTodoEditor,
                    onCancel: { showRebaseTodoEditor = false }
                )
            }
        }
    }

    private var rebaseRawTodoSheet: some View {
        RawRebaseTodoEditorView(
            onto: rebaseTodoOnto,
            text: $rebaseRawTodoText,
            preserveMerges: rebaseTodoPreserveMerges,
            root: rebaseTodoRoot,
            onStart: startRawTodoRebase,
            onCancel: {
                showRawRebaseTodoEditor = false
                rebaseRawTodoText = ""
            }
        )
    }

    /// IDX-001 二进制文件路径集合（staging model 提供）。
    private var stagingBinaryPaths: Set<String> {
        Set((stagingModel?.entries ?? []).filter { $0.binary }.map { $0.path })
    }

    /// IDX-001: expose exact HEAD/index/worktree presence to Changes actions;
    /// status kinds alone cannot distinguish an empty file from a missing side.
    private var stagingPresenceByPath: [String: StagingVersionPresence] {
        Dictionary(
            uniqueKeysWithValues: (stagingModel?.entries ?? []).map { entry in
                (entry.path, stagingVersionPresence(for: entry))
            }
        )
    }

    private var fileContentVersionOptions: [FileContentVersion] {
        guard let path = fileSelection,
              let entry = entries.first(where: { $0.path == path }) else {
            return [fileSelectionVersion]
        }
        return fileContentVersions(
            for: stagingVersionActions(
                for: entry,
                presence: stagingPresenceByPath[path]
            ),
            current: fileSelectionVersion
        )
    }

    /// CONFLICT-001：merge/rebase/cherry-pick/revert 进入同一冲突工作台。
    private var mergeRevisionsMode: MergeRevisionsDialogView.Mode {
        if stashPopConflictInProgress || stashApplyConflictInProgress {
            return .stashRestore
        }
        if shelveConflictInProgress {
            if shelveConflictIsDirectPatch {
                return .applyPatch
            }
            return .shelveRestore(isPop: shelveConflictIsPop)
        }
        switch operationState?.kind {
        case .rebase: return .rebase
        case .cherryPick: return .cherryPick
        case .revert: return .revert
        default: return .merge
        }
    }

    private var mergeRevisionsAbortAction: (() -> Void)? {
        if shelveConflictInProgress {
            return { abortShelveConflict() }
        }
        if stashPopConflictInProgress || stashApplyConflictInProgress {
            return nil
        }
        return {
            doOperationAbort()
            showMergeRevisionsDialog = false
        }
    }

    /// IntelliJ keeps the conflict resolver in a non-modal tool window: the
    /// user can hide it, inspect the rest of the project, and reopen it from
    /// the operation bar or conflict notification without changing the
    /// in-progress Git state. Keep
    /// the resolver itself as the single source of truth and only change its
    /// presentation here.
    @ViewBuilder
    private var conflictResolverOverlays: some View {
        if showMergeRevisionsDialog {
            singleRootConflictResolverPanel
        }
        if showMultiRootConflictResolver {
            multiRootConflictResolverPanel
        }
    }

    @ViewBuilder
    private var singleRootConflictResolverPanel: some View {
        if let repo = pendingShelveConflictRepository ?? self.repo {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Resolve Conflicts")
                        .font(.headline)
                    Text(mergeRevisionsMode.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Close") {
                        showMergeRevisionsDialog = false
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                Divider()
                MergeRevisionsDialogView(
                    repo: repo,
                    entries: $entries,
                    initialPath: mergeInitialPath ?? selection,
                    mode: mergeRevisionsMode,
                    directPatchText: shelveConflictIsDirectPatch ? pendingShelveConflictPatch : nil,
                    directPatchRestoreName: shelveConflictIsDirectPatch ? pendingShelveConflictName : nil,
                    onChanged: {
                        if shelveConflictInProgress {
                            refreshShelveConflictStatus()
                        } else {
                            refreshAll()
                        }
                    },
                    onComplete: {
                        if shelveConflictInProgress {
                            finishShelveConflict()
                        } else {
                            doOperationContinue()
                            showMergeRevisionsDialog = false
                            mergeInitialPath = nil
                        }
                    },
                    onAbort: mergeRevisionsAbortAction,
                    onSkip: nil,
                    compact: true
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 1000, height: 680)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.16), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
            .padding(14)
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .zIndex(20)
        }
    }

    @ViewBuilder
    private var multiRootConflictResolverPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Git Roots Conflicts")
                    .font(.headline)
                Spacer()
                Button("Close", action: closeMultiRootResolver)
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()
            MultiRootConflictResolverView(
                roots: multiRootResolverRoots,
                activeRootPath: multiRootResolverActiveRootPath,
                activeRepo: multiRootResolverActiveRepo,
                entries: $multiRootResolverActiveEntries,
                initialPath: multiRootResolverActiveInitialPath,
                activeKind: multiRootResolverActiveKind,
                isWorking: multiRootResolverWorking,
                error: multiRootResolverError,
                onSelectRoot: selectMultiRootResolverRoot,
                onChanged: refreshMultiRootResolverActiveRoot,
                onComplete: completeMultiRootResolverRoot,
                onSkip: skipMultiRootResolverRoot,
                onAbort: abortMultiRootResolverRoot,
                onClose: closeMultiRootResolver,
                compact: true
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 1060, height: 700)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.16), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        .padding(14)
        .transition(.move(edge: .trailing).combined(with: .opacity))
        .zIndex(21)
    }

    func openMergeDialog(_ branch: String?) {
        guard operationState?.kind == nil,
              isArborVCSActionVisible(.merge, in: vcsActionContext),
              isArborVCSActionEnabled(.merge, in: vcsActionContext) else { return }
        loadMergeDialogSettings(for: projectPath)
        if let branch { mergeBranch = branch }
        mergeDialogGeneration &+= 1
        let generation = mergeDialogGeneration
        mergeMergedBranches = []
        showMergeActionDialog = true
        guard let repo else { return }
        Task.detached(priority: .userInitiated) {
            let mergedBranches = (try? repo.branchListMerged().map(\.name)) ?? []
            await MainActor.run {
                guard generation == self.mergeDialogGeneration else { return }
                self.mergeMergedBranches = Set(mergedBranches)
            }
        }
    }

    func loadMergeDialogSettings(for projectPath: String?) {
        let settings = GitMergeDialogSettingsStore.load(for: projectPath)
        mergeBranch = settings.branch
        mergeStrategyRaw = settings.strategyRaw
        mergeUseCustomCommitMessage = settings.useCustomCommitMessage
        mergeNoCommit = settings.noCommit
        mergeNoVerify = settings.noVerify
        mergeAllowUnrelatedHistories = settings.allowUnrelatedHistories
        if !mergeUseCustomCommitMessage {
            mergeCommitMessage = ""
        }
    }

    func saveMergeDialogSettings() {
        GitMergeDialogSettingsStore.save(
            GitMergeDialogSettings(
                branch: mergeBranch,
                strategyRaw: mergeStrategyRaw,
                useCustomCommitMessage: mergeUseCustomCommitMessage,
                noCommit: mergeNoCommit,
                noVerify: mergeNoVerify,
                allowUnrelatedHistories: mergeAllowUnrelatedHistories
            ),
            for: projectPath
        )
    }

    func loadRebaseDialogSettings(for projectPath: String?) {
        let settings = GitRebaseDialogSettingsStore.load(for: projectPath)
        rebaseOnto = settings.onto
        rebaseInteractive = settings.interactive
        rebasePreserveMerges = settings.preserveMerges
        rebaseAutoSquash = settings.autoSquash
        rebaseKeepEmpty = settings.keepEmpty
        rebaseUpdateRefs = settings.updateRefs
        rebaseRoot = settings.root
    }

    func saveRebaseDialogSettings() {
        GitRebaseDialogSettingsStore.save(
            GitRebaseDialogSettings(
                onto: rebaseOnto,
                interactive: rebaseInteractive,
                preserveMerges: rebasePreserveMerges,
                autoSquash: rebaseAutoSquash,
                keepEmpty: rebaseKeepEmpty,
                updateRefs: rebaseUpdateRefs,
                root: rebaseRoot
            ),
            for: projectPath
        )
    }

    func openRebaseDialog(_ branch: String?) {
        guard operationState?.kind == nil,
              isArborVCSActionVisible(.rebase, in: vcsActionContext),
              isArborVCSActionEnabled(.rebase, in: vcsActionContext) else { return }
        loadRebaseDialogSettings(for: projectPath)
        if let branch { rebaseOnto = branch }
        rebaseRootPath = repo?.workdir() ?? multiRoots.first?.path ?? ""
        rebaseBranch = rebaseBranchOptions.first(where: { $0.isCurrent })?.name
            ?? rebaseBranchOptions.first?.name
            ?? ""
        rebaseApplyToAllRoots = false
        rebaseRange = []
        rebaseActions = []
        rebaseFeedback = nil
        showRebaseActionDialog = true
    }

    private func selectRebaseRepository() {
        let snapshot = multiRootBranchSnapshots.first(where: {
            $0.rootPath == rebaseRootPath
        })
        rebaseBranch = snapshot?.headBranch
            ?? snapshot?.branches.first(where: { $0.isCurrent })?.name
            ?? snapshot?.branches.first?.name
            ?? ""
        invalidateLoadedRebaseRange()
    }

    private func compareBranchFromPopup(_ branch: String) {
        toolWindowMode = .log
        toolWindowExpanded = true
        projectPanelExpanded = false
        compareLogBranch(rootPath: nil, branch: branch)
        showBranchesPopover = false
    }

    func renameBranchFromPopup(_ oldName: String) {
        let alert = NSAlert()
        alert.messageText = "Rename Branch"
        let field = NSTextField(string: oldName)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != oldName else { return }
        renameOld = oldName
        renameNew = newName
        branchRename()
    }

    private func deleteBranchFromPopup(_ name: String) {
        let alert = NSAlert()
        alert.messageText = "Delete branch \(name)?"
        alert.informativeText = "This removes the local branch reference. Unmerged commits are not deleted from the object database immediately."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        branchDelete(name)
    }

    private func handleBranchCleanupAction(_ action: BranchCleanupWindowAction?) {
        guard let action else { return }
        branchCleanupWindow.action = nil
        switch action {
        case let .calculate(target, prefix):
            calculateBranchCleanup(target: target, prefix: prefix)
        case let .delete(selections):
            deleteBranchCleanup(selections)
        case .refresh:
            refreshBranchCleanup()
        }
    }

}

// MARK: - 可编辑三栏合并编辑器（NSTextView + TextKit 2）

/// 本地解析的冲突块（行号 + 两侧内容）。编辑后行号会漂移，每次操作前重解析，不缓存。
struct SwiftConflictBlock: Identifiable {
    let index: Int          // 在当前文本中的块下标
    let lineStart: Int      // <<<<<<< 行（0-based）
    let lineEnd: Int        // >>>>>>> 行的下一行（0-based，splice 用）
    let oursLines: [String]
    let theirsLines: [String]
    var id: Int { index }
}

/// 块接受方向（「两者」= ours+theirs 拼接，UI 侧操作，非引擎 PickKind）。
enum AcceptSide: Equatable { case ours, theirs, both }

/// Apply Patch 的稳定 hunk 状态。`pending`/`alreadyApplied`/`notApplied`
/// 是当前 result 文本相对于 patch 的判定；其余三种是用户在当前 viewer
/// 会话中的 resolved 状态。
enum ApplyPatchHunkResolution: Equatable {
    case pending
    case alreadyApplied
    case notApplied
    case applied
    case automaticallyApplied
    case ignored

    var isResolved: Bool {
        switch self {
        case .applied, .automaticallyApplied, .ignored: return true
        case .pending, .alreadyApplied, .notApplied: return false
        }
    }

    var title: String {
        switch self {
        case .pending: return "Ready to apply"
        case .alreadyApplied: return "Already applied"
        case .notApplied: return "Not applied"
        case .applied: return "Applied"
        case .automaticallyApplied: return "Applied automatically"
        case .ignored: return "Ignored"
        }
    }
}

struct ApplyPatchConflictHunk: Identifiable, Equatable {
    let path: String
    let index: UInt32
    let header: String
    let oldStart: UInt32
    let newStart: UInt32
    let oldLines: [String]
    let newLines: [String]
    let oldChangedLines: [String]
    let newChangedLines: [String]
    var resolution: ApplyPatchHunkResolution

    var id: String { "\(path)#\(index)" }
}

/// Pure patch-hunk model used by the direct Apply Patch conflict viewer.
/// Matching is intentionally bounded around the hunk's expected line, just as
/// the differentiated patch flow does when selecting a base candidate.
enum ApplyPatchConflictHunkModel {
    static func editorPatchText(patch: String, path: String) -> String {
        RebasedUnshelveDialog
            .parsePatchFiles(patch, allowedPaths: [path])
            .first(where: { $0.path == path })?
            .rawPatch ?? patch
    }

    static func patchHunkLineRange(in patchText: String, index: UInt32) -> Range<Int>? {
        let lines = splitLines(patchText)
        let headers = lines.indices.filter { lines[$0].hasPrefix("@@") }
        let hunkIndex = Int(index)
        guard hunkIndex >= 0, hunkIndex < headers.count else { return nil }
        let start = headers[hunkIndex]
        let end = headers.drop { $0 <= start }.first ?? lines.count
        return start..<end
    }

    static func patchHunkIndex(in patchText: String, atPatchLine line: Int) -> UInt32? {
        guard line >= 0 else { return nil }
        let lines = splitLines(patchText)
        let headers = lines.indices.filter { lines[$0].hasPrefix("@@") }
        guard let index = headers.firstIndex(of: line) else { return nil }
        return UInt32(index)
    }

    static func clipboardText(for hunk: ApplyPatchConflictHunk) -> String? {
        let lines = hunk.newChangedLines.isEmpty ? hunk.newLines : hunk.newChangedLines
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n") + "\n"
    }

    static func restoredResolution(
        for hunk: ApplyPatchConflictHunk,
        from persisted: [ShelveRestoreHunkResolution]
    ) -> ApplyPatchHunkResolution? {
        guard let item = persisted.first(where: {
            $0.path == hunk.path && $0.hunkIndex == hunk.index
        }) else { return nil }
        switch item.resolution {
        case "applied": return .applied
        case "automatically_applied": return .automaticallyApplied
        case "ignored": return .ignored
        default: return nil
        }
    }

    static func parse(patch: String, path: String, result: String) -> [ApplyPatchConflictHunk] {
        guard let file = RebasedUnshelveDialog
            .parsePatchFiles(patch, allowedPaths: [path])
            .first(where: { $0.path == path }),
            let diff = RebasedPatchDiffParser.parse(patch: file.rawPatch, path: path) else {
            return []
        }

        return diff.hunks.enumerated().map { offset, hunk in
            let oldLines = hunk.oldLines.map(\.text)
            let newLines = hunk.newLines.map(\.text)
            let oldChangedLines = hunk.oldLines
                .filter { $0.kind == .deletion }
                .map(\.text)
            let newChangedLines = hunk.newLines
                .filter { $0.kind == .addition }
                .map(\.text)
            let header = file.hunks.indices.contains(offset)
                ? file.hunks[offset].header
                : "@@ -\(hunk.oldStart) +\(hunk.newStart) @@"
            var item = ApplyPatchConflictHunk(
                path: path,
                index: UInt32(offset),
                header: header,
                oldStart: hunk.oldStart,
                newStart: hunk.newStart,
                oldLines: oldLines,
                newLines: newLines,
                oldChangedLines: oldChangedLines,
                newChangedLines: newChangedLines,
                resolution: .notApplied
            )
            item.resolution = status(of: item, in: result)
            return item
        }
    }

    static func status(
        of hunk: ApplyPatchConflictHunk,
        in text: String
    ) -> ApplyPatchHunkResolution {
        let lines = splitLines(text)
        let oldExpected = Int(hunk.oldStart == 0 ? 0 : hunk.oldStart - 1)
        let newExpected = Int(hunk.newStart == 0 ? 0 : hunk.newStart - 1)

        if !hunk.oldLines.isEmpty,
           findLineRange(hunk.oldLines, in: lines, expectedStart: oldExpected) != nil {
            return .pending
        }
        if findLineRange(hunk.newLines, in: lines, expectedStart: newExpected) != nil {
            return .alreadyApplied
        }
        if hunk.oldLines.isEmpty, oldExpected <= lines.count {
            return .pending
        }
        return .notApplied
    }

    static func findLineRange(
        _ sequence: [String],
        in lines: [String],
        expectedStart: Int,
        maxWalk: Int = 100
    ) -> Range<Int>? {
        if sequence.isEmpty {
            guard expectedStart >= 0, expectedStart <= lines.count else { return nil }
            return expectedStart..<expectedStart
        }
        guard sequence.count <= lines.count else { return nil }
        let lastStart = lines.count - sequence.count
        let lower = max(0, expectedStart - maxWalk)
        let upper = min(lastStart, expectedStart + maxWalk)
        guard lower <= upper else { return nil }
        for start in lower...upper {
            if Array(lines[start..<(start + sequence.count)]) == sequence {
                return start..<(start + sequence.count)
            }
        }
        return nil
    }
}

/// 匹配 Rust str::lines() 的行切分：按 \n 切，去掉尾随 \n 产生的空串。
func splitLines(_ text: String) -> [String] {
    var lines = text.components(separatedBy: "\n")
    if text.hasSuffix("\n") { lines.removeLast() }
    return lines
}

/// 解析冲突 marker 成块（与引擎 parse_marker_blocks 同语义）。
func parseConflictMarkers(_ text: String) -> [SwiftConflictBlock] {
    let lines = splitLines(text)
    var blocks: [SwiftConflictBlock] = []
    var i = 0
    var blockIdx = 0
    while i < lines.count {
        if lines[i].hasPrefix("<<<<<<<") {
            let start = i
            i += 1
            var ours: [String] = []
            while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces) != "=======" {
                ours.append(lines[i]); i += 1
            }
            if i >= lines.count { break }
            i += 1 // 跳过 =======
            var theirs: [String] = []
            while i < lines.count && !lines[i].hasPrefix(">>>>>>>") {
                theirs.append(lines[i]); i += 1
            }
            if i >= lines.count { break }
            let end = i + 1 // >>>>>>> 行的下一行
            blocks.append(SwiftConflictBlock(index: blockIdx, lineStart: start, lineEnd: end,
                                             oursLines: ours, theirsLines: theirs))
            blockIdx += 1
            i = end
        } else {
            i += 1
        }
    }
    return blocks
}

/// 按 \n 计算每行的字符范围（UTF-16 NSRange，含行尾 \n；与 splitLines 行号对齐）。
func lineCharRanges(_ text: String) -> [NSRange] {
    let ns = text as NSString
    var ranges: [NSRange] = []
    var lineStart = 0
    for i in 0..<ns.length {
        if ns.character(at: i) == 0x000A {
            ranges.append(NSRange(location: lineStart, length: i - lineStart + 1))
            lineStart = i + 1
        }
    }
    if lineStart < ns.length {
        ranges.append(NSRange(location: lineStart, length: ns.length - lineStart))
    }
    return ranges
}

private func characterRange(for lineRange: Range<Int>, in text: String) -> NSRange? {
    let ranges = lineCharRanges(text)
    guard !ranges.isEmpty,
          lineRange.lowerBound >= 0,
          lineRange.upperBound <= ranges.count,
          lineRange.lowerBound < lineRange.upperBound else { return nil }
    let start = ranges[lineRange.lowerBound].location
    let end = NSMaxRange(ranges[lineRange.upperBound - 1])
    return NSRange(location: start, length: end - start)
}

/// 对 NSTextView 应用 tree-sitter 语法高亮（前景色；字节偏移转 UTF-16 NSRange）。
/// 复用引擎 HighlightSpan + SyntaxHighlight 调色板。静默降级（未知语言/超长/失败 -> 空）。
private func applySyntaxHighlight(to tv: NSTextView?, path: String) {
    guard let tv, let ts = tv.textStorage else { return }
    let text = tv.string
    let spans = highlightCode(content: text, path: path)
    guard !spans.isEmpty else { return }
    let utf8 = text.utf8
    let nsLen = (text as NSString).length
    for s in spans {
        guard let startIdx = utf8.index(utf8.startIndex, offsetBy: Int(s.start), limitedBy: utf8.endIndex),
              let endIdx = utf8.index(utf8.startIndex, offsetBy: Int(s.end), limitedBy: utf8.endIndex) else { continue }
        let start16 = text.utf16.distance(from: text.utf16.startIndex, to: startIdx)
        let end16 = text.utf16.distance(from: text.utf16.startIndex, to: endIdx)
        let len = end16 - start16
        if start16 >= 0, len > 0, start16 + len <= nsLen {
            ts.addAttribute(.foregroundColor, value: SyntaxHighlight.color(for: s.kind),
                            range: NSRange(location: start16, length: len))
        }
    }
}

private func applyPatchHighlight(to tv: NSTextView?) {
    guard let tv, let textStorage = tv.textStorage else { return }
    let text = tv.string
    let ranges = lineCharRanges(text)
    let lines = splitLines(text)
    textStorage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: textStorage.length))
    for (index, line) in lines.enumerated() where index < ranges.count {
        let color: NSColor?
        if line.hasPrefix("@@") {
            color = NSColor.systemBlue.withAlphaComponent(0.16)
        } else if line.hasPrefix("+++") || line.hasPrefix("---") {
            color = NSColor.systemGray.withAlphaComponent(0.12)
        } else if line.hasPrefix("+") {
            color = NSColor.systemGreen.withAlphaComponent(0.16)
        } else if line.hasPrefix("-") {
            color = NSColor.systemRed.withAlphaComponent(0.16)
        } else {
            color = nil
        }
        if let color {
            textStorage.addAttribute(.backgroundColor, value: color, range: ranges[index])
        }
    }
}

private enum ApplyPatchGutterAction {
    case apply
    case copy
    case ignore
}

/// Patch editor 的轻量 gutter。IntelliJ 把逐 hunk 操作放在 Patch 编辑器
/// gutter；这里使用覆盖在 NSScrollView 上的 AppKit view，避免引入 TextKit 1
/// layout manager。行高固定为编辑器字体的默认行高，Patch pane 关闭软换行，
/// 因而 gutter 行号与 raw patch 行号保持一一对应。
private final class ApplyPatchGutterView: NSView {
    static let width: CGFloat = 48

    weak var textView: NSTextView?
    var hunks: [ApplyPatchConflictHunk] = [] {
        didSet { needsDisplay = true }
    }
    var onSelect: ((ApplyPatchConflictHunk) -> Void)?
    var onApply: ((ApplyPatchConflictHunk) -> Void)?
    var onCopy: ((ApplyPatchConflictHunk) -> Void)?
    var onIgnore: ((ApplyPatchConflictHunk) -> Void)?
    var scrollOriginY: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    func update(textView: NSTextView, scrollOriginY: CGFloat) {
        self.textView = textView
        self.scrollOriginY = scrollOriginY
        needsDisplay = true
    }

    private var lineHeight: CGFloat {
        max(1, ceil(textView?.font?.boundingRectForFont.height ?? 14))
    }

    private func documentY(for line: Int) -> CGFloat {
        let inset = textView?.textContainerInset.height ?? 0
        return inset + CGFloat(line) * lineHeight
    }

    private func visibleY(for line: Int) -> CGFloat {
        documentY(for: line) - scrollOriginY
    }

    private func hunk(at point: NSPoint) -> (ApplyPatchConflictHunk, ApplyPatchGutterAction)? {
        let line = Int(floor((point.y + scrollOriginY - (textView?.textContainerInset.height ?? 0)) / lineHeight))
        guard line >= 0 else { return nil }
        guard let index = ApplyPatchConflictHunkModel.patchHunkIndex(
            in: textView?.string ?? "",
            atPatchLine: line
        ), let hunk = hunks.first(where: { $0.index == index }) else { return nil }
        let action: ApplyPatchGutterAction = point.x < Self.width / 2
            ? (hunk.resolution == .pending ? .apply : .copy)
            : .ignore
        return (hunk, action)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()

        NSColor.separatorColor.setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: bounds.maxX - 0.5, y: dirtyRect.minY))
        divider.line(to: NSPoint(x: bounds.maxX - 0.5, y: dirtyRect.maxY))
        divider.stroke()

        for hunk in hunks {
            guard let range = ApplyPatchConflictHunkModel.patchHunkLineRange(
                in: textView?.string ?? "",
                index: hunk.index
            ) else { continue }
            let y = visibleY(for: range.lowerBound)
            let row = NSRect(x: 1, y: y + 1, width: Self.width - 2, height: lineHeight - 2)
            guard row.intersects(dirtyRect) else { continue }

            drawStatusDot(at: NSPoint(x: 7, y: row.midY), resolution: hunk.resolution)
            guard !hunk.resolution.isResolved else { continue }
            let operationRect = NSRect(x: 14, y: row.minY + 2, width: 13, height: 13)
            if hunk.resolution == .pending {
                drawCheckmark(in: operationRect, enabled: true)
            } else {
                drawCopy(in: operationRect, enabled: true)
            }
            drawCross(in: NSRect(x: 31, y: row.minY + 2, width: 13, height: 13), enabled: true)
        }
    }

    private func drawStatusDot(at point: NSPoint, resolution: ApplyPatchHunkResolution) {
        let color: NSColor
        switch resolution {
        case .pending: color = .systemOrange
        case .alreadyApplied, .automaticallyApplied, .applied: color = .systemGreen
        case .notApplied: color = .systemRed
        case .ignored: color = .secondaryLabelColor
        }
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)).fill()
    }

    private func drawCheckmark(in rect: NSRect, enabled: Bool) {
        (enabled ? NSColor.systemGreen : NSColor.tertiaryLabelColor).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.8
        path.move(to: NSPoint(x: rect.minX + 2, y: rect.midY))
        path.line(to: NSPoint(x: rect.minX + 5, y: rect.minY + 3))
        path.line(to: NSPoint(x: rect.maxX - 2, y: rect.maxY - 3))
        path.stroke()
    }

    private func drawCross(in rect: NSRect, enabled: Bool) {
        (enabled ? NSColor.systemRed : NSColor.tertiaryLabelColor).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.6
        path.move(to: NSPoint(x: rect.minX + 3, y: rect.minY + 3))
        path.line(to: NSPoint(x: rect.maxX - 3, y: rect.maxY - 3))
        path.move(to: NSPoint(x: rect.maxX - 3, y: rect.minY + 3))
        path.line(to: NSPoint(x: rect.minX + 3, y: rect.maxY - 3))
        path.stroke()
    }

    private func drawCopy(in rect: NSRect, enabled: Bool) {
        (enabled ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.4
        path.appendRoundedRect(
            NSRect(x: rect.minX + 4, y: rect.minY + 2, width: 7, height: 9),
            xRadius: 1.5,
            yRadius: 1.5
        )
        path.appendRoundedRect(
            NSRect(x: rect.minX + 2, y: rect.minY + 4, width: 7, height: 9),
            xRadius: 1.5,
            yRadius: 1.5
        )
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let (hunk, action) = hunk(at: point) else {
            super.mouseDown(with: event)
            return
        }
        onSelect?(hunk)
        switch action {
        case .apply: onApply?(hunk)
        case .copy: onCopy?(hunk)
        case .ignore: onIgnore?(hunk)
        }
    }
}

/// NSTextView 的命令式桥接（SwiftUI <-> AppKit）。
/// 持有结果栏 NSTextView 弱引用；块操作直接改文本；保存时读 getResultText()。
/// 铁律：绝不访问 TextKit 1 布局管理器（防降级）；着色走 textStorage 属性。
final class MergeEditorBridge: ObservableObject {
    fileprivate weak var resultTextView: NSTextView?
    fileprivate weak var patchTextView: NSTextView?
    /// 文件路径（语法高亮 grammar 选取用）
    var path: String = ""
    /// 当前块列表（重解析后刷新；SwiftUI 观察）
    @Published var blocks: [SwiftConflictBlock] = []
    /// Result text revision, including edits that do not change the number of
    /// marker blocks. Apply Patch uses it to refresh hunk status.
    @Published var resultRevision = 0
    /// NSTextView selection revision, so toolbar actions can follow an editor
    /// range in addition to an explicitly selected hunk chip.
    @Published var selectionRevision = 0
    private var resultEditGroupActionName: String?

    func attachResult(_ tv: NSTextView) {
        resultTextView = tv
        applyColoring()
        refreshBlocks()
    }

    func attachPatch(_ tv: NSTextView?) {
        patchTextView = tv
    }

    func getResultText() -> String { resultTextView?.string ?? "" }

    @discardableResult
    private func replaceResultText(_ text: String, actionName: String) -> Bool {
        guard let tv = resultTextView else { return false }
        let previous = tv.string
        guard previous != text else { return false }

        // NSTextView.string is a bulk replacement and does not reliably
        // register an undo item. The IntelliJ viewer wraps every hunk action
        // in a command, so keep the same boundary explicitly and suppress a
        // possible duplicate TextKit registration for the bulk assignment.
        if let undoManager = tv.undoManager {
            undoManager.registerUndo(withTarget: self) { target in
                target.replaceResultText(previous, actionName: actionName)
            }
            undoManager.setActionName(actionName)
            undoManager.disableUndoRegistration()
            tv.string = text
            undoManager.enableUndoRegistration()
        } else {
            tv.string = text
        }
        applyColoring()
        refreshBlocks()
        return true
    }

    func beginResultEditGroup(_ actionName: String) {
        guard let undoManager = resultTextView?.undoManager else { return }
        resultEditGroupActionName = actionName
        undoManager.beginUndoGrouping()
    }

    func endResultEditGroup() {
        guard let undoManager = resultTextView?.undoManager else { return }
        if let actionName = resultEditGroupActionName {
            undoManager.setActionName(actionName)
        }
        undoManager.endUndoGrouping()
        resultEditGroupActionName = nil
    }

    func canApplyPatchHunk(_ hunk: ApplyPatchConflictHunk) -> Bool {
        let text = getResultText()
        let lines = splitLines(text)
        let expected = Int(hunk.oldStart == 0 ? 0 : hunk.oldStart - 1)
        if ApplyPatchConflictHunkModel.findLineRange(
            hunk.oldLines,
            in: lines,
            expectedStart: expected
        ) != nil {
            return true
        }
        return conflictBlockIndex(for: hunk, side: .theirs) != nil
    }

    @discardableResult
    func applyPatchHunk(_ hunk: ApplyPatchConflictHunk) -> ApplyPatchHunkResolution {
        guard let tv = resultTextView else { return .notApplied }
        let text = tv.string
        let lines = splitLines(text)
        // A conflict marker contains the local old line verbatim. Prefer the
        // marker-level resolution before the generic line splice, otherwise
        // applying a hunk would leave half of the marker block behind.
        if let blockIndex = conflictBlockIndex(for: hunk, side: .theirs) {
            acceptBlock(blockIndex, .theirs)
            return .applied
        }
        let expected = Int(hunk.oldStart == 0 ? 0 : hunk.oldStart - 1)
        if let range = ApplyPatchConflictHunkModel.findLineRange(
            hunk.oldLines,
            in: lines,
            expectedStart: expected
        ) {
            var updated = lines
            updated.replaceSubrange(range, with: hunk.newLines)
            _ = replaceResultText(
                joinLines(updated, trailingNewline: text.hasSuffix("\n")),
                actionName: "Apply Patch Change"
            )
            return .applied
        }
        let newExpected = Int(hunk.newStart == 0 ? 0 : hunk.newStart - 1)
        if ApplyPatchConflictHunkModel.findLineRange(
            hunk.newLines,
            in: lines,
            expectedStart: newExpected
        ) != nil {
            return .alreadyApplied
        }
        return .notApplied
    }

    /// Ignore is a resolved patch decision even if the result has no matching
    /// marker block (for example, a hunk already removed by manual editing).
    @discardableResult
    func ignorePatchHunk(_ hunk: ApplyPatchConflictHunk) -> Bool {
        guard let blockIndex = conflictBlockIndex(for: hunk, side: .ours) else {
            return true
        }
        acceptBlock(blockIndex, .ours)
        return true
    }

    func isHunkSelected(_ hunk: ApplyPatchConflictHunk) -> Bool {
        if let tv = resultTextView,
           let selected = selectionLineRange(in: tv),
           resultSelectionMatches(selected, hunk: hunk) {
            return true
        }
        guard let tv = patchTextView,
              let selected = selectionLineRange(in: tv),
              let patchRange = ApplyPatchConflictHunkModel.patchHunkLineRange(
                  in: tv.string,
                  index: hunk.index
              ) else { return false }
        return patchRange.lowerBound < selected.upperBound
            && selected.lowerBound < patchRange.upperBound
    }

    private func selectionLineRange(in tv: NSTextView) -> Range<Int>? {
        let selection = tv.selectedRange()
        guard selection.length > 0 else { return nil }
        let text = tv.string
        let ranges = lineCharRanges(text)
        guard !ranges.isEmpty else { return nil }

        func line(at offset: Int) -> Int {
            let bounded = min(max(0, offset), (text as NSString).length)
            return ranges.firstIndex(where: { NSMaxRange($0) > bounded })
                ?? max(0, ranges.count - 1)
        }
        let start = line(at: selection.location)
        let end = line(at: selection.location + selection.length - 1)
        return start..<(end + 1)
    }

    private func resultSelectionMatches(
        _ selected: Range<Int>,
        hunk: ApplyPatchConflictHunk
    ) -> Bool {
        let text = getResultText()
        let markerBlocks = parseConflictMarkers(text)
        for side in [AcceptSide.ours, AcceptSide.theirs] {
            if let blockIndex = conflictBlockIndex(for: hunk, side: side),
               let block = markerBlocks.first(where: { $0.index == blockIndex }),
               block.lineStart < selected.upperBound,
               selected.lowerBound < block.lineEnd {
                return true
            }
        }
        let expectedOld = Int(hunk.oldStart == 0 ? 0 : hunk.oldStart - 1)
        let expectedNew = Int(hunk.newStart == 0 ? 0 : hunk.newStart - 1)
        let oldRange = ApplyPatchConflictHunkModel.findLineRange(
            hunk.oldLines,
            in: splitLines(text),
            expectedStart: expectedOld
        )
        let newRange = ApplyPatchConflictHunkModel.findLineRange(
            hunk.newLines,
            in: splitLines(text),
            expectedStart: expectedNew
        )
        return [oldRange, newRange].compactMap { $0 }.contains { range in
            range.lowerBound < selected.upperBound
                && selected.lowerBound < range.upperBound
        }
    }

    func revealPatchHunk(_ hunk: ApplyPatchConflictHunk) {
        let resultText = getResultText()
        let resultLines: Range<Int>? = {
            let blocks = parseConflictMarkers(resultText)
            if let blockIndex = conflictBlockIndex(for: hunk, side: .theirs),
               let block = blocks.first(where: { $0.index == blockIndex }) {
                return block.lineStart..<block.lineEnd
            }
            let oldExpected = Int(hunk.oldStart == 0 ? 0 : hunk.oldStart - 1)
            let newExpected = Int(hunk.newStart == 0 ? 0 : hunk.newStart - 1)
            return ApplyPatchConflictHunkModel.findLineRange(
                hunk.oldLines,
                in: splitLines(resultText),
                expectedStart: oldExpected
            ) ?? ApplyPatchConflictHunkModel.findLineRange(
                hunk.newLines,
                in: splitLines(resultText),
                expectedStart: newExpected
            )
        }()
        if let resultTextView,
           let resultLines,
           let range = characterRange(for: resultLines, in: resultText) {
            resultTextView.scrollRangeToVisible(range)
        }
        if let patchTextView,
           let patchLines = ApplyPatchConflictHunkModel.patchHunkLineRange(
               in: patchTextView.string,
               index: hunk.index
           ),
           let range = characterRange(for: patchLines, in: patchTextView.string) {
            patchTextView.scrollRangeToVisible(range)
        }
    }

    /// 接受第 i 个块：重解析当前文本定位（编辑后行号漂移），按行替换（同引擎 resolve 语义）。
    func acceptBlock(_ index: Int, _ side: AcceptSide) {
        guard let tv = resultTextView else { return }
        let text = tv.string
        let parsed = parseConflictMarkers(text)
        guard index >= 0, index < parsed.count else { return }
        let b = parsed[index]
        var lines = splitLines(text)
        lines.replaceSubrange(b.lineStart..<b.lineEnd, with: pickedLines(b, side))
        _ = replaceResultText(
            joinLines(lines, trailingNewline: text.hasSuffix("\n")),
            actionName: side == .ours ? "Keep Local Conflict Change" : "Apply Conflict Change"
        )
    }

    /// 全部块按同一方向接受（倒序替换避免行号漂移）。
    func acceptAll(_ side: AcceptSide) {
        guard let tv = resultTextView else { return }
        let text = tv.string
        let parsed = parseConflictMarkers(text)
        var lines = splitLines(text)
        for b in parsed.reversed() {
            lines.replaceSubrange(b.lineStart..<b.lineEnd, with: pickedLines(b, side))
        }
        _ = replaceResultText(
            joinLines(lines, trailingNewline: text.hasSuffix("\n")),
            actionName: side == .ours ? "Keep All Local Changes" : "Apply All Conflict Changes"
        )
    }

    private func pickedLines(_ b: SwiftConflictBlock, _ side: AcceptSide) -> [String] {
        switch side {
        case .ours: return b.oursLines
        case .theirs: return b.theirsLines
        case .both: return b.oursLines + b.theirsLines
        }
    }

    private func joinLines(_ lines: [String], trailingNewline: Bool) -> String {
        lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
    }

    /// 冲突区域着色（textStorage 背景色；不碰 TextKit 1 布局管理器）。
    func applyColoring() {
        guard let tv = resultTextView, let ts = tv.textStorage else { return }
        let text = tv.string
        let ranges = lineCharRanges(text)
        let blocks = parseConflictMarkers(text)
        ts.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: ts.length))
        let markerColor = NSColor.systemGray.withAlphaComponent(0.28)
        let oursColor = NSColor.systemRed.withAlphaComponent(0.16)
        let theirsColor = NSColor.systemGreen.withAlphaComponent(0.16)
        for b in blocks {
            let sepLine = b.lineStart + 1 + b.oursLines.count // ======= 行
            colorLines(ranges, line: b.lineStart, count: 1, color: markerColor, ts: ts)        // <<<<<<<
            colorLines(ranges, line: sepLine, count: 1, color: markerColor, ts: ts)             // =======
            colorLines(ranges, line: b.lineEnd - 1, count: 1, color: markerColor, ts: ts)       // >>>>>>>
            colorLines(ranges, line: b.lineStart + 1, count: b.oursLines.count, color: oursColor, ts: ts)
            colorLines(ranges, line: sepLine + 1, count: b.theirsLines.count, color: theirsColor, ts: ts)
        }
        // 语法高亮前景色叠加（冲突背景之后；冲突标记行无语法色不影响）
        applySyntaxHighlight(to: tv, path: path)
    }

    private func colorLines(_ ranges: [NSRange], line: Int, count: Int, color: NSColor, ts: NSTextStorage) {
        guard count > 0, line >= 0, line + count <= ranges.count else { return }
        let start = ranges[line].location
        let last = ranges[line + count - 1]
        let end = last.location + last.length
        ts.addAttribute(.backgroundColor, value: color, range: NSRange(location: start, length: end - start))
    }

    fileprivate func refreshBlocks() {
        blocks = parseConflictMarkers(resultTextView?.string ?? "")
        resultRevision &+= 1
    }

    private func conflictBlockIndex(
        for hunk: ApplyPatchConflictHunk,
        side: AcceptSide
    ) -> Int? {
        let text = getResultText()
        let blocks = parseConflictMarkers(text)
        let preferred = side == .theirs ? hunk.newChangedLines : hunk.oldChangedLines
        let fallback = side == .theirs ? hunk.oldChangedLines : hunk.newChangedLines
        guard !preferred.isEmpty || !fallback.isEmpty else { return nil }
        let expectedLine = Int(
            side == .theirs
                ? (hunk.newStart == 0 ? 0 : hunk.newStart - 1)
                : (hunk.oldStart == 0 ? 0 : hunk.oldStart - 1)
        )

        var best: (index: Int, score: Int, distance: Int)?
        for block in blocks {
            let primaryLines = side == .theirs ? block.theirsLines : block.oursLines
            let secondaryLines = side == .theirs ? block.oursLines : block.theirsLines
            let primaryScore = preferred.filter(primaryLines.contains).count
            let secondaryScore = fallback.filter(secondaryLines.contains).count
            let score = primaryScore * 2 + secondaryScore
            guard score > 0 else { continue }
            let distance = abs(block.lineStart - expectedLine)
            if best == nil || score > best!.score
                || (score == best!.score && distance < best!.distance) {
                best = (block.index, score, distance)
            }
        }
        return best?.index
    }
}

/// 普通冲突为三栏 NSTextView；direct Apply Patch 为结果/patch 双栏，均由
/// NSViewRepresentable 包进 SwiftUI。
struct MergeEditorView: NSViewRepresentable {
    let ours: String
    let theirs: String
    let initialResult: String
    let path: String
    let bridge: MergeEditorBridge
    let patchText: String?
    let patchHunks: [ApplyPatchConflictHunk]
    let onSelectPatchHunk: (ApplyPatchConflictHunk) -> Void
    let onApplyPatchHunk: (ApplyPatchConflictHunk) -> Void
    let onCopyPatchHunk: (ApplyPatchConflictHunk) -> Void
    let onIgnorePatchHunk: (ApplyPatchConflictHunk) -> Void
    /// 外部重载令牌：刷新/切文件时递增，updateNSView 据此同步（不覆盖用户编辑）。
    let reloadToken: Int

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        if let patchText {
            let (resultScroll, resultTV) = Self.makePane(readOnly: false, tint: nil)
            let (patchScroll, patchTV) = Self.makePane(
                readOnly: true,
                tint: NSColor.systemGray.withAlphaComponent(0.05)
            )
            patchTV.textContainerInset = NSSize(width: ApplyPatchGutterView.width + 8, height: 6)
            patchTV.isHorizontallyResizable = true
            patchTV.textContainer?.widthTracksTextView = false
            patchTV.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            resultTV.string = initialResult
            patchTV.string = ApplyPatchConflictHunkModel.editorPatchText(
                patch: patchText,
                path: path
            )
            resultTV.delegate = context.coordinator
            patchTV.delegate = context.coordinator
            context.coordinator.resultScroll = resultScroll
            context.coordinator.patchScroll = patchScroll
            context.coordinator.attachScrolls(result: resultScroll, patch: patchScroll)
            context.coordinator.resultTV = resultTV
            context.coordinator.patchTV = patchTV
            context.coordinator.oursTV = nil
            context.coordinator.theirsTV = nil
            context.coordinator.lastReloadToken = reloadToken
            bridge.path = path
            bridge.attachResult(resultTV)
            bridge.attachPatch(patchTV)
            applyPatchHighlight(to: patchTV)

            let gutter = ApplyPatchGutterView(frame: NSRect(
                x: 0,
                y: 0,
                width: ApplyPatchGutterView.width,
                height: patchScroll.bounds.height
            ))
            gutter.hunks = patchHunks
            gutter.onSelect = onSelectPatchHunk
            gutter.onApply = onApplyPatchHunk
            gutter.onCopy = onCopyPatchHunk
            gutter.onIgnore = onIgnorePatchHunk
            context.coordinator.attachPatchGutter(gutter, to: patchScroll, textView: patchTV)

            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.distribution = .fillEqually
            stack.spacing = 1
            stack.addView(Self.wrap(resultScroll, title: "结果（可编辑）", color: .orange), in: .center)
            stack.addView(Self.wrap(patchScroll, title: "Patch（只读）", color: .blue), in: .center)
            stack.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: container.topAnchor),
                stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
            return container
        }
        let (oursScroll, oursTV) = Self.makePane(readOnly: true, tint: NSColor.systemRed.withAlphaComponent(0.05))
        let (resultScroll, resultTV) = Self.makePane(readOnly: false, tint: nil)
        let (theirsScroll, theirsTV) = Self.makePane(readOnly: true, tint: NSColor.systemGreen.withAlphaComponent(0.05))
        oursTV.string = ours
        theirsTV.string = theirs
        resultTV.string = initialResult
        applySyntaxHighlight(to: oursTV, path: path)
        applySyntaxHighlight(to: theirsTV, path: path)
        resultTV.delegate = context.coordinator
        context.coordinator.resultTV = resultTV
        context.coordinator.patchTV = nil
        context.coordinator.patchGutter = nil
        context.coordinator.resultScroll = nil
        context.coordinator.patchScroll = nil
        context.coordinator.clearScrolls()
        context.coordinator.oursTV = oursTV
        context.coordinator.theirsTV = theirsTV
        context.coordinator.lastReloadToken = reloadToken
        bridge.path = path
        bridge.attachResult(resultTV)
        bridge.attachPatch(nil)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 1
        stack.addView(Self.wrap(oursScroll, title: "本地 (ours)", color: .red), in: .center)
        stack.addView(Self.wrap(resultScroll, title: "结果（可编辑）", color: .orange), in: .center)
        stack.addView(Self.wrap(theirsScroll, title: "远程 (theirs)", color: .green), in: .center)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.patchGutter?.hunks = patchHunks
        context.coordinator.patchGutter?.onSelect = onSelectPatchHunk
        context.coordinator.patchGutter?.onApply = onApplyPatchHunk
        context.coordinator.patchGutter?.onCopy = onCopyPatchHunk
        context.coordinator.patchGutter?.onIgnore = onIgnorePatchHunk
        // 仅在外部重载（reloadToken 变化）时同步当前编辑器的内容；用户编辑/块操作不触发。
        guard context.coordinator.lastReloadToken != reloadToken else { return }
        if let patchText {
            context.coordinator.resultTV?.string = initialResult
            context.coordinator.patchTV?.string = ApplyPatchConflictHunkModel.editorPatchText(
                patch: patchText,
                path: path
            )
            applyPatchHighlight(to: context.coordinator.patchTV)
            context.coordinator.lastReloadToken = reloadToken
            bridge.path = path
            bridge.applyColoring()
            bridge.refreshBlocks()
            return
        }
        context.coordinator.oursTV?.string = ours
        context.coordinator.theirsTV?.string = theirs
        applySyntaxHighlight(to: context.coordinator.oursTV, path: path)
        applySyntaxHighlight(to: context.coordinator.theirsTV, path: path)
        context.coordinator.resultTV?.string = initialResult
        context.coordinator.lastReloadToken = reloadToken
        bridge.path = path
        bridge.applyColoring()
        bridge.refreshBlocks()
    }

    func makeCoordinator() -> Coordinator { Coordinator(bridge: bridge) }

    private static func makePane(readOnly: Bool, tint: NSColor?) -> (NSScrollView, NSTextView) {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        let textView = NSTextView()
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isEditable = !readOnly
        textView.allowsUndo = !readOnly
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = tint ?? .textBackgroundColor
        textView.textColor = .labelColor
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        return (scrollView, textView)
    }

    private static func wrap(_ view: NSView, title: String, color: Color) -> NSView {
        let container = NSView()
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        label.textColor = NSColor(color)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        container.addSubview(view)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            view.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var resultTV: NSTextView?
        weak var patchTV: NSTextView?
        fileprivate weak var patchGutter: ApplyPatchGutterView?
        weak var resultScroll: NSScrollView?
        weak var patchScroll: NSScrollView?
        weak var oursTV: NSTextView?
        weak var theirsTV: NSTextView?
        var syncingScroll = false
        private var scrollObservers: [NSObjectProtocol] = []
        var lastReloadToken = 0
        let bridge: MergeEditorBridge
        init(bridge: MergeEditorBridge) { self.bridge = bridge }

        func textDidChange(_ notification: Notification) {
            // 延迟刷新块列表（避免在文本变更通知中重入；合并连续输入）。
            // 着色不在此重算——textStorage 背景属性随文本持久，块操作/重载时重算即可。
            DispatchQueue.main.async { [weak self] in
                self?.bridge.refreshBlocks()
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            bridge.selectionRevision &+= 1
        }

        func attachScrolls(result: NSScrollView, patch: NSScrollView) {
            clearScrolls()
            for clipView in [result.contentView, patch.contentView] {
                clipView.postsBoundsChangedNotifications = true
                let observer = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clipView,
                    queue: .main
                ) { [weak self] notification in
                    self?.syncScroll(for: notification)
                }
                scrollObservers.append(observer)
            }
        }

        fileprivate func attachPatchGutter(
            _ gutter: ApplyPatchGutterView,
            to scroll: NSScrollView,
            textView: NSTextView
        ) {
            patchGutter = gutter
            gutter.autoresizingMask = [.height]
            scroll.addSubview(gutter, positioned: .above, relativeTo: scroll.contentView)
            gutter.frame = NSRect(
                x: 0,
                y: 0,
                width: ApplyPatchGutterView.width,
                height: scroll.bounds.height
            )
            gutter.update(
                textView: textView,
                scrollOriginY: scroll.contentView.bounds.origin.y
            )
        }

        func clearScrolls() {
            for observer in scrollObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            scrollObservers.removeAll()
        }

        deinit {
            clearScrolls()
        }

        private func syncScroll(for notification: Notification) {
            guard !syncingScroll,
                  let source = notification.object as? NSClipView else { return }
            let targetScroll = source === resultScroll?.contentView ? patchScroll : resultScroll
            guard let target = targetScroll, source !== target.contentView else { return }
            let sourceMax = max(
                0,
                source.documentRect.height - source.bounds.height
            )
            let targetMax = max(
                0,
                (target.documentView?.bounds.height ?? 0) - target.contentView.bounds.height
            )
            let fraction = sourceMax > 0
                ? source.bounds.origin.y / sourceMax
                : 0
            syncingScroll = true
            var origin = target.contentView.bounds.origin
            origin.y = min(targetMax, max(0, fraction * targetMax))
            target.contentView.setBoundsOrigin(origin)
            target.reflectScrolledClipView(target.contentView)
            if let patchGutter, let patchTV, let patchScroll {
                patchGutter.update(
                    textView: patchTV,
                    scrollOriginY: patchScroll.contentView.bounds.origin.y
                )
            }
            syncingScroll = false
        }
    }
}

// MARK: - 冲突三栏视图（可编辑）

struct ConflictDetailView: View {
    let repo: Repository?
    let path: String
    let onChanged: () -> Void
    /// Direct Apply Patch conflicts use the same Git conflict stages, but the
    /// second side is the patch rather than a branch or shelf. Keep the
    /// original effective patch available for an IntelliJ-style preview.
    let patchText: String?
    /// Restore snapshot name used to persist per-hunk Apply Patch decisions.
    let restoreName: String?

    init(
        repo: Repository?,
        path: String,
        patchText: String? = nil,
        restoreName: String? = nil,
        onChanged: @escaping () -> Void
    ) {
        self.repo = repo
        self.path = path
        self.patchText = patchText
        self.restoreName = restoreName
        self.onChanged = onChanged
    }

    @State private var conflict: ConflictFile?
    @State private var conflictIsBinary = false
    @State private var conflictError: String?
    @State private var feedback: String?
    @State private var saving = false
    @State private var externalToolWorking = false
    @State private var externalToolCancelling = false
    @State private var externalToolCancelHandle: GitCancelHandle?
    @State private var showExternalToolSettings = false
    @State private var selectedBlock = 0
    @State private var patchHunks: [ApplyPatchConflictHunk] = []
    @State private var selectedPatchHunkID: String?
    @State private var showBase = false
    @State private var showPatchPreview = false
    @State private var showLocalDiff = false
    @State private var patchPreviewPresentationMode: DiffPresentationMode = .sideBySide
    @State private var localDiffPresentationMode: DiffPresentationMode = .sideBySide
    @State private var localDiff: FileDiff?
    @State private var localDiffLoading = false
    @State private var localDiffError: String?
    @State private var showPartialResolveConfirmation = false
    @State private var pendingResolveContent: String?
    @State private var reloadToken = 0
    @StateObject private var bridge = MergeEditorBridge()

    private var isPatchMode: Bool { patchText != nil }

    private var selectedPatchHunk: ApplyPatchConflictHunk? {
        guard isPatchMode else { return nil }
        return patchHunks.first { $0.id == selectedPatchHunkID }
    }

    private var editorSelectedPatchHunk: ApplyPatchConflictHunk? {
        guard isPatchMode else { return nil }
        return patchHunks.first { bridge.isHunkSelected($0) }
    }

    private var editorSelectedPatchHunks: [ApplyPatchConflictHunk] {
        guard isPatchMode else { return [] }
        return patchHunks.filter { bridge.isHunkSelected($0) }
    }

    private var actionPatchHunks: [ApplyPatchConflictHunk] {
        if !editorSelectedPatchHunks.isEmpty {
            return editorSelectedPatchHunks
        }
        return selectedPatchHunk.map { [$0] } ?? []
    }

    private var unresolvedPatchHunks: [ApplyPatchConflictHunk] {
        patchHunks.filter { !$0.resolution.isResolved }
    }

    private var patchPreviewDiff: FileDiff? {
        guard let patchText else { return nil }
        let file = RebasedUnshelveDialog.parsePatchFiles(
            patchText,
            allowedPaths: [path]
        ).first { $0.path == path }
        guard let file else { return nil }
        return RebasedPatchDiffParser.parse(patch: file.rawPatch, path: path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text((isPatchMode ? "补丁冲突：" : "冲突：") + path)
                    .font(.headline).lineLimit(1)
                Spacer()
                if patchText != nil {
                    Button("Patch") { showPatchPreview = true }
                        .help("查看当前 Apply Patch 冲突的实际补丁")
                    Button("Local Diff") { loadLocalDiff() }
                        .help("比较本地冲突阶段与当前结果编辑器")
                }
                Button("Reset") { resetConflictFile() }
                    .help("从 index stages 重新生成冲突 marker，并清理当前文件的 hunk 决策")
                    .disabled(conflict == nil || conflictIsBinary || saving)
                if !isPatchMode {
                    Button("Accept Both") { acceptFile(.both) }
                        .help("保留双方内容（ours 在上）")
                        .disabled(conflict == nil || conflictIsBinary)
                    Button("Base") { showBase = true }
                        .help("查看共同祖先版本")
                        .disabled(conflict == nil || conflictIsBinary)
                    Button(externalToolWorking ? (externalToolCancelling ? "Canceling…" : "Cancel") : "External Tool") {
                        if externalToolWorking {
                            externalToolCancelling = true
                            externalToolCancelHandle?.cancel()
                        } else {
                            openExternalTool()
                        }
                    }
                    .help("Run Git's configured external merge tool")
                    .disabled(
                        externalToolCancelling
                            || saving
                            || repo == nil
                            || conflict == nil
                    )
                    Button("Settings…") { showExternalToolSettings = true }
                        .disabled(repo == nil || externalToolWorking || saving)
                }
                Button("刷新") { load() }
                Button(saving ? "保存中…" : "标记已解决") { markResolved() }
                    .disabled(saving || repo == nil || conflict == nil || conflictIsBinary)
            }
            .padding(10)
            Divider()
            if let conflictError {
                Text(conflictError).foregroundStyle(.red).padding()
                Spacer()
            } else if conflict == nil, let feedback {
                Label(feedback, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .padding()
                Spacer()
            } else if conflictIsBinary {
                binaryConflictView
            } else if let conflict {
                MergeEditorView(ours: conflict.ours, theirs: conflict.theirs,
                                initialResult: conflict.result, path: path, bridge: bridge,
                                patchText: patchText,
                                patchHunks: patchHunks,
                                onSelectPatchHunk: { selectedPatchHunkID = $0.id },
                                onApplyPatchHunk: { applySelectedPatchHunk($0) },
                                onCopyPatchHunk: { copyPatchHunk($0) },
                                onIgnorePatchHunk: { ignoreSelectedPatchHunk($0) },
                                reloadToken: reloadToken)
                Divider()
                if isPatchMode {
                    applyPatchToolbar
                } else {
                    blockToolbar
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { load() }
        .onChange(of: path) { _, _ in load() }
        .onChange(of: bridge.blocks.count) { _, n in
            if selectedBlock >= n { selectedBlock = max(0, n - 1) }
        }
        .onChange(of: bridge.resultRevision) { _, _ in
            if isPatchMode { refreshUnresolvedPatchHunks() }
        }
        .onChange(of: bridge.selectionRevision) { _, _ in
            guard isPatchMode, let hunk = editorSelectedPatchHunk else { return }
            if selectedPatchHunkID != hunk.id {
                selectedPatchHunkID = hunk.id
            }
            bridge.revealPatchHunk(hunk)
        }
        .onChange(of: selectedPatchHunkID) { _, _ in
            guard isPatchMode, let hunk = selectedPatchHunk else { return }
            bridge.revealPatchHunk(hunk)
        }
        .sheet(isPresented: $showBase) { baseSheet }
        .sheet(isPresented: $showPatchPreview) { patchPreviewSheet }
        .sheet(isPresented: $showLocalDiff) { localDiffSheet }
        .sheet(isPresented: $showExternalToolSettings) {
            if let repo {
                GitMergeToolSettingsView(
                    repo: repo,
                    onSaved: { showExternalToolSettings = false },
                    onCancel: { showExternalToolSettings = false }
                )
            }
        }
        .alert("Patch changes remain unresolved", isPresented: $showPartialResolveConfirmation) {
            Button("Finish Anyway", role: .destructive) {
                let content = pendingResolveContent
                pendingResolveContent = nil
                guard let content else { return }
                resolveEditedContent(content)
            }
            Button("Continue Editing", role: .cancel) {
                pendingResolveContent = nil
            }
        } message: {
            Text("\(unresolvedPatchHunks.count) patch change(s) are still unresolved. Finish the file anyway, or continue editing.")
        }
    }

    private var binaryConflictView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Binary Conflict", systemImage: "doc.badge.gearshape")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.orange)
            Text(isPatchMode
                 ? "This file cannot be merged in the text editor. Keep the local file or apply the complete patch side."
                 : "This file cannot be merged in the text editor. Choose which complete version to keep.")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(isPatchMode ? "Keep Local" : "Accept Ours") { acceptFile(.ours) }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving)
                Button(isPatchMode ? "Apply Patch" : "Accept Theirs") { acceptFile(.theirs) }
                    .buttonStyle(.bordered)
                    .disabled(saving)
            }
            Text("Accept Both, Reset, manual editing, and Base are unavailable for binary conflicts to avoid corrupting the file.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
    }

    private var blockToolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("全部接受本地") { acceptAllBlocks(.ours) }
                Button("全部接受远程") { acceptAllBlocks(.theirs) }
                Spacer()
                Button("↑") { navigateBlock(-1) }
                    .help("上一个冲突块")
                    .disabled(bridge.blocks.isEmpty)
                Text(bridge.blocks.isEmpty ? "无冲突块" : "块 \(selectedBlock + 1)/\(bridge.blocks.count)")
                    .font(.caption).foregroundStyle(.secondary).frame(minWidth: 90)
                Button("↓") { navigateBlock(1) }
                    .help("下一个冲突块")
                    .disabled(bridge.blocks.isEmpty)
            }
            .padding(6)
            if !bridge.blocks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(bridge.blocks) { b in
                            blockChip(b)
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 8)
                }
            }
            if let feedback {
                Text(feedback).font(.caption)
                    .foregroundStyle(feedback.hasPrefix("已") ? .green : .red)
                    .padding(.horizontal, 8).padding(.bottom, 6)
            }
        }
    }

    private var applyPatchToolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("Keep All Local") { acceptAllBlocks(.ours) }
                Button("Apply All Patch") { acceptAllBlocks(.theirs) }
                Button("Apply Non-Conflicts") { applyNonConflictingPatchHunks() }
                    .disabled(patchHunks.allSatisfy { $0.resolution.isResolved || $0.resolution == .notApplied })
                Button("Apply Selected Changes") { applySelectedPatchHunk() }
                    .help("将结果或 Patch 编辑器选中的 patch changes 应用到结果编辑器")
                    .disabled(!canApplySelectedPatchHunk || saving)
                Button("Ignore Selected Changes") { ignoreSelectedPatchHunk() }
                    .help("忽略选中的 patch hunk，并保留当前结果")
                    .disabled(!canIgnoreSelectedPatchHunk || saving)
                Spacer()
                Button("Previous Unresolved") { navigatePatchHunk(-1) }
                    .help("跳到上一个未解决 patch hunk")
                    .disabled(unresolvedPatchHunks.isEmpty)
                Text(patchHunkSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 180)
                Button("Next Unresolved") { navigatePatchHunk(1) }
                    .help("跳到下一个未解决 patch hunk")
                    .disabled(unresolvedPatchHunks.isEmpty)
            }
            .padding(6)
            if patchHunks.isEmpty {
                Text("No structured text hunks for this patch file; use the result editor or file-level actions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(patchHunks) { hunk in
                            patchHunkChip(hunk)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
            if let feedback {
                Text(feedback).font(.caption)
                    .foregroundStyle(feedback.hasPrefix("已") ? .green : .red)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
        }
    }

    private func patchHunkChip(_ hunk: ApplyPatchConflictHunk) -> some View {
        let isSelected = hunk.id == selectedPatchHunkID
        return Button {
            selectedPatchHunkID = hunk.id
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Hunk \(hunk.index + 1)")
                    .font(.caption2.weight(.semibold))
                Text(hunk.resolution.title)
                    .font(.caption2)
                    .foregroundStyle(patchHunkColor(hunk.resolution))
            }
            .padding(5)
            .frame(minWidth: 92, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 4)
            )
        }
        .buttonStyle(.plain)
        .help(hunk.header)
    }

    private func blockChip(_ b: SwiftConflictBlock) -> some View {
        let isSel = b.index == selectedBlock
        return HStack(spacing: 4) {
            Button {
                selectedBlock = b.index
            } label: {
                Text(isPatchMode ? "Patch Block \(b.index + 1)" : "块 \(b.index + 1)").font(.caption2)
            }
            .buttonStyle(.plain)
            Button("本地") { resolveBlock(b.index, .ours) }
            Button(isPatchMode ? "应用补丁" : "远程") { resolveBlock(b.index, .theirs) }
            Button("两者") { resolveBlock(b.index, .both) }
        }
        .padding(4)
        .background(isSel ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 4))
    }

    private func navigateBlock(_ dir: Int) {
        let n = bridge.blocks.count
        guard n > 0 else { return }
        selectedBlock = (selectedBlock + dir + n) % n
    }

    private func acceptAllBlocks(_ side: AcceptSide) {
        let count = bridge.blocks.count
        guard isPatchMode || count > 0 else { return }
        if isPatchMode {
            guard !patchHunks.isEmpty else {
                bridge.acceptAll(side)
                feedback = side == .ours ? "已全部保留本地结果" : "已全部应用补丁"
                return
            }
            var resolved = 0
            for hunk in patchHunks.reversed() {
                guard !hunk.resolution.isResolved else { continue }
                if side == .ours {
                    _ = bridge.ignorePatchHunk(hunk)
                    setPatchHunkResolution(hunk.id, .ignored)
                    resolved += 1
                } else {
                    switch bridge.applyPatchHunk(hunk) {
                    case .applied:
                        setPatchHunkResolution(hunk.id, .applied)
                        resolved += 1
                    case .alreadyApplied:
                        setPatchHunkResolution(hunk.id, .automaticallyApplied)
                        resolved += 1
                    case .pending, .notApplied, .automaticallyApplied, .ignored:
                        break
                    }
                }
            }
            refreshUnresolvedPatchHunks()
            selectedPatchHunkID = nil
            feedback = side == .ours
                ? "已忽略 \(resolved) 个 patch hunk"
                : "已应用 \(resolved) 个 patch hunk"
            return
        }
        bridge.acceptAll(side)
        feedback = side == .ours ? "已全部接受本地" : "已全部接受远程"
    }

    private func resolveBlock(_ index: Int, _ side: AcceptSide) {
        guard bridge.blocks.contains(where: { $0.index == index }) else { return }
        bridge.acceptBlock(index, side)
        if selectedBlock >= bridge.blocks.count {
            selectedBlock = max(0, bridge.blocks.count - 1)
        }
    }

    private var patchHunkSummary: String {
        guard !patchHunks.isEmpty else { return "No patch hunks" }
        let resolved = patchHunks.filter { $0.resolution.isResolved }.count
        if resolved == patchHunks.count {
            return "All patch hunks resolved"
        }
        let selected = selectedPatchHunk.map { "Hunk \($0.index + 1) · " } ?? ""
        return "\(selected)\(resolved)/\(patchHunks.count) resolved"
    }

    private var canApplySelectedPatchHunk: Bool {
        actionPatchHunks.contains { hunk in
            !hunk.resolution.isResolved
                && (hunk.resolution == .pending || bridge.canApplyPatchHunk(hunk))
        }
    }

    private var canIgnoreSelectedPatchHunk: Bool {
        actionPatchHunks.contains { !$0.resolution.isResolved }
    }

    private func patchHunkColor(_ resolution: ApplyPatchHunkResolution) -> Color {
        switch resolution {
        case .pending: return .orange
        case .alreadyApplied, .automaticallyApplied: return .green
        case .notApplied: return .red
        case .applied: return .green
        case .ignored: return .secondary
        }
    }

    private func navigatePatchHunk(_ direction: Int) {
        let candidates = unresolvedPatchHunks
        guard !candidates.isEmpty else { return }
        let currentIndex = selectedPatchHunk.flatMap { hunk in
            candidates.firstIndex { $0.id == hunk.id }
        } ?? (direction > 0 ? -1 : 0)
        let next = (currentIndex + direction + candidates.count) % candidates.count
        selectedPatchHunkID = candidates[next].id
    }

    private func applySelectedPatchHunk(_ explicitHunk: ApplyPatchConflictHunk? = nil) {
        let candidates = (explicitHunk.map { [$0] } ?? actionPatchHunks)
            .filter { !$0.resolution.isResolved }
        guard !candidates.isEmpty else { return }

        var applied = 0
        var alreadyApplied = 0
        var skipped = 0
        let grouped = candidates.count > 1
        if grouped {
            bridge.beginResultEditGroup("Apply Selected Changes")
        }
        defer {
            if grouped { bridge.endResultEditGroup() }
        }
        // Apply from the bottom up so a replacement cannot invalidate the
        // editor ranges used by a later selected change.
        for hunk in candidates.reversed() {
            selectedPatchHunkID = hunk.id
            switch bridge.applyPatchHunk(hunk) {
            case .applied:
                setPatchHunkResolution(hunk.id, .applied)
                applied += 1
            case .alreadyApplied:
                setPatchHunkResolution(hunk.id, .automaticallyApplied)
                alreadyApplied += 1
            case .notApplied, .pending, .automaticallyApplied, .ignored:
                skipped += 1
            }
        }
        refreshUnresolvedPatchHunks()
        feedback = "已应用 (applied + alreadyApplied) 个 patch change"
            + (skipped == 0 ? "" : "，跳过 (skipped) 个不可精确应用的 change")
        selectNextUnresolvedPatchHunkIfNeeded()
    }

    private func ignoreSelectedPatchHunk(_ explicitHunk: ApplyPatchConflictHunk? = nil) {
        let candidates = (explicitHunk.map { [$0] } ?? actionPatchHunks)
            .filter { !$0.resolution.isResolved }
        guard !candidates.isEmpty else { return }
        let grouped = candidates.count > 1
        if grouped {
            bridge.beginResultEditGroup("Ignore Selected Changes")
        }
        defer {
            if grouped { bridge.endResultEditGroup() }
        }
        for hunk in candidates {
            selectedPatchHunkID = hunk.id
            _ = bridge.ignorePatchHunk(hunk)
            setPatchHunkResolution(hunk.id, .ignored)
        }
        refreshUnresolvedPatchHunks()
        feedback = "已忽略 (candidates.count) 个 patch change"
        selectNextUnresolvedPatchHunkIfNeeded()
    }

    private func copyPatchHunk(_ hunk: ApplyPatchConflictHunk) {
        guard let content = ApplyPatchConflictHunkModel.clipboardText(for: hunk) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        selectedPatchHunkID = hunk.id
        feedback = "已复制 Hunk \(hunk.index + 1) 的补丁内容"
    }

    private func applyNonConflictingPatchHunks() {
        var appliedCount = 0
        var automaticallyResolvedCount = 0
        let candidates = patchHunks.filter { !$0.resolution.isResolved }
        let grouped = candidates.count > 1
        if grouped {
            bridge.beginResultEditGroup("Apply Non-Conflicts")
        }
        defer {
            if grouped { bridge.endResultEditGroup() }
        }
        for hunk in candidates.reversed() {
            guard !hunk.resolution.isResolved else { continue }
            if hunk.resolution == .alreadyApplied {
                setPatchHunkResolution(hunk.id, .automaticallyApplied)
                automaticallyResolvedCount += 1
                continue
            }
            guard hunk.resolution == .pending || bridge.canApplyPatchHunk(hunk) else { continue }
            if bridge.applyPatchHunk(hunk) == .applied {
                setPatchHunkResolution(hunk.id, .applied)
                appliedCount += 1
            }
        }
        refreshUnresolvedPatchHunks()
        selectNextUnresolvedPatchHunkIfNeeded()
        let total = appliedCount + automaticallyResolvedCount
        feedback = total == 0
            ? "没有可自动应用的 patch hunk"
            : "已自动处理 \(total) 个 patch hunk"
    }

    private func setPatchHunkResolution(
        _ id: String,
        _ resolution: ApplyPatchHunkResolution
    ) {
        guard let index = patchHunks.firstIndex(where: { $0.id == id }) else { return }
        if persistPatchHunkResolution(patchHunks[index], resolution) {
            patchHunks[index].resolution = resolution
        }
    }

    private func persistPatchHunkResolution(
        _ hunk: ApplyPatchConflictHunk,
        _ resolution: ApplyPatchHunkResolution
    ) -> Bool {
        guard isPatchMode, let repo, let restoreName else { return true }
        let rawResolution: String
        switch resolution {
        case .applied: rawResolution = "applied"
        case .automaticallyApplied: rawResolution = "automatically_applied"
        case .ignored: rawResolution = "ignored"
        case .pending, .alreadyApplied, .notApplied: return true
        }
        do {
            try repo.shelveSetRestoreHunkResolution(
                name: restoreName,
                path: hunk.path,
                hunkIndex: hunk.index,
                resolution: rawResolution
            )
        } catch {
            feedback = "保存 patch hunk 状态失败：\(error)"
            return false
        }
        return true
    }

    private func selectNextUnresolvedPatchHunkIfNeeded() {
        guard selectedPatchHunk?.resolution.isResolved == true else { return }
        selectedPatchHunkID = patchHunks.first(where: { !$0.resolution.isResolved })?.id
    }

    private func refreshUnresolvedPatchHunks() {
        guard isPatchMode else { return }
        let result = bridge.getResultText()
        patchHunks = patchHunks.map { hunk in
            var updated = hunk
            if !updated.resolution.isResolved {
                updated.resolution = ApplyPatchConflictHunkModel.status(of: updated, in: result)
            }
            return updated
        }
        if selectedPatchHunkID == nil {
            selectedPatchHunkID = patchHunks.first(where: { !$0.resolution.isResolved })?.id
        }
    }

    private var baseSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Base（共同祖先）").font(.headline)
                Spacer()
                Button("关闭") { showBase = false }
            }.padding(10)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(conflict?.base ?? "（无）")
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    private var patchPreviewSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Patch to Apply").font(.headline)
                Spacer()
                Button("关闭") { showPatchPreview = false }
            }
            .padding(10)
            Divider()
            if let patchPreviewDiff, !patchPreviewDiff.binary, !patchPreviewDiff.hunks.isEmpty {
                VStack(spacing: 0) {
                    HStack {
                        Text("Structured patch preview")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("Diff View", selection: $patchPreviewPresentationMode) {
                            ForEach(DiffPresentationMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Design.Colors.surface)
                    if patchPreviewPresentationMode == .sideBySide {
                        SideBySideDiffView(fileDiff: patchPreviewDiff)
                    } else {
                        UnifiedDiffView(fileDiff: patchPreviewDiff)
                    }
                }
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(patchText ?? "")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    private var localDiffSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Local → Result").font(.headline)
                Spacer()
                Button("关闭") { showLocalDiff = false }
            }
            .padding(10)
            Divider()
            if localDiffLoading {
                ProgressView("Loading local diff…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let localDiff {
                if localDiff.binary {
                    Label("Binary content cannot be rendered as a text diff.", systemImage: "doc.badge.gearshape")
                        .foregroundStyle(.secondary)
                        .padding(16)
                    Spacer()
                } else if localDiff.hunks.isEmpty {
                    Text("No changes between local and the current result.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            Text(path)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            Picker("Diff View", selection: $localDiffPresentationMode) {
                                ForEach(DiffPresentationMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 180)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Design.Colors.surface)
                        if localDiffPresentationMode == .sideBySide {
                            SideBySideDiffView(fileDiff: localDiff)
                        } else {
                            UnifiedDiffView(fileDiff: localDiff)
                        }
                    }
                }
            } else if let localDiffError {
                Text(localDiffError)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(16)
                Spacer()
            } else {
                Text("No local diff loaded.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    private func loadLocalDiff() {
        guard isPatchMode, let repo, let conflict else { return }
        let path = self.path
        let local = conflict.ours
        let result = bridge.getResultText()
        localDiff = nil
        localDiffError = nil
        localDiffLoading = true
        showLocalDiff = true
        Task.detached(priority: .userInitiated) {
            do {
                let diff = try repo.diffTexts(
                    path: path,
                    oldText: local,
                    newText: result,
                    ignoreWhitespace: false
                )
                await MainActor.run {
                    self.localDiff = diff
                    self.localDiffLoading = false
                }
            } catch {
                await MainActor.run {
                    self.localDiffError = "无法生成 Local Diff：\(error)"
                    self.localDiffLoading = false
                }
            }
        }
    }

    private func load() {
        guard let repo else { return }
        let path = self.path
        let directPatchText = patchText
        let restoreName = self.restoreName
        Task.detached(priority: .userInitiated) {
            do {
                let workspace = try repo.conflictWorkspace()
                let persistedResolutions: [ShelveRestoreHunkResolution]
                if directPatchText != nil, let restoreName,
                   let restoreInfo = try? repo.shelveRestoreInfo(),
                   restoreInfo.name == restoreName {
                    persistedResolutions = restoreInfo.resolvedHunks
                } else {
                    persistedResolutions = []
                }
                guard let workspaceFile = workspace.files.first(where: { $0.path == path }) else {
                    await MainActor.run {
                        self.conflict = nil
                        self.conflictIsBinary = false
                        self.conflictError = "冲突文件已解决或不再存在：\(path)"
                        self.patchHunks = []
                        self.selectedPatchHunkID = nil
                    }
                    return
                }
                let cf = workspaceFile.file
                await MainActor.run {
                    var restoredHunks = directPatchText.map {
                        ApplyPatchConflictHunkModel.parse(
                            patch: $0,
                            path: path,
                            result: cf.result
                        )
                    } ?? []
                    for index in restoredHunks.indices {
                        if let resolution = ApplyPatchConflictHunkModel.restoredResolution(
                            for: restoredHunks[index],
                            from: persistedResolutions
                        ) {
                            restoredHunks[index].resolution = resolution
                        }
                    }
                    self.conflict = cf
                    self.conflictIsBinary = workspaceFile.binary
                    self.conflictError = nil
                    self.selectedBlock = 0
                    self.patchHunks = restoredHunks
                    self.selectedPatchHunkID = self.patchHunks
                        .first(where: { !$0.resolution.isResolved })?.id
                        ?? self.patchHunks.first?.id
                    self.reloadToken += 1  // 外部重载：触发编辑器同步
                }
            } catch {
                await MainActor.run {
                    self.conflict = nil
                    self.conflictIsBinary = false
                    self.conflictError = "\(error)"
                    self.patchHunks = []
                    self.selectedPatchHunkID = nil
                }
            }
        }
    }

    /// 标记已解决：取结果栏文本 -> resolve_edited -> 刷新 status（文件不再显示 !）。
    /// 文件级 Accept（CONFLICT-001）：整文件接受一侧或双方，二进制安全。
    private func acceptFile(_ pick: FilePick) {
        guard let repo, !saving else { return }
        let path = self.path
        saving = true
        Task.detached(priority: .userInitiated) {
            do {
                try repo.acceptConflict(path: path, pick: pick)
                await MainActor.run {
                    self.saving = false
                    let side = pick == .both ? "双方" : pick == .ours
                        ? "本地" : self.isPatchMode ? "补丁" : "远程"
                    self.feedback = "已接受" + side
                    self.onChanged()
                }
            } catch {
                await MainActor.run {
                    self.saving = false
                    self.conflictError = "\(error)"
                }
            }
        }
    }

    /// 重置冲突现场：放弃当前编辑，从 index stages 重新生成 marker。
    private func resetConflictFile() {
        guard let repo, !saving else { return }
        let path = self.path
        let restoreName = self.restoreName
        saving = true
        Task.detached(priority: .userInitiated) {
            do {
                try repo.resetConflict(path: path)
                let resetFeedback: String
                if let restoreName {
                    do {
                        try repo.shelveClearRestoreHunkResolutions(name: restoreName, path: path)
                        resetFeedback = "已重置为未解决状态"
                    } catch {
                        resetFeedback = "已重置为未解决状态，但清理恢复状态失败：\(error)"
                    }
                } else {
                    resetFeedback = "已重置为未解决状态"
                }
                await MainActor.run {
                    self.saving = false
                    self.feedback = resetFeedback
                    self.onChanged()
                    self.load()
                }
            } catch {
                await MainActor.run {
                    self.saving = false
                    self.conflictError = "\(error)"
                }
            }
        }
    }

    private func markResolved() {
        guard repo != nil, !saving else { return }
        let content = bridge.getResultText()
        if isPatchMode {
            // textDidChange coalesces through the main queue; refresh once
            // synchronously here so a fast click after editing cannot bypass
            // the partial-resolution confirmation with stale hunk state.
            refreshUnresolvedPatchHunks()
        }
        if isPatchMode, !unresolvedPatchHunks.isEmpty {
            pendingResolveContent = content
            showPartialResolveConfirmation = true
            return
        }
        resolveEditedContent(content)
    }

    private func resolveEditedContent(_ content: String) {
        guard let repo, !saving else { return }
        let path = self.path
        saving = true
        Task.detached(priority: .userInitiated) {
            do {
                try repo.resolveEdited(path: path, content: content)
                await MainActor.run {
                    self.saving = false
                    self.feedback = "已标记为已解决"
                    self.onChanged()
                }
            } catch {
                await MainActor.run {
                    self.saving = false
                    self.feedback = "\(error)"
                }
            }
        }
    }

    /// 运行 Git 配置的 mergetool；Git 返回后重新读取 index stages，保留
    /// 外部工具只改工作区但未完成 stage 的情况，不能把它误报成已解决。
    private func openExternalTool() {
        guard let repo, !externalToolWorking else { return }
        let path = self.path
        let cancelHandle = GitCancelHandle()
        externalToolWorking = true
        externalToolCancelling = false
        externalToolCancelHandle = cancelHandle
        conflictError = nil
        feedback = nil
        Task.detached(priority: .userInitiated) {
            do {
                let result = try repo.openExternalMergeToolWithCancel(path: path, cancel: cancelHandle)
                await MainActor.run {
                    self.externalToolWorking = false
                    self.externalToolCancelling = false
                    self.externalToolCancelHandle = nil
                    self.onChanged()
                    if result.resolved {
                        self.conflict = nil
                        self.conflictIsBinary = false
                        self.feedback = "External merge tool resolved the file."
                    } else {
                        self.feedback = "External merge tool returned; conflicts remain."
                        self.load()
                    }
                }
            } catch {
                await MainActor.run {
                    self.externalToolWorking = false
                    self.externalToolCancelling = false
                    self.externalToolCancelHandle = nil
                    if cancelHandle.isCancelled() {
                        self.feedback = String(localized: "External merge tool canceled.")
                        self.load()
                    } else {
                        self.conflictError = "\(error)"
                    }
                }
            }
        }
    }
}

/// side-by-side 渲染：每个 hunk 一个头部 + 配对行。
enum DiffHunkAction: String, CaseIterable, Hashable {
    case stage
    case unstage
    case rollback

    var title: String {
        switch self {
        case .stage: "Stage Hunk"
        case .unstage: "Unstage Hunk"
        case .rollback: "Rollback Hunk"
        }
    }

    var systemImage: String {
        switch self {
        case .stage: "plus"
        case .unstage: "minus"
        case .rollback: "arrow.uturn.backward"
        }
    }
}

struct SideBySideDiffView: View {
    let fileDiff: FileDiff
    var selectionMode: Bool = false
    var selectedLines: Set<SelectedDiffLine> = []
    var onToggleLine: (SelectedDiffLine) -> Void = { _ in }
    var hunkActions: [DiffHunkAction] = []
    var hunkActionsDisabled = false
    var onHunkAction: (DiffHunkAction, Int) -> Void = { _, _ in }

    var body: some View {
        GeometryReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(fileDiff.hunks.enumerated()), id: \.offset) { hindex, hunk in
                        HunkHeaderView(
                            hunk: hunk,
                            actions: hunkActions,
                            actionsDisabled: hunkActionsDisabled,
                            onAction: { action in onHunkAction(action, hindex) }
                        )
                            .frame(minWidth: proxy.size.width, alignment: .leading)
                        ForEach(pairRows(hunk), id: \.self) { row in
                            DiffRowView(row: row, hunkIndex: hindex,
                                        selectionMode: selectionMode,
                                        isOldSelected: isOldSelected(hindex, row),
                                        selectedLines: selectedLines,
                                        onToggleLine: onToggleLine)
                                // A short hunk must still occupy the viewport so
                                // the two diff columns stay anchored left/top.
                                .frame(minWidth: proxy.size.width, alignment: .leading)
                        }
                    }
                }
                .font(.system(.body, design: .monospaced))
                // ScrollView otherwise sizes this stack only to its intrinsic
                // content and can center short diffs in both axes.
                .frame(minWidth: proxy.size.width,
                       minHeight: proxy.size.height,
                       alignment: .topLeading)
            }
            .frame(width: proxy.size.width,
                   height: proxy.size.height,
                   alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .scrollContentBackground(.hidden)
    }

    private func isOldSelected(_ hindex: Int, _ row: DiffRow) -> Bool {
        guard let old = row.old, old.kind == .deletion, old.oldLine > 0 else { return false }
        return selectedLines.contains(SelectedDiffLine(hunkIndex: hindex, oldLine: old.oldLine))
    }

    private func pairRows(_ hunk: DiffHunk) -> [DiffRow] {
        var rows: [DiffRow] = []
        var i = 0, j = 0
        let old = hunk.oldLines, new = hunk.newLines
        while i < old.count || j < new.count {
            let o = i < old.count ? old[i] : nil
            let n = j < new.count ? new[j] : nil
            if let o, let n, o.kind == .context && n.kind == .context {
                rows.append(DiffRow(old: o, new: n)); i += 1; j += 1
            } else if let o, let n, o.kind == .deletion && n.kind == .addition {
                rows.append(DiffRow(old: o, new: n)); i += 1; j += 1
            } else if let o, o.kind == .deletion {
                rows.append(DiffRow(old: o, new: nil)); i += 1
            } else if let n, n.kind == .addition {
                rows.append(DiffRow(old: nil, new: n)); j += 1
            } else if let o, let n {
                rows.append(DiffRow(old: o, new: n)); i += 1; j += 1
            } else if let o {
                rows.append(DiffRow(old: o, new: nil)); i += 1
            } else if let n {
                rows.append(DiffRow(old: nil, new: n)); j += 1
            }
        }
        return rows
    }
}

struct DiffRow: Hashable {
    let old: DiffLine?
    let new: DiffLine?
}

struct HunkHeaderView: View {
    let hunk: DiffHunk
    var actions: [DiffHunkAction] = []
    var actionsDisabled = false
    var onAction: (DiffHunkAction) -> Void = { _ in }

    var body: some View {
        HStack {
            Text("@@ -\(hunk.oldStart),\(hunk.oldLines.count) +\(hunk.newStart),\(hunk.newLines.count) @@")
                .font(Design.Typography.codeSmall)
                .foregroundStyle(Design.Colors.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Design.Colors.selection, in: Capsule())
            Spacer()
            ForEach(actions, id: \.self) { action in
                if action == .rollback {
                    Button(role: .destructive) {
                        onAction(action)
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(actionsDisabled)
                } else {
                    Button {
                        onAction(action)
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(actionsDisabled)
                }
            }
        }
        .padding(.horizontal, Design.Spacing.sm)
        .padding(.vertical, 3)
        .background(Design.Colors.surface)
    }
}

/// 语法高亮渲染辅助：HighlightKind → 颜色；span 数组 → AttributedString 前景色。
/// 颜色只是默认调色板（UI 重写时随意换），引擎只负责语义 span（D82）。
enum SyntaxHighlight {
    static func color(for kind: HighlightKind) -> Color {
        switch kind {
        case .keyword: Design.Colors.keyword
        case .string: Design.Colors.string
        case .comment: .secondary
        case .function: Design.Colors.function
        case .type: Design.Colors.type
        case .number: Design.Colors.number
        case .constant: Design.Colors.constant
        case .operator: .secondary
        }
    }

    /// 把行内局部偏移的 span 上色（UTF-8 字节偏移 → String.Index；越界安全）。
    static func apply(_ spans: [HighlightSpan], to text: String, attr: inout AttributedString) {
        guard !spans.isEmpty else { return }
        let utf8 = text.utf8
        for s in spans {
            guard let start = utf8.index(utf8.startIndex, offsetBy: Int(s.start), limitedBy: utf8.endIndex),
                  let end = utf8.index(utf8.startIndex, offsetBy: Int(s.end), limitedBy: utf8.endIndex),
                  let range = Range(start..<end, in: attr) else { continue }
            attr[range].foregroundColor = color(for: s.kind)
        }
    }
}

struct DiffRowView: View {
    let row: DiffRow
    var hunkIndex: Int = 0
    var selectionMode: Bool = false
    var isOldSelected: Bool = false
    var selectedLines: Set<SelectedDiffLine> = []
    var onToggleLine: (SelectedDiffLine) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 0) {
            oldCell
            Divider()
            newCell
        }
    }

    @ViewBuilder
    private var oldCell: some View {
        let line = row.old
        let isDeletion = line?.kind == .deletion
        HStack(spacing: 8) {
            if selectionMode && isDeletion {
                // 选择标记列（IntelliJ 式，替代行号）
                Text(isOldSelected ? "✓" : " ")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isOldSelected ? Design.Colors.accent : Design.Colors.secondary.opacity(0.3))
                    .frame(width: 16, alignment: .center)
            } else {
                Text(line.map { $0.oldLine == 0 ? " " : String($0.oldLine) } ?? " ")
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            Text(highlightedText(line))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 0.5)
        .background(oldBackground(isDeletion: isDeletion))
        .contentShape(Rectangle())
        .onTapGesture {
            guard selectionMode, let line, line.kind == .deletion, line.oldLine > 0 else { return }
            onToggleLine(SelectedDiffLine(hunkIndex: hunkIndex, oldLine: line.oldLine))
        }
    }

    private func oldBackground(isDeletion: Bool) -> Color {
        if selectionMode && isDeletion && isOldSelected {
            return Design.Colors.accent.opacity(0.25)
        }
        return isDeletion ? Design.Colors.deletion : .clear
    }

    @ViewBuilder
    private var newCell: some View {
        let line = row.new
        let isAddition = line?.kind == .addition
        HStack(spacing: 8) {
            if selectionMode && isAddition {
                Text(isNewSelected ? "✓" : " ")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isNewSelected ? Design.Colors.accent : Design.Colors.secondary.opacity(0.3))
                    .frame(width: 16, alignment: .center)
            } else {
                Text(line.map { $0.newLine == 0 ? " " : String($0.newLine) } ?? " ")
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            Text(highlightedText(line))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 0.5)
        .background(newBackground(isAddition: isAddition))
        .contentShape(Rectangle())
        .onTapGesture {
            guard selectionMode, let line, line.kind == .addition, line.newLine > 0 else { return }
            onToggleLine(SelectedDiffLine(hunkIndex: hunkIndex, oldLine: 0, newLine: line.newLine))
        }
    }

    private var isNewSelected: Bool {
        guard let line = row.new, line.kind == .addition, line.newLine > 0 else { return false }
        return selectedLines.contains(SelectedDiffLine(hunkIndex: hunkIndex, oldLine: 0, newLine: line.newLine))
    }

    private func newBackground(isAddition: Bool) -> Color {
        if selectionMode && isAddition && isNewSelected {
            return Design.Colors.accent.opacity(0.25)
        }
        return isAddition ? Design.Colors.addition : .clear
    }

    /// 语法高亮（前景色）+ word-level spans（背景色）；字节偏移转 String.Index。
    private func highlightedText(_ line: DiffLine?) -> AttributedString {
        guard let line else { return AttributedString("") }
        var attr = AttributedString(line.text)
        SyntaxHighlight.apply(line.highlights, to: line.text, attr: &attr)
        if !line.spans.isEmpty {
            let bg = line.kind == .addition ? Design.Colors.success.opacity(0.3) : Design.Colors.error.opacity(0.3)
            let utf8 = line.text.utf8
            for s in line.spans {
                guard let start = utf8.index(utf8.startIndex, offsetBy: Int(s.start), limitedBy: utf8.endIndex),
                      let end = utf8.index(utf8.startIndex, offsetBy: Int(s.end), limitedBy: utf8.endIndex),
                      let range = Range(start..<end, in: attr) else { continue }
                attr[range].backgroundColor = bg
            }
        }
        return attr
    }
}

// MARK: - 侧栏行 + 徽标

struct StatusRow: View {
    let entry: FileEntry
    let onStage: () -> Void
    let onUnstage: () -> Void
    let onPartial: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            if entry.unstaged != .unchanged {
                Button("暂存", action: onStage).buttonStyle(.bordered).controlSize(.mini)
            }
            if entry.staged != .unchanged {
                Button("取消", action: onUnstage).buttonStyle(.bordered).controlSize(.mini)
            }
            StatusBadge(kind: entry.staged)
            StatusBadge(kind: entry.unstaged)
            Text(entry.path).font(.system(.body, design: .monospaced))
            if let oldPath = entry.oldPath {
                Text("← \(oldPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Renamed from \(oldPath)")
            }
            Spacer()
            Button("逐行…", action: onPartial)
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("逐行/逐 hunk 暂存")
        }
        .padding(.vertical, 1)
    }
}

struct StatusBadge: View {
    let kind: ChangeKind
    var body: some View {
        Text(ChangeBadge.label(kind))
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(kind == .unchanged ? .clear : .white)
            .frame(width: 16, height: 16)
            .background(ChangeBadge.color(kind), in: RoundedRectangle(cornerRadius: 3))
    }
}

enum ChangeBadge {
    static func label(_ k: ChangeKind) -> String {
        switch k {
        case .unchanged: return "·"
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .typeChanged: return "T"
        case .untracked: return "U"
        case .ignored: return "I"
        case .conflicted: return "!"
        }
    }
    static func color(_ k: ChangeKind) -> Color {
        switch k {
        case .unchanged: return Design.Colors.secondary.opacity(0.15)
        case .added: return Design.Colors.success
        case .modified: return Design.Colors.info
        case .deleted, .conflicted: return Design.Colors.error
        case .renamed, .typeChanged: return Design.Colors.warning
        case .copied: return Design.Colors.keyword
        case .untracked, .ignored: return .secondary
        }
    }
}

struct Legend: View {
    var body: some View {
        HStack(spacing: 10) {
            legendItem(.added, "新增")
            legendItem(.modified, "修改")
            legendItem(.deleted, "删除")
            legendItem(.untracked, "未跟踪")
        }
    }
    @ViewBuilder
    private func legendItem(_ kind: ChangeKind, _ text: String) -> some View {
        HStack(spacing: 3) {
            StatusBadge(kind: kind)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 工具

func dateStr(_ seconds: Int64) -> String {
    Date(timeIntervalSince1970: TimeInterval(seconds))
        .formatted(date: .abbreviated, time: .shortened)
}

#Preview {
    ContentView()
}

/// 常驻左栏：项目身份 + 轻量状态徽标 + 懒加载文件树。
/// 变更详情不再占据左栏，点击文件只负责把主区路由到 FileContentView。
struct ProjectTreePane: View {
    let repo: Repository?
    let projectPath: String?
    let headId: String?
    let entries: [FileEntry]
    @Binding var selection: String?
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onCopyPath: (String) -> Void
    let onCompareWithReference: (String, Bool) -> Void
    let onCompareWithSameVersion: (String) -> Void
    let onCompareWithSelectedRevision: (String, Bool) -> Void
    let onShowFileHistory: (String) -> Void
    let onShowCurrentRevision: (String) -> Void
    let onAnnotate: (String) -> Void
    let onCheckin: (String) -> Void
    let onAdd: (String) -> Void
    let onRevert: (String) -> Void
    let onResolveConflicts: (String) -> Void
    let resolvedConflictPaths: [String]
    let onRevertResolved: (String) -> Void
    let showHeader: Bool

    init(
        repo: Repository?,
        projectPath: String?,
        headId: String?,
        entries: [FileEntry],
        selection: Binding<String?>,
        onOpen: @escaping () -> Void,
        onReveal: @escaping () -> Void,
        onCopyPath: @escaping (String) -> Void,
        onCompareWithReference: @escaping (String, Bool) -> Void = { _, _ in },
        onCompareWithSameVersion: @escaping (String) -> Void = { _ in },
        onCompareWithSelectedRevision: @escaping (String, Bool) -> Void = { _, _ in },
        onShowFileHistory: @escaping (String) -> Void = { _ in },
        onShowCurrentRevision: @escaping (String) -> Void = { _ in },
        onAnnotate: @escaping (String) -> Void = { _ in },
        onCheckin: @escaping (String) -> Void = { _ in },
        onAdd: @escaping (String) -> Void = { _ in },
        onRevert: @escaping (String) -> Void = { _ in },
        onResolveConflicts: @escaping (String) -> Void = { _ in },
        resolvedConflictPaths: [String] = [],
        onRevertResolved: @escaping (String) -> Void = { _ in },
        showHeader: Bool = true
    ) {
        self.repo = repo
        self.projectPath = projectPath
        self.headId = headId
        self.entries = entries
        self._selection = selection
        self.onOpen = onOpen
        self.onReveal = onReveal
        self.onCopyPath = onCopyPath
        self.onCompareWithReference = onCompareWithReference
        self.onCompareWithSameVersion = onCompareWithSameVersion
        self.onCompareWithSelectedRevision = onCompareWithSelectedRevision
        self.onShowFileHistory = onShowFileHistory
        self.onShowCurrentRevision = onShowCurrentRevision
        self.onAnnotate = onAnnotate
        self.onCheckin = onCheckin
        self.onAdd = onAdd
        self.onRevert = onRevert
        self.onResolveConflicts = onResolveConflicts
        self.resolvedConflictPaths = resolvedConflictPaths
        self.onRevertResolved = onRevertResolved
        self.showHeader = showHeader
    }

    private var changedCount: Int {
        entries.filter {
            $0.staged != .unchanged
                || ($0.unstaged != .unchanged && $0.unstaged != .ignored)
        }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            if showHeader {
                HStack(spacing: Design.Spacing.sm) {
                    Image(systemName: "square.stack.3d.up")
                        .foregroundStyle(Design.Colors.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repo?.displayName() ?? "未打开项目")
                            .font(.headline)
                            .lineLimit(1)
                        if let projectPath {
                            Text(projectPath)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer()
                    Button(action: onOpen) {
                        Image(systemName: "folder.badge.plus")
                    }
                    .buttonStyle(.borderless)
                    .help("打开项目")
                    if repo != nil {
                        Button(action: onReveal) {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .buttonStyle(.borderless)
                        .help("在 Finder 中显示项目根目录")
                    }
                }
                .padding(.horizontal, Design.Spacing.md)
                .padding(.vertical, Design.Spacing.sm)
            }

            if repo != nil {
                HStack(spacing: Design.Spacing.sm) {
                    Label("项目", systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if changedCount > 0 {
                        Text("\(changedCount)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Design.Colors.warning, in: Capsule())
                    }
                    Spacer()
                    if let headId {
                        Text(String(headId.prefix(7)))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, Design.Spacing.md)
                .padding(.bottom, Design.Spacing.sm)
            }
            Divider()
            ProjectFileTreeView(
                repo: repo,
                entries: entries,
                selection: $selection,
                onCopyPath: onCopyPath,
                onCompareWithReference: onCompareWithReference,
                onCompareWithSameVersion: onCompareWithSameVersion,
                        onCompareWithSelectedRevision: onCompareWithSelectedRevision,
                        onShowFileHistory: onShowFileHistory,
                        onShowCurrentRevision: onShowCurrentRevision,
                        onAnnotate: onAnnotate,
                        onCheckin: onCheckin,
                        onAdd: onAdd,
                        onRevert: onRevert,
                        onResolveConflicts: onResolveConflicts,
                        resolvedConflictPaths: resolvedConflictPaths,
                        onRevertResolved: onRevertResolved
                    )
        }
    }
}
