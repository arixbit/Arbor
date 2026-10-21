import SwiftUI
import AppKit


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
