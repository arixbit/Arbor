import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
