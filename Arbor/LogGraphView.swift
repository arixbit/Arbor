import SwiftUI
import AppKit

enum LogColumnID: String, CaseIterable, Hashable, Identifiable {
    case commit
    case author
    case date
    case hash
    case root
    case signature

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .commit: "Commit"
        case .author: "Author"
        case .date: "Date"
        case .hash: "Hash"
        case .root: "Root Names"
        case .signature: "Commit Signature"
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .commit: 276
        case .author: 132
        case .date: 154
        case .hash: 76
        case .root: 180
        case .signature: 156
        }
    }

    var minimumWidth: CGFloat {
        switch self {
        case .commit: 276
        case .author: 88
        case .date: 112
        case .hash: 64
        case .root: 120
        case .signature: 120
        }
    }

    /// IntelliJ's Git signature external-status column has a fixed renderer
    /// width and is not user-resizable.
    var isResizable: Bool {
        self != .signature
    }
}

struct LogColumnLayout: Equatable {
    static let defaultOrder: [LogColumnID] = [.commit, .author, .date, .hash, .root, .signature]

    let order: [LogColumnID]
    let widths: [LogColumnID: CGFloat]

    init(orderRaw: String, widthsRaw: String = "") {
        let parsedOrder = orderRaw
            .split(separator: ",")
            .compactMap { LogColumnID(rawValue: String($0)) }
        order = Self.normalizedOrder(parsedOrder)

        var parsedWidths: [LogColumnID: CGFloat] = [:]
        for entry in widthsRaw.split(separator: ";") {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let column = LogColumnID(rawValue: parts[0]),
                  let width = Double(parts[1]) else { continue }
            parsedWidths[column] = max(column.minimumWidth, CGFloat(width))
        }
        widths = Dictionary(uniqueKeysWithValues: LogColumnID.allCases.map { column in
            (column, parsedWidths[column] ?? column.defaultWidth)
        })
    }

    init(
        order: [LogColumnID] = Self.defaultOrder,
        widths: [LogColumnID: CGFloat] = [:]
    ) {
        self.order = Self.normalizedOrder(order)
        self.widths = Dictionary(uniqueKeysWithValues: LogColumnID.allCases.map { column in
            (column, max(column.minimumWidth, widths[column] ?? column.defaultWidth))
        })
    }

    var orderRaw: String { order.map(\.rawValue).joined(separator: ",") }

    var widthsRaw: String {
        LogColumnID.allCases
            .map { "\($0.rawValue)=\(Int(width(for: $0)))" }
            .joined(separator: ";")
    }

    func width(for column: LogColumnID) -> CGFloat {
        widths[column] ?? column.defaultWidth
    }

    func moving(_ column: LogColumnID, by offset: Int) -> LogColumnLayout {
        guard let index = order.firstIndex(of: column) else { return self }
        let newIndex = index + offset
        guard order.indices.contains(newIndex) else { return self }
        var nextOrder = order
        nextOrder.swapAt(index, newIndex)
        return LogColumnLayout(order: nextOrder, widths: widths)
    }

    func moving(_ column: LogColumnID, before target: LogColumnID) -> LogColumnLayout {
        guard column != target,
              order.contains(column),
              order.contains(target) else { return self }
        var nextOrder = order
        nextOrder.removeAll { $0 == column }
        guard let targetIndex = nextOrder.firstIndex(of: target) else { return self }
        nextOrder.insert(column, at: targetIndex)
        return LogColumnLayout(order: nextOrder, widths: widths)
    }

    func settingWidth(_ width: CGFloat, for column: LogColumnID) -> LogColumnLayout {
        var nextWidths = widths
        nextWidths[column] = max(column.minimumWidth, width)
        return LogColumnLayout(order: order, widths: nextWidths)
    }

    func visibleOrder(
        showAuthor: Bool,
        showDate: Bool,
        showHash: Bool,
        showRoot: Bool,
        showSignature: Bool
    ) -> [LogColumnID] {
        order.filter { column in
            switch column {
            case .commit: true
            case .author: showAuthor
            case .date: showDate
            case .hash: showHash
            case .root: showRoot
            case .signature: showSignature
            }
        }
    }

    private static func normalizedOrder(_ order: [LogColumnID]) -> [LogColumnID] {
        var result: [LogColumnID] = []
        for column in order where !result.contains(column) {
            result.append(column)
        }
        for column in defaultOrder where !result.contains(column) {
            result.append(column)
        }
        return result
    }
}

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

/// The graph table keeps every commit row visible while LinearBek changes
/// which edges are painted. This is intentionally a value type so the
/// collapse/expand rules can be tested without rendering SwiftUI.
enum LinearBekRowAction: Equatable {
    case collapse(String)
    case expand(String)

    var isCollapse: Bool {
        if case .collapse = self { return true }
        return false
    }
}

enum LinearBekGraphElement: Hashable {
    case node(Int)
    case normal(LinearBekGraphEdge)
    case dotted(LinearBekDottedEdge)
}

/// IntelliJ's graph controller receives typed actions from the graph table and
/// returns a new graph answer. Keep the same boundary in the SwiftUI value
/// model so row buttons, edge clicks, hover highlighting, and future keyboard
/// graph actions do not each mutate fragment state differently.
enum LinearBekGraphActionType: Equatable {
    case mouseClick
    case mouseOver
    case buttonCollapse
    case buttonExpand
}

struct LinearBekGraphAction: Equatable {
    let type: LinearBekGraphActionType
    let affectedElement: LinearBekGraphElement?
}

/// A monotonic command envelope lets the Log menu invoke the same graph
/// controller as pointer actions, including repeated Expand/Collapse commands
/// of the same type.
struct LinearBekGraphCommand: Equatable {
    let id: Int
    let action: LinearBekGraphActionType
}

struct LinearBekGraphEdge: Hashable {
    let upRow: Int
    let downRow: Int
    let fromLane: UInt32
    let toLane: UInt32
    let parentIndex: Int
}

struct LinearBekDottedEdge: Hashable {
    let mergeID: String
    let upRow: Int
    let downRow: Int
    let fromLane: UInt32
    let toLane: UInt32
}

/// IntelliJ's graph answer selects the complete fragment node set, rather
/// than only the print element currently under the pointer. Keep the selected
/// rows and edges together so Canvas can render the same feedback without
/// coupling the controller to SwiftUI.
struct LinearBekGraphHighlight: Equatable {
    let rows: Set<Int>
    let normalEdges: Set<LinearBekGraphEdge>
    let dottedEdges: Set<LinearBekDottedEdge>
}

struct LinearBekMergeFragment: Hashable {
    let mergeID: String
    let mergeRow: Int
    let leftChildRow: Int
    let rightChildRow: Int
    let affectedRows: Set<Int>
    let hiddenEdges: Set<LinearBekGraphEdge>
    let tailRows: Set<Int>
    let bodyRows: Set<Int>
    let tailEdges: Set<LinearBekGraphEdge>
    let mergeWithOldCommit: Bool
    let dottedEdges: [LinearBekDottedEdge]

    /// Kept as a compatibility convenience for callers that only need the
    /// common single-tail case. IntelliJ can produce several dotted tails for
    /// one merge fragment.
    var dottedEdge: LinearBekDottedEdge? {
        dottedEdges.first
    }
}

struct LinearBekGraphModel {
    let normalEdges: [LinearBekGraphEdge]
    let fragments: [String: LinearBekMergeFragment]
    let collapsedMergeIDs: Set<String>
    private let collapsedHiddenEdges: Set<LinearBekGraphEdge>
    private let activeCollapsedDottedEdges: [LinearBekDottedEdge]

    init(
        commits: [CommitInfo],
        collapseAll: Bool,
        expandedMergeIDs: Set<String>,
        collapsedMergeIDs: Set<String> = [],
        identity: (CommitInfo) -> String = { $0.id }
    ) {
        let rowByID = Dictionary(uniqueKeysWithValues: commits.enumerated().map { (identity($0.element), $0.offset) })
        let identityByRootID = Dictionary(uniqueKeysWithValues: commits.map {
            ("\($0.repositoryPath ?? "")\u{1f}\($0.id)", identity($0))
        })
        let edges = Self.makeEdges(
            commits: commits,
            rowByID: rowByID,
            identityByRootID: identityByRootID
        )
        let layoutIndexByRow = Self.makeLayoutIndexes(
            commits: commits,
            normalEdges: edges
        )
        var builtFragments: [String: LinearBekMergeFragment] = [:]

        for (mergeRow, merge) in commits.enumerated() where merge.parentIds.count == 2 {
            guard let fragment = Self.makeFragment(
                merge: merge,
                mergeRow: mergeRow,
                commits: commits,
                rowByID: rowByID,
                identityByRootID: identityByRootID,
                mergeID: identity(merge),
                normalEdges: edges,
                layoutIndexByRow: layoutIndexByRow
            ) else { continue }
            builtFragments[identity(merge)] = fragment
        }

        normalEdges = edges
        fragments = builtFragments
        let availableMergeIDs = Set(builtFragments.keys)
        self.collapsedMergeIDs = collapseAll
            ? availableMergeIDs.subtracting(expandedMergeIDs)
            : collapsedMergeIDs.intersection(availableMergeIDs)
        let collapsedState = Self.simulateCollapsedState(
            fragments: builtFragments,
            normalEdges: edges,
            collapsedMergeIDs: self.collapsedMergeIDs
        )
        collapsedHiddenEdges = collapsedState.hiddenNormalEdges
        activeCollapsedDottedEdges = collapsedState.dottedEdges
    }

    var visibleEdges: [LinearBekGraphEdge] {
        normalEdges.filter { !collapsedHiddenEdges.contains($0) }
    }

    var dottedEdges: [LinearBekDottedEdge] {
        activeCollapsedDottedEdges
    }

    var mergeIDs: Set<String> {
        Set(fragments.keys)
    }

    func rowAction(at row: Int) -> LinearBekRowAction? {
        for mergeID in collapsedMergeIDs {
            if fragments[mergeID]?.affectedRows.contains(row) == true {
                return .expand(mergeID)
            }
        }
        for (mergeID, fragment) in fragments where fragment.mergeRow == row {
            return .collapse(mergeID)
        }
        return nil
    }

    /// IntelliJ resolves a node click to the nearest LinearBek fragment, not
    /// only to the merge row. This keeps every node in a visible fragment
    /// clickable while leaving the compact row button anchored to the merge.
    func nodeAction(at row: Int) -> LinearBekRowAction? {
        let candidates = fragments.values
            .filter { $0.affectedRows.contains(row) }
            .sorted { $0.mergeRow > $1.mergeRow }
        if let collapsed = candidates.first(where: { collapsedMergeIDs.contains($0.mergeID) }) {
            return .expand(collapsed.mergeID)
        }
        return candidates.first.map { .collapse($0.mergeID) }
    }

