import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// Clipboard payload used by IntelliJ's Cleanup Branches table copy provider.
/// Each selected row is copied as branch name, last commit date, and tracked
/// branch, separated by tabs and kept in table order.
struct BranchCleanupClipboardRow: Equatable {
    let branchName: String
    let lastCommitDate: String
    let trackedBranch: String
}

func formattedBranchCleanupClipboardRows(_ rows: [BranchCleanupClipboardRow]) -> String {
    rows.map { row in
        [row.branchName, row.lastCommitDate, row.trackedBranch].joined(separator: "\t")
    }
    .joined(separator: "\n")
}

/// IntelliJ's cleanup table copies the selected table rows, not the rows
/// checked for deletion. Keep the two selection concepts separate while
/// preserving the table's current row order.
func branchCleanupSelectedRows(
    _ orderedRows: [BranchCleanupSelection],
    selected: Set<BranchCleanupSelection>
) -> [BranchCleanupSelection] {
    orderedRows.filter(selected.contains)
}

enum BranchCleanupWindowAction: Equatable {
    case calculate(String, String)
    case delete([BranchCleanupSelection])
    case refresh
}

private enum BranchCleanupSelectionHeaderState: Equatable {
    case none
    case some
    case all
}

private enum BranchCleanupSortMode: String, CaseIterable, Identifiable {
    case name
    case lastCommit
    case mergedStatus

    var id: String { rawValue }
}

private struct BranchCleanupHeaderCheckbox: NSViewRepresentable {
    let state: BranchCleanupSelectionHeaderState
    let onToggle: () -> Void

    final class Coordinator: NSObject {
        var onToggle: () -> Void

        init(onToggle: @escaping () -> Void) {
            self.onToggle = onToggle
        }

        @objc func toggle() {
            onToggle()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onToggle: onToggle)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            checkboxWithTitle: "",
            target: context.coordinator,
            action: #selector(Coordinator.toggle)
        )
        button.allowsMixedState = true
        button.toolTip = String(localized: "Select all visible branches")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.onToggle = onToggle
        button.state = switch state {
        case .none: .off
        case .some: .mixed
        case .all: .on
        }
    }
}

@MainActor
final class BranchCleanupWindowCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var roots: [BranchCleanupRoot] = []
    @Published var action: BranchCleanupWindowAction?

    private var windowController: NSWindowController?

    func present(roots: [BranchCleanupRoot]) {
        self.roots = roots
        if let window = windowController?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Cleanup Branches")
        window.identifier = NSUserInterfaceItemIdentifier("arbor.branch-cleanup")
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.minSize = NSSize(width: 900, height: 620)
        window.delegate = self
        let hostingView = NSHostingView(rootView: BranchCleanupWindowRootView(coordinator: self))
        hostingView.frame = NSRect(
            origin: .zero,
            size: window.contentRect(forFrameRect: window.frame).size
        )
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
        window.center()

        let controller = NSWindowController(window: window)
        windowController = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateRoots(_ roots: [BranchCleanupRoot]) {
        self.roots = roots
    }

    func close() {
        windowController?.close()
    }

    func windowWillClose(_ notification: Notification) {
        windowController = nil
        action = nil
    }
}

private struct BranchCleanupWindowRootView: View {
    @ObservedObject var coordinator: BranchCleanupWindowCoordinator

    var body: some View {
        BranchCleanupDialogView(
            roots: coordinator.roots,
            onCalculate: { target, prefix in
                coordinator.action = .calculate(target, prefix)
            },
            onDelete: { selections in
                coordinator.action = .delete(selections)
            },
            onRefresh: {
                coordinator.action = .refresh
            },
            onCancel: {
                coordinator.close()
            }
        )
    }
}

/// Rebased/IntelliJ 风格的分支弹出面板：分支列表与常用 Git 操作在同一处完成。
struct BranchDirectoryRow: Identifiable {
    let id: String
    let name: String
    let depth: Int
    let isGroup: Bool
}

/// The IntelliJ branch tree uses a MinusculeMatcher rather than a plain
/// substring check. Keep the macOS implementation deliberately small, but
/// preserve the user-visible rules that matter here: case-insensitive
/// matching, branch-component prefixes, and fuzzy subsequence matching.
func branchSearchScore(_ value: String, query: String) -> Int? {
    let normalizedValue = value
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    let normalizedQuery = query
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    guard !normalizedQuery.isEmpty else { return 0 }

    if normalizedValue == normalizedQuery { return 10_000 }
    if normalizedValue.hasPrefix(normalizedQuery) { return 9_000 }

    let components = normalizedValue.split(separator: "/").map(String.init)
    if components.contains(where: { $0.hasPrefix(normalizedQuery) }) {
        return 8_500
    }
    if normalizedValue.localizedCaseInsensitiveContains(normalizedQuery) {
        return 7_000 - min(999, normalizedValue.count)
    }

    var queryIndex = normalizedQuery.startIndex
    var gap = 0
    var matched = 0
    for character in normalizedValue {
        guard queryIndex < normalizedQuery.endIndex else { break }
        if character == normalizedQuery[queryIndex] {
            matched += 1
            queryIndex = normalizedQuery.index(after: queryIndex)
        } else if matched > 0 {
            gap += 1
        }
    }
    guard queryIndex == normalizedQuery.endIndex else { return nil }
    return max(1, 1_000 - gap)
}

/// IntelliJ's branch matcher treats whitespace-separated search words as
/// alternatives. This also makes a typed path segment useful without
/// requiring the user to enter the full ref name.
func branchSearchMatches(_ value: String, query: String) -> Bool {
    let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard !terms.isEmpty else { return true }
    return terms.contains { branchSearchScore(value, query: $0) != nil }
}

/// IntelliJ adds repository nodes to the multi-root branch tree while the
/// speed-search query is active. Match both the short repository name and its
/// project-relative path so a nested root can be reached without a separate
/// scope picker.
func branchPopupRepositorySearchMatches(
    displayName: String,
    relativePath: String,
    query: String
) -> Bool {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedQuery.isEmpty else { return false }
    return branchSearchMatches(displayName, query: normalizedQuery)
        || branchSearchMatches(relativePath, query: normalizedQuery)
}

enum BranchPopupExitDestination: Equatable {
    case dismiss
    case repositoryList
}

/// A repository node opens IntelliJ's second-level branch popup. The first
/// Escape therefore returns to the multi-repository list; only the next
/// Escape dismisses the whole popup.
func branchPopupExitDestination(repositoryFilter: String) -> BranchPopupExitDestination {
    repositoryFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? .dismiss
        : .repositoryList
}

enum BranchTreeTargetKind: Equatable {
    case action
    case repository
    case head
    case recent
    case local
    case remote
    case remoteGroup
    case tag
}

/// IntelliJ's `Git.Branches.List` action group contributes these actions to
/// the branch tree's speed search.  The remaining branch operations stay in
/// the popup footer or on reference context menus, so they are intentionally
/// not treated as speed-search results here.
enum BranchPopupActionID: String, CaseIterable, Identifiable {
    case commitChanges
    case newBranch
    case checkoutReference

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commitChanges: "Commit Changes…"
        case .newBranch: "New Branch…"
        case .checkoutReference: "Checkout Tag or Revision…"
        }
    }

    var systemImage: String {
        switch self {
        case .commitChanges: "checkmark.circle"
        case .newBranch: "plus"
        case .checkoutReference: "arrow.down.to.line"
        }
    }
}

/// IntelliJ's `Git.Ongoing.Rebase.Actions` is a non-popup action group that
/// is injected at the top of `Git.Branches.List`. Keep the action IDs here so
/// the popup can preserve the same ordering and route recovery operations
/// without guessing from localized titles.
enum BranchPopupOperationActionID: String, CaseIterable, Identifiable {
    case abortRebase = "Git.Rebase.Abort"
    case mergeCommit = "Git.Merge.Commit"
    case mergeAbort = "Git.Merge.Abort"
    case cherryPickAbort = "Git.CherryPick.Abort"
    case cherryPickContinue = "Git.CherryPick.Continue"
    case revertAbort = "Git.Revert.Abort"
    case rebaseContinue = "Git.Rebase.Continue"
    case rebaseSkip = "Git.Rebase.Skip"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .abortRebase: "Abort Rebase"
        case .mergeCommit: "Commit Merge"
        case .mergeAbort: "Abort Merge"
        case .cherryPickAbort: "Abort Cherry-Pick"
        case .cherryPickContinue: "Continue Cherry-Pick"
        case .revertAbort: "Abort Revert"
        case .rebaseContinue: "Continue Rebase"
        case .rebaseSkip: "Skip Commit"
        }
    }

    var systemImage: String {
        switch self {
        case .abortRebase, .mergeAbort, .cherryPickAbort, .revertAbort:
            "xmark.circle"
        case .cherryPickContinue, .mergeCommit, .rebaseContinue:
            "arrow.right.circle"
        case .rebaseSkip:
            "forward.end"
        }
    }

    var recoveryAction: ArborVCSActionRequest.OperationRecoveryAction {
        switch self {
        case .mergeCommit, .rebaseContinue, .cherryPickContinue:
            .continueOperation
        case .rebaseSkip:
            .skip
        case .abortRebase, .mergeAbort, .cherryPickAbort, .revertAbort:
            .abort
        }
    }

    static func actions(for kind: OperationKind) -> [Self] {
        switch kind {
        case .merge:
            [.mergeAbort]
        case .rebase:
            [.abortRebase, .rebaseContinue, .rebaseSkip]
        case .cherryPick:
            [.cherryPickAbort, .cherryPickContinue]
        case .revert:
            [.revertAbort]
        }
    }

    /// IntelliJ hides Cherry-Pick Continue while the conflict resolver owns
    /// the flow. The abort action remains available, matching the reference
    /// action update rules.
    var isVisibleWithConflicts: Bool {
        self != .cherryPickContinue && self != .mergeCommit
    }
}

func branchPopupOperationActions(
    for kind: OperationKind,
    hasConflicts: Bool
) -> [BranchPopupOperationActionID] {
    BranchPopupOperationActionID.actions(for: kind)
        .filter { $0.isVisibleWithConflicts || !hasConflicts }
}

/// IntelliJ keeps Git.Merge.Commit in Git.MainMenu.MergeActions. It is not
/// part of Git.Ongoing.Rebase.Actions, which is the operation group injected
/// into the Branches Popup.
func gitMainMenuOperationActions(
    for kind: OperationKind,
    hasConflicts: Bool
) -> [BranchPopupOperationActionID] {
    let actions: [BranchPopupOperationActionID] = switch kind {
    case .merge:
        [.mergeCommit, .mergeAbort]
    default:
        branchPopupOperationActions(for: kind, hasConflicts: false)
    }
    return actions.filter { $0.isVisibleWithConflicts || !hasConflicts }
}

struct BranchPopupOperationContext: Identifiable, Equatable {
    let rootPath: String
    let displayName: String
    let relativePath: String
    let kind: OperationKind
    let hasConflicts: Bool

    var id: String { rootPath }
}

func filteredBranchPopupActions(
    _ actions: [BranchPopupActionID] = BranchPopupActionID.allCases,
    query: String,
    filterByAction: Bool
) -> [BranchPopupActionID] {
    guard filterByAction else { return [] }
    return actions.filter { branchSearchMatches($0.title, query: query) }
}

func branchPopupVisibleActions(
    _ actions: [BranchPopupActionID] = BranchPopupActionID.allCases,
    query: String,
    filterByAction: Bool
) -> [BranchPopupActionID] {
    filterByAction
        ? filteredBranchPopupActions(actions, query: query, filterByAction: true)
        : actions
}

/// GitCreateNewBranchAction stays visible but disabled for a fresh/unborn
/// repository because its top-level action always starts from HEAD.
func isBranchPopupActionEnabled(
    _ action: BranchPopupActionID,
    hasHeadCommit: Bool,
    hasCommitChanges: Bool = true
) -> Bool {
    switch action {
    case .commitChanges:
        return hasCommitChanges
    case .newBranch:
        return hasHeadCommit
    case .checkoutReference:
        return true
    }
}

func branchPopupActionDisabledDescription(
    _ action: BranchPopupActionID,
    hasHeadCommit: Bool,
    hasCommitChanges: Bool = true
) -> String? {
    switch action {
    case .commitChanges where !hasCommitChanges:
        return "There are no Git changes to commit"
    case .newBranch where !hasHeadCommit:
        return "Cannot create new branch in empty repository. Make initial commit first"
    default:
        return nil
    }
}

/// FindMergedLocalBranchesAction is useful only when at least one repository
/// has a candidate local branch in addition to the target branch.
func isFindMergedBranchesActionEnabled(localBranchCounts: [Int]) -> Bool {
    localBranchCounts.contains { $0 > 1 }
}

/// The Log branch dashboard keeps local and remote references separate from
/// the repository that owns them.  The action group must use the same scope;
/// otherwise a same-named branch in another Git root can execute against the
/// window's active repository.
enum BranchDashboardReferenceKind: String, Hashable, Sendable {
    case head
    case local
    case remote
    case tag
}

struct BranchDashboardReference: Hashable, Sendable {
    let rootPath: String
    let name: String
    let kind: BranchDashboardReferenceKind
    let remote: String?
    let localBranchName: String?
    let isCurrent: Bool
    let hasUpstream: Bool
    let hasTracking: Bool
    let hasRemote: Bool
    let isProtected: Bool
    let hasHeadCommit: Bool
    let worktreePath: String?
    /// The named branch behind the synthetic HEAD row. IntelliJ resolves a
    /// HEAD + branch selection to this name before invoking GitBrancher.
    let headBranchName: String?

    static func referenceID(
        rootPath: String,
        name: String,
        kind: BranchDashboardReferenceKind
    ) -> String {
        kind.rawValue + ":" + rootPath + ":" + name
    }

    var favoriteID: String {
        Self.referenceID(rootPath: rootPath, name: name, kind: kind)
    }

    init(
        rootPath: String,
        name: String,
        kind: BranchDashboardReferenceKind,
        remote: String?,
        localBranchName: String? = nil,
        isCurrent: Bool,
        hasUpstream: Bool,
        hasTracking: Bool,
        hasRemote: Bool,
        isProtected: Bool,
        hasHeadCommit: Bool = true,
        worktreePath: String? = nil,
        headBranchName: String? = nil
    ) {
        self.rootPath = rootPath
        self.name = name
        self.kind = kind
        self.remote = remote
        self.localBranchName = localBranchName
        self.isCurrent = isCurrent
        self.hasUpstream = hasUpstream
        self.hasTracking = hasTracking
        self.hasRemote = hasRemote
        self.isProtected = isProtected
        self.hasHeadCommit = hasHeadCommit
        self.worktreePath = worktreePath
        self.headBranchName = headBranchName
    }
}

struct BranchDashboardComparisonPair: Equatable, Sendable {
    let rootPath: String
    let first: String
    let second: String
}

/// Resolves the pair that IntelliJ's BranchesPairActionBase hands to
/// GitBrancher. A synthetic HEAD is never passed through as the literal ref
/// name: it represents the current named branch, when one exists.
func branchDashboardComparisonPair(
    selection: [BranchDashboardReference]
) -> BranchDashboardComparisonPair? {
    guard selection.count == 2,
          let first = selection.first,
          selection.allSatisfy({ $0.rootPath == first.rootPath }),
          selection.allSatisfy({ $0.kind != .tag }) else {
        return nil
    }

    if let head = selection.first(where: { $0.kind == .head }) {
        guard selection.filter({ $0.kind == .head }).count == 1,
              head.hasHeadCommit,
              let currentBranch = head.headBranchName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !currentBranch.isEmpty,
              let other = selection.first(where: { $0.kind != .head }),
              other.name != currentBranch else {
            return nil
        }
        return BranchDashboardComparisonPair(
            rootPath: first.rootPath,
            first: other.name,
            second: currentBranch
        )
    }

    guard selection[0].name != selection[1].name else { return nil }
    return BranchDashboardComparisonPair(
        rootPath: first.rootPath,
        first: selection[0].name,
        second: selection[1].name
    )
}

func linkedWorktreePathForBranch(
    branch: String,
    worktrees: [WorktreeInfo],
    currentRootPath: String
) -> String? {
    let currentPath = currentRootPath.isEmpty
        ? nil
        : URL(fileURLWithPath: currentRootPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    return worktrees.first { worktree in
        guard worktree.branch == branch, !worktree.path.isEmpty else { return false }
        guard let currentPath else { return true }
        return URL(fileURLWithPath: worktree.path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path != currentPath
    }?.path
}

struct BranchDashboardRemoteGroup: Hashable, Sendable {
    let rootPath: String
    let name: String
}

enum BranchDashboardRemoteGroupAction: String, Hashable, Sendable {
    case editRemote
    case removeRemote
}

struct BranchDashboardRemoteGroupActionAvailability: Equatable, Sendable {
    let actions: Set<BranchDashboardRemoteGroupAction>

    func contains(_ action: BranchDashboardRemoteGroupAction) -> Bool {
        actions.contains(action)
    }

    /// IntelliJ exposes Edit for one remote group and only Remove for a
    /// multi-selection. Each group remains a root-scoped target.
    static func resolve(
        selection: [BranchDashboardRemoteGroup]
    ) -> BranchDashboardRemoteGroupActionAvailability {
        switch selection.count {
        case 0:
            return BranchDashboardRemoteGroupActionAvailability(actions: [])
        case 1:
            return BranchDashboardRemoteGroupActionAvailability(
                actions: [.editRemote, .removeRemote]
            )
        default:
            return BranchDashboardRemoteGroupActionAvailability(actions: [.removeRemote])
        }
    }
}

enum BranchDashboardAction: String, Hashable, Sendable {
    case filterLog
    case compareWithCurrent
    case showDiffWithWorkingTree
    case deleteTag
    case pushTag
    case compareSelected
    case compareSelectedFiles
    case checkout
    case checkoutAsNewBranch
    case openWorktree
    case createWorktree
    case checkoutWithUpdate
    case checkoutWithRebase
    case update
    case updateSelected
    case merge
    case rebase
    case push
    case fetch
    case pull
    case pullWithRebase
    case setUpstream
    case unsetUpstream
    case rename
    case deleteLocal
    case deleteSelected
    case deleteRemote
}

struct BranchDashboardActionAvailability: Equatable, Sendable {
    let actions: Set<BranchDashboardAction>
    let disabledActions: Set<BranchDashboardAction>

    init(
        actions: Set<BranchDashboardAction>,
        disabledActions: Set<BranchDashboardAction> = []
    ) {
        self.actions = actions
        self.disabledActions = disabledActions
    }

    func contains(_ action: BranchDashboardAction) -> Bool {
        actions.contains(action)
    }

    func isEnabled(_ action: BranchDashboardAction) -> Bool {
        contains(action) && !disabledActions.contains(action)
    }

    func disabledDescription(for action: BranchDashboardAction) -> String? {
        guard disabledActions.contains(action) else { return nil }
        switch action {
        case .checkoutWithUpdate:
            return "Checkout and Update is unavailable because the branch is either not tracking a remote branch or is checked out in another worktree."
        case .update, .updateSelected:
            return "Update is unavailable because the branch is either not tracking a remote branch or is checked out in another worktree."
        default:
            return nil
        }
    }

    /// Mirrors the useful part of IntelliJ's BranchesDashboardActions:
    /// one reference gets the complete single-ref group, while mixed or
    /// multi-root selections fail closed instead of guessing a repository.
    static func resolve(
        selection: [BranchDashboardReference]
    ) -> BranchDashboardActionAvailability {
        guard let reference = selection.first else {
            return BranchDashboardActionAvailability(actions: [])
        }

        if selection.count > 1 {
            var actions: Set<BranchDashboardAction> = []
            var disabledActions: Set<BranchDashboardAction> = []
            if selection.count == 2,
               selection.allSatisfy({ $0.kind != .tag }) {
                actions.insert(.compareSelected)
                actions.insert(.compareSelectedFiles)
                if branchDashboardComparisonPair(selection: selection) == nil {
                    disabledActions.insert(.compareSelected)
                    disabledActions.insert(.compareSelectedFiles)
                }
            }
            if selection.allSatisfy({ $0.kind == .local }),
               selection.allSatisfy({ $0.hasTracking }) {
                actions.insert(.updateSelected)
                if selection.contains(where: { $0.worktreePath != nil }) {
                    disabledActions.insert(.updateSelected)
                }
            }
            let hasOnlyTags = selection.allSatisfy { $0.kind == .tag }
            let hasOnlyDeletableRefs = selection.allSatisfy { $0.kind != .tag && $0.kind != .head }
            if hasOnlyTags || hasOnlyDeletableRefs {
                actions.insert(.deleteSelected)
                if selection.contains(where: { $0.isCurrent || $0.isProtected }) {
                    disabledActions.insert(.deleteSelected)
                }
            }
            return BranchDashboardActionAvailability(
                actions: actions,
                disabledActions: disabledActions
            )
        }

        var actions: Set<BranchDashboardAction> = [
            .filterLog,
            .showDiffWithWorkingTree
        ]
        var disabledActions: Set<BranchDashboardAction> = []
        switch reference.kind {
        case .head:
            actions.formUnion([.checkoutAsNewBranch, .createWorktree])
            if !reference.hasHeadCommit {
                disabledActions.insert(.checkoutAsNewBranch)
                disabledActions.insert(.createWorktree)
            }
            if reference.worktreePath != nil {
                actions.insert(.openWorktree)
            }
        case .local:
            actions.insert(.compareWithCurrent)
            actions.formUnion([.checkoutAsNewBranch, .createWorktree, .rename])
            if reference.worktreePath != nil {
                actions.insert(.openWorktree)
            }
            if !reference.isCurrent {
                actions.formUnion([.checkout, .checkoutWithRebase, .merge, .rebase, .deleteLocal])
                if reference.worktreePath != nil {
                    disabledActions.insert(.checkout)
                }
                if reference.hasRemote {
                    actions.insert(.checkoutWithUpdate)
                    if !reference.hasTracking || reference.worktreePath != nil {
                        disabledActions.insert(.checkoutWithUpdate)
                    }
                }
                if reference.worktreePath != nil {
                    disabledActions.insert(.checkoutWithRebase)
                }
            }
            if reference.hasRemote {
                actions.insert(.update)
                if !reference.hasTracking || reference.worktreePath != nil {
                    disabledActions.insert(.update)
                }
            }
            if !reference.hasHeadCommit {
                disabledActions.insert(.checkoutAsNewBranch)
                disabledActions.insert(.createWorktree)
            }
            if reference.hasUpstream {
                actions.insert(.unsetUpstream)
            } else if reference.hasRemote {
                actions.insert(.setUpstream)
            }
            // GitPushBranchAction only disables remote refs; it remains
            // visible for a local branch even when no remote is configured.
            actions.insert(.push)
        case .remote:
            actions.insert(.compareWithCurrent)
            actions.formUnion([
                .checkout,
                .checkoutAsNewBranch,
                .checkoutWithRebase,
                .merge,
                .rebase,
                .fetch,
                .pull,
                .pullWithRebase
            ])
            actions.insert(.deleteRemote)
            if reference.isProtected {
                disabledActions.insert(.deleteRemote)
            }
        case .tag:
            actions.insert(.compareWithCurrent)
            if !reference.isCurrent {
                actions.formUnion([
                    .checkout,
                    .merge,
                    .deleteTag
                ])
            }
            if reference.hasRemote {
                actions.insert(.pushTag)
            }
        }

        if reference.isCurrent || reference.kind == .tag || reference.kind == .head {
            actions.remove(.compareWithCurrent)
        }
        return BranchDashboardActionAvailability(
            actions: actions,
            disabledActions: disabledActions
        )
    }
}

/// The branch dialog validates local ref conflicts before GitBrancher runs.
/// Keep the conflict portion pure so single-root and multi-root rename flows
/// cannot drift apart while repository I/O remains at their call sites.
func branchRenameConflictMessage(
    oldName: String,
    newName: String,
    localBranchNames: [String],
    remoteBranchNames: [String]
) -> String? {
    let oldName = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
    let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !newName.isEmpty else { return "A branch name is required." }
    guard newName != oldName else { return "The new name must be different." }

    let localConflicts = localBranchNames.filter { name in
        guard name != oldName else { return false }
        return name == newName
            || name.hasPrefix(newName + "/")
            || newName.hasPrefix(name + "/")
    }
    if !localConflicts.isEmpty {
        return "Branch \(newName) conflicts with an existing local branch."
    }

    let remoteShortNames = remoteBranchNames.map { name in
        guard let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }
    if remoteShortNames.contains(newName) {
        return "Branch \(newName) clashes with a remote branch."
    }
    return nil
}

struct RebasedSingleRootRenameBranchDialog: View {
    let oldName: String
    @Binding var newName: String
    @Binding var unsetUpstream: Bool
    let hasUpstream: Bool
    let validateName: (String) -> String?
    let onRename: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let validationMessage = validateName(newName)
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Branch")
                .font(.title3.weight(.semibold))
            Text("Rename \(oldName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("New branch name", text: $newName)
                .textFieldStyle(.roundedBorder)
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if hasUpstream {
                Toggle("Unset upstream after rename", isOn: $unsetUpstream)
                    .toggleStyle(.checkbox)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Rename", action: onRename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || newName.trimmingCharacters(in: .whitespacesAndNewlines) == oldName
                            || validationMessage != nil
                    )
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

struct BranchTreeTarget: Identifiable, Equatable {
    let id: String
    let value: String
    let title: String
    let kind: BranchTreeTargetKind
    let rootPath: String?
    let isEnabled: Bool

    init(
        id: String,
        value: String,
        title: String,
        kind: BranchTreeTargetKind,
        rootPath: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.value = value
        self.title = title
        self.kind = kind
        self.rootPath = rootPath
        self.isEnabled = isEnabled
    }
}

func bestBranchTreeTargetID(
    query: String,
    targets: [BranchTreeTarget],
    preserving selectedID: String? = nil
) -> String? {
    guard !targets.isEmpty else { return nil }
    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       let selectedID,
       targets.contains(where: { $0.id == selectedID }) {
        return selectedID
    }

    let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard !terms.isEmpty else { return targets.first?.id }
    var best: (id: String, score: Int)?
    for target in targets {
        let score = terms.compactMap { branchSearchScore(target.value, query: $0) }.max()
        guard let score else { continue }
        if best == nil || score > best!.score {
            best = (target.id, score)
        }
    }
    return best?.id ?? targets.first?.id
}

func branchTreeSelectableIDs(
    _ rows: [BranchDirectoryRow],
    collapsedGroups: Set<String>
) -> [String] {
    visibleBranchDirectoryRows(rows, collapsedGroups: collapsedGroups)
        .filter { !$0.isGroup }
        .map(\.id)
}

func movedBranchTreeSelection(
    currentID: String?,
    selectableIDs: [String],
    offset: Int,
    wraps: Bool = true
) -> String? {
    guard !selectableIDs.isEmpty, offset != 0 else { return currentID }
    guard let currentID, let index = selectableIDs.firstIndex(of: currentID) else {
        return offset > 0 ? selectableIDs.first : selectableIDs.last
    }
    let candidate = index + offset
    if selectableIDs.indices.contains(candidate) { return selectableIDs[candidate] }
    guard wraps else { return selectableIDs[index] }
    let wrapped = candidate % selectableIDs.count
    return selectableIDs[wrapped >= 0 ? wrapped : wrapped + selectableIDs.count]
}

/// Mirrors macOS tree selection: a plain click replaces the selection while a
/// Command-click toggles one root-qualified node without collapsing the rest.
func toggledBranchTreeSelection(
    current: Set<String>,
    id: String,
    command: Bool
) -> Set<String> {
    guard command else { return [id] }
    var next = current
    if next.contains(id) {
        next.remove(id)
    } else {
        next.insert(id)
    }
    return next
}

/// Applies a branch-tree click while keeping the anchor root-qualified.
/// Shift extends from the last non-range click; Shift-Command adds the range
/// to the existing selection, which is the useful desktop-tree behavior for
/// combining disjoint selections with a contiguous range.
func branchTreeSelectionAfterClick(
    current: Set<String>,
    anchorID: String?,
    orderedIDs: [String],
    id: String,
    command: Bool,
    shift: Bool
) -> (selection: Set<String>, anchorID: String) {
    if shift,
       let anchorID,
       let anchorIndex = orderedIDs.firstIndex(of: anchorID),
       let clickedIndex = orderedIDs.firstIndex(of: id) {
        let lower = min(anchorIndex, clickedIndex)
        let upper = max(anchorIndex, clickedIndex)
        let range = Set(orderedIDs[lower...upper])
        return (command ? current.union(range) : range, anchorID)
    }

    return (
        toggledBranchTreeSelection(current: current, id: id, command: command),
        id
    )
}

private final class BranchDirectoryNode {
    let segment: String
    let path: String
    var branchName: String?
    var children: [String: BranchDirectoryNode] = [:]
    var childOrder: [String] = []

    init(segment: String, path: String) {
        self.segment = segment
        self.path = path
    }
}

func branchDirectoryRows(
    for names: [String],
    grouped: Bool,
    scope: String = ""
) -> [BranchDirectoryRow] {
    guard grouped else {
        return names.map {
            BranchDirectoryRow(id: "branch:\($0)", name: $0, depth: 0, isGroup: false)
        }
    }

    let root = BranchDirectoryNode(segment: "", path: "")
    for name in names {
        var node = root
        for segment in name.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            if let child = node.children[segment] {
                node = child
            } else {
                let path = node.path.isEmpty ? segment : "\(node.path)/\(segment)"
                let child = BranchDirectoryNode(segment: segment, path: path)
                node.children[segment] = child
                node.childOrder.append(segment)
                node = child
            }
        }
        node.branchName = name
    }

    var rows: [BranchDirectoryRow] = []
    func appendRows(from node: BranchDirectoryNode, depth: Int) {
        for segment in node.childOrder {
            guard let child = node.children[segment] else { continue }
            if child.children.isEmpty {
                if let branchName = child.branchName {
                    rows.append(BranchDirectoryRow(
                        id: "branch:\(branchName)",
                        name: child.segment,
                        depth: depth,
                        isGroup: false
                    ))
                }
                continue
            }

            rows.append(BranchDirectoryRow(
                id: "group:\(scope):\(child.path)",
                name: child.segment,
                depth: depth,
                isGroup: true
            ))
            if let branchName = child.branchName {
                rows.append(BranchDirectoryRow(
                    id: "branch:\(branchName)",
                    name: child.segment,
                    depth: depth + 1,
                    isGroup: false
                ))
            }
            appendRows(from: child, depth: depth + 1)
        }
    }
    appendRows(from: root, depth: 0)
    return rows
}

private func branchDirectoryRefName(_ row: BranchDirectoryRow) -> String? {
    guard !row.isGroup, row.id.hasPrefix("branch:") else { return nil }
    return String(row.id.dropFirst("branch:".count))
}

func visibleBranchDirectoryRefNames(
    _ names: [String],
    grouped: Bool,
    scope: String,
    collapsedGroups: Set<String>
) -> [String] {
    visibleBranchDirectoryRows(
        branchDirectoryRows(for: names, grouped: grouped, scope: scope),
        collapsedGroups: collapsedGroups
    ).compactMap(branchDirectoryRefName)
}

func visibleBranchDirectoryRows(
    _ rows: [BranchDirectoryRow],
    collapsedGroups: Set<String>
) -> [BranchDirectoryRow] {
    var visible: [BranchDirectoryRow] = []
    var collapsedDepth: Int?
    for row in rows {
        if let depth = collapsedDepth {
            if row.depth > depth { continue }
            collapsedDepth = nil
        }
        visible.append(row)
        if row.isGroup, collapsedGroups.contains(row.id) {
            collapsedDepth = row.depth
        }
    }
    return visible
}

struct RebasedBranchesPopover: View {
    var projectPath: String? = nil
    let branches: [BranchInfo]
    let remoteBranches: [RemoteBranchInfo]
    let recentBranches: [String]
    let tags: [TagInfo]
    let comparisons: [String: BranchCompare]
    let syncStatuses: [SyncStatus]
    var incomingBranches: Set<GitIncomingBranch> = []
    let stashes: [StashInfo]
    var worktrees: [WorktreeInfo] = []
    let hasRemote: Bool
    var protectedBranchPatterns: [String] = []
    var isShallow: Bool = false
    /// An unborn repository cannot create a branch or worktree from HEAD.
    /// Keep this in the action context instead of relying on an optimistic
    /// default while the status snapshot is resolving.
    var hasHeadCommit: Bool = true
    var hasCommitChanges: Bool = false
    let onCheckout: (String) -> Void
    var onRenameBranch: (String) -> Void = { _ in }
    var onDeleteBranch: (String) -> Void = { _ in }
    var onCheckoutRecent: (String) -> Void = { _ in }
    var onCheckoutTag: (String) -> Void = { _ in }
    var onCheckoutAsNewBranch: (String, Bool) -> Void = { _, _ in }
    var onDeleteTag: (String) -> Void = { _ in }
    var onRenameTag: (String) -> Void = { _ in }
    var onPushTag: (String) -> Void = { _ in }
    var tagPushRemotes: [String] = []
    var onPushTagToRemote: (String, String) -> Void = { _, _ in }
    var onShowDiffWithWorkingTree: (String) -> Void = { _ in }
    var onPushAllTags: (String) -> Void = { _ in }
    var onRemoteTags: () -> Void = {}
    var onCheckoutAndUpdate: (String, Bool) -> Void = { _, _ in }
    let onUpdateBranch: (String) -> Void
    /// GitPushBranchAction opens Push with the selected local branch as the
    /// source, including when that branch is not checked out.
    var onPushBranch: (String) -> Void = { _ in }
    var onForcePushedUpdate: () -> Void = {}
    var onPullRemoteBranch: (RemoteBranchInfo, Bool) -> Void = { _, _ in }
    let onCheckoutRemote: (RemoteBranchInfo) -> Void
    var onCheckoutRemoteWithRebase: (RemoteBranchInfo) -> Void = { _ in }
    let onDeleteRemote: (RemoteBranchInfo) -> Void
    let onNewBranch: () -> Void
    var onCommitChanges: () -> Void = {}
    var onFindMerged: () -> Void = {}
    var onCheckoutReference: () -> Void = {}
    var onOpenWorktree: (String) -> Void = { _ in }
    var onCreateWorktreeFromReference: (String, Bool) -> Void = { _, _ in }
    let onCompare: (String) -> Void
    let onMerge: (String?) -> Void
    let onRebase: (String?) -> Void
    let onStash: () -> Void
    let onApplyStash: (String, Bool) -> Void
    let onPopStash: (String, Bool) -> Void
    let onDropStash: (String) -> Void
    let onStashBranch: (String) -> Void
    let onStashDiff: (String) -> Void
    var onStashClear: () -> Void = {}
    let onNewTag: () -> Void
    let onShelve: () -> Void
    let onUpdate: (Bool) -> Void
    let onPush: () -> Void
    let onFetch: () -> Void
    let onRefresh: () -> Void
    var onConfigureRemotes: () -> Void = {}
    var onProjectGitSettings: () -> Void = {}
    var onFetchAll: () -> Void = {}
    var onFetchPrune: () -> Void = {}
    var onFetchUnshallow: () -> Void = {}
    var onSetUpstream: (String) -> Void = { _ in }
    var onUnsetUpstream: (String) -> Void = { _ in }
    var operationState: OperationState? = nil
    var onOperationContinue: () -> Void = {}
    var onOperationSkip: () -> Void = {}
    var onOperationAbort: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @AppStorage(GitIncomingOutgoingInfoSettings.key)
    private var incomingOutgoingInfoEnabled = GitIncomingOutgoingInfoSettings.defaultValue
    @State private var query = ""
    @State private var showRecentBranches = GitBranchesPopupSettings.defaultShowRecentBranches
    @State private var filterByAction = GitBranchesPopupSettings.defaultFilterByActionInPopup
    @State private var showTags = GitBranchesPopupSettings.defaultShowTags
    @State private var groupByDirectory = GitBranchesPopupSettings.defaultGroupByDirectory
    @State private var collapsedDirectoryGroups: Set<String> = []
    @State private var selectedBranchTargetID: String?
    @State private var favoriteReferenceIDs: Set<String> = []

    private var filteredBranches: [BranchInfo] {
        branches.filter { branchSearchMatches($0.name, query: query) }
    }

    private var filteredRemoteBranches: [RemoteBranchInfo] {
        remoteBranches.filter { branchSearchMatches($0.name, query: query) }
    }

    private var filteredRecentBranches: [String] {
        recentBranches.filter { branchSearchMatches($0, query: query) }
    }

    private var filteredActionTargets: [BranchTreeTarget] {
        branchPopupVisibleActions(
            query: query,
            filterByAction: filterByAction
        ).map { action in
            BranchTreeTarget(
                id: "single.action:\(action.rawValue)",
                value: action.rawValue,
                title: action.title,
                kind: .action,
                isEnabled: isBranchPopupActionEnabled(
                    action,
                    hasHeadCommit: hasHeadCommit,
                    hasCommitChanges: hasCommitChanges
                )
            )
        }
    }

    private var filteredOperationActionTargets: [BranchTreeTarget] {
        guard let operationState else { return [] }
        return branchPopupOperationActions(
            for: operationState.kind,
            hasConflicts: !operationState.conflictedFiles.isEmpty
        )
            .filter { !filterByAction || branchSearchMatches($0.title, query: query) }
            .map { action in
                BranchTreeTarget(
                    id: "single.operation:\(action.rawValue)",
                    value: action.rawValue,
                    title: action.title,
                    kind: .action,
                    isEnabled: true
                )
            }
    }

    private var keyboardTargets: [BranchTreeTarget] {
        let recentNames = showRecentBranches ? visibleBranchDirectoryRefNames(
            filteredRecentBranches,
            grouped: groupByDirectory,
            scope: "single.recent",
            collapsedGroups: collapsedDirectoryGroups
        ) : []
        let recent = recentNames.map {
            BranchTreeTarget(id: "single.recent:\($0)", value: $0, title: $0, kind: .recent)
        }
        let local = visibleBranchDirectoryRefNames(
            filteredBranches.map(\.name),
            grouped: groupByDirectory,
            scope: "single.local",
            collapsedGroups: collapsedDirectoryGroups
        ).map {
            BranchTreeTarget(id: "single.local:\($0)", value: $0, title: $0, kind: .local)
        }
        let remote = visibleBranchDirectoryRefNames(
            filteredRemoteBranches.map(\.name),
            grouped: groupByDirectory,
            scope: "single.remote",
            collapsedGroups: collapsedDirectoryGroups
        ).map {
            BranchTreeTarget(id: "single.remote:\($0)", value: $0, title: $0, kind: .remote)
        }
        let tagNames = showTags ? visibleBranchDirectoryRefNames(
            tags.filter { branchSearchMatches($0.name, query: query) }.map(\.name),
            grouped: groupByDirectory,
            scope: "single.tags",
            collapsedGroups: collapsedDirectoryGroups
        ) : []
        let tagTargets = tagNames.map {
            BranchTreeTarget(id: "single.tag:\($0)", value: $0, title: $0, kind: .tag)
        }
        let references = recent + local + remote + tagTargets
        let actionTargets = filterByAction
            ? (filteredOperationActionTargets + filteredActionTargets).filter(\.isEnabled)
            : []
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return references + actionTargets
        }
        return actionTargets + references
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.blue)
                Text("Branches")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Refresh branches")
                Menu {
                    Toggle("Show Recent Branches", isOn: $showRecentBranches)
                    Toggle("Show Actions in Search Results", isOn: $filterByAction)
                    Toggle("Show Tags", isOn: $showTags)
                    Toggle("Group by Directory", isOn: $groupByDirectory)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(.secondary)
                .help("Branches Popup Settings")
            }
            .padding(.bottom, 10)

            TextField("Search branches", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.bottom, 8)
                .onSubmit { activateSelectedBranch() }
                .onKeyPress(.downArrow, action: handleDownKeyPress)
                .onKeyPress(.upArrow, action: handleUpKeyPress)

            HStack(spacing: 5) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("↓ Incoming / ↑ Outgoing · Pull selected branch without checkout")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !filteredOperationActionTargets.isEmpty {
                        Text("ONGOING OPERATIONS")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.top, 2)
                        ForEach(filteredOperationActionTargets) { target in
                            Button {
                                selectedBranchTargetID = target.id
                                if let action = BranchPopupOperationActionID(rawValue: target.value) {
                                    activateOperationAction(action)
                                }
                                dismiss()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(
                                        systemName: BranchPopupOperationActionID(rawValue: target.value)?.systemImage
                                            ?? "bolt"
                                    )
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .frame(width: 16)
                                    Text(target.title)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                            }
                            .buttonStyle(.plain)
                            .disabled(!target.isEnabled)
                            .background(
                                selectedBranchTargetID == target.id
                                    ? Color.accentColor.opacity(0.22)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                        }
                    }
                    if !filteredActionTargets.isEmpty {
                        Text("ACTIONS")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.top, 2)
                        ForEach(filteredActionTargets) { target in
                            Button {
                                selectedBranchTargetID = target.id
                                if let action = BranchPopupActionID(rawValue: target.value) {
                                    activateAction(action)
                                }
                                dismiss()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: BranchPopupActionID(rawValue: target.value)?.systemImage ?? "bolt")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 16)
                                    Text(target.title)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                            }
                            .buttonStyle(.plain)
                            .disabled(!target.isEnabled)
                            .help(
                                BranchPopupActionID(rawValue: target.value).flatMap {
                                    branchPopupActionDisabledDescription(
                                        $0,
                                        hasHeadCommit: hasHeadCommit,
                                        hasCommitChanges: hasCommitChanges
                                    )
                                } ?? ""
                            )
                            .background(
                                selectedBranchTargetID == target.id
                                    ? Color.accentColor.opacity(0.22)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                        }
                    }
                    if showRecentBranches && !filteredRecentBranches.isEmpty {
                        Text("RECENT")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.top, 2)
                        ForEach(visibleBranchDirectoryRows(
                            branchDirectoryRows(
                                for: filteredRecentBranches,
                                grouped: groupByDirectory,
                                scope: "single.recent"
                            ),
                            collapsedGroups: collapsedDirectoryGroups
                        )) { row in
                            if row.isGroup {
                                branchDirectoryGroupRow(row)
                            } else if let refName = branchDirectoryRefName(row) {
                                Button {
                                    selectedBranchTargetID = "single.recent:\(refName)"
                                    onCheckoutRecent(refName)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "clock")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 16)
                                        Text(row.name)
                                            .lineLimit(1)
                                    }
                                    .padding(.leading, CGFloat(row.depth) * 14)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                }
                                .buttonStyle(.plain)
                                .background(
                                    selectedBranchTargetID == "single.recent:\(refName)"
                                        ? Color.accentColor.opacity(0.22)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5)
                                )
                            }
                        }
                    }
                    Text("LOCAL BRANCHES")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.top, 2)
                    if filteredBranches.isEmpty {
                        Text("No matching branches")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    } else {
                        ForEach(visibleBranchDirectoryRows(
                            branchDirectoryRows(
                                for: filteredBranches.map(\.name),
                                grouped: groupByDirectory,
                                scope: "single.local"
                            ),
                            collapsedGroups: collapsedDirectoryGroups
                        )) { row in
                            if row.isGroup {
                                branchDirectoryGroupRow(row)
                            } else if let refName = branchDirectoryRefName(row),
                                      let branch = filteredBranches.first(where: { $0.name == refName }) {
                                branchRow(
                                    branch,
                                    title: row.name,
                                    depth: row.depth,
                                    selected: selectedBranchTargetID == "single.local:\(branch.name)"
                                )
                            }
                        }
                    }
                    Text("REMOTE BRANCHES")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.top, 10)
                    if filteredRemoteBranches.isEmpty {
                        Text("No remote-tracking branches")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    } else {
                        ForEach(visibleBranchDirectoryRows(
                            branchDirectoryRows(
                                for: filteredRemoteBranches.map(\.name),
                                grouped: groupByDirectory,
                                scope: "single.remote"
                            ),
                            collapsedGroups: collapsedDirectoryGroups
                        )) { row in
                            if row.isGroup {
                                branchDirectoryGroupRow(row)
                            } else if let refName = branchDirectoryRefName(row),
                                      let remote = filteredRemoteBranches.first(where: { $0.name == refName }) {
                                remoteBranchRow(
                                    remote,
                                    title: row.name,
                                    depth: row.depth,
                                    selected: selectedBranchTargetID == "single.remote:\(remote.name)"
                                )
                            }
                        }
                    }
                    if (showTags && !tags.isEmpty) || hasRemote {
                        HStack {
                            Text("TAGS")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if showTags && !tags.isEmpty {
                                if tagPushRemotes.count == 1 {
                                    Button("Push All Tags") {
                                        onPushAllTags(tagPushRemotes[0])
                                        dismiss()
                                    }
                                    .font(.caption)
                                    .controlSize(.small)
                                } else if tagPushRemotes.count > 1 {
                                    Menu("Push All Tags") {
                                        ForEach(tagPushRemotes, id: \.self) { remote in
                                            Button(remote) {
                                                onPushAllTags(remote)
                                                dismiss()
                                            }
                                        }
                                    }
                                    .font(.caption)
                                    .controlSize(.small)
                                }
                            }
                            if hasRemote {
                                Button("Remote Tags…") {
                                    onRemoteTags()
                                    dismiss()
                                }
                                .font(.caption)
                                .controlSize(.small)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.top, 10)
                        if showTags {
                            ForEach(visibleBranchDirectoryRows(
                                branchDirectoryRows(
                                    for: tags.map(\.name),
                                    grouped: groupByDirectory,
                                    scope: "single.tags"
                                ),
                                collapsedGroups: collapsedDirectoryGroups
                            )) { row in
                            if row.isGroup {
                                branchDirectoryGroupRow(row)
                            } else if let refName = branchDirectoryRefName(row),
                                      let tag = tags.first(where: { $0.name == refName }) {
                                Button {
                                    selectedBranchTargetID = "single.tag:\(tag.name)"
                                    onCheckoutTag(tag.name)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "tag")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 16)
                                        Text(row.name)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(tag.shortId)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.leading, CGFloat(row.depth) * 14)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                }
                                .buttonStyle(.plain)
                                .disabled(tag.isCurrent)
                                .background(
                                    selectedBranchTargetID == "single.tag:\(tag.name)"
                                        ? Color.accentColor.opacity(0.22)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5)
                                )
                                .contextMenu {
                                    if !tag.isCurrent {
                                        Button("Checkout") {
                                            onCheckoutTag(tag.name)
                                        }
                                    }
                                    Button("Show Diff with Working Tree") {
                                        onShowDiffWithWorkingTree(tag.name)
                                    }
                                    if !tag.isCurrent {
                                        Button("Merge into Current…") {
                                            onMerge(tag.name)
                                        }
                                        Button("Delete") { onDeleteTag(tag.name) }
                                    }
                                    if tagPushRemotes.count > 1 {
                                        Menu("Push to Remote") {
                                            ForEach(tagPushRemotes, id: \.self) { remote in
                                                Button(remote) { onPushTagToRemote(tag.name, remote) }
                                            }
                                        }
                                    } else if tagPushRemotes.count == 1 {
                                        Button("Push to Remote") { onPushTag(tag.name) }
                                    }
                                }
                            }
                            }
                        }
                    }
                    HStack {
                        Text("STASHES")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !stashes.isEmpty {
                            Button("Clear All") { onStashClear() }
                                .font(.caption)
                                .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 10)
                    if stashes.isEmpty {
                        Text("No stashes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    } else {
                        ForEach(stashes, id: \.id) { stash in
                            stashRow(stash)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 380)

            Divider()
                .padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 4) {
                Button(action: { onCommitChanges(); dismiss() }) {
                    Label("Commit Changes…", systemImage: "checkmark.circle")
                }
                .disabled(!hasCommitChanges)
                .help(
                    branchPopupActionDisabledDescription(
                        .commitChanges,
                        hasHeadCommit: hasHeadCommit,
                        hasCommitChanges: hasCommitChanges
                    ) ?? ""
                )
                Button(action: { onNewBranch(); dismiss() }) {
                    Label("New Branch…", systemImage: "plus")
                }
                .disabled(!hasHeadCommit)
                .help(
                    branchPopupActionDisabledDescription(
                        .newBranch,
                        hasHeadCommit: hasHeadCommit
                    ) ?? ""
                )
                Button(action: { onFindMerged(); dismiss() }) {
                    Label("Find Merged Branches…", systemImage: "checkmark.branch")
                }
                .disabled(!isFindMergedBranchesActionEnabled(localBranchCounts: [branches.count]))
                Button(action: { onCheckoutReference(); dismiss() }) {
                    Label("Checkout Tag or Revision…", systemImage: "arrow.down.to.line")
                }
                Button(action: { onCompare(comparisonTarget); dismiss() }) {
                    Label("Compare with Current…", systemImage: "arrow.left.arrow.right")
                }
                .disabled(comparisonTarget == currentBranchName)
                HStack(spacing: 6) {
                    Button("Update") { onUpdate(false); dismiss() }
                        .disabled(!hasRemote)
                    Button("Push") { onPush(); dismiss() }
                        .disabled(!hasRemote)
                    Button("Fetch") { onFetch(); dismiss() }
                        .disabled(!hasRemote)
                }
                Menu("Remote maintenance…") {
                    Button("Fetch All") { onFetchAll(); dismiss() }
                        .disabled(!hasRemote)
                    Button("Prune Deleted Branches") { onFetchPrune(); dismiss() }
                        .disabled(!hasRemote)
                    if isShallow {
                        Button("Fetch Full History…") { onFetchUnshallow(); dismiss() }
                            .disabled(!hasRemote)
                    }
                }
                HStack(spacing: 6) {
                    Button("Merge…") { onMerge(nil); dismiss() }
                    Button("Rebase…") { onRebase(nil); dismiss() }
                    Button("Stash…") { onStash(); dismiss() }
                }
                HStack(spacing: 6) {
                    Button("New Tag…") { onNewTag(); dismiss() }
                    Button("Shelve…") { onShelve(); dismiss() }
                }
                SettingsLink {
                    Label("Settings…", systemImage: "gearshape")
                }
                .buttonStyle(.link)
                .padding(.top, 2)
                Button(action: { onProjectGitSettings(); dismiss() }) {
                    Label("Project Git Settings…", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.link)
                Button(action: { onConfigureRemotes(); dismiss() }) {
                    Label("Configure Remotes…", systemImage: "server.rack")
                }
                .buttonStyle(.link)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 350)
        .onAppear {
            favoriteReferenceIDs = GitBranchesPopupSettings.favorites(for: projectPath)
            selectedBranchTargetID = bestBranchTreeTargetID(
                query: query,
                targets: keyboardTargets,
                preserving: selectedBranchTargetID
            )
            showRecentBranches = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.showRecentBranchesKey,
                for: projectPath
            )
            filterByAction = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.filterByActionInPopupKey,
                for: projectPath
            )
            showTags = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.showTagsKey,
                for: projectPath
            )
            groupByDirectory = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.groupByDirectoryKey,
                for: projectPath
            )
            collapsedDirectoryGroups = GitBranchesPopupSettings.collapsedDirectoryGroups(
                for: projectPath
            )
        }
        .onChange(of: showRecentBranches) { _, value in
            GitBranchesPopupSettings.save(
                value,
                GitBranchesPopupSettings.showRecentBranchesKey,
                for: projectPath
            )
        }
        .onChange(of: filterByAction) { _, value in
            GitBranchesPopupSettings.save(
                value,
                GitBranchesPopupSettings.filterByActionInPopupKey,
                for: projectPath
            )
            selectedBranchTargetID = bestBranchTreeTargetID(
                query: query,
                targets: keyboardTargets,
                preserving: selectedBranchTargetID
            )
        }
        .onChange(of: showTags) { _, value in
            GitBranchesPopupSettings.save(
                value,
                GitBranchesPopupSettings.showTagsKey,
                for: projectPath
            )
            selectedBranchTargetID = bestBranchTreeTargetID(
                query: query,
                targets: keyboardTargets,
                preserving: selectedBranchTargetID
            )
        }
        .onChange(of: groupByDirectory) { _, value in
            GitBranchesPopupSettings.save(
                value,
                GitBranchesPopupSettings.groupByDirectoryKey,
                for: projectPath
            )
        }
        .onChange(of: collapsedDirectoryGroups) { _, value in
            GitBranchesPopupSettings.saveCollapsedDirectoryGroups(
                value,
                for: projectPath
            )
        }
        .onChange(of: query) { _, _ in
            selectedBranchTargetID = bestBranchTreeTargetID(
                query: query,
                targets: keyboardTargets,
                preserving: selectedBranchTargetID
            )
        }
    }

    private func moveSelectedBranch(by offset: Int) {
        selectedBranchTargetID = movedBranchTreeSelection(
            currentID: selectedBranchTargetID,
            selectableIDs: keyboardTargets.map(\.id),
            offset: offset
        )
    }

    private func handleDownKeyPress() -> KeyPress.Result {
        moveSelectedBranch(by: 1)
        return .handled
    }

    private func handleUpKeyPress() -> KeyPress.Result {
        moveSelectedBranch(by: -1)
        return .handled
    }

    private func activateSelectedBranch() {
        guard let selectedBranchTargetID,
              let target = keyboardTargets.first(where: { $0.id == selectedBranchTargetID }) else { return }
        switch target.kind {
        case .action:
            if let action = BranchPopupOperationActionID(rawValue: target.value) {
                activateOperationAction(action)
            } else if let action = BranchPopupActionID(rawValue: target.value) {
                activateAction(action)
            }
        case .repository:
            return
        case .head:
            return
        case .recent:
            onCheckoutRecent(target.value)
        case .local:
            onCheckout(target.value)
        case .remote:
            guard let branch = remoteBranches.first(where: { $0.name == target.value }) else { return }
            onCheckoutRemote(branch)
        case .remoteGroup:
            return
        case .tag:
            onCheckoutTag(target.value)
        }
        dismiss()
    }

    private func activateAction(_ action: BranchPopupActionID) {
        switch action {
        case .commitChanges:
            onCommitChanges()
        case .newBranch:
            onNewBranch()
        case .checkoutReference:
            onCheckoutReference()
        }
    }

    private func activateOperationAction(_ action: BranchPopupOperationActionID) {
        switch action.recoveryAction {
        case .continueOperation:
            onOperationContinue()
        case .skip:
            onOperationSkip()
        case .abort:
            onOperationAbort()
        case .openRecovery:
            break
        }
    }

    private var currentBranchName: String {
        branches.first(where: { $0.isCurrent })?.name ?? "HEAD"
    }

    private func popupReference(for branch: BranchInfo) -> BranchDashboardReference {
        let sync = syncStatuses.first(where: { $0.branch == branch.name })
        return BranchDashboardReference(
            rootPath: projectPath ?? "",
            name: branch.name,
            kind: .local,
            remote: nil,
            isCurrent: branch.isCurrent,
            hasUpstream: sync != nil,
            hasTracking: sync?.trackingExists == true,
            hasRemote: hasRemote || sync != nil,
            isProtected: GitProtectedBranchRules.matches(
                branch.name,
                patterns: protectedBranchPatterns
            ),
            hasHeadCommit: hasHeadCommit,
            worktreePath: linkedWorktreePathForBranch(
                branch: branch.name,
                worktrees: worktrees,
                currentRootPath: projectPath ?? ""
            )
        )
    }

    private func popupReference(for branch: RemoteBranchInfo) -> BranchDashboardReference {
        let localBranchName = syncStatus(for: branch)?.branch
        let shortName = branch.name.split(separator: "/", maxSplits: 1)
            .dropFirst()
            .joined(separator: "/")
        return BranchDashboardReference(
            rootPath: projectPath ?? "",
            name: branch.name,
            kind: .remote,
            remote: branch.remote,
            localBranchName: localBranchName,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: GitProtectedBranchRules.matches(
                shortName.isEmpty ? branch.name : shortName,
                patterns: protectedBranchPatterns
            )
        )
    }

    private func trackedRemoteBranch(for branch: BranchInfo) -> RemoteBranchInfo? {
        guard let sync = syncStatuses.first(where: {
            $0.branch == branch.name && $0.trackingExists
        }) else { return nil }
        return remoteBranches.first(where: { $0.name == sync.upstream })
    }

    private var comparisonTarget: String {
        branches.first(where: { !$0.isCurrent })?.name ?? currentBranchName
    }

    private func favoriteTitle(name: String, isRemote: Bool) -> String {
        favoriteReferenceIDs.contains(branchFavoriteID(name: name, isRemote: isRemote))
            ? "Unmark As Favorite"
            : "Mark As Favorite"
    }

    private func branchFavoriteID(name: String, isRemote: Bool) -> String {
        BranchDashboardReference.referenceID(
            rootPath: projectPath ?? "",
            name: name,
            kind: isRemote ? .remote : .local
        )
    }

    private func toggleFavorite(name: String, isRemote: Bool) {
        let id = branchFavoriteID(name: name, isRemote: isRemote)
        if favoriteReferenceIDs.contains(id) {
            favoriteReferenceIDs.remove(id)
        } else {
            favoriteReferenceIDs.insert(id)
        }
        GitBranchesPopupSettings.saveFavorites(favoriteReferenceIDs, for: projectPath)
    }

    @ViewBuilder
    private func branchDirectoryGroupRow(_ row: BranchDirectoryRow) -> some View {
        Button {
            if collapsedDirectoryGroups.contains(row.id) {
                collapsedDirectoryGroups.remove(row.id)
            } else {
                collapsedDirectoryGroups.insert(row.id)
            }
        } label: {
            Label(
                row.name,
                systemImage: collapsedDirectoryGroups.contains(row.id) ? "chevron.right" : "chevron.down"
            )
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, CGFloat(row.depth) * 14 + 6)
                .padding(.top, 4)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func branchRow(
        _ branch: BranchInfo,
        title: String? = nil,
        depth: Int = 0,
        selected: Bool = false
    ) -> some View {
        let availability = BranchDashboardActionAvailability.resolve(
            selection: [popupReference(for: branch)]
        )
        let hasIncoming = hasUnfetchedIncomingBranch(
            rootPath: projectPath,
            branch: branch.name,
            in: incomingBranches
        )
        HStack(spacing: 6) {
            Button {
                selectedBranchTargetID = "single.local:\(branch.name)"
                guard !branch.isCurrent else { return }
                onCheckout(branch.name)
                dismiss()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: branch.isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch")
                        .foregroundStyle(branch.isCurrent ? .blue : .secondary)
                        .frame(width: 16)
                    Text(title ?? branch.name)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if incomingOutgoingInfoEnabled,
                       let sync = syncStatuses.first(where: { $0.branch == branch.name }) {
                        syncBadge(sync, hasUnfetchedIncoming: hasIncoming)
                    } else if incomingOutgoingInfoEnabled, hasIncoming {
                        unfetchedIncomingBadge
                    } else if incomingOutgoingInfoEnabled,
                              let compare = comparisons[branch.name], compare.ahead > 0 || compare.behind > 0 {
                        Text("↑\(compare.ahead) ↓\(compare.behind)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if favoriteReferenceIDs.contains(branchFavoriteID(name: branch.name, isRemote: false)) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!availability.isEnabled(.checkout))

            Menu {
                Button(favoriteTitle(name: branch.name, isRemote: false)) {
                    toggleFavorite(name: branch.name, isRemote: false)
                }
                Divider()
                if availability.contains(.compareWithCurrent) {
                    Button("Compare with Current…") { onCompare(branch.name); dismiss() }
                }
                if availability.contains(.showDiffWithWorkingTree) {
                    Button("Show Diff with Working Tree") {
                        onShowDiffWithWorkingTree(branch.name)
                        dismiss()
                    }
                }
                if !branch.isCurrent {
                    Divider()
                    if availability.contains(.rebase) {
                        Button("Rebase Current onto…") { onRebase(branch.name); dismiss() }
                    }
                    if availability.contains(.merge) {
                        Button("Merge into Current…") { onMerge(branch.name); dismiss() }
                    }
                    Divider()
                }
                if availability.contains(.createWorktree) {
                    Button("New Working Tree from Branch…") {
                        onCreateWorktreeFromReference(branch.name, false)
                        dismiss()
                    }
                }
                if let trackedRemote = trackedRemoteBranch(for: branch) {
                    let trackedAvailability = BranchDashboardActionAvailability.resolve(
                        selection: [popupReference(for: trackedRemote)]
                    )
                    Divider()
                    Menu("Tracked Branch: \(trackedRemote.name)") {
                        Button("Compare with Current…") {
                            onCompare(trackedRemote.name)
                            dismiss()
                        }
                        Button("Show Diff with Working Tree") {
                            onShowDiffWithWorkingTree(trackedRemote.name)
                            dismiss()
                        }
                        Divider()
                        Button("Rebase Current onto…") {
                            onRebase(trackedRemote.name)
                            dismiss()
                        }
                        Button("Merge into Current…") {
                            onMerge(trackedRemote.name)
                            dismiss()
                        }
                        Divider()
                        Button("Pull into Current") {
                            onPullRemoteBranch(trackedRemote, false)
                            dismiss()
                        }
                        Button("Pull into Current with Rebase") {
                            onPullRemoteBranch(trackedRemote, true)
                            dismiss()
                        }
                        Divider()
                        Button("Checkout as Local Branch") {
                            onCheckoutRemote(trackedRemote)
                            dismiss()
                        }
                        Button("Checkout as New Branch…") {
                            onCheckoutAsNewBranch(trackedRemote.name, true)
                            dismiss()
                        }
                        Button("Checkout with Rebase") {
                            onCheckoutRemoteWithRebase(trackedRemote)
                            dismiss()
                        }
                        Button("Delete Remote Branch", role: .destructive) {
                            onDeleteRemote(trackedRemote)
                            dismiss()
                        }
                        .disabled(!trackedAvailability.isEnabled(.deleteRemote))
                    }
                }
                if availability.contains(.setUpstream) {
                    Divider()
                    Button("Set Upstream…") { onSetUpstream(branch.name); dismiss() }
                } else if availability.contains(.unsetUpstream) {
                    Divider()
                    Button("Unset Upstream") { onUnsetUpstream(branch.name); dismiss() }
                }
                if availability.contains(.update) {
                    Divider()
                    Button("Update") { onUpdateBranch(branch.name); dismiss() }
                        .disabled(!availability.isEnabled(.update))
                        .help(availability.disabledDescription(for: .update) ?? "")
                }
                if availability.contains(.push) {
                    Divider()
                    Button("Push…") {
                        onPushBranch(branch.name)
                        dismiss()
                    }
                }
                if branch.isCurrent,
                   let sync = syncStatuses.first(where: { $0.branch == branch.name }),
                   sync.trackingExists,
                   sync.ahead > 0,
                   sync.behind > 0 {
                    Button("Update Force-Pushed Branch…") {
                        onForcePushedUpdate()
                        dismiss()
                    }
                }
                if !branch.isCurrent {
                    if availability.contains(.checkout) {
                        Button("Checkout") { onCheckout(branch.name); dismiss() }
                            .disabled(!availability.isEnabled(.checkout))
                    }
                    if availability.contains(.checkoutAsNewBranch) {
                        Button("Checkout as New Branch…") {
                            onCheckoutAsNewBranch(branch.name, false)
                            dismiss()
                        }
                    }
                    if availability.contains(.checkoutWithUpdate) {
                        Button("Checkout and Update") { onCheckoutAndUpdate(branch.name, false); dismiss() }
                            .disabled(!availability.isEnabled(.checkoutWithUpdate))
                            .help(availability.disabledDescription(for: .checkoutWithUpdate) ?? "")
                    }
                    if availability.contains(.checkoutWithRebase) {
                        Button("Checkout with Rebase") { onCheckoutAndUpdate(branch.name, true); dismiss() }
                            .disabled(!availability.isEnabled(.checkoutWithRebase))
                    }
                    if availability.contains(.openWorktree),
                       let worktree = worktrees.first(where: { $0.branch == branch.name && !$0.path.isEmpty }) {
                        Button("Open Worktree…") { onOpenWorktree(worktree.path); dismiss() }
                    }
                    if availability.contains(.deleteLocal) {
                        Divider()
                        Button("Delete", role: .destructive) { onDeleteBranch(branch.name); dismiss() }
                    }
                }
                if availability.contains(.rename) {
                    Divider()
                    Button("Rename…") { onRenameBranch(branch.name); dismiss() }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.vertical, 4)
        .background(selected ? Color.accentColor.opacity(0.22) : (branch.isCurrent ? Color.accentColor.opacity(0.14) : Color.clear),
                    in: RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder
    private func remoteBranchRow(
        _ branch: RemoteBranchInfo,
        title: String? = nil,
        depth: Int = 0,
        selected: Bool = false
    ) -> some View {
        let sync = syncStatus(for: branch)
        let local = localBranch(for: branch)
        let incomingBranch = branch.name.hasPrefix("\(branch.remote)/")
            ? String(branch.name.dropFirst(branch.remote.count + 1))
            : nil
        let hasIncoming = incomingBranch.map {
            hasUnfetchedIncomingRemoteBranch(
                rootPath: projectPath,
                remote: branch.remote,
                branch: $0,
                in: incomingBranches
            )
        } ?? false
        let availability = BranchDashboardActionAvailability.resolve(
            selection: [popupReference(for: branch)]
        )
        HStack(spacing: 7) {
            Image(systemName: "cloud")
                .foregroundStyle(.blue)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title ?? branch.name)
                    .lineLimit(1)
                if incomingOutgoingInfoEnabled, let sync {
                    Text("跟踪本地 \(sync.branch)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if favoriteReferenceIDs.contains(branchFavoriteID(name: branch.name, isRemote: true)) {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(branch.shortId)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                if incomingOutgoingInfoEnabled, let sync {
                    remoteSyncBadge(sync, hasUnfetchedIncoming: hasIncoming)
                } else if incomingOutgoingInfoEnabled, hasIncoming {
                    unfetchedIncomingBadge
                } else if incomingOutgoingInfoEnabled, let local, local.shortId != branch.shortId {
                    Text("远程有更新")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.blue)
                } else if incomingOutgoingInfoEnabled, local != nil {
                    Text("已同步")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Menu {
                Button(favoriteTitle(name: branch.name, isRemote: true)) {
                    toggleFavorite(name: branch.name, isRemote: true)
                }
                Divider()
                Button("Pull into Current") {
                    onPullRemoteBranch(branch, false)
                    dismiss()
                }
                Button("Pull into Current with Rebase") {
                    onPullRemoteBranch(branch, true)
                    dismiss()
                }
                Divider()
                if availability.contains(.compareWithCurrent) {
                    Button("Compare with Current…") {
                        onCompare(branch.name)
                        dismiss()
                    }
                }
                if availability.contains(.showDiffWithWorkingTree) {
                    Button("Show Diff with Working Tree") {
                        onShowDiffWithWorkingTree(branch.name)
                        dismiss()
                    }
                }
                if availability.contains(.rebase) {
                    Button("Rebase Current onto…") {
                        onRebase(branch.name)
                        dismiss()
                    }
                }
                if availability.contains(.merge) {
                    Button("Merge into Current…") {
                        onMerge(branch.name)
                        dismiss()
                    }
                }
                Divider()
                if availability.contains(.checkout) {
                    Button("Checkout as Local Branch") {
                        onCheckoutRemote(branch)
                        dismiss()
                    }
                }
                if availability.contains(.checkoutAsNewBranch) {
                    Button("Checkout as New Branch…") {
                        onCheckoutAsNewBranch(branch.name, true)
                        dismiss()
                    }
                }
                if availability.contains(.checkoutWithRebase) {
                    Button("Checkout with Rebase") {
                        onCheckoutRemoteWithRebase(branch)
                        dismiss()
                    }
                }
                if availability.contains(.deleteRemote) {
                    Button("Delete Remote Branch", role: .destructive) {
                        onDeleteRemote(branch)
                        dismiss()
                    }
                    .disabled(!availability.isEnabled(.deleteRemote))
                    .help(availability.disabledDescription(for: .deleteRemote) ?? "Protected remote branches cannot be deleted.")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedBranchTargetID = "single.remote:\(branch.name)"
        }
        .background(selected ? Color.accentColor.opacity(0.22) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder
    private func stashRow(_ stash: StashInfo) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full")
                .foregroundStyle(.orange)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(stash.message.isEmpty ? "WIP" : stash.message)
                    .lineLimit(1)
                Text(stash.shortId)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Menu {
                Button("Apply (Keep)") { onApplyStash(stash.id, false); dismiss() }
                Button("Apply + Restore Index (Keep)") { onApplyStash(stash.id, true); dismiss() }
                Button("Pop (Apply and Remove)") { onPopStash(stash.id, false); dismiss() }
                Button("Pop + Restore Index") { onPopStash(stash.id, true); dismiss() }
                Button("Create Branch from Stash…") { onStashBranch(stash.id); dismiss() }
                Button("View Diff") { onStashDiff(stash.id); dismiss() }
                Divider()
                Button("Drop", role: .destructive) { onDropStash(stash.id); dismiss() }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private func syncStatus(for branch: RemoteBranchInfo) -> SyncStatus? {
        syncStatuses.first(where: { $0.upstream == branch.name })
    }

    private func localBranch(for branch: RemoteBranchInfo) -> BranchInfo? {
        let prefix = "\(branch.remote)/"
        guard branch.name.hasPrefix(prefix) else { return nil }
        let localName = String(branch.name.dropFirst(prefix.count))
        return branches.first(where: { $0.name == localName })
    }

    @ViewBuilder
    private func remoteSyncBadge(
        _ sync: SyncStatus,
        hasUnfetchedIncoming: Bool = false
    ) -> some View {
        if !sync.trackingExists {
            Text("未跟踪")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.orange)
        } else if sync.ahead > 0 || sync.behind > 0 || hasUnfetchedIncoming {
            HStack(spacing: 5) {
                if sync.behind > 0 {
                    Label("\(sync.behind)", systemImage: "arrow.down")
                        .foregroundStyle(.blue)
                }
                if sync.ahead > 0 {
                    Label("\(sync.ahead)", systemImage: "arrow.up")
                        .foregroundStyle(.green)
                }
                if hasUnfetchedIncoming {
                    Label("?", systemImage: "arrow.down")
                        .foregroundStyle(.blue)
                }
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .help("蓝色表示远程有更新，绿色表示本地有待推送提交")
        } else {
            Text("已同步")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func syncBadge(
        _ sync: SyncStatus,
        hasUnfetchedIncoming: Bool = false
    ) -> some View {
        if !sync.trackingExists {
            Text("Missing upstream")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.orange)
                .help("Upstream tracking branch is missing")
        } else if sync.ahead > 0 || sync.behind > 0 || hasUnfetchedIncoming {
            HStack(spacing: 5) {
                if sync.ahead > 0 {
                    Label("\(sync.ahead)", systemImage: "arrow.up")
                        .foregroundStyle(.green)
                }
                if sync.behind > 0 {
                    Label("\(sync.behind)", systemImage: "arrow.down")
                        .foregroundStyle(.blue)
                }
                if hasUnfetchedIncoming {
                    Label("?", systemImage: "arrow.down")
                        .foregroundStyle(.blue)
                }
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .help("绿色表示本地待推送提交，蓝色表示远程有更新")
        }
    }

    private var unfetchedIncomingBadge: some View {
        Label("?", systemImage: "arrow.down")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.blue)
            .help("Remote has incoming commits not fetched locally")
    }
}

/// SwiftUI equivalent of IntelliJ's GitUpdateOptionsDialog. The method
/// picker is the GitUpdateConfigurable panel; Reset is a dialog-side action
/// and is deliberately not persisted as an update method.
struct UpdateProjectOptionsDialogView: View {
    let projectPath: String
    let rootCount: Int
    let showsResetAction: Bool
    let onUpdate: (GitUpdateMethodChoice, Bool) -> Void
    let onResetToRemote: () -> Void
    let onCancel: () -> Void

    @State private var selectedUpdateMethod: GitUpdateMethodChoice
    @State private var doNotShowAgain: Bool

    init(
        projectPath: String,
        rootCount: Int,
        initialUpdateMethod: GitUpdateMethodChoice,
        showsResetAction: Bool,
        onUpdate: @escaping (GitUpdateMethodChoice, Bool) -> Void,
        onResetToRemote: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.projectPath = projectPath
        self.rootCount = rootCount
        self.showsResetAction = showsResetAction
        self.onUpdate = onUpdate
        self.onResetToRemote = onResetToRemote
        self.onCancel = onCancel
        _selectedUpdateMethod = State(initialValue: initialUpdateMethod)
        _doNotShowAgain = State(
            initialValue: !GitUpdateOptionsDialogSettings.shouldShow(for: projectPath)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Update Project")
                .font(.title2.weight(.semibold))
            Text(projectPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 8) {
                Text(rootCount == 1 ? "Git root" : "Git roots")
                    .font(.headline)
                Text(rootCount == 1
                     ? "Update the current Git root."
                     : "Update all discovered Git roots in project order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Update method", selection: $selectedUpdateMethod) {
                ForEach(GitUpdateMethodChoice.allCases) { method in
                    Text(method.title).tag(method)
                }
            }
            .pickerStyle(.radioGroup)
            Text(selectedUpdateMethod.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Do not show this dialog again", isOn: $doNotShowAgain)
                .help("Skip the Update Project options dialog for this project after confirmation.")

            if showsResetAction {
                Divider()
                Button("Reset to Remote Branch…", action: onResetToRemote)
                    .foregroundStyle(.red)
                    .help("Fetch the tracked upstream and reset the current branch to it.")
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Update Project") {
                    onUpdate(selectedUpdateMethod, !doNotShowAgain)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 500)
    }
}

/// Shared Create Patch configuration. IntelliJ keeps these choices in the
/// patch dialog instead of making reverse/export destination separate actions.
struct RebasedPatchExportDialog: View {
    let request: PatchExportRequest
    let onExport: (PatchExportOptions) -> Void
    let onCancel: () -> Void

    @State private var baseDirectory: String
    @State private var reverse = false
    @State private var copyToClipboard: Bool
    @State private var encoding: PatchExportEncodingChoice

    init(
        request: PatchExportRequest,
        onExport: @escaping (PatchExportOptions) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.onExport = onExport
        self.onCancel = onCancel
        _baseDirectory = State(initialValue: request.repositoryRootPath)
        _copyToClipboard = State(initialValue: request.initialCopyToClipboard)
        _encoding = State(initialValue: request.initialEncoding)
    }

    private var baseDirectoryError: String? {
        guard request.allowsBaseDirectory else { return nil }
        return patchExportBaseDirectoryIsValid(
            repositoryRootPath: request.repositoryRootPath,
            baseDirectory: baseDirectory,
            paths: request.paths
        ) ? nil : "Choose a directory inside the Git root that contains every selected path."
    }

    private func chooseBaseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: baseDirectory)
        panel.prompt = "Choose Base Directory"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        baseDirectory = url.standardizedFileURL.path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.title)
                .font(.title2.weight(.semibold))

            Text("Choose how the selected Git changes are written. The patch remains a portable Git patch.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 7) {
                Text("Base directory")
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(baseDirectory == request.repositoryRootPath ? "Repository root" : baseDirectory)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…", action: chooseBaseDirectory)
                        .disabled(!request.allowsBaseDirectory)
                }
                if !request.allowsBaseDirectory {
                    Text("Full revision export uses the repository root because its complete path set is not loaded in the dialog.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let baseDirectoryError {
                    Label(baseDirectoryError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Patch paths are written relative to this directory.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Reverse patch", isOn: $reverse)
                .toggleStyle(.checkbox)
                .help("Swap the before and after sides of the selected comparison.")
            Toggle("Copy to Clipboard", isOn: $copyToClipboard)
                .toggleStyle(.checkbox)

            HStack(spacing: 10) {
                Text("Encoding")
                Picker("Encoding", selection: $encoding) {
                    ForEach(PatchExportEncodingChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .labelsHidden()
                .frame(width: 180, alignment: .leading)
                if copyToClipboard {
                    Text("Clipboard uses Unicode text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button(copyToClipboard ? "Copy Patch" : "Create Patch") {
                    let selectedBase = baseDirectory == request.repositoryRootPath ? nil : baseDirectory
                    onExport(PatchExportOptions(
                        baseDirectory: selectedBase,
                        reverse: reverse,
                        copyToClipboard: copyToClipboard,
                        encoding: encoding
                    ))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(baseDirectoryError != nil)
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}

/// IntelliJ Branches Popup 的 tracking 分支选择器。
struct SetUpstreamDialogView: View {
    let localBranch: String
    let repositoryName: String?
    let remoteBranches: [RemoteBranchInfo]
    let onCancel: () -> Void
    let onSave: (String) -> Void

    @State private var selectedUpstream: String

    init(
        localBranch: String,
        remoteBranches: [RemoteBranchInfo],
        currentUpstream: String?,
        repositoryName: String? = nil,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String) -> Void
    ) {
        self.localBranch = localBranch
        self.repositoryName = repositoryName
        self.remoteBranches = remoteBranches
        self.onCancel = onCancel
        self.onSave = onSave
        _selectedUpstream = State(initialValue: currentUpstream ?? remoteBranches.first?.name ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set Upstream").font(.title3.weight(.semibold))
            Text("为 \(localBranch) 选择一个 remote-tracking branch。")
                .foregroundStyle(.secondary)
            if let repositoryName, !repositoryName.isEmpty {
                Label(repositoryName, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if remoteBranches.isEmpty {
                ContentUnavailableView {
                    Label("No remote branches", systemImage: "cloud.slash")
                } description: {
                    Text("先 Fetch 远程分支，再设置 upstream。")
                }
            } else {
                Picker("Upstream", selection: $selectedUpstream) {
                    ForEach(remoteBranches, id: \.name) { branch in
                        Text(branch.name).tag(branch.name)
                    }
                }
                .labelsHidden()
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Set Upstream") {
                    onSave(selectedUpstream)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedUpstream.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct RebasedNewBranchDialog: View {
    let title: String
    @Binding var name: String
    @Binding var baseRevision: String
    @Binding var checkout: Bool
    @Binding var resetExisting: Bool
    let validateName: (String) -> String?
    let branches: [BranchInfo]
    let onCreate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let validationMessage = validateName(name)
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.weight(.semibold))
            TextField("Branch name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onChange(of: name) { _, value in
                    let cleaned = GitBranchNameCleanup.cleanUpOnTyping(value)
                    if cleaned != value { name = cleaned }
                }
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                Text("Create from")
                    .foregroundStyle(.secondary)
                TextField("HEAD", text: $baseRevision)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    Button("HEAD") { baseRevision = "" }
                    ForEach(branches, id: \.name) { branch in
                        Button(branch.name) { baseRevision = branch.name }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
            }
            Toggle("Checkout branch", isOn: $checkout)
                .toggleStyle(.checkbox)
            Toggle("Overwrite existing branch", isOn: $resetExisting)
                .toggleStyle(.checkbox)
                .disabled(!branches.contains { $0.name == name.trimmingCharacters(in: .whitespacesAndNewlines) })
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Create", action: onCreate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || validationMessage != nil
                    )
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// IntelliJ's Create New Working Tree action keeps the selected branch or tag
/// as the source ref.  The optional branch field mirrors the dialog's
/// existing-branch versus new-branch choice; a remote branch is intentionally
/// not offered here because the fork hides this action for remote refs.
struct RebasedNewWorktreeDialog: View {
    let rootPath: String?
    let reference: String
    let isTag: Bool
    let occupiedBranches: Set<String>
    let validateBranchName: (String) -> String?
    @Binding var path: String
    @Binding var branch: String
    let onCreate: (String, String) -> Void
    let onCancel: () -> Void

    private var trimmedPath: String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedBranch: String {
        GitBranchNameCleanup.cleanUp(branch)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var branchError: String? {
        guard !trimmedBranch.isEmpty else { return nil }
        if occupiedBranches.contains(trimmedBranch) {
            return "该分支已被其他 worktree 占用。"
        }
        return validateBranchName(trimmedBranch)
    }

    private var sourceRefError: String? {
        guard !isTag,
              trimmedBranch.isEmpty,
              occupiedBranches.contains(reference) else { return nil }
        return "来源分支已被其他 worktree 占用；请填写一个新分支名。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isTag ? "New Working Tree from Tag" : "New Working Tree from Branch")
                .font(.title3.weight(.semibold))
            if let rootPath {
                LabeledContent("Repository", value: rootPath)
                    .lineLimit(1)
            }
            LabeledContent("Source ref", value: reference)
                .font(.system(.body, design: .monospaced))
            TextField("Worktree path", text: $path)
                .textFieldStyle(.roundedBorder)
            TextField("New branch (optional)", text: $branch)
                .textFieldStyle(.roundedBorder)
                .onChange(of: branch) { _, value in
                    let cleaned = GitBranchNameCleanup.cleanUpOnTyping(value)
                    if cleaned != value { branch = cleaned }
                }
            Text("留空将直接检出来源引用；填写后会从来源引用创建新分支。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let branchError {
                Text(branchError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let sourceRefError {
                Text(sourceRefError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Create") {
                    onCreate(trimmedPath, trimmedBranch)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    trimmedPath.isEmpty
                        || branchError != nil
                        || sourceRefError != nil
                )
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

/// Recovery surface shown after force-deleting an unmerged local branch. The
/// exact old tip is retained by the engine, so restoring does not depend on a
/// reflog entry still being available.
struct BranchDeleteRecoveryView: View {
    let preview: BranchDeletePreview
    let rootPath: String?
    let trackedRemoteBranch: String?
    let onRestore: () -> Void
    let onDeleteTrackedRemote: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(.orange)
                Text("Branch deleted")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            Text("The branch reference was removed, but its old tip is still available to restore.")
                .foregroundStyle(.secondary)
            LabeledContent("Branch", value: preview.branchName)
            LabeledContent("Deleted tip", value: preview.tipId)
                .font(.system(.caption, design: .monospaced))
            if let rootPath {
                LabeledContent("Repository", value: rootPath)
                    .lineLimit(1)
            }
            if !preview.baseBranches.isEmpty {
                LabeledContent("Already merged into", value: preview.baseBranches.joined(separator: ", "))
            }
            Divider()
            HStack {
                Text("Unmerged commits")
                    .font(.headline)
                Text("\(preview.unmergedCommits.count)")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if preview.unmergedCommits.isEmpty {
                Text("No unmerged commits were found in the captured snapshot.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                List(preview.unmergedCommits, id: \.id) { commit in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(commit.shortId)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(commit.summary.isEmpty ? "(no subject)" : commit.summary)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
            HStack {
                Spacer()
                Button("Done", role: .cancel, action: onDone)
                if trackedRemoteBranch != nil {
                    Button("Delete Tracked Remote", role: .destructive, action: onDeleteTrackedRemote)
                }
                Button("Restore Branch", action: onRestore)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
    }
}

struct RebasedMultiRootBranchDeleteRecoveryView: View {
    let branchName: String
    let contexts: [BranchDeleteRecoveryContext]
    let onRestore: () -> Void
    let onDeleteTrackedRemote: (String) -> Void
    let onDone: () -> Void

    private var trackedRemoteBranches: [String] {
        Array(Set(contexts.compactMap(\.trackedRemoteBranch))).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(.orange)
                Text("Branches deleted")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            Text(
                String(localized: "The branch %@ was deleted from the selected repositories.")
                    .replacingOccurrences(of: "%@", with: branchName)
            )
                .foregroundStyle(.secondary)
            List(contexts, id: \.id) { context in
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(context.rootPath ?? String(localized: "Repository"))
                            .lineLimit(1)
                        Text(context.preview.tipId)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !context.preview.unmergedCommits.isEmpty {
                        Text(String(localized: "unmerged"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
            HStack {
                Text(
                    String(localized: "%@ repositories available to restore")
                        .replacingOccurrences(of: "%@", with: String(contexts.count))
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", role: .cancel, action: onDone)
                if trackedRemoteBranches.count == 1, let remoteBranch = trackedRemoteBranches.first {
                    Button("Delete Tracked Remote", role: .destructive) {
                        onDeleteTrackedRemote(remoteBranch)
                    }
                } else if trackedRemoteBranches.count > 1 {
                    Menu("Delete Tracked Remote") {
                        ForEach(trackedRemoteBranches, id: \.self) { remoteBranch in
                            Button(remoteBranch, role: .destructive) {
                                onDeleteTrackedRemote(remoteBranch)
                            }
                        }
                    }
                }
                Button("Restore All", action: onRestore)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 420)
    }
}

struct RebasedMultiRootTagDeleteRecoveryView: View {
    let tagName: String
    let contexts: [TagDeleteRecoveryContext]
    let onRestore: () -> Void
    let onDeleteRemote: () -> Void
    let onDone: () -> Void

    private var hasRemotes: Bool {
        contexts.contains { !$0.remotes.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(.orange)
                Text("Tags deleted")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            Text(
                String(localized: "The tag %@ was deleted from the selected repositories.")
                    .replacingOccurrences(of: "%@", with: tagName)
            )
                .foregroundStyle(.secondary)
            List(contexts, id: \.id) { context in
                HStack(spacing: 8) {
                    Image(systemName: "tag")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(context.rootPath ?? String(localized: "Repository"))
                            .lineLimit(1)
                        Text(context.tag.id)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(context.tag.kind == .annotated ? "Annotated" : "Lightweight")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
            HStack {
                Text(
                    String(localized: "%@ repositories available to restore")
                        .replacingOccurrences(of: "%@", with: String(contexts.count))
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", role: .cancel, action: onDone)
                if hasRemotes {
                    Button("Delete on Remote", role: .destructive, action: onDeleteRemote)
                }
                Button("Restore All", action: onRestore)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 420)
    }
}

/// Recovery surface shown after deleting a local tag. The saved peeled tip
/// mirrors IntelliJ's notification restore action and is independent of the
/// repository reflog.
struct TagDeleteRecoveryView: View {
    let tag: TagInfo
    let rootPath: String?
    let remotes: [RemoteInfo]
    let onRestore: () -> Void
    let onDeleteRemote: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(.orange)
                Text("Tag deleted")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            Text("The tag reference was removed, but its saved target is still available to restore.")
                .foregroundStyle(.secondary)
            LabeledContent("Tag", value: tag.name)
            LabeledContent("Target", value: tag.id)
                .font(.system(.caption, design: .monospaced))
            LabeledContent(
                "Kind",
                value: tagKindLabel
            )
            Text("Restore will recreate a lightweight tag at this target.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let rootPath {
                LabeledContent("Repository", value: rootPath)
                    .lineLimit(1)
            }
            if !tag.message.isEmpty {
                Divider()
                Text("Original message")
                    .font(.headline)
                Text(tag.message)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done", role: .cancel, action: onDone)
                if !remotes.isEmpty {
                    Button("Delete on Remote", role: .destructive, action: onDeleteRemote)
                }
                Button("Restore Tag", action: onRestore)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 320)
    }

    private var tagKindLabel: String {
        switch tag.kind {
        case .lightweight: "Lightweight"
        case .annotated: "Annotated"
        case .signed: "Signed"
        }
    }
}

/// Browse and delete tags from a selected remote without first importing them
/// into the local tag namespace. Listing and deletion both use the credential
/// broker because either operation can require authentication.
struct MultiRootRemoteTagRow: Identifiable {
    let rootPath: String
    let displayName: String
    let relativePath: String
    let tag: RemoteTagInfo

    var id: String {
        "\(rootPath)::\(tag.remote)::\(tag.name)"
    }
}

func stableMultiRootRemoteTagRows(_ rows: [MultiRootRemoteTagRow]) -> [MultiRootRemoteTagRow] {
    rows.sorted {
        let left = [$0.relativePath, $0.tag.remote, $0.tag.name, $0.rootPath]
            .joined(separator: "\u{1F}")
        let right = [$1.relativePath, $1.tag.remote, $1.tag.name, $1.rootPath]
            .joined(separator: "\u{1F}")
        return left.localizedStandardCompare(right) == .orderedAscending
    }
}

func filteredMultiRootRemoteTagRows(
    _ rows: [MultiRootRemoteTagRow],
    query: String
) -> [MultiRootRemoteTagRow] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return rows }
    return rows.filter { row in
        [row.rootPath, row.displayName, row.relativePath, row.tag.remote, row.tag.name, row.tag.id]
            .contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}

/// Browse and delete remote tags across all discovered Git roots. Every row
/// stays root-qualified because identical remote/tag names are independent
/// refs in IntelliJ's multi-repository model.
struct MultiRootRemoteTagsDialogView: View {
    let roots: [GitRootInfo]
    let broker: CredentialBroker
    let onResult: ([String], [String], Bool) -> Void
    let onDone: () -> Void

    @State private var rows: [MultiRootRemoteTagRow] = []
    @State private var selectedIDs: Set<String> = []
    @State private var query = ""
    @State private var isLoading = false
    @State private var isDeleting = false
    @State private var errorText: String?
    @State private var resultText: String?
    @State private var operationCancelHandle: GitCancelHandle?
    @State private var operationCancelling = false
    @State private var operationID = UUID()

    private var filteredRows: [MultiRootRemoteTagRow] {
        filteredMultiRootRemoteTagRows(rows, query: query)
    }

    private var allVisibleSelected: Bool {
        !filteredRows.isEmpty && filteredRows.allSatisfy { selectedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "tag.fill")
                    .foregroundStyle(.blue)
                Text("Remote Tags Across Repositories")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    loadTags()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(isLoading || isDeleting)
                .help("Refresh remote tags across repositories")
            }

            HStack(spacing: 8) {
                TextField("Search remote tags", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button(allVisibleSelected ? "Clear Selection" : "Select Visible") {
                    if allVisibleSelected {
                        selectedIDs.subtract(filteredRows.map(\.id))
                    } else {
                        selectedIDs.formUnion(filteredRows.map(\.id))
                    }
                }
                .controlSize(.small)
                .disabled(filteredRows.isEmpty || isLoading || isDeleting)
            }

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if let resultText {
                Label(resultText, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if isLoading {
                HStack {
                    Spacer()
                    ProgressView("Loading remote tags…")
                    Spacer()
                }
                .padding(.vertical, 24)
            } else if filteredRows.isEmpty {
                ContentUnavailableView(
                    "No Remote Tags",
                    systemImage: "tag.slash",
                    description: Text("No matching remote tags were found in the discovered repositories.")
                )
            } else {
                List(filteredRows) { row in
                    Toggle(isOn: selectionBinding(for: row.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Image(systemName: "tag")
                                    .foregroundStyle(.secondary)
                                Text(row.tag.name)
                                    .lineLimit(1)
                                Text(remoteTagKindLabel(row.tag.kind))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text("\(row.relativePath) · \(row.tag.remote)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(row.tag.id)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }

            HStack {
                Text("\(selectedIDs.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isLoading {
                    Button(operationCancelling ? "Canceling…" : "Cancel") {
                        cancelOperation()
                    }
                    .disabled(operationCancelling)
                } else {
                    Button("Done", role: .cancel, action: onDone)
                    Button("Delete Selected", role: .destructive) {
                        deleteSelected()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedIDs.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(width: 760, height: 600)
        .onAppear(perform: loadTags)
    }

    private func selectionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(id) },
            set: { selected in
                if selected {
                    selectedIDs.insert(id)
                } else {
                    selectedIDs.remove(id)
                }
            }
        )
    }

    private func loadTags() {
        guard !isDeleting else { return }
        operationCancelHandle?.cancel()
        let operationID = UUID()
        self.operationID = operationID
        let cancelHandle = GitCancelHandle()
        operationCancelHandle = cancelHandle
        operationCancelling = false
        isLoading = true
        errorText = nil
        resultText = nil
        let roots = roots
        let broker = broker
        Task.detached(priority: .userInitiated) {
            var loadedRows: [MultiRootRemoteTagRow] = []
            var failures: [String] = []
            var cancelled = false
            rootLoop: for root in roots {
                if cancelHandle.isCancelled() {
                    cancelled = true
                    break
                }
                do {
                    let repo = try openRepository(path: root.path)
                    for remote in try repo.remoteList() {
                        if cancelHandle.isCancelled() {
                            cancelled = true
                            break rootLoop
                        }
                        do {
                            let tags = try repo.remoteTagListWithAuthAndCancel(
                                remote: remote.name,
                                broker: broker,
                                cancel: cancelHandle
                            )
                            loadedRows.append(contentsOf: tags.map { tag in
                                MultiRootRemoteTagRow(
                                    rootPath: root.path,
                                    displayName: root.displayName,
                                    relativePath: root.relativePath,
                                    tag: tag
                                )
                            })
                        } catch {
                            if cancelHandle.isCancelled() {
                                cancelled = true
                                break rootLoop
                            }
                            failures.append("\(root.relativePath) · \(remote.name): \(error)")
                        }
                    }
                } catch {
                    if cancelHandle.isCancelled() {
                        cancelled = true
                        break
                    }
                    failures.append("\(root.relativePath): \(error)")
                }
            }
            let sortedRows = stableMultiRootRemoteTagRows(loadedRows)
            let loadErrorText = failures.isEmpty
                ? nil
                : "Some repositories or remotes could not be loaded: " + failures.joined(separator: " | ")
            let wasCancelled = cancelled
            await MainActor.run {
                guard self.operationID == operationID else { return }
                self.rows = sortedRows
                self.selectedIDs = self.selectedIDs.intersection(Set(sortedRows.map(\.id)))
                self.isLoading = false
                self.operationCancelHandle = nil
                self.operationCancelling = false
                self.errorText = wasCancelled
                    ? String(localized: "Remote tag operation canceled.")
                    : loadErrorText
            }
        }
    }

    private func deleteSelected() {
        let selectedRows = rows.filter { selectedIDs.contains($0.id) }
        guard !selectedRows.isEmpty else { return }
        operationCancelHandle?.cancel()
        let operationID = UUID()
        self.operationID = operationID
        let cancelHandle = GitCancelHandle()
        operationCancelHandle = cancelHandle
        operationCancelling = false
        isDeleting = true
        isLoading = true
        errorText = nil
        resultText = nil
        let broker = broker
        Task.detached(priority: .userInitiated) {
            var successes: [String] = []
            var failures: [String] = []
            var completedIDs: Set<String> = []
            var cancelled = false
            rowLoop: for row in selectedRows {
                if cancelHandle.isCancelled() {
                    cancelled = true
                    break
                }
                let label = "\(row.relativePath) · \(row.tag.remote)/\(row.tag.name)"
                do {
                    let repo = try openRepository(path: row.rootPath)
                    let deleted = try repo.deleteRemoteTagWithAuthLeaseAndCancel(
                        remote: row.tag.remote,
                        tag: row.tag.name,
                        expectedObjectId: row.tag.objectId,
                        broker: broker,
                        cancel: cancelHandle
                    )
                    if deleted {
                        successes.append(label)
                        completedIDs.insert(row.id)
                    } else {
                        failures.append("\(label): already absent")
                        completedIDs.insert(row.id)
                    }
                } catch {
                    if cancelHandle.isCancelled() {
                        cancelled = true
                        break rowLoop
                    }
                    failures.append("\(label): \(error)")
                }
            }
            let completedSuccesses = successes
            let completedFailures = failures
            let completedRowIDs = completedIDs
            let wasCancelled = cancelled
            let resultText = "Deleted \(completedSuccesses.count) remote tag(s)."
                + (completedFailures.isEmpty ? "" : " Failed \(completedFailures.count): " + completedFailures.joined(separator: " | "))
            await MainActor.run {
                guard self.operationID == operationID else { return }
                self.isDeleting = false
                self.isLoading = false
                self.operationCancelHandle = nil
                self.operationCancelling = false
                self.selectedIDs.subtract(completedRowIDs)
                self.resultText = wasCancelled
                    ? String(localized: "Remote tag deletion canceled; completed changes were kept.")
                    : resultText
                self.onResult(completedSuccesses, completedFailures, wasCancelled)
                if !wasCancelled {
                    self.loadTags()
                }
            }
        }
    }

    private func cancelOperation() {
        guard isLoading, !operationCancelling else { return }
        operationCancelling = true
        operationCancelHandle?.cancel()
    }

    private func remoteTagKindLabel(_ kind: TagKind) -> String {
        switch kind {
        case .lightweight: "Lightweight"
        case .annotated: "Annotated"
        case .signed: "Signed"
        }
    }
}

struct RemoteTagsDialogView: View {
    let repo: Repository
    let broker: CredentialBroker
    let remotes: [RemoteInfo]
    let onDeleted: (String, String) -> Void
    let onDone: () -> Void

    @State private var selectedRemote: String
    @State private var remoteTags: [RemoteTagInfo] = []
    @State private var query = ""
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var pendingDelete: RemoteTagInfo?
    @State private var operationCancelHandle: GitCancelHandle?
    @State private var operationCancelling = false
    @State private var operationID = UUID()

    init(
        repo: Repository,
        broker: CredentialBroker,
        remotes: [RemoteInfo],
        onDeleted: @escaping (String, String) -> Void,
        onDone: @escaping () -> Void
    ) {
        self.repo = repo
        self.broker = broker
        self.remotes = remotes
        self.onDeleted = onDeleted
        self.onDone = onDone
        _selectedRemote = State(
            initialValue: resolveSelectedRemoteName(
                selectedRemote: nil,
                availableRemoteNames: remotes.map(\.name)
            ) ?? ""
        )
    }

    private var filteredTags: [RemoteTagInfo] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return remoteTags }
        return remoteTags.filter { $0.name.localizedCaseInsensitiveContains(value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "tag.fill")
                    .foregroundStyle(.blue)
                Text("Remote Tags")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    loadTags()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(isLoading || selectedRemote.isEmpty)
                .help("Refresh remote tags")
            }

            Picker("Remote", selection: $selectedRemote) {
                Text("Select a remote…").tag("")
                ForEach(remotes, id: \.name) { remote in
                    Text(remote.name).tag(remote.name)
                }
            }
            .onChange(of: selectedRemote) { _, _ in
                loadTags()
            }

            TextField("Search remote tags", text: $query)
                .textFieldStyle(.roundedBorder)

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if isLoading {
                HStack {
                    Spacer()
                    ProgressView("Loading remote tags…")
                    Spacer()
                }
                .padding(.vertical, 24)
            } else if filteredTags.isEmpty {
                ContentUnavailableView(
                    "No Remote Tags",
                    systemImage: "tag.slash",
                    description: Text("The selected remote has no matching tags.")
                )
            } else {
                List(filteredTags, id: \.name) { tag in
                    HStack(spacing: 8) {
                        Image(systemName: "tag")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tag.name)
                                .lineLimit(1)
                            Text(tag.id)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Text(remoteTagKindLabel(tag.kind))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Delete", role: .destructive) {
                            pendingDelete = tag
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }

            HStack {
                Spacer()
                if isLoading {
                    Button(operationCancelling ? "Canceling…" : "Cancel") {
                        cancelOperation()
                    }
                    .disabled(operationCancelling)
                } else {
                    Button("Done", role: .cancel, action: onDone)
                }
            }
        }
        .padding(20)
        .frame(width: 640, height: 500)
        .onAppear {
            loadTags()
        }
        .alert(
            "Delete Remote Tag?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { isPresented in
                    if !isPresented { pendingDelete = nil }
                }
            )
        ) {
            Button("Delete", role: .destructive) {
                guard let tag = pendingDelete else { return }
                pendingDelete = nil
                deleteTag(tag)
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if let pendingDelete {
                Text(verbatim: pendingDelete.name + " · " + pendingDelete.remote)
            }
        }
    }

    private func loadTags() {
        let remote = selectedRemote
        operationCancelHandle?.cancel()
        let operationID = UUID()
        self.operationID = operationID
        let cancelHandle = GitCancelHandle()
        operationCancelHandle = cancelHandle
        operationCancelling = false
        guard !remote.isEmpty else {
            remoteTags = []
            operationCancelHandle = nil
            isLoading = false
            return
        }
        isLoading = true
        errorText = nil
        Task.detached(priority: .userInitiated) {
            do {
                let tags = try repo.remoteTagListWithAuthAndCancel(
                    remote: remote,
                    broker: broker,
                    cancel: cancelHandle
                )
                await MainActor.run {
                    guard self.operationID == operationID,
                          self.selectedRemote == remote else { return }
                    self.remoteTags = tags
                    self.isLoading = false
                    self.operationCancelHandle = nil
                    self.operationCancelling = false
                }
            } catch {
                await MainActor.run {
                    guard self.operationID == operationID,
                          self.selectedRemote == remote else { return }
                    self.isLoading = false
                    self.operationCancelHandle = nil
                    self.operationCancelling = false
                    self.errorText = cancelHandle.isCancelled()
                        ? String(localized: "Remote tag operation canceled.")
                        : String(describing: error)
                }
            }
        }
    }

    private func deleteTag(_ tag: RemoteTagInfo) {
        operationCancelHandle?.cancel()
        let operationID = UUID()
        self.operationID = operationID
        let cancelHandle = GitCancelHandle()
        operationCancelHandle = cancelHandle
        operationCancelling = false
        isLoading = true
        errorText = nil
        let remote = tag.remote
        Task.detached(priority: .userInitiated) {
            var didDelete = false
            do {
                didDelete = try repo.deleteRemoteTagWithAuthLeaseAndCancel(
                    remote: remote,
                    tag: tag.name,
                    expectedObjectId: tag.objectId,
                    broker: broker,
                    cancel: cancelHandle
                )
                guard !cancelHandle.isCancelled() else {
                    let completedDelete = didDelete
                    await MainActor.run {
                        guard self.operationID == operationID else { return }
                        self.isLoading = false
                        self.operationCancelHandle = nil
                        self.operationCancelling = false
                        self.errorText = completedDelete
                            ? String(localized: "Remote tag deletion canceled; completed changes were kept.")
                            : String(localized: "Remote tag operation canceled.")
                    }
                    return
                }
                let tags = try repo.remoteTagListWithAuthAndCancel(
                    remote: remote,
                    broker: broker,
                    cancel: cancelHandle
                )
                let completedDelete = didDelete
                await MainActor.run {
                    guard self.operationID == operationID,
                          self.selectedRemote == remote else { return }
                    self.remoteTags = tags
                    self.isLoading = false
                    self.operationCancelHandle = nil
                    self.operationCancelling = false
                    if completedDelete {
                        self.onDeleted(remote, tag.name)
                    } else {
                        self.errorText = "The remote tag was already absent."
                    }
                }
            } catch {
                let completedDelete = didDelete
                await MainActor.run {
                    guard self.operationID == operationID else { return }
                    self.isLoading = false
                    self.operationCancelHandle = nil
                    self.operationCancelling = false
                    if cancelHandle.isCancelled() {
                        if completedDelete {
                            self.remoteTags.removeAll { $0.name == tag.name }
                        }
                        self.errorText = completedDelete
                            ? String(localized: "Remote tag deletion canceled; completed changes were kept.")
                            : String(localized: "Remote tag operation canceled.")
                    } else {
                        self.errorText = String(describing: error)
                    }
                }
            }
        }
    }

    private func cancelOperation() {
        guard isLoading, !operationCancelling else { return }
        operationCancelling = true
        operationCancelHandle?.cancel()
    }

    private func remoteTagKindLabel(_ kind: TagKind) -> String {
        switch kind {
        case .lightweight: "Lightweight"
        case .annotated: "Annotated"
        case .signed: "Signed"
        }
    }
}

/// IntelliJ-style multi-root branch creation. The branch name is shared, while
/// each selected Git root remains an independent operation target.
struct RebasedMultiRootNewBranchDialog: View {
    @Binding var name: String
    @Binding var baseRevision: String
    @Binding var checkout: Bool
    @Binding var resetExisting: Bool
    @Binding var selectedRootPaths: Set<String>
    let roots: [GitRootInfo]
    let existingBranchNames: [String: Set<String>]
    let validateName: (String) -> String?
    let onCreate: () -> Void
    let onCancel: () -> Void

    private var allSelected: Bool {
        !roots.isEmpty && roots.allSatisfy { selectedRootPaths.contains($0.path) }
    }

    private var hasExistingBranch: Bool {
        let candidate = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return false }
        return selectedRootPaths.contains { path in
            existingBranchNames[path]?.contains(candidate) == true
        }
    }

    private func selectionBinding(for path: String) -> Binding<Bool> {
        Binding(
            get: { selectedRootPaths.contains(path) },
            set: { isSelected in
                if isSelected {
                    selectedRootPaths.insert(path)
                } else {
                    selectedRootPaths.remove(path)
                }
            }
        )
    }

    var body: some View {
        let validationMessage = validateName(name)
        VStack(alignment: .leading, spacing: 14) {
            Text("New Branch").font(.title3.weight(.semibold))
            Text("Create in Git roots")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Branch name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onChange(of: name) { _, value in
                    let cleaned = GitBranchNameCleanup.cleanUpOnTyping(value)
                    if cleaned != value { name = cleaned }
                }
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                Text("Create from")
                    .foregroundStyle(.secondary)
                TextField("HEAD", text: $baseRevision)
                    .textFieldStyle(.roundedBorder)
            }
            Toggle("Checkout branch", isOn: $checkout)
                .toggleStyle(.checkbox)
            Toggle("Overwrite existing branch", isOn: $resetExisting)
                .toggleStyle(.checkbox)
                .disabled(!hasExistingBranch)
            Divider()
            Toggle(
                "All repositories",
                isOn: Binding(
                    get: { allSelected },
                    set: { isSelected in
                        selectedRootPaths = isSelected ? Set(roots.map(\.path)) : []
                    }
                )
            )
            .toggleStyle(.checkbox)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(roots, id: \.path) { root in
                        Toggle(isOn: selectionBinding(for: root.path)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(root.displayName)
                                Text(root.relativePath)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(maxHeight: 150)
            if selectedRootPaths.isEmpty {
                Text("Select at least one repository")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text("\(selectedRootPaths.count) repositories selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Create", action: onCreate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || validationMessage != nil
                            || selectedRootPaths.isEmpty
                    )
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}

/// IntelliJ GitRenameBranchAction 的多 root 选择器：同名分支可能存在于
/// 多个 Git root，重命名必须先明确受影响仓库以及是否解除 upstream。
struct RebasedMultiRootRenameBranchDialog: View {
    let oldName: String
    @Binding var newName: String
    @Binding var unsetUpstream: Bool
    @Binding var selectedRootPaths: Set<String>
    let snapshots: [GitRootBranchSnapshot]
    let validateName: (String) -> String?
    let onRename: () -> Void
    let onCancel: () -> Void

    private var eligibleSnapshots: [GitRootBranchSnapshot] {
        snapshots
            .filter { snapshot in snapshot.branches.contains(where: { $0.name == oldName }) }
            .sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
    }

    private var allSelected: Bool {
        !eligibleSnapshots.isEmpty
            && eligibleSnapshots.allSatisfy { selectedRootPaths.contains($0.rootPath) }
    }

    private var hasUpstream: Bool {
        eligibleSnapshots.contains { snapshot in
            guard snapshot.branches.contains(where: { $0.name == oldName }) else { return false }
            return snapshot.syncStatuses.contains {
                $0.branch == oldName && $0.trackingExists
            }
        }
    }

    private func selectionBinding(for path: String) -> Binding<Bool> {
        Binding(
            get: { selectedRootPaths.contains(path) },
            set: { isSelected in
                if isSelected {
                    selectedRootPaths.insert(path)
                } else {
                    selectedRootPaths.remove(path)
                }
            }
        )
    }

    var body: some View {
        let validationMessage = validateName(newName)
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Branch")
                .font(.title3.weight(.semibold))
            Text(
                String(localized: "Rename %@ in Git roots")
                    .replacingOccurrences(of: "%@", with: oldName)
            )
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("New branch name", text: $newName)
                .textFieldStyle(.roundedBorder)
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if hasUpstream {
                Toggle("Unset upstream after rename", isOn: $unsetUpstream)
                    .toggleStyle(.checkbox)
            }
            Divider()
            Toggle(
                "All repositories",
                isOn: Binding(
                    get: { allSelected },
                    set: { isSelected in
                        selectedRootPaths = isSelected ? Set(eligibleSnapshots.map(\.rootPath)) : []
                    }
                )
            )
            .toggleStyle(.checkbox)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(eligibleSnapshots, id: \.rootPath) { snapshot in
                        Toggle(isOn: selectionBinding(for: snapshot.rootPath)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(snapshot.displayName)
                                Text(snapshot.relativePath)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(maxHeight: 180)
            if selectedRootPaths.isEmpty {
                Text("Select at least one repository")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text(
                    String(localized: "%@ repositories selected")
                        .replacingOccurrences(of: "%@", with: String(selectedRootPaths.count))
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Rename", action: onRename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || newName.trimmingCharacters(in: .whitespacesAndNewlines) == oldName
                            || validationMessage != nil
                            || selectedRootPaths.isEmpty
                    )
            }
        }
        .padding(20)
        .frame(width: 540)
    }
}

/// Cross-root merge selection follows IntelliJ's repository operation model:
/// only roots that actually contain the local target branch are offered.
struct RebasedMultiRootMergeDialog: View {
    let branchName: String
    @Binding var selectedRootPaths: Set<String>
    @Binding var strategy: MergeStrategyChoice
    @Binding var commitMessage: String
    @Binding var useCustomCommitMessage: Bool
    @Binding var noCommit: Bool
    @Binding var noVerify: Bool
    @Binding var allowUnrelatedHistories: Bool
    let snapshots: [GitRootBranchSnapshot]
    let mergedBranchesByRoot: [String: Set<String>]
    let onMerge: () -> Void
    let onCancel: () -> Void

    private var eligibleSnapshots: [GitRootBranchSnapshot] {
        snapshots
            .filter { snapshot in
                snapshot.branches.contains { $0.name == branchName }
            }
            .sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
    }

    private var allSelected: Bool {
        !mergeableSnapshots.isEmpty
            && mergeableSnapshots.allSatisfy { selectedRootPaths.contains($0.rootPath) }
    }

    private var mergeableSnapshots: [GitRootBranchSnapshot] {
        eligibleSnapshots.filter { !branchIsAlreadyMerged(in: $0) }
    }

    private func branchIsAlreadyMerged(in snapshot: GitRootBranchSnapshot) -> Bool {
        guard let mergedBranches = mergedBranchesByRoot[snapshot.rootPath] else { return false }
        return mergeBranchIsAlreadyMerged(branchName, mergedBranches: mergedBranches)
    }

    private var selectedOptions: Set<MergeOptionChoice> {
        var options = Set<MergeOptionChoice>()
        if useCustomCommitMessage { options.insert(.commitMessage) }
        if noCommit { options.insert(.noCommit) }
        if noVerify { options.insert(.noVerify) }
        if allowUnrelatedHistories { options.insert(.allowUnrelatedHistories) }
        return options
    }

    private func normalizeOptions() {
        if !mergeOptionIsEnabled(
            .commitMessage,
            strategy: strategy,
            selectedOptions: selectedOptions
        ) {
            useCustomCommitMessage = false
            commitMessage = ""
        }
        if !mergeOptionIsEnabled(
            .noCommit,
            strategy: strategy,
            selectedOptions: selectedOptions
        ) {
            noCommit = false
        }
    }

    private func setOption(_ option: MergeOptionChoice, enabled: Bool) {
        guard enabled || mergeOptionIsEnabled(
            option,
            strategy: strategy,
            selectedOptions: selectedOptions
        ) else { return }
        switch option {
        case .commitMessage:
            useCustomCommitMessage = enabled
            if !enabled { commitMessage = "" }
        case .noCommit:
            noCommit = enabled
        case .noVerify:
            noVerify = enabled
        case .allowUnrelatedHistories:
            allowUnrelatedHistories = enabled
        }
    }

    private func selectionBinding(for path: String) -> Binding<Bool> {
        Binding(
            get: { selectedRootPaths.contains(path) },
            set: { isSelected in
                if isSelected {
                    selectedRootPaths.insert(path)
                } else {
                    selectedRootPaths.remove(path)
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Merge Branch")
                .font(.title3.weight(.semibold))
            Text(
                String(localized: "Merge %@ in Git roots")
                    .replacingOccurrences(of: "%@", with: branchName)
            )
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(
                String(localized: "Repositories run in order. Conflicts continue to the next repository; a fatal failure stops the remaining repositories and keeps successful roots available for rollback.")
            )
                .font(.caption)
                .foregroundStyle(.orange)
            Divider()
            Toggle(
                "All eligible repositories",
                isOn: Binding(
                    get: { allSelected },
                    set: { isSelected in
                        selectedRootPaths = isSelected ? Set(mergeableSnapshots.map(\.rootPath)) : []
                    }
                )
            )
            .toggleStyle(.checkbox)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(eligibleSnapshots, id: \.rootPath) { snapshot in
                        let alreadyMerged = branchIsAlreadyMerged(in: snapshot)
                        Toggle(isOn: selectionBinding(for: snapshot.rootPath)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(snapshot.displayName)
                                Text(snapshot.relativePath)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if alreadyMerged {
                                    Text("Already merged into current branch")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(alreadyMerged)
                    }
                }
            }
            .frame(maxHeight: 180)
            if eligibleSnapshots.isEmpty {
                Text("No repository contains this local branch.")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if mergeableSnapshots.isEmpty {
                Text("This branch is already merged in every eligible repository.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if selectedRootPaths.isEmpty {
                Text("Select at least one repository")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text(
                    String(localized: "%@ repositories selected")
                        .replacingOccurrences(of: "%@", with: String(selectedRootPaths.count))
                )
                    .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("Strategy")
                    .foregroundStyle(.secondary)
                Text(strategy.title)
                Spacer()
                Menu("Modify options…") {
                    Section("Merge strategy") {
                        ForEach(MergeStrategyChoice.allCases) { choice in
                            Button {
                                guard mergeStrategyIsEnabled(
                                    choice,
                                    selectedOptions: selectedOptions
                                ) else { return }
                                strategy = choice
                                normalizeOptions()
                            } label: {
                                Label(
                                    choice.title,
                                    systemImage: strategy == choice ? "checkmark" : ""
                                )
                            }
                            .disabled(!mergeStrategyIsEnabled(
                                choice,
                                selectedOptions: selectedOptions
                            ))
                        }
                    }
                    Section("Merge options") {
                        Toggle(
                            MergeOptionChoice.commitMessage.title,
                            isOn: Binding(
                                get: { useCustomCommitMessage },
                                set: { setOption(.commitMessage, enabled: $0) }
                            )
                        )
                        .disabled(!mergeOptionIsEnabled(
                            .commitMessage,
                            strategy: strategy,
                            selectedOptions: selectedOptions
                        ))
                        Toggle(
                            MergeOptionChoice.noCommit.title,
                            isOn: Binding(
                                get: { noCommit },
                                set: { setOption(.noCommit, enabled: $0) }
                            )
                        )
                        .disabled(!mergeOptionIsEnabled(
                            .noCommit,
                            strategy: strategy,
                            selectedOptions: selectedOptions
                        ))
                        Toggle(
                            MergeOptionChoice.noVerify.title,
                            isOn: Binding(
                                get: { noVerify },
                                set: { setOption(.noVerify, enabled: $0) }
                            )
                        )
                        Toggle(
                            MergeOptionChoice.allowUnrelatedHistories.title,
                            isOn: Binding(
                                get: { allowUnrelatedHistories },
                                set: { setOption(.allowUnrelatedHistories, enabled: $0) }
                            )
                        )
                    }
                }
                .menuStyle(.borderlessButton)
            }
            if useCustomCommitMessage {
                TextField("Commit message", text: $commitMessage)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Merge", action: onMerge)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        selectedRootPaths.isEmpty
                            || mergeableSnapshots.isEmpty
                            || !selectedRootPaths.contains(where: { path in
                                mergeableSnapshots.contains { $0.rootPath == path }
                            })
                    )
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear(perform: normalizeOptions)
    }
}

/// Recovery choice shown when a cross-root merge has both completed roots and
/// a later fatal failure. It keeps rollback explicit and guarded by each root's
/// expected HEAD in the operation layer.
struct RebasedMultiRootMergeRollbackView: View {
    let branchName: String
    let targets: [MultiRootMergeRollbackTarget]
    let failures: [String]
    let onRollback: () -> Void
    let onKeep: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Multi-root Merge Partially Completed")
                .font(.title3.weight(.semibold))
            Text(
                String(localized: "Merge %@ completed in some repositories, but the operation could not finish everywhere.")
                    .replacingOccurrences(of: "%@", with: branchName)
            )
                .font(.caption)
                .foregroundStyle(.secondary)
            if !targets.isEmpty {
                Text("Successful repositories")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(targets) { target in
                        HStack(spacing: 7) {
                            Image(systemName: target.operationPending ? "exclamationmark.triangle" : "checkmark.circle")
                                .foregroundStyle(target.operationPending ? .orange : .green)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(target.displayName)
                                Text(
                                    "HEAD \(String(target.initialHead.prefix(7))) → \(String(target.expectedHead.prefix(7)))"
                                )
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if target.operationPending {
                                Text("needs resolution")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            if !failures.isEmpty {
                Text("Failed or skipped repositories")
                    .font(.headline)
                ScrollView {
                    Text(failures.joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
            }
            Text("Rollback only runs when a repository still has the expected HEAD; newer commits are never overwritten.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done", role: .cancel, action: onDone)
                Button("Keep Partial", action: onKeep)
                Button("Rollback Successful Roots", role: .destructive, action: onRollback)
                    .keyboardShortcut(.defaultAction)
                    .disabled(targets.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 680, height: 480)
    }
}

/// Recovery choice for a multi-root rebase that was aborted or failed after
/// one or more repositories already moved their selected branch.
struct RebasedMultiRootRebaseRollbackView: View {
    let branch: String
    let targets: [MultiRootRebaseRollbackTarget]
    let failures: [String]
    let onRollback: () -> Void
    let onKeep: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Multi-root Rebase Partially Completed")
                .font(.title3.weight(.semibold))
            Text(
                String(localized: "Rebase %@ completed in some repositories, but the operation was stopped before every repository finished.")
                    .replacingOccurrences(of: "%@", with: branch)
            )
                .font(.caption)
                .foregroundStyle(.secondary)
            if !targets.isEmpty {
                Text("Successful repositories")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(targets) { target in
                        HStack(spacing: 7) {
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(target.displayName)
                                Text(
                                    "HEAD \(String(target.initialHead.prefix(7))) → \(String(target.expectedHead.prefix(7)))"
                                )
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
            }
            if !failures.isEmpty {
                Text("Failed or stopped repositories")
                    .font(.headline)
                ScrollView {
                    Text(failures.joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
            }
            Text("Rollback only runs when a repository still has the expected HEAD; newer commits are never overwritten.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done", role: .cancel, action: onDone)
                Button("Keep Partial", action: onKeep)
                Button("Rollback Successful Roots", role: .destructive, action: onRollback)
                    .keyboardShortcut(.defaultAction)
                    .disabled(targets.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 680, height: 480)
    }
}

struct RebasedMultiRootDeleteBranchDialog: View {
    let branchName: String
    @Binding var selectedRootPaths: Set<String>
    let snapshots: [GitRootBranchSnapshot]
    let onDelete: () -> Void
    let onCancel: () -> Void

    private var branchSnapshots: [GitRootBranchSnapshot] {
        snapshots
            .filter { snapshot in
                snapshot.branches.contains { $0.name == branchName && !$0.isCurrent }
            }
            .sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
    }

    private var currentBranchRepositories: Int {
        snapshots.filter { snapshot in
            snapshot.branches.contains { $0.name == branchName && $0.isCurrent }
        }.count
    }

    private var allSelected: Bool {
        !branchSnapshots.isEmpty
            && branchSnapshots.allSatisfy { selectedRootPaths.contains($0.rootPath) }
    }

    private func selectionBinding(for path: String) -> Binding<Bool> {
        Binding(
            get: { selectedRootPaths.contains(path) },
            set: { isSelected in
                if isSelected {
                    selectedRootPaths.insert(path)
                } else {
                    selectedRootPaths.remove(path)
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete Branch")
                .font(.title3.weight(.semibold))
            Text(
                String(localized: "Delete %@ from Git roots")
                    .replacingOccurrences(of: "%@", with: branchName)
            )
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(
                String(localized: "Unmerged branches are force-deleted like IntelliJ's multi-repository operation; their exact tips remain available for restore.")
            )
                .font(.caption)
                .foregroundStyle(.orange)
            if currentBranchRepositories > 0 {
                Text(
                    String(localized: "%@ repositories are currently on this branch and will be skipped.")
                        .replacingOccurrences(of: "%@", with: String(currentBranchRepositories))
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            Toggle(
                "All eligible repositories",
                isOn: Binding(
                    get: { allSelected },
                    set: { isSelected in
                        selectedRootPaths = isSelected ? Set(branchSnapshots.map(\.rootPath)) : []
                    }
                )
            )
            .toggleStyle(.checkbox)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(branchSnapshots, id: \.rootPath) { snapshot in
                        Toggle(isOn: selectionBinding(for: snapshot.rootPath)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(snapshot.displayName)
                                Text(snapshot.relativePath)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(maxHeight: 180)
            if branchSnapshots.isEmpty {
                Text("No eligible repository contains a deletable copy of this branch.")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if selectedRootPaths.isEmpty {
                Text("Select at least one repository")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text(
                    String(localized: "%@ repositories selected")
                        .replacingOccurrences(of: "%@", with: String(selectedRootPaths.count))
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Delete", role: .destructive, action: onDelete)
                    .keyboardShortcut(.defaultAction)
                    .disabled(branchSnapshots.isEmpty || selectedRootPaths.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

struct RebasedMultiRootDeleteTagDialog: View {
    let tagName: String
    @Binding var selectedRootPaths: Set<String>
    let snapshots: [GitRootBranchSnapshot]
    let onDelete: () -> Void
    let onCancel: () -> Void

    private var tagSnapshots: [GitRootBranchSnapshot] {
        snapshots
            .filter { snapshot in
                snapshot.tags.contains { $0.name == tagName }
            }
            .sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
    }

    private var allSelected: Bool {
        !tagSnapshots.isEmpty
            && tagSnapshots.allSatisfy { selectedRootPaths.contains($0.rootPath) }
    }

    private func selectionBinding(for path: String) -> Binding<Bool> {
        Binding(
            get: { selectedRootPaths.contains(path) },
            set: { isSelected in
                if isSelected {
                    selectedRootPaths.insert(path)
                } else {
                    selectedRootPaths.remove(path)
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete Tag")
                .font(.title3.weight(.semibold))
            Text(
                String(localized: "Delete %@ from Git roots")
                    .replacingOccurrences(of: "%@", with: tagName)
            )
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("This removes the local tag in every selected root; its exact target remains available to restore.")
                .font(.caption)
                .foregroundStyle(.orange)
            Divider()
            Toggle(
                "All repositories",
                isOn: Binding(
                    get: { allSelected },
                    set: { isSelected in
                        selectedRootPaths = isSelected ? Set(tagSnapshots.map(\.rootPath)) : []
                    }
                )
            )
            .toggleStyle(.checkbox)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tagSnapshots, id: \.rootPath) { snapshot in
                        Toggle(isOn: selectionBinding(for: snapshot.rootPath)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(snapshot.displayName)
                                Text(snapshot.relativePath)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(maxHeight: 180)
            if tagSnapshots.isEmpty {
                Text("No repository contains this tag.")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if selectedRootPaths.isEmpty {
                Text("Select at least one repository")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text(
                    String(localized: "%@ repositories selected")
                        .replacingOccurrences(of: "%@", with: String(selectedRootPaths.count))
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Delete", role: .destructive, action: onDelete)
                    .keyboardShortcut(.defaultAction)
                    .disabled(tagSnapshots.isEmpty || selectedRootPaths.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

struct RebasedMultiRootRemoteDeleteBranchDialog: View {
    let remoteBranch: String
    @Binding var selectedRootPaths: Set<String>
    @Binding var deleteTracking: Bool
    let snapshots: [GitRootBranchSnapshot]
    let onDelete: () -> Void
    let onCancel: () -> Void

    private var eligibleSnapshots: [GitRootBranchSnapshot] {
        snapshots
            .filter { snapshot in
                snapshot.remoteBranches.contains { $0.name == remoteBranch }
            }
            .sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
    }

    private var allSelected: Bool {
        !eligibleSnapshots.isEmpty
            && eligibleSnapshots.allSatisfy { selectedRootPaths.contains($0.rootPath) }
    }

    private var commonTrackingBranches: [String] {
        let selected = eligibleSnapshots.filter { selectedRootPaths.contains($0.rootPath) }
        guard let first = selected.first else { return [] }
        let initial = Set(
            first.syncStatuses
                .filter { $0.upstream == remoteBranch && $0.trackingExists }
                .map(\.branch)
        )
        let intersection = selected.dropFirst().reduce(initial) { common, snapshot in
            common.intersection(
                snapshot.syncStatuses
                    .filter { $0.upstream == remoteBranch && $0.trackingExists }
                    .map(\.branch)
            )
        }
        let currentBranches = Set(selected.compactMap(\.headBranch))
        return intersection.subtracting(currentBranches).sorted()
    }

    private func selectionBinding(for path: String) -> Binding<Bool> {
        Binding(
            get: { selectedRootPaths.contains(path) },
            set: { isSelected in
                if isSelected {
                    selectedRootPaths.insert(path)
                } else {
                    selectedRootPaths.remove(path)
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete Remote Branch")
                .font(.title3.weight(.semibold))
            Text(
                String(localized: "Delete %@ from Git roots")
                    .replacingOccurrences(of: "%@", with: remoteBranch)
            )
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("This deletes the branch from the remote repository in every selected root.")
                .font(.caption)
                .foregroundStyle(.orange)
            Divider()
            Toggle(
                "All repositories",
                isOn: Binding(
                    get: { allSelected },
                    set: { isSelected in
                        selectedRootPaths = isSelected ? Set(eligibleSnapshots.map(\.rootPath)) : []
                    }
                )
            )
            .toggleStyle(.checkbox)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(eligibleSnapshots, id: \.rootPath) { snapshot in
                        Toggle(isOn: selectionBinding(for: snapshot.rootPath)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(snapshot.displayName)
                                Text(snapshot.relativePath)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(maxHeight: 170)
            if !commonTrackingBranches.isEmpty {
                Toggle(
                    "Also delete common local tracking branches",
                    isOn: $deleteTracking
                )
                .toggleStyle(.checkbox)
                Text(commonTrackingBranches.joined(separator: ", "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if eligibleSnapshots.isEmpty {
                Text("No repository contains this remote branch.")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if selectedRootPaths.isEmpty {
                Text("Select at least one repository")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text(
                    String(localized: "%@ repositories selected")
                        .replacingOccurrences(of: "%@", with: String(selectedRootPaths.count))
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Delete", role: .destructive, action: onDelete)
                    .keyboardShortcut(.defaultAction)
                    .disabled(eligibleSnapshots.isEmpty || selectedRootPaths.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

enum MergeStrategyChoice: String, CaseIterable, Codable, Identifiable {
    case automatic
    case fastForwardOnly
    case noFastForward
    case squash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic (fast-forward when possible)"
        case .fastForwardOnly: return "Fast-forward only"
        case .noFastForward: return "No fast-forward (create merge commit)"
        case .squash: return "Squash (single-parent commit)"
        }
    }
}

enum MergeOptionChoice: String, CaseIterable, Hashable, Identifiable {
    case commitMessage
    case noCommit
    case noVerify
    case allowUnrelatedHistories

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commitMessage: return "Use custom commit message"
        case .noCommit: return "Do not commit automatically"
        case .noVerify: return "Skip hooks"
        case .allowUnrelatedHistories: return "Allow unrelated histories"
        }
    }
}

/// Mirrors GitMergeOption.isOptionSuitable from the reference implementation.
/// Strategy choices are the mutually exclusive --no-ff/--ff-only/--squash
/// options; the remaining options are the popup's independent choices.
func mergeOptionIsEnabled(
    _ option: MergeOptionChoice,
    strategy: MergeStrategyChoice,
    selectedOptions: Set<MergeOptionChoice>
) -> Bool {
    switch option {
    case .commitMessage:
        return strategy != .fastForwardOnly
            && strategy != .squash
            && !selectedOptions.contains(.noCommit)
    case .noCommit:
        return !selectedOptions.contains(.commitMessage)
    case .noVerify, .allowUnrelatedHistories:
        return true
    }
}

func mergeStrategyIsEnabled(
    _ strategy: MergeStrategyChoice,
    selectedOptions: Set<MergeOptionChoice>
) -> Bool {
    switch strategy {
    case .automatic, .noFastForward:
        return true
    case .fastForwardOnly, .squash:
        return !selectedOptions.contains(.commitMessage)
    }
}

func mergeEngineMode(for strategy: MergeStrategyChoice) -> MergeMode {
    switch strategy {
    case .automatic: return .fastForward
    case .fastForwardOnly: return .fastForwardOnly
    case .noFastForward: return .noFastForward
    case .squash: return .squash
    }
}

func mergeBranchIsAlreadyMerged(_ value: String, mergedBranches: Set<String>) -> Bool {
    let branch = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !branch.isEmpty else { return false }
    if mergedBranches.contains(branch) { return true }
    if branch.hasPrefix("refs/heads/") {
        return mergedBranches.contains(String(branch.dropFirst("refs/heads/".count)))
    }
    if branch.hasPrefix("refs/remotes/") {
        return mergedBranches.contains(String(branch.dropFirst("refs/remotes/".count)))
    }
    return false
}

struct RebasedMergeDialog: View {
    @Binding var branch: String
    @Binding var strategy: MergeStrategyChoice
    @Binding var commitMessage: String
    @Binding var useCustomCommitMessage: Bool
    @Binding var noCommit: Bool
    @Binding var noVerify: Bool
    @Binding var allowUnrelatedHistories: Bool
    let branches: [BranchInfo]
    let mergedBranches: Set<String>
    let onMerge: () -> Void
    let onCancel: () -> Void

    private var branchAlreadyMerged: Bool {
        mergeBranchIsAlreadyMerged(branch, mergedBranches: mergedBranches)
    }

    private var selectedOptions: Set<MergeOptionChoice> {
        var options = Set<MergeOptionChoice>()
        if useCustomCommitMessage { options.insert(.commitMessage) }
        if noCommit { options.insert(.noCommit) }
        if noVerify { options.insert(.noVerify) }
        if allowUnrelatedHistories { options.insert(.allowUnrelatedHistories) }
        return options
    }

    private func normalizeOptions() {
        if !mergeOptionIsEnabled(
            .commitMessage,
            strategy: strategy,
            selectedOptions: selectedOptions
        ) {
            useCustomCommitMessage = false
            commitMessage = ""
        }
        if !mergeOptionIsEnabled(
            .noCommit,
            strategy: strategy,
            selectedOptions: selectedOptions
        ) {
            noCommit = false
        }
    }

    private func setOption(_ option: MergeOptionChoice, enabled: Bool) {
        guard enabled || mergeOptionIsEnabled(
            option,
            strategy: strategy,
            selectedOptions: selectedOptions
        ) else { return }
        switch option {
        case .commitMessage:
            useCustomCommitMessage = enabled
            if !enabled { commitMessage = "" }
        case .noCommit:
            noCommit = enabled
        case .noVerify:
            noVerify = enabled
        case .allowUnrelatedHistories:
            allowUnrelatedHistories = enabled
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Merge Revisions").font(.title3.weight(.semibold))
            Text("Select a branch or revision to merge into the current branch.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("Revision")
                    .foregroundStyle(.secondary)
                TextField("branch or revision", text: $branch)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    ForEach(branches.filter { !$0.isCurrent }, id: \.name) { item in
                        Button(item.name) { branch = item.name }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
            }
            if branchAlreadyMerged {
                Label(
                    "This branch is already merged into the current branch.",
                    systemImage: "checkmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                Text("Strategy")
                    .foregroundStyle(.secondary)
                Text(strategy.title)
                Spacer()
                Menu("Modify options…") {
                    Section("Merge strategy") {
                        ForEach(MergeStrategyChoice.allCases) { choice in
                            Button {
                                guard mergeStrategyIsEnabled(
                                    choice,
                                    selectedOptions: selectedOptions
                                ) else { return }
                                strategy = choice
                                normalizeOptions()
                            } label: {
                                Label(
                                    choice.title,
                                    systemImage: strategy == choice ? "checkmark" : ""
                                )
                            }
                            .disabled(!mergeStrategyIsEnabled(
                                choice,
                                selectedOptions: selectedOptions
                            ))
                        }
                    }
                    Section("Merge options") {
                        Toggle(
                            MergeOptionChoice.commitMessage.title,
                            isOn: Binding(
                                get: { useCustomCommitMessage },
                                set: { setOption(.commitMessage, enabled: $0) }
                            )
                        )
                        .disabled(!mergeOptionIsEnabled(
                            .commitMessage,
                            strategy: strategy,
                            selectedOptions: selectedOptions
                        ))
                        Toggle(
                            MergeOptionChoice.noCommit.title,
                            isOn: Binding(
                                get: { noCommit },
                                set: { setOption(.noCommit, enabled: $0) }
                            )
                        )
                        .disabled(!mergeOptionIsEnabled(
                            .noCommit,
                            strategy: strategy,
                            selectedOptions: selectedOptions
                        ))
                        Toggle(
                            MergeOptionChoice.noVerify.title,
                            isOn: Binding(
                                get: { noVerify },
                                set: { setOption(.noVerify, enabled: $0) }
                            )
                        )
                        Toggle(
                            MergeOptionChoice.allowUnrelatedHistories.title,
                            isOn: Binding(
                                get: { allowUnrelatedHistories },
                                set: { setOption(.allowUnrelatedHistories, enabled: $0) }
                            )
                        )
                    }
                }
                .menuStyle(.borderlessButton)
            }
            if useCustomCommitMessage {
                TextField("Commit message", text: $commitMessage)
                    .textFieldStyle(.roundedBorder)
            }
            Text(strategy == .squash
                 ? "The merged tree will be staged and finished as a single-parent commit."
                 : "The selected strategy is applied before conflict resolution and merge completion.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Merge", action: onMerge)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || branchAlreadyMerged
                    )
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: normalizeOptions)
    }
}

func rebaseInputsCanLoadRange(onto: String, branch: String, root: Bool) -> Bool {
    !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && (root || !onto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
}

func rebaseStartNeedsNoopConfirmation(interactive: Bool, rangeCount: Int) -> Bool {
    interactive && rangeCount == 0
}

let rebaseHelpDocumentationURL = URL(string: "https://git-scm.com/docs/git-rebase")!

private struct RebaseHelpPopupView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rebase a branch based on one branch to another:")
                .font(.headline)
            Text("A---B---C  main\n     \\\n      D---E    feature\n\nfeature → main\nA---B---C---D'---E'")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Link("git rebase on git-scm.com", destination: rebaseHelpDocumentationURL)
                .help("Open the Git rebase documentation")
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }
}

struct RebasedRebaseDialog: View {
    @Binding var onto: String
    @Binding var branch: String
    @Binding var repositoryPath: String
    @Binding var interactive: Bool
    @Binding var preserveMerges: Bool
    @Binding var autoSquash: Bool
    @Binding var keepEmpty: Bool
    @Binding var updateRefs: Bool
    @Binding var root: Bool
    @Binding var applyToAllRepositories: Bool
    let rangeCount: Int
    let repositories: [GitRootInfo]
    let branches: [BranchInfo]
    let onLoadRange: () -> Void
    let onRangeInputsChanged: () -> Void
    let onRepositoryChanged: () -> Void
    let onStart: () -> Void
    let onCancel: () -> Void

    @State private var showNoopConfirmation = false
    @State private var showRebaseHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rebase").font(.title3.weight(.semibold))
            if repositories.count > 1 {
                Picker("Repository", selection: $repositoryPath) {
                    ForEach(repositories, id: \.path) { repository in
                        Text(repository.displayName).tag(repository.path)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if !repositoryPath.isEmpty {
                LabeledContent("Repository") {
                    Text(repositoryPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if repositories.count > 1 {
                Toggle("Edit todo for all repositories", isOn: $applyToAllRepositories)
                    .toggleStyle(.checkbox)
            }
            HStack(spacing: 8) {
                Text("Branch")
                    .foregroundStyle(.secondary)
                TextField("branch to rebase", text: $branch)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    ForEach(branches, id: \.name) { item in
                        Button(item.name) { branch = item.name }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
            }
            HStack(spacing: 8) {
                Text(root ? "New base" : "Onto")
                    .foregroundStyle(.secondary)
                TextField(root ? "optional branch or revision" : "branch or revision", text: $onto)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    ForEach(branches, id: \.name) { item in
                        Button(item.name) { onto = item.name }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                Button {
                    showRebaseHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Show Git rebase help")
                .accessibilityLabel("Show Git rebase help")
                .popover(isPresented: $showRebaseHelp, arrowEdge: .bottom) {
                    RebaseHelpPopupView()
                }
            }
            HStack(spacing: 14) {
                Toggle("Interactive", isOn: $interactive)
                    .toggleStyle(.checkbox)
                Toggle("Preserve merge commits", isOn: $preserveMerges)
                    .toggleStyle(.checkbox)
                Toggle("Autosquash", isOn: $autoSquash)
                    .toggleStyle(.checkbox)
            }
            HStack(spacing: 14) {
                Toggle("Keep empty commits", isOn: $keepEmpty)
                    .toggleStyle(.checkbox)
                Toggle("Update refs", isOn: $updateRefs)
                    .toggleStyle(.checkbox)
                Toggle("Rebase from root", isOn: $root)
                    .toggleStyle(.checkbox)
            }
            if rangeCount > 0 {
                Text("\(rangeCount) commits loaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Load Range", action: onLoadRange)
                    .disabled(!rebaseInputsCanLoadRange(onto: onto, branch: branch, root: root))
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Start Rebase", action: requestStart)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        !rebaseInputsCanLoadRange(onto: onto, branch: branch, root: root)
                    )
            }
        }
        .padding(20)
        .frame(width: 600)
        .onChange(of: onto) { _, _ in
            onRangeInputsChanged()
        }
        .onChange(of: branch) { _, _ in
            onRangeInputsChanged()
        }
        .onChange(of: repositoryPath) { _, _ in
            onRepositoryChanged()
        }
        .onChange(of: preserveMerges) { _, _ in
            onRangeInputsChanged()
        }
        .onChange(of: interactive) { _, newValue in
            if !newValue {
                onRangeInputsChanged()
            }
        }
        .onChange(of: root) { _, _ in
            onRangeInputsChanged()
        }
        .alert("No Commits to Rebase", isPresented: $showNoopConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Continue", action: onStart)
        } message: {
            Text("The selected branch has no commits to rebase. Continue anyway?")
        }
    }

    private func requestStart() {
        guard rebaseInputsCanLoadRange(onto: onto, branch: branch, root: root) else { return }
        if rebaseStartNeedsNoopConfirmation(interactive: interactive, rangeCount: rangeCount) {
            showNoopConfirmation = true
        } else {
            onStart()
        }
    }
}

/// Multi-root interactive rebase keeps one independent todo list per Git
/// root.  IntelliJ presents the operation as one workflow, but never reuses
/// commit indexes from one repository in another repository.
struct MultiRootRebaseTodoDraft: Identifiable, Sendable {
    let rootPath: String
    let displayName: String
    var items: [RebaseTodoItem]
    var rawTodo: String?
    var loadError: String?

    var id: String { rootPath }
}

func multiRootRebaseNoopRootPaths(_ drafts: [MultiRootRebaseTodoDraft]) -> [String] {
    drafts
        .filter { $0.loadError == nil && $0.items.isEmpty }
        .map(\.rootPath)
}

struct MultiRootRawTodoContext: Identifiable, Sendable {
    let rootPath: String
    let displayName: String
    let onto: String
    let preserveMerges: Bool
    let root: Bool

    var id: String { rootPath }
}

private struct MultiRootRebaseDetailSelection: Equatable {
    let rootPath: String
    let commitID: String
}

func multiRootRebaseDetailCommitIDs(
    draft: MultiRootRebaseTodoDraft,
    selectedIDs: Set<String>,
    focusedID: String
) -> [String] {
    if selectedIDs.isEmpty {
        return [focusedID]
    }
    return draft.items
        .map(\.commitId)
        .filter { selectedIDs.contains($0) }
}

/// The batch counterpart of `RebaseTodoEditorView`.  The root sections share
/// one confirmation surface while action changes and ordering remain scoped
/// to the selected root.
struct MultiRootRebaseTodoEditorView: View {
    let onto: String
    let branch: String
    @Binding var drafts: [MultiRootRebaseTodoDraft]
    let preserveMerges: Bool
    let autoSquash: Bool
    let keepEmpty: Bool
    let updateRefs: Bool
    let root: Bool
    let onStart: () -> Void
    let onCancel: () -> Void
    let onOpenRawTodo: (MultiRootRebaseTodoDraft) -> Void

    @State private var initialItemsByRoot: [String: [RebaseTodoItem]]
    @State private var historyByRoot: [String: RebaseTodoEditHistory]
    @State private var selectedByRoot: [String: Set<String>] = [:]
    @State private var bulkActionByRoot: [String: RebaseTodoAction] = [:]
    @State private var detailSelection: MultiRootRebaseDetailSelection?
    @State private var repositoriesByRoot: [String: Repository] = [:]
    @State private var repositoryErrorsByRoot: [String: String] = [:]
    @State private var commandsHelpContext: RebaseCommandsHelpContext?
    @State private var showDiscardChangesAlert = false
    @State private var showNoopConfirmation = false

    init(
        onto: String,
        branch: String,
        drafts: Binding<[MultiRootRebaseTodoDraft]>,
        preserveMerges: Bool,
        autoSquash: Bool,
        keepEmpty: Bool,
        updateRefs: Bool,
        root: Bool,
        onStart: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onOpenRawTodo: @escaping (MultiRootRebaseTodoDraft) -> Void
    ) {
        self.onto = onto
        self.branch = branch
        self._drafts = drafts
        self.preserveMerges = preserveMerges
        self.autoSquash = autoSquash
        self.keepEmpty = keepEmpty
        self.updateRefs = updateRefs
        self.root = root
        self.onStart = onStart
        self.onCancel = onCancel
        self.onOpenRawTodo = onOpenRawTodo
        let initialItems = Dictionary(
            uniqueKeysWithValues: drafts.wrappedValue
                .filter { $0.loadError == nil }
                .map { ($0.rootPath, $0.items) }
        )
        self._initialItemsByRoot = State(initialValue: initialItems)
        self._historyByRoot = State(initialValue: initialItems.mapValues(RebaseTodoEditHistory.init(initial:)))
    }

    private var hasErrors: Bool {
        drafts.contains { $0.loadError != nil }
    }

    private var noopRootPaths: [String] {
        multiRootRebaseNoopRootPaths(drafts)
    }

    private var totalItems: Int {
        drafts.reduce(0) { $0 + $1.items.count }
    }

    private var summaryText: String {
        let rangeDescription = onto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? branch + " from repository root"
            : branch + " onto " + shortId(onto)
        return rangeDescription + " · " + String(drafts.count)
            + " repositories · " + String(totalItems) + " commits"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Multi-root Interactive Rebase")
                        .font(.title3.weight(.semibold))
                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if preserveMerges || autoSquash || keepEmpty || updateRefs || root {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.secondary)
                        .help("Advanced rebase options are applied to every repository")
                }
            }

            Text("Each repository has its own todo list. Changes to one section do not affect another repository.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if preserveMerges {
                Label(
                    "Preserve merge topology: merge anchors stay fixed; commits may reorder inside their branch segment. After reordering, squash/fixup is disabled until reset.",
                    systemImage: "arrow.triangle.merge"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if !noopRootPaths.isEmpty {
                Label(
                    "\(noopRootPaths.count) repository\(noopRootPaths.count == 1 ? "" : "ies") has no commits to rebase; starting will ask for confirmation.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HSplitView {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(drafts.indices, id: \.self) { rootIndex in
                            rootSection(rootIndex)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minWidth: 680, idealWidth: 760, maxWidth: .infinity)

                if let detailSelection,
                   let detailRepository = repositoriesByRoot[detailSelection.rootPath] {
                    RebaseTodoCommitDetailsPane(
                        repo: detailRepository,
                        commitIDs: detailCommitIDs(for: detailSelection)
                    )
                    .frame(minWidth: 380, idealWidth: 460, maxWidth: .infinity)
                } else if let detailSelection,
                          let repositoryError = repositoryErrorsByRoot[detailSelection.rootPath] {
                    Label(repositoryError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                } else if detailSelection != nil {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Loading commit details…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "sidebar.right")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("Select a commit to view details")
                            .foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 400, maxHeight: 620)

            HStack {
                if hasErrors {
                    Label("Every repository must have a valid todo before starting", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: requestCancel)
                Button("Start Rebase", action: requestStart)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(hasErrors || drafts.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 1180, minHeight: 620)
        .task(id: drafts.map(\.rootPath)) {
            let rootPaths = drafts.map(\.rootPath)
            let result = await Task.detached(priority: .userInitiated) {
                var repositories: [String: Repository] = [:]
                var errors: [String: String] = [:]
                for rootPath in rootPaths {
                    do {
                        let repository = try openRepository(path: rootPath)
                        repositories[rootPath] = repository
                    } catch {
                        errors[rootPath] = error.localizedDescription
                    }
                }
                return (repositories, errors)
            }.value
            guard !Task.isCancelled else { return }
            repositoriesByRoot = result.0
            repositoryErrorsByRoot = result.1
        }
        .sheet(item: $commandsHelpContext) { context in
            RebaseCommandsHelpView(title: context.title, items: context.items)
        }
        .alert("Discard Rebase Changes?", isPresented: $showDiscardChangesAlert) {
            Button("Keep Editing", role: .cancel) {}
            Button("Discard Changes", role: .destructive, action: onCancel)
        } message: {
            Text("One or more Git roots have unsaved interactive rebase changes.")
        }
        .alert("No Commits to Rebase", isPresented: $showNoopConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Continue", action: onStart)
        } message: {
            Text("One or more selected repositories have no commits to rebase. Continue anyway?")
        }
    }

    @ViewBuilder
    private func rootSection(_ rootIndex: Int) -> some View {
        let draft = drafts[rootIndex]
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(draft.displayName, systemImage: "externaldrive")
                    .font(.callout.weight(.semibold))
                Text(draft.rootPath)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let initialItems = initialItemsByRoot[draft.rootPath] {
                    Button("Undo") { undo(rootIndex: rootIndex) }
                        .disabled(!(historyByRoot[draft.rootPath]?.canUndo ?? false))
                        .help("Undo the last todo edit in this repository")
                    Button("Redo") { redo(rootIndex: rootIndex) }
                        .disabled(!(historyByRoot[draft.rootPath]?.canRedo ?? false))
                        .help("Redo the last todo edit in this repository")
                    Button("Reset") {
                        let reset = resetRebaseTodoDraftItems(
                            current: drafts[rootIndex].items,
                            initial: initialItems
                        )
                        record(reset, rootIndex: rootIndex, change: .structural)
                        drafts[rootIndex].rawTodo = nil
                        selectedByRoot[draft.rootPath] = nil
                    }
                    .disabled(draft.items == initialItems && draft.rawTodo == nil)
                    .help("Restore this repository's todo from when the editor opened")
                }
                if draft.loadError == nil {
                    Button(draft.rawTodo == nil ? "Edit Native Todo…" : "Native Todo Edited") {
                        onOpenRawTodo(draft)
                    }
                    .buttonStyle(.bordered)
                    Button("Commands…") {
                        commandsHelpContext = RebaseCommandsHelpContext(
                            title: "Git Rebase Commands · \(draft.displayName)",
                            items: draft.items
                        )
                    }
                    .help("Show the available action commands for this repository's todo")
                }
                Text("\(draft.items.count) commits")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let loadError = draft.loadError {
                Label(loadError, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                HStack(spacing: 8) {
                    Picker("bulk action", selection: Binding(
                        get: { bulkActionByRoot[draft.rootPath] ?? .pick },
                        set: { bulkActionByRoot[draft.rootPath] = $0 }
                    )) {
                        Text("Pick").tag(RebaseTodoAction.pick)
                        Text("Reword").tag(RebaseTodoAction.reword)
                        Text("Edit").tag(RebaseTodoAction.edit)
                        Text("Squash").tag(RebaseTodoAction.squash)
                        Text("Fixup").tag(RebaseTodoAction.fixup)
                        Text("Drop").tag(RebaseTodoAction.drop)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 100)
                    Button("Apply to Selected") { applyBulkAction(rootIndex: rootIndex) }
                        .disabled((selectedByRoot[draft.rootPath]?.isEmpty ?? true))
                    Text("\(selectedByRoot[draft.rootPath]?.count ?? 0) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                ForEach(drafts[rootIndex].items.indices, id: \.self) { itemIndex in
                    todoRow(rootIndex: rootIndex, itemIndex: itemIndex)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
    }

    private func todoRow(rootIndex: Int, itemIndex: Int) -> some View {
        let rootPath = drafts[rootIndex].rootPath
        let commitID = drafts[rootIndex].items[itemIndex].commitId
        let isSelected = selectedByRoot[rootPath]?.contains(commitID) == true
        let selectedIDs = selectedByRoot[rootPath] ?? []
        let selectedIndices = Set(drafts[rootIndex].items.indices.filter {
            selectedIDs.contains(drafts[rootIndex].items[$0].commitId)
        })
        let contextSelection = rebaseTodoContextSelection(
            selectedIndices: selectedIndices,
            row: itemIndex
        )
        let preserveMergeOrderChanged = preserveMergeOrderChanged(rootIndex: rootIndex)
        let canEditOrDrop = contextSelection.allSatisfy {
            drafts[rootIndex].items.indices.contains($0)
                && !drafts[rootIndex].items[$0].isMergeCommit
        }
        let canUnite = uniteRebaseTodoItems(
            drafts[rootIndex].items,
            selectedIndices: contextSelection,
            action: .squash,
            preserveMerges: preserveMerges
        ) != nil && !preserveMergeOrderChanged
        return HStack(spacing: 8) {
            Button {
                toggleSelection(rootIndex: rootIndex, commitID: commitID)
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isSelected ? "Remove from selection" : "Select this commit")
            if drafts[rootIndex].items[itemIndex].isMergeCommit {
                Picker("merge action", selection: Binding(
                    get: { drafts[rootIndex].items[itemIndex].action },
                    set: { setMergeAction($0, rootIndex: rootIndex, itemIndex: itemIndex) }
                )) {
                    Text("pick").tag(RebaseTodoAction.pick)
                    Text("reword").tag(RebaseTodoAction.reword)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 100)
            } else {
                Picker("", selection: Binding(
                    get: { drafts[rootIndex].items[itemIndex].action },
                    set: { setAction($0, rootIndex: rootIndex, itemIndex: itemIndex) }
                )) {
                    Text("pick").tag(RebaseTodoAction.pick)
                    if rebaseTodoCanReword(
                        items: drafts[rootIndex].items,
                        index: itemIndex
                    ) {
                        Text("reword").tag(RebaseTodoAction.reword)
                    }
                    Text("edit").tag(RebaseTodoAction.edit)
                    if !preserveMergeOrderChanged,
                       rebaseTodoCanSquashOrFixup(
                        items: drafts[rootIndex].items,
                        index: itemIndex,
                        preserveMerges: preserveMerges
                    ) {
                        Text("squash").tag(RebaseTodoAction.squash)
                        Text("fixup").tag(RebaseTodoAction.fixup)
                    }
                    Text("drop").tag(RebaseTodoAction.drop)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 100)
            }

            Text(shortId(drafts[rootIndex].items[itemIndex].commitId))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)

            if drafts[rootIndex].items[itemIndex].isMergeCommit,
               drafts[rootIndex].items[itemIndex].action == .reword {
                TextField("reword merge message", text: Binding(
                    get: { drafts[rootIndex].items[itemIndex].message ?? drafts[rootIndex].items[itemIndex].summary },
                    set: { setMessage($0, rootIndex: rootIndex, itemIndex: itemIndex) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
            } else if drafts[rootIndex].items[itemIndex].isMergeCommit {
                Text("merge topology controlled by Git: \(drafts[rootIndex].items[itemIndex].summary)")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            } else if drafts[rootIndex].items[itemIndex].action == .squash {
                TextEditor(text: Binding(
                    get: { drafts[rootIndex].items[itemIndex].message ?? "" },
                    set: { setMessage($0, rootIndex: rootIndex, itemIndex: itemIndex) }
                ))
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 48, maxHeight: 88)
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.25))
                }
                .help("Optional final message for the squashed commit; leave empty for Git's default combined message.")
            } else if drafts[rootIndex].items[itemIndex].action == .reword {
                TextField("reword message", text: Binding(
                    get: { drafts[rootIndex].items[itemIndex].message ?? drafts[rootIndex].items[itemIndex].summary },
                    set: { setMessage($0, rootIndex: rootIndex, itemIndex: itemIndex) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
            } else {
                Text(drafts[rootIndex].items[itemIndex].summary)
                    .lineLimit(1)
                    .strikethrough(drafts[rootIndex].items[itemIndex].action == .drop)
                    .foregroundStyle(drafts[rootIndex].items[itemIndex].action == .drop ? .secondary : .primary)
            }
            Spacer()
            Button(action: { move(rootIndex: rootIndex, itemIndex: itemIndex, by: -1) }) {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.plain)
            .disabled(!rebaseTodoCanMove(
                drafts[rootIndex].items,
                selectedIndices: selectedIndices,
                requestedIndex: itemIndex,
                by: -1,
                preserveMerges: preserveMerges
            ))
            Button(action: { move(rootIndex: rootIndex, itemIndex: itemIndex, by: 1) }) {
                Image(systemName: "arrow.down")
            }
            .buttonStyle(.plain)
            .disabled(!rebaseTodoCanMove(
                drafts[rootIndex].items,
                selectedIndices: selectedIndices,
                requestedIndex: itemIndex,
                by: 1,
                preserveMerges: preserveMerges
            ))
        }
        .contextMenu {
            Button("Pick") { applyContextAction(.pick, rootIndex: rootIndex, itemIndex: itemIndex) }
            if drafts[rootIndex].items[itemIndex].isMergeCommit
                || rebaseTodoCanReword(items: drafts[rootIndex].items, index: itemIndex) {
                Button("Reword") { applyContextAction(.reword, rootIndex: rootIndex, itemIndex: itemIndex) }
            }
            if canEditOrDrop {
                Button("Edit") { applyContextAction(.edit, rootIndex: rootIndex, itemIndex: itemIndex) }
            }
            if canUnite {
                Button("Squash") { applyContextAction(.squash, rootIndex: rootIndex, itemIndex: itemIndex) }
                Button("Fixup") { applyContextAction(.fixup, rootIndex: rootIndex, itemIndex: itemIndex) }
            }
            if canEditOrDrop {
                Button("Drop") { applyContextAction(.drop, rootIndex: rootIndex, itemIndex: itemIndex) }
            }
            Divider()
            Button("Commands…") {
                commandsHelpContext = RebaseCommandsHelpContext(
                    title: "Git Rebase Commands · \(drafts[rootIndex].displayName)",
                    items: drafts[rootIndex].items
                )
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            detailSelection = MultiRootRebaseDetailSelection(rootPath: rootPath, commitID: commitID)
        }
    }

    private func move(rootIndex: Int, itemIndex: Int, by delta: Int) {
        guard drafts.indices.contains(rootIndex),
              drafts[rootIndex].items.indices.contains(itemIndex) else { return }
        let rootPath = drafts[rootIndex].rootPath
        let selectedIDs = selectedByRoot[rootPath] ?? []
        let selectedIndices = Set(drafts[rootIndex].items.indices.filter {
            selectedIDs.contains(drafts[rootIndex].items[$0].commitId)
        })
        let effectiveSelection = selectedIndices.contains(itemIndex) ? selectedIndices : [itemIndex]
        let updated = moveRebaseTodoItems(
            drafts[rootIndex].items,
            selectedIndices: effectiveSelection,
            requestedIndex: itemIndex,
            by: delta
        )
        guard updated != drafts[rootIndex].items,
              !preserveMerges
                || rebaseTodoPreserveMergeReorderIsSafe(
                    original: drafts[rootIndex].items,
                    updated: updated
                ) else { return }
        record(updated, rootIndex: rootIndex, change: .structural)
    }

    private func setAction(
        _ action: RebaseTodoAction,
        rootIndex: Int,
        itemIndex: Int
    ) {
        guard drafts.indices.contains(rootIndex),
              drafts[rootIndex].items.indices.contains(itemIndex),
              !drafts[rootIndex].items[itemIndex].isMergeCommit else { return }
        guard !preserveMergeOrderChanged(rootIndex: rootIndex)
                || (action != .squash && action != .fixup) else { return }
        var updated = drafts[rootIndex].items
        guard applyRebaseTodoAction(&updated, at: itemIndex, action: action) else { return }
        record(updated, rootIndex: rootIndex, change: .structural)
    }

    private func toggleSelection(rootIndex: Int, commitID: String) {
        guard drafts.indices.contains(rootIndex) else { return }
        let rootPath = drafts[rootIndex].rootPath
        detailSelection = MultiRootRebaseDetailSelection(rootPath: rootPath, commitID: commitID)
        var selection = selectedByRoot[rootPath, default: []]
        if !selection.insert(commitID).inserted {
            selection.remove(commitID)
        }
        selectedByRoot[rootPath] = selection
    }

    private func detailCommitIDs(for selection: MultiRootRebaseDetailSelection) -> [String] {
        guard let draft = drafts.first(where: { $0.rootPath == selection.rootPath }) else {
            return [selection.commitID]
        }
        let selectedIDs = selectedByRoot[selection.rootPath] ?? []
        return multiRootRebaseDetailCommitIDs(
            draft: draft,
            selectedIDs: selectedIDs,
            focusedID: selection.commitID
        )
    }

    private func applyBulkAction(rootIndex: Int) {
        guard drafts.indices.contains(rootIndex) else { return }
        let rootPath = drafts[rootIndex].rootPath
        let selectedIDs = selectedByRoot[rootPath] ?? []
        let indices = Set(drafts[rootIndex].items.indices.filter {
            selectedIDs.contains(drafts[rootIndex].items[$0].commitId)
        })
        guard !indices.isEmpty else { return }
        let action = bulkActionByRoot[rootPath] ?? .pick
        if action == .squash || action == .fixup {
            guard !preserveMergeOrderChanged(rootIndex: rootIndex) else { return }
            guard let united = uniteRebaseTodoItems(
                drafts[rootIndex].items,
                selectedIndices: indices,
                action: action,
                preserveMerges: preserveMerges
            ) else { return }
            record(united, rootIndex: rootIndex, change: .structural)
            return
        }

        var updated = drafts[rootIndex].items
        let selectedCommitIDs = indices.sorted().compactMap { index in
            drafts[rootIndex].items.indices.contains(index)
                ? drafts[rootIndex].items[index].commitId
                : nil
        }
        for commitID in selectedCommitIDs.reversed() {
            guard let index = updated.firstIndex(where: { $0.commitId == commitID }) else { continue }
            guard !updated[index].isMergeCommit else { continue }
            _ = applyRebaseTodoAction(&updated, at: index, action: action)
        }
        normalizeRebaseTodoActions(&updated, preserveMerges: preserveMerges)
        record(updated, rootIndex: rootIndex, change: .structural)
    }

    private func applyContextAction(
        _ action: RebaseTodoAction,
        rootIndex: Int,
        itemIndex: Int
    ) {
        guard drafts.indices.contains(rootIndex),
              drafts[rootIndex].items.indices.contains(itemIndex) else { return }
        let rootPath = drafts[rootIndex].rootPath
        let selectedIDs = selectedByRoot[rootPath] ?? []
        let selectedIndices = Set(drafts[rootIndex].items.indices.filter {
            selectedIDs.contains(drafts[rootIndex].items[$0].commitId)
        })
        let contextSelection = rebaseTodoContextSelection(
            selectedIndices: selectedIndices,
            row: itemIndex
        )
        let contextIDs = Set(contextSelection.compactMap { index in
            drafts[rootIndex].items.indices.contains(index)
                ? drafts[rootIndex].items[index].commitId
                : nil
        })

        if action == .squash || action == .fixup {
            guard !preserveMergeOrderChanged(rootIndex: rootIndex) else { return }
            guard let united = uniteRebaseTodoItems(
                drafts[rootIndex].items,
                selectedIndices: contextSelection,
                action: action,
                preserveMerges: preserveMerges
            ) else { return }
            selectedByRoot[rootPath] = contextIDs
            detailSelection = MultiRootRebaseDetailSelection(
                rootPath: rootPath,
                commitID: drafts[rootIndex].items[itemIndex].commitId
            )
            record(united, rootIndex: rootIndex, change: .structural)
            return
        }

        if action == .edit || action == .drop {
            guard contextSelection.allSatisfy({
                drafts[rootIndex].items.indices.contains($0)
                    && !drafts[rootIndex].items[$0].isMergeCommit
            }) else { return }
        }

        var updated = drafts[rootIndex].items
        let contextCommitIDs = contextSelection.sorted().compactMap { target in
            drafts[rootIndex].items.indices.contains(target)
                ? drafts[rootIndex].items[target].commitId
                : nil
        }
        for commitID in contextCommitIDs.reversed() {
            guard let target = updated.firstIndex(where: { $0.commitId == commitID }) else { continue }
            _ = applyRebaseTodoAction(&updated, at: target, action: action)
        }
        normalizeRebaseTodoActions(&updated, preserveMerges: preserveMerges)
        selectedByRoot[rootPath] = contextIDs
        detailSelection = MultiRootRebaseDetailSelection(
            rootPath: rootPath,
            commitID: drafts[rootIndex].items[itemIndex].commitId
        )
        record(updated, rootIndex: rootIndex, change: .structural)
    }

    private func setMergeAction(
        _ action: RebaseTodoAction,
        rootIndex: Int,
        itemIndex: Int
    ) {
        guard drafts.indices.contains(rootIndex),
              drafts[rootIndex].items.indices.contains(itemIndex),
              drafts[rootIndex].items[itemIndex].isMergeCommit else { return }
        var updated = drafts[rootIndex].items
        setRebaseTodoAction(&updated[itemIndex], action: action)
        record(updated, rootIndex: rootIndex, change: .structural)
    }

    private func setMessage(
        _ message: String,
        rootIndex: Int,
        itemIndex: Int
    ) {
        guard drafts.indices.contains(rootIndex),
              drafts[rootIndex].items.indices.contains(itemIndex) else { return }
        var updated = drafts[rootIndex].items
        updated[itemIndex].message = message.isEmpty ? nil : message
        record(
            updated,
            rootIndex: rootIndex,
            change: .message(commitID: updated[itemIndex].commitId)
        )
    }

    private func record(
        _ updated: [RebaseTodoItem],
        rootIndex: Int,
        change: RebaseTodoHistoryChange
    ) {
        guard drafts.indices.contains(rootIndex) else { return }
        let rootPath = drafts[rootIndex].rootPath
        var rootHistory = historyByRoot[rootPath]
            ?? RebaseTodoEditHistory(initial: drafts[rootIndex].items)
        rootHistory.record(updated, change: change)
        historyByRoot[rootPath] = rootHistory
        drafts[rootIndex].items = updated
    }

    private func undo(rootIndex: Int) {
        guard drafts.indices.contains(rootIndex) else { return }
        let rootPath = drafts[rootIndex].rootPath
        guard var rootHistory = historyByRoot[rootPath],
              let previous = rootHistory.undo() else { return }
        historyByRoot[rootPath] = rootHistory
        drafts[rootIndex].items = previous
    }

    private func redo(rootIndex: Int) {
        guard drafts.indices.contains(rootIndex) else { return }
        let rootPath = drafts[rootIndex].rootPath
        guard var rootHistory = historyByRoot[rootPath],
              let next = rootHistory.redo() else { return }
        historyByRoot[rootPath] = rootHistory
        drafts[rootIndex].items = next
    }

    private func shortId(_ id: String) -> String {
        String(id.prefix(7))
    }

    private func preserveMergeOrderChanged(rootIndex: Int) -> Bool {
        guard preserveMerges,
              drafts.indices.contains(rootIndex),
              let initial = initialItemsByRoot[drafts[rootIndex].rootPath] else {
            return false
        }
        return rebaseTodoPreserveMergeOrderChanged(
            initial: initial,
            current: drafts[rootIndex].items,
            preserveMerges: preserveMerges
        )
    }

    private func requestCancel() {
        let hasChanges = drafts.contains { draft in
            guard let initial = initialItemsByRoot[draft.rootPath] else {
                return draft.rawTodo != nil
            }
            return rebaseTodoHasUnsavedChanges(
                current: draft.items,
                initial: initial,
                rawTodo: draft.rawTodo
            )
        }
        if hasChanges {
            showDiscardChangesAlert = true
        } else {
            onCancel()
        }
    }

    private func requestStart() {
        guard !drafts.isEmpty, !hasErrors else { return }
        if !noopRootPaths.isEmpty {
            showNoopConfirmation = true
        } else {
            onStart()
        }
    }
}

struct RebasedStashDialog: View {
    let roots: [GitRootInfo]
    @Binding var selectedRootPath: String?
    @Binding var currentBranch: String
    @Binding var isLoadingRoot: Bool
    @Binding var message: String
    @Binding var keepIndex: Bool
    let onSelectRoot: (String) -> Void
    let onSave: () -> Void
    let onCancel: () -> Void

    private var activeRoot: GitRootInfo? {
        roots.first {
            canonicalExternalLogPath($0.path) == canonicalExternalLogPath(selectedRootPath ?? "")
        }
    }

    private var canSubmit: Bool {
        !isLoadingRoot && activeRoot != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Stash Changes").font(.title3.weight(.semibold))

            if roots.count > 1 {
                Picker("Git root", selection: Binding(
                    get: { selectedRootPath ?? roots.first?.path ?? "" },
                    set: { path in
                        guard !path.isEmpty, path != selectedRootPath else { return }
                        onSelectRoot(path)
                    }
                )) {
                    ForEach(roots, id: \.path) { root in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(root.displayName)
                            Text(root.relativePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(root.path)
                    }
                }
                .pickerStyle(.menu)
            } else if let root = roots.first {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Git root")
                        .foregroundStyle(.secondary)
                    Text(root.displayName)
                        .font(.system(.body, design: .monospaced))
                    Text(root.relativePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Current branch")
                    .foregroundStyle(.secondary)
                Text(currentBranch.isEmpty ? "HEAD" : currentBranch)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
            }

            TextField("Message (optional)", text: $message)
                .textFieldStyle(.roundedBorder)
            Toggle(isOn: $keepIndex) {
                Text("Keep index").font(.callout)
            }
            .toggleStyle(.checkbox)
            Text("保存后保留当前已暂存的内容；未暂存的修改会被收进 stash。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Stash", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

/// IntelliJ's GitUnstashAsDialog equivalent for a single stash entry.
/// Leaving the branch empty keeps the selected stash available for Apply/Pop;
/// entering a branch uses `git stash branch` and disables the other options.
struct RebasedUnstashAsDialog: View {
    let stash: StashInfo
    let currentBranch: String
    let validateBranchName: (String) -> String?
    let onApply: (Bool) -> Void
    let onPop: (Bool) -> Void
    let onStashBranch: (String) -> Void
    let onCancel: () -> Void

    @State private var branchName = ""
    @State private var popStash = false
    @State private var reinstateIndex = false

    private var normalizedBranchName: String {
        branchName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var branchValidationMessage: String? {
        guard !normalizedBranchName.isEmpty else { return nil }
        return validateBranchName(normalizedBranchName)
    }

    private var actionTitle: String {
        if !normalizedBranchName.isEmpty { return "Create Branch" }
        return popStash ? "Pop" : "Apply"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Unstash Changes")
                .font(.title3.weight(.semibold))

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Current branch")
                    .foregroundStyle(.secondary)
                Text(currentBranch.isEmpty ? "HEAD" : currentBranch)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Stash")
                    .foregroundStyle(.secondary)
                Text(stash.message.isEmpty ? "WIP" : stash.message)
                    .lineLimit(1)
                Text(stash.shortId)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField("Branch name (optional)", text: $branchName)
                    .textFieldStyle(.roundedBorder)
                if let branchValidationMessage {
                    Text(branchValidationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Toggle("Pop stash (remove after applying)", isOn: $popStash)
                .toggleStyle(.checkbox)
                .disabled(!normalizedBranchName.isEmpty)
            Toggle("Restore staged state", isOn: $reinstateIndex)
                .toggleStyle(.checkbox)
                .disabled(!normalizedBranchName.isEmpty)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button(actionTitle) {
                    if !normalizedBranchName.isEmpty {
                        onStashBranch(normalizedBranchName)
                    } else if popStash {
                        onPop(reinstateIndex)
                    } else {
                        onApply(reinstateIndex)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(branchValidationMessage != nil)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

/// IntelliJ's GitUnstashDialog equivalent for the top-level Git actions menu.
/// The Commit/Stash workspace still exposes the same row actions; this dialog
/// provides the repository-level entry point with the reference apply/pop,
/// restore-index, view, drop, clear, and stash-branch choices in one place.
struct RebasedUnstashDialog: View {
    let roots: [GitRootInfo]
    let selectedRootPath: String?
    let isLoadingRoot: Bool
    let stashes: [StashInfo]
    let currentBranch: String
    let onSelectRoot: (String) -> Void
    let validateBranchName: (String, String) -> String?
    let onApply: (String, String, Bool) -> Void
    let onPop: (String, String, Bool) -> Void
    let onStashBranch: (String, String, String) -> Void
    let onViewDiff: (String, String) -> Void
    let onDrop: (String, String) -> Void
    let onClear: (String) -> Void
    let onCancel: () -> Void

    @State private var selectedStashID: String?
    @State private var popStash = false
    @State private var reinstateIndex = false
    @State private var branchName = ""
    @State private var pendingDropRootPath: String?
    @State private var pendingDropStashID: String?
    @State private var showDropConfirmation = false
    @State private var showClearConfirmation = false

    private var selectedStash: StashInfo? {
        guard let selectedStashID else { return nil }
        return stashes.first { $0.id == selectedStashID }
    }

    private var normalizedBranchName: String {
        branchName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var branchValidationMessage: String? {
        guard !normalizedBranchName.isEmpty, let activeRootPath else { return nil }
        return validateBranchName(activeRootPath, normalizedBranchName)
    }

    private var activeRootPath: String? {
        guard let selectedRootPath, roots.isEmpty || roots.contains(where: { $0.path == selectedRootPath }) else {
            return nil
        }
        return selectedRootPath
    }

    private var canOperate: Bool {
        !isLoadingRoot && activeRootPath != nil && selectedStash != nil
    }

    private var clearStashesConfirmation: StashClearConfirmation {
        let repositoryName = activeRootPath.map {
            URL(fileURLWithPath: $0).lastPathComponent
        } ?? ""
        return stashClearConfirmation(repositoryName: repositoryName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Unstash Changes")
                .font(.title3.weight(.semibold))

            if roots.count > 1 {
                Picker("Git root", selection: Binding(
                    get: { selectedRootPath ?? roots.first?.path ?? "" },
                    set: { path in
                        guard !path.isEmpty, path != selectedRootPath else { return }
                        onSelectRoot(path)
                    }
                )) {
                    ForEach(roots, id: \.path) { root in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(root.displayName)
                            Text(root.relativePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(root.path)
                    }
                }
                .pickerStyle(.menu)
            } else if let root = roots.first {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Git root")
                        .foregroundStyle(.secondary)
                    Text(root.displayName)
                        .font(.system(.body, design: .monospaced))
                    Text(root.relativePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Current branch")
                    .foregroundStyle(.secondary)
                Text(currentBranch.isEmpty ? "HEAD" : currentBranch)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
            }

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Stashes")
                        .font(.headline)
                    if isLoadingRoot {
                        ProgressView("Loading stashes…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(.top, 8)
                    } else if stashes.isEmpty {
                        Text("No stashed changes")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(.top, 8)
                    } else {
                        List(stashes, id: \.id, selection: $selectedStashID) { stash in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(stash.message.isEmpty ? "WIP" : stash.message)
                                    .lineLimit(1)
                                Text(stash.shortId)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .tag(stash.id as String?)
                            .padding(.vertical, 2)
                        }
                        .listStyle(.inset)
                    }
                }
                .frame(minWidth: 300, idealWidth: 390, maxWidth: .infinity, minHeight: 180, maxHeight: 260)

                VStack(alignment: .leading, spacing: 8) {
                    Button("View Diff") {
                        if let activeRootPath, let selectedStash {
                            onViewDiff(activeRootPath, selectedStash.id)
                        }
                    }
                    .disabled(!canOperate)
                    Button("Drop", role: .destructive) {
                        pendingDropRootPath = activeRootPath
                        pendingDropStashID = selectedStash?.id
                        showDropConfirmation = selectedStash != nil
                    }
                    .disabled(!canOperate)
                    Divider()
                    Button("Clear All Stashes", role: .destructive) {
                        showClearConfirmation = true
                    }
                    .disabled(isLoadingRoot || activeRootPath == nil || stashes.isEmpty)
                    Spacer()
                }
                .frame(width: 150, alignment: .leading)
            }

            Divider()

            Toggle("Pop stash (remove after applying)", isOn: $popStash)
                .toggleStyle(.checkbox)
                .disabled(!normalizedBranchName.isEmpty)
            Toggle("Restore staged state", isOn: $reinstateIndex)
                .toggleStyle(.checkbox)
                .disabled(!normalizedBranchName.isEmpty)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Create branch from stash (optional)", text: $branchName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: branchName) { _, value in
                        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            popStash = true
                            reinstateIndex = true
                        } else {
                            popStash = false
                            reinstateIndex = false
                        }
                    }
                if let branchValidationMessage {
                    Text(branchValidationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Spacer()
                Button("Close", role: .cancel, action: onCancel)
                if normalizedBranchName.isEmpty {
                    Button(popStash ? "Pop" : "Apply") {
                        guard let activeRootPath, let selectedStash else { return }
                        if popStash {
                            onPop(activeRootPath, selectedStash.id, reinstateIndex)
                        } else {
                            onApply(activeRootPath, selectedStash.id, reinstateIndex)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canOperate)
                } else {
                    Button("Create Branch") {
                        guard let activeRootPath, let selectedStash else { return }
                        onStashBranch(activeRootPath, selectedStash.id, normalizedBranchName)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canOperate || branchValidationMessage != nil)
                }
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear {
            if selectedStashID == nil, let firstStash = stashes.first {
                selectedStashID = firstStash.id
            }
            if selectedRootPath == nil, let firstRoot = roots.first {
                onSelectRoot(firstRoot.path)
            }
        }
        .onChange(of: roots.map(\.path)) { _, paths in
            guard let selectedRootPath,
                  !paths.contains(selectedRootPath),
                  let firstRoot = roots.first else { return }
            onSelectRoot(firstRoot.path)
        }
        .onChange(of: stashes.map(\.id), initial: false) { _, ids in
            if let selectedStashID, ids.contains(selectedStashID) { return }
            self.selectedStashID = ids.first
        }
        .confirmationDialog(
            "Drop stash?",
            isPresented: $showDropConfirmation,
            titleVisibility: .visible
        ) {
            Button("Drop", role: .destructive) {
                if let pendingDropRootPath, let pendingDropStashID {
                    onDrop(pendingDropRootPath, pendingDropStashID)
                }
                pendingDropRootPath = nil
                pendingDropStashID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDropRootPath = nil
                pendingDropStashID = nil
            }
        } message: {
            Text("This permanently removes the selected stash from the repository.")
        }
        .confirmationDialog(
            clearStashesConfirmation.title,
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All Stashes", role: .destructive) {
                if let activeRootPath { onClear(activeRootPath) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(clearStashesConfirmation.message)
        }
    }
}

/// Git 项目生命周期入口：把 Rebased 的 Clone 作为项目管理的一等操作，
/// 而不是要求用户先在终端完成 clone 再回到 Arbor 打开目录。
struct RebasedRemoteBranchSelectionDialog: View {
    let commits: [CommitInfo]
    let remoteBranches: [RemoteBranchInfo]
    let onCancel: () -> Void
    let onSelect: (RemoteBranchInfo) -> Void

    @State private var selectedBranch: String

    init(
        commits: [CommitInfo],
        remoteBranches: [RemoteBranchInfo],
        onCancel: @escaping () -> Void,
        onSelect: @escaping (RemoteBranchInfo) -> Void
    ) {
        self.commits = commits
        self.remoteBranches = remoteBranches
        self.onCancel = onCancel
        self.onSelect = onSelect
        _selectedBranch = State(initialValue: remoteBranches.first?.name ?? "")
    }

    private var selectedRemoteBranch: RemoteBranchInfo? {
        remoteBranches.first { $0.name == selectedBranch }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Commits to Remote Branch")
                .font(.title3)
                .bold()
            Text("Fetch the selected remote branch, replay the selected commits in memory, then open Push with the new detached tip.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Remote branch", selection: $selectedBranch) {
                ForEach(remoteBranches, id: \.name) { branch in
                    Text("\(branch.name) · \(branch.shortId)").tag(branch.name)
                }
            }
            .pickerStyle(.menu)

            VStack(alignment: .leading, spacing: 6) {
                Text("Commits")
                    .font(.headline)
                ForEach(commits.prefix(20), id: \.id) { commit in
                    HStack(spacing: 7) {
                        Text(commit.shortId)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(commit.summary)
                            .lineLimit(1)
                        Spacer()
                    }
                }
                if commits.count > 20 {
                    Text("\(commits.count - 20) more commits…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Continue") {
                    if let selectedRemoteBranch {
                        onSelect(selectedRemoteBranch)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedRemoteBranch == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct RebasedCloneDialog: View {
    @Binding var url: String
    @Binding var parentDirectory: String
    @Binding var directoryName: String
    @Binding var recursiveSubmodules: Bool
    @Binding var shallowClone: Bool
    @Binding var depth: String
    let onChooseParent: () -> Void
    let onClone: () -> Void
    let onCancel: () -> Void

    private var canClone: Bool {
        let depthValue = depth.trimmingCharacters(in: .whitespacesAndNewlines)
        let validDepth = !shallowClone || (UInt32(depthValue) != nil && UInt32(depthValue)! > 0)
        return !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !parentDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && validDepth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clone Git Repository")
                .font(.title3.weight(.semibold))
            TextField("Repository URL", text: $url)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                TextField("Parent directory", text: $parentDirectory)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…", action: onChooseParent)
            }
            TextField("Directory name (optional)", text: $directoryName)
                .textFieldStyle(.roundedBorder)
            Toggle("Initialize and update submodules", isOn: $recursiveSubmodules)
                .toggleStyle(.checkbox)
            Toggle("Shallow clone", isOn: $shallowClone)
                .toggleStyle(.checkbox)
            if shallowClone {
                TextField("Depth (positive integer)", text: $depth)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: depth) { _, value in
                        let filtered = value.filter(\.isNumber)
                        if filtered != value { depth = filtered }
                    }
                if !depth.isEmpty && (UInt32(depth) == nil || UInt32(depth)! == 0) {
                    Text("Depth must be a positive integer.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Text("The destination folder must not already exist.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Clone", action: onClone)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canClone)
            }
        }
        .padding(20)
        .frame(width: 600)
    }
}

struct RebasedTagDialog: View {
    @Binding var name: String
    @Binding var revision: String
    @Binding var message: String
    @Binding var signKey: String
    @Binding var annotated: Bool
    @Binding var force: Bool
    let onCreate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Tag").font(.title3.weight(.semibold))
            TextField("Tag name", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("Revision (empty = HEAD)", text: $revision)
                .textFieldStyle(.roundedBorder)
            Toggle("Replace existing tag", isOn: $force)
                .toggleStyle(.checkbox)
            if force {
                Label(
                    "If this tag already exists, its target will be replaced.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            Toggle("Annotated tag", isOn: $annotated)
                .toggleStyle(.checkbox)
            if annotated {
                TextField("Tag message", text: $message)
                    .textFieldStyle(.roundedBorder)
                TextField("GPG key (optional)", text: $signKey)
                    .textFieldStyle(.roundedBorder)
                Text("A non-empty GPG key creates a signed tag via git tag -s.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Create", action: onCreate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

struct RebasedShelveDialog: View {
    @Binding var name: String
    var repo: Repository? = nil
    let entries: [FileEntry]
    let onShelve: ([String]) -> Void
    let onCancel: () -> Void
    @State private var selectedPaths: Set<String> = []
    @State private var previewPath: String?
    @State private var showPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shelve Changes").font(.title3.weight(.semibold))
            TextField("Shelf name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 10) {
                Text("Files selected: \(selectedPaths.count)/\(entries.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(showPreview ? "Hide Diff" : "Review Diff") {
                    showPreview.toggle()
                    if showPreview, previewPath == nil {
                        previewPath = entries.first(where: { selectedPaths.contains($0.path) })?.path
                    }
                }
                .disabled(repo == nil || selectedPaths.isEmpty)
            }
            if showPreview, let repo {
                HSplitView {
                    List(entries, id: \.path, selection: $previewPath) { entry in
                        Text(entry.path).lineLimit(1).tag(entry.path)
                    }
                    .frame(minWidth: 190, idealWidth: 240)
                    if let previewPath,
                       let entry = entries.first(where: { $0.path == previewPath }) {
                        DiffDetailView(
                            repo: repo,
                            entry: entry,
                            onChanged: {},
                            selectionModePath: nil
                        )
                    } else {
                        ContentUnavailableView("Select a file", systemImage: "doc.text")
                    }
                }
                .frame(height: 280)
            } else {
                List(entries, id: \.path) { entry in
                    Toggle(isOn: Binding(
                        get: { selectedPaths.contains(entry.path) },
                        set: { checked in
                            if checked { selectedPaths.insert(entry.path) }
                            else { selectedPaths.remove(entry.path) }
                        }
                    )) {
                        HStack {
                            StatusBadge(kind: entry.unstaged != .unchanged ? entry.unstaged : entry.staged)
                            Text(entry.path).lineLimit(1)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .frame(height: 220)
            }
            HStack {
                Button("Select All") { selectedPaths = Set(entries.map(\.path)) }
                Button("Clear") { selectedPaths.removeAll(); previewPath = nil }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Shelve", action: { onShelve(Array(selectedPaths)) })
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedPaths.isEmpty)
            }
        }
        .padding(20)
        .frame(width: showPreview ? 860 : 560)
        .onAppear {
            if selectedPaths.isEmpty { selectedPaths = Set(entries.map(\.path)) }
        }
    }
}

/// Repository-scoped Shelf storage configuration. The engine keeps Git refs in
/// the repository and only moves the manifest/patch artifacts, so migration is
/// explicit and cannot be mistaken for a normal folder preference.
struct RebasedShelfLocationDialog: View {
    @Binding var location: String
    @Binding var migrateExisting: Bool
    let currentLocation: String
    let onSave: () -> Void
    let onCancel: () -> Void

    private var normalizedLocation: String {
        location.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationError: String? {
        guard !normalizedLocation.isEmpty else { return "Shelf location is required." }
        guard URL(fileURLWithPath: normalizedLocation).isFileURL,
              normalizedLocation.hasPrefix("/") else {
            return "Shelf location must be an absolute path."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shelf Location")
                .font(.title3.weight(.semibold))
            Text("Choose where Shelf manifests and raw patches are stored for this Git repository.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Absolute folder path", text: $location)
                .textFieldStyle(.roundedBorder)
            Text("Current: \(currentLocation)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Toggle("Migrate existing Shelves", isOn: $migrateExisting)
                .toggleStyle(.checkbox)
            if migrateExisting {
                Text("Existing Shelf files will be copied and verified before this repository switches to the new folder. Git Shelf refs stay in the repository.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("New Shelves use the folder above. Existing Shelves remain at their current location until migrated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let validationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationError != nil || normalizedLocation == currentLocation)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

struct RebasedShelfPatchHunk: Identifiable {
    let path: String
    let index: UInt32
    let header: String
    let preview: String

    var id: String { "\(path)#\(index)" }
}

enum RebasedShelfPatchStatus: String, CaseIterable, Identifiable {
    case added = "Added"
    case deleted = "Deleted"
    case modified = "Modified"
    case renamed = "Renamed"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .added: return .green
        case .deleted: return .red
        case .modified: return .orange
        case .renamed: return .blue
        }
    }
}

struct RebasedShelfPatchFile: Identifiable {
    let path: String
    let hunks: [RebasedShelfPatchHunk]
    let isBinary: Bool
    let status: RebasedShelfPatchStatus
    let rawPatch: String

    var id: String { path }
    var isWholeFileOnly: Bool { hunks.isEmpty }
}

/// Applies a patch's raw path-strip independently from filesystem matching.
/// Keeping this pure lets the Apply Patch tree explain an invalid mapping
/// before invoking Git, while a user-selected base can still be tried again.
enum RebasedPatchPathMapper {
    static func strippedPath(rawPath: String, pathStrip: UInt32) -> String? {
        let components = rawPath
            .split(separator: "/")
            .map(String.init)
        guard !components.isEmpty, Int(pathStrip) < components.count else { return nil }
        return components.dropFirst(Int(pathStrip)).joined(separator: "/")
    }
}

struct RebasedPatchBaseCandidate: Hashable, Identifiable {
    let basePath: String
    let pathStrip: UInt32
    var contextScore: Int

    var id: String { "\(basePath)|\(pathStrip)" }

    var title: String {
        let base = basePath.isEmpty ? "Repository root" : basePath
        return "\(base) (−p\(pathStrip))"
    }
}

/// The project-scoped equivalent of IntelliJ's GlobalSearchScope.projectScope.
/// Arbor has no IDE content-root model, so a repository patch starts with its
/// worktree as the content root and accepts explicit excluded roots from the
/// caller. This keeps scope behavior data-driven instead of guessing hidden
/// directory names.
struct RebasedPatchCandidateScope: Hashable, Codable, Sendable {
    let rootPath: String
    /// Explicit content roots mirror IntelliJ's project scope without
    /// inventing module/IDE metadata. An empty list means the repository root.
    let contentRootPaths: [String]
    let excludedPaths: [String]

    init(
        rootPath: String,
        contentRootPaths: [String] = [],
        excludedPaths: [String] = []
    ) {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        self.rootPath = root
        self.contentRootPaths = Array(
            Set(contentRootPaths.map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            })
        ).sorted()
        self.excludedPaths = Array(
            Set(excludedPaths.map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            })
        ).sorted()
    }

    static func repository(rootPath: String) -> Self {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        return Self(
            rootPath: root.path,
            excludedPaths: [root.appendingPathComponent(".git").path]
        )
    }

    func contains(_ path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard normalized == rootPath || normalized.hasPrefix(rootPath + "/") else {
            return false
        }
        if !contentRootPaths.isEmpty,
           !contentRootPaths.contains(where: {
               normalized == $0 || normalized.hasPrefix($0 + "/")
           }) {
            return false
        }
        return !isExcluded(normalized)
    }

    func isExcluded(_ path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        return excludedPaths.contains {
            normalized == $0 || normalized.hasPrefix($0 + "/")
        }
    }

    /// Roots to walk for a physical index build. Nested content roots are
    /// collapsed so the same file is not visited twice.
    var scanRoots: [URL] {
        let roots = (contentRootPaths.isEmpty ? [rootPath] : contentRootPaths)
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { contains($0.path) && !isExcluded($0.path) }
            .sorted { $0.path.count < $1.path.count }
        return roots.filter { candidate in
            !roots.contains { parent in
                parent.path != candidate.path && candidate.path.hasPrefix(parent.path + "/")
            }
        }
    }
}

/// Project-scoped filename index used by patch matching. IntelliJ's
/// `PsiPatchBaseDirectoryDetector` queries `FilenameIndex` rather than the
/// Git index, so this model deliberately combines materialized project files
/// with paths known by Git and applies the caller's content/excluded scope
/// before candidates are generated.
struct RebasedPatchFilenameIndex: Hashable, Codable, Sendable {
    let rootPath: String
    let relativeFiles: [String]
    let relativeDirectories: [String]
    let directoryModificationDates: [String: TimeInterval]

    init(
        rootPath: String,
        filePaths: [String],
        directoryPaths: [String] = [],
        scope: RebasedPatchCandidateScope? = nil
    ) {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        let candidateScope = scope ?? RebasedPatchCandidateScope.repository(rootPath: root.path)
        self.rootPath = root.path

        var files = Set<String>()
        var directories = Set<String>([""])

        func relativePath(_ path: String) -> String? {
            let candidateURL: URL
            if path.hasPrefix("/") {
                candidateURL = URL(fileURLWithPath: path).standardizedFileURL
            } else {
                candidateURL = root.appendingPathComponent(path).standardizedFileURL
            }
            let candidatePath = candidateURL.path
            guard candidatePath != root.path,
                  candidateScope.rootPath == root.path,
                  candidateScope.contains(candidatePath) else {
                return nil
            }
            return String(candidatePath.dropFirst(root.path.count + 1))
        }

        func addParentDirectories(for relativePath: String) {
            let components = relativePath.split(separator: "/").map(String.init)
            guard components.count > 1 else { return }
            for depth in 1..<components.count {
                directories.insert(components.prefix(depth).joined(separator: "/"))
            }
        }

        for path in filePaths {
            guard let relative = relativePath(path), !relative.isEmpty else { continue }
            files.insert(relative)
            addParentDirectories(for: relative)
        }
        for path in directoryPaths {
            guard let relative = relativePath(path), !relative.isEmpty else { continue }
            directories.insert(relative)
        }

        self.relativeFiles = files.sorted()
        self.relativeDirectories = directories.sorted()
        self.directoryModificationDates = Self.modificationDates(
            root: root,
            relativeDirectories: self.relativeDirectories
        )
    }

    /// Build the index from all files visible under the project scope. This
    /// is intentionally an explicit provider boundary: callers can inject
    /// virtual/index-backed paths in tests or when a project root is not fully
    /// materialized, while the default path still covers untracked files.
    static func build(
        rootPath: String,
        indexedPaths: [String],
        scope: RebasedPatchCandidateScope? = nil
    ) -> Self {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        let candidateScope = scope ?? RebasedPatchCandidateScope.repository(rootPath: root.path)
        var files = indexedPaths
        var directories: [String] = []

        for scanRoot in candidateScope.scanRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: scanRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else { continue }
            for case let url as URL in enumerator {
                let path = url.standardizedFileURL.path
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                guard candidateScope.contains(path) else {
                    if isDirectory { enumerator.skipDescendants() }
                    continue
                }
                if isDirectory {
                    directories.append(path)
                } else {
                    files.append(path)
                }
            }
        }

        return Self(
            rootPath: root.path,
            filePaths: files,
            directoryPaths: directories,
            scope: candidateScope
        )
    }

    func files(matchingSuffix components: [String]) -> [String] {
        guard !components.isEmpty else { return [] }
        return relativeFiles.filter { path in
            let pathComponents = path.split(separator: "/").map(String.init)
            return pathComponents.count >= components.count
                && Array(pathComponents.suffix(components.count)) == components
        }
    }

    func directories(matchingSuffix components: [String]) -> [String] {
        guard !components.isEmpty else { return [] }
        return relativeDirectories.filter { path in
            let pathComponents = path.split(separator: "/").map(String.init)
            return pathComponents.count >= components.count
                && Array(pathComponents.suffix(components.count)) == components
        }
    }

    var indexedItems: Set<String> {
        Set(relativeFiles + relativeDirectories.filter { !$0.isEmpty })
    }

    /// A persisted filename index is valid as long as every indexed directory
    /// still exists with the same filesystem revision. Directory metadata is
    /// enough for filename membership: file content changes do not affect the
    /// candidate set, while create/delete/rename changes update a directory.
    func isFilesystemCurrent() -> Bool {
        guard !directoryModificationDates.isEmpty else { return true }
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        for (relativePath, expectedDate) in directoryModificationDates {
            let url = relativePath.isEmpty
                ? root
                : root.appendingPathComponent(relativePath)
            guard let actualDate = Self.modificationDate(for: url),
                  actualDate == expectedDate else {
                return false
            }
        }
        return true
    }

    private static func modificationDates(
        root: URL,
        relativeDirectories: [String]
    ) -> [String: TimeInterval] {
        Dictionary(uniqueKeysWithValues: relativeDirectories.compactMap { relativePath in
            let url = relativePath.isEmpty
                ? root
                : root.appendingPathComponent(relativePath)
            guard let date = modificationDate(for: url) else { return nil }
            return (relativePath, date)
        })
    }

    private static func modificationDate(for url: URL) -> TimeInterval? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970
    }
}

/// A project-scoped, persisted approximation of IntelliJ's VFS/Psi
/// FilenameIndex. The cache is keyed by root and content/excluded scope, is
/// validated through directory revisions, and can be explicitly invalidated
/// by the repository watcher. It stores names only; candidate application
/// still verifies the actual target file and patch context.
enum RebasedPatchFilenameIndexStore {
    private static let keyPrefix = "arbor.git.patchFilenameIndex.v2."

    private struct Snapshot: Codable {
        let scope: RebasedPatchCandidateScope
        let indexedPathRevision: String
        let index: RebasedPatchFilenameIndex
    }

    static func loadOrBuild(
        rootPath: String,
        indexedPaths: [String],
        scope: RebasedPatchCandidateScope? = nil,
        defaults: UserDefaults = .standard
    ) -> RebasedPatchFilenameIndex {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        let candidateScope = scope ?? RebasedPatchCandidateScope.repository(rootPath: root)
        let revision = indexedPathRevision(indexedPaths)
        let key = cacheKey(rootPath: root, scope: candidateScope)

        if let data = defaults.data(forKey: key),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
           snapshot.scope == candidateScope,
           snapshot.indexedPathRevision == revision,
           snapshot.index.rootPath == root,
           snapshot.index.isFilesystemCurrent() {
            return snapshot.index
        }

        let index = RebasedPatchFilenameIndex.build(
            rootPath: root,
            indexedPaths: indexedPaths,
            scope: candidateScope
        )
        let snapshot = Snapshot(
            scope: candidateScope,
            indexedPathRevision: revision,
            index: index
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: key)
        }
        return index
    }

    static func invalidate(
        rootPath: String,
        defaults: UserDefaults = .standard
    ) {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        let prefix = keyPrefix + encoded(root) + "."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private static func cacheKey(
        rootPath: String,
        scope: RebasedPatchCandidateScope
    ) -> String {
        let scopeData = (try? JSONEncoder().encode(scope)) ?? Data()
        return keyPrefix + encoded(rootPath) + "." + scopeData.base64EncodedString()
    }

    private static func encoded(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    private static func indexedPathRevision(_ paths: [String]) -> String {
        // Stable FNV-1a avoids relying on Swift's randomized Hashable value.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for path in paths.sorted() {
            for byte in path.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            hash ^= 0xff
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

extension RebasedUnshelveDialog {
    /// MatchPatchPaths falls back to the project root when a new file has
    /// multiple equally good VFS candidates. Existing text files still use
    /// their best context match, with the project root already preferred by
    /// `discoverBaseMappings` on ties.
    nonisolated static func automaticallySelectedBaseMapping(
        patchFiles: [RebasedShelfPatchFile],
        candidates: [RebasedPatchBaseCandidate]
    ) -> RebasedPatchBaseCandidate? {
        guard let best = candidates.first else { return nil }
        guard patchFiles.allSatisfy({ $0.status == .added }) else { return best }

        let tied = candidates.filter { $0.contextScore == best.contextScore }
        guard tied.count > 1 else { return best }
        return tied.first(where: { $0.basePath.isEmpty })
    }
}

/// Matches imported patch hunks using the same signal as IntelliJ's
/// `GenericPatchApplier.weightContextMatch(100, 5)`: one point per matching
/// split hunk, bounded by a line-position window and by the first five parts.
/// This is deliberately kept pure so candidate selection can be regression-tested.
enum RebasedPatchContextMatcher {
    private struct SplitHunk {
        let expectedOldStart: Int
        let oldLines: [String]
        let newLines: [String]
    }

    static func score(
        patch: String,
        text: String,
        maxWalk: Int = 100,
        maxPartsToCheck: Int = 5
    ) -> Int {
        guard maxPartsToCheck > 0 else { return 0 }
        let textLines = text.components(separatedBy: .newlines)
        var score = 0
        var checkedParts = 0
        for hunk in parseSplitHunks(patch: patch) {
            // GenericPatchApplier does not consume a maxPartsToCheck slot for
            // a pure insertion, because it cannot provide old-file context.
            guard !hunk.oldLines.isEmpty else { continue }
            if checkedParts == maxPartsToCheck { break }
            checkedParts += 1
            let oldMatches = matches(
                hunk.oldLines,
                in: textLines,
                expectedStart: hunk.expectedOldStart,
                maxWalk: maxWalk
            )
            let newMatches = matches(
                hunk.newLines,
                in: textLines,
                expectedStart: hunk.expectedOldStart,
                maxWalk: maxWalk
            )
            if oldMatches || newMatches { score += 1 }
        }
        return score
    }

    private static func parseSplitHunks(patch: String) -> [SplitHunk] {
        let lines = patch
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let hunkStarts = lines.indices.filter { lines[$0].hasPrefix("@@") }
        var result: [SplitHunk] = []

        for (offset, start) in hunkStarts.enumerated() {
            let nextHunk = hunkStarts.dropFirst(offset + 1).first ?? lines.count
            let end = lines[start..<nextHunk].firstIndex(where: { $0.hasPrefix("diff --git ") }) ?? nextHunk
            guard let oldStart = oldStartLine(in: lines[start]) else { continue }
            let body = Array(lines[(start + 1)..<end])

            var pendingContext: [String] = []
            var oldLineOffset = 0
            var index = 0
            while index < body.count {
                if let context = contextLine(body[index]) {
                    pendingContext.append(context)
                    oldLineOffset += 1
                    index += 1
                    continue
                }

                var oldChanges: [String] = []
                var newChanges: [String] = []
                let expectedOffset = oldLineOffset - pendingContext.count
                var hasChange = false
                while index < body.count, let type = body[index].first {
                    switch type {
                    case "-":
                        oldChanges.append(String(body[index].dropFirst()))
                        oldLineOffset += 1
                        hasChange = true
                    case "+":
                        newChanges.append(String(body[index].dropFirst()))
                        hasChange = true
                    case "\\":
                        index += 1
                        continue
                    default:
                        break
                    }
                    if type == " " || (type != "-" && type != "+" && type != "\\") {
                        break
                    }
                    index += 1
                }

                var trailingContext: [String] = []
                while index < body.count, let context = contextLine(body[index]) {
                    trailingContext.append(context)
                    oldLineOffset += 1
                    index += 1
                }

                if hasChange {
                    result.append(
                        SplitHunk(
                            expectedOldStart: max(0, oldStart - 1 + expectedOffset),
                            oldLines: pendingContext + oldChanges + trailingContext,
                            newLines: pendingContext + newChanges + trailingContext
                        )
                    )
                }
                pendingContext = trailingContext
            }
        }
        return result
    }

    private static func oldStartLine(in header: String) -> Int? {
        guard let range = header.range(of: "@@ -") else { return nil }
        let suffix = header[range.upperBound...]
        let digits = suffix.prefix { $0.isNumber }
        return Int(digits)
    }

    private static func contextLine(_ line: String) -> String? {
        guard line.first == " " else { return nil }
        return String(line.dropFirst())
    }

    private static func matches(
        _ sequence: [String],
        in lines: [String],
        expectedStart: Int,
        maxWalk: Int
    ) -> Bool {
        guard !sequence.isEmpty, sequence.count <= lines.count else { return false }
        let lastStart = lines.count - sequence.count
        let lowerBound = max(0, expectedStart - maxWalk)
        let upperBound = min(lastStart, expectedStart + maxWalk)
        guard lowerBound <= upperBound else { return false }
        for start in lowerBound...upperBound {
            if Array(lines[start..<(start + sequence.count)]) == sequence {
                return true
            }
        }
        return false
    }
}

/// Converts a raw unified/Git patch hunk into the same structured diff model
/// used by revision-backed previews. Apply Patch has no revision tree to ask
/// the engine for, but the patch itself already contains enough old/new line
/// content for a faithful side-by-side or unified viewer.
enum RebasedPatchDiffParser {
    static func parse(
        patch: String,
        path: String
    ) -> FileDiff? {
        let lines = patch
            .components(separatedBy: "\n")
            .map { line in
                line.hasSuffix("\r") ? String(line.dropLast()) : line
            }
        let hunkStarts = lines.indices.filter { lines[$0].hasPrefix("@@") }
        guard !hunkStarts.isEmpty else { return nil }

        var hunks: [DiffHunk] = []
        for (offset, start) in hunkStarts.enumerated() {
            guard let starts = parseHunkStarts(lines[start]) else { continue }
            let end = hunkStarts.dropFirst(offset + 1).first ?? lines.count
            var oldLineNumber = starts.old
            var newLineNumber = starts.new
            var oldLines: [DiffLine] = []
            var newLines: [DiffLine] = []

            for line in lines[(start + 1)..<end] {
                guard let marker = line.first else { continue }
                let text = String(line.dropFirst())
                switch marker {
                case " ":
                    let context = DiffLine(
                        kind: .context,
                        oldLine: oldLineNumber,
                        newLine: newLineNumber,
                        text: text,
                        spans: [],
                        highlights: []
                    )
                    oldLines.append(context)
                    newLines.append(context)
                    oldLineNumber += 1
                    newLineNumber += 1
                case "-":
                    oldLines.append(DiffLine(
                        kind: .deletion,
                        oldLine: oldLineNumber,
                        newLine: 0,
                        text: text,
                        spans: [],
                        highlights: []
                    ))
                    oldLineNumber += 1
                case "+":
                    newLines.append(DiffLine(
                        kind: .addition,
                        oldLine: 0,
                        newLine: newLineNumber,
                        text: text,
                        spans: [],
                        highlights: []
                    ))
                    newLineNumber += 1
                case "\\":
                    // Git's "No newline at end of file" marker is metadata.
                    continue
                default:
                    // Be tolerant of extended patch metadata inside a chunk.
                    continue
                }
            }

            hunks.append(DiffHunk(
                oldStart: starts.old,
                newStart: starts.new,
                oldLines: oldLines,
                newLines: newLines
            ))
        }

        return hunks.isEmpty ? nil : FileDiff(path: path, binary: false, hunks: hunks)
    }

    private static func parseHunkStarts(_ header: String) -> (old: UInt32, new: UInt32)? {
        let tokens = header.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count >= 3,
              let old = parseLineStart(String(tokens[1]), marker: "-"),
              let new = parseLineStart(String(tokens[2]), marker: "+") else {
            return nil
        }
        return (old, new)
    }

    private static func parseLineStart(_ token: String, marker: String) -> UInt32? {
        guard token.hasPrefix(marker) else { return nil }
        let value = token.dropFirst().split(separator: ",", maxSplits: 1).first
        return value.flatMap { UInt32($0) }
    }
}

struct RebasedUnshelveDialog: View {
    let name: String
    let paths: [String]
    let initialPaths: [String]
    let changeLists: [ChangeListInfo]
    let repo: Repository?
    var patchText: String? = nil
    @Binding var removeAppliedFilesFromShelf: Bool
    let onUnshelve: ([String], [ShelvePatchSelection], String?, Bool, String?, UInt32, String?) -> Void
    var onApplyPatch: ([String], [ShelvePatchSelection], String?, String?, UInt32) -> Void = { _, _, _, _, _ in }
    let onCancel: () -> Void
    @State private var selectedPaths: Set<String> = []
    @State private var selectedHunkIDs: Set<String> = []
    @State private var patchFiles: [RebasedShelfPatchFile] = []
    @State private var loadedPatchText = ""
    @State private var patchLoadError: String?
    @State private var isLoadingPatch = false
    @State private var previewPath: String?
    @State private var previewDiff: FileDiff?
    @State private var previewError: String?
    @State private var isLoadingPreview = false
    @State private var previewGeneration = 0
    @State private var previewPresentationMode: DiffPresentationMode = .sideBySide
    @State private var groupByDirectory = true
    @State private var collapsedPatchFolders: Set<String> = []
    @State private var targetName = ""
    @State private var changelistComment = ""
    @State private var isImportedShelf = false
    @State private var mappedBaseDirectory: String?
    @State private var mappedPathStrip: UInt32 = 1
    @State private var defaultPathStrip: UInt32 = 1
    @State private var baseDirectoryError: String?
    @State private var suggestedBaseMappings: [RebasedPatchBaseCandidate] = []

    private var selectedPathCount: Int {
        selectedPaths.intersection(paths).count
    }

    private var selectedHunkCount: Int {
        selectedHunkIDs.count
    }

    private var selectedFilesAreApplicable: Bool {
        guard isImportedShelf else { return true }
        guard !patchFiles.isEmpty else { return true }
        let selectedFiles = patchFiles.filter { selectedPaths.contains($0.path) }
        return !selectedFiles.isEmpty && selectedFiles.allSatisfy {
            patchApplicabilityIssue(for: $0) == nil
        }
    }

    private var selectedPatchSelections: [ShelvePatchSelection] {
        guard !patchFiles.isEmpty else { return [] }
        let validPaths = Set(paths)
        return patchFiles
            .filter { validPaths.contains($0.path) }
            .flatMap { file -> [ShelvePatchSelection] in
                guard selectedPaths.contains(file.path) else { return [] }
                if file.isWholeFileOnly {
                    return [ShelvePatchSelection(path: file.path, hunkIndex: nil)]
                }
                return file.hunks.compactMap { hunk in
                    selectedHunkIDs.contains(hunk.id)
                        ? ShelvePatchSelection(path: file.path, hunkIndex: hunk.index)
                        : nil
                }
            }
    }

    private var visiblePatchRows: [ShelfTreeRow] {
        let rows = shelfTreeRows(
            paths: patchFiles.map(\.path),
            groupByDirectory: groupByDirectory
        )
        guard groupByDirectory else { return rows }
        return rows.filter { row in
            !rows.contains { folder in
                folder.isFolder
                    && row.path.hasPrefix(folder.path + "/")
                    && collapsedPatchFolders.contains(folder.path)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(patchText == nil ? "Unshelve" : "Apply Patch")
                .font(.title3.weight(.semibold))
            Text(patchText == nil
                ? "Apply selected changes from this Shelf to the working tree."
                : "Review and apply the selected patch changes to the working tree.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(name)
                .font(.headline)
                .lineLimit(1)
            HStack(spacing: 8) {
                Text("Files selected: \(selectedPathCount)/\(paths.count)")
                if selectedHunkCount > 0 {
                    Text("· \(selectedHunkCount) hunks")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Select All") { selectAll() }
                Button("Clear") { clearSelection() }
                if isLoadingPatch {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
            }
            if let patchLoadError {
                Text(patchLoadError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if paths.isEmpty {
                Text("No patch files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if patchFiles.isEmpty || isLoadingPatch {
                fileSelectionFallback
            } else {
                HSplitView {
                    patchSelectionList
                        .frame(minWidth: 280, idealWidth: 360, maxWidth: 460)
                    patchPreview
                        .frame(minWidth: 360)
                }
                .frame(height: CGFloat(min(480, max(240, (paths.count + selectedHunkCount) * 30))))
            }
            if isImportedShelf {
                patchBaseDirectoryPanel
            }
            Picker("Target Changelist", selection: $targetName) {
                Text("Default / automatic").tag("")
                ForEach(changeLists, id: \.name) { list in
                    Text(list.name).tag(list.name)
                }
            }
            .pickerStyle(.menu)
            if patchText == nil {
                TextField("Changelist comment (optional)", text: $changelistComment)
                    .textFieldStyle(.roundedBorder)
            }
            if patchText == nil {
                Toggle("Remove Applied Files from Shelf", isOn: $removeAppliedFilesFromShelf)
                    .toggleStyle(.checkbox)
                if removeAppliedFilesFromShelf {
                    Text("Applied files will be moved to Recently Deleted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button(patchText == nil ? "Unshelve" : "Apply Patch", action: {
                    let selected = paths.filter { selectedPaths.contains($0) }
                    if patchText == nil {
                        onUnshelve(
                            selected,
                            selectedPatchSelections,
                            targetName.isEmpty ? nil : targetName,
                            removeAppliedFilesFromShelf,
                            mappedBaseDirectory,
                            mappedPathStrip,
                            changelistComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? nil
                                : changelistComment.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    } else {
                        onApplyPatch(
                            selected,
                            selectedPatchSelections,
                            targetName.isEmpty ? nil : targetName,
                            mappedBaseDirectory,
                            mappedPathStrip
                        )
                    }
                })
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        selectedPathCount == 0
                            || isLoadingPatch
                            || !selectedFilesAreApplicable
                    )
            }
        }
        .padding(20)
        .frame(width: 980, height: isImportedShelf ? 800 : 720)
        .onAppear {
            selectedPaths = Set(initialPaths.filter(Set(paths).contains))
            targetName = ""
            mappedBaseDirectory = nil
            mappedPathStrip = 1
            defaultPathStrip = 1
            baseDirectoryError = nil
            isImportedShelf = false
            suggestedBaseMappings = []
            loadedPatchText = ""
            previewGeneration = 0
            loadPatch()
        }
        .onChange(of: mappedBaseDirectory) { _, _ in
            guard isImportedShelf else { return }
            loadPreview(previewPath)
        }
        .onChange(of: mappedPathStrip) { _, _ in
            guard isImportedShelf else { return }
            loadPreview(previewPath)
        }
    }

    @ViewBuilder
    private var patchSelectionList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    groupByDirectory.toggle()
                    if !groupByDirectory { collapsedPatchFolders.removeAll() }
                } label: {
                    Label(
                        groupByDirectory ? "Flatten Directories" : "Group by Directory",
                        systemImage: groupByDirectory ? "rectangle.split.3x1" : "folder"
                    )
                }
                .buttonStyle(.borderless)
                .font(.caption)
                Spacer()
                patchStatusLegend
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Design.Colors.surface)

            List {
                ForEach(visiblePatchRows) { row in
                    if row.isFolder {
                        Button {
                            if collapsedPatchFolders.contains(row.path) {
                                collapsedPatchFolders.remove(row.path)
                            } else {
                                collapsedPatchFolders.insert(row.path)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: collapsedPatchFolders.contains(row.path)
                                    ? "chevron.right"
                                    : "chevron.down")
                                    .font(.caption2.weight(.bold))
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                Text(row.name)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.leading, CGFloat(row.depth * 14))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    } else if let file = patchFiles.first(where: { $0.path == row.path }) {
                        patchFileRow(file, depth: row.depth)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var patchStatusLegend: some View {
        HStack(spacing: 6) {
            ForEach(RebasedShelfPatchStatus.allCases) { status in
                let count = patchFiles.filter { $0.status == status }.count
                if count > 0 {
                    HStack(spacing: 2) {
                        Circle()
                            .fill(status.color)
                            .frame(width: 6, height: 6)
                        Text("\(count)")
                        Text(LocalizedStringKey(status.rawValue))
                    }
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func patchFileRow(_ file: RebasedShelfPatchFile, depth: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Toggle(isOn: Binding(
                    get: { isFileSelected(file) },
                    set: { setFileSelected(file, isSelected: $0) }
                )) {
                    HStack(spacing: 6) {
                        Image(systemName: file.isBinary ? "doc.fill" : "doc.text")
                            .foregroundStyle(.secondary)
                        Text(groupByDirectory
                            ? (file.path.split(separator: "/").last.map(String.init) ?? file.path)
                            : file.path)
                            .lineLimit(1)
                        Text(LocalizedStringKey(file.status.rawValue))
                            .font(.caption2)
                            .foregroundStyle(file.status.color)
                        if file.isBinary {
                            Text("Binary")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let issue = patchApplicabilityIssue(for: file) {
                            Label(issue, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(patchApplicabilityIssue(for: file) != nil)
                Button {
                    loadPreview(file.path)
                } label: {
                    Image(systemName: previewPath == file.path ? "eye.fill" : "eye")
                }
                .buttonStyle(.plain)
                .foregroundStyle(previewPath == file.path ? Color.accentColor : Color.secondary)
                .help("Preview file diff")
            }
            .padding(.leading, CGFloat(depth * 14))
            if !file.isWholeFileOnly {
                ForEach(file.hunks) { hunk in
                    Toggle(isOn: Binding(
                        get: { selectedHunkIDs.contains(hunk.id) },
                        set: { setHunkSelected(hunk, isSelected: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hunk.header)
                                .font(.system(size: 11, design: .monospaced))
                            if !hunk.preview.isEmpty {
                                Text(hunk.preview)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { loadPreview(file.path) }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.leading, CGFloat(depth * 14 + 22))
                    .disabled(patchApplicabilityIssue(for: file) != nil)
                }
            }
        }
    }

    @ViewBuilder
    private var patchPreview: some View {
        if let previewPath,
           let file = patchFiles.first(where: { $0.path == previewPath }) {
            if isLoadingPreview {
                ProgressView("Loading diff…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let previewDiff {
                if previewDiff.binary {
                    rawPatchView(file.rawPatch)
                } else if previewDiff.hunks.isEmpty {
                    Text("No changes")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            Text(isImportedShelf ? "Local → Applied Patch · \(file.path)" : file.path)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            Picker("Diff View", selection: $previewPresentationMode) {
                                ForEach(DiffPresentationMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 180)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Design.Colors.surface)
                        if previewPresentationMode == .sideBySide {
                            SideBySideDiffView(fileDiff: previewDiff)
                        } else {
                            UnifiedDiffView(fileDiff: previewDiff)
                        }
                    }
                }
            } else if let previewError {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Structured diff unavailable", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Text(previewError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    rawPatchView(file.rawPatch)
                }
                .padding(8)
            } else {
                rawPatchView(file.rawPatch)
            }
        } else {
            Text("Select a file to preview its diff")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func rawPatchView(_ patch: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(patch.isEmpty ? "No patch details" : patch)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(8)
        }
    }

    private var fileSelectionFallback: some View {
        List(paths, id: \.self) { path in
            Toggle(isOn: Binding(
                get: { selectedPaths.contains(path) },
                set: { selected in
                    if selected { selectedPaths.insert(path) }
                    else { selectedPaths.remove(path) }
                }
            )) {
                Text(path).lineLimit(1)
            }
            .toggleStyle(.checkbox)
        }
        .frame(height: CGFloat(min(260, max(80, paths.count * 24))))
    }

    private var patchBaseDirectoryPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Patch Base Directory", systemImage: "folder.badge.gearshape")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text("\(mappedBaseDirectory ?? "Repository root") · −p\(mappedPathStrip)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Map Base Directory…", action: choosePatchBaseDirectory)
                if mappedBaseDirectory != nil {
                    Button("Use Repository Root") {
                        mappedBaseDirectory = nil
                        mappedPathStrip = defaultPathStrip
                        baseDirectoryError = nil
                    }
                }
            }
            HStack(spacing: 10) {
                Text("Imported patches are applied relative to this directory.")
                Spacer()
                Stepper(value: $mappedPathStrip, in: UInt32(0)...UInt32(16)) {
                    Text("Path strip −p\(mappedPathStrip)")
                        .font(.caption)
                        .monospacedDigit()
                }
                .fixedSize()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let baseDirectoryError {
                Text(baseDirectoryError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if !suggestedBaseMappings.isEmpty {
                HStack(spacing: 6) {
                    Text("Suggested bases:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Menu("Choose Suggested Base") {
                        ForEach(suggestedBaseMappings) { candidate in
                            Button(candidate.title) {
                                mappedBaseDirectory = candidate.basePath.isEmpty ? nil : candidate.basePath
                                mappedPathStrip = candidate.pathStrip
                                baseDirectoryError = nil
                            }
                        }
                    }
                    .font(.caption)
                }
            }
        }
        .padding(8)
        .background(Design.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func choosePatchBaseDirectory() {
        guard let repositoryRoot = repositoryRootURL else {
            baseDirectoryError = "Repository working directory is unavailable."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = repositoryRoot
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

        let root = repositoryRoot.resolvingSymlinksInPath()
        let selected = selectedURL.standardizedFileURL.resolvingSymlinksInPath()
        guard selected.path == root.path || selected.path.hasPrefix(root.path + "/") else {
            baseDirectoryError = "Selected base directory must be inside the repository."
            return
        }
        baseDirectoryError = nil
        if selected.path == root.path {
            mappedBaseDirectory = nil
        } else {
            mappedBaseDirectory = String(selected.path.dropFirst(root.path.count + 1))
        }
    }

    private var repositoryRootURL: URL? {
        guard let workdir = repo?.workdir(), !workdir.isEmpty else { return nil }
        return URL(fileURLWithPath: workdir).standardizedFileURL
    }

    private func selectAll() {
        guard !isImportedShelf || !patchFiles.isEmpty else {
            selectedPaths = Set(paths)
            selectedHunkIDs.removeAll()
            return
        }
        let selectableFiles = patchFiles.filter { patchApplicabilityIssue(for: $0) == nil }
        selectedPaths = isImportedShelf ? Set(selectableFiles.map(\.path)) : Set(paths)
        selectedHunkIDs = Set(selectableFiles.flatMap { $0.hunks.map(\.id) })
    }

    private func clearSelection() {
        selectedPaths.removeAll()
        selectedHunkIDs.removeAll()
    }

    private func isFileSelected(_ file: RebasedShelfPatchFile) -> Bool {
        guard selectedPaths.contains(file.path) else { return false }
        return file.isWholeFileOnly || file.hunks.allSatisfy { selectedHunkIDs.contains($0.id) }
    }

    private func setFileSelected(_ file: RebasedShelfPatchFile, isSelected: Bool) {
        if isSelected {
            selectedPaths.insert(file.path)
            selectedHunkIDs.formUnion(file.hunks.map(\.id))
        } else {
            selectedPaths.remove(file.path)
            selectedHunkIDs.subtract(file.hunks.map(\.id))
        }
    }

    private func setHunkSelected(_ hunk: RebasedShelfPatchHunk, isSelected: Bool) {
        if isSelected {
            selectedHunkIDs.insert(hunk.id)
            selectedPaths.insert(hunk.path)
        } else {
            selectedHunkIDs.remove(hunk.id)
            let hasSelectedHunk = patchFiles
                .first(where: { $0.path == hunk.path })?.hunks
                .contains(where: { selectedHunkIDs.contains($0.id) }) ?? false
            if !hasSelectedHunk { selectedPaths.remove(hunk.path) }
        }
    }

    private func loadPatch() {
        guard let repo else { return }
        isLoadingPatch = true
        patchLoadError = nil
        let rootPath = repositoryRootURL?.path
        let suppliedPatch = patchText
        Task.detached(priority: .userInitiated) {
            do {
                let imported = suppliedPatch != nil
                    || ((try? repo.shelveIsImported(name: name)) ?? false)
                let patch: String
                if let suppliedPatch {
                    patch = suppliedPatch
                } else {
                    patch = try repo.shelveDiff(name: name)
                }
                let parsedFiles = Self.parsePatchFiles(patch, allowedPaths: paths)
                let parsedPaths = Set(parsedFiles.map(\.path))
                let files = Set(paths).isSubset(of: parsedPaths) ? parsedFiles : []
                let indexedPaths = (try? repo.patchIndexPaths()) ?? []
                let candidateScope = rootPath.map {
                    RebasedPatchCandidateScope.repository(rootPath: $0)
                }
                let filenameIndex = rootPath.map {
                    RebasedPatchFilenameIndexStore.loadOrBuild(
                        rootPath: $0,
                        indexedPaths: indexedPaths,
                        scope: candidateScope
                    )
                }
                let candidates = Self.discoverBaseMappings(
                    patchFiles: files,
                    rootPath: rootPath,
                    indexedPaths: indexedPaths,
                    scope: candidateScope,
                    filenameIndex: filenameIndex
                )
                let defaultStrip = Self.defaultPathStrip(for: files)
                await MainActor.run {
                    self.isImportedShelf = imported
                    self.loadedPatchText = patch
                    self.patchFiles = files
                    self.suggestedBaseMappings = candidates
                    self.defaultPathStrip = defaultStrip
                    self.mappedPathStrip = defaultStrip
                    // MatchPatchPaths selects a best text/strip variant. For
                    // ambiguous new files it deliberately falls back to the
                    // project root and leaves the suggestion menu available.
                    if imported,
                       let candidate = Self.automaticallySelectedBaseMapping(
                           patchFiles: files,
                           candidates: candidates
                       ) {
                        self.mappedBaseDirectory = candidate.basePath.isEmpty ? nil : candidate.basePath
                        self.mappedPathStrip = candidate.pathStrip
                    }
                    self.isLoadingPatch = false
                    self.previewPath = files.first?.path
                    if files.isEmpty {
                        self.patchLoadError = "Patch details are unavailable; using file selection."
                    } else {
                        self.initializeHunkSelection()
                        self.loadPreview(files.first?.path)
                    }
                }
            } catch {
                await MainActor.run {
                    self.isImportedShelf = suppliedPatch != nil
                        || ((try? repo.shelveIsImported(name: name)) ?? false)
                    self.isLoadingPatch = false
                    self.patchLoadError = "Patch details are unavailable; using file selection."
                }
            }
        }
    }

    private func loadPreview(_ path: String?) {
        previewGeneration &+= 1
        let generation = previewGeneration
        guard let path else {
            previewPath = nil
            previewDiff = nil
            previewError = nil
            isLoadingPreview = false
            return
        }
        previewPath = path
        previewDiff = nil
        previewError = nil
        if isImportedShelf {
            guard let repo, !loadedPatchText.isEmpty else {
                isLoadingPreview = false
                return
            }
            isLoadingPreview = true
            let patch = loadedPatchText
            let baseDirectory = mappedBaseDirectory ?? ""
            let pathStrip = mappedPathStrip
            Task.detached(priority: .userInitiated) {
                do {
                    let diff = try repo.importedPatchFileDiff(
                        patch: patch,
                        path: path,
                        baseDirectory: baseDirectory,
                        pathStrip: pathStrip,
                        ignoreWhitespace: false
                    )
                    await MainActor.run {
                        guard self.previewPath == path,
                              self.previewGeneration == generation else { return }
                        self.previewDiff = diff
                        self.previewError = nil
                        self.isLoadingPreview = false
                    }
                } catch {
                    await MainActor.run {
                        guard self.previewPath == path,
                              self.previewGeneration == generation else { return }
                        self.previewDiff = nil
                        self.previewError = String(describing: error)
                        self.isLoadingPreview = false
                    }
                }
            }
            return
        }
        if patchText != nil {
            if let rawPatch = patchFiles.first(where: { $0.path == path })?.rawPatch {
                previewDiff = RebasedPatchDiffParser.parse(patch: rawPatch, path: path)
            }
            isLoadingPreview = false
            return
        }
        guard let repo, patchText == nil else {
            isLoadingPreview = false
            return
        }
        isLoadingPreview = true
        let shelfName = name
        Task.detached(priority: .userInitiated) {
            do {
                let diff = try repo.shelveFileDiffWithSettings(
                    name: shelfName,
                    path: path,
                    withLocal: false,
                    settings: makeArborGitDiffSettings()
                )
                await MainActor.run {
                    guard self.previewPath == path,
                          self.previewGeneration == generation else { return }
                    self.previewDiff = diff
                    self.previewError = nil
                    self.isLoadingPreview = false
                }
            } catch {
                await MainActor.run {
                    guard self.previewPath == path,
                          self.previewGeneration == generation else { return }
                    self.previewDiff = nil
                    self.previewError = String(describing: error)
                    self.isLoadingPreview = false
                }
            }
        }
    }

    private func initializeHunkSelection() {
        let initial = Set(initialPaths)
        selectedHunkIDs = Set(
            patchFiles
                .filter { initial.contains($0.path) && patchApplicabilityIssue(for: $0) == nil }
                .flatMap { $0.hunks.map(\.id) }
        )
        selectedPaths = Set(
            paths.filter(initial.contains).filter { path in
                patchFiles.first(where: { $0.path == path }).map {
                    patchApplicabilityIssue(for: $0) == nil
                } ?? true
            }
        )
    }

    private func patchApplicabilityIssue(for file: RebasedShelfPatchFile) -> String? {
        guard isImportedShelf else { return nil }
        guard let root = repositoryRootURL else {
            return "Repository root unavailable"
        }
        guard let rawPath = Self.rawPatchPath(file.rawPatch),
              let strippedPath = RebasedPatchPathMapper.strippedPath(
                  rawPath: rawPath,
                  pathStrip: mappedPathStrip
              ) else {
            return "Invalid path strip"
        }

        let baseURL = mappedBaseDirectory.map {
            root.appendingPathComponent($0, isDirectory: true)
        } ?? root
        let targetURL = baseURL
            .appendingPathComponent(strippedPath)
            .standardizedFileURL
        guard targetURL.path == root.path || targetURL.path.hasPrefix(root.path + "/") else {
            return "Base is outside repository"
        }
        let exists = FileManager.default.fileExists(atPath: targetURL.path)
        switch file.status {
        case .added:
            return exists ? "Target already exists" : nil
        case .deleted, .modified:
            return exists ? nil : "Base file not found"
        case .renamed:
            // A rename can target a new path while its old endpoint exists;
            // the engine owns that endpoint-aware apply check.
            return nil
        }
    }

    nonisolated static func parsePatchFiles(
        _ patch: String,
        allowedPaths: [String]
    ) -> [RebasedShelfPatchFile] {
        let lines = patch
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var chunks: [(path: String, lines: [String])] = []
        var currentPath: String?
        var currentLines: [String] = []

        func flush() {
            guard let currentPath, !currentLines.isEmpty else { return }
            chunks.append((currentPath, currentLines))
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("diff --git ") {
                flush()
                currentPath = pathFromHeader(line, allowedPaths: allowedPaths)
                currentLines = [line]
            } else if line.hasPrefix("--- "),
                      index + 1 < lines.count,
                      lines[index + 1].hasPrefix("+++ ") {
                let oldPath = pathFromUnifiedHeader(line, marker: "--- ", allowedPaths: allowedPaths)
                let newPath = pathFromUnifiedHeader(lines[index + 1], marker: "+++ ", allowedPaths: allowedPaths)
                let isGitExtendedHeader = currentLines.first?.hasPrefix("diff --git ") == true
                if !isGitExtendedHeader, let path = newPath ?? oldPath {
                    flush()
                    currentPath = path
                    currentLines = [line, lines[index + 1]]
                    index += 1
                } else if currentPath != nil {
                    // A Git extended diff owns its ---/+++ headers. Do not
                    // split it into a second chunk merely because it also
                    // contains a traditional unified header pair.
                    currentLines.append(line)
                } else {
                    currentLines.append(line)
                }
            } else if currentPath != nil {
                currentLines.append(line)
            } else if line.hasPrefix("--- ") {
                // A new unified file can follow the previous file without a
                // diff --git separator. We only recognize it when its next
                // line is a valid +++ header, so hunk content such as
                // "--- value" remains part of the current patch.
                let oldPath = pathFromUnifiedHeader(line, marker: "--- ", allowedPaths: allowedPaths)
                if oldPath != nil {
                    currentPath = nil
                    currentLines = []
                }
            } else if currentPath == nil {
                // Ignore mail headers and patch metadata until a file header
                // or a Git diff boundary identifies a real change.
            }
            index += 1
        }
        flush()

        return chunks.compactMap { chunk in
            let hunkStarts = chunk.lines.indices.filter { chunk.lines[$0].hasPrefix("@@") }
            let hunks = hunkStarts.enumerated().map { offset, start in
                let end = hunkStarts.dropFirst(offset + 1).first ?? chunk.lines.count
                let lines = Array(chunk.lines[start..<end])
                return RebasedShelfPatchHunk(
                    path: chunk.path,
                    index: UInt32(offset),
                    header: lines.first ?? "Hunk \(offset + 1)",
                    preview: lines.dropFirst().prefix(3).joined(separator: "\n")
                )
            }
            let body = chunk.lines.joined(separator: "\n")
            let isBinary = body.contains("GIT binary patch") || body.contains("Binary files ")
            let status: RebasedShelfPatchStatus
            if body.contains("new file mode") || body.contains("--- /dev/null") {
                status = .added
            } else if body.contains("deleted file mode") || body.contains("+++ /dev/null") {
                status = .deleted
            } else if body.contains("rename from ") || body.contains("rename to ") {
                status = .renamed
            } else {
                status = .modified
            }
            return RebasedShelfPatchFile(
                path: chunk.path,
                hunks: hunks,
                isBinary: isBinary,
                status: status,
                rawPatch: body
            )
        }
    }

    nonisolated private static func pathFromHeader(_ line: String, allowedPaths: [String]) -> String? {
        let unquoted = line.replacingOccurrences(of: "\"", with: "")
        if let path = allowedPaths
            .sorted(by: { $0.count > $1.count })
            .first(where: { unquoted.contains("b/\($0)") || unquoted.contains("a/\($0)") }) {
            return path
        }
        guard let separator = unquoted.range(of: " b/") else { return nil }
        let path = String(unquoted[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    nonisolated private static func pathFromUnifiedHeader(
        _ line: String,
        marker: String,
        allowedPaths: [String]
    ) -> String? {
        guard line.hasPrefix(marker) else { return nil }
        let value = String(line.dropFirst(marker.count))
            .replacingOccurrences(of: "\"", with: "")
            .split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty, value != "/dev/null" else { return nil }

        if let path = allowedPaths
            .sorted(by: { $0.count > $1.count })
            .first(where: { value == $0 || value == "a/\($0)" || value == "b/\($0)" }) {
            return path
        }
        if value.hasPrefix("a/") || value.hasPrefix("b/") {
            return String(value.dropFirst(2))
        }
        return value
    }

    nonisolated private static func defaultPathStrip(
        for patchFiles: [RebasedShelfPatchFile]
    ) -> UInt32 {
        patchFiles
            .compactMap { rawPatchPath($0.rawPatch) }
            .map { rawPath in
                UInt32(rawPath.hasPrefix("a/") || rawPath.hasPrefix("b/") ? 1 : 0)
            }
            .max() ?? 1
    }

    nonisolated private static func rawPatchPath(_ patch: String) -> String? {
        let lines = patch
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if let header = lines.first(where: { $0.hasPrefix("diff --git ") }) {
            let unquoted = header.replacingOccurrences(of: "\"", with: "")
            guard let separator = unquoted.range(of: " b/") else { return nil }
            let path = String(unquoted[separator.lowerBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        }
        if let header = lines.first(where: { $0.hasPrefix("+++ ") }),
           let path = pathFromUnifiedHeader(header, marker: "+++ ", allowedPaths: []) {
            return path
        }
        guard let header = lines.first(where: { $0.hasPrefix("--- ") }) else { return nil }
        return pathFromUnifiedHeader(header, marker: "--- ", allowedPaths: [])
    }

    nonisolated static func discoverBaseMappings(
        patchFiles: [RebasedShelfPatchFile],
        rootPath: String?,
        indexedPaths: [String],
        scope: RebasedPatchCandidateScope? = nil,
        filenameIndex: RebasedPatchFilenameIndex? = nil
    ) -> [RebasedPatchBaseCandidate] {
        guard !patchFiles.isEmpty, let rootPath, !rootPath.isEmpty else { return [] }
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        let candidateScope = scope ?? RebasedPatchCandidateScope.repository(rootPath: root.path)
        guard candidateScope.rootPath == root.path else { return [] }
        let filenameIndex = filenameIndex ?? RebasedPatchFilenameIndexStore.loadOrBuild(
            rootPath: root.path,
            indexedPaths: indexedPaths,
            scope: candidateScope
        )
        guard filenameIndex.rootPath == root.path else { return [] }

        let rawPaths = patchFiles.compactMap { rawPatchPath($0.rawPatch) }
        guard rawPaths.count == patchFiles.count else { return [] }
        let indexedItems = filenameIndex.indexedItems

        // MatchPatchPaths has a second path-finding branch for new files (or
        // existing files with no exact FilenameIndex variant). It can infer a
        // base from any indexed file/directory whose name appears in the
        // patch path, even when the trailing target directories do not exist
        // yet. A suffix-only scan misses the common "new module/new folder"
        // case and silently falls back to the wrong -p0 mapping.
        func inferredCandidates(
            rawComponents: [String],
            pathStrip: UInt32
        ) -> Set<String> {
            guard rawComponents.count > 1 else { return [] }
            var result = Set<String>()
            for index in 0..<(rawComponents.count - 1) {
                let component = rawComponents[index]
                for itemPath in indexedItems {
                    let itemComponents = itemPath.split(separator: "/").map(String.init)
                    guard itemComponents.last == component else { continue }

                    var rawIndex = index
                    var itemIndex = itemComponents.count - 1
                    var matched = 0
                    while rawIndex >= 0,
                          itemIndex >= 0,
                          rawComponents[rawIndex] == itemComponents[itemIndex] {
                        matched += 1
                        rawIndex -= 1
                        itemIndex -= 1
                    }

                    let inferredStrip = index + 1 - matched
                    guard inferredStrip < index,
                          inferredStrip == Int(pathStrip) else { continue }
                    result.insert(itemComponents.dropLast(matched).joined(separator: "/"))
                }
            }
            return result
        }

        let maximumStrip = rawPaths
            .map { $0.split(separator: "/").count }
            .max() ?? 0
        var mappings: [RebasedPatchBaseCandidate] = []
        for pathStrip in 0...UInt32(max(0, maximumStrip - 1)) {
            var commonCandidates: Set<String>?
            for rawPath in rawPaths {
                let components = rawPath.split(separator: "/").map(String.init)
                let minimumStrip = rawPath.hasPrefix("a/") || rawPath.hasPrefix("b/") ? 1 : 0
                guard pathStrip >= minimumStrip,
                      Int(pathStrip) < components.count else {
                    commonCandidates = []
                    break
                }
                let target = Array(components.dropFirst(Int(pathStrip)))
                guard !target.isEmpty else {
                    commonCandidates = []
                    break
                }
                var candidates = Set(
                    filenameIndex.files(matchingSuffix: target).map { relativeFile in
                        let fileComponents = relativeFile.split(separator: "/").map(String.init)
                        return fileComponents.dropLast(target.count).joined(separator: "/")
                    }
                )
                let targetParent = Array(target.dropLast())
                if !targetParent.isEmpty {
                    for relativeDirectory in filenameIndex.directories(matchingSuffix: targetParent) {
                        let directoryComponents = relativeDirectory.split(separator: "/").map(String.init)
                        candidates.insert(
                            directoryComponents.dropLast(targetParent.count).joined(separator: "/")
                        )
                    }
                }
                if candidates.isEmpty {
                    candidates.formUnion(
                        inferredCandidates(rawComponents: components, pathStrip: pathStrip)
                    )
                }
                commonCandidates = commonCandidates.map { $0.intersection(candidates) } ?? candidates
                if commonCandidates?.isEmpty ?? true { break }
            }
            for basePath in commonCandidates ?? [] {
                let contextScore = contextScore(
                    patchFiles: patchFiles,
                    basePath: basePath,
                    pathStrip: pathStrip,
                    root: root
                )
                let candidate = RebasedPatchBaseCandidate(
                    basePath: basePath,
                    pathStrip: pathStrip,
                    contextScore: contextScore
                )
                if let index = mappings.firstIndex(where: {
                    $0.basePath == candidate.basePath && $0.pathStrip == candidate.pathStrip
                }) {
                    if candidate.contextScore > mappings[index].contextScore {
                        mappings[index] = candidate
                    }
                } else {
                    mappings.append(candidate)
                }
            }
        }
        let allBinary = patchFiles.allSatisfy(\.isBinary)
        return mappings.sorted { lhs, rhs in
            if lhs.contextScore != rhs.contextScore { return lhs.contextScore > rhs.contextScore }
            if lhs.basePath.isEmpty != rhs.basePath.isEmpty { return lhs.basePath.isEmpty }
            if allBinary && lhs.pathStrip != rhs.pathStrip { return lhs.pathStrip < rhs.pathStrip }
            if lhs.basePath.count != rhs.basePath.count { return lhs.basePath.count < rhs.basePath.count }
            if lhs.pathStrip != rhs.pathStrip { return lhs.pathStrip < rhs.pathStrip }
            return lhs.basePath.localizedStandardCompare(rhs.basePath) == .orderedAscending
        }
    }

    nonisolated private static func contextScore(
        patchFiles: [RebasedShelfPatchFile],
        basePath: String,
        pathStrip: UInt32,
        root: URL
    ) -> Int {
        patchFiles.reduce(0) { total, file in
            guard let rawPath = rawPatchPath(file.rawPatch) else { return total }
            let components = rawPath.split(separator: "/").map(String.init)
            let strip = Int(pathStrip)
            guard strip < components.count else { return total }
            let strippedPath = components.dropFirst(strip).joined(separator: "/")
            let mappedPath = basePath.isEmpty ? strippedPath : "\(basePath)/\(strippedPath)"
            let fileURL = root.appendingPathComponent(mappedPath)
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return total }
            return total + RebasedPatchContextMatcher.score(
                patch: file.rawPatch,
                text: String(text.prefix(100_000))
            )
        }
    }
}

/// IntelliJ's multi-ShelvedChangeList action chooses one target Changelist
/// before applying the selected shelves asynchronously. Keeping this chooser
/// separate from the single-shelf patch dialog preserves that interaction
/// boundary and makes the batch operation's destination explicit.
struct RebasedUnshelveMultipleDialog: View {
    let names: [String]
    let changeLists: [ChangeListInfo]
    let suggestedName: String?
    @Binding var removeAppliedFilesFromShelf: Bool
    let onUnshelve: (String, Bool) -> Void
    let onCancel: () -> Void
    @State private var targetName = ""

    private var selectedNames: [String] {
        names.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Unshelve Multiple Shelves")
                .font(.title3.weight(.semibold))
            Text("Apply the selected shelves to one Changelist.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(selectedNames.joined(separator: ", "))
                .font(.headline)
                .lineLimit(2)
            Picker("Target Changelist", selection: $targetName) {
                ForEach(changeLists, id: \.name) { list in
                    Text(list.name).tag(list.name)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            Toggle("Remove Applied Files from Shelf", isOn: $removeAppliedFilesFromShelf)
                .toggleStyle(.checkbox)
            if removeAppliedFilesFromShelf {
                Text("Applied files will be moved to Recently Deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Unshelve", action: { onUnshelve(targetName, removeAppliedFilesFromShelf) })
                    .keyboardShortcut(.defaultAction)
                    .disabled(targetName.isEmpty || selectedNames.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            guard targetName.isEmpty else { return }
            let suggested = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            targetName = changeLists.first(where: { $0.name == suggested })?.name
                ?? changeLists.first(where: \.isActive)?.name
                ?? changeLists.first?.name
                ?? ""
        }
    }
}

/// IntelliJ Git 的 Stash Files：只保存选中的路径，并默认把未跟踪文件
/// 纳入当前选区。它与整棵工作树的 Stash 对话框分开，避免误清理未选中的修改。
struct RebasedStashFilesDialog: View {
    @Binding var message: String
    let entries: [FileEntry]
    let initialPaths: Set<String>
    let onStash: ([String]) -> Void
    let onCancel: () -> Void
    @State private var selectedPaths: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stash Selected Files").font(.title3.weight(.semibold))
            TextField("Message (optional)", text: $message)
                .textFieldStyle(.roundedBorder)
            Text("Only selected paths are stashed. Untracked files are included; ignored files are excluded.")
                .font(.caption)
                .foregroundStyle(.secondary)
            List(entries, id: \.path) { entry in
                Toggle(isOn: Binding(
                    get: { selectedPaths.contains(entry.path) },
                    set: { checked in
                        if checked { selectedPaths.insert(entry.path) }
                        else { selectedPaths.remove(entry.path) }
                    }
                )) {
                    HStack {
                        StatusBadge(kind: entry.unstaged != .unchanged ? entry.unstaged : entry.staged)
                        Text(entry.path).lineLimit(1)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .frame(height: 260)
            HStack {
                Button("Select All") { selectedPaths = Set(entries.map(\.path)) }
                Button("Clear") { selectedPaths.removeAll() }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Stash", action: { onStash(Array(selectedPaths).sorted()) })
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedPaths.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear {
            selectedPaths = initialPaths.intersection(Set(entries.map(\.path)))
            if selectedPaths.isEmpty {
                selectedPaths = Set(entries.map(\.path))
            }
        }
    }
}

/// IntelliJ GitConflictsView 的批量动作只作用于当前冲突选择，且保持稳定路径顺序。
func conflictPathsForSelection(_ selection: Set<String>, paths: [String]) -> [String] {
    paths.filter(selection.contains).sorted()
}

/// 对话框化的 Merge Revisions 三栏页面。左侧文件清单，右侧是
/// Local │ Result │ Remote 三栏编辑器；解析文件后仍由父视图刷新状态。
struct MergeRevisionsDialogView: View {
    enum Mode {
        case merge
        case rebase
        case cherryPick
        case revert
        case stashRestore
        case shelveRestore(isPop: Bool)
        case applyPatch

        var title: String {
            switch self {
            case .merge: "Merge Revisions"
            case .rebase: "Rebase — Resolve Conflicts"
            case .cherryPick: "Cherry-pick — Resolve Conflicts"
            case .revert: "Revert — Resolve Conflicts"
            case .stashRestore: "Stash — Resolve Conflicts"
            case .shelveRestore: "Shelve — Resolve Conflicts"
            case .applyPatch: "Apply Patch — Resolve Conflicts"
            }
        }

        var primaryTitle: String {
            switch self {
            case .merge: "Complete Merge"
            case .rebase: "Continue Rebase"
            case .cherryPick: "Continue Cherry-pick"
            case .revert: "Continue Revert"
            case .stashRestore: "Complete Stash Apply"
            case .shelveRestore(let isPop): isPop ? "Complete Shelve Pop" : "Complete Unshelve"
            case .applyPatch: "Complete Apply Patch"
            }
        }

        var abortTitle: String {
            switch self {
            case .shelveRestore(let isPop):
                return isPop ? "Rollback Shelve Pop" : "Rollback Unshelve"
            case .applyPatch:
                return "Rollback Apply Patch"
            default:
                return "Abort"
            }
        }

        var isApplyPatch: Bool {
            if case .applyPatch = self { return true }
            return false
        }
    }

    let repo: Repository
    @Binding var entries: [FileEntry]
    let initialPath: String?
    let mode: Mode
    let directPatchText: String?
    let directPatchRestoreName: String?
    let onChanged: () -> Void
    let onComplete: () -> Void
    let onAbort: (() -> Void)?
    let onSkip: (() -> Void)?
    /// Non-modal resolver panels use a smaller minimum size so the main
    /// workspace remains visible beside the conflict queue.
    let compact: Bool

    init(
        repo: Repository,
        entries: Binding<[FileEntry]>,
        initialPath: String?,
        mode: Mode,
        directPatchText: String? = nil,
        directPatchRestoreName: String? = nil,
        onChanged: @escaping () -> Void,
        onComplete: @escaping () -> Void,
        onAbort: (() -> Void)?,
        onSkip: (() -> Void)?,
        compact: Bool = false
    ) {
        self.repo = repo
        self._entries = entries
        self.initialPath = initialPath
        self.mode = mode
        self.directPatchText = directPatchText
        self.directPatchRestoreName = directPatchRestoreName
        self.onChanged = onChanged
        self.onComplete = onComplete
        self.onAbort = onAbort
        self.onSkip = onSkip
        self.compact = compact
    }

    @State private var selectedPath: String?
    @State private var selectedPaths: Set<String> = []
    @State private var resolvedPaths: [String] = []
    @State private var binaryPaths: Set<String> = []
    @State private var batchWorking = false
    @State private var pendingRevertPath: String?
    @State private var revertingPath: String?
    @State private var actionError: String?

    private var conflictPaths: [String] {
        entries
            .filter { $0.staged == .conflicted || $0.unstaged == .conflicted }
            .map(\.path)
            .sorted()
    }

    private var selectedConflictPaths: [String] {
        conflictPathsForSelection(selectedPaths, paths: conflictPaths)
    }

    var body: some View {
        VStack(spacing: 0) {
            conflictToolbar
            Divider()
            if let actionError {
                Text(actionError)
                    .font(.caption)
                    .foregroundStyle(.red)
        .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }

            conflictWorkspace
        }
        .frame(minWidth: compact ? 920 : 1120, minHeight: compact ? 540 : 700)
        .onAppear {
            loadWorkspaceState()
        }
        .onChange(of: conflictPaths) { _, paths in
            selectAvailablePath(preferred: selectedPath, conflictPaths: paths, resolvedPaths: resolvedPaths)
        }
        .onChange(of: resolvedPaths) { _, paths in
            selectAvailablePath(preferred: selectedPath, conflictPaths: conflictPaths, resolvedPaths: paths)
        }
        .onChange(of: selectedPaths) { _, paths in
            let available = Set(conflictPaths).union(resolvedPaths)
            let valid = paths.intersection(available)
            if valid != paths {
                selectedPaths = valid
            }
            if let selectedPath, valid.contains(selectedPath) {
                return
            }
            self.selectedPath = valid.sorted().first
        }
        .alert("Revert resolved file?", isPresented: Binding(
            get: { pendingRevertPath != nil },
            set: { if !$0 { pendingRevertPath = nil } }
        )) {
            Button("Revert", role: .destructive) {
                guard let path = pendingRevertPath else { return }
                pendingRevertPath = nil
                revertResolved(path)
            }
            Button("Cancel", role: .cancel) { pendingRevertPath = nil }
        } message: {
            Text("The file will return to the unresolved conflict list.")
        }
    }

    private var conflictToolbar: AnyView {
        let selectedPathsForBatch = selectedConflictPaths
        let patchMode = mode.isApplyPatch
        return AnyView(HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.merge")
                .foregroundStyle(.orange)
            Text(mode.title)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Text("\(conflictPaths.count) conflicted files")
                .font(.caption)
                .foregroundStyle(conflictPaths.isEmpty ? .green : .secondary)
            if !resolvedPaths.isEmpty {
                Text("\(resolvedPaths.count) resolved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !selectedPathsForBatch.isEmpty {
                Text("\(selectedPathsForBatch.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(patchMode ? "Keep Local" : "Accept Ours") { acceptSelectedConflicts(.ours) }
                    .disabled(batchWorking)
                Button(patchMode ? "Apply Patch" : "Accept Theirs") { acceptSelectedConflicts(.theirs) }
                    .disabled(batchWorking)
            }
            if let onAbort {
                Button(mode.abortTitle, role: .destructive, action: onAbort)
            }
            if let onSkip {
                Button("Skip", action: onSkip)
                    .disabled(!conflictPaths.isEmpty)
            }
            Button(mode.primaryTitle, action: onComplete)
                .buttonStyle(.borderedProminent)
                .disabled(!conflictPaths.isEmpty)
        }
        .padding(12))
    }

    private var conflictWorkspace: AnyView {
        AnyView(HStack(spacing: 0) {
            conflictPathList
            Divider()
            conflictDetail
        })
    }

    private var conflictPathList: AnyView {
        AnyView(VStack(alignment: .leading, spacing: 0) {
            if conflictPaths.isEmpty && resolvedPaths.isEmpty {
                Text("All conflicts resolved")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .padding(12)
            } else {
                List(selection: $selectedPaths) {
                    if !conflictPaths.isEmpty {
                        Section("CONFLICTS") {
                            ForEach(conflictPaths, id: \.self) { path in
                                conflictPathRow(path)
                            }
                        }
                    }
                    if !resolvedPaths.isEmpty {
                        Section("RESOLVED") {
                            ForEach(resolvedPaths, id: \.self) { path in
                                resolvedPathRow(path)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            Spacer()
        }
        .frame(width: 230))
    }

    private var conflictDetail: AnyView {
        if let selectedPath, conflictPaths.contains(selectedPath) {
            return AnyView(ConflictDetailView(
                repo: repo,
                path: selectedPath,
                patchText: directPatchText,
                restoreName: directPatchRestoreName,
                onChanged: {
                    onChanged()
                    loadWorkspaceState()
                }
            ))
        }
        if let selectedPath, resolvedPaths.contains(selectedPath) {
            return AnyView(ResolvedConflictFileView(
                path: selectedPath,
                isWorking: revertingPath == selectedPath,
                error: actionError,
                onRevert: { pendingRevertPath = selectedPath }
            ))
        }
        return AnyView(VStack(spacing: 10) {
            Image(systemName: "arrow.left.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Select a conflicted file")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity))
    }

    private func resolvedPathRow(_ path: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
            Text(path)
                .lineLimit(1)
        }
        .tag(path)
    }

    @ViewBuilder
    private func conflictPathRow(_ path: String) -> some View {
        let isBinary = binaryPaths.contains(path)
        HStack(spacing: 6) {
            Image(systemName: isBinary
                  ? "doc.badge.gearshape"
                  : "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Text(path)
                .lineLimit(1)
            if isBinary {
                Text("Binary")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .tag(path)
    }

    private func selectAvailablePath(
        preferred: String?,
        conflictPaths: [String],
        resolvedPaths: [String]
    ) {
        let available = Set(conflictPaths).union(resolvedPaths)
        selectedPaths = selectedPaths.intersection(available)
        if let preferred, available.contains(preferred), selectedPaths.isEmpty {
            selectedPath = preferred
            selectedPaths = [preferred]
            return
        }
        if let selectedPath, available.contains(selectedPath), selectedPaths.contains(selectedPath) {
            return
        }
        selectedPath = initialPath.flatMap { available.contains($0) ? $0 : nil }
            ?? conflictPaths.first
            ?? resolvedPaths.first
        if let selectedPath {
            selectedPaths = [selectedPath]
        }
    }

    private func loadWorkspaceState() {
        Task.detached(priority: .userInitiated) {
            do {
                let workspace = try repo.conflictWorkspace()
                await MainActor.run {
                    self.resolvedPaths = workspace.resolvedFiles
                    self.binaryPaths = Set(workspace.files.filter(\.binary).map(\.path))
                    self.selectAvailablePath(
                        preferred: self.selectedPath,
                        conflictPaths: self.conflictPaths,
                        resolvedPaths: workspace.resolvedFiles
                    )
                }
            } catch {
                await MainActor.run {
                    self.binaryPaths.removeAll()
                    self.actionError = "\(error)"
                }
            }
        }
    }

    private func acceptSelectedConflicts(_ pick: FilePick) {
        guard !batchWorking else { return }
        let paths = selectedConflictPaths
        guard !paths.isEmpty else { return }
        batchWorking = true
        actionError = nil
        Task.detached(priority: .userInitiated) {
            var accepted: [String] = []
            var failure: String?
            for path in paths {
                do {
                    try repo.acceptConflict(path: path, pick: pick)
                    accepted.append(path)
                } catch {
                    failure = "\(path): \(error)"
                    break
                }
            }
            let acceptedPaths = accepted
            let failureMessage = failure
            await MainActor.run {
                self.batchWorking = false
                self.selectedPaths.subtract(acceptedPaths)
                if let failureMessage {
                    self.actionError = "部分冲突已解决；\(failureMessage)"
                }
                self.onChanged()
                self.loadWorkspaceState()
            }
        }
    }

    private func revertResolved(_ path: String) {
        guard revertingPath == nil else { return }
        revertingPath = path
        actionError = nil
        Task.detached(priority: .userInitiated) {
            do {
                try repo.revertResolvedConflict(path: path)
                await MainActor.run {
                    self.revertingPath = nil
                    self.selectedPath = path
                    self.onChanged()
                    self.loadWorkspaceState()
                }
            } catch {
                await MainActor.run {
                    self.revertingPath = nil
                    self.actionError = "\(error)"
                }
            }
        }
    }
}

private struct ResolvedConflictFileView: View {
    let path: String
    let isWorking: Bool
    let error: String?
    let onRevert: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.green)
            Text("Resolved: \(path)")
                .font(.headline)
            Text("This file is resolved in the current Git operation. Revert the resolution to reopen the three-way conflict editor.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(isWorking ? "Reverting…" : "Revert Resolved") {
                onRevert()
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking)
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct RebasedUncommitRequest: Identifiable {
    let id = UUID()
    let commit: CommitInfo
    let repositoryPath: String
    let changedPaths: [String]
    let changeLists: [ChangeListInfo]
    let headBranch: String?
}

/// IntelliJ GitUncommitAction equivalent: choose the destination Changelist
/// before the soft reset moves the selected HEAD commit's changes back into
/// the Changes Browser.
struct RebasedUncommitDialog: View {
    private enum Field: Hashable {
        case targetList
        case newTargetName
    }

    let request: RebasedUncommitRequest
    let onUncommit: (String) -> Void
    let onCancel: () -> Void
    @State private var targetName = ""
    @State private var newTargetName = ""
    @FocusState private var focusedField: Field?

    private var normalizedNewTargetName: String {
        newTargetName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var newTargetNameError: String? {
        guard !normalizedNewTargetName.isEmpty else { return nil }
        if normalizedNewTargetName.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\t" }) {
            return "Changelist names cannot contain tabs or line breaks."
        }
        return nil
    }

    private var resolvedTargetName: String {
        normalizedNewTargetName.isEmpty ? targetName : normalizedNewTargetName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Undo Latest Commit")
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(request.headBranch ?? "Detached HEAD") · \(request.commit.shortId)")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                Text(request.commit.summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Divider()
            Text("Choose the Changelist for the \(request.changedPaths.count) changes from this commit.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Picker("Target Changelist", selection: $targetName) {
                ForEach(request.changeLists, id: \.name) { list in
                    Text(list.name).tag(list.name)
                }
            }
            .pickerStyle(.menu)
            .focused($focusedField, equals: .targetList)
            .help("Choose the Changelist that will receive the changes after the soft reset.")
            HStack(spacing: 8) {
                TextField("New Changelist (optional)", text: $newTargetName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .newTargetName)
                    .help("Type a new Changelist name, or leave this empty to use the selected list.")
                if !newTargetName.isEmpty {
                    Button("Use Existing") {
                        newTargetName = ""
                        focusedField = .targetList
                    }
                    .buttonStyle(.borderless)
                    .help("Clear the new name and return to the selected Changelist.")
                }
            }
            if let newTargetNameError {
                Text(newTargetNameError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Undo Commit", action: { onUncommit(resolvedTargetName) })
                    .keyboardShortcut(.defaultAction)
                    .help("Soft reset HEAD to its first parent and keep the commit changes staged.")
                    .disabled(resolvedTargetName.isEmpty || newTargetNameError != nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            guard targetName.isEmpty else { return }
            let suggestedName = request.commit.summary
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = request.changeLists.first(where: { $0.name == suggestedName }) {
                targetName = existing.name
                focusedField = .targetList
            } else if GitChangelistSettings.createAutomatically(from: .standard), !suggestedName.isEmpty {
                newTargetName = suggestedName
                focusedField = .newTargetName
            } else {
                targetName = request.changeLists.first(where: { $0.isActive })?.name
                    ?? request.changeLists.first(where: { $0.isDefault })?.name
                    ?? request.changeLists.first?.name
                    ?? ""
                focusedField = .targetList
            }
        }
    }
}

/// Rebased/IntelliJ Git Reset 面板：目标提交固定展示，模式用单选互斥，
/// Hard/Keep 的破坏性边界在确认前明确说明。
struct RebasedResetDialog: View {
    let commit: CommitInfo
    var targetCommits: [CommitInfo] = []
    @Binding var mode: ResetMode
    let onReset: () -> Void
    let onCancel: () -> Void
    var multiRootResetAvailable = false
    var onResetAcrossRoots: (ResetMode) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(targetCommits.count > 1 ? "Reset Selected Git Roots" : "Reset Current Branch")
                .font(.title3.weight(.semibold))
            if targetCommits.count > 1 {
                Text("One selected revision will be used for each Git root.")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(targetCommits, id: \.id) { target in
                        HStack(spacing: 8) {
                            Text(URL(fileURLWithPath: target.repositoryPath ?? "").lastPathComponent)
                                .font(.headline)
                                .lineLimit(1)
                            Text("HEAD → \(target.shortId)")
                                .font(.system(.body, design: .monospaced))
                            Spacer(minLength: 4)
                        }
                        Text(target.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text("HEAD → \(commit.shortId)")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                    Text(commit.summary)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Divider()
            Picker("Reset mode", selection: $mode) {
                Text("Soft — keep index and working tree").tag(ResetMode.soft)
                Text("Mixed — reset index, keep working tree").tag(ResetMode.mixed)
                Text("Hard — reset index and working tree").tag(ResetMode.hard)
                Text("Keep — keep non-overlapping local changes").tag(ResetMode.keep)
            }
            .pickerStyle(.radioGroup)
            Text(description)
                .font(.caption)
                .foregroundStyle(mode == .hard ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if multiRootResetAvailable {
                    Button(targetCommits.count > 1 ? "Reset selected Git roots…" : "Reset in all Git roots…") {
                        onResetAcrossRoots(mode)
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Reset", role: mode == .hard ? .destructive : nil, action: onReset)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var description: String {
        switch mode {
        case .soft:
            return "Only the current branch pointer moves. Staged and unstaged changes stay exactly where they are."
        case .mixed:
            return "The index is reset to the target commit. Working-tree files are not rewritten."
        case .hard:
            return "Uncommitted staged and unstaged changes may be discarded. This cannot be undone from the working tree."
        case .keep:
            return "Git refuses overlapping local changes and keeps edits on paths unaffected by the reset."
        }
    }
}

struct RebasedResetTargetValidation: Equatable {
    let isValid: Bool
    let message: String
}

/// IntelliJ GitResetHead equivalent: choose a Git root, enter any revision
/// expression, validate it, then select the reset mode before execution.
struct RebasedHeadResetDialog: View {
    let roots: [GitRootInfo]
    @Binding var selectedRootPath: String
    @Binding var target: String
    @Binding var mode: ResetMode
    let onValidate: (String, String) -> RebasedResetTargetValidation
    let onReset: () -> Void
    let onCancel: () -> Void

    @State private var validation: RebasedResetTargetValidation?

    private var selectedRoot: GitRootInfo? {
        roots.first {
            canonicalExternalLogPath($0.path) == canonicalExternalLogPath(selectedRootPath)
        }
    }

    private var targetIsUsable: Bool {
        !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Reset Head")
                .font(.title3.weight(.semibold))
            if roots.count > 1 {
                Picker("Git root", selection: $selectedRootPath) {
                    ForEach(roots, id: \.path) { root in
                        Text("\(root.displayName) · \(root.relativePath)")
                            .tag(root.path)
                    }
                }
                .onChange(of: selectedRootPath) { _, _ in
                    validation = nil
                }
            }
            HStack {
                Text("Current branch")
                Spacer()
                Text(selectedRoot?.headBranch ?? "Detached HEAD")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                TextField("Revision", text: $target)
                    .textFieldStyle(.roundedBorder)
                Button("Validate") {
                    validation = onValidate(target, selectedRootPath)
                }
                .disabled(!targetIsUsable)
            }
            Text("Enter HEAD, a branch or tag name, a commit hash, or another Git revision expression.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let validation {
                Label(
                    validation.message,
                    systemImage: validation.isValid
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(validation.isValid ? .green : .red)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Picker("Reset mode", selection: $mode) {
                Text("Soft — keep index and working tree").tag(ResetMode.soft)
                Text("Mixed — reset index, keep working tree").tag(ResetMode.mixed)
                Text("Hard — reset index and working tree").tag(ResetMode.hard)
            }
            .pickerStyle(.radioGroup)
            Text(description)
                .font(.caption)
                .foregroundStyle(mode == .hard ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Reset", role: mode == .hard ? .destructive : nil, action: onReset)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!targetIsUsable)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onChange(of: target) { _, _ in
            validation = nil
        }
    }

    private var description: String {
        switch mode {
        case .soft:
            return "Only the current branch pointer moves. Staged and unstaged changes stay exactly where they are."
        case .mixed:
            return "The index is reset to the target commit. Working-tree files are not rewritten."
        case .hard:
            return "Uncommitted staged and unstaged changes may be discarded. This cannot be undone from the working tree."
        case .keep:
            return "Git refuses overlapping local changes and keeps edits on paths unaffected by the reset."
        }
    }
}

/// IntelliJ GitSmartOperationDialog equivalent. The list is deliberately
/// path-based because Git's overwrite detector is the authoritative source;
/// when a richer local Change model is unavailable, no affected path is hidden.
struct RebasedSmartOperationDialog: View {
    let request: SmartOperationRequest
    let onSmart: () -> Void
    let onForce: () -> Void
    let onCancel: () -> Void

    private var saveMethod: String {
        request.localChangesSavePolicy.title
    }

    private var affectedPaths: [String] {
        var seen = Set<String>()
        return request.paths.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Local changes would be overwritten")
                    .font(.title3.weight(.semibold))
            }
            Text("\(request.operationTitle) cannot continue because these local changes overlap the target operation.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(
                "Smart \(request.operationTitle) temporarily saves local changes as \(saveMethod), performs the operation, then restores them.",
                systemImage: saveMethod == "Shelf" ? "tray.and.arrow.down" : "archivebox"
            )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let detail = request.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }

            if affectedPaths.isEmpty {
                ContentUnavailableView(
                    "Git did not return affected paths",
                    systemImage: "doc.questionmark",
                    description: Text("Review the operation error before choosing how to continue.")
                )
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Affected local changes (\(affectedPaths.count))")
                        .font(.headline)
                    List(affectedPaths, id: \.self) { path in
                        Label(path, systemImage: "doc.text")
                            .lineLimit(1)
                            .help(path)
                    }
                    .listStyle(.inset)
                    .frame(minHeight: 160)
                }
            }

            HStack(spacing: 10) {
                if request.onForce != nil, let forceButtonTitle = request.forceButtonTitle {
                    Button(forceButtonTitle, role: .destructive, action: onForce)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button(request.smartButtonTitle, action: onSmart)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 440)
    }
}


/// REBASE-001：显式 rebase todo 编辑器。
/// 行内 action 菜单（pick/reword/edit/squash/fixup/drop）、上移/下移排序、
/// 多选后批量设置 action；reword 行内编辑新信息。最终顺序与 action 是
/// 执行时的权威（rebase_with_todo）。
func resetRebaseTodoDraftItems(
    current: [RebaseTodoItem],
    initial: [RebaseTodoItem]
) -> [RebaseTodoItem] {
    current == initial ? current : initial
}

/// Match IntelliJ's modified flag for the structured todo and an optional
/// native-todo override owned by the same editor session.
func rebaseTodoHasUnsavedChanges(
    current: [RebaseTodoItem],
    initial: [RebaseTodoItem],
    rawTodo: String? = nil
) -> Bool {
    current != initial || rawTodo != nil
}

/// Read-only commit details shown beside the structured rebase table.
/// The selected todo rows remain the source of truth; this pane only loads
/// metadata and changes for inspection, matching IntelliJ's details splitter.
private struct RebaseTodoCommitDetailsPane: View {
    let repo: Repository
    let commitIDs: [String]
    @State private var commits: [CommitInfo] = []
    @State private var focusedID: String?
    @State private var loadError: String?

    private var focusedCommit: CommitInfo? {
        guard let focusedID else { return commits.first }
        return commits.first { $0.id == focusedID } ?? commits.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if commits.count > 1 {
                List(selection: $focusedID) {
                    ForEach(commits, id: \.id) { commit in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(commit.summary)
                                .font(.callout.weight(.semibold))
                                .lineLimit(2)
                            Text(commit.shortId)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .tag(commit.id)
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 90, idealHeight: 125, maxHeight: 180)
            }

            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if let focusedCommit {
                CommitDetailView(
                    repo: repo,
                    commit: focusedCommit,
                    remotes: [],
                    onReverted: {},
                    onCherryPicked: {},
                    onCreateBranch: { _ in },
                    showsMetadata: true,
                    showsActions: false,
                    showsDiffPreview: true,
                    showsChanges: true
                )
            } else if commitIDs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sidebar.right")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Select a commit to view details")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Loading commit details…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: commitIDs) {
            commits = []
            focusedID = nil
            loadError = nil
            guard !commitIDs.isEmpty else { return }
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try commitIDs.map { try repo.commitInfo(commitId: $0) }
                }.value
                guard !Task.isCancelled else { return }
                commits = loaded
                focusedID = loaded.first?.id
            } catch {
                guard !Task.isCancelled else { return }
                loadError = error.localizedDescription
            }
        }
    }
}

/// Move the selected entries by one row while preserving their entry identity.
/// This mirrors IntelliJ's table move action: non-contiguous selections move
/// one step at a time, in order, rather than being treated as one index range.
func moveRebaseTodoItems(
    _ items: [RebaseTodoItem],
    selectedIndices: Set<Int>,
    requestedIndex: Int,
    by delta: Int
) -> [RebaseTodoItem] {
    guard (delta == -1 || delta == 1),
          items.indices.contains(requestedIndex) else { return items }
    let movingIDs: Set<String>
    if selectedIndices.contains(requestedIndex) {
        movingIDs = Set(selectedIndices.compactMap { index in
            items.indices.contains(index) ? items[index].commitId : nil
        })
    } else {
        movingIDs = [items[requestedIndex].commitId]
    }
    guard !movingIDs.isEmpty else { return items }

    let orderedIDs = items.filter { movingIDs.contains($0.commitId) }.map(\.commitId)
    var result = items
    let iteration: [String] = delta < 0 ? orderedIDs : Array(orderedIDs.reversed())
    for commitID in iteration {
        _ = moveOneRebaseTodoItem(&result, commitID: commitID, by: delta)
    }
    return result
}

/// Move one todo entry with the same group semantics as IntelliJ's
/// `GitRebaseTodoModel.exchangeIndices`:
///
/// - a squash/fixup child stays inside its group while moving within the
///   group, but becomes an independent pick when moved outside it;
/// - a group root moves together with all of its children;
/// - an entry inserted immediately before another group's child joins that
///   group as a fixup.
///
/// The structured model has no separate UniteRoot/UniteChild type, so the
/// action (`pick`/`squash`/`fixup`) is the persisted representation of that
/// relationship.
@discardableResult
private func moveOneRebaseTodoItem(
    _ items: inout [RebaseTodoItem],
    commitID: String,
    by delta: Int
) -> Bool {
    guard (delta == -1 || delta == 1),
          let index = items.firstIndex(where: { $0.commitId == commitID }),
          !items[index].isMergeCommit else { return false }

    let groupRoot = rebaseTodoGroupRootIndex(items: items, index: index) ?? index
    let groupIndices = rebaseTodoGroupIndices(items: items, rootIndex: groupRoot)
    let isGroupChild = groupIndices.count > 1 && index != groupRoot

    if isGroupChild {
        let targetIndex = index + delta
        guard items.indices.contains(targetIndex) else { return false }

        // IntelliJ first removes a UniteChild, moves it to the old group's
        // last slot, and only then applies the requested exchange. This
        // preserves the group's invariant when a child is exchanged with
        // another child, while making a child an independent pick when it
        // crosses the group's root or its trailing boundary.
        let groupEnd = groupIndices.last ?? index
        var detached = items.remove(at: index)
        setRebaseTodoAction(&detached, action: .pick)
        let groupSlot = min(groupEnd, items.count)
        items.insert(detached, at: groupSlot)

        if groupSlot == targetIndex {
            setRebaseTodoAction(&items[groupSlot], action: .fixup)
            return true
        }

        let moved = items.remove(at: groupSlot)
        items.insert(moved, at: targetIndex)
        attachRebaseTodoEntryIfNeeded(&items, at: targetIndex)
        return true
    }

    let isGroupRoot = groupIndices.count > 1 && index == groupRoot
    if isGroupRoot {
        let range = groupRoot...(groupIndices.last ?? groupRoot)
        let destination = delta < 0 ? range.lowerBound - 1 : range.upperBound + 1
        guard destination >= 0, destination < items.count else { return false }

        let moving = Array(items[range])
        items.removeSubrange(range)
        let insertionIndex = delta < 0
            ? destination
            : min(destination - moving.count + 1, items.count)
        items.insert(contentsOf: moving, at: insertionIndex)
        attachRebaseTodoUnitIfNeeded(&items, at: insertionIndex, count: moving.count)
        return true
    }

    let adjacentIndex = index + delta
    guard items.indices.contains(adjacentIndex) else { return false }
    items.swapAt(index, adjacentIndex)
    attachRebaseTodoEntryIfNeeded(&items, at: adjacentIndex)
    return true
}

/// If a moved entry now sits immediately before a UniteChild, preserve the
/// reference model's implicit group join by representing it as a fixup.
private func attachRebaseTodoEntryIfNeeded(
    _ items: inout [RebaseTodoItem],
    at index: Int
) {
    attachRebaseTodoUnitIfNeeded(&items, at: index, count: 1)
}

private func attachRebaseTodoUnitIfNeeded(
    _ items: inout [RebaseTodoItem],
    at index: Int,
    count: Int
) {
    guard count > 0,
          index >= 0,
          index + count <= items.count,
          index + count < items.count,
          !items[index].isMergeCommit,
          !items[index + count].isMergeCommit,
          items[index + count].action == .squash || items[index + count].action == .fixup,
          let groupRoot = rebaseTodoGroupRootIndex(items: items, index: index + count),
          groupRoot < index + count else {
        return
    }
    for offset in 0..<count {
        setRebaseTodoAction(&items[index + offset], action: .fixup)
    }
}

/// Apply SwiftUI's drag/drop destination to the todo array while preserving
/// the dragged commit identities and the order of a multi-row selection.
/// The destination is expressed in the pre-removal coordinate space.
func moveRebaseTodoRows(
    _ items: [RebaseTodoItem],
    from source: IndexSet,
    to destination: Int
) -> [RebaseTodoItem] {
    let sourceIndices = source.filter { items.indices.contains($0) }
    guard sourceIndices.count == source.count,
          !sourceIndices.isEmpty,
          (0...items.count).contains(destination) else { return items }

    // Dragging any member of a squash/fixup group moves the complete group.
    // This keeps the drag path consistent with the arrow buttons and avoids
    // manufacturing a group whose root is left behind in the source range.
    var expandedSource = Set(sourceIndices)
    for index in sourceIndices {
        guard let root = rebaseTodoGroupRootIndex(items: items, index: index) else { continue }
        expandedSource.formUnion(rebaseTodoGroupIndices(items: items, rootIndex: root))
    }
    let expandedIndices = expandedSource.sorted()
    let moving = expandedIndices.map { items[$0] }
    let movingSet = Set(expandedIndices)
    var remaining = items.enumerated()
        .filter { !movingSet.contains($0.offset) }
        .map(\.element)
    let removedBeforeDestination = expandedIndices.filter { $0 < destination }.count
    let insertionIndex = min(
        max(destination - removedBeforeDestination, 0),
        remaining.count
    )
    remaining.insert(contentsOf: moving, at: insertionIndex)
    attachRebaseTodoUnitIfNeeded(&remaining, at: insertionIndex, count: moving.count)
    return remaining
}

/// Preserve-merges structured editing may reorder rows only inside the
/// branch segments represented by the native todo. Merge rows are the visible
/// anchors for Git's hidden label/reset/merge control blocks and must keep
/// both their position and identity.
func rebaseTodoPreserveMergeSegmentRanges(
    _ items: [RebaseTodoItem]
) -> [Range<Int>] {
    guard !items.isEmpty else { return [] }
    var ranges: [Range<Int>] = []
    var segmentStart: Int?
    for index in items.indices {
        if items[index].isMergeCommit {
            if let segmentStart {
                ranges.append(segmentStart..<index)
            }
            segmentStart = nil
            continue
        }
        let startsSegment = index == items.startIndex
            || items[index - 1].isMergeCommit
            || !items[index].canSquashOrFixup
        if startsSegment {
            if let segmentStart {
                ranges.append(segmentStart..<index)
            }
            segmentStart = index
        }
    }
    if let segmentStart {
        ranges.append(segmentStart..<items.count)
    }
    return ranges
}

/// Return false when a proposed structured move would cross a merge control
/// boundary. The check is identity-based so selection and action edits cannot
/// make a stale index appear safe.
func rebaseTodoPreserveMergeReorderIsSafe(
    original: [RebaseTodoItem],
    updated: [RebaseTodoItem]
) -> Bool {
    guard original.count == updated.count else { return false }
    guard zip(original, updated).allSatisfy({ $0.isMergeCommit == $1.isMergeCommit }) else {
        return false
    }
    for (index, item) in original.enumerated() where item.isMergeCommit {
        guard original[index].commitId == updated[index].commitId else { return false }
    }
    for range in rebaseTodoPreserveMergeSegmentRanges(original) {
        let originalIDs = Set(original[range].map(\.commitId))
        let updatedIDs = Set(updated[range].map(\.commitId))
        guard originalIDs == updatedIDs else { return false }
    }
    return true
}

/// Whether a preserve-merges todo changed its visible commit order. The
/// identity check is shared by single-root and per-root multi-root editors.
func rebaseTodoPreserveMergeOrderChanged(
    initial: [RebaseTodoItem],
    current: [RebaseTodoItem],
    preserveMerges: Bool
) -> Bool {
    preserveMerges && initial.map(\.commitId) != current.map(\.commitId)
}

func rebaseTodoCanMove(
    _ items: [RebaseTodoItem],
    selectedIndices: Set<Int>,
    requestedIndex: Int,
    by delta: Int,
    preserveMerges: Bool
) -> Bool {
    guard items.indices.contains(requestedIndex),
          !items[requestedIndex].isMergeCommit else { return false }
    let updated = moveRebaseTodoItems(
        items,
        selectedIndices: selectedIndices,
        requestedIndex: requestedIndex,
        by: delta
    )
    guard updated != items else { return false }
    return !preserveMerges
        || rebaseTodoPreserveMergeReorderIsSafe(original: items, updated: updated)
}

private struct RebaseTodoDropDelegate: DropDelegate {
    let targetCommitID: String
    let sourceCommitIDs: () -> [String]
    let onMove: ([String], String) -> Void

    func dropEntered(info: DropInfo) {
        onMove(sourceCommitIDs(), targetCommitID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        true
    }
}

/// A squash/fixup row consumes the immediately preceding kept commit. The
/// graph capability is static, but the predecessor's action is user-editable;
/// keep the picker and bulk actions aligned with Git's todo constraint.
func rebaseTodoCanSquashOrFixup(
    items: [RebaseTodoItem],
    index: Int,
    preserveMerges: Bool
) -> Bool {
    guard items.indices.contains(index), index > 0 else { return false }
    guard !items[index].isMergeCommit, !items[index - 1].isMergeCommit else { return false }
    guard items[index - 1].action != .drop else { return false }
    return !preserveMerges || items[index].canSquashOrFixup
}

private func rebaseTodoGroupRootIndex(
    items: [RebaseTodoItem],
    index: Int
) -> Int? {
    guard items.indices.contains(index), !items[index].isMergeCommit else { return nil }
    var root = index
    while root > 0,
          items[root].action == .squash || items[root].action == .fixup {
        root -= 1
    }
    guard !items[root].isMergeCommit,
          items[root].action != .drop || root == index else { return nil }
    return root
}

private func rebaseTodoGroupIndices(
    items: [RebaseTodoItem],
    rootIndex: Int
) -> [Int] {
    guard items.indices.contains(rootIndex) else { return [] }
    var indices = [rootIndex]
    var next = rootIndex + 1
    while next < items.count,
          !items[next].isMergeCommit,
          items[next].action == .squash || items[next].action == .fixup {
        indices.append(next)
        next += 1
    }
    return indices
}

private func rebaseTodoEffectiveGroupMessage(
    items: [RebaseTodoItem],
    rootIndex: Int
) -> String {
    let indices = rebaseTodoGroupIndices(items: items, rootIndex: rootIndex)
    guard items.indices.contains(rootIndex) else { return "" }
    let root = items[rootIndex]
    if let message = root.message?.trimmingCharacters(in: .whitespacesAndNewlines),
       !message.isEmpty {
        return message
    }
    var parts = [root.summary]
    for index in indices.dropFirst() where items[index].action == .squash {
        parts.append(items[index].message ?? items[index].summary)
    }
    return parts.joined(separator: "\n\n")
}

/// Apply IntelliJ's selection-based unite behavior to a structured todo.
/// Selected rows (or their existing groups) are moved behind one kept root;
/// Fixup keeps the root message, while Squash exposes one final message row
/// and turns earlier children into fixups. In merge-preserving mode, only a
/// contiguous selection within one branch segment is accepted; native
/// topology rows and cross-segment selections remain fail-closed.
func uniteRebaseTodoItems(
    _ items: [RebaseTodoItem],
    selectedIndices: Set<Int>,
    action: RebaseTodoAction,
    preserveMerges: Bool
) -> [RebaseTodoItem]? {
    guard action == .squash || action == .fixup else { return nil }
    let selected = selectedIndices.sorted()
    guard !selected.isEmpty,
          selected.allSatisfy({ items.indices.contains($0) && !items[$0].isMergeCommit }) else {
        return nil
    }
    if preserveMerges {
        guard let first = selected.first,
              let last = selected.last,
              selected == Array(first...last),
              selected.dropFirst().allSatisfy({
                  rebaseTodoCanSquashOrFixup(items: items, index: $0, preserveMerges: true)
              }) else {
            return nil
        }
    }

    let targetRoot: Int?
    if selected.count == 1 {
        let selectedIndex = selected[0]
        targetRoot = (0..<selectedIndex).reversed()
            .compactMap { rebaseTodoGroupRootIndex(items: items, index: $0) }
            .first { items[$0].action != .drop }
    } else {
        targetRoot = rebaseTodoGroupRootIndex(items: items, index: selected[0])
    }
    guard let targetRoot else { return nil }

    let targetGroup = rebaseTodoGroupIndices(items: items, rootIndex: targetRoot)
    let targetGroupSet = Set(targetGroup)
    var addedIndices: [Int] = []
    for index in selected {
        guard let root = rebaseTodoGroupRootIndex(items: items, index: index) else { return nil }
        if targetGroupSet.contains(index) {
            continue
        }
        let group = rebaseTodoGroupIndices(items: items, rootIndex: root)
        if root == index, group.count > 1 {
            addedIndices.append(contentsOf: group)
        } else {
            addedIndices.append(index)
        }
    }
    guard !addedIndices.isEmpty else { return nil }
    var groupIndexSet = targetGroupSet
    groupIndexSet.formUnion(addedIndices)

    var orderedGroupIndices = targetGroup + addedIndices
    var seen = Set<Int>()
    orderedGroupIndices = orderedGroupIndices.filter { seen.insert($0).inserted }
    let groupItems = orderedGroupIndices.map { items[$0] }
    let remaining = items.enumerated()
        .filter { !groupIndexSet.contains($0.offset) }
        .map(\.element)
    let insertionIndex = items.enumerated()
        .prefix(targetRoot)
        .filter { !groupIndexSet.contains($0.offset) }
        .count

    var result = remaining
    result.insert(contentsOf: groupItems, at: insertionIndex)
    let rootResultIndex = insertionIndex
    let childStart = rootResultIndex + 1
    guard childStart < result.count else { return nil }

    if result[rootResultIndex].action == .edit || result[rootResultIndex].action == .drop {
        setRebaseTodoAction(&result[rootResultIndex], action: .pick)
    }
    for offset in 1..<groupItems.count {
        let originalIndex = orderedGroupIndices[offset]
        guard !targetGroupSet.contains(originalIndex) else { continue }
        let resultIndex = rootResultIndex + offset
        setRebaseTodoAction(&result[resultIndex], action: .fixup)
    }
    if action == .squash {
        let finalChildIndex = rootResultIndex + groupItems.count - 1
        setRebaseTodoAction(&result[finalChildIndex], action: .squash)
        var messageParts = [rebaseTodoEffectiveGroupMessage(items: items, rootIndex: targetRoot)]
        var consumedAddedIndices = Set<Int>()
        for index in addedIndices {
            guard !consumedAddedIndices.contains(index),
                  let root = rebaseTodoGroupRootIndex(items: items, index: index) else { continue }
            let group = rebaseTodoGroupIndices(items: items, rootIndex: root)
            if root == index, group.count > 1 {
                messageParts.append(rebaseTodoEffectiveGroupMessage(items: items, rootIndex: root))
                consumedAddedIndices.formUnion(group)
            } else if items[index].action != .fixup {
                messageParts.append(items[index].message ?? items[index].summary)
                consumedAddedIndices.insert(index)
            } else {
                consumedAddedIndices.insert(index)
            }
        }
        result[finalChildIndex].message = messageParts
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
    return result
}

/// Return whether a structured editor row can be reworded without breaking a
/// squash/fixup group. IntelliJ keeps reword on the group's root; a child must
/// first be detached with Pick/Edit/Drop.
func rebaseTodoCanReword(
    items: [RebaseTodoItem],
    index: Int
) -> Bool {
    guard items.indices.contains(index), !items[index].isMergeCommit else { return false }
    return rebaseTodoGroupRootIndex(items: items, index: index) == index
}

/// Apply one structured todo action while preserving IntelliJ's root/child
/// group semantics. A non-root action on a squash/fixup child detaches that
/// child and moves it after the group; dropping a group root drops the whole
/// group. Returning false means the action is not valid for this row.
@discardableResult
func applyRebaseTodoAction(
    _ items: inout [RebaseTodoItem],
    at index: Int,
    action: RebaseTodoAction
) -> Bool {
    guard items.indices.contains(index) else { return false }
    if items[index].isMergeCommit {
        guard action == .pick || action == .reword else { return false }
        setRebaseTodoAction(&items[index], action: action)
        return true
    }

    guard let rootIndex = rebaseTodoGroupRootIndex(items: items, index: index) else {
        return false
    }
    if action == .reword, rootIndex != index {
        return false
    }

    let groupIndices = rebaseTodoGroupIndices(items: items, rootIndex: rootIndex)
    if action == .drop, rootIndex == index, groupIndices.count > 1 {
        for groupIndex in groupIndices {
            setRebaseTodoAction(&items[groupIndex], action: .drop)
        }
        return true
    }

    if rootIndex != index,
       action != .squash,
       action != .fixup {
        let groupEndIndex = groupIndices.last ?? index
        var detached = items.remove(at: index)
        setRebaseTodoAction(&detached, action: action)
        items.insert(detached, at: min(groupEndIndex, items.count))
        return true
    }

    setRebaseTodoAction(&items[index], action: action)
    return true
}

func normalizeRebaseTodoActions(
    _ items: inout [RebaseTodoItem],
    preserveMerges: Bool
) {
    for index in items.indices {
        guard items[index].action == .squash || items[index].action == .fixup else { continue }
        guard rebaseTodoCanSquashOrFixup(items: items, index: index, preserveMerges: preserveMerges) else {
            items[index].action = .pick
            items[index].message = nil
            continue
        }
    }
}

func setRebaseTodoAction(_ item: inout RebaseTodoItem, action: RebaseTodoAction) {
    item.action = action
    if action != .reword && action != .squash {
        item.message = nil
    }
}

enum RebaseTodoHistoryChange: Equatable {
    case structural
    case message(commitID: String)
}

struct RebaseTodoEditHistory: Equatable {
    static let maximumStateCount = 10

    private(set) var states: [[RebaseTodoItem]]
    private(set) var cursor: Int
    private var lastChange: RebaseTodoHistoryChange?

    init(initial: [RebaseTodoItem]) {
        states = [initial]
        cursor = 0
        lastChange = nil
    }

    var current: [RebaseTodoItem] { states[cursor] }
    var canUndo: Bool { cursor > 0 }
    var canRedo: Bool { cursor + 1 < states.count }

    mutating func record(
        _ items: [RebaseTodoItem],
        change: RebaseTodoHistoryChange
    ) {
        guard items != current else { return }

        if cursor + 1 < states.count {
            states.removeSubrange((cursor + 1)..<states.count)
        }

        if case let .message(commitID) = change,
           lastChange == .message(commitID: commitID),
           !states.isEmpty {
            states[cursor] = items
        } else {
            states.append(items)
            cursor = states.count - 1
            if states.count > Self.maximumStateCount {
                states.removeFirst()
                cursor -= 1
            }
        }
        lastChange = change
    }

    mutating func undo() -> [RebaseTodoItem]? {
        guard canUndo else { return nil }
        cursor -= 1
        lastChange = nil
        return current
    }

    mutating func redo() -> [RebaseTodoItem]? {
        guard canRedo else { return nil }
        cursor += 1
        lastChange = nil
        return current
    }
}

func rebaseTodoActionCommand(_ action: RebaseTodoAction) -> String {
    switch action {
    case .pick: "pick"
    case .reword: "reword"
    case .edit: "edit"
    case .squash: "squash"
    case .fixup: "fixup"
    case .drop: "drop"
    }
}

func rebaseTodoContextSelection(selectedIndices: Set<Int>, row: Int) -> Set<Int> {
    selectedIndices.contains(row) ? selectedIndices : [row]
}

private struct RebaseCommandsHelpContext: Identifiable {
    let id = UUID()
    let title: String
    let items: [RebaseTodoItem]
}

/// IntelliJ's GitRebaseCommandsDialog equivalent. Keep this as a read-only
/// command reference so it cannot mutate the todo while the main editor keeps
/// ownership of selection, history, and execution state.
private struct RebaseCommandsHelpView: View {
    let title: String
    let items: [RebaseTodoItem]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
            HStack(spacing: 10) {
                Text("Action")
                    .frame(width: 90, alignment: .leading)
                Text("Commit")
                    .frame(width: 90, alignment: .leading)
                Text("Subject")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Divider()
            List(items.indices, id: \.self) { index in
                let item = items[index]
                HStack(spacing: 10) {
                    Text(rebaseTodoActionCommand(item.action))
                        .font(.system(.callout, design: .monospaced))
                        .frame(width: 90, alignment: .leading)
                    Text(String(item.commitId.prefix(10)))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)
                    Text(item.summary)
                        .lineLimit(1)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
            HStack {
                Text("Native label/reset/merge/exec/break/update-ref rows are available from Edit Native Todo…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 420)
    }
}

struct RebaseTodoEditorView: View {
    let repo: Repository
    let onto: String
    @Binding var items: [RebaseTodoItem]
    let preserveMerges: Bool
    let root: Bool
    let onStart: () -> Void
    let onOpenRawTodo: () -> Void
    let onCancel: () -> Void

    @State private var initialItems: [RebaseTodoItem]
    @State private var selected = Set<Int>()
    @State private var history: RebaseTodoEditHistory
    @State private var showDiscardChangesAlert = false
    @State private var draggedCommitID: String?
    @State private var commandsHelpContext: RebaseCommandsHelpContext?

    init(
        repo: Repository,
        onto: String,
        items: Binding<[RebaseTodoItem]>,
        preserveMerges: Bool,
        root: Bool,
        onStart: @escaping () -> Void,
        onOpenRawTodo: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.repo = repo
        self.onto = onto
        self._items = items
        self.preserveMerges = preserveMerges
        self.root = root
        self.onStart = onStart
        self.onOpenRawTodo = onOpenRawTodo
        self.onCancel = onCancel
        self._initialItems = State(initialValue: items.wrappedValue)
        self._history = State(initialValue: RebaseTodoEditHistory(initial: items.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Interactive Rebase").font(.title3.weight(.semibold))
                Spacer()
                Text(root ? "repository root · \(items.count) commits" : "onto \(shortId(onto)) · \(items.count) commits")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if root {
                Label("Rewrite from the repository root", systemImage: "arrow.uturn.left.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if preserveMerges {
                Label("Preserve merge commits", systemImage: "arrow.triangle.merge")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Merge rows keep Git's label/reset/merge topology; rows may be reordered only within one native branch segment. Squash/fixup remains limited to an unchanged segment order, and cross-boundary combinations are blocked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Picker("", selection: $bulkAction) {
                    Text("Pick").tag(RebaseTodoAction.pick)
                    Text("Reword").tag(RebaseTodoAction.reword)
                    Text("Edit").tag(RebaseTodoAction.edit)
                    Text("Squash").tag(RebaseTodoAction.squash)
                    Text("Fixup").tag(RebaseTodoAction.fixup)
                    Text("Drop").tag(RebaseTodoAction.drop)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 110)
                Button("Apply to Selected") { applyBulkAction() }
                    .disabled(selected.isEmpty)
                Button("Undo") { undo() }
                    .disabled(!history.canUndo)
                    .keyboardShortcut("z", modifiers: .command)
                    .help("Undo the last todo edit")
                Button("Redo") { redo() }
                    .disabled(!history.canRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .help("Redo the last todo edit")
                Button("Reset") {
                    let reset = resetRebaseTodoDraftItems(current: items, initial: initialItems)
                    record(reset, change: .structural)
                    selected.removeAll()
                }
                .disabled(items == initialItems)
                .help("Restore the todo order and actions from when this editor opened")
                Button("Edit Native Todo…", action: onOpenRawTodo)
                    .help("Edit Git's complete todo text, including label/reset/merge and other native commands")
                Button("Commands…") {
                    commandsHelpContext = RebaseCommandsHelpContext(
                        title: "Git Rebase Commands",
                        items: items
                    )
                }
                .help("Show the available action commands for this todo")
                Spacer()
                Text(selected.isEmpty ? "单击行选中；⌘ 多选" : "\(selected.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HSplitView {
                List(Array(items.indices), id: \.self, selection: $selected) { index in
                    todoRow(index)
                        .onDrag {
                            draggedCommitID = items[index].commitId
                            return NSItemProvider(object: NSString(string: items[index].commitId))
                        }
                        .onDrop(
                            of: [.text],
                            delegate: RebaseTodoDropDelegate(
                                targetCommitID: items[index].commitId,
                                sourceCommitIDs: {
                                    guard let draggedCommitID else { return [] }
                                    return selectedCommitIDs.contains(draggedCommitID)
                                        ? selectedCommitIDs
                                        : [draggedCommitID]
                                },
                                onMove: moveDraggedRows
                            )
                        )
                }
                .listStyle(.inset)
                .frame(minWidth: 520, idealWidth: 620, maxWidth: .infinity)

                RebaseTodoCommitDetailsPane(
                    repo: repo,
                    commitIDs: selectedCommitIDs
                )
                .frame(minWidth: 380, idealWidth: 460, maxWidth: .infinity)
            }
            .frame(minHeight: 340, maxHeight: .infinity)
            HStack {
                Button("Cancel", role: .cancel, action: requestCancel)
                Spacer()
                Button("Start Rebase", action: onStart)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(items.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 1020, minHeight: 560)
        .sheet(item: $commandsHelpContext) { context in
            RebaseCommandsHelpView(title: context.title, items: context.items)
        }
        .alert("Discard Rebase Changes?", isPresented: $showDiscardChangesAlert) {
            Button("Keep Editing", role: .cancel) {}
            Button("Discard Changes", role: .destructive, action: onCancel)
        } message: {
            Text("Your interactive rebase todo has unsaved changes.")
        }
    }

    private var selectedCommitIDs: [String] {
        selected.sorted().compactMap { index in
            items.indices.contains(index) ? items[index].commitId : nil
        }
    }

    private func moveDraggedRows(_ movingIDs: [String], before targetID: String) {
        guard !movingIDs.isEmpty,
              let targetIndex = items.firstIndex(where: { $0.commitId == targetID }),
              !movingIDs.contains(targetID),
              movingIDs.allSatisfy({ id in
                  items.first(where: { $0.commitId == id })?.isMergeCommit == false
              }) else {
            return
        }
        let source = IndexSet(items.indices.filter { movingIDs.contains(items[$0].commitId) })
        let updated = moveRebaseTodoRows(items, from: source, to: targetIndex)
        guard updated != items,
              !preserveMerges
                || rebaseTodoPreserveMergeReorderIsSafe(original: items, updated: updated) else {
            return
        }
        record(updated, change: .structural)
    }

    @State private var bulkAction: RebaseTodoAction = .pick

    private func todoRow(_ index: Int) -> some View {
        let contextSelection = rebaseTodoContextSelection(
            selectedIndices: selected,
            row: index
        )
        let canEditOrDrop = contextSelection.allSatisfy {
            items.indices.contains($0) && !items[$0].isMergeCommit
        }
        let canUnite = uniteRebaseTodoItems(
            items,
            selectedIndices: contextSelection,
            action: .squash,
            preserveMerges: preserveMerges
        ) != nil && !preserveMergeOrderChanged
        return HStack(spacing: 8) {
            if items[index].isMergeCommit {
                Picker("merge action", selection: Binding(
                    get: { items[index].action },
                    set: { setMergeAction($0, at: index) }
                )) {
                    Text("pick").tag(RebaseTodoAction.pick)
                    Text("reword").tag(RebaseTodoAction.reword)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 100)
            } else {
                Picker("", selection: Binding(
                    get: { items[index].action },
                    set: { setAction($0, at: index) }
                )) {
                    Text("pick").tag(RebaseTodoAction.pick)
                    if rebaseTodoCanReword(items: items, index: index) {
                        Text("reword").tag(RebaseTodoAction.reword)
                    }
                    Text("edit").tag(RebaseTodoAction.edit)
                    if !preserveMergeOrderChanged,
                       rebaseTodoCanSquashOrFixup(
                        items: items,
                        index: index,
                        preserveMerges: preserveMerges
                    ) {
                        Text("squash").tag(RebaseTodoAction.squash)
                        Text("fixup").tag(RebaseTodoAction.fixup)
                    }
                    Text("drop").tag(RebaseTodoAction.drop)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 100)
            }
            Text(shortId(items[index].commitId))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            if items[index].isMergeCommit, items[index].action == .reword {
                TextField("reword merge message", text: Binding(
                    get: { items[index].message ?? items[index].summary },
                    set: { setMessage($0, at: index) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
            } else if items[index].isMergeCommit {
                Text("merge topology controlled by Git: \(items[index].summary)")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            } else if items[index].action == .squash {
                TextEditor(text: Binding(
                    get: { items[index].message ?? "" },
                    set: { setMessage($0, at: index) }
                ))
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 48, maxHeight: 88)
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.25))
                }
                .help("Optional final message for the squashed commit; leave empty for Git's default combined message.")
            } else if items[index].action == .reword {
                TextField("reword message", text: Binding(
                    get: { items[index].message ?? items[index].summary },
                    set: { setMessage($0, at: index) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
            } else {
                Text(items[index].summary)
                    .lineLimit(1)
                    .strikethrough(items[index].action == .drop)
                    .foregroundStyle(items[index].action == .drop ? .secondary : .primary)
            }
            Spacer()
            Button(action: { move(index, by: -1) }) {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.plain)
            .disabled(!rebaseTodoCanMove(
                items,
                selectedIndices: selected,
                requestedIndex: index,
                by: -1,
                preserveMerges: preserveMerges
            ))
            Button(action: { move(index, by: 1) }) {
                Image(systemName: "arrow.down")
            }
            .buttonStyle(.plain)
            .disabled(!rebaseTodoCanMove(
                items,
                selectedIndices: selected,
                requestedIndex: index,
                by: 1,
                preserveMerges: preserveMerges
            ))
        }
        .contextMenu {
            Button("Pick") { applyContextAction(.pick, at: index) }
            if items[index].isMergeCommit
                || rebaseTodoCanReword(items: items, index: index) {
                Button("Reword") { applyContextAction(.reword, at: index) }
            }
            if canEditOrDrop {
                Button("Edit") { applyContextAction(.edit, at: index) }
            }
            if canUnite {
                Button("Squash") { applyContextAction(.squash, at: index) }
                Button("Fixup") { applyContextAction(.fixup, at: index) }
            }
            if canEditOrDrop {
                Button("Drop") { applyContextAction(.drop, at: index) }
            }
            Divider()
            Button("Commands…") {
                commandsHelpContext = RebaseCommandsHelpContext(
                    title: "Git Rebase Commands",
                    items: items
                )
            }
        }
    }

    private func move(_ index: Int, by delta: Int) {
        guard items.indices.contains(index) else { return }
        let effectiveSelection = selected.contains(index) ? selected : [index]
        let updated = moveRebaseTodoItems(
            items,
            selectedIndices: effectiveSelection,
            requestedIndex: index,
            by: delta
        )
        guard updated != items,
              !preserveMerges
                || rebaseTodoPreserveMergeReorderIsSafe(original: items, updated: updated) else {
            return
        }
        record(updated, change: .structural)
    }

    private func applyBulkAction() {
        if bulkAction == .squash || bulkAction == .fixup {
            guard !preserveMergeOrderChanged else { return }
            guard let united = uniteRebaseTodoItems(
                items,
                selectedIndices: selected,
                action: bulkAction,
                preserveMerges: preserveMerges
            ) else { return }
            record(united, change: .structural)
            return
        }

        var updated = items
        let selectedCommitIDs = selected.sorted().compactMap { index in
            items.indices.contains(index) ? items[index].commitId : nil
        }
        for commitID in selectedCommitIDs.reversed() {
            guard let index = updated.firstIndex(where: { $0.commitId == commitID }) else { continue }
            guard !updated[index].isMergeCommit else { continue }
            _ = applyRebaseTodoAction(&updated, at: index, action: bulkAction)
        }
        normalizeRebaseTodoActions(&updated, preserveMerges: preserveMerges)
        record(updated, change: .structural)
    }

    private func applyContextAction(_ action: RebaseTodoAction, at index: Int) {
        guard items.indices.contains(index) else { return }
        let contextSelection = rebaseTodoContextSelection(
            selectedIndices: selected,
            row: index
        )
        if action == .squash || action == .fixup {
            guard !preserveMergeOrderChanged else { return }
            guard let united = uniteRebaseTodoItems(
                items,
                selectedIndices: contextSelection,
                action: action,
                preserveMerges: preserveMerges
            ) else { return }
            selected = contextSelection
            record(united, change: .structural)
            return
        }

        if action == .edit || action == .drop {
            guard contextSelection.allSatisfy({
                items.indices.contains($0) && !items[$0].isMergeCommit
            }) else { return }
        }

        var updated = items
        let contextCommitIDs = contextSelection.sorted().compactMap { target in
            items.indices.contains(target) ? items[target].commitId : nil
        }
        for commitID in contextCommitIDs.reversed() {
            guard let target = updated.firstIndex(where: { $0.commitId == commitID }) else { continue }
            _ = applyRebaseTodoAction(&updated, at: target, action: action)
        }
        normalizeRebaseTodoActions(&updated, preserveMerges: preserveMerges)
        selected = contextSelection
        record(updated, change: .structural)
    }

    private func setAction(_ action: RebaseTodoAction, at index: Int) {
        guard items.indices.contains(index), !items[index].isMergeCommit else { return }
        guard !preserveMergeOrderChanged || (action != .squash && action != .fixup) else { return }
        var updated = items
        guard applyRebaseTodoAction(&updated, at: index, action: action) else { return }
        record(updated, change: .structural)
    }

    private func setMergeAction(_ action: RebaseTodoAction, at index: Int) {
        guard items.indices.contains(index), items[index].isMergeCommit else { return }
        var updated = items
        setRebaseTodoAction(&updated[index], action: action)
        record(updated, change: .structural)
    }

    private func setMessage(_ message: String, at index: Int) {
        guard items.indices.contains(index) else { return }
        var updated = items
        updated[index].message = message.isEmpty ? nil : message
        record(updated, change: .message(commitID: updated[index].commitId))
    }

    private func record(_ updated: [RebaseTodoItem], change: RebaseTodoHistoryChange) {
        let selectedIDs = Set(selected.compactMap { index in
            items.indices.contains(index) ? items[index].commitId : nil
        })
        history.record(updated, change: change)
        items = updated
        selected = Set(updated.indices.filter { selectedIDs.contains(updated[$0].commitId) })
    }

    private func undo() {
        let selectedIDs = Set(selected.compactMap { index in
            items.indices.contains(index) ? items[index].commitId : nil
        })
        guard let previous = history.undo() else { return }
        items = previous
        selected = Set(previous.indices.filter { selectedIDs.contains(previous[$0].commitId) })
    }

    private func redo() {
        let selectedIDs = Set(selected.compactMap { index in
            items.indices.contains(index) ? items[index].commitId : nil
        })
        guard let next = history.redo() else { return }
        items = next
        selected = Set(next.indices.filter { selectedIDs.contains(next[$0].commitId) })
    }

    private func shortId(_ id: String) -> String {
        String(id.prefix(7))
    }

    private var preserveMergeOrderChanged: Bool {
        rebaseTodoPreserveMergeOrderChanged(
            initial: initialItems,
            current: items,
            preserveMerges: preserveMerges
        )
    }

    private func requestCancel() {
        if rebaseTodoHasUnsavedChanges(current: items, initial: initialItems) {
            showDiscardChangesAlert = true
        } else {
            onCancel()
        }
    }
}

enum NativeRebaseTodoLineKind: Equatable {
    case blank
    case comment
    case commit(command: String, commitID: String, subject: String)
    case control(command: String, arguments: String)
    case invalid
}

struct NativeRebaseTodoPreviewRow: Identifiable, Equatable {
    let lineNumber: Int
    let source: String
    let kind: NativeRebaseTodoLineKind

    var id: Int { lineNumber }
}

/// Parse only enough of Git's native todo syntax to make control rows
/// legible while editing. Git remains the execution authority; this preview
/// deliberately warns about unknown/malformed rows instead of rejecting a
/// command that a newer Git version may understand.
func parseNativeRebaseTodoPreview(_ text: String) -> [NativeRebaseTodoPreviewRow] {
    let commitCommands: Set<String> = [
        "pick", "p", "reword", "r", "edit", "e", "squash", "s", "fixup", "f", "drop", "d"
    ]
    let controlCommands: Set<String> = [
        "label", "reset", "merge", "exec", "break", "update-ref"
    ]

    let normalizedLines = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .components(separatedBy: "\n")

    return normalizedLines.enumerated().map { offset, source in
        let lineNumber = offset + 1
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return NativeRebaseTodoPreviewRow(lineNumber: lineNumber, source: source, kind: .blank)
        }
        if trimmed.hasPrefix("#") {
            return NativeRebaseTodoPreviewRow(lineNumber: lineNumber, source: source, kind: .comment)
        }

        let tokens = trimmed.split { character in
            character == " " || character == "\t"
        }
        guard let commandToken = tokens.first else {
            return NativeRebaseTodoPreviewRow(lineNumber: lineNumber, source: source, kind: .blank)
        }
        let command = String(commandToken).lowercased()
        if commitCommands.contains(command), tokens.count >= 2 {
            let subject = tokens.dropFirst(2).map(String.init).joined(separator: " ")
            return NativeRebaseTodoPreviewRow(
                lineNumber: lineNumber,
                source: source,
                kind: .commit(
                    command: command,
                    commitID: String(tokens[tokens.index(tokens.startIndex, offsetBy: 1)]),
                    subject: subject
                )
            )
        }
        if controlCommands.contains(command) {
            return NativeRebaseTodoPreviewRow(
                lineNumber: lineNumber,
                source: source,
                kind: .control(
                    command: command,
                    arguments: tokens.dropFirst().map(String.init).joined(separator: " ")
                )
            )
        }
        return NativeRebaseTodoPreviewRow(lineNumber: lineNumber, source: source, kind: .invalid)
    }
}

/// Update only the argument payload of one native control row. Keeping this
/// transformation line-scoped preserves comments, commit rows, unknown Git
/// syntax, and the original newline convention; Git still validates the
/// resulting todo before execution.
func updateNativeRebaseTodoControlLine(
    _ text: String,
    lineNumber: Int,
    command: String,
    arguments: String
) -> String {
    guard lineNumber > 0 else { return text }
    let newline = text.contains("\r\n") ? "\r\n" : "\n"
    var lines = text.components(separatedBy: newline)
    let index = lineNumber - 1
    guard lines.indices.contains(index) else { return text }

    let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedCommand.isEmpty else { return text }
    let indentation = lines[index].prefix { character in
        character == " " || character == "\t"
    }
    let trimmedArguments = trimmedCommand.lowercased() == "break"
        ? ""
        : arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    lines[index] = String(indentation) + trimmedCommand
        + (trimmedArguments.isEmpty ? "" : " \(trimmedArguments)")
    return lines.joined(separator: newline)
}

let nativeRebaseTodoControlCommands = [
    "label", "reset", "merge", "exec", "break", "update-ref"
]

/// Move one native control row without interpreting the surrounding todo.
/// Raw text remains the source of truth, so comments, unknown commands, and
/// Git-version-specific syntax travel with the line exactly as entered.
func moveNativeRebaseTodoControlLine(
    _ text: String,
    lineNumber: Int,
    by delta: Int
) -> String {
    guard lineNumber > 0, delta != 0 else { return text }
    let newline = text.contains("\r\n") ? "\r\n" : "\n"
    var lines = text.components(separatedBy: newline)
    let sourceIndex = lineNumber - 1
    let destinationIndex = sourceIndex + delta
    guard lines.indices.contains(sourceIndex),
          lines.indices.contains(destinationIndex),
          let sourceRow = parseNativeRebaseTodoPreview(text)
              .first(where: { $0.lineNumber == lineNumber }),
          case .control = sourceRow.kind else {
        return text
    }
    lines.swapAt(sourceIndex, destinationIndex)
    return lines.joined(separator: newline)
}

func nativeRebaseTodoControlCommand(_ text: String, lineNumber: Int) -> String? {
    guard let row = parseNativeRebaseTodoPreview(text)
        .first(where: { $0.lineNumber == lineNumber }),
        case let .control(command, _) = row.kind else { return nil }
    return command
}

func nativeRebaseTodoControlArguments(_ text: String, lineNumber: Int) -> String? {
    guard let row = parseNativeRebaseTodoPreview(text)
        .first(where: { $0.lineNumber == lineNumber }),
        case let .control(_, arguments) = row.kind else { return nil }
    return arguments
}

private struct NativeRebaseTodoPreviewView: View {
    @Binding var text: String

    private var rows: [NativeRebaseTodoPreviewRow] {
        parseNativeRebaseTodoPreview(text)
    }

    private var invalidCount: Int {
        rows.filter { $0.kind == .invalid }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Structured Preview", systemImage: "list.bullet.rectangle")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text("Git remains authoritative")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if invalidCount > 0 {
                Label(
                    String(invalidCount) + " line(s) are not recognized by this preview; Git will validate them on start.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            List(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(String(row.lineNumber))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .frame(width: 32, alignment: .trailing)
                    previewRow(row)
                }
                .listRowSeparator(.visible)
            }
            .listStyle(.inset)
        }
        .padding(.leading, 8)
    }

    @ViewBuilder
    private func previewRow(_ row: NativeRebaseTodoPreviewRow) -> some View {
        switch row.kind {
        case .blank:
            Text("blank")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .comment:
            Text(row.source.trimmingCharacters(in: .whitespaces))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case let .commit(command, commitID, subject):
            Text(command)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 64, alignment: .leading)
            Text(String(commitID.prefix(10)))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(subject.isEmpty ? "(commit message)" : subject)
                .lineLimit(1)
        case let .control(command, arguments):
            Picker(
                "control command",
                selection: Binding(
                    get: {
                        nativeRebaseTodoControlCommand(text, lineNumber: row.lineNumber)
                            ?? command
                    },
                    set: { newCommand in
                        let newArguments = newCommand == "break" ? "" : arguments
                        text = updateNativeRebaseTodoControlLine(
                            text,
                            lineNumber: row.lineNumber,
                            command: newCommand,
                            arguments: newArguments
                        )
                    }
                )
            ) {
                ForEach(nativeRebaseTodoControlCommands, id: \.self) { controlCommand in
                    Text(controlCommand).tag(controlCommand)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(.caption.monospaced().weight(.semibold))
            .frame(width: 120, alignment: .leading)

            if command == "break" {
                Text("(stop here)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                TextField(
                    "arguments",
                    text: Binding(
                        get: {
                            nativeRebaseTodoControlArguments(text, lineNumber: row.lineNumber)
                                ?? arguments
                        },
                        set: { newValue in
                            text = updateNativeRebaseTodoControlLine(
                                text,
                                lineNumber: row.lineNumber,
                                command: nativeRebaseTodoControlCommand(
                                    text,
                                    lineNumber: row.lineNumber
                                ) ?? command,
                                arguments: newValue
                            )
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity)
            }
            Button {
                text = moveNativeRebaseTodoControlLine(
                    text,
                    lineNumber: row.lineNumber,
                    by: -1
                )
            } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.plain)
            .disabled(row.lineNumber == 1)
            .help("Move control row up")
            Button {
                text = moveNativeRebaseTodoControlLine(
                    text,
                    lineNumber: row.lineNumber,
                    by: 1
                )
            } label: {
                Image(systemName: "arrow.down")
            }
            .buttonStyle(.plain)
            .disabled(row.lineNumber == rows.count)
            .help("Move control row down")
        case .invalid:
            Label(row.source, systemImage: "questionmark.square")
                .font(.caption.monospaced())
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }
}

/// Text fallback for Git's native interactive-rebase todo. The editor keeps
/// comments and control rows intact, while the adjacent preview makes
/// `label/reset/merge/exec/break/update-ref` understandable without taking
/// ownership of Git's evolving native syntax.
struct RawRebaseTodoEditorView: View {
    let onto: String
    @Binding var text: String
    let preserveMerges: Bool
    let root: Bool
    let onStart: () -> Void
    let onCancel: () -> Void
    private let initialText: String
    @State private var showDiscardChangesAlert = false

    init(
        onto: String,
        text: Binding<String>,
        preserveMerges: Bool,
        root: Bool,
        onStart: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onto = onto
        self._text = text
        self.preserveMerges = preserveMerges
        self.root = root
        self.onStart = onStart
        self.onCancel = onCancel
        self.initialText = text.wrappedValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Native Git Rebase Todo")
                        .font(.title3.weight(.semibold))
                    Text(root ? "repository root" : "onto \(shortId(onto))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label("Git syntax", systemImage: "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("This is Git's complete todo file. Keep commit IDs and control rows valid; commands such as exec run with the repository's normal Git permissions.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if preserveMerges {
                Label("Merge-preserving topology is controlled by the native label/reset/merge rows.", systemImage: "arrow.triangle.merge")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HSplitView {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(minWidth: 680, minHeight: 520)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25))
                    }

                NativeRebaseTodoPreviewView(text: $text)
                    .frame(minWidth: 390, idealWidth: 460, maxWidth: .infinity)
            }
            HStack {
                Button("Cancel", role: .cancel, action: requestCancel)
                Spacer()
                Button("Start Rebase", action: onStart)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 1180, minHeight: 680)
        .alert("Discard Native Todo Changes?", isPresented: $showDiscardChangesAlert) {
            Button("Keep Editing", role: .cancel) {}
            Button("Discard Changes", role: .destructive, action: onCancel)
        } message: {
            Text("The native Git rebase todo has unsaved changes.")
        }
    }

    private func shortId(_ id: String) -> String {
        String(id.prefix(7))
    }

    private func requestCancel() {
        if text == initialText {
            onCancel()
        } else {
            showDiscardChangesAlert = true
        }
    }
}

/// SwiftUI counterpart of Git's unstructured commit-message editor request
/// during a native raw-todo rebase.
struct RawRebaseMessageEditorView: View {
    @Binding var message: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Commit Message")
                .font(.title3.weight(.semibold))
            Text("Git is waiting for the message for a reword or squash step.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $message)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 620, minHeight: 300)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25))
                }
            HStack {
                Button("Cancel Message Edit", role: .cancel, action: onCancel)
                Spacer()
                Button("Save Message", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 700, minHeight: 420)
    }
}

/// Full-message dialog for the Log HEAD Reword fast path.
/// It intentionally does not expose staged-file controls: the engine uses
/// `git commit --amend --only` and leaves the current index untouched.
struct LogRewordDialogView: View {
    let commit: CommitInfo
    @Binding var message: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reword Commit")
                .font(.title3.weight(.semibold))
            Text("HEAD \(commit.shortId) · Edit the complete commit message. Staged changes are not included.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $message)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 560, minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Reword", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 320)
    }
}

/// IntelliJ's multi-commit Squash action edits the final combined message
/// before starting the rewrite; it does not open the generic todo editor.
struct LogSquashDialogView: View {
    let commitSummaries: [String]
    @Binding var message: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Squash Commits")
                .font(.title3.weight(.semibold))
            Text("Edit the combined commit message. The selected commits will be replayed as one commit.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(commitSummaries.enumerated()), id: \.offset) { _, summary in
                        Text("• \(summary)")
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 86)
            .padding(8)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            TextEditor(text: $message)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 600, minHeight: 210)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Squash", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 660, minHeight: 430)
    }
}


/// REMOTE-001：Configure Remotes Dialog。
/// 远程列表 + URL / push URL / fetch refspec / push refspec 编辑 + 添加/删除/重命名。
struct RemoteConfigDialogView: View {
    let remotes: [RemoteInfo]
    @Binding var name: String
    @Binding var url: String
    @Binding var pushUrl: String
    @Binding var fetchRefspec: String
    @Binding var pushRefspec: String
    let initialSelectedName: String?
    @State private var selectedName: String?
    let onAdd: (Bool) -> Void
    let onRemove: (String) -> Void
    let onRename: (String, String) -> Void
    let onSave: () -> Void
    let onCancel: () -> Void
    let onRefresh: () -> Void
    @State private var fetchAfterAdd = true

    private var remoteNamesKey: String {
        remotes.map(\.name).joined(separator: "\u{1F}")
    }

    private func populate(_ remote: RemoteInfo) {
        name = remote.name
        url = remote.url
        pushUrl = remote.pushUrl ?? ""
        fetchRefspec = remote.fetchRefspec ?? ""
        pushRefspec = remote.pushRefspec ?? ""
    }

    private func clearFields() {
        name = ""
        url = ""
        pushUrl = ""
        fetchRefspec = ""
        pushRefspec = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Remotes").font(.title3.weight(.semibold))
                Spacer()
                Button("Refresh") { onRefresh() }
                Button("Cancel", role: .cancel, action: onCancel)
            }
            HStack(spacing: 0) {
                List(remotes, id: \.name, selection: $selectedName) { remote in
                    HStack(spacing: 6) {
                        Image(systemName: "network")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(remote.name).font(.system(size: 13, weight: .semibold))
                            Text(remote.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tag(remote.name)
                }
                .listStyle(.sidebar)
                .frame(width: 240)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if let selected = selectedName, let remote = remotes.first(where: { $0.name == selected }) {
                        Group {
                            Text("Name")
                            TextField("name", text: Binding(get: { name }, set: { name = $0 }))
                                .textFieldStyle(.roundedBorder)
                            Text("URL")
                            TextField("https://…", text: $url)
                                .textFieldStyle(.roundedBorder)
                            Text("Push URL (可选)")
                            TextField("https://…", text: $pushUrl)
                                .textFieldStyle(.roundedBorder)
                            Text("Fetch refspec")
                            TextField("+refs/heads/*:refs/remotes/origin/*", text: $fetchRefspec)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                            Text("Push refspec (可选)")
                            TextField("HEAD:refs/heads/main", text: $pushRefspec)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Button("Remove") { onRemove(remote.name) }
                            Button("Rename…") {
                                if name.trimmingCharacters(in: .whitespaces).isEmpty {
                                    name = remote.name
                                }
                                onRename(remote.name, name)
                                selectedName = name.trimmingCharacters(in: .whitespaces)
                            }
                            Spacer()
                            Button("Save") { onSave() }
                                .keyboardShortcut(.defaultAction)
                                .buttonStyle(.borderedProminent)
                        }
                    } else {
                        Text("选择一个远程进行编辑")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 8) {
                Text("New remote")
                    .foregroundStyle(.secondary)
                TextField("name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                TextField("https://…", text: $url)
                    .textFieldStyle(.roundedBorder)
                Toggle("Fetch after adding", isOn: $fetchAfterAdd)
                    .toggleStyle(.checkbox)
                Button("Add") { onAdd(fetchAfterAdd) }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                        || url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 420)
        .onAppear {
            let initial = selectedName.flatMap { selected in
                remotes.first(where: { $0.name == selected })
            } ?? initialSelectedName.flatMap { selected in
                remotes.first(where: { $0.name == selected })
            }
            if selectedName == nil {
                selectedName = initial?.name
            }
            if let initial {
                populate(initial)
            } else {
                clearFields()
            }
        }
        .onChange(of: selectedName) { _, newValue in
            guard let newValue, let remote = remotes.first(where: { $0.name == newValue }) else { return }
            populate(remote)
        }
        .onChange(of: remoteNamesKey) { _, _ in
            let selected = selectedName.flatMap { selected in
                remotes.first(where: { $0.name == selected })
            }
            selectedName = selected?.name
            if let selected {
                populate(selected)
            } else {
                clearFields()
            }
        }
    }
}


private struct MultiRootRemoteEditorContext: Identifiable {
    let id = UUID()
    let rootPath: String
    let originalName: String?
    let isAdd: Bool
    let name: String
    let url: String
    let pushURL: String
    let fetchRefspec: String
    let pushRefspec: String
}

private struct MultiRootRemoteConfigEditorView: View {
    let context: MultiRootRemoteEditorContext
    let onSubmit: (String, String, String, String, String, Bool, @escaping (Bool) -> Void) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var url: String
    @State private var pushURL: String
    @State private var fetchRefspec: String
    @State private var pushRefspec: String
    @State private var fetchAfterSave = true
    @State private var validationMessage: String?
    @State private var isSubmitting = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case name
        case url
    }

    init(
        context: MultiRootRemoteEditorContext,
        onSubmit: @escaping (String, String, String, String, String, Bool, @escaping (Bool) -> Void) -> Void
    ) {
        self.context = context
        self.onSubmit = onSubmit
        _name = State(initialValue: context.name)
        _url = State(initialValue: context.url)
        _pushURL = State(initialValue: context.pushURL)
        _fetchRefspec = State(initialValue: context.fetchRefspec)
        _pushRefspec = State(initialValue: context.pushRefspec)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(context.isAdd ? "Add Remote" : "Edit Remote")
                .font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $name)
                    .focused($focusedField, equals: .name)
                TextField("URL", text: $url)
                    .focused($focusedField, equals: .url)
                Toggle("Fetch after saving", isOn: $fetchAfterSave)
                    .toggleStyle(.checkbox)
                if !context.isAdd {
                    DisclosureGroup("Advanced") {
                        TextField("Push URL (可选)", text: $pushURL)
                        TextField("Fetch refspec", text: $fetchRefspec)
                            .font(.system(.body, design: .monospaced))
                        TextField("Push refspec (可选)", text: $pushRefspec)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .disabled(isSubmitting)
                Button(context.isAdd ? "Add" : "Save") {
                    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
                    validationMessage = nil
                    guard !trimmedName.isEmpty else {
                        validationMessage = "Remote name is required"
                        focusedField = .name
                        return
                    }
                    guard !trimmedURL.isEmpty else {
                        validationMessage = "Remote URL is required"
                        focusedField = .url
                        return
                    }
                    isSubmitting = true
                    onSubmit(
                        trimmedName,
                        trimmedURL,
                        pushURL.trimmingCharacters(in: .whitespacesAndNewlines),
                        fetchRefspec.trimmingCharacters(in: .whitespacesAndNewlines),
                        pushRefspec.trimmingCharacters(in: .whitespacesAndNewlines),
                        fetchAfterSave
                    ) { success in
                        isSubmitting = false
                        if success {
                            dismiss()
                        } else {
                            validationMessage = "Remote URL check failed; see the operation feedback for details."
                            focusedField = .url
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting)
            }
        }
        .padding(18)
        .frame(width: 560)
    }
}

/// IntelliJ 的 GitConfigureRemotesDialog：按 Git root 分组展示 remote，
/// Add 使用当前 root，Edit/Remove 使用选中的 remote，双击 remote 进入编辑。
struct MultiRootRemoteConfigDialogView: View {
    let roots: [MultiRootRemoteConfigRoot]
    let onAdd: (String, String, String, Bool, @escaping (Bool) -> Void) -> Void
    let onEdit: (String, String, String, String, String, String, String, Bool, @escaping (Bool) -> Void) -> Void
    let onRemove: (String, String) -> Void
    let onRefresh: () -> Void
    let onCancel: () -> Void
    @State private var selectedID: String?
    @State private var selectedRootPath: String?
    @State private var editor: MultiRootRemoteEditorContext?

    private func selectionID(rootPath: String, remoteName: String) -> String {
        "\(rootPath)\u{1F}\(remoteName)"
    }

    private func selectedRoot() -> MultiRootRemoteConfigRoot? {
        if let selectedRootPath, let root = roots.first(where: { $0.rootPath == selectedRootPath }) {
            return root
        }
        guard let selectedID else { return roots.first }
        return roots.first { root in
            selectedID == root.rootPath || selectedID.hasPrefix(root.rootPath + "\u{1F}")
        } ?? roots.first
    }

    private func selectedRemote() -> (MultiRootRemoteConfigRoot, RemoteInfo)? {
        guard let selectedID else { return nil }
        for root in roots {
            if let remote = root.remotes.first(where: {
                selectedID == selectionID(rootPath: root.rootPath, remoteName: $0.name)
            }) {
                return (root, remote)
            }
        }
        return nil
    }

    private func openAdd() {
        guard let root = selectedRoot() else { return }
        let proposedName = root.remotes.contains(where: { $0.name == "origin" }) ? "" : "origin"
        editor = MultiRootRemoteEditorContext(
            rootPath: root.rootPath,
            originalName: nil,
            isAdd: true,
            name: proposedName,
            url: "",
            pushURL: "",
            fetchRefspec: "",
            pushRefspec: ""
        )
    }

    private func openEdit(root: MultiRootRemoteConfigRoot, remote: RemoteInfo) {
        editor = MultiRootRemoteEditorContext(
            rootPath: root.rootPath,
            originalName: remote.name,
            isAdd: false,
            name: remote.name,
            url: remote.url,
            pushURL: remote.pushUrl ?? "",
            fetchRefspec: remote.fetchRefspec ?? "",
            pushRefspec: remote.pushRefspec ?? ""
        )
    }

    private func openEdit() {
        guard let (root, remote) = selectedRemote() else { return }
        openEdit(root: root, remote: remote)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Configure Remotes")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Refresh") { onRefresh() }
                Button("Done", role: .cancel, action: onCancel)
            }
            List(selection: $selectedID) {
                ForEach(roots) { root in
                    Section {
                        if root.remotes.isEmpty {
                            Text("No remotes")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(root.remotes, id: \.name) { remote in
                                HStack(spacing: 8) {
                                    Text(remote.name)
                                        .font(.system(size: 13, weight: .medium))
                                    Spacer(minLength: 12)
                                    Text(remote.url)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .contentShape(Rectangle())
                                .tag(selectionID(rootPath: root.rootPath, remoteName: remote.name))
                                .onTapGesture(count: 2) {
                                    selectedID = selectionID(rootPath: root.rootPath, remoteName: remote.name)
                                    openEdit(root: root, remote: remote)
                                }
                            }
                        }
                    } header: {
                        Button {
                            selectedRootPath = root.rootPath
                            selectedID = nil
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(root.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                Text(root.relativePath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.inset)
            HStack(spacing: 8) {
                Button("Add") { openAdd() }
                Button("Edit…") { openEdit() }
                    .disabled(selectedRemote() == nil)
                Button("Remove") {
                    guard let (root, remote) = selectedRemote() else { return }
                    onRemove(root.rootPath, remote.name)
                }
                .disabled(selectedRemote() == nil)
                Spacer()
                Text("\(roots.count) repositories")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 500)
        .onAppear {
            if selectedRootPath == nil {
                selectedRootPath = roots.first?.rootPath
            }
        }
        .onChange(of: selectedID) { _, newValue in
            guard let newValue else { return }
            selectedRootPath = roots.first { root in
                newValue == root.rootPath || newValue.hasPrefix(root.rootPath + "\u{1F}")
            }?.rootPath
        }
        .onChange(of: roots.map(\.rootPath)) { _, _ in
            if selectedRootPath == nil || !roots.contains(where: { $0.rootPath == selectedRootPath }) {
                selectedRootPath = roots.first?.rootPath
            }
        }
        .sheet(item: $editor) { context in
            MultiRootRemoteConfigEditorView(context: context) { name, url, pushURL, fetchRefspec, pushRefspec, fetchAfterSave, completion in
                if context.isAdd {
                    onAdd(context.rootPath, name, url, fetchAfterSave, completion)
                } else if let originalName = context.originalName {
                    onEdit(
                        context.rootPath,
                        originalName,
                        name,
                        url,
                        pushURL,
                        fetchRefspec,
                        pushRefspec,
                        fetchAfterSave,
                        completion
                    )
                }
            }
        }
    }
}

/// IntelliJ 的 CleanupBranchesDialog：按目标分支和名称前缀筛选，
/// 先计算合并状态，再逐项选择并批量删除本地分支。
struct BranchCleanupDialogView: View {
    let roots: [BranchCleanupRoot]
    let onCalculate: (String, String) -> Void
    let onDelete: ([BranchCleanupSelection]) -> Void
    let onRefresh: () -> Void
    let onCancel: () -> Void

    @State private var targetBranch = ""
    @State private var prefix = ""
    @State private var appliedPrefix = ""
    @State private var sortMode: BranchCleanupSortMode = .name
    @State private var selected = Set<BranchCleanupSelection>()
    @State private var rowSelection = Set<BranchCleanupSelection>()
    @State private var showDeleteConfirmation = false

    private func selection(for root: BranchCleanupRoot, branch: BranchInfo) -> BranchCleanupSelection {
        BranchCleanupSelection(rootPath: root.rootPath, branchName: branch.name)
    }

    private func visibleBranches(in root: BranchCleanupRoot, prefix filterPrefix: String? = nil) -> [BranchInfo] {
        let filter = (filterPrefix ?? appliedPrefix).trimmingCharacters(in: .whitespacesAndNewlines)
        let branches = root.branches
            .filter { filter.isEmpty || $0.name.hasPrefix(filter) }
        return branches.sorted { lhs, rhs in
            switch sortMode {
            case .name:
                return lhs.name < rhs.name
            case .lastCommit:
                if lhs.lastCommitTime != rhs.lastCommitTime {
                    return lhs.lastCommitTime > rhs.lastCommitTime
                }
                return lhs.name < rhs.name
            case .mergedStatus:
                let lhsMerged = root.mergedBranches.contains(lhs.name)
                let rhsMerged = root.mergedBranches.contains(rhs.name)
                if lhsMerged != rhsMerged { return lhsMerged && !rhsMerged }
                return lhs.name < rhs.name
            }
        }
    }

    private var selectableVisibleBranches: [BranchCleanupSelection] {
        roots.flatMap { root in
            visibleBranches(in: root)
                .filter { !$0.isCurrent }
                .map { selection(for: root, branch: $0) }
        }
    }

    private var selectedNames: String {
        selected.compactMap { branch in
            guard let root = roots.first(where: { $0.rootPath == branch.rootPath }) else { return nil }
            return "\(root.relativePath): \(branch.branchName)"
        }
        .sorted()
        .joined(separator: ", ")
    }

    private var selectionHeaderState: BranchCleanupSelectionHeaderState {
        let visible = selectableVisibleBranches
        guard !visible.isEmpty else { return .none }
        let selectedCount = visible.filter { selected.contains($0) }.count
        if selectedCount == 0 { return .none }
        if selectedCount == visible.count { return .all }
        return .some
    }

    private func toggleVisibleSelection() {
        if selectionHeaderState == .all {
            selected.subtract(selectableVisibleBranches)
        } else {
            selected.formUnion(selectableVisibleBranches)
        }
    }

    private func applyFilter() {
        let nextPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        appliedPrefix = nextPrefix
        let visibleRows = roots.flatMap { root in
            visibleBranches(in: root, prefix: nextPrefix).map { branch in
                (root: root, branch: branch)
            }
        }
        selected.formIntersection(Set(
            visibleRows
                .filter { !$0.branch.isCurrent }
                .map { selection(for: $0.root, branch: $0.branch) }
        ))
        rowSelection.formIntersection(Set(
            visibleRows.map { selection(for: $0.root, branch: $0.branch) }
        ))
    }

    private func selectedBranchesClipboardText() -> String? {
        let orderedRows = roots.flatMap { root in
            visibleBranches(in: root).map { selection(for: root, branch: $0) }
        }
        let selectedRows = branchCleanupSelectedRows(orderedRows, selected: rowSelection)
        let rows = selectedRows.compactMap { row -> BranchCleanupClipboardRow? in
            guard let root = roots.first(where: { $0.rootPath == row.rootPath }),
                  let branch = root.branches.first(where: { $0.name == row.branchName }) else {
                return nil
            }
            return BranchCleanupClipboardRow(
                branchName: branch.name,
                lastCommitDate: lastCommitDate(for: branch),
                trackedBranch: root.trackingByBranch[branch.name] ?? ""
            )
        }
        let copied = formattedBranchCleanupClipboardRows(rows)
        return copied.isEmpty ? nil : copied
    }

    private func copySelectedBranches() {
        guard let copied = selectedBranchesClipboardText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copied, forType: .string)
    }

    private func mergeStatusIsAvailable(for root: BranchCleanupRoot) -> Bool {
        let target = targetBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = appliedPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return !target.isEmpty
            && root.calculatedTarget == target
            && root.calculatedPrefix == prefix
    }

    private var mergeStatusIsAvailableForAllRoots: Bool {
        !roots.isEmpty && roots.allSatisfy { mergeStatusIsAvailable(for: $0) }
    }

    private func defaultTargetBranch() -> String {
        let allBranches = roots.flatMap(\.branches)
        return allBranches.first(where: { $0.name == "main" })?.name
            ?? allBranches.first(where: { $0.name == "master" })?.name
            ?? allBranches.first(where: { $0.isCurrent })?.name
            ?? allBranches.first?.name
            ?? ""
    }

    private func lastCommitDate(for branch: BranchInfo) -> String {
        guard branch.lastCommitTime > 0 else { return "" }
        return Date(timeIntervalSince1970: TimeInterval(branch.lastCommitTime))
            .formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Cleanup Branches")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Refresh") {
                    selected.removeAll()
                    rowSelection.removeAll()
                    onRefresh()
                }
                Button("Done", role: .cancel, action: onCancel)
            }

            HStack(spacing: 10) {
                Text("Target branch")
                TextField("Target branch", text: $targetBranch)
                    .textFieldStyle(.roundedBorder)
                Text("Filter prefix")
                TextField("Filter prefix", text: $prefix)
                    .textFieldStyle(.roundedBorder)
                Button("Filter", action: applyFilter)
                Button("Calculate") {
                    selected.removeAll()
                    onCalculate(
                        targetBranch.trimmingCharacters(in: .whitespacesAndNewlines),
                        appliedPrefix
                    )
                }
                .disabled(targetBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack {
                Text("Branch")
                Spacer()
                Text("Last commit")
                    .frame(width: 150, alignment: .leading)
                Text("Tracked branch")
                    .frame(width: 180, alignment: .leading)
                Text("Status")
                    .frame(width: 100, alignment: .leading)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                BranchCleanupHeaderCheckbox(state: selectionHeaderState, onToggle: toggleVisibleSelection)
                    .frame(width: 18, height: 18)
                    .accessibilityLabel("Select all visible branches")
                Button("Clear") { selected.removeAll() }
                Button("Copy", action: copySelectedBranches)
                    .disabled(rowSelection.isEmpty)
                Menu("Sort") {
                    Picker("Sort", selection: $sortMode) {
                        Text("Name").tag(BranchCleanupSortMode.name)
                        Text("Last commit").tag(BranchCleanupSortMode.lastCommit)
                        Text("Merged status").tag(BranchCleanupSortMode.mergedStatus)
                    }
                }
                if mergeStatusIsAvailableForAllRoots {
                    Text(
                        String(localized: "Merged status calculated for %@")
                            .replacingOccurrences(
                                of: "%@",
                                with: targetBranch.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(
                    String(localized: "%@ selected")
                        .replacingOccurrences(of: "%@", with: String(selected.count))
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            List(selection: $rowSelection) {
                ForEach(roots) { root in
                    Section {
                        let rows = visibleBranches(in: root)
                        let mergeStatusAvailable = mergeStatusIsAvailable(for: root)
                        if rows.isEmpty {
                            Text("No branches")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(rows, id: \.name) { branch in
                                let branchSelection = selection(for: root, branch: branch)
                                Toggle(isOn: Binding(
                                    get: { selected.contains(branchSelection) },
                                    set: { value in
                                        if value {
                                            selected.insert(branchSelection)
                                        } else {
                                            selected.remove(branchSelection)
                                        }
                                    }
                                )) {
                                    HStack(spacing: 8) {
                                        Text(branch.name)
                                            .font(.system(.body, design: .monospaced))
                                        if branch.isCurrent {
                                            Text("Current")
                                                .font(.caption)
                                                .foregroundStyle(.blue)
                                        }
                                        Spacer()
                                        Text(lastCommitDate(for: branch))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 150, alignment: .leading)
                                        Text(root.trackingByBranch[branch.name] ?? "")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .frame(width: 180, alignment: .leading)
                                        if mergeStatusAvailable {
                                            Text(root.mergedBranches.contains(branch.name) ? "Merged" : "Not merged")
                                                .font(.caption)
                                                .foregroundStyle(root.mergedBranches.contains(branch.name) ? .green : .secondary)
                                        } else {
                                            Text("Not calculated")
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .tag(branchSelection)
                                .disabled(branch.isCurrent)
                            }
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(root.displayName)
                                .font(.system(size: 13, weight: .semibold))
                            Text(root.relativePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)

            HStack {
                Text(
                    String(localized: "%@ repositories")
                        .replacingOccurrences(of: "%@", with: String(roots.count))
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Delete selected branches", role: .destructive) {
                    showDeleteConfirmation = true
                }
                .disabled(selected.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 900, minHeight: 560)
        .onAppear {
            if targetBranch.isEmpty { targetBranch = defaultTargetBranch() }
        }
        .onCopyCommand {
            guard let copied = selectedBranchesClipboardText() else { return [] }
            return [NSItemProvider(object: NSString(string: copied))]
        }
        .alert("Delete selected branches", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                onDelete(Array(selected))
                selected.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(selectedNames)
        }
    }
}

/// IntelliJ 的 FindMergedLocalBranchesAction：只读扫描各 Git root，按目标分支
/// 和名称前缀列出已合并的本地分支，并保留仓库边界。
struct FindMergedBranchesDialogView: View {
    let roots: [BranchCleanupRoot]
    let projectName: String
    @Binding var targetBranch: String
    @Binding var prefix: String
    let isRunning: Bool
    let hasCalculated: Bool
    let summary: FindMergedScanSummary?
    let onCalculate: () -> Void
    let onOpenReport: () -> Void
    let onCopy: () -> Void
    let onDone: () -> Void
    let onCancel: () -> Void

    private var normalizedTarget: String {
        targetBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedPrefix: String {
        prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasMatchingCalculation: Bool {
        summary?.targetBranch == normalizedTarget && summary?.prefix == normalizedPrefix
    }

    private var reportText: String? {
        guard let summary, hasMatchingCalculation else { return nil }
        return findMergedBranchesReportText(
            summary: summary,
            roots: roots,
            projectName: projectName
        )
    }

    private var mergedBranchCount: Int {
        roots.reduce(0) { count, root in
            count + mergedBranches(in: root).count
        }
    }

    private func mergedBranches(in root: BranchCleanupRoot) -> [BranchInfo] {
        mergedBranchNames(
            in: root,
            targetBranch: normalizedTarget,
            prefix: normalizedPrefix
        ).compactMap { name in root.branches.first { $0.name == name } }
    }

    private func rootStatus(for root: BranchCleanupRoot) -> String? {
        guard hasCalculated, root.calculatedTarget == nil else { return nil }
        let title = String(localized: "Calculation unavailable in this repository")
        guard let error = root.calculationError, !error.isEmpty else { return title }
        return "\(title): \(error)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Find Merged Local Branches")
                    .font(.title3.weight(.semibold))
                Spacer()
                if isRunning {
                    Button("Cancel", role: .cancel, action: onCancel)
                } else {
                    Button("Done", role: .cancel, action: onDone)
                }
            }

            HStack(spacing: 10) {
                Text("Target branch")
                TextField("Target branch", text: $targetBranch)
                    .textFieldStyle(.roundedBorder)
                Text("Filter prefix")
                TextField("Filter prefix", text: $prefix)
                    .textFieldStyle(.roundedBorder)
                Button("Find", action: onCalculate)
                    .disabled(normalizedTarget.isEmpty || isRunning)
            }

            HStack(spacing: 8) {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text("Finding merged branches…")
                        .foregroundStyle(.secondary)
                } else if hasMatchingCalculation {
                    Text(
                        String(localized: "%@ merged branches found")
                            .replacingOccurrences(of: "%@", with: String(mergedBranchCount))
                    )
                        .foregroundStyle(.secondary)
                } else if hasCalculated {
                    Text("Run Find after changing the target or prefix")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if reportText != nil {
                    Button("Open Report", action: onOpenReport)
                }
                Button("Copy", action: onCopy)
                    .disabled(!hasMatchingCalculation || isRunning)
            }

            if roots.isEmpty {
                if isRunning {
                    ProgressView("Loading repositories…")
                } else if hasCalculated {
                    Text("No repository results are available for this target")
                        .foregroundStyle(.secondary)
                } else {
                    Text("No repositories loaded")
                        .foregroundStyle(.secondary)
                }
            } else {
                List {
                    ForEach(roots) { root in
                        Section {
                        let branches = mergedBranches(in: root)
                            if !hasCalculated {
                                Text("Run Find to calculate merged branches")
                                    .foregroundStyle(.secondary)
                            } else if root.calculatedTarget != normalizedTarget
                                        || root.calculatedPrefix != normalizedPrefix {
                                Text("Run Find after changing the target or prefix")
                                    .foregroundStyle(.secondary)
                            } else if let status = rootStatus(for: root) {
                                Text(status)
                                    .foregroundStyle(.secondary)
                            } else if branches.isEmpty {
                                Text("No merged branches")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(branches, id: \.name) { branch in
                                    HStack(spacing: 8) {
                                        Image(systemName: "checkmark.branch")
                                            .foregroundStyle(.green)
                                        Text(branch.name)
                                            .font(.system(.body, design: .monospaced))
                                        Spacer()
                                        Text(branch.shortId)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(root.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                Text(root.relativePath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(16)
        .frame(minWidth: 820, minHeight: 520)
    }
}

/// IntelliJ opens FindMergedLocalBranches results as a standalone plain-text
/// editor. Keep the document independent from the grouped scan dialog so it
/// can be inspected, selected, edited, or copied after the dialog changes.
struct FindMergedReportEditorView: View {
    let report: String
    @Environment(\.dismiss) private var dismiss
    @State private var document: String

    init(report: String) {
        self.report = report
        _document = State(initialValue: report)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .foregroundStyle(Design.Colors.accent)
                Text("Merged Branches Report")
                    .font(.headline)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(document, forType: .string)
                }
                Button("Done", role: .cancel) {
                    dismiss()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            TextEditor(text: $document)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

/// Returns stable branch rows for a completed calculation. A root with an
/// error intentionally produces no rows, so a partial result cannot be read
/// as a successful empty result.
func mergedBranchNames(
    in root: BranchCleanupRoot,
    targetBranch: String,
    prefix: String
) -> [String] {
    guard root.calculatedTarget == targetBranch,
          root.calculatedPrefix == prefix else {
        return []
    }
    return root.branches
        .filter {
            $0.name != targetBranch
                && root.mergedBranches.contains($0.name)
                && (prefix.isEmpty || $0.name.hasPrefix(prefix))
        }
        .map(\.name)
        .sorted()
}

/// Builds the plain-text result document used by Find Merged Local Branches.
/// Raw root errors remain visible instead of being reduced to an empty list.
func findMergedBranchesReportText(
    summary: FindMergedScanSummary,
    roots: [BranchCleanupRoot],
    projectName: String
) -> String {
    var lines = [
        "=== Merged local branches into '\(summary.targetBranch)' ==="
    ]
    if !summary.prefix.isEmpty {
        lines.append("Filter prefix: '\(summary.prefix)'")
    }
    if !projectName.isEmpty {
        lines.append("Project: \(projectName)")
    }
    lines.append("")

    var found = 0
    for root in roots.sorted(by: { $0.relativePath < $1.relativePath }) {
        lines.append("Root: \(root.rootPath)")
        if let error = root.calculationError, !error.isEmpty {
            lines.append("  Error: \(error)")
        } else {
            let branches = mergedBranchNames(
                in: root,
                targetBranch: summary.targetBranch,
                prefix: summary.prefix
            )
            found += branches.count
            if branches.isEmpty {
                lines.append("  No merged branches found.")
            } else {
                lines.append(contentsOf: branches.map { "  \($0)" })
            }
        }
        lines.append("")
    }

    lines.append("Summary:")
    lines.append("  Status: \(summary.isCancelled ? "Cancelled" : "Completed")")
    lines.append("  Repositories discovered: \(summary.repositoriesDiscovered)")
    lines.append("  Repositories scanned: \(summary.repositoriesScanned)")
    lines.append("  Candidate branches checked: \(summary.candidateBranchesChecked)")
    lines.append("  Merged branches found: \(found)")
    lines.append("  Errors count: \(summary.errorsCount)")
    lines.append("  Total search time: \(summary.elapsedMilliseconds) ms")
    return lines.joined(separator: "\n") + "\n"
}


/// Phase 5：Submodule 面板——列表 + add/update(+init/recursive/remote)/嵌套 Log/deinit/remove/分支配置。
struct SubmodulePanel: View {
    let submodules: [SubmoduleInfo]
    let feedback: String?
    let onAdd: () -> Void
    let onUpdate: () -> Void
    let onSync: () -> Void
    let onUpdatePath: (String) -> Void
    let onUpdateOptions: (Bool, Bool, Bool) -> Void
    let onDeinit: (String, Bool) -> Void
    let onRemove: (String) -> Void
    let onSetBranch: (String, String) -> Void
    let onLog: (String) -> Void
    let onPush: (String) -> Void
    let onConfigureRemotes: (String) -> Void
    let onRefresh: () -> Void

    @State private var initFlag = true
    @State private var recursiveFlag = false
    @State private var remoteFlag = false
    @State private var branchInput = ""

    private func stateText(_ state: SubmoduleState) -> String {
        switch state {
        case .clean: return "clean"
        case .modified: return "modified"
        case .uninitialized: return "uninitialized"
        case .conflict: return "conflict"
        case .missing: return "missing"
        case .unknown: return "unknown"
        }
    }

    private func canPush(_ state: SubmoduleState) -> Bool {
        switch state {
        case .uninitialized, .missing:
            return false
        case .clean, .modified, .conflict, .unknown:
            return true
        }
    }

    private func canUpdate(_ state: SubmoduleState) -> Bool {
        switch state {
        case .clean, .modified:
            return true
        case .uninitialized, .conflict, .missing, .unknown:
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Submodules").font(.headline)
                Spacer()
                Toggle("init", isOn: $initFlag).toggleStyle(.checkbox).font(.caption)
                Toggle("recursive", isOn: $recursiveFlag).toggleStyle(.checkbox).font(.caption)
                Toggle("--remote", isOn: $remoteFlag).toggleStyle(.checkbox).font(.caption)
                Button("Update") { onUpdateOptions(initFlag, recursiveFlag, remoteFlag) }
                    .controlSize(.small)
                Button("Sync") { onSync() }
                    .controlSize(.small)
                    .help("Synchronize submodule URLs from .gitmodules")
                Button("Add…") { onAdd() }
                    .controlSize(.small)
                Button("Refresh") { onRefresh() }
                    .controlSize(.small)
            }
            if let feedback, !feedback.isEmpty {
                Text(feedback).font(.caption).foregroundStyle(.secondary)
            }
            if submodules.isEmpty {
                ContentUnavailableView {
                    Label("No Submodules", systemImage: "square.stack.3d.up")
                }
            } else {
                List(submodules, id: \.path) { module in
                    HStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(module.path).font(.system(size: 13, weight: .medium))
                            HStack(spacing: 6) {
                                Text(stateText(module.state))
                                    .font(.caption)
                                    .foregroundStyle(module.dirty ? .orange : .secondary)
                                if module.dirty {
                                    Text("dirty")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                                if let branch = module.branch {
                                    Text(branch)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        Spacer()
                        TextField("branch", text: $branchInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                            .font(.caption)
                        Button("Set Branch") { onSetBranch(module.path, branchInput) }
                            .controlSize(.small)
                            .disabled(branchInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Update") { onUpdatePath(module.path) }
                            .controlSize(.small)
                            .disabled(!canUpdate(module.state))
                            .help("Update this initialized submodule from its parent; local changes are preserved.")
                        Button("Log") { onLog(module.path) }
                            .controlSize(.small)
                        Button("Push") { onPush(module.path) }
                            .controlSize(.small)
                            .disabled(!canPush(module.state))
                        Button("Remotes…") { onConfigureRemotes(module.path) }
                            .controlSize(.small)
                        Button("Deinit") { onDeinit(module.path, true) }
                            .controlSize(.small)
                        Button("Remove", role: .destructive) { onRemove(module.path) }
                            .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
        .padding(12)
    }
}

/// 子模块自己的提交日志；数据来自嵌套仓库，而不是父仓库的 gitlink 记录。
struct SubmoduleLogView: View {
    let path: String
    let commits: [CommitInfo]
    let error: String?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Submodule Log")
                        .font(.title2.weight(.semibold))
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Close", action: onClose)
            }

            if let error, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if commits.isEmpty {
                ContentUnavailableView {
                    Label("No commits", systemImage: "clock")
                }
            } else {
                List(commits, id: \.id) { commit in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(commit.summary)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(2)
                            Spacer()
                            Text(commit.shortId)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            Text(commit.authorName.isEmpty ? "—" : commit.authorName)
                            Text(Date(timeIntervalSince1970: TimeInterval(commit.time)), style: .date)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if !commit.messageBody.isEmpty {
                            Text(commit.messageBody)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    .padding(.vertical, 3)
                    .contextMenu {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(commit.id, forType: .string)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 460)
    }
}


/// The Git contributor's searchable project scope. Keeping the repository
/// path with each ref is essential in a multi-root project: the same branch
/// or tag name may resolve to different commits in different roots.
struct SearchEverywhereGitRoot {
    let rootPath: String
    let displayName: String
    let relativePath: String
    let branches: [BranchInfo]
    let remoteBranches: [RemoteBranchInfo]
    let tags: [TagInfo]
}

enum SearchEverywhereItemKind: String, Equatable {
    case localBranch
    case remoteBranch
    case tag
    case commitByHash
    case commitByMessage

    var sectionTitle: String {
        switch self {
        case .localBranch: return "LOCAL BRANCHES"
        case .remoteBranch: return "REMOTE BRANCHES"
        case .tag: return "TAGS"
        case .commitByHash: return "COMMITS BY HASH"
        case .commitByMessage: return "COMMITS BY MESSAGE"
        }
    }

    var symbolName: String {
        switch self {
        case .localBranch: return "arrow.branch"
        case .remoteBranch: return "arrow.triangle.branch"
        case .tag: return "tag"
        case .commitByHash, .commitByMessage: return "clock"
        }
    }
}

struct SearchEverywhereItem: Identifiable, Equatable {
    let kind: SearchEverywhereItemKind
    let rootPath: String
    let revision: String
    let title: String
    let subtitle: String
    let shortID: String?

    var id: String {
        "\(kind.rawValue):\(rootPath):\(revision)"
    }
}

func searchEverywhereReferenceItems(
    roots: [SearchEverywhereGitRoot],
    query: String
) -> [SearchEverywhereItem] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedQuery.isEmpty else { return [] }

    var items: [SearchEverywhereItem] = []
    for root in roots {
        let rootLabel = root.relativePath == "."
            ? root.displayName
            : "\(root.displayName) · \(root.relativePath)"
        items.append(contentsOf: root.branches.filter {
            branchSearchMatches($0.name, query: normalizedQuery)
        }.map { branch in
            SearchEverywhereItem(
                kind: .localBranch,
                rootPath: root.rootPath,
                revision: branch.name,
                title: branch.name,
                subtitle: branch.isCurrent ? "\(rootLabel) · current" : rootLabel,
                shortID: branch.shortId
            )
        })
        items.append(contentsOf: root.remoteBranches.filter {
            branchSearchMatches($0.name, query: normalizedQuery)
        }.map { branch in
            SearchEverywhereItem(
                kind: .remoteBranch,
                rootPath: root.rootPath,
                revision: branch.name,
                title: branch.name,
                subtitle: "\(rootLabel) · \(branch.remote)",
                shortID: branch.shortId
            )
        })
        items.append(contentsOf: root.tags.filter {
            branchSearchMatches($0.name, query: normalizedQuery)
        }.map { tag in
            SearchEverywhereItem(
                kind: .tag,
                rootPath: root.rootPath,
                revision: tag.name,
                title: tag.name,
                subtitle: rootLabel,
                shortID: tag.shortId
            )
        })
    }
    return items
}

func searchEverywhereCanSearchCommitByHash(_ query: String) -> Bool {
    let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.count >= 7 else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
        (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 65 && scalar.value <= 70)
            || (scalar.value >= 97 && scalar.value <= 102)
    }
}

func searchEverywhereCanSearchCommitByMessage(_ query: String) -> Bool {
    query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
}

func searchEverywhereCommitItems(
    roots: [SearchEverywhereGitRoot],
    query: String
) -> [SearchEverywhereItem] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard searchEverywhereCanSearchCommitByMessage(normalizedQuery) else { return [] }

    var items: [SearchEverywhereItem] = []
    if searchEverywhereCanSearchCommitByHash(normalizedQuery) {
        for root in roots {
            guard let repository = try? openRepository(path: root.rootPath),
                  let commit = try? repository.commitInfo(commitId: normalizedQuery) else {
                continue
            }
            items.append(SearchEverywhereItem(
                kind: .commitByHash,
                rootPath: root.rootPath,
                revision: commit.id,
                title: commit.summary,
                subtitle: "\(root.displayName) · \(commit.authorName)",
                shortID: commit.shortId
            ))
        }
    }

    for root in roots {
        guard let repository = try? openRepository(path: root.rootPath),
              let commits = try? repository.logWithCommand(
                  commandArgs: [
                      "--all",
                      "--grep", normalizedQuery,
                      "--regexp-ignore-case",
                      "--fixed-strings",
                  ],
                  limit: 20
              ) else {
            continue
        }
        items.append(contentsOf: commits.map { commit in
            SearchEverywhereItem(
                kind: .commitByMessage,
                rootPath: root.rootPath,
                revision: commit.id,
                title: commit.summary,
                subtitle: "\(root.displayName) · \(commit.authorName)",
                shortID: commit.shortId
            )
        })
    }
    return items
}

/// Phase 5：Search Everywhere——对齐 IntelliJ Git contributor 的 refs、提交和动作搜索。
struct SearchEverywhereView: View {
    let roots: [SearchEverywhereGitRoot]
    @Binding var query: String
    let onSelect: (SearchEverywhereItem) -> Void
    let onCancel: () -> Void

    @State private var commitHits: [SearchEverywhereItem] = []
    @State private var isSearchingCommits = false
    @FocusState private var queryIsFocused: Bool

    private let actions: [(String, String)] = [
        ("update", "Update Project (⌘T)"),
        ("commit", "Commit… (⌘K)"),
        ("commitAndPush", "Commit and Push…"),
        ("push", "Push… (⌘⇧K)"),
        ("fetch", "Fetch"),
        ("fetchAll", "Fetch All"),
        ("fetchPrune", "Prune Remote Branches"),
        ("fetchUnshallow", "Fetch Full History…"),
        ("pullMerge", "Pull (Merge)"),
        ("pullRebase", "Pull (Rebase)"),
        ("branches", "Branches Popup"),
        ("merge", "Merge…"),
        ("rebase", "Rebase…"),
        ("stash", "Stash…"),
        ("shelve", "Shelve…"),
        ("newBranch", "New Branch…"),
        ("newTag", "New Tag…"),
    ]

    private var referenceHits: [SearchEverywhereItem] {
        searchEverywhereReferenceItems(roots: roots, query: query)
    }

    private var actionHits: [(String, String)] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return actions.filter {
            $0.1.lowercased().contains(normalizedQuery) || $0.0.contains(normalizedQuery)
        }
    }

    private var hasResults: Bool {
        !referenceHits.isEmpty || !commitHits.isEmpty || !actionHits.isEmpty
    }

    private var selectableItems: [SearchEverywhereItem] {
        groupedItems(commitHits, kind: .commitByHash)
            + groupedItems(referenceHits, kind: .localBranch)
            + groupedItems(referenceHits, kind: .remoteBranch)
            + groupedItems(referenceHits, kind: .tag)
            + groupedItems(commitHits, kind: .commitByMessage)
    }

    private var searchTaskID: String {
        var components = [query]
        for root in roots {
            components.append(root.rootPath)
            components.append(contentsOf: root.branches.map { "local:\($0.name):\($0.shortId)" })
            components.append(contentsOf: root.remoteBranches.map { "remote:\($0.name):\($0.shortId)" })
            components.append(contentsOf: root.tags.map { "tag:\($0.name):\($0.shortId)" })
        }
        return components.joined(separator: "\u{1f}")
    }

    private func groupedItems(
        _ items: [SearchEverywhereItem],
        kind: SearchEverywhereItemKind
    ) -> [SearchEverywhereItem] {
        items.filter { $0.kind == kind }
    }

    private func itemRow(_ item: SearchEverywhereItem) -> some View {
        Button {
            onSelect(item)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: item.kind.symbolName)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let shortID = item.shortID {
                    Text(shortID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func submitSelection() {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let item = selectableItems.first {
            onSelect(item)
        } else if let action = actionHits.first {
            NotificationCenter.default.post(name: .arborVCSAction, object: action.0)
            onCancel()
        }
    }

    private func section(_ title: String, items: [SearchEverywhereItem]) -> some View {
        Group {
            if !items.isEmpty {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                ForEach(items) { item in
                    itemRow(item)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search branches, commits, tags and actions", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($queryIsFocused)
                    .onSubmit { submitSelection() }
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    if normalizedQuery.isEmpty {
                        Text("输入以搜索分支、提交、Tag 或 Git 动作")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    } else {
                        section(
                            SearchEverywhereItemKind.commitByHash.sectionTitle,
                            items: groupedItems(commitHits, kind: .commitByHash)
                        )
                        section(
                            SearchEverywhereItemKind.localBranch.sectionTitle,
                            items: groupedItems(referenceHits, kind: .localBranch)
                        )
                        section(
                            SearchEverywhereItemKind.remoteBranch.sectionTitle,
                            items: groupedItems(referenceHits, kind: .remoteBranch)
                        )
                        section(
                            SearchEverywhereItemKind.tag.sectionTitle,
                            items: groupedItems(referenceHits, kind: .tag)
                        )
                        section(
                            SearchEverywhereItemKind.commitByMessage.sectionTitle,
                            items: groupedItems(commitHits, kind: .commitByMessage)
                        )
                        if isSearchingCommits {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Searching commits…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(8)
                        }
                        if !actionHits.isEmpty {
                            Text("ACTIONS")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.top, 4)
                            ForEach(actionHits, id: \.0) { item in
                                Button {
                                    NotificationCenter.default.post(name: .arborVCSAction, object: item.0)
                                    onCancel()
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "command")
                                            .foregroundStyle(.secondary)
                                            .font(.caption)
                                        Text(item.1)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if !hasResults && !isSearchingCommits {
                            Text("无匹配结果")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(8)
                        }
                    }
                }
            }
            HStack {
                Text("⌘O 动作 · 回车在 Log 中定位")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Close", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(12)
        .frame(width: 560, height: 500)
        .onExitCommand(perform: onCancel)
        .onAppear { queryIsFocused = true }
        .task(id: searchTaskID) {
            let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard searchEverywhereCanSearchCommitByMessage(normalizedQuery) else {
                commitHits = []
                isSearchingCommits = false
                return
            }
            isSearchingCommits = true
            let currentRoots = roots
            let hits = await Task.detached(priority: .userInitiated) {
                searchEverywhereCommitItems(roots: currentRoots, query: normalizedQuery)
            }.value
            guard !Task.isCancelled else { return }
            commitHits = hits
            isSearchingCommits = false
        }
    }
}


enum MultiRootRecoveryAction: Equatable {
    case continueOperation
    case skip
    case abort
}

/// 项目级冲突 resolver 的一个待处理 root。一个 root 可能来自 Git
/// operation、普通 unmerged files，或 Update Project stash 恢复冲突。
enum MultiRootConflictResolverKind {
    case operation(OperationKind)
    case workingTree
    case stash(stashID: String?, index: Int, isPop: Bool)
    case shelve(name: String, isPop: Bool)
}

struct MultiRootConflictResolverRoot: Identifiable {
    let rootPath: String
    let displayName: String
    let relativePath: String
    let paths: [String]
    let kind: MultiRootConflictResolverKind

    var id: String { rootPath }

    var operation: OperationKind? {
        guard case let .operation(kind) = kind else { return nil }
        return kind
    }

    var isStash: Bool {
        if case .stash = kind { return true }
        return false
    }

    var isShelf: Bool {
        if case .shelve = kind { return true }
        return false
    }

    var canSkip: Bool {
        operation == .rebase
    }
}

func stableMultiRootConflictResolverRoots(
    _ roots: [MultiRootConflictResolverRoot]
) -> [MultiRootConflictResolverRoot] {
    roots.sorted { $0.rootPath < $1.rootPath }
}

/// IntelliJ GitConflictResolver 的项目级 SwiftUI 外壳：左侧保持所有
/// Git root 的待处理队列，右侧复用当前 root 的三栏冲突编辑器。
struct MultiRootConflictResolverView: View {
    let roots: [MultiRootConflictResolverRoot]
    let activeRootPath: String?
    let activeRepo: Repository?
    @Binding var entries: [FileEntry]
    let initialPath: String?
    let activeKind: MultiRootConflictResolverKind?
    let isWorking: Bool
    let error: String?
    let onSelectRoot: (String) -> Void
    let onChanged: () -> Void
    let onComplete: () -> Void
    let onSkip: () -> Void
    let onAbort: () -> Void
    let onClose: () -> Void
    /// Compact mode is used by the non-modal project conflict panel.
    let compact: Bool

    private var activeMode: MergeRevisionsDialogView.Mode {
        switch activeKind {
        case .operation(.rebase): return .rebase
        case .operation(.cherryPick): return .cherryPick
        case .operation(.revert): return .revert
        case .operation(.merge): return .merge
        case .stash: return .stashRestore
        case .shelve(_, let isPop): return .shelveRestore(isPop: isPop)
        case .workingTree, nil: return .merge
        }
    }

    private var activeRoot: MultiRootConflictResolverRoot? {
        roots.first(where: { $0.rootPath == activeRootPath })
    }

    private var activeOperation: OperationKind? {
        activeRoot?.operation
    }

    private var allowsAbort: Bool {
        if activeOperation != nil { return true }
        if case .shelve = activeKind { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if !compact {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.merge")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Git Roots Conflicts")
                                .font(.headline)
                            Text("\(roots.count) root\(roots.count == 1 ? "" : "s") pending")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Close", action: onClose)
                            .controlSize(.small)
                    }
                    .padding(12)
                    Divider()
                }

                List {
                    ForEach(roots) { root in
                        Button {
                            onSelectRoot(root.rootPath)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Image(systemName: root.isStash || root.isShelf
                                          ? "archivebox.fill"
                                          : "exclamationmark.triangle.fill")
                                        .foregroundStyle(root.isStash || root.isShelf ? .purple : .orange)
                                    Text(root.displayName)
                                        .font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    if root.canSkip {
                                        Text("Skip")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text(root.relativePath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                HStack(spacing: 6) {
                                    Text(root.isStash
                                         ? "Stash restore"
                                         : root.isShelf
                                         ? "Shelf restore"
                                         : operationLabel(root.operation))
                                    Text("·")
                                    Text("\(root.paths.count) conflicted file\(root.paths.count == 1 ? "" : "s")")
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .listRowBackground(
                            root.rootPath == activeRootPath
                                ? Color.accentColor.opacity(0.16)
                                : Color.clear
                        )
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(width: compact ? 230 : 290)

            Divider()

            VStack(spacing: 0) {
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                if let activeRepo {
                    MergeRevisionsDialogView(
                        repo: activeRepo,
                        entries: $entries,
                        initialPath: initialPath,
                        mode: activeMode,
                        onChanged: onChanged,
                        onComplete: onComplete,
                        onAbort: allowsAbort ? onAbort : nil,
                        onSkip: activeOperation == .rebase ? onSkip : nil,
                        compact: compact
                    )
                    .disabled(isWorking)
                } else if isWorking {
                    ProgressView("Loading Git root…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.circle")
                            .font(.title)
                            .foregroundStyle(.green)
                        Text("All Git roots are resolved")
                            .font(.headline)
                        Button("Close", action: onClose)
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: compact ? 980 : 1420, minHeight: compact ? 620 : 760)
    }

    private func operationLabel(_ operation: OperationKind?) -> String {
        switch operation {
        case .merge: return "Merge"
        case .rebase: return "Rebase"
        case .cherryPick: return "Cherry-pick"
        case .revert: return "Revert"
        case nil: return "Unmerged files"
        }
    }
}

private struct MultiRootBranchRow: Identifiable {
    let id: String
    let name: String
    let isCurrent: Bool
    let sync: SyncStatus?
    let rootPath: String
    let isRemote: Bool
    let worktreePath: String?
}

/// IntelliJ Branches Popup 的多 root 展示：分支名称只在所属 Git root 内
/// 解释，避免不同仓库的同名分支被错误合并。
struct MultiRootBranchesPopover: View {
    var projectPath: String? = nil
    var protectedBranchPatterns: [String] = []
    let snapshots: [GitRootBranchSnapshot]
    var incomingBranches: Set<GitIncomingBranch> = []
    var operationContexts: [BranchPopupOperationContext] = []
    var onOperationAction: (String, BranchPopupOperationActionID) -> Void = { _, _ in }
    var onCommitChanges: () -> Void = {}
    var hasCommitChanges: Bool = false
    var onNewBranch: () -> Void = {}
    var onFindMerged: () -> Void = {}
    var onRemoteTags: () -> Void = {}
    let onCheckout: (String, String, Bool) -> Void
    var onCheckoutAsNewBranch: (String, String, Bool) -> Void = { _, _, _ in }
    let onCheckoutAndUpdate: (String, String, Bool, Bool) -> Void
    let onCheckoutWithRebase: (String, String, Bool) -> Void
    let onCheckoutRecent: (String, String) -> Void
    let onCheckoutTag: (String, String) -> Void
    let onDeleteTag: (String, String) -> Void
    var onDeleteTagAcrossRoots: (String) -> Void = { _ in }
    let onRenameTag: (String, String) -> Void
    let onPushTag: (String, String) -> Void
    var onPushTagToRemote: (String, String, String) -> Void = { _, _, _ in }
    var onShowDiffWithWorkingTree: (String, String) -> Void = { _, _ in }
    var onPushAllTags: (String, String) -> Void = { _, _ in }
    let onApplyStash: (String, String, Bool) -> Void
    let onPopStash: (String, String, Bool) -> Void
    let onDropStash: (String, String) -> Void
    let onStashBranch: (String, String) -> Void
    let onStashDiff: (String, String) -> Void
    let onStashClear: (String) -> Void
    let onUpdateBranch: (String, String) -> Void
    var onForcePushedUpdate: (String, String) -> Void = { _, _ in }
    var onForcePushedUpdateAcrossRoots: (String) -> Void = { _ in }
    let onPullBranch: (String, String, Bool) -> Void
    var onPullRemoteBranch: (String, String, Bool) -> Void = { _, _, _ in }
    let onDeleteRemote: (String, String) -> Void
    var onDeleteRemoteAcrossRoots: (String) -> Void = { _ in }
    let onMerge: (String, String) -> Void
    var onMergeAcrossRoots: (String) -> Void = { _ in }
    let onRebase: (String, String) -> Void
    let onCompare: (String, String) -> Void
    var onCompareSelected: ([BranchDashboardReference]) -> Void = { _ in }
    var onCompareSelectedFiles: ([BranchDashboardReference]) -> Void = { _ in }
    var onUpdateSelected: ([BranchDashboardReference]) -> Void = { _ in }
    var onDeleteSelected: ([BranchDashboardReference]) -> Void = { _ in }
    let onPushDialog: (String, String) -> Void
    var onEditRemote: (String, String) -> Void = { _, _ in }
    var onRemoveRemote: (String, String) -> Void = { _, _ in }
    var onRemoveRemoteSelected: ([BranchDashboardRemoteGroup]) -> Void = { _ in }
    var onConfigureRemotes: () -> Void = {}
    let onSetUpstream: (String, String) -> Void
    let onUnsetUpstream: (String, String) -> Void
    let onRenameBranch: (String, String) -> Void
    var onRenameBranchAcrossRoots: (String) -> Void = { _ in }
    var onDeleteBranchAcrossRoots: (String) -> Void = { _ in }
    let onDeleteBranch: (String, String) -> Void
    var onCheckoutReference: (String?) -> Void = { _ in }
    var onOpenWorktree: (String) -> Void = { _ in }
    var onCreateWorktreeFromReference: (String, String, Bool) -> Void = { _, _, _ in }
    var onProjectGitSettings: () -> Void = {}
    let onCancel: () -> Void

    @AppStorage(GitIncomingOutgoingInfoSettings.key)
    private var incomingOutgoingInfoEnabled = GitIncomingOutgoingInfoSettings.defaultValue
    @State private var query = ""
    @State private var repositoryFilter = ""
    @State private var repositoryScopeParentQuery: String?
    @State private var showRecentBranches = GitBranchesPopupSettings.defaultShowRecentBranches
    @State private var filterByAction = GitBranchesPopupSettings.defaultFilterByActionInPopup
    @State private var showTags = GitBranchesPopupSettings.defaultShowTags
    @State private var rootSyncChoice = GitRootSyncChoice.notDecided
    @State private var filterByRepository = GitBranchesPopupSettings.defaultFilterByRepository
    @State private var groupByRepository = GitBranchesPopupSettings.defaultGroupByRepository
    @State private var groupByDirectory = GitBranchesPopupSettings.defaultGroupByDirectory
    @State private var collapsedDirectoryGroups: Set<String> = []
    @State private var selectedBranchTargetID: String?
    @State private var selectedBranchTargetIDs: Set<String> = []
    @State private var branchSelectionAnchorID: String?
    @State private var selectedRemoteGroupIDs: Set<String> = []
    @State private var favoriteReferenceIDs: Set<String> = []

    private var allowsSynchronizedBranchActions: Bool {
        rootSyncChoice.shouldExecuteOperationsOnAllRoots
    }

    private var remoteGroups: [BranchDashboardRemoteGroup] {
        snapshots.flatMap { snapshot in
            let names = Set(snapshot.remotes.map(\.name) + snapshot.remoteBranches.map(\.remote))
            return names.map { name in
                BranchDashboardRemoteGroup(rootPath: snapshot.rootPath, name: name)
            }
        }
        .sorted {
            if $0.rootPath == $1.rootPath { return $0.name < $1.name }
            return $0.rootPath < $1.rootPath
        }
    }

    private var selectedRemoteGroups: [BranchDashboardRemoteGroup] {
        remoteGroups.filter { selectedRemoteGroupIDs.contains(remoteGroupTargetID(
            rootPath: $0.rootPath,
            name: $0.name
        )) }
    }

    private var selectableBranchReferences: [BranchDashboardReference] {
        snapshots.flatMap { snapshot in
            let head = BranchDashboardReference(
                rootPath: snapshot.rootPath,
                name: "HEAD",
                kind: .head,
                remote: nil,
                isCurrent: true,
                hasUpstream: false,
                hasTracking: false,
                hasRemote: false,
                isProtected: false,
                hasHeadCommit: snapshot.headId != nil,
                headBranchName: snapshot.headBranch
            )
            let local = snapshot.branches.map { branch in
                popupReference(
                    name: branch.name,
                    isCurrent: branch.isCurrent,
                    sync: snapshot.syncStatuses.first { $0.branch == branch.name },
                    rootPath: snapshot.rootPath,
                    isRemote: false,
                    hasHeadCommit: snapshot.headId != nil,
                    worktreePath: snapshot.worktrees.first {
                        $0.branch == branch.name && !$0.path.isEmpty
                    }?.path
                )
            }
            let remote = snapshot.remoteBranches.map { branch in
                popupReference(
                    name: branch.name,
                    isCurrent: false,
                    sync: snapshot.syncStatuses.first { $0.upstream == branch.name },
                    rootPath: snapshot.rootPath,
                    isRemote: true,
                    worktreePath: nil
                )
            }
            let tags = snapshot.tags.map { tag in
                BranchDashboardReference(
                    rootPath: snapshot.rootPath,
                    name: tag.name,
                    kind: .tag,
                    remote: nil,
                    isCurrent: tag.isCurrent,
                    hasUpstream: false,
                    hasTracking: false,
                    hasRemote: !snapshot.remotes.isEmpty || !snapshot.remoteBranches.isEmpty,
                    isProtected: false
                )
            }
            return [head] + local + remote + tags
        }
    }

    private var selectedBranchReferences: [BranchDashboardReference] {
        selectableBranchReferences.filter { reference in
            selectedBranchTargetIDs.contains(branchTargetID(for: reference))
        }
    }

    private var selectedBranchActionsEnabled: Bool {
        let selection = selectedBranchReferences
        return selection.count >= 2
            && !BranchDashboardActionAvailability.resolve(selection: selection).actions.isEmpty
    }

    private var canCreateNewBranch: Bool {
        !snapshots.isEmpty && snapshots.allSatisfy { $0.headId != nil }
    }

    private func popupSnapshot(_ snapshot: GitRootBranchSnapshot) -> GitRootBranchSnapshot {
        guard !showTags else { return snapshot }
        return GitRootBranchSnapshot(
            rootPath: snapshot.rootPath,
            displayName: snapshot.displayName,
            relativePath: snapshot.relativePath,
            headBranch: snapshot.headBranch,
            headId: snapshot.headId,
            branches: snapshot.branches,
            remoteBranches: snapshot.remoteBranches,
            remotes: snapshot.remotes,
            syncStatuses: snapshot.syncStatuses,
            recentBranches: snapshot.recentBranches,
            tags: [],
            stashes: snapshot.stashes,
            shelves: snapshot.shelves,
            worktrees: snapshot.worktrees
        )
    }

    private var filteredSnapshots: [GitRootBranchSnapshot] {
        let selectedSnapshots = snapshots.filter {
            !filterByRepository || repositoryFilter.isEmpty || $0.rootPath == repositoryFilter
        }.map(popupSnapshot)
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return selectedSnapshots }
        return selectedSnapshots.compactMap { snapshot in
            let repositoryMatches = filterByRepository
                && branchPopupRepositorySearchMatches(
                    displayName: snapshot.displayName,
                    relativePath: snapshot.relativePath,
                    query: query
                )
            let local = snapshot.branches.filter { branchSearchMatches($0.name, query: query) }
            let remote = snapshot.remoteBranches.filter { branchSearchMatches($0.name, query: query) }
            let remotes = snapshot.remotes.filter { branchSearchMatches($0.name, query: query) }
            let recent = snapshot.recentBranches.filter { branchSearchMatches($0, query: query) }
            let tags = snapshot.tags.filter { branchSearchMatches($0.name, query: query) }
            let stashes = snapshot.stashes.filter {
                branchSearchMatches($0.message, query: query)
                    || branchSearchMatches($0.shortId, query: query)
            }
            let shelves = snapshot.shelves.filter {
                branchSearchMatches($0.name, query: query)
                    || branchSearchMatches($0.shortId, query: query)
            }
            let headMatches = branchSearchMatches("HEAD", query: query)
                || snapshot.headBranch.map { branchSearchMatches($0, query: query) } == true
            let visibleRecent = showRecentBranches ? recent : []
            guard repositoryMatches || headMatches || !local.isEmpty || !remote.isEmpty || !remotes.isEmpty || !visibleRecent.isEmpty
                    || !tags.isEmpty || !stashes.isEmpty || !shelves.isEmpty else {
                return nil
            }
            if repositoryMatches {
                return popupSnapshot(snapshot)
            }
            return GitRootBranchSnapshot(
                rootPath: snapshot.rootPath,
                displayName: snapshot.displayName,
                relativePath: snapshot.relativePath,
                headBranch: snapshot.headBranch,
                headId: snapshot.headId,
                branches: local,
                remoteBranches: remote,
                remotes: remotes.isEmpty ? snapshot.remotes : remotes,
                syncStatuses: snapshot.syncStatuses,
                recentBranches: showRecentBranches
                    ? recent
                    : [],
                tags: tags,
                stashes: stashes,
                shelves: shelves,
                worktrees: snapshot.worktrees
            )
        }
    }

    private var filteredRepositoryTargets: [BranchTreeTarget] {
        guard filterByRepository,
              repositoryFilter.isEmpty,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        return snapshots
            .filter {
                branchPopupRepositorySearchMatches(
                    displayName: $0.displayName,
                    relativePath: $0.relativePath,
                    query: query
                )
            }
            .sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
            .map { snapshot in
                let path = snapshot.relativePath.isEmpty ? snapshot.rootPath : snapshot.relativePath
                return BranchTreeTarget(
                    id: "multi.repository:\(snapshot.rootPath)",
                    value: "\(snapshot.displayName) \(path)",
                    title: snapshot.displayName,
                    kind: .repository,
                    rootPath: snapshot.rootPath
                )
            }
    }

    private var filteredActionTargets: [BranchTreeTarget] {
        branchPopupVisibleActions(
            query: query,
            filterByAction: filterByAction
        ).map { action in
            BranchTreeTarget(
                id: "multi.action:\(action.rawValue)",
                value: action.rawValue,
                title: action.title,
                kind: .action,
                isEnabled: isBranchPopupActionEnabled(
                    action,
                    hasHeadCommit: canCreateNewBranch,
                    hasCommitChanges: hasCommitChanges
                )
            )
        }
    }

    private var filteredOperationActionTargets: [BranchTreeTarget] {
        return operationContexts.flatMap { context in
            let repositoryLabel = context.relativePath.isEmpty
                ? context.displayName
                : "\(context.displayName) · \(context.relativePath)"
            return branchPopupOperationActions(for: context.kind, hasConflicts: context.hasConflicts)
                .filter {
                    !filterByAction
                        || branchSearchMatches("\($0.title) \(repositoryLabel)", query: query)
                }
                .map { action in
                    BranchTreeTarget(
                        id: "multi.operation:\(context.rootPath):\(action.rawValue)",
                        value: action.rawValue,
                        title: "\(action.title) — \(repositoryLabel)",
                        kind: .action,
                        rootPath: context.rootPath,
                        isEnabled: true
                    )
                }
        }
    }

    private var flatBranchRows: [MultiRootBranchRow] {
        filteredSnapshots.flatMap { snapshot in
            let localRows = snapshot.branches.map { branch in
                MultiRootBranchRow(
                    id: "\(snapshot.rootPath)::local::\(branch.name)",
                    name: branch.name,
                    isCurrent: branch.isCurrent,
                    sync: snapshot.syncStatuses.first { $0.branch == branch.name },
                    rootPath: snapshot.rootPath,
                    isRemote: false,
                    worktreePath: snapshot.worktrees.first { $0.branch == branch.name && !$0.path.isEmpty }?.path
                )
            }
            let remoteRows = snapshot.remoteBranches.map { branch in
                MultiRootBranchRow(
                    id: "\(snapshot.rootPath)::remote::\(branch.name)",
                    name: branch.name,
                    isCurrent: false,
                    sync: snapshot.syncStatuses.first { $0.upstream == branch.name },
                    rootPath: snapshot.rootPath,
                    isRemote: true,
                    worktreePath: nil
                )
            }
            return localRows + remoteRows
        }
    }

    private var keyboardTargets: [BranchTreeTarget] {
        let rootTargets = filteredSnapshots.flatMap { snapshot in
            branchTargets(for: snapshot, includeExtras: true)
        }
        let repositoryTargets = filteredRepositoryTargets
        guard groupByRepository || groupByDirectory else {
            let branchOnlyTargets = filteredSnapshots.flatMap { snapshot in
                branchTargets(for: snapshot, includeExtras: false)
            }
            let extraTargets = filteredSnapshots.flatMap { snapshot in
                branchTargets(for: snapshot, includeBranches: false, includeExtras: true)
            }
            let references = repositoryTargets + branchOnlyTargets + extraTargets
            let actionTargets = filterByAction
                ? (filteredOperationActionTargets + filteredActionTargets).filter(\.isEnabled)
                : []
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return references + actionTargets
            }
            return actionTargets + references
        }
        let actionTargets = filterByAction
            ? (filteredOperationActionTargets + filteredActionTargets).filter(\.isEnabled)
            : []
        let references = repositoryTargets + rootTargets
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return references + actionTargets
        }
        return actionTargets + references
    }

    private var visibleBranchSelectionIDs: [String] {
        keyboardTargets.compactMap { target in
            guard target.kind == .head
                    || target.kind == .local
                    || target.kind == .remote
                    || target.kind == .tag else {
                return nil
            }
            return target.id
        }
    }

    private func branchTargets(
        for snapshot: GitRootBranchSnapshot,
        includeBranches: Bool = true,
        includeExtras: Bool
    ) -> [BranchTreeTarget] {
        let head = includeBranches
            ? [BranchTreeTarget(
                id: multiTargetID(rootPath: snapshot.rootPath, kind: .head, value: "HEAD"),
                value: "HEAD",
                title: "HEAD",
                kind: .head,
                rootPath: snapshot.rootPath
            )]
            : []
        let local = includeBranches
            ? visibleBranchDirectoryRefNames(
                snapshot.branches.map(\.name),
                grouped: groupByDirectory,
                scope: "\(snapshot.rootPath).local",
                collapsedGroups: collapsedDirectoryGroups
            ).map {
                BranchTreeTarget(
                    id: multiTargetID(rootPath: snapshot.rootPath, kind: .local, value: $0),
                    value: $0,
                    title: $0,
                    kind: .local,
                    rootPath: snapshot.rootPath
                )
            }
            : []
        let remote = includeBranches
            ? visibleBranchDirectoryRefNames(
                snapshot.remoteBranches.map(\.name),
                grouped: groupByDirectory,
                scope: "\(snapshot.rootPath).remote",
                collapsedGroups: collapsedDirectoryGroups
            ).map {
                BranchTreeTarget(
                    id: multiTargetID(rootPath: snapshot.rootPath, kind: .remote, value: $0),
                    value: $0,
                    title: $0,
                    kind: .remote,
                    rootPath: snapshot.rootPath
                )
            }
            : []
        let remoteGroups = includeBranches
            ? remoteGroupNames(snapshot).map { name in
                BranchTreeTarget(
                    id: remoteGroupTargetID(rootPath: snapshot.rootPath, name: name),
                    value: name,
                    title: name,
                    kind: .remoteGroup,
                    rootPath: snapshot.rootPath
                )
            }
            : []
        guard includeExtras else { return head + local + remoteGroups + remote }
        let recent = showRecentBranches
            ? visibleBranchDirectoryRefNames(
                snapshot.recentBranches,
                grouped: groupByDirectory,
                scope: "\(snapshot.rootPath).recent",
                collapsedGroups: collapsedDirectoryGroups
            ).map {
                BranchTreeTarget(
                    id: multiTargetID(rootPath: snapshot.rootPath, kind: .recent, value: $0),
                    value: $0,
                    title: $0,
                    kind: .recent,
                    rootPath: snapshot.rootPath
                )
            }
            : []
        let tags = showTags ? visibleBranchDirectoryRefNames(
            snapshot.tags.map(\.name),
            grouped: groupByDirectory,
            scope: "\(snapshot.rootPath).tags",
            collapsedGroups: collapsedDirectoryGroups
        ).map {
            BranchTreeTarget(
                id: multiTargetID(rootPath: snapshot.rootPath, kind: .tag, value: $0),
                value: $0,
                title: $0,
                kind: .tag,
                rootPath: snapshot.rootPath
            )
        } : []
        return head + local + remoteGroups + remote + recent + tags
    }

    private func multiTargetID(
        rootPath: String,
        kind: BranchTreeTargetKind,
        value: String
    ) -> String {
        let kindValue: String
        switch kind {
        case .action: kindValue = "action"
        case .repository: kindValue = "repository"
        case .head: kindValue = "head"
        case .recent: kindValue = "recent"
        case .local: kindValue = "local"
        case .remote: kindValue = "remote"
        case .remoteGroup: kindValue = "remote-group"
        case .tag: kindValue = "tag"
        }
        return "multi:\(rootPath):\(kindValue):\(value)"
    }

    private func remoteGroupTargetID(rootPath: String, name: String) -> String {
        multiTargetID(rootPath: rootPath, kind: .remoteGroup, value: name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Branches", systemImage: "arrow.triangle.branch")
                    .font(.headline)
                if let snapshot = repositoryScopedSnapshot {
                    Text("in \(snapshot.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text("\(filteredSnapshots.count) repositories")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 8) {
                filterField
                if let snapshot = repositoryScopedSnapshot {
                    Button {
                        leaveRepositoryScope()
                    } label: {
                        Label("All Repositories", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Return to all repositories")
                    Text(snapshot.relativePath.isEmpty ? snapshot.displayName : snapshot.relativePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Menu {
                    Toggle("Show Recent Branches", isOn: $showRecentBranches)
                    Toggle("Actions", isOn: $filterByAction)
                    Toggle("Show Tags", isOn: $showTags)
                    Toggle("Filter by Repository", isOn: $filterByRepository)
                    Toggle("Group by repository", isOn: $groupByRepository)
                    Toggle("Group by Directory", isOn: $groupByDirectory)
                    Divider()
                    Picker("Cross-root action scope", selection: $rootSyncChoice) {
                        ForEach(GitRootSyncChoice.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton)
                .help("Branches Popup Settings")
            }
            HStack {
                Button("Commit Changes…") {
                    onCommitChanges()
                    onCancel()
                }
                .controlSize(.small)
                .disabled(!hasCommitChanges)
                .help(
                    branchPopupActionDisabledDescription(
                        .commitChanges,
                        hasHeadCommit: canCreateNewBranch,
                        hasCommitChanges: hasCommitChanges
                    ) ?? ""
                )
                Button("New Branch…", action: onNewBranch)
                    .controlSize(.small)
                    .disabled(!canCreateNewBranch)
                    .help(
                        branchPopupActionDisabledDescription(
                            .newBranch,
                            hasHeadCommit: canCreateNewBranch
                        ) ?? ""
                    )
                Button("Find Merged…") {
                    onFindMerged()
                    onCancel()
                }
                .controlSize(.small)
                .disabled(!isFindMergedBranchesActionEnabled(localBranchCounts: snapshots.map { $0.branches.count }))
                Button("Remote Tags…") {
                    onRemoteTags()
                    onCancel()
                }
                .controlSize(.small)
                Menu("Actions…") {
                    selectedBranchActionMenu(for: selectedBranchReferences)
                }
                .controlSize(.small)
                .disabled(!selectedBranchActionsEnabled)
                Menu("Remote Actions…") {
                    remoteGroupActionMenu(for: selectedRemoteGroups)
                }
                .controlSize(.small)
                .disabled(selectedRemoteGroups.isEmpty)
                Button("Configure Remotes…", action: onConfigureRemotes)
                    .controlSize(.small)
                Button {
                    onCheckoutReference(filterByRepository && !repositoryFilter.isEmpty ? repositoryFilter : nil)
                } label: {
                    Label("Checkout Tag or Revision…", systemImage: "arrow.down.to.line")
                }
                .controlSize(.small)
                Button(action: { onProjectGitSettings(); onCancel() }) {
                    Label("Project Git Settings…", systemImage: "slider.horizontal.3")
                }
                .controlSize(.small)
                Spacer()
                Text("Enter branch, tag, or commit")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Divider()
            if filteredSnapshots.isEmpty && filteredActionTargets.isEmpty
                    && filteredOperationActionTargets.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if !filteredOperationActionTargets.isEmpty {
                            Text("ONGOING OPERATIONS")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                            ForEach(filteredOperationActionTargets) { target in
                                Button {
                                    selectedBranchTargetID = target.id
                                    if let action = BranchPopupOperationActionID(rawValue: target.value),
                                       let rootPath = target.rootPath {
                                        onOperationAction(rootPath, action)
                                        onCancel()
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(
                                            systemName: BranchPopupOperationActionID(rawValue: target.value)?.systemImage
                                                ?? "bolt"
                                        )
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                        .frame(width: 16)
                                        Text(target.title)
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                }
                                .buttonStyle(.plain)
                                .disabled(!target.isEnabled)
                                .background(
                                    selectedBranchTargetID == target.id
                                        ? Color.accentColor.opacity(0.22)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5)
                                )
                            }
                        }
                        if !filteredActionTargets.isEmpty {
                            Text("ACTIONS")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                            ForEach(filteredActionTargets) { target in
                                Button {
                                    selectedBranchTargetID = target.id
                                    if let action = BranchPopupActionID(rawValue: target.value) {
                                        activateAction(action)
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: BranchPopupActionID(rawValue: target.value)?.systemImage ?? "bolt")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 16)
                                        Text(target.title)
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                }
                                .buttonStyle(.plain)
                                .disabled(!target.isEnabled)
                                .help(
                                    BranchPopupActionID(rawValue: target.value).flatMap {
                                        branchPopupActionDisabledDescription(
                                            $0,
                                            hasHeadCommit: canCreateNewBranch,
                                            hasCommitChanges: hasCommitChanges
                                        )
                                    } ?? ""
                                )
                                .background(
                                    selectedBranchTargetID == target.id
                                        ? Color.accentColor.opacity(0.22)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5)
                                )
                            }
                        }
                        if !filteredRepositoryTargets.isEmpty {
                            Text("REPOSITORIES")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                            ForEach(filteredRepositoryTargets) { target in
                                Button {
                                    selectRepositoryTarget(target)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "folder").font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 16)
                                        Text(target.title).lineLimit(1)
                                        if let rootPath = target.rootPath,
                                           let snapshot = snapshots.first(where: { $0.rootPath == rootPath }),
                                           !snapshot.relativePath.isEmpty {
                                            Text(snapshot.relativePath)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                }
                                .buttonStyle(.plain)
                                .background(
                                    selectedBranchTargetID == target.id
                                        ? Color.accentColor.opacity(0.22)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5)
                                )
                            }
                        }
                        if !filteredSnapshots.isEmpty {
                            if groupByRepository {
                                ForEach(filteredSnapshots, id: \.rootPath) { snapshot in
                                    rootSection(snapshot)
                                }
                            } else if groupByDirectory {
                                ForEach(filteredSnapshots, id: \.rootPath) { snapshot in
                                    rootSection(snapshot, compact: true)
                                }
                            } else {
                                ForEach(filteredSnapshots, id: \.rootPath) { snapshot in
                                    headRow(snapshot)
                                }
                                ForEach(flatBranchRows) { row in
                                    branchRow(
                                        row.name,
                                        isCurrent: row.isCurrent,
                                        sync: row.sync,
                                        rootPath: row.rootPath,
                                        isRemote: row.isRemote,
                                        worktreePath: row.worktreePath,
                                        selected: selectedBranchTargetIDs.contains(multiTargetID(
                                            rootPath: row.rootPath,
                                            kind: row.isRemote ? .remote : .local,
                                            value: row.name
                                        ))
                                    )
                                }
                                ForEach(filteredSnapshots, id: \.rootPath) { snapshot in
                                    extraSection(snapshot)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(12)
        .frame(width: 700, height: 560)
        .onExitCommand(perform: handleExitCommand)
        .onAppear {
            favoriteReferenceIDs = GitBranchesPopupSettings.favorites(for: projectPath)
            rootSyncChoice = GitRootSyncSettings.choice(for: projectPath)
            selectedBranchTargetID = bestBranchTreeTargetID(
                query: query,
                targets: keyboardTargets,
                preserving: selectedBranchTargetID
            )
            showRecentBranches = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.showRecentBranchesKey,
                for: projectPath
            )
            filterByAction = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.filterByActionInPopupKey,
                for: projectPath
            )
            showTags = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.showTagsKey,
                for: projectPath
            )
            filterByRepository = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.filterByRepositoryKey,
                for: projectPath
            )
            groupByRepository = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.groupByRepositoryKey,
                for: projectPath
            )
            groupByDirectory = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.groupByDirectoryKey,
                for: projectPath
            )
            collapsedDirectoryGroups = GitBranchesPopupSettings.collapsedDirectoryGroups(
                for: projectPath
            )
        }
        .onChange(of: showRecentBranches) { _, value in
            GitBranchesPopupSettings.save(
                value,
                GitBranchesPopupSettings.showRecentBranchesKey,
                for: projectPath
            )
        }
        .onChange(of: rootSyncChoice) { _, value in
            GitRootSyncSettings.save(value, for: projectPath)
        }
        .onChange(of: filterByAction) { _, value in
            GitBranchesPopupSettings.save(
                value,
                GitBranchesPopupSettings.filterByActionInPopupKey,
                for: projectPath
            )
            selectedBranchTargetID = bestBranchTreeTargetID(
                query: query,
                targets: keyboardTargets,
                preserving: selectedBranchTargetID
            )
        }
        .onChange(of: showTags) { _, value in
            GitBranchesPopupSettings.save(
                value,
                GitBranchesPopupSettings.showTagsKey,
                for: projectPath
            )
            selectedBranchTargetID = bestBranchTreeTargetID(
                query: query,
                targets: keyboardTargets,
                preserving: selectedBranchTargetID
            )
        }
        .onChange(of: filterByRepository) { _, value in
            GitBranchesPopupSettings.save(
                value,
                GitBranchesPopupSettings.filterByRepositoryKey,
                for: projectPath
            )
            if !value {
                leaveRepositoryScope()
            }
            reconcileBranchSelection(with: filteredSnapshots)
        }
        .onChange(of: repositoryFilter) { _, _ in
            selectedBranchTargetID = bestBranchTreeTargetID(
                query: query,
                targets: keyboardTargets,
                preserving: selectedBranchTargetID
            )
            reconcileBranchSelection(with: filteredSnapshots)
        }
        .onChange(of: groupByRepository) { _, value in
            GitBranchesPopupSettings.save(
                value,
                GitBranchesPopupSettings.groupByRepositoryKey,
                for: projectPath
            )
        }
        .onChange(of: groupByDirectory) { _, value in
            GitBranchesPopupSettings.save(
                value,
                GitBranchesPopupSettings.groupByDirectoryKey,
                for: projectPath
            )
        }
        .onChange(of: collapsedDirectoryGroups) { _, value in
            GitBranchesPopupSettings.saveCollapsedDirectoryGroups(
                value,
                for: projectPath
            )
        }
        .onChange(of: query) { _, _ in
            selectedBranchTargetID = bestBranchTreeTargetID(
                query: query,
                targets: keyboardTargets,
                preserving: selectedBranchTargetID
            )
            let visibleRemoteGroupIDs = Set(filteredSnapshots.flatMap { snapshot in
                remoteGroupNames(snapshot).map {
                    remoteGroupTargetID(rootPath: snapshot.rootPath, name: $0)
                }
            })
            selectedRemoteGroupIDs.formIntersection(visibleRemoteGroupIDs)
            reconcileBranchSelection(with: filteredSnapshots)
        }
        .onChange(of: snapshots) { _, newSnapshots in
            if filterByRepository,
               !repositoryFilter.isEmpty,
               !newSnapshots.contains(where: { $0.rootPath == repositoryFilter })
            {
                leaveRepositoryScope()
            }
            let validRemoteGroupIDs = Set(newSnapshots.flatMap { snapshot in
                remoteGroupNames(snapshot).map {
                    remoteGroupTargetID(rootPath: snapshot.rootPath, name: $0)
                }
            })
            selectedRemoteGroupIDs.formIntersection(validRemoteGroupIDs)
            reconcileBranchSelection(with: filteredSnapshots)
        }
    }

    private var filterField: some View {
        TextField("Filter branches", text: $query)
            .textFieldStyle(.roundedBorder)
            .onSubmit { activateSelectedBranch() }
            .onKeyPress(.downArrow, action: handleDownKeyPress)
            .onKeyPress(.upArrow, action: handleUpKeyPress)
    }

    private func moveSelectedBranch(by offset: Int) {
        let nextID = movedBranchTreeSelection(
            currentID: selectedBranchTargetID,
            selectableIDs: keyboardTargets.map(\.id),
            offset: offset
        )
        selectedBranchTargetID = nextID
        selectedRemoteGroupIDs = []
        if let nextID,
           let kind = keyboardTargets.first(where: { $0.id == nextID })?.kind,
           kind == .head || kind == .local || kind == .remote || kind == .tag {
            selectedBranchTargetIDs = [nextID]
            branchSelectionAnchorID = nextID
        } else {
            selectedBranchTargetIDs = []
            branchSelectionAnchorID = nil
        }
    }

    private func handleDownKeyPress() -> KeyPress.Result {
        moveSelectedBranch(by: 1)
        return .handled
    }

    private func handleUpKeyPress() -> KeyPress.Result {
        moveSelectedBranch(by: -1)
        return .handled
    }

    private var repositoryScopedSnapshot: GitRootBranchSnapshot? {
        guard !repositoryFilter.isEmpty else { return nil }
        return snapshots.first(where: { $0.rootPath == repositoryFilter })
    }

    private func enterRepositoryScope(_ rootPath: String) {
        guard filterByRepository,
              snapshots.contains(where: { $0.rootPath == rootPath }) else { return }
        if repositoryFilter.isEmpty {
            repositoryScopeParentQuery = query
        }
        repositoryFilter = rootPath
        query = ""
        selectedBranchTargetIDs = []
        branchSelectionAnchorID = nil
    }

    private func leaveRepositoryScope() {
        guard !repositoryFilter.isEmpty else { return }
        repositoryFilter = ""
        query = repositoryScopeParentQuery ?? ""
        repositoryScopeParentQuery = nil
        selectedBranchTargetIDs = []
        branchSelectionAnchorID = nil
        selectedBranchTargetID = nil
    }

    private func handleExitCommand() {
        switch branchPopupExitDestination(repositoryFilter: repositoryFilter) {
        case .repositoryList:
            leaveRepositoryScope()
        case .dismiss:
            onCancel()
        }
    }

    private func activateSelectedBranch() {
        guard let selectedBranchTargetID,
              let target = keyboardTargets.first(where: { $0.id == selectedBranchTargetID }) else { return }
        if target.kind == .remoteGroup {
            selectRemoteGroupTarget(id: target.id)
            return
        }
        if target.kind == .action {
            if let action = BranchPopupOperationActionID(rawValue: target.value),
               let rootPath = target.rootPath {
                onOperationAction(rootPath, action)
                onCancel()
            } else if let action = BranchPopupActionID(rawValue: target.value) {
                activateAction(action)
            }
            return
        }
        guard let rootPath = target.rootPath else { return }
        switch target.kind {
        case .head:
            return
        case .action:
            return
        case .repository:
            selectRepositoryTarget(target)
        case .local:
            onCheckout(rootPath, target.value, false)
        case .remote:
            onCheckout(rootPath, target.value, true)
        case .remoteGroup:
            return
        case .recent:
            onCheckoutRecent(rootPath, target.value)
        case .tag:
            onCheckoutTag(rootPath, target.value)
        }
    }

    private func selectRepositoryTarget(_ target: BranchTreeTarget) {
        guard target.kind == .repository,
              let rootPath = target.rootPath else { return }
        selectedBranchTargetID = target.id
        enterRepositoryScope(rootPath)
    }

    private func activateAction(_ action: BranchPopupActionID) {
        switch action {
        case .commitChanges:
            onCommitChanges()
        case .newBranch:
            onNewBranch()
        case .checkoutReference:
            onCheckoutReference(
                filterByRepository && !repositoryFilter.isEmpty ? repositoryFilter : nil
            )
        }
    }

    @ViewBuilder
    private func rootSection(_ snapshot: GitRootBranchSnapshot, compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !compact {
                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.displayName)
                        .font(.system(size: 12, weight: .semibold))
                    Text(snapshot.relativePath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }
            headRow(snapshot)
            ForEach(visibleBranchDirectoryRows(
                branchDirectoryRows(
                    for: snapshot.branches.map(\.name),
                    grouped: groupByDirectory,
                    scope: "\(snapshot.rootPath).local"
                ),
                collapsedGroups: collapsedDirectoryGroups
            )) { row in
                if row.isGroup {
                    directoryGroupRow(row)
                } else if let refName = branchDirectoryRefName(row),
                          let branch = snapshot.branches.first(where: { $0.name == refName }) {
                    branchRow(
                        row.name,
                        isCurrent: branch.isCurrent,
                        sync: snapshot.syncStatuses.first { $0.branch == branch.name },
                        rootPath: snapshot.rootPath,
                        isRemote: false,
                        hasHeadCommit: snapshot.headId != nil,
                        worktreePath: snapshot.worktrees.first { $0.branch == branch.name && !$0.path.isEmpty }?.path,
                        depth: row.depth,
                        selected: selectedBranchTargetIDs.contains(multiTargetID(
                            rootPath: snapshot.rootPath,
                            kind: .local,
                            value: branch.name
                        ))
                    )
                }
            }
            remoteSection(snapshot)
            extraSection(snapshot)
        }
        .padding(.bottom, 4)
    }

    private func headRow(_ snapshot: GitRootBranchSnapshot) -> some View {
        let targetID = multiTargetID(
            rootPath: snapshot.rootPath,
            kind: .head,
            value: "HEAD"
        )
        let reference = BranchDashboardReference(
            rootPath: snapshot.rootPath,
            name: "HEAD",
            kind: .head,
            remote: nil,
            isCurrent: true,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false,
            hasHeadCommit: snapshot.headId != nil,
            headBranchName: snapshot.headBranch
        )
        let availability = BranchDashboardActionAvailability.resolve(selection: [reference])
        return HStack(spacing: 7) {
            Image(systemName: "arrow.uturn.backward.circle")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text("HEAD")
                .lineLimit(1)
            if snapshots.count > 1 {
                Text(snapshot.relativePath == "." ? snapshot.displayName : snapshot.relativePath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(snapshot.headBranch ?? "detached")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Menu {
                Button("New Branch from HEAD…") {
                    onCheckoutAsNewBranch(snapshot.rootPath, "HEAD", false)
                }
                .disabled(!availability.isEnabled(.checkoutAsNewBranch))
                if let headBranch = snapshot.headBranch,
                   availability.contains(.createWorktree) {
                    Button("New Working Tree from Current Branch…") {
                        onCreateWorktreeFromReference(snapshot.rootPath, headBranch, false)
                    }
                    .disabled(!availability.isEnabled(.createWorktree))
                }
                if availability.contains(.showDiffWithWorkingTree) {
                    Button("Show Diff with Working Tree") {
                        onShowDiffWithWorkingTree(snapshot.rootPath, "HEAD")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            selectBranchTarget(id: targetID)
        }
        .background(
            selectedBranchTargetIDs.contains(targetID)
                ? Color.accentColor.opacity(0.22)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
    }

    @ViewBuilder
    private func remoteSection(_ snapshot: GitRootBranchSnapshot) -> some View {
        HStack(spacing: 6) {
            Text("REMOTE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Configure…", action: onConfigureRemotes)
                .font(.caption)
                .controlSize(.small)
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)

        ForEach(remoteGroupNames(snapshot), id: \.self) { remoteName in
            remoteGroupRow(
                rootPath: snapshot.rootPath,
                name: remoteName,
                branchCount: snapshot.remoteBranches.filter { $0.remote == remoteName }.count
            )
            ForEach(visibleBranchDirectoryRows(
                branchDirectoryRows(
                    for: snapshot.remoteBranches
                        .filter { $0.remote == remoteName }
                        .map(\.name),
                    grouped: groupByDirectory,
                    scope: "\(snapshot.rootPath).remote.\(remoteName)"
                ),
                collapsedGroups: collapsedDirectoryGroups
            )) { row in
                if row.isGroup {
                    directoryGroupRow(row)
                } else if let refName = branchDirectoryRefName(row),
                          let branch = snapshot.remoteBranches.first(where: { $0.name == refName }) {
                    branchRow(
                        row.name,
                        isCurrent: false,
                        sync: snapshot.syncStatuses.first { $0.upstream == branch.name },
                        rootPath: snapshot.rootPath,
                        isRemote: true,
                        worktreePath: nil,
                        depth: row.depth,
                        selected: selectedBranchTargetIDs.contains(multiTargetID(
                            rootPath: snapshot.rootPath,
                            kind: .remote,
                            value: branch.name
                        ))
                    )
                }
            }
        }
    }

    private func remoteGroupNames(_ snapshot: GitRootBranchSnapshot) -> [String] {
        var names = snapshot.remotes.map(\.name)
        for remote in snapshot.remoteBranches.map(\.remote) where !names.contains(remote) {
            names.append(remote)
        }
        return names.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private func branchFavoriteID(rootPath: String, name: String, isRemote: Bool) -> String {
        BranchDashboardReference.referenceID(
            rootPath: rootPath,
            name: name,
            kind: isRemote ? .remote : .local
        )
    }

    private func branchTargetID(for reference: BranchDashboardReference) -> String {
        let kind: BranchTreeTargetKind
        switch reference.kind {
        case .head: kind = .head
        case .local: kind = .local
        case .remote: kind = .remote
        case .tag: kind = .tag
        }
        return multiTargetID(
            rootPath: reference.rootPath,
            kind: kind,
            value: reference.name
        )
    }

    private func branchTargetIDs(in snapshots: [GitRootBranchSnapshot]) -> Set<String> {
        Set(snapshots.flatMap { snapshot in
            let head = multiTargetID(rootPath: snapshot.rootPath, kind: .head, value: "HEAD")
            let local = snapshot.branches.map {
                multiTargetID(rootPath: snapshot.rootPath, kind: .local, value: $0.name)
            }
            let remote = snapshot.remoteBranches.map {
                multiTargetID(rootPath: snapshot.rootPath, kind: .remote, value: $0.name)
            }
            let tags = snapshot.tags.map {
                multiTargetID(rootPath: snapshot.rootPath, kind: .tag, value: $0.name)
            }
            return [head] + local + remote + tags
        })
    }

    private func reconcileBranchSelection(with snapshots: [GitRootBranchSnapshot]) {
        let validIDs = branchTargetIDs(in: snapshots)
        selectedBranchTargetIDs.formIntersection(validIDs)
        if selectedBranchTargetIDs.isEmpty,
           let selectedBranchTargetID,
           validIDs.contains(selectedBranchTargetID) {
            selectedBranchTargetIDs = [selectedBranchTargetID]
        }
        let visibleIDs = Set(visibleBranchSelectionIDs)
        if let branchSelectionAnchorID,
           !visibleIDs.contains(branchSelectionAnchorID) {
            self.branchSelectionAnchorID = nil
        }
        if self.branchSelectionAnchorID == nil,
           let selectedBranchTargetID,
           visibleIDs.contains(selectedBranchTargetID) {
            self.branchSelectionAnchorID = selectedBranchTargetID
        }
    }

    @ViewBuilder
    private func selectedBranchActionMenu(for selection: [BranchDashboardReference]) -> some View {
        let availability = BranchDashboardActionAvailability.resolve(selection: selection)
        if availability.contains(.compareSelected) {
            Button("Compare Branches…") {
                onCompareSelected(selection)
                onCancel()
            }
            .disabled(!availability.isEnabled(.compareSelected))
        }
        if availability.contains(.compareSelectedFiles) {
            Button("Compare Files…") {
                onCompareSelectedFiles(selection)
                onCancel()
            }
            .disabled(!availability.isEnabled(.compareSelectedFiles))
        }
        if availability.contains(.updateSelected) {
            Divider()
            Button("Update Selected Branches") {
                onUpdateSelected(selection)
                onCancel()
            }
            .disabled(!availability.isEnabled(.updateSelected))
            .help(availability.disabledDescription(for: .updateSelected) ?? "")
        }
        if availability.contains(.deleteSelected) {
            Divider()
            Button("Delete Selected", role: .destructive) {
                onDeleteSelected(selection)
                onCancel()
            }
            .disabled(!availability.isEnabled(.deleteSelected))
        }
    }

    private func favoriteTitle(rootPath: String, name: String, isRemote: Bool) -> String {
        favoriteReferenceIDs.contains(
            branchFavoriteID(rootPath: rootPath, name: name, isRemote: isRemote)
        ) ? "Unmark As Favorite" : "Mark As Favorite"
    }

    private func toggleFavorite(rootPath: String, name: String, isRemote: Bool) {
        let id = branchFavoriteID(rootPath: rootPath, name: name, isRemote: isRemote)
        if favoriteReferenceIDs.contains(id) {
            favoriteReferenceIDs.remove(id)
        } else {
            favoriteReferenceIDs.insert(id)
        }
        GitBranchesPopupSettings.saveFavorites(favoriteReferenceIDs, for: projectPath)
    }

    @ViewBuilder
    private func extraSection(_ snapshot: GitRootBranchSnapshot) -> some View {
        if showRecentBranches && !snapshot.recentBranches.isEmpty {
            Text("RECENT")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.top, 6)
            ForEach(visibleBranchDirectoryRows(
                branchDirectoryRows(
                    for: snapshot.recentBranches,
                    grouped: groupByDirectory,
                    scope: "\(snapshot.rootPath).recent"
                ),
                collapsedGroups: collapsedDirectoryGroups
            )) { row in
                if row.isGroup {
                    directoryGroupRow(row)
                    } else if let refName = branchDirectoryRefName(row) {
                        Button {
                            selectedRemoteGroupIDs = []
                            selectedBranchTargetID = multiTargetID(
                                rootPath: snapshot.rootPath,
                                kind: .recent,
                                value: refName
                            )
                            onCheckoutRecent(snapshot.rootPath, refName)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "clock")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(row.name)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.leading, CGFloat(row.depth) * 14)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    .background(
                        selectedBranchTargetID == multiTargetID(
                            rootPath: snapshot.rootPath,
                            kind: .recent,
                            value: refName
                        ) ? Color.accentColor.opacity(0.22) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                }
            }
        }
        if !snapshot.tags.isEmpty {
            HStack {
                Text("TAGS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                let tagRemotes = snapshot.remotes.map(\.name)
                if tagRemotes.count == 1 {
                    Button("Push All Tags") {
                        onPushAllTags(snapshot.rootPath, tagRemotes[0])
                    }
                    .font(.caption)
                    .controlSize(.small)
                } else if tagRemotes.count > 1 {
                    Menu("Push All Tags") {
                        ForEach(tagRemotes, id: \.self) { remote in
                            Button(remote) {
                                onPushAllTags(snapshot.rootPath, remote)
                            }
                        }
                    }
                    .font(.caption)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 6)
            ForEach(visibleBranchDirectoryRows(
                branchDirectoryRows(
                    for: snapshot.tags.map(\.name),
                    grouped: groupByDirectory,
                    scope: "\(snapshot.rootPath).tags"
                ),
                collapsedGroups: collapsedDirectoryGroups
            )) { row in
                if row.isGroup {
                    directoryGroupRow(row)
                } else if let refName = branchDirectoryRefName(row),
                          let tag = snapshot.tags.first(where: { $0.name == refName }) {
                    let targetID = multiTargetID(
                        rootPath: snapshot.rootPath,
                        kind: .tag,
                        value: tag.name
                    )
                    HStack(spacing: 6) {
                        Image(systemName: "tag")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(row.name)
                            .lineLimit(1)
                        Spacer()
                        Text(tag.shortId)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedRemoteGroupIDs = []
                        selectBranchTarget(id: targetID)
                    }
                    .disabled(tag.isCurrent)
                    .padding(.leading, CGFloat(row.depth) * 14)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        selectedBranchTargetIDs.contains(targetID)
                            ? Color.accentColor.opacity(0.22)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .contextMenu {
                        if !tag.isCurrent {
                            Button("Checkout") {
                                onCheckoutTag(snapshot.rootPath, tag.name)
                            }
                        }
                        Button("Show Diff with Working Tree") {
                            onShowDiffWithWorkingTree(snapshot.rootPath, tag.name)
                        }
                        if !tag.isCurrent {
                            Button("Merge into Current…") {
                                onMerge(snapshot.rootPath, tag.name)
                            }
                            Button("Delete") { onDeleteTag(snapshot.rootPath, tag.name) }
                            if snapshots.filter({ snapshot in
                                snapshot.tags.contains { $0.name == tag.name }
                            }).count > 1,
                            allowsSynchronizedBranchActions {
                                Button("Delete in Repositories…", role: .destructive) {
                                    onDeleteTagAcrossRoots(tag.name)
                                }
                            }
                        }
                        let tagRemotes = snapshot.remotes.map(\.name)
                        if tagRemotes.count > 1 {
                            Menu("Push to Remote") {
                                ForEach(tagRemotes, id: \.self) { remote in
                                    Button(remote) {
                                        onPushTagToRemote(snapshot.rootPath, tag.name, remote)
                                    }
                                }
                            }
                        } else if tagRemotes.count == 1 {
                            Button("Push to Remote") { onPushTag(snapshot.rootPath, tag.name) }
                        }
                    }
                }
            }
        }
        HStack {
            Text("STASHES")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if !snapshot.stashes.isEmpty {
                Button("Clear All") { onStashClear(snapshot.rootPath) }
                    .font(.caption)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        if snapshot.stashes.isEmpty {
            Text("No stashes")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        } else {
            ForEach(snapshot.stashes, id: \.id) { stash in
                rootStashRow(snapshot.rootPath, stash: stash)
            }
        }
    }

    private func rootStashRow(_ rootPath: String, stash: StashInfo) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full")
                .foregroundStyle(.orange)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(stash.message.isEmpty ? "WIP" : stash.message)
                    .lineLimit(1)
                Text(stash.shortId)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Menu {
                Button("Apply (Keep)") { onApplyStash(rootPath, stash.id, false) }
                Button("Apply + Restore Index (Keep)") { onApplyStash(rootPath, stash.id, true) }
                Button("Pop (Apply and Remove)") { onPopStash(rootPath, stash.id, false) }
                Button("Pop + Restore Index") { onPopStash(rootPath, stash.id, true) }
                Button("Create Branch from Stash…") { onStashBranch(rootPath, stash.id) }
                Button("View Diff") { onStashDiff(rootPath, stash.id) }
                Divider()
                Button("Drop", role: .destructive) { onDropStash(rootPath, stash.id) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }

    private func directoryGroupRow(_ row: BranchDirectoryRow) -> some View {
        Button {
            if collapsedDirectoryGroups.contains(row.id) {
                collapsedDirectoryGroups.remove(row.id)
            } else {
                collapsedDirectoryGroups.insert(row.id)
            }
        } label: {
            Label(
                row.name,
                systemImage: collapsedDirectoryGroups.contains(row.id) ? "chevron.right" : "chevron.down"
            )
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, CGFloat(row.depth) * 14 + 6)
                .padding(.top, 4)
        }
        .buttonStyle(.plain)
    }

    private func remoteGroupRow(
        rootPath: String,
        name: String,
        branchCount: Int
    ) -> some View {
        let id = remoteGroupTargetID(rootPath: rootPath, name: name)
        return Button {
            selectRemoteGroupTarget(id: id)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "network")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(name)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                Text("\(branchCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            selectedRemoteGroupIDs.contains(id) ? Color.accentColor.opacity(0.22) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .contextMenu {
            remoteGroupActionMenu(for: [
                BranchDashboardRemoteGroup(rootPath: rootPath, name: name)
            ])
        }
    }

    @ViewBuilder
    private func remoteGroupActionMenu(for selection: [BranchDashboardRemoteGroup]) -> some View {
        let availability = BranchDashboardRemoteGroupActionAvailability.resolve(selection: selection)
        if availability.contains(.editRemote), let group = selection.first {
            Button("Edit Remote…") {
                onEditRemote(group.rootPath, group.name)
            }
        }
        if availability.contains(.removeRemote) {
            if availability.contains(.editRemote) {
                Divider()
            }
            Button(
                selection.count == 1 ? "Remove Remote…" : "Remove Selected Remotes…",
                role: .destructive
            ) {
                if selection.count == 1, let group = selection.first {
                    onRemoveRemote(group.rootPath, group.name)
                } else {
                    onRemoveRemoteSelected(selection)
                }
            }
        }
    }

    private func popupReference(
        name: String,
        isCurrent: Bool,
        sync: SyncStatus?,
        rootPath: String,
        isRemote: Bool,
        hasHeadCommit: Bool = true,
        worktreePath: String?
    ) -> BranchDashboardReference {
        if isRemote {
            let shortName = name.split(separator: "/", maxSplits: 1)
                .dropFirst()
                .joined(separator: "/")
            return BranchDashboardReference(
                rootPath: rootPath,
                name: name,
                kind: .remote,
                remote: name.split(separator: "/", maxSplits: 1).first.map(String.init),
                localBranchName: sync?.branch,
                isCurrent: false,
                hasUpstream: false,
                hasTracking: false,
                hasRemote: true,
                isProtected: GitProtectedBranchRules.matches(
                    shortName.isEmpty ? name : shortName,
                    patterns: protectedBranchPatterns
                )
            )
        }

        return BranchDashboardReference(
            rootPath: rootPath,
            name: name,
            kind: .local,
            remote: nil,
            isCurrent: isCurrent,
            hasUpstream: sync != nil,
            hasTracking: sync?.trackingExists == true,
            hasRemote: snapshots.first(where: { $0.rootPath == rootPath }).map {
                !$0.remotes.isEmpty || !$0.remoteBranches.isEmpty
            } ?? false,
            isProtected: GitProtectedBranchRules.matches(
                name,
                patterns: protectedBranchPatterns
            ),
            hasHeadCommit: hasHeadCommit,
            worktreePath: worktreePath
        )
    }

    private func trackedRemoteBranch(rootPath: String, localName: String) -> RemoteBranchInfo? {
        guard let snapshot = snapshots.first(where: { $0.rootPath == rootPath }),
              let sync = snapshot.syncStatuses.first(where: {
                  $0.branch == localName && $0.trackingExists
              }) else { return nil }
        return snapshot.remoteBranches.first(where: { $0.name == sync.upstream })
    }

    @ViewBuilder
    private func trackedBranchMenu(rootPath: String, remote: RemoteBranchInfo) -> some View {
        let sync = snapshots.first(where: { $0.rootPath == rootPath })?.syncStatuses.first {
            $0.upstream == remote.name && $0.trackingExists
        }
        let availability = BranchDashboardActionAvailability.resolve(selection: [
            popupReference(
                name: remote.name,
                isCurrent: false,
                sync: sync,
                rootPath: rootPath,
                isRemote: true,
                worktreePath: nil
            )
        ])
        Menu("Tracked Branch: \(remote.name)") {
            if availability.contains(.compareWithCurrent) {
                Button("Compare with Current…") { onCompare(rootPath, remote.name) }
            }
            if availability.contains(.showDiffWithWorkingTree) {
                Button("Show Diff with Working Tree") {
                    onShowDiffWithWorkingTree(rootPath, remote.name)
                }
            }
            if availability.contains(.rebase) {
                Button("Rebase Current onto…") { onRebase(rootPath, remote.name) }
            }
            if availability.contains(.merge) {
                Button("Merge into Current…") { onMerge(rootPath, remote.name) }
            }
            Divider()
            if availability.contains(.pull) {
                Button("Pull into Current") {
                    onPullRemoteBranch(rootPath, remote.name, false)
                }
            }
            if availability.contains(.pullWithRebase) {
                Button("Pull into Current with Rebase") {
                    onPullRemoteBranch(rootPath, remote.name, true)
                }
            }
            Divider()
            if availability.contains(.checkout) {
                Button("Checkout as Local Branch") {
                    onCheckout(rootPath, remote.name, true)
                }
            }
            if availability.contains(.checkoutAsNewBranch) {
                Button("Checkout as New Branch…") {
                    onCheckoutAsNewBranch(rootPath, remote.name, true)
                }
            }
            if availability.contains(.checkoutWithRebase) {
                Button("Checkout with Rebase") {
                    onCheckoutWithRebase(rootPath, remote.name, true)
                }
            }
            if availability.contains(.deleteRemote) {
                Button("Delete Remote Branch", role: .destructive) {
                    onDeleteRemote(rootPath, remote.name)
                }
                .disabled(!availability.isEnabled(.deleteRemote))
            }
        }
    }

    private func branchRow(
        _ name: String,
        isCurrent: Bool,
        sync: SyncStatus?,
        rootPath: String,
        isRemote: Bool,
        hasHeadCommit: Bool = true,
        worktreePath: String? = nil,
        depth: Int = 0,
        selected: Bool = false
    ) -> some View {
        let reference = popupReference(
            name: name,
            isCurrent: isCurrent,
            sync: sync,
            rootPath: rootPath,
            isRemote: isRemote,
            hasHeadCommit: hasHeadCommit,
            worktreePath: worktreePath
        )
        let availability = BranchDashboardActionAvailability.resolve(selection: [reference])
        let incomingIdentity = isRemote ? autoFetchRemoteBranchIdentity(name) : nil
        let hasIncoming = isRemote
            ? incomingIdentity.map {
                hasUnfetchedIncomingRemoteBranch(
                    rootPath: rootPath,
                    remote: $0.remote,
                    branch: $0.branch,
                    in: incomingBranches
                )
            } ?? false
            : hasUnfetchedIncomingBranch(
                rootPath: rootPath,
                branch: name,
                in: incomingBranches
            )
        return HStack(spacing: 7) {
            Image(systemName: isRemote ? "cloud" : (isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch"))
                .foregroundStyle(isCurrent ? .green : .secondary)
                .frame(width: 16)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            if incomingOutgoingInfoEnabled,
               let sync, sync.trackingExists,
               sync.ahead > 0 || sync.behind > 0 || hasIncoming {
                HStack(spacing: 2) {
                    if sync.ahead > 0 { Text("↑\(sync.ahead)") }
                    if sync.behind > 0 { Text("↓\(sync.behind)") }
                    if hasIncoming { Text("↓?") }
                }
                .font(.caption2.monospaced())
                .foregroundStyle(sync.behind > 0 ? .blue : .green)
            } else if incomingOutgoingInfoEnabled, hasIncoming {
                Label("?", systemImage: "arrow.down")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.blue)
                    .help("Remote has incoming commits not fetched locally")
            }
            Spacer()
            if favoriteReferenceIDs.contains(
                branchFavoriteID(rootPath: rootPath, name: name, isRemote: isRemote)
            ) {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
            }
            if isCurrent {
                Menu {
                    Button(favoriteTitle(rootPath: rootPath, name: name, isRemote: isRemote)) {
                        toggleFavorite(rootPath: rootPath, name: name, isRemote: isRemote)
                    }
                    Divider()
                    if availability.contains(.showDiffWithWorkingTree) {
                        Button("Show Diff with Working Tree") {
                            onShowDiffWithWorkingTree(rootPath, name)
                        }
                    }
                    if availability.contains(.createWorktree) {
                        Button("New Working Tree from Branch…") {
                            onCreateWorktreeFromReference(rootPath, name, false)
                        }
                        .disabled(!availability.isEnabled(.createWorktree))
                    }
                    if availability.contains(.checkoutAsNewBranch) {
                        Button("Checkout as New Branch…") {
                            onCheckoutAsNewBranch(rootPath, name, false)
                        }
                    }
                    if availability.contains(.update) {
                        Button("Update") { onUpdateBranch(rootPath, name) }
                            .disabled(!availability.isEnabled(.update))
                            .help(availability.disabledDescription(for: .update) ?? "")
                    }
                    if let sync, sync.trackingExists, sync.ahead > 0, sync.behind > 0 {
                        Button("Update Force-Pushed Branch…") {
                            onForcePushedUpdate(rootPath, name)
                        }
                        if snapshots.filter({ snapshot in
                            snapshot.branches.contains { branch in
                                branch.name == name && branch.isCurrent
                            } && snapshot.syncStatuses.contains { status in
                                status.branch == name
                                    && status.trackingExists
                                    && status.ahead > 0
                                    && status.behind > 0
                            }
                        }).count > 1,
                           allowsSynchronizedBranchActions {
                            Button("Update Force-Pushed Branch in Repositories…") {
                                onForcePushedUpdateAcrossRoots(name)
                            }
                        }
                    }
                    if availability.contains(.push) {
                        Divider()
                        Button("Push…") { onPushDialog(rootPath, name) }
                    }
                    if let trackedRemote = trackedRemoteBranch(rootPath: rootPath, localName: name) {
                        Divider()
                        trackedBranchMenu(rootPath: rootPath, remote: trackedRemote)
                    }
                    if availability.contains(.rename) {
                        Divider()
                        Button("Rename…") { onRenameBranch(rootPath, name) }
                    }
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(.secondary)
            } else {
                Menu {
                    Button(favoriteTitle(rootPath: rootPath, name: name, isRemote: isRemote)) {
                        toggleFavorite(rootPath: rootPath, name: name, isRemote: isRemote)
                    }
                    Divider()
                    if isRemote {
                        if availability.contains(.pull) {
                            Button("Pull into Current") {
                                onPullRemoteBranch(rootPath, name, false)
                            }
                        }
                        if availability.contains(.pullWithRebase) {
                            Button("Pull into Current with Rebase") {
                                onPullRemoteBranch(rootPath, name, true)
                            }
                        }
                        Divider()
                        if availability.contains(.compareWithCurrent) {
                            Button("Compare with Current…") {
                                onCompare(rootPath, name)
                            }
                        }
                        if availability.contains(.showDiffWithWorkingTree) {
                            Button("Show Diff with Working Tree") {
                                onShowDiffWithWorkingTree(rootPath, name)
                            }
                        }
                        if availability.contains(.rebase) {
                            Button("Rebase Current onto…") {
                                onRebase(rootPath, name)
                            }
                        }
                        if availability.contains(.merge) {
                            Button("Merge into Current…") {
                                onMerge(rootPath, name)
                            }
                        }
                        Divider()
                    } else {
                        if availability.contains(.compareWithCurrent) {
                            Button("Compare with Current…") {
                                onCompare(rootPath, name)
                            }
                        }
                        if availability.contains(.showDiffWithWorkingTree) {
                            Button("Show Diff with Working Tree") {
                                onShowDiffWithWorkingTree(rootPath, name)
                            }
                        }
                        if availability.contains(.createWorktree) {
                            Button("New Working Tree from Branch…") {
                                onCreateWorktreeFromReference(rootPath, name, false)
                            }
                            .disabled(!availability.isEnabled(.createWorktree))
                        }
                        if availability.contains(.merge) {
                            Button("Merge into Current…") {
                                onMerge(rootPath, name)
                            }
                        }
                        if availability.contains(.rebase) {
                            Button("Rebase Current onto…") {
                                onRebase(rootPath, name)
                            }
                        }
                        if availability.contains(.push) {
                            Button("Push…") {
                                onPushDialog(rootPath, name)
                            }
                        }
                        if availability.contains(.update) {
                            Divider()
                            Button("Update") {
                                onUpdateBranch(rootPath, name)
                            }
                            .disabled(!availability.isEnabled(.update))
                            .help(availability.disabledDescription(for: .update) ?? "")
                        }
                        if let trackedRemote = trackedRemoteBranch(rootPath: rootPath, localName: name) {
                            Divider()
                            trackedBranchMenu(rootPath: rootPath, remote: trackedRemote)
                        }
                        if availability.contains(.setUpstream) {
                            Divider()
                            Button("Set Upstream…") {
                                onSetUpstream(rootPath, name)
                            }
                        }
                        if availability.contains(.unsetUpstream) {
                            Divider()
                            Button("Unset Upstream") {
                                onUnsetUpstream(rootPath, name)
                            }
                        }
                    }
                    if availability.contains(.checkout) {
                        Button(isRemote ? "Checkout as Local" : "Checkout") {
                            onCheckout(rootPath, name, isRemote)
                        }
                        .disabled(!availability.isEnabled(.checkout))
                    }
                    if availability.contains(.checkoutAsNewBranch) {
                        Button("Checkout as New Branch…") {
                            onCheckoutAsNewBranch(rootPath, name, isRemote)
                        }
                    }
                    if availability.contains(.checkoutWithUpdate) {
                        Button("Checkout and Update") {
                            onCheckoutAndUpdate(rootPath, name, false, false)
                        }
                        .disabled(!availability.isEnabled(.checkoutWithUpdate))
                        .help(availability.disabledDescription(for: .checkoutWithUpdate) ?? "")
                    }
                    if availability.contains(.checkoutWithRebase) {
                        Button("Checkout with Rebase") {
                            onCheckoutWithRebase(rootPath, name, isRemote)
                        }
                        .disabled(!availability.isEnabled(.checkoutWithRebase))
                    }
                    if availability.contains(.openWorktree),
                       let worktreePath, !worktreePath.isEmpty {
                        Button("Open Worktree…") {
                            onOpenWorktree(worktreePath)
                        }
                    }
                    if !isRemote {
                        Divider()
                        if availability.contains(.rename) {
                            Button("Rename…") {
                                onRenameBranch(rootPath, name)
                            }
                        }
                        let sameNameLocalReferences = snapshots.compactMap { snapshot -> BranchDashboardReference? in
                            guard let branch = snapshot.branches.first(where: { $0.name == name }) else { return nil }
                            let branchSync = snapshot.syncStatuses.first(where: { $0.branch == name })
                            return popupReference(
                                name: branch.name,
                                isCurrent: branch.isCurrent,
                                sync: branchSync,
                                rootPath: snapshot.rootPath,
                                isRemote: false,
                                hasHeadCommit: snapshot.headId != nil,
                                worktreePath: snapshot.worktrees.first { $0.branch == name && !$0.path.isEmpty }?.path
                            )
                        }
                        if sameNameLocalReferences.count > 1,
                           allowsSynchronizedBranchActions {
                            let crossRootAvailability = BranchDashboardActionAvailability.resolve(
                                selection: sameNameLocalReferences
                            )
                            Button("Merge in Repositories…") {
                                onMergeAcrossRoots(name)
                            }
                            Button("Rename in Repositories…") {
                                onRenameBranchAcrossRoots(name)
                            }
                            Button("Delete in Repositories…", role: .destructive) {
                                onDeleteBranchAcrossRoots(name)
                            }
                            .disabled(!crossRootAvailability.isEnabled(.deleteSelected))
                        }
                        if availability.contains(.deleteLocal) {
                            Button("Delete", role: .destructive) {
                                onDeleteBranch(rootPath, name)
                            }
                        }
                    } else if availability.contains(.deleteRemote) {
                        Button("Delete Remote Branch", role: .destructive) {
                            onDeleteRemote(rootPath, name)
                        }
                        .disabled(!availability.isEnabled(.deleteRemote))
                        let sameNameRemoteReferences = snapshots.compactMap { snapshot -> BranchDashboardReference? in
                            guard snapshot.remoteBranches.contains(where: { $0.name == name }) else { return nil }
                            let remoteSync = snapshot.syncStatuses.first(where: { $0.upstream == name })
                            return popupReference(
                                name: name,
                                isCurrent: false,
                                sync: remoteSync,
                                rootPath: snapshot.rootPath,
                                isRemote: true,
                                worktreePath: nil
                            )
                        }
                        if sameNameRemoteReferences.count > 1,
                           allowsSynchronizedBranchActions {
                            Button("Delete in Repositories…", role: .destructive) {
                                onDeleteRemoteAcrossRoots(name)
                            }
                            .disabled(!BranchDashboardActionAvailability.resolve(
                                selection: sameNameRemoteReferences
                            ).isEnabled(.deleteSelected))
                        }
                    }
                } label: {
                    Image(systemName: isRemote ? "arrow.down.to.line" : "arrow.triangle.branch")
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            selectBranchTarget(
                id: multiTargetID(
                    rootPath: rootPath,
                    kind: isRemote ? .remote : .local,
                    value: name
                )
            )
        }
        .background(selected ? Color.accentColor.opacity(0.22) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
    }

    private func selectRemoteGroupTarget(id: String) {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        selectedBranchTargetID = id
        selectedBranchTargetIDs = []
        branchSelectionAnchorID = nil
        if flags.contains(.command) {
            if selectedRemoteGroupIDs.contains(id) {
                selectedRemoteGroupIDs.remove(id)
            } else {
                selectedRemoteGroupIDs.insert(id)
            }
            return
        }
        selectedRemoteGroupIDs = [id]
    }

    private func selectBranchTarget(id: String) {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        selectedBranchTargetID = id
        selectedRemoteGroupIDs = []
        let selection = branchTreeSelectionAfterClick(
            current: selectedBranchTargetIDs,
            anchorID: branchSelectionAnchorID,
            orderedIDs: visibleBranchSelectionIDs,
            id: id,
            command: flags.contains(.command),
            shift: flags.contains(.shift)
        )
        selectedBranchTargetIDs = selection.selection
        branchSelectionAnchorID = selection.anchorID
    }

}

/// 多 root 冲突恢复的聚合索引；详情仍在对应 root 的 Repository 上执行。
struct MultiRootConflictGroup: Identifiable, Hashable {
    let rootPath: String
    let displayName: String
    let relativePath: String
    let operation: OperationKind?
    let paths: [String]

    var id: String { rootPath }
}

/// 项目级冲突树中的叶节点。rootPath 参与 identity，避免不同 Git root 的同名文件串到一起。
struct MultiRootConflictTarget: Identifiable, Hashable {
    let rootPath: String
    let path: String

    var id: String { "\(rootPath)\u{0}\(path)" }
}

func multiRootConflictTargets(from groups: [MultiRootConflictGroup]) -> [MultiRootConflictTarget] {
    groups
        .sorted { $0.rootPath < $1.rootPath }
        .flatMap { group in
            group.paths.sorted().map { path in
                MultiRootConflictTarget(rootPath: group.rootPath, path: path)
            }
    }
}

/// Project-level commit confirmation. IntelliJ's commit workflow makes the
/// message and affected repositories explicit; never fall back to a hidden
/// WIP message or the current window's repository.
struct MultiRootCommitDialogView: View {
    let groups: [MultiRootCommitGroup]
    let isLoading: Bool
    let error: String?
    let recentMessages: [String]
    let onTemplate: ([String]) -> Void
    let onBeforeCommitSettings: () -> Void
    let onIdentitySettings: () -> Void
    @Binding var message: String
    @Binding var amendMode: Bool
    @Binding var skipHooks: Bool
    @AppStorage(GitCommitHooksSettings.key)
    private var alwaysSkipCommitHooks = GitCommitHooksSettings.defaultValue
    @Binding var authorName: String
    @Binding var authorEmail: String
    @Binding var committerName: String
    @Binding var committerEmail: String
    @Binding var signOff: Bool
    @Binding var coAuthors: String
    /// Non-nil when the dialog was opened from Changes Browser's file
    /// selection. Nil retains the root-level Commit workflow.
    let selectedChanges: [MultiRootChangeSelection]?
    let onCommit: ([String], String) -> Void
    let onCommitAndPush: ([String], String) -> Void
    let onCommitSelectedChanges: ([MultiRootChangeSelection], String) -> Void
    let onCommitAndPushSelectedChanges: ([MultiRootChangeSelection], String) -> Void
    let onCancel: () -> Void
    @State private var selectedRootPaths: Set<String> = []
    @State private var selectedChangeIDs: Set<String> = []
    @State private var selectionInitialized = false
    @State private var showCommitOptions = false

    private var eligibleGroups: [MultiRootCommitGroup] {
        groups.filter { $0.canCommit(amend: amendMode) }
    }

    private var selectedEligibleGroups: [MultiRootCommitGroup] {
        eligibleGroups.filter { selectedRootPaths.contains($0.rootPath) }
    }

    private var selectedEligibleChanges: [MultiRootChangeSelection] {
        let eligibleRootPaths = Set(eligibleGroups.map(\.rootPath))
        return groups
            .flatMap(\.stagedEntries)
            .filter {
                eligibleRootPaths.contains($0.rootPath)
                    && selectedChangeIDs.contains($0.id)
            }
            .sorted {
                if $0.rootPath == $1.rootPath { return $0.path < $1.path }
                return $0.rootPath < $1.rootPath
            }
    }

    private var selectedEligibleChangeRootPaths: [String] {
        Array(Set(selectedEligibleChanges.map(\.rootPath))).sorted()
    }

    private var canSubmit: Bool {
        guard !isLoading, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if selectedChanges != nil {
            return !selectedEligibleChanges.isEmpty
        }
        return !selectedEligibleGroups.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle").foregroundStyle(Design.Colors.accent)
                Text("Commit Changes")
                    .font(.title2.weight(.semibold))
                Spacer()
                Toggle("Amend", isOn: $amendMode)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                if isLoading { ProgressView().controlSize(.small) }
            }

            Text(
                selectedChanges == nil
                    ? "Select the Git roots whose staged changes should be committed."
                    : "Select the staged files to commit. Files remain qualified by their Git root."
            )
                .font(.callout)
                .foregroundStyle(.secondary)

            if let error, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            if isLoading && groups.isEmpty {
                ProgressView("Loading staged changes…")
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else if groups.isEmpty {
                ContentUnavailableView(
                    "No Git Roots",
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text("No Git root is available for this commit.")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                if selectedChanges != nil {
                    List {
                        ForEach(groups) { group in
                            if !group.stagedEntries.isEmpty {
                                Section {
                                    ForEach(group.stagedEntries, id: \.id) { selection in
                                        Toggle(isOn: changeSelectionBinding(for: selection.id)) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(selection.path)
                                                    .font(.callout)
                                                if let oldPath = selection.oldPath,
                                                   oldPath != selection.path {
                                                    Text("renamed from \(oldPath)")
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                        }
                                        .toggleStyle(.checkbox)
                                        .disabled(
                                            isLoading
                                                || !group.canCommit(amend: amendMode)
                                        )
                                    }
                                } header: {
                                    HStack(spacing: 6) {
                                        Text(group.displayName)
                                            .font(.callout.weight(.medium))
                                        Text(group.relativePath)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .frame(minHeight: 180, maxHeight: 300)
                } else {
                    List {
                        ForEach(groups) { group in
                            Toggle(isOn: selectionBinding(for: group.rootPath)) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(group.displayName)
                                            .font(.callout.weight(.medium))
                                        Text(group.relativePath)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if !group.conflictedPaths.isEmpty {
                                        Text("\(group.conflictedPaths.count) conflicted file(s); resolve before committing")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    } else if group.stagedPaths.isEmpty {
                                        Text(amendMode ? "Amend current HEAD" : "No staged changes")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("\(group.stagedPaths.count) staged file(s)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(!group.canCommit(amend: amendMode) || isLoading)
                        }
                    }
                    .listStyle(.inset)
                    .frame(minHeight: 180, maxHeight: 300)
                }
            }

            DisclosureGroup("Commit options", isExpanded: $showCommitOptions) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(
                        "Skip hooks",
                        isOn: Binding(
                            get: { skipHooks || alwaysSkipCommitHooks },
                            set: { skipHooks = $0 }
                        )
                    )
                        .toggleStyle(.checkbox)
                        .disabled(alwaysSkipCommitHooks)
                    Toggle("Add Signed-off-by", isOn: $signOff)
                        .toggleStyle(.checkbox)
                    Text("Configured before-commit checks run separately for every selected root.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("Before-commit settings", action: onBeforeCommitSettings)
                        Button("Git identity", action: onIdentitySettings)
                    }
                    HStack(spacing: 8) {
                        TextField("Author name", text: $authorName)
                            .textFieldStyle(.roundedBorder)
                        TextField("Author email", text: $authorEmail)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack(spacing: 8) {
                        TextField("Committer name", text: $committerName)
                            .textFieldStyle(.roundedBorder)
                        TextField("Committer email", text: $committerEmail)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("Co-authors (one Name <email> per line)")
                        .font(.caption.weight(.medium))
                    TextEditor(text: $coAuthors)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 46)
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.secondary.opacity(0.25))
                        }
                }
                .padding(.top, 6)
            }

            HStack(spacing: 8) {
                Text("Commit message")
                    .font(.callout.weight(.medium))
                Spacer()
                Button("Template") {
                    let roots: [String]
                    if selectedChanges != nil {
                        roots = selectedEligibleChangeRootPaths.isEmpty
                            ? eligibleGroups.map(\.rootPath)
                            : selectedEligibleChangeRootPaths
                    } else {
                        roots = selectedRootPaths.isEmpty
                            ? eligibleGroups.map(\.rootPath)
                            : Array(selectedRootPaths)
                    }
                    onTemplate(roots.sorted())
                }
                Menu {
                    if recentMessages.isEmpty {
                        Text("No recent commit messages")
                    } else {
                        ForEach(recentMessages, id: \.self) { recentMessage in
                            Button(recentMessage) { message = recentMessage }
                        }
                    }
                } label: {
                    Image(systemName: "clock")
                }
                .menuStyle(.borderlessButton)
                .help("Recent commit messages")
            }
            TextEditor(text: $message)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 90, maxHeight: 150)
                .padding(6)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.35))
                }

            HStack {
                Text(
                    selectedChanges == nil
                        ? "\(selectedEligibleGroups.count) root(s) selected"
                        : "\(selectedEligibleChanges.count) file(s) selected"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button(
                    selectedChanges == nil
                        ? (amendMode ? "Amend Selected" : "Commit Selected")
                        : (amendMode ? "Amend Selected Files" : "Commit Selected Files")
                ) {
                    let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    if selectedChanges != nil {
                        guard !selectedEligibleChanges.isEmpty else { return }
                        onCommitSelectedChanges(selectedEligibleChanges, text)
                    } else {
                        let selected = selectedEligibleGroups.map(\.rootPath).sorted()
                        guard !selected.isEmpty else { return }
                        onCommit(selected, text)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
                Button(
                    selectedChanges == nil
                        ? (amendMode ? "Amend and Push Selected" : "Commit and Push Selected")
                        : (amendMode
                            ? "Amend and Push Selected Files"
                            : "Commit and Push Selected Files")
                ) {
                    let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    if selectedChanges != nil {
                        guard !selectedEligibleChanges.isEmpty else { return }
                        onCommitAndPushSelectedChanges(selectedEligibleChanges, text)
                    } else {
                        let selected = selectedEligibleGroups.map(\.rootPath).sorted()
                        guard !selected.isEmpty else { return }
                        onCommitAndPush(selected, text)
                    }
                }
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(minWidth: 700, minHeight: 700)
        .onAppear { initializeSelection() }
        .onChange(of: groups.map { group in
            "\(group.rootPath)|\(group.stagedEntries.map(\.id).joined(separator: ","))|\(group.conflictedPaths.count)"
        }) { _, _ in
            initializeSelection()
        }
        .onChange(of: amendMode) { _, _ in
            initializeSelection()
        }
        .onChange(of: selectedChanges?.map(\.id) ?? []) { _, _ in
            selectionInitialized = false
            initializeSelection()
        }
    }

    private func selectionBinding(for rootPath: String) -> Binding<Bool> {
        Binding(
            get: { selectedRootPaths.contains(rootPath) },
            set: { selected in
                if selected {
                    selectedRootPaths.insert(rootPath)
                } else {
                    selectedRootPaths.remove(rootPath)
                }
            }
        )
    }

    private func changeSelectionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selectedChangeIDs.contains(id) },
            set: { selected in
                if selected {
                    selectedChangeIDs.insert(id)
                } else {
                    selectedChangeIDs.remove(id)
                }
            }
        )
    }

    private func initializeSelection() {
        guard !groups.isEmpty else { return }
        if let selectedChanges {
            let eligible = Set(groups.flatMap(\.stagedEntries).map(\.id))
            if !selectionInitialized {
                selectedChangeIDs = Set(selectedChanges.map(\.id)).intersection(eligible)
                selectionInitialized = true
            } else {
                selectedChangeIDs.formIntersection(eligible)
            }
        } else {
            let eligible = Set(eligibleGroups.map(\.rootPath))
            if !selectionInitialized {
                selectedRootPaths = eligible
                selectionInitialized = true
            } else {
                selectedRootPaths.formIntersection(eligible)
            }
        }
    }
}

/// REPO-001：多 Git root 聚合视图——逐 root 状态 + 聚合操作按钮,
/// 显示部分成功、部分失败与跳过。
struct MultiRootPanel: View {
    let roots: [GitRootInfo]
    let results: [RootOperationResult]
    let conflictGroups: [MultiRootConflictGroup]
    let isRunning: Bool
    let canRetryFailedUpdate: Bool
    let canRetryFailedCheckoutUpdate: Bool
    let canRetryFailedPush: Bool
    let onOperation: (MultiRootOperation) -> Void
    let onCommitAll: () -> Void
    let onCheckout: (String, Bool) -> Void
    let onRecovery: (String, MultiRootRecoveryAction) -> Void
    let onRetryFailedUpdate: () -> Void
    let onRetryFailedCheckoutUpdate: () -> Void
    let onRetryFailedPush: () -> Void
    let onResolveOperationConflict: (String, String?) -> Void
    let onAcceptConflicts: ([MultiRootConflictTarget], FilePick) -> Void
    let conflictBatchWorking: Bool
    let conflictBatchError: String?
    let stashConflicts: [String: [String]]
    let onResolveStashConflict: (String) -> Void
    let updateStashRoots: Set<String>
    let onRestoreUpdateStash: (String) -> Void
    let onRefresh: () -> Void
    let onShowChanges: () -> Void
    @State private var checkoutReference = ""
    @State private var checkoutDetached = false
    @State private var selectedConflictIDs: Set<String> = []

    private var conflictTargets: [MultiRootConflictTarget] {
        multiRootConflictTargets(from: conflictGroups)
    }

    private var selectedConflictTargets: [MultiRootConflictTarget] {
        conflictTargets.filter { selectedConflictIDs.contains($0.id) }
    }

    private var hasRetryableFailedUpdate: Bool {
        guard canRetryFailedUpdate else { return false }
        return results.contains { result in
            guard !result.success,
                  !updateStashRoots.contains(result.rootPath) else { return false }
            return roots.first(where: { $0.path == result.rootPath })?.operation == nil
        }
    }

    private var hasRetryableFailedCheckoutUpdate: Bool {
        guard canRetryFailedCheckoutUpdate else { return false }
        return results.contains { result in
            guard !result.success,
                  !updateStashRoots.contains(result.rootPath) else { return false }
            return roots.first(where: { $0.path == result.rootPath })?.operation == nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Git Roots").font(.headline)
                Text("\(roots.count) roots")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Fetch All") { onOperation(.fetch) }
                    .controlSize(.small)
                    .disabled(isRunning)
                Button("Pull All (Merge)") { onOperation(.pullMerge) }
                    .controlSize(.small)
                    .disabled(isRunning)
                Button("Pull All (Rebase)") { onOperation(.pullRebase) }
                    .controlSize(.small)
                    .disabled(isRunning)
                Button("Push All") { onOperation(.push) }
                    .controlSize(.small)
                    .disabled(isRunning)
                if hasRetryableFailedUpdate {
                    Button("Retry Failed Roots") { onRetryFailedUpdate() }
                        .controlSize(.small)
                        .disabled(isRunning)
                }
                if hasRetryableFailedCheckoutUpdate {
                    Button("Retry Failed Checkout Roots") { onRetryFailedCheckoutUpdate() }
                        .controlSize(.small)
                        .disabled(isRunning)
                }
                if canRetryFailedPush {
                    Button("Retry Failed Push Roots") { onRetryFailedPush() }
                        .controlSize(.small)
                        .disabled(isRunning)
                }
                Button("Commit All", action: onCommitAll)
                    .controlSize(.small)
                    .disabled(isRunning)
                Button("View Changes", action: onShowChanges)
                    .controlSize(.small)
                Button("Refresh") { onRefresh() }
                    .controlSize(.small)
            }
            HStack(spacing: 8) {
                TextField("Branch / tag / revision", text: $checkoutReference)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220)
                Toggle("Detached", isOn: $checkoutDetached)
                    .toggleStyle(.checkbox)
                Button("Checkout") {
                    let reference = checkoutReference.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !reference.isEmpty else { return }
                    onCheckout(reference, checkoutDetached)
                }
                .controlSize(.small)
                .disabled(isRunning || checkoutReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !conflictGroups.isEmpty || !stashConflicts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Label("Conflicts", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        if !selectedConflictTargets.isEmpty {
                            Text("\(selectedConflictTargets.count) selected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Accept Ours") {
                                onAcceptConflicts(selectedConflictTargets, .ours)
                            }
                            .controlSize(.small)
                            .disabled(isRunning || conflictBatchWorking)
                            Button("Accept Theirs") {
                                onAcceptConflicts(selectedConflictTargets, .theirs)
                            }
                            .controlSize(.small)
                            .disabled(isRunning || conflictBatchWorking)
                        }
                        if conflictBatchWorking {
                            ProgressView()
                                .controlSize(.small)
                            Text("Resolving…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let conflictBatchError {
                        Text(conflictBatchError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if !conflictTargets.isEmpty {
                        List(selection: $selectedConflictIDs) {
                            ForEach(conflictGroups) { group in
                                Section {
                                    ForEach(group.paths, id: \.self) { path in
                                        let targetID = MultiRootConflictTarget(
                                            rootPath: group.rootPath,
                                            path: path
                                        ).id
                                        HStack(spacing: 6) {
                                            Label(path, systemImage: "exclamationmark.triangle")
                                                .font(.caption)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Spacer(minLength: 4)
                                            Button("Open") {
                                                onResolveOperationConflict(group.rootPath, path)
                                            }
                                            .buttonStyle(.link)
                                            .controlSize(.small)
                                            .disabled(isRunning || conflictBatchWorking)
                                        }
                                        .tag(targetID)
                                    }
                                } header: {
                                    HStack(spacing: 6) {
                                        Text(group.displayName)
                                            .font(.system(size: 13, weight: .medium))
                                        Text(group.relativePath)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if let operation = group.operation {
                                            Text(operationText(operation))
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                }
                            }
                        }
                        .listStyle(.inset)
                        .frame(minHeight: 72, maxHeight: 240)
                    }
                    ForEach(stashConflicts.keys.sorted(), id: \.self) { rootPath in
                        if let paths = stashConflicts[rootPath] {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(URL(fileURLWithPath: rootPath).lastPathComponent)
                                        .font(.system(size: 13, weight: .medium))
                                    Text("stash")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                    Spacer()
                                    Button("Resolve…") {
                                        onResolveStashConflict(rootPath)
                                    }
                                    .controlSize(.small)
                                    .disabled(isRunning)
                                }
                                ForEach(paths, id: \.self) { path in
                                    Text("• \(path)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .padding(.leading, 6)
                        }
                    }
                }
                .padding(8)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                Divider()
            }
            if isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在逐 root 执行…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if roots.isEmpty {
                ContentUnavailableView {
                    Label("No Git Roots", systemImage: "externaldrive.badge.questionmark")
                } description: {
                    Text("当前项目目录不包含 Git 仓库。")
                }
            } else {
                List {
                    ForEach(roots, id: \.path) { root in
                        let result = results.first { $0.rootPath == root.path }
                        HStack(spacing: 8) {
                            Image(systemName: statusIcon(result))
                                .foregroundStyle(statusColor(result))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(root.displayName)
                                    .font(.system(size: 13, weight: .medium))
                                Text(root.relativePath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if root.dirty {
                                Text("dirty")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            if let operation = root.operation {
                                Text(operationText(operation))
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                Button("Resolve…") {
                                    onResolveOperationConflict(root.path, nil)
                                }
                                .controlSize(.small)
                                .disabled(isRunning)
                            }
                            if let conflicts = stashConflicts[root.path] {
                                Text("stash conflict (\(conflicts.count))")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                Button("Resolve…") {
                                    onResolveStashConflict(root.path)
                                }
                                .controlSize(.small)
                                .disabled(isRunning)
                            }
                            if updateStashRoots.contains(root.path), root.operation == nil {
                                Text("Update stash pending")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                Button("Restore…") {
                                    onRestoreUpdateStash(root.path)
                                }
                                .controlSize(.small)
                                .disabled(isRunning)
                            }
                            if let result {
                                Text(result.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            if let operation = root.operation {
                                HStack(spacing: 4) {
                                    Button("Continue") {
                                        onRecovery(root.path, .continueOperation)
                                    }
                                    .controlSize(.small)
                                    if operation == .rebase {
                                        Button("Skip") {
                                            onRecovery(root.path, .skip)
                                        }
                                        .controlSize(.small)
                                    }
                                    Button("Abort", role: .destructive) {
                                        onRecovery(root.path, .abort)
                                    }
                                    .controlSize(.small)
                                }
                                .disabled(isRunning)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
            }
        }
        .onChange(of: conflictTargets.map(\.id)) { _, ids in
            selectedConflictIDs.formIntersection(Set(ids))
        }
        .padding(12)
    }

    private func statusIcon(_ result: RootOperationResult?) -> String {
        guard let result else { return "circle.dotted" }
        if result.skipped { return "arrow.right.square" }
        return result.success ? "checkmark.circle" : "xmark.circle"
    }

    private func statusColor(_ result: RootOperationResult?) -> Color {
        guard let result else { return .secondary }
        if result.skipped { return .secondary }
        return result.success ? .green : .red
    }

    private func operationText(_ kind: OperationKind) -> String {
        switch kind {
        case .merge: return "merge"
        case .rebase: return "rebase"
        case .cherryPick: return "cherry-pick"
        case .revert: return "revert"
        }
    }
}
