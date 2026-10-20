import SwiftUI
import AppKit
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