    func action(for element: LinearBekGraphElement) -> LinearBekRowAction? {
        switch element {
        case let .node(row):
            return nodeAction(at: row)
        case let .normal(edge):
            guard !collapsedMergeIDs.isEmpty || !fragments.isEmpty else { return nil }
            for (mergeID, fragment) in fragments where !collapsedMergeIDs.contains(mergeID) {
                // IntelliJ's LinearBek collapse action is attached to the
                // visible long-fragment edges. The two edges represented by
                // hiddenEdges are the exact fragment boundary edges in our
                // value model; clicking either boundary collapses it.
                if fragment.hiddenEdges.contains(edge) {
                    return .collapse(mergeID)
                }
            }
            return nil
        case let .dotted(edge):
            guard collapsedMergeIDs.contains(edge.mergeID) else { return nil }
            return .expand(edge.mergeID)
        }
    }

    /// Resolve the same fragment-wide selection that IntelliJ's
    /// `LinearBekController.highlightNode` and collapsing action manager
    /// return through `LinearGraphUtils.createSelectedAnswer`.
    func highlight(for element: LinearBekGraphElement) -> LinearBekGraphHighlight? {
        var rows = Set<Int>()
        var fragmentIDs = Set<String>()
        var dottedEdges = Set<LinearBekDottedEdge>()

        switch element {
        case let .node(row):
            guard let mergeID = mergeID(at: row) else { return nil }
            if collapsedMergeIDs.contains(mergeID) {
                dottedEdges = Set(activeCollapsedDottedEdges.filter {
                    $0.mergeID == mergeID || $0.upRow == row || $0.downRow == row
                })
                rows.formUnion(dottedEdges.flatMap { [$0.upRow, $0.downRow] })
                rows.insert(row)
            } else {
                let fragments = childFragments(startingAt: mergeID)
                fragmentIDs = Set(fragments.map(\.mergeID))
                rows = fragments.reduce(into: Set<Int>()) {
                    $0.formUnion($1.affectedRows)
                }
            }
        case let .normal(edge):
            guard let owner = fragments.values.first(where: {
                !$0.mergeID.isEmpty && $0.hiddenEdges.contains(edge)
            }) else { return nil }
            let fragments = childFragments(startingAt: owner.mergeID)
            fragmentIDs = Set(fragments.map(\.mergeID))
            rows = fragments.reduce(into: Set<Int>()) {
                $0.formUnion($1.affectedRows)
            }
            rows.formUnion([edge.upRow, edge.downRow])
        case let .dotted(edge):
            guard collapsedMergeIDs.contains(edge.mergeID) else { return nil }
            dottedEdges.insert(edge)
            rows = [edge.upRow, edge.downRow]
        }

        guard !rows.isEmpty else { return nil }
        let normalEdges = Set(self.normalEdges.filter {
            rows.contains($0.upRow) && rows.contains($0.downRow)
        })
        if dottedEdges.isEmpty {
            dottedEdges = Set(activeCollapsedDottedEdges.filter {
                fragmentIDs.contains($0.mergeID)
                    || rows.contains($0.upRow)
                    || rows.contains($0.downRow)
            })
        }
        return LinearBekGraphHighlight(
            rows: rows,
            normalEdges: normalEdges,
            dottedEdges: dottedEdges
        )
    }

    private func mergeID(at row: Int) -> String? {
        fragments.values
            .filter { $0.affectedRows.contains(row) }
            .sorted { $0.mergeRow > $1.mergeRow }
            .first?
            .mergeID
    }

    private func childFragments(startingAt mergeID: String) -> [LinearBekMergeFragment] {
        var pending = [mergeID]
        var visited = Set<String>()
        var result: [LinearBekMergeFragment] = []

        while let next = pending.popLast() {
            guard visited.insert(next).inserted,
                  let fragment = fragments[next] else { continue }
            result.append(fragment)

            let childIDs = fragments.values
                .filter { candidate in
                    candidate.mergeRow != fragment.mergeRow
                        && candidate.mergeRow >= 0
                        && (fragment.tailRows.contains(candidate.mergeRow)
                            || fragment.bodyRows.contains(candidate.mergeRow))
                }
                .map(\.mergeID)
            pending.append(contentsOf: childIDs)
        }

        return result.sorted { $0.mergeRow < $1.mergeRow }
    }

    private static func makeEdges(
        commits: [CommitInfo],
        rowByID: [String: Int],
        identityByRootID: [String: String]
    ) -> [LinearBekGraphEdge] {
        commits.enumerated().flatMap { row, commit in
            commit.parentIds.enumerated().compactMap { parentIndex, parentID in
                let parentKey = "\(commit.repositoryPath ?? "")\u{1f}\(parentID)"
                guard let downRow = rowByID[identityByRootID[parentKey] ?? parentID] else { return nil }
                let toLane = commit.parentLanes.indices.contains(parentIndex)
                    ? commit.parentLanes[parentIndex]
                    : commits[downRow].lane
                return LinearBekGraphEdge(
                    upRow: row,
                    downRow: downRow,
                    fromLane: commit.lane,
                    toLane: toLane,
                    parentIndex: parentIndex
                )
            }
        }
    }

    private static func makeFragment(
        merge: CommitInfo,
        mergeRow: Int,
        commits: [CommitInfo],
        rowByID: [String: Int],
        identityByRootID: [String: String],
        mergeID: String,
        normalEdges: [LinearBekGraphEdge],
        layoutIndexByRow: [Int: Int]
    ) -> LinearBekMergeFragment? {
        let firstParentKey = "\(merge.repositoryPath ?? "")\u{1f}\(merge.parentIds[0])"
        let secondParentKey = "\(merge.repositoryPath ?? "")\u{1f}\(merge.parentIds[1])"
        guard
            let firstChildRow = rowByID[identityByRootID[firstParentKey] ?? merge.parentIds[0]],
            let secondChildRow = rowByID[identityByRootID[secondParentKey] ?? merge.parentIds[1]],
            firstChildRow != secondChildRow
        else { return nil }

        // LinearBek orders the two down nodes by graph row. The larger row is
        // the left child in the reference implementation and the smaller row
        // starts the fragment traversal. The traversal below mirrors
        // LinearBekGraphBuilder: it follows every normal down edge in row
        // order, allowing side merges and multiple tails instead of assuming
        // that the right branch is a single-parent chain.
        let leftChildRow = max(firstChildRow, secondChildRow)
        let rightChildRow = min(firstChildRow, secondChildRow)
        let normalEdgesByUp = Dictionary(grouping: normalEdges, by: \.upRow)
        var queue = normalEdgesByUp[rightChildRow] ?? []
        var tailRows = Set<Int>()
        var bodyRows = Set<Int>()
        var tailEdges = Set<LinearBekGraphEdge>()
        var mergeWithOldCommit = false
        var rowsCount = 1
        var blockSize = 1
        var magicSet: Set<Int>?

        func addTail(_ row: Int) {
            guard !bodyRows.contains(row) else { return }
            tailRows.insert(row)
        }

        func addTailEdge(_ edge: LinearBekGraphEdge) {
            guard !bodyRows.contains(edge.upRow) else { return }
            tailRows.insert(edge.upRow)
            tailEdges.insert(edge)
        }

        func calculateMagicSet(from row: Int) -> Set<Int> {
            var result = Set<Int>()
            var pending = (normalEdgesByUp[row] ?? []).compactMap { $0.downRow }
            var visited = Set<Int>()
            while !pending.isEmpty {
                pending.sort()
                let next = pending.removeFirst()
                guard next <= row + 30, visited.insert(next).inserted else { continue }
                result.insert(next)
                pending.append(contentsOf: (normalEdgesByUp[next] ?? []).compactMap { $0.downRow })
            }
            return result
        }

        while !queue.isEmpty {
            queue.sort {
                if $0.downRow == $1.downRow { return $0.upRow < $1.upRow }
                return $0.downRow < $1.downRow
            }
            let nextEdge = queue.removeFirst()
            let next = nextEdge.downRow
            let upRow = nextEdge.upRow

            if next == leftChildRow {
                addTail(upRow)
                mergeWithOldCommit = true
            } else if next == rightChildRow + rowsCount {
                rowsCount += 1
                blockSize += 1
                queue.append(contentsOf: normalEdgesByUp[next] ?? [])
                bodyRows.insert(upRow)
            } else if next > rightChildRow + rowsCount && next < leftChildRow {
                rowsCount = next - rightChildRow + 1
                blockSize += 1
                queue.append(contentsOf: normalEdgesByUp[next] ?? [])
                bodyRows.insert(upRow)
            } else if next > leftChildRow {
                let leftLayoutIndex = layoutIndexByRow[leftChildRow] ?? leftChildRow
                let rightLayoutIndex = layoutIndexByRow[rightChildRow] ?? rightChildRow
                let nextLayoutIndex = layoutIndexByRow[next] ?? next
                if leftLayoutIndex > rightLayoutIndex && !mergeWithOldCommit {
                    if next > leftChildRow + 30 { return nil }
                    if magicSet == nil { magicSet = calculateMagicSet(from: leftChildRow) }
                    if magicSet?.contains(next) == true {
                        addTailEdge(nextEdge)
                    } else {
                        return nil
                    }
                } else if (nextLayoutIndex > leftLayoutIndex && nextLayoutIndex < rightLayoutIndex)
                            || nextLayoutIndex == leftLayoutIndex {
                    addTailEdge(nextEdge)
                } else if next >= rightLayoutIndex {
                    // Once the right branch has already reached the left
                    // child, LinearBek permits another outgoing edge from
                    // that same tail. It is hidden together with the
                    // fragment and the tail receives the dotted replacement.
                    // This is the shape used by crossed/recursive tails in
                    // IntelliJ's graph tests; rejecting it would lose a
                    // valid fragment even though the topology is bounded.
                    if mergeWithOldCommit && tailRows.contains(upRow) {
                        addTailEdge(nextEdge)
                    } else {
                        return nil
                    }
                } else if next > leftChildRow + 30 {
                    if !tailEdges.contains(where: { $0.upRow == upRow }) && !bodyRows.contains(upRow) {
                        return nil
                    }
                } else {
                    if magicSet == nil { magicSet = calculateMagicSet(from: leftChildRow) }
                    if magicSet?.contains(next) == true {
                        addTailEdge(nextEdge)
                    } else {
                        return nil
                    }
                }
            }

            if blockSize >= 200 { return nil }
        }

        guard !tailRows.isEmpty,
              let mergeEdge = normalEdges.first(where: {
                  $0.upRow == mergeRow && $0.downRow == leftChildRow
              })
        else { return nil }

        let dottedEdges = tailRows.sorted().compactMap { tailRow -> LinearBekDottedEdge? in
            guard commits.indices.contains(tailRow) else { return nil }
            return LinearBekDottedEdge(
                mergeID: mergeID,
                upRow: tailRow,
                downRow: leftChildRow,
                fromLane: commits[tailRow].lane,
                toLane: mergeEdge.toLane
            )
        }
        guard !dottedEdges.isEmpty else { return nil }

        var hiddenEdges = tailEdges
        hiddenEdges.insert(mergeEdge)
        for dotted in dottedEdges {
            hiddenEdges.formUnion(normalEdges.filter {
                $0.upRow == dotted.upRow && $0.downRow == dotted.downRow
            })
        }
        let affectedRows = Set([mergeRow, leftChildRow, rightChildRow])
            .union(tailRows)
            .union(bodyRows)
        return LinearBekMergeFragment(
            mergeID: mergeID,
            mergeRow: mergeRow,
            leftChildRow: leftChildRow,
            rightChildRow: rightChildRow,
            affectedRows: affectedRows,
            hiddenEdges: hiddenEdges,
            tailRows: tailRows,
            bodyRows: bodyRows,
            tailEdges: tailEdges,
            mergeWithOldCommit: mergeWithOldCommit,
            dottedEdges: dottedEdges
        )
    }

    private static func simulateCollapsedState(
        fragments: [String: LinearBekMergeFragment],
        normalEdges: [LinearBekGraphEdge],
        collapsedMergeIDs: Set<String>
    ) -> (hiddenNormalEdges: Set<LinearBekGraphEdge>, dottedEdges: [LinearBekDottedEdge]) {
        var hiddenNormalEdges = Set<LinearBekGraphEdge>()
        var dottedEdges = Set<LinearBekDottedEdge>()

        let normalEdge = { (upRow: Int, downRow: Int) -> LinearBekGraphEdge? in
            normalEdges.first { $0.upRow == upRow && $0.downRow == downRow }
        }
        let dottedMatches = { (upRow: Int, downRow: Int) -> [LinearBekDottedEdge] in
            dottedEdges.filter { $0.upRow == upRow && $0.downRow == downRow }
        }
        let removeEdge = { (edge: LinearBekGraphEdge) in
            let existingDotted = dottedMatches(edge.upRow, edge.downRow)
            if !existingDotted.isEmpty {
                dottedEdges.subtract(existingDotted)
            } else {
                hiddenNormalEdges.insert(edge)
            }
        }
        let addDotted = { (edge: LinearBekDottedEdge) in
            // A collapsed outer fragment can replace the dotted continuation
            // emitted by an inner fragment at the same tail. Keep the latest
            // replacement, matching LinearBekGraph's hidden-edge recursion.
            dottedEdges = Set(dottedEdges.filter { $0.upRow != edge.upRow })
            dottedEdges.insert(edge)
        }

        // LinearBek collapses from the bottom of the permanent graph towards
        // the heads. That order matters: an outer fragment may replace an
        // already-dotted tail from a nested fragment, recursively hiding the
        // inner dotted edge.
        for fragment in fragments.values
            .filter({ collapsedMergeIDs.contains($0.mergeID) })
            .sorted(by: { $0.mergeRow > $1.mergeRow }) {
            for edge in fragment.tailEdges {
                removeEdge(edge)
            }
            for dotted in fragment.dottedEdges {
                if let existingNormal = normalEdge(dotted.upRow, dotted.downRow) {
                    hiddenNormalEdges.insert(existingNormal)
                }
                addDotted(dotted)
            }
            if let mergeEdge = normalEdge(fragment.mergeRow, fragment.leftChildRow) {
                removeEdge(mergeEdge)
            }
        }

        return (
            hiddenNormalEdges,
            dottedEdges.sorted {
                if $0.upRow == $1.upRow { return $0.downRow < $1.downRow }
                return $0.upRow < $1.upRow
            }
        )
    }

    /// `GraphLayoutImpl` assigns one layout index to a DFS lane until the
    /// lane terminates, then advances to the next layout index. The Rust log
    /// payload already supplies drawing lanes, but not IntelliJ's permanent
    /// graph layout index, so reconstruct the same stable index from the
    /// normal commit graph before building LinearBek fragments.
    private static func makeLayoutIndexes(
        commits: [CommitInfo],
        normalEdges: [LinearBekGraphEdge]
    ) -> [Int: Int] {
        let edgesByUp = Dictionary(grouping: normalEdges, by: \.upRow)
        let incomingRows = Set(normalEdges.map(\.downRow))
        let heads = commits.indices.filter { !incomingRows.contains($0) }
        var layoutIndexes: [Int: Int] = [:]
        var nextLayoutIndex = 1

        for head in heads where layoutIndexes[head] == nil {
            var stack = [head]
            while let current = stack.last {
                let firstVisit = layoutIndexes[current] == nil
                if firstVisit {
                    layoutIndexes[current] = nextLayoutIndex
                }

                let child = (edgesByUp[current] ?? [])
                    .sorted { $0.parentIndex < $1.parentIndex }
                    .map(\.downRow)
                    .first { layoutIndexes[$0] == nil }
                if let child {
                    stack.append(child)
                } else {
                    if firstVisit { nextLayoutIndex += 1 }
                    stack.removeLast()
                }
            }
        }

        // A paged or multi-root log may contain a row whose incoming edge is
        // outside the current page. Keep the fragment algorithm total for
        // that partial graph by assigning any remaining rows deterministically.
        for row in commits.indices where layoutIndexes[row] == nil {
            layoutIndexes[row] = nextLayoutIndex
            nextLayoutIndex += 1
        }
        return layoutIndexes
    }
}

struct LinearBekGraphActionAnswer: Equatable {
    let expandedMergeIDs: Set<String>
    let collapsedMergeIDs: Set<String>
    let highlightedElement: LinearBekGraphElement?
    let highlight: LinearBekGraphHighlight?
    let didChange: Bool
}

/// A small value-type equivalent of IntelliJ's LinearBekController. The
/// controller owns only the graph interaction state; commit data remains in
/// `LinearBekGraphModel`, which keeps this transition logic deterministic and
/// directly testable without rendering SwiftUI.
struct LinearBekGraphController {
    let graph: LinearBekGraphModel
    let collapseAll: Bool
    let expandedMergeIDs: Set<String>
    let collapsedMergeIDs: Set<String>

    init(
        commits: [CommitInfo],
        collapseAll: Bool,
        expandedMergeIDs: Set<String>,
        collapsedMergeIDs: Set<String>,
        identity: (CommitInfo) -> String = { $0.id }
    ) {
        self.collapseAll = collapseAll
        self.expandedMergeIDs = expandedMergeIDs
        self.collapsedMergeIDs = collapsedMergeIDs
        self.graph = LinearBekGraphModel(
            commits: commits,
            collapseAll: collapseAll,
            expandedMergeIDs: expandedMergeIDs,
            collapsedMergeIDs: collapsedMergeIDs,
            identity: identity
        )
    }

    func perform(_ action: LinearBekGraphAction) -> LinearBekGraphActionAnswer {
        switch action.type {
        case .buttonCollapse:
            return answer(
                expanded: collapseAll ? [] : expandedMergeIDs,
                collapsed: collapseAll ? [] : graph.mergeIDs,
                highlighted: nil
            )
        case .buttonExpand:
            return answer(
                expanded: collapseAll ? graph.mergeIDs : [],
                collapsed: collapseAll ? [] : [],
                highlighted: nil
            )
        case .mouseOver:
            let highlight = action.affectedElement.flatMap { graph.highlight(for: $0) }
            return answer(
                expanded: expandedMergeIDs,
                collapsed: collapsedMergeIDs,
                highlighted: highlight == nil ? nil : action.affectedElement,
                highlight: highlight
            )
        case .mouseClick:
            guard let element = action.affectedElement,
                  let rowAction = graph.action(for: element) else {
                return answer(
                    expanded: expandedMergeIDs,
                    collapsed: collapsedMergeIDs,
                    highlighted: nil
                )
            }
            return perform(rowAction: rowAction)
        }
    }

    func perform(rowAction: LinearBekRowAction) -> LinearBekGraphActionAnswer {
        var expanded = expandedMergeIDs
        var collapsed = collapsedMergeIDs
        switch rowAction {
        case let .collapse(mergeID):
            if collapseAll {
                expanded.remove(mergeID)
            } else {
                collapsed.insert(mergeID)
            }
        case let .expand(mergeID):
            if collapseAll {
                expanded.insert(mergeID)
            } else {
                collapsed.remove(mergeID)
            }
        }
        return answer(expanded: expanded, collapsed: collapsed, highlighted: nil)
    }

    private func answer(
        expanded: Set<String>,
        collapsed: Set<String>,
        highlighted: LinearBekGraphElement?,
        highlight: LinearBekGraphHighlight? = nil
    ) -> LinearBekGraphActionAnswer {
        LinearBekGraphActionAnswer(
            expandedMergeIDs: expanded,
            collapsedMergeIDs: collapsed,
            highlightedElement: highlighted,
            highlight: highlight,
            didChange: expanded != expandedMergeIDs || collapsed != collapsedMergeIDs
        )
    }
}

/// Git log 的图表列。它对应 IntelliJ 的 VcsLogGraphTable：
/// 图和提交信息是同一张可横向滚动的表，而不是一块固定宽度的装饰性 Canvas。
struct LogGraphView: View {
    let commits: [CommitInfo]
    @Binding var selection: String?
    @Binding var selectedIDs: Set<String>
    var commitIdentity: (CommitInfo) -> String = { $0.id }
    let compactReferences: Bool
    let showCommitColumns: Bool
    let showAuthorColumn: Bool
    let showDateColumn: Bool
    let showHashColumn: Bool
    let showRootColumn: Bool
    let showSignatureColumn: Bool
    let signatureStatuses: [String: CommitSignatureInfo]
    let signatureLoadingIDs: Set<String>
    let signatureFailedIDs: Set<String>
    let columnLayout: LogColumnLayout
    let showTagNames: Bool
    let alignLabels: Bool
    let showLongEdges: Bool
    let collapseGraph: Bool
    var graphCommand: LinearBekGraphCommand? = nil
    let highlightCherryPickedCommits: Bool
    var actionAvailability: LogActionAvailability = .permissive
    /// File History uses the narrower `Git.FileHistory.ContextMenu` action
    /// group. Keep it separate from the full VCS Log menu even though both
    /// views share the same graph/table renderer.
    var isFileHistory = false
    var onReachedEnd: () -> Void = {}
    var hasMore: Bool = false
    var isLoadingMore: Bool = false
    var pullRequestRemotesForCommit: (CommitInfo) -> [RemoteInfo] = { _ in [] }
    var onOpenPullRequest: (CommitInfo, RemoteInfo) -> Void = { _, _ in }
    var commentRemotesForCommit: (CommitInfo) -> [RemoteInfo] = { _ in [] }
    var onComment: (CommitInfo, RemoteInfo) -> Void = { _, _ in }
    var onCreateBranch: (CommitInfo) -> Void = { _ in }
    var onCreateTag: (CommitInfo) -> Void = { _ in }
    var onCherryPick: (CommitInfo) -> Void = { _ in }
    var onCherryPickSelected: ([CommitInfo]) -> Void = { _ in }
    var onRevert: (CommitInfo) -> Void = { _ in }
    var onRevertSelected: ([CommitInfo]) -> Void = { _ in }
    var onCheckout: (CommitInfo) -> Void = { _ in }
    var onReset: (CommitInfo) -> Void = { _ in }
    var onResetSelected: ([CommitInfo]) -> Void = { _ in }
    var onCompare: (CommitInfo) -> Void = { _ in }
    var currentBranchNameForCommit: (CommitInfo) -> String? = { _ in nil }
    var onReferenceAction: (CommitInfo, LogReferenceActionTarget, LogReferenceAction) -> Void = { _, _, _ in }
    var onRebaseOntoCommit: (CommitInfo) -> Void = { _ in }
    var onInteractiveRebase: (CommitInfo) -> Void = { _ in }
    var onCreateAutoSquashCommit: (CommitInfo, AutoSquashCommitKind) -> Void = { _, _ in }
    var onRewriteCommit: (CommitInfo, RebaseTodoAction) -> Void = { _, _ in }
    var onRewriteSelected: ([CommitInfo], RebaseTodoAction) -> Void = { _, _ in }
    var onPushUpToCommit: (CommitInfo) -> Void = { _ in }
    var onAddCommitsToRemoteBranch: ([CommitInfo]) -> Void = { _ in }
    var highlightedCherryPickedCommitIDs: Set<String> = []
    var cherryPickComparisonReady = false
    var hostedRemotesForCommit: (CommitInfo) -> [RemoteInfo] = { _ in [] }
    var onBrowseHostedRevision: (CommitInfo, RemoteInfo) -> Void = { _, _ in }
    var onBrowseRevision: (CommitInfo) -> Void = { _ in }
    var onCopyRevisionLink: (CommitInfo, RemoteInfo) -> Void = { _, _ in }
    var onUncommit: (CommitInfo) -> Void = { _ in }
    var onColumnOrderChanged: ([LogColumnID]) -> Void = { _ in }
    var onColumnWidthChanged: (LogColumnID, CGFloat) -> Void = { _, _ in }
    @State private var expandedLinearBekMergeIDs: Set<String> = []
    @State private var collapsedLinearBekMergeIDs: Set<String> = []
    @State private var hoveredLinearBekElement: LinearBekGraphElement?
    @State private var hoveredLinearBekHighlight: LinearBekGraphHighlight?
    @State private var resizingColumn: LogColumnID?
    @State private var resizeStartWidth: CGFloat?

    // Rebased keeps the log dense enough to scan dozens of commits at once.
    // The old 58pt rows made the graph look like a card list and diverged
    // visibly from the reference workspace.
    private let rowHeight: CGFloat = 31
    // Rebased keeps a real graph gutter in front of the commit table. It is
    // deliberately wide enough for merge-heavy histories: collapsing this
    // column to a tiny decoration makes all branches look like one line and
    // also puts the filter controls in the wrong visual column.
    // IntelliJ's graph column grows with the permanent graph. Capping it at
    // 180pt collapses merge-heavy histories into an apparent single line and
    // makes the commit text start on top of the lanes. Keep enough room for
    // the dense histories used by rebased; the surrounding table remains
    // horizontally scrollable when a repository has even more active lanes.
    private let laneWidth: CGFloat = 18
    private let maximumGraphWidth: CGFloat = 360
    private let minimumCommitColumnWidth: CGFloat = 276
    private let preferredTableWidth: CGFloat = 720
    private let columnHeaderHeight: CGFloat = 28

    private enum RefKind {
        case head
        case local
        case tag
        case remote

        var foreground: Color {
            switch self {
            case .head: .white
            case .local: .orange
            case .tag: .green
            case .remote: .blue
            }
        }

        var background: Color {
            switch self {
            case .head: .blue.opacity(0.78)
            case .local: .orange.opacity(0.16)
            case .tag: .green.opacity(0.16)
            case .remote: .blue.opacity(0.16)
            }
        }

        var border: Color {
            switch self {
            case .head: .blue.opacity(0.95)
            case .local: .orange.opacity(0.36)
            case .tag: .green.opacity(0.36)
            case .remote: .blue.opacity(0.36)
            }
        }
    }

    @ViewBuilder
    private func fileHistoryContextMenu(for commit: CommitInfo) -> some View {
        let hasSingleLogSelection = selectedIDs.count <= 1
        let contextSelectionCount = max(selectedIDs.count, 1)
        let selectedCommits = commits.filter { selectedIDs.contains(commitIdentity($0)) }
        let commitsForRevert = selectedCommits.count > 1 ? selectedCommits : [commit]
        if selectedCommits.count > 1, selectedIDs.contains(commitIdentity(commit)) {
            Button("Revert Selected Commits") {
                onRevertSelected(commitsForRevert)
            }
            .disabled(
                commitsForRevert.contains { $0.parentIds.count != 1 }
                    || !actionAvailability.allowsMutation(for: commitsForRevert)
            )
        } else {
            Button("Revert Commit") { onRevert(commit) }
                .disabled(
                    commit.parentIds.count != 1
                        || !actionAvailability.allowsMutation(for: [commit])
                )
        }
        Button("Create Fixup Commit…") { onCreateAutoSquashCommit(commit, .fixup) }
            .disabled(
                !hasSingleLogSelection
                    || !actionAvailability.hasLocalChanges
                    || !isLogRewriteActionAvailable(for: commit, action: .fixup)
                    || !actionAvailability.allowsHistoryRewrite(for: [commit])
            )
        Button("Create Squash Commit…") { onCreateAutoSquashCommit(commit, .squash) }
            .disabled(
                !hasSingleLogSelection
                    || !actionAvailability.hasLocalChanges
                    || !isLogRewriteActionAvailable(for: commit, action: .squash)
                    || !actionAvailability.allowsHistoryRewrite(for: [commit])
            )
        Divider()
        Button("Create Tag at Commit…") { onCreateTag(commit) }
            .disabled(!isLogSingleCommitActionAvailable(
                selectionCount: contextSelectionCount,
                for: commit
            ))
    }

    private struct RefLabel: Identifiable {
        let id: String
        let title: String
        let kind: RefKind
    }

    private var maxLane: Int {
        commits.reduce(0) { result, commit in
            let ownLane = Int(commit.lane)
            let parentLane = commit.parentLanes.map(Int.init).max() ?? 0
            return max(result, ownLane, parentLane)
        }
    }

    /// 留出左右边距，lane 数增多时只在极端历史上轻微压缩 lane 间距。
    private var graphWidth: CGFloat {
        min(
            maximumGraphWidth,
            max(120, CGFloat(maxLane + 1) * effectiveLaneWidth + 28)
        )
    }

    private var effectiveLaneWidth: CGFloat {
        max(
            8,
            min(laneWidth, (maximumGraphWidth - 32) / CGFloat(maxLane + 1))
        )
    }

    private var renderRange: Range<Int> {
        0..<commits.count
    }

    var body: some View {
        // Resolve graph metrics once per graph update. Reading the computed
        // graphWidth from every row makes SwiftUI reduce the entire commit
        // list once per row, which is very noticeable on a large history.
        let linearBekController = LinearBekGraphController(
            commits: commits,
            collapseAll: collapseGraph,
            expandedMergeIDs: expandedLinearBekMergeIDs,
            collapsedMergeIDs: collapsedLinearBekMergeIDs,
            identity: commitIdentity
        )
        let linearBekGraph = linearBekController.graph
        // LinearBek collapses edges, not the graph column. The gutter remains
        // interactive so a merge node or dotted edge can be restored.
        let layoutGraphWidth = graphWidth
        let layoutGraphHeight = max(rowHeight, CGFloat(commits.count) * rowHeight)

        // A ScrollView directly inside the resizable tool window can be
        // measured with an unbounded height. In that case SwiftUI lays out
        // the content, but the viewport itself ends up outside the visible
        // tool-window region. Give it a real viewport first, then let the
        // history content scroll inside it.
        GeometryReader { viewport in
            // The reference log is one horizontally scrollable table. The
            // table must at least fill the visible graph workspace so the
            // selection highlight, row hit target, and commit column reach
            // the graph/details divider instead of stopping at an arbitrary
            // fixed width.
            let visibleColumns = columnLayout.visibleOrder(
                showAuthor: showAuthorColumn || showCommitColumns,
                showDate: showDateColumn || showCommitColumns,
                showHash: showHashColumn,
                showRoot: showRootColumn,
                showSignature: showSignatureColumn
            )
            let dynamicColumnWidth = visibleColumns
                .filter { $0 != .commit }
                .reduce(CGFloat.zero) { $0 + columnLayout.width(for: $1) }
            let configuredCommitWidth = max(
                minimumCommitColumnWidth,
                columnLayout.width(for: .commit)
            )
            let layoutCommitColumnWidth = max(
                configuredCommitWidth,
                viewport.size.width - layoutGraphWidth - dynamicColumnWidth - 24
            )
            let layoutContentWidth = max(
                viewport.size.width,
                preferredTableWidth,
                layoutGraphWidth + layoutCommitColumnWidth + dynamicColumnWidth + 24
            )
            // Keep the deterministic pagination fallback inside the
            // scrollable content. The old height ended at the last row and
            // clipped the button below the LazyVStack.
            let layoutContentHeight = layoutGraphHeight + (hasMore ? 36 : 0)
            let verticalViewportHeight = max(0, viewport.size.height - columnHeaderHeight)

            ScrollView(.horizontal, showsIndicators: true) {
                VStack(spacing: 0) {
                    logColumnHeader(
                        graphWidth: layoutGraphWidth,
                        commitColumnWidth: layoutCommitColumnWidth,
                        contentWidth: layoutContentWidth,
                        visibleColumns: visibleColumns
                    )

                    ScrollView(.vertical) {
                        ZStack(alignment: .topLeading) {
                            Canvas { context, _ in
                                drawGraph(
                                    context: &context,
                                    size: CGSize(width: layoutGraphWidth, height: layoutGraphHeight),
                                    rows: renderRange,
                                    graph: linearBekGraph,
                                    highlight: hoveredLinearBekHighlight
                                )
                            }
                            .frame(width: layoutGraphWidth, height: layoutGraphHeight)
                            .allowsHitTesting(false)

                            LazyVStack(spacing: 0) {
                                ForEach(commits.indices, id: \.self) { index in
                                    graphRow(
                                        index: index,
                                        commit: commits[index],
                                        graphWidth: layoutGraphWidth,
                                        commitColumnWidth: layoutCommitColumnWidth,
                                        contentWidth: layoutContentWidth,
                                        visibleColumns: visibleColumns,
                                        showTagNames: showTagNames,
                                        alignLabels: alignLabels,
                                        linearBekGraph: linearBekGraph,
                                        linearBekController: linearBekController
                                    )
                                    .onAppear {
                                        // Rebased fetches the next log block as
                                        // the last visible row enters the lazy
                                        // list. Keep the button below as a
                                        // deterministic fallback for keyboard
                                        // navigation and accessibility clients.
                                        if index == commits.count - 1,
                                           hasMore,
                                           !isLoadingMore {
                                            onReachedEnd()
                                        }
                                    }
                                }
                                if hasMore {
                                    HStack {
                                        Spacer()
                                        Button {
                                            onReachedEnd()
                                        } label: {
                                            if isLoadingMore {
                                                ProgressView()
                                                    .controlSize(.small)
                                            } else {
                                                Text("加载更多提交")
                                            }
                                        }
                                        .buttonStyle(.borderless)
                                        .disabled(isLoadingMore)
                                        Spacer()
                                    }
                                    .frame(width: layoutContentWidth, height: 36)
                                }
                            }

                            linearBekEdgeHitTargets(
                                graph: linearBekGraph,
                                controller: linearBekController,
                                rows: renderRange,
                                graphWidth: layoutGraphWidth,
                                height: layoutGraphHeight
                            )

                            linearBekNodeHitTargets(
                                graph: linearBekGraph,
                                controller: linearBekController,
                                rows: renderRange,
                                graphWidth: layoutGraphWidth,
                                height: layoutGraphHeight
                            )
                        }
                        .frame(width: layoutContentWidth, height: layoutContentHeight, alignment: .topLeading)
                    }
                    .frame(width: layoutContentWidth, height: verticalViewportHeight)
                }
                .frame(width: layoutContentWidth, height: viewport.size.height, alignment: .top)
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .onChange(of: commits.map(\.id)) { _, _ in
            hoveredLinearBekHighlight = nil
            hoveredLinearBekElement = nil
            let mergeIDs = Set(commits.filter { $0.parentIds.count == 2 }.map(\.id))
            expandedLinearBekMergeIDs.formIntersection(mergeIDs)
            collapsedLinearBekMergeIDs.formIntersection(mergeIDs)
        }
        .onChange(of: collapseGraph) { _, _ in
            // The menu toggle is the product's global Collapse Graph action.
            // Do not resurrect stale per-fragment state when the user turns
            // that global mode off again; IntelliJ's Expand All action leaves
            // the graph fully expanded.
            expandedLinearBekMergeIDs.removeAll()
            collapsedLinearBekMergeIDs.removeAll()
            hoveredLinearBekHighlight = nil
            hoveredLinearBekElement = nil
        }
        .onChange(of: graphCommand) { _, command in
            guard let command else { return }
            let controller = LinearBekGraphController(
                commits: commits,
                collapseAll: collapseGraph,
                expandedMergeIDs: expandedLinearBekMergeIDs,
                collapsedMergeIDs: collapsedLinearBekMergeIDs,
                identity: commitIdentity
            )
            let answer = controller.perform(
                LinearBekGraphAction(
                    type: command.action,
                    affectedElement: nil
                )
            )
            expandedLinearBekMergeIDs = answer.expandedMergeIDs
            collapsedLinearBekMergeIDs = answer.collapsedMergeIDs
            hoveredLinearBekHighlight = nil
            hoveredLinearBekElement = nil
        }
    }

    private func logColumnHeader(
        graphWidth: CGFloat,
        commitColumnWidth: CGFloat,
        contentWidth: CGFloat,
        visibleColumns: [LogColumnID]
    ) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: graphWidth)
            HStack(spacing: 6) {
                ForEach(visibleColumns) { column in
                    logColumnHeaderCell(
                        column,
                        width: column == .commit ? commitColumnWidth : columnLayout.width(for: column)
                    )
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(width: contentWidth, height: columnHeaderHeight, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func logColumnHeaderCell(_ column: LogColumnID, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(column.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: column == .date || column == .hash ? .trailing : .leading)
                .contentShape(Rectangle())
                .draggable(column.rawValue)

            Rectangle()
                .fill(Color.clear)
                .frame(width: 8)
                .contentShape(Rectangle())
                .allowsHitTesting(column.isResizable)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            guard column.isResizable else { return }
                            if resizingColumn != column {
                                resizingColumn = column
                                resizeStartWidth = width
                            }
                            let start = resizeStartWidth ?? width
                            onColumnWidthChanged(column, max(column.minimumWidth, start + value.translation.width))
                        }
                        .onEnded { _ in
                            resizingColumn = nil
                            resizeStartWidth = nil
                        }
                )
        }
        .frame(width: width, height: columnHeaderHeight)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.secondary.opacity(0.24))
                .frame(width: 1, height: 16)
                .allowsHitTesting(false)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let rawValue = items.first,
                  let source = LogColumnID(rawValue: rawValue),
                  source != column else { return false }
            onColumnOrderChanged(columnLayout.moving(source, before: column).order)
            return true
        }
    }

    @ViewBuilder
    private func graphRow(
        index: Int,
        commit: CommitInfo,
        graphWidth: CGFloat,
        commitColumnWidth: CGFloat,
        contentWidth: CGFloat,
        visibleColumns: [LogColumnID],
        showTagNames: Bool,
        alignLabels: Bool,
        linearBekGraph: LinearBekGraphModel,
        linearBekController: LinearBekGraphController
    ) -> some View {
        let identity = commitIdentity(commit)
        let isCherryPicked = isCherryPickedCommitHighlighted(
            highlightingEnabled: highlightCherryPickedCommits,
            comparisonReady: cherryPickComparisonReady,
            identity: identity,
            highlightedCommitIDs: highlightedCherryPickedCommitIDs
        )
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: graphWidth)
                HStack(spacing: 6) {
                    ForEach(visibleColumns) { column in
                        logColumnView(
                            column,
                            commit: commit,
                            commitWidth: commitColumnWidth,
                            showTagNames: showTagNames,
                            alignLabels: alignLabels
                        )
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(width: contentWidth, height: rowHeight, alignment: .leading)

            // IntelliJ treats the graph and commit summary as one table row.
            // Keep exactly one selection gesture for the whole row. The old
            // split implementation had an `onTapGesture` on the summary plus
            // a transparent Button over the graph; Cmd-clicking a lane could
            // therefore toggle the same commit twice and cancel the selection.
            Button {
                select(commit)
            } label: {
                Color.clear
                    .frame(width: contentWidth, height: rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择提交 \(commit.shortId)")

            if let action = linearBekGraph.rowAction(at: index) {
                Button {
                    applyLinearBekAction(action, controller: linearBekController)
                } label: {
                    Image(systemName: action.isCollapse ? "chevron.down.circle.fill" : "chevron.up.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: graphWidth, height: rowHeight, alignment: .center)
                }
                .buttonStyle(.plain)
                .help(action.isCollapse ? "Collapse linear branch" : "Expand collapsed branch")
                .accessibilityLabel(action.isCollapse ? "Collapse linear branch" : "Expand collapsed branch")
            }
        }
        .frame(width: contentWidth, height: rowHeight, alignment: .leading)
        .background(
            selectedIDs.contains(identity)
                ? Color.accentColor.opacity(0.14)
                : isCherryPicked ? Color.purple.opacity(0.13) : Color.clear
        )
        .overlay(alignment: .leading) {
            if isCherryPicked {
                Capsule()
                    .fill(Color.purple.opacity(0.8))
                    .frame(width: 3, height: rowHeight - 8)
                    .padding(.leading, 2)
                    .help("Cherry-picked commit")
                    .allowsHitTesting(false)
            }
        }
        .contextMenu {
            if isFileHistory {
                fileHistoryContextMenu(for: commit)
            } else {
            let hasSingleLogSelection = selectedIDs.count <= 1
            // A row context menu can open before the table publishes the row
            // selection. IntelliJ's VCS Log still supplies the contextual row
            // as the single commit in that case.
            let contextSelectionCount = max(selectedIDs.count, 1)
            let currentBranchName = hasSingleLogSelection
                ? currentBranchNameForCommit(commit)
                : nil
            let checkoutBranchTargets = hasSingleLogSelection
                ? logCheckoutBranchTargets(
                    for: commit,
                    currentBranchName: currentBranchName
                )
                : []
            let checkoutRevisionAvailable = hasSingleLogSelection
                && logReferenceRootPath(for: commit) != nil
                && actionAvailability.allowsMutation(for: [commit])
            Button("View Commit Details") { select(commit, modifiers: []) }
            Button("Copy Commit ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.id, forType: .string)
            }
            Button("Copy Commit Message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.summary, forType: .string)
            }
            Button("Create Branch from Commit") { onCreateBranch(commit) }
                .disabled(!isLogSingleCommitActionAvailable(
                    selectionCount: contextSelectionCount,
                    for: commit
                ))
            Button("Create Tag at Commit…") { onCreateTag(commit) }
                .disabled(!isLogSingleCommitActionAvailable(
                    selectionCount: contextSelectionCount,
                    for: commit
                ))
            if hasSingleLogSelection {
                let referenceTargets = logReferenceActionTargets(
                    for: commit,
                    currentBranchName: currentBranchName
                )
                let branchTargets = referenceTargets.filter { $0.kind != .tag }
                let tagTargets = referenceTargets.filter { $0.kind == .tag }
                let referenceActionsRoutable = logReferenceRootPath(for: commit) != nil
                let referenceMutationAvailable = referenceActionsRoutable
                    && actionAvailability.allowsMutation(for: [commit])
                let referenceHistoryRewriteAvailable = referenceActionsRoutable
                    && actionAvailability.allowsHistoryRewrite(for: [commit])
                if !branchTargets.isEmpty || !tagTargets.isEmpty {
                    Divider()
                }
                if !branchTargets.isEmpty {
                    Menu("Branches") {
                        ForEach(branchTargets) { target in
                            Menu(target.name) {
                                Button("Checkout") {
                                    onReferenceAction(commit, target, .checkout)
                                }
                                .disabled(!referenceMutationAvailable)
                                if target.kind == .local {
                                    Button("Checkout and Update") {
                                        onReferenceAction(commit, target, .checkoutAndUpdate)
                                    }
                                    .disabled(!referenceMutationAvailable)
                                }
                                Button("Checkout with Rebase") {
                                    onReferenceAction(commit, target, .checkoutWithRebase)
                                }
                                .disabled(!referenceMutationAvailable)
                                Button("Checkout as New Branch…") {
                                    onCreateBranch(commit)
                                }
                                .disabled(!referenceMutationAvailable)
                                Divider()
                                Button("Compare with Current…") {
                                    onReferenceAction(commit, target, .compare)
                                }
                                .disabled(!referenceActionsRoutable)
                                Button("Show Diff with Working Tree") {
                                    onReferenceAction(commit, target, .showDiff)
                                }
                                .disabled(!referenceActionsRoutable)
                                Divider()
                                Button("Rebase Current onto…") {
                                    onReferenceAction(commit, target, .rebase)
                                }
                                .disabled(!referenceHistoryRewriteAvailable)
                                Button("Merge into Current…") {
                                    onReferenceAction(commit, target, .merge)
                                }
                                .disabled(!referenceMutationAvailable)
                                if target.kind == .local {
                                    Divider()
                                    Button("Update") {
                                        onReferenceAction(commit, target, .update)
                                    }
                                    .disabled(!referenceMutationAvailable)
                                    Button("Push…") {
                                        onReferenceAction(commit, target, .push)
                                    }
                                    .disabled(!referenceMutationAvailable)
                                    Divider()
                                    Button("Rename…") {
                                        onReferenceAction(commit, target, .rename)
                                    }
                                    .disabled(!referenceMutationAvailable)
                                } else {
                                    Divider()
                                    Button("Pull with Merge") {
                                        onReferenceAction(commit, target, .pullMerge)
                                    }
                                    .disabled(!referenceMutationAvailable)
                                    Button("Pull with Rebase") {
                                        onReferenceAction(commit, target, .pullRebase)
                                    }
                                    .disabled(!referenceMutationAvailable)
                                }
                                Button("Delete", role: .destructive) {
                                    onReferenceAction(commit, target, .delete)
                                }
                                .disabled(!referenceMutationAvailable)
                            }
                        }
                    }
                } else if referenceActionsRoutable {
                    Button("Rebase Current onto Selected Commit…") {
                        onRebaseOntoCommit(commit)
                    }
                    .disabled(
                        !isLogRebaseOntoSelectedCommitAvailable(
                            selectionCount: contextSelectionCount,
                            for: commit,
                            currentBranchName: currentBranchNameForCommit(commit)
                        ) || !referenceHistoryRewriteAvailable
                    )
                }
                if !tagTargets.isEmpty {
                    Menu("Tags") {
                        ForEach(tagTargets) { target in
                            Menu(target.name) {
                                Button("Merge into Current…") {
                                    onReferenceAction(commit, target, .merge)
                                }
                                .disabled(!referenceMutationAvailable)
                                Button("Delete Tag", role: .destructive) {
                                    onReferenceAction(commit, target, .delete)
                                }
                                .disabled(!referenceMutationAvailable)
                            }
                        }
                    }
                }
            }
            if checkoutBranchTargets.isEmpty {
                Button("Checkout Revision \(commit.shortId)") {
                    onCheckout(commit)
                }
                .disabled(!checkoutRevisionAvailable)
            } else {
                Menu("Checkout") {
                    ForEach(checkoutBranchTargets) { target in
                        Button(target.name) {
                            onReferenceAction(commit, target, .checkout)
                        }
                        .disabled(!checkoutRevisionAvailable)
                    }
                    Divider()
                    Button("Checkout Revision \(commit.shortId)") {
                        onCheckout(commit)
                    }
                    .disabled(!checkoutRevisionAvailable)
                }
            }
            Divider()
            Button("Cherry-pick") { onCherryPick(commit) }
                .disabled(!actionAvailability.allowsMutation(for: [commit]))
            Button("Revert Commit") { onRevert(commit) }
                .disabled(
                    commit.parentIds.count != 1
                        || !actionAvailability.allowsMutation(for: [commit])
                )
            if selectedIDs.count > 1, selectedIDs.contains(identity) {
                let selectedCommits = commits.filter { selectedIDs.contains(commitIdentity($0)) }
                Button("Cherry-pick Selected Commits") {
                    onCherryPickSelected(selectedCommits)
                }
                .disabled(!actionAvailability.allowsMutation(for: selectedCommits))
                Button("Revert Selected Commits") {
                    onRevertSelected(selectedCommits)
                }
                .disabled(
                    selectedCommits.contains { $0.parentIds.count != 1 }
                        || !actionAvailability.allowsMutation(for: selectedCommits)
                )
            }
            Button("Reset Current Branch to Here…") { onReset(commit) }
                .disabled(!actionAvailability.allowsMutation(for: [commit]))
            if selectedIDs.count > 1, selectedIDs.contains(identity) {
                let selectedCommits = commits.filter { selectedIDs.contains(commitIdentity($0)) }
                Button("Reset Selected Revisions…") {
                    onResetSelected(selectedCommits)
                }
                .disabled(
                    !isResetSelectionAvailable(for: selectedCommits)
                        || !actionAvailability.allowsMutation(for: selectedCommits)
                )
            }
            Button("Compare with Current…") { onCompare(commit) }
            Divider()
            Button("Interactive Rebase from Here…") { onInteractiveRebase(commit) }
                .disabled(
                    !hasSingleLogSelection
                        || !isInteractiveRebaseAvailable(for: commit)
                        || !actionAvailability.allowsHistoryRewrite(for: [commit])
                )
            Divider()
            Button("Reword Commit…") { onRewriteCommit(commit, .reword) }
                .disabled(
                    !hasSingleLogSelection
                        || !isLogRewriteActionAvailable(for: commit, action: .reword)
                        || !actionAvailability.allowsHistoryRewrite(for: [commit])
                )
            Button("Create Fixup Commit…") { onCreateAutoSquashCommit(commit, .fixup) }
                .disabled(
                    !hasSingleLogSelection
                        || !actionAvailability.hasLocalChanges
                        || !isLogRewriteActionAvailable(for: commit, action: .fixup)
                        || !actionAvailability.allowsHistoryRewrite(for: [commit])
                )
            Button("Create Squash Commit…") { onCreateAutoSquashCommit(commit, .squash) }
                .disabled(
                    !hasSingleLogSelection
                        || !actionAvailability.hasLocalChanges
                        || !isLogRewriteActionAvailable(for: commit, action: .squash)
                        || !actionAvailability.allowsHistoryRewrite(for: [commit])
                )
            Button("Rewrite Selected Commit as Fixup…") { onRewriteCommit(commit, .fixup) }
                .disabled(
                    !hasSingleLogSelection
                        || !isLogRewriteActionAvailable(for: commit, action: .fixup)
                        || !actionAvailability.allowsHistoryRewrite(for: [commit])
                )
            Button("Rewrite Selected Commit as Squash…") { onRewriteCommit(commit, .squash) }
                .disabled(
                    !hasSingleLogSelection
                        || !isLogRewriteActionAvailable(for: commit, action: .squash)
                        || !actionAvailability.allowsHistoryRewrite(for: [commit])
                )
            Button("Drop Commit…", role: .destructive) { onRewriteCommit(commit, .drop) }
                .disabled(
                    !hasSingleLogSelection
                        || !isLogRewriteActionAvailable(for: commit, action: .drop)
                        || !actionAvailability.allowsHistoryRewrite(for: [commit])
                )
            if selectedIDs.count > 1, selectedIDs.contains(identity) {
                let selectedCommits = commits.filter { selectedIDs.contains(commitIdentity($0)) }
                let batchRewriteAvailable = areLogRewriteSelectionActionsAvailable(for: selectedCommits)
                    && actionAvailability.allowsSingleRootHistoryRewrite(for: selectedCommits)
                Divider()
                Button("Reword Selected Commits…") {
                    onRewriteSelected(selectedCommits, .reword)
                }
                .disabled(!batchRewriteAvailable)
                Button("Squash Selected Commits…") {
                    onRewriteSelected(selectedCommits, .squash)
                }
                .disabled(!batchRewriteAvailable)
                Button("Drop Selected Commits…", role: .destructive) {
                    onRewriteSelected(selectedCommits, .drop)
                }
                .disabled(!batchRewriteAvailable)
            }
            Divider()
            Button("Push Up to Commit…") { onPushUpToCommit(commit) }
                .disabled(
                    !hasSingleLogSelection
                        || !actionAvailability.allowsMutation(for: [commit])
                )
            let selectedCommitsForRemoteBranch = selectedIDs.contains(identity)
                ? commits.filter { selectedIDs.contains(commitIdentity($0)) }
                : [commit]
            Button("Add Commits to Remote Branch…") {
                onAddCommitsToRemoteBranch(selectedCommitsForRemoteBranch)
            }
            .disabled(
                !isAddCommitsToRemoteBranchAvailable(for: selectedCommitsForRemoteBranch)
                    || !actionAvailability.allowsAddCommitsToRemote(for: selectedCommitsForRemoteBranch)
            )
            Button("Browse Repository at Revision") { onBrowseRevision(commit) }
            let hostedRemotes = hostedRemotesForCommit(commit)
            switch hostedRemoteActionPresentation(for: hostedRemotes.count) {
            case .direct where hostedRemotes.count == 1:
                let remote = hostedRemotes[0]
                Button("Open in Browser") { onBrowseHostedRevision(commit, remote) }
                Button("Copy Repository Link") { onCopyRevisionLink(commit, remote) }
            case .submenu:
                Menu("Open in Browser") {
                    ForEach(hostedRemotes, id: \.name) { remote in
                        Button(remote.name) {
                            onBrowseHostedRevision(commit, remote)
                        }
                    }
                }
                Menu("Copy Repository Link") {
                    ForEach(hostedRemotes, id: \.name) { remote in
                        Button(remote.name) {
                            onCopyRevisionLink(commit, remote)
                        }
                    }
                }
            case .direct, .hidden:
                EmptyView()
            }
            if commit.isHead {
                Divider()
                Button("Undo Latest Commit…", role: .destructive) { onUncommit(commit) }
                    .disabled(
                        !hasSingleLogSelection
                            || !isUncommitActionAvailable(for: commit)
                            || !actionAvailability.allowsMutation(for: [commit])
                    )
            }
            Divider()
            let pullRequestRemotes = pullRequestRemotesForCommit(commit)
            switch hostedRemoteActionPresentation(for: pullRequestRemotes.count) {
            case .direct where pullRequestRemotes.count == 1:
                Button("Open Pull Requests") {
                    onOpenPullRequest(commit, pullRequestRemotes[0])
                }
            case .submenu:
                Menu("Open Pull Requests") {
                    ForEach(pullRequestRemotes, id: \.name) { remote in
                        Button(remote.name) {
                            onOpenPullRequest(commit, remote)
                        }
                    }
                }
            case .direct, .hidden:
                EmptyView()
            }
            let commentRemotes = commentRemotesForCommit(commit)
            switch hostedRemoteActionPresentation(for: commentRemotes.count) {
            case .direct where commentRemotes.count == 1:
                Button("Comment this commit") {
                    onComment(commit, commentRemotes[0])
                }
            case .submenu:
                Menu("Comment this commit") {
                    ForEach(commentRemotes, id: \.name) { remote in
                        Button(remote.name) {
                            onComment(commit, remote)
                        }
                    }
                }
            case .direct, .hidden:
                EmptyView()
            }
            }
        }
    }

    @ViewBuilder
    private func linearBekNodeHitTargets(
        graph: LinearBekGraphModel,
        controller: LinearBekGraphController,
        rows: Range<Int>,
        graphWidth: CGFloat,
        height: CGFloat
    ) -> some View {
        ZStack {
            ForEach(rows.filter { graph.nodeAction(at: $0) != nil }, id: \.self) { row in
                let element = LinearBekGraphElement.node(row)
                Circle()
                    .fill(Color.clear)
                    .frame(width: 18, height: 18)
                    .contentShape(Circle())
                    .position(point(lane: commits[row].lane, row: row))
                    .onHover { isHovering in
                        updateHoveredLinearBekElement(
                            element,
                            isHovering: isHovering,
                            controller: controller
                        )
                    }
                    .onTapGesture {
                        applyLinearBekAction(
                            graph.action(for: element),
                            controller: controller
                        )
                    }
            }
        }
        .frame(width: graphWidth, height: height)
    }

    @ViewBuilder
    private func linearBekEdgeHitTargets(
        graph: LinearBekGraphModel,
        controller: LinearBekGraphController,
        rows: Range<Int>,
        graphWidth: CGFloat,
        height: CGFloat
    ) -> some View {
        ZStack {
            ForEach(graph.visibleEdges.filter { rows.contains($0.upRow) && rows.contains($0.downRow) }, id: \.self) { edge in
                graphEdgeHitTarget(
                    element: .normal(edge),
                    start: point(lane: edge.fromLane, row: edge.upRow),
                    target: point(lane: edge.toLane, row: edge.downRow),
                    graph: graph,
                    controller: controller
                )
            }
            ForEach(graph.dottedEdges.filter { rows.contains($0.upRow) && rows.contains($0.downRow) }, id: \.self) { edge in
                graphEdgeHitTarget(
                    element: .dotted(edge),
                    start: point(lane: edge.fromLane, row: edge.upRow),
                    target: point(lane: edge.toLane, row: edge.downRow),
                    graph: graph,
                    controller: controller
                )
            }
        }
        .frame(width: graphWidth, height: height)
    }

    private func graphEdgeHitTarget(
        element: LinearBekGraphElement,
        start: CGPoint,
        target: CGPoint,
        graph: LinearBekGraphModel,
        controller: LinearBekGraphController
    ) -> some View {
        let hitStyle = StrokeStyle(lineWidth: 14, lineCap: .round, lineJoin: .round)
        let path = graphEdgePath(start: start, target: target)
        return path
            .stroke(Color.clear, style: hitStyle)
            .contentShape(path.strokedPath(hitStyle))
            .onHover { isHovering in
                updateHoveredLinearBekElement(
                    element,
                    isHovering: isHovering,
                    controller: controller
                )
            }
            .onTapGesture {
                applyLinearBekAction(graph.action(for: element), controller: controller)
            }
    }

    private func updateHoveredLinearBekElement(
        _ element: LinearBekGraphElement,
        isHovering: Bool,
        controller: LinearBekGraphController
    ) {
        if isHovering {
            let answer = controller.perform(
                LinearBekGraphAction(type: .mouseOver, affectedElement: element)
            )
            hoveredLinearBekElement = element
            hoveredLinearBekHighlight = answer.highlight
        } else if hoveredLinearBekElement == element {
            hoveredLinearBekElement = nil
            hoveredLinearBekHighlight = nil
        }
    }

    private func applyLinearBekAction(
        _ action: LinearBekRowAction?,
        controller: LinearBekGraphController
    ) {
        guard let action else { return }
        let answer = controller.perform(rowAction: action)
        expandedLinearBekMergeIDs = answer.expandedMergeIDs
        collapsedLinearBekMergeIDs = answer.collapsedMergeIDs
    }

    @ViewBuilder
    private func logColumnView(
        _ column: LogColumnID,
        commit: CommitInfo,
        commitWidth: CGFloat,
        showTagNames: Bool,
        alignLabels: Bool
    ) -> some View {
        switch column {
        case .commit:
            HStack(spacing: 6) {
                // VcsLog's default table starts the commit column after the
                // graph gutter and paints branch/HEAD references in the same
                // cell as the subject. Reordering moves this whole semantic
                // column, not just one of its labels.
                if alignLabels {
                    referenceLabels(for: commit, showTagNames: showTagNames)
                    commitSummary(commit)
                } else {
                    commitSummary(commit)
                    referenceLabels(for: commit, showTagNames: showTagNames)
                }
            }
            .frame(width: commitWidth, height: rowHeight, alignment: .leading)
        case .author:
            Text(commit.authorName.isEmpty ? "—" : commit.authorName)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
                .frame(width: columnLayout.width(for: .author), alignment: .leading)
        case .date:
            Text(dateStr(commit.time))
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .frame(width: columnLayout.width(for: .date), alignment: .trailing)
        case .hash:
            Text(commit.shortId)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: columnLayout.width(for: .hash), alignment: .trailing)
        case .root:
            Text(logRepositoryDisplayName(commit.repositoryPath))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .help(logRepositoryDisplayPath(commit.repositoryPath))
                .frame(width: columnLayout.width(for: .root), alignment: .leading)
        case .signature:
            logSignatureCell(commit)
                .frame(width: columnLayout.width(for: .signature), alignment: .leading)
        }
    }

    @ViewBuilder
    private func logSignatureCell(_ commit: CommitInfo) -> some View {
        let key = commitIdentity(commit)
        if let info = signatureStatuses[key] {
            Group {
                switch info.status {
                case .none:
                    Text("—")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("No signature")
                case .valid:
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Verified signature")
                case .invalid:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Bad signature")
                case .unknown:
                    Image(systemName: "questionmark.circle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Unverified signature")
                @unknown default:
                    Image(systemName: "questionmark.circle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Unverified signature")
                }
            }
            .help(logSignatureHelp(info))
        } else if signatureFailedIDs.contains(key) {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.orange)
                .accessibilityLabel("Unable to load signature status")
                .help("Unable to load signature status")
        } else if signatureLoadingIDs.contains(key) || commit.hasSignature {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Loading signature status")
        } else {
            Text("—")
                .foregroundStyle(.secondary)
                .accessibilityLabel("No signature")
        }
    }

    private func logSignatureHelp(_ info: CommitSignatureInfo) -> String {
        let label: String
        switch info.status {
        case .none:
            label = "No signature"
        case .valid:
            label = "Verified signature"
        case .invalid:
            label = "Bad signature"
        case .unknown:
            label = info.reason.isEmpty ? "Unverified signature" : "Unverified signature: \(info.reason)"
        @unknown default:
            label = "Unverified signature"
        }
        var details = [label]
        if !info.signer.isEmpty { details.append("Signer: \(info.signer)") }
        if !info.fingerprint.isEmpty { details.append("Fingerprint: \(info.fingerprint)") }
        return details.joined(separator: "\n")
    }

    @ViewBuilder
    private func commitSummary(_ commit: CommitInfo) -> some View {
        Text(commit.summary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func referenceLabels(for commit: CommitInfo, showTagNames: Bool) -> some View {
        ForEach(refLabels(
            for: commit,
            compact: compactReferences,
            showTagNames: showTagNames
        )) { ref in
            Text(ref.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ref.kind.foreground)
                .padding(.horizontal, 5)
                .frame(height: 18)
                .background(ref.kind.background, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(ref.kind.border, lineWidth: 0.75)
                }
                .lineLimit(1)
                .frame(minWidth: alignLabels ? 56 : nil, alignment: .leading)
                .help(ref.title)
        }
    }

    private func refLabels(
        for commit: CommitInfo,
        compact: Bool,
        showTagNames: Bool
    ) -> [RefLabel] {
        var labels: [RefLabel] = []
        var seen = Set<String>()

        func append(_ label: RefLabel) {
            // A repository can expose the same shortened remote name through
            // more than one ref namespace (and older engine versions did not
            // normalize that list). SwiftUI requires every ForEach identity
            // to be unique; duplicate IDs here made the history table enter
            // undefined rendering state and could erase the commit summary.
            guard seen.insert(label.id).inserted else { return }
            labels.append(label)
        }

        if commit.isHead {
            append(RefLabel(id: "head", title: "HEAD", kind: .head))
        }
        commit.refs.forEach { append(RefLabel(id: "local:\($0)", title: $0, kind: .local)) }
        if showTagNames {
            commit.tagRefs.forEach { append(RefLabel(id: "tag:\($0)", title: $0, kind: .tag)) }
        }
        commit.remoteRefs.forEach { append(RefLabel(id: "remote:\($0)", title: $0, kind: .remote)) }
        if compact, labels.count > 2 {
            let hiddenCount = labels.count - 2
            return Array(labels.prefix(2)) + [RefLabel(
                id: "more:\(commit.id)",
                title: "+\(hiddenCount)",
                kind: .remote
            )]
        }
        return labels
    }

    /// VcsLogGraphTable supports the standard macOS table selection model.
    /// SwiftUI's high-level tap gesture does not expose modifier flags, so use
    /// the current AppKit event at the instant of the click and preserve the
    /// same single / Cmd-toggle / Shift-range semantics.
    private func select(_ commit: CommitInfo, modifiers: NSEvent.ModifierFlags? = nil) {
        let identity = commitIdentity(commit)
        let flags = modifiers ?? NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            var next = selectedIDs
            if next.contains(identity) {
                next.remove(identity)
            } else {
                next.insert(identity)
            }
            if next.isEmpty { next.insert(identity) }
            selectedIDs = next
            if next.contains(identity) {
                selection = identity
            } else if let nextActive = commits.first(where: { next.contains(commitIdentity($0)) }) {
                selection = commitIdentity(nextActive)
            }
            return
        }

        if flags.contains(.shift),
           let anchor = selection,
           let anchorIndex = commits.firstIndex(where: { commitIdentity($0) == anchor }),
           let targetIndex = commits.firstIndex(where: { commitIdentity($0) == identity }) {
            let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
            selectedIDs = Set(commits[range].map(commitIdentity))
            selection = identity
            return
        }

        selectedIDs = [identity]
        selection = identity
    }

    private func point(lane: UInt32, row: Int) -> CGPoint {
        CGPoint(
            x: 16 + CGFloat(lane) * effectiveLaneWidth,
            y: CGFloat(row) * rowHeight + rowHeight / 2
        )
    }

    private func color(for lane: UInt32) -> Color {
        let colors: [Color] = [.blue, .purple, .orange, .green, .pink, .teal, .indigo]
        return colors[Int(lane) % colors.count]
    }

    private func strokeGraphEdge(
        context: inout GraphicsContext,
        start: CGPoint,
        target: CGPoint,
        color: Color,
        style: StrokeStyle
    ) {
        context.stroke(
            graphEdgePath(start: start, target: target),
            with: .color(color),
            style: style
        )
    }

    private func graphEdgePath(start: CGPoint, target: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        let middleY = (start.y + target.y) / 2
        if start.x == target.x {
            path.addLine(to: target)
        } else {
            path.addLine(to: CGPoint(x: start.x, y: middleY))
            path.addCurve(
                to: target,
                control1: CGPoint(x: start.x, y: middleY),
                control2: CGPoint(x: target.x, y: middleY)
            )
        }
        return path
    }

    private func drawGraph(
        context: inout GraphicsContext,
        size: CGSize,
        rows: Range<Int>,
        graph: LinearBekGraphModel,
        highlight: LinearBekGraphHighlight?
    ) {
        let indexes = Dictionary(uniqueKeysWithValues: rows.map { ($0, commits[$0].id) }.map { ($1, $0) })

        for edge in graph.visibleEdges where rows.contains(edge.upRow) {
            guard rows.contains(edge.downRow) || showLongEdges else { continue }
            let start = point(lane: edge.fromLane, row: edge.upRow)
            let target = rows.contains(edge.downRow)
                ? point(lane: edge.toLane, row: edge.downRow)
                : CGPoint(
                    x: 16 + CGFloat(edge.toLane) * effectiveLaneWidth,
                    y: size.height
                )
            strokeGraphEdge(
                context: &context,
                start: start,
                target: target,
                color: highlight?.normalEdges.contains(edge) == true
                    ? .primary
                    : color(for: edge.toLane),
                style: StrokeStyle(
                    lineWidth: highlight?.normalEdges.contains(edge) == true ? 3.5 : 2,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }

        for edge in graph.dottedEdges {
            guard rows.contains(edge.upRow), rows.contains(edge.downRow) else { continue }
            strokeGraphEdge(
                context: &context,
                start: point(lane: edge.fromLane, row: edge.upRow),
                target: point(lane: edge.toLane, row: edge.downRow),
                color: highlight?.dottedEdges.contains(edge) == true
                    ? .primary
                    : color(for: edge.toLane),
                style: StrokeStyle(
                    lineWidth: highlight?.dottedEdges.contains(edge) == true ? 3.5 : 2,
                    lineCap: .round,
                    lineJoin: .round,
                    dash: [2, 3]
                )
            )
        }

        // A paged log has no row for a parent at the bottom of the current
        // page. Keep that continuation lane visible to the viewport edge.
        for index in rows {
            let commit = commits[index]
            let start = point(lane: commit.lane, row: index)
            for (parentIndex, parentId) in commit.parentIds.enumerated() {
                guard indexes[parentId] == nil else { continue }
                guard parentIndex < commit.parentLanes.count, showLongEdges else { continue }
                let parentLane = commit.parentLanes[parentIndex]
                strokeGraphEdge(
                    context: &context,
                    start: start,
                    target: CGPoint(
                        x: 16 + CGFloat(parentLane) * effectiveLaneWidth,
                        y: size.height
                    ),
                    color: color(for: parentLane),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )
            }
            let radius: CGFloat = commit.parentIds.count > 1 ? 6 : 5
            context.fill(
                Path(ellipseIn: CGRect(
                    x: start.x - radius,
                    y: start.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )),
                with: .color(
                    highlight?.rows.contains(index) == true
                        ? .primary
                        : commit.isHead ? .blue : color(for: commit.lane)
                )
            )
            if commit.isHead {
                context.stroke(
                    Path(ellipseIn: CGRect(
                        x: start.x - radius - 2,
                        y: start.y - radius - 2,
                        width: (radius + 2) * 2,
                        height: (radius + 2) * 2
                    )),
                    with: .color(.blue.opacity(0.35)),
                    lineWidth: 2
                )
            }
        }
    }
}

/// Reverse a parsed diff for IntelliJ's default branch comparison direction:
/// the current working tree is the left/base side and the selected branch is
/// the right side. The engine intentionally returns revision → worktree, so
/// this presentation-only transform keeps the engine API unambiguous.
func reversedFileDiffForPresentation(_ diff: FileDiff) -> FileDiff {
    let hunks = diff.hunks.map { hunk in
        DiffHunk(
            oldStart: hunk.newStart,
            newStart: hunk.oldStart,
            oldLines: hunk.newLines.map { line in
                switch line.kind {
                case .context:
                    DiffLine(
                        kind: .context,
                        oldLine: line.newLine,
                        newLine: line.oldLine,
                        text: line.text,
                        spans: line.spans,
                        highlights: line.highlights
                    )
                case .addition, .deletion:
                    DiffLine(
                        kind: .deletion,
                        oldLine: line.newLine,
                        newLine: 0,
                        text: line.text,
                        spans: line.spans,
                        highlights: line.highlights
                    )
                }
            },
            newLines: hunk.oldLines.map { line in
                switch line.kind {
                case .context:
                    DiffLine(
                        kind: .context,
                        oldLine: line.newLine,
                        newLine: line.oldLine,
                        text: line.text,
                        spans: line.spans,
                        highlights: line.highlights
                    )
                case .addition, .deletion:
                    DiffLine(
                        kind: .addition,
                        oldLine: 0,
                        newLine: line.oldLine,
                        text: line.text,
                        spans: line.spans,
                        highlights: line.highlights
                    )
                }
            }
        )
    }
    return FileDiff(path: diff.path, binary: diff.binary, hunks: hunks)
}

/// v0.4 两个 revision 的文件变化详情，复用现有 side-by-side diff。
struct TreeCompareDetailView: View {
    let repo: Repository?
    let change: TreeChange?
    let selectedChanges: [TreeChange]
    let selectedPaths: Set<String>
    let rev1: String
    let rev2: String
    let comparesWithWorkingTree: Bool
    let projectPath: String?
    let onSelectPath: (String) -> Void
    @State private var fileDiff: FileDiff?
    @State private var error: String?
    @State private var diffTask: Task<Void, Never>?
    @State private var swapSides: Bool

    init(
        repo: Repository?,
        change: TreeChange?,
        selectedChanges: [TreeChange],
        selectedPaths: Set<String>,
        rev1: String,
        rev2: String,
        comparesWithWorkingTree: Bool,
        projectPath: String? = nil,
        onSelectPath: @escaping (String) -> Void
    ) {
        self.repo = repo
        self.change = change
        self.selectedChanges = selectedChanges
        self.selectedPaths = selectedPaths
        self.rev1 = rev1
        self.rev2 = rev2
        self.comparesWithWorkingTree = comparesWithWorkingTree
        self.projectPath = projectPath
        self.onSelectPath = onSelectPath
        _swapSides = State(
            initialValue: GitCompareBranchesSettings.swapSides(for: projectPath)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let change {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(change.path).font(.headline)
                        Text(comparesWithWorkingTree
                             ? (swapSides
                                ? "\(rev1) → Working Tree"
                                : "Working Tree → \(rev1)")
                             : "\(rev1) → \(rev2)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if comparesWithWorkingTree {
                        Button {
                            swapSides.toggle()
                            GitCompareBranchesSettings.saveSwapSides(
                                swapSides,
                                for: projectPath
                            )
                            load()
                        } label: {
                            Label("Swap Sides", systemImage: "arrow.left.arrow.right")
                        }
                        .buttonStyle(.borderless)
                        .help(swapSides
                              ? "Show the working tree on the left"
                              : "Show the selected branch on the left")
                    }
                    if selectedPaths.count > 1 {
                        Text("\(selectedPaths.count) selected")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button {
                            selectAdjacentChange(offset: -1)
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.borderless)
                        .help("Previous File")
                        .disabled(!canSelectAdjacentChange(offset: -1))
                        Button {
                            selectAdjacentChange(offset: 1)
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(.borderless)
                        .help("Next File")
                        .disabled(!canSelectAdjacentChange(offset: 1))
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                } else if let fileDiff {
                    SideBySideDiffView(fileDiff: fileDiff)
                } else {
                    ProgressView()
                }
            } else {
                Text("选择一个文件查看比较结果").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: change?.path) { _, _ in load() }
        .onChange(of: rev1) { _, _ in load() }
        .onChange(of: rev2) { _, _ in load() }
        .onChange(of: comparesWithWorkingTree) { _, _ in load() }
        .onChange(of: swapSides) { _, _ in load() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            guard comparesWithWorkingTree else { return }
            let persisted = GitCompareBranchesSettings.swapSides(for: projectPath)
            if persisted != swapSides {
                swapSides = persisted
            }
        }
        .onAppear {
            swapSides = GitCompareBranchesSettings.swapSides(for: projectPath)
            load()
        }
        .onDisappear { diffTask?.cancel() }
    }

    private func canSelectAdjacentChange(offset: Int) -> Bool {
        guard let index = selectedChanges.firstIndex(where: { $0.path == change?.path }) else {
            return false
        }
        return selectedChanges.indices.contains(index + offset)
    }

    private func selectAdjacentChange(offset: Int) {
        guard let index = selectedChanges.firstIndex(where: { $0.path == change?.path }),
              selectedChanges.indices.contains(index + offset) else { return }
        onSelectPath(selectedChanges[index + offset].path)
    }

    private func load() {
        diffTask?.cancel()
        fileDiff = nil
        error = nil
        guard let repo, let change else {
            return
        }
        let path = change.path
        let expectedRev1 = rev1
        let expectedRev2 = rev2
        let expectedWorkingTreeMode = comparesWithWorkingTree
        let expectedSwapSides = swapSides
        let task = Task.detached(priority: .userInitiated) {
            do {
                let rawDiff: FileDiff
                if expectedWorkingTreeMode {
                    rawDiff = try repo.diffRevisionPathWithWorktreeWithSettings(
                        revision: expectedRev1,
                        revisionPath: change.oldPath ?? path,
                        worktreePath: path,
                        settings: makeArborGitDiffSettings()
                    )
                } else {
                    rawDiff = try repo.diffCommitsWithSettings(
                        rev1: expectedRev1,
                        rev2: expectedRev2,
                        path: path,
                        settings: makeArborGitDiffSettings()
                    )
                }
                let diff = expectedWorkingTreeMode && !expectedSwapSides
                    ? reversedFileDiffForPresentation(rawDiff)
                    : rawDiff
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled,
                          self.rev1 == expectedRev1,
                          self.rev2 == expectedRev2,
                          self.comparesWithWorkingTree == expectedWorkingTreeMode,
                          self.swapSides == expectedSwapSides,
                          self.change?.path == path else { return }
                    self.fileDiff = diff
                    self.error = nil
                }
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled,
                          self.rev1 == expectedRev1,
                          self.rev2 == expectedRev2,
                          self.comparesWithWorkingTree == expectedWorkingTreeMode,
                          self.swapSides == expectedSwapSides,
                          self.change?.path == path else { return }
                    self.error = "\(error)"
                    self.fileDiff = nil
                }
            }
        }
        diffTask = task
    }
}
