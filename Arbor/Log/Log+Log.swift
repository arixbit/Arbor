import SwiftUI
import AppKit
import UniformTypeIdentifiers


func logNavigationChoiceTitle(_ commit: CommitInfo) -> String {
    let shortID = commit.shortId.isEmpty ? String(commit.id.prefix(7)) : commit.shortId
    let summary = commit.summary.isEmpty ? "(no subject)" : commit.summary
    let author = commit.authorName.isEmpty ? "—" : commit.authorName
    return "\(shortID)  \(summary) · \(author) · \(dateStr(commit.time))"
}

/// Mirrors IntelliJ's structure-filter matching for the Changes Browser.
/// Paths are repository-relative; directories match descendants and renames
/// match either endpoint so the affected file is never hidden.
func normalizedLogAffectedPath(_ raw: String) -> String? {
    var value = raw
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\\", with: "/")
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    while value.hasPrefix("./") {
        value.removeFirst(2)
    }
    guard !value.isEmpty, value != "." else { return nil }
    return value
}

/// IntelliJ's structure filter is a set of paths, while the current Log tab
/// descriptor is intentionally kept as a single text value for compatibility
/// with existing tabs. Treat each line as one path and remove duplicates while
/// preserving the user's order.
func normalizedLogPathFilters(_ raw: String) -> [String] {
    var seen = Set<String>()
    return raw
        .components(separatedBy: CharacterSet.newlines)
        .compactMap(normalizedLogAffectedPath)
        .filter { seen.insert($0).inserted }
}

func logPathFilterText(_ paths: [String]) -> String {
    var seen = Set<String>()
    return paths
        .compactMap(normalizedLogAffectedPath)
        .filter { seen.insert($0).inserted }
        .joined(separator: "\n")
}

/// Converts a selected file or directory into the repository-relative path
/// used by Git's VCS Log path filter. The deepest matching root wins so
/// nested Git repositories do not accidentally produce a parent-relative path.
func relativeLogPathFilter(for url: URL, roots: [String]) -> String? {
    let selectedPath = url.standardizedFileURL.path
    let normalizedRoots = logRootPathsDeepestFirst(roots)
    guard let root = normalizedRoots.first(where: {
        selectedPath == $0 || selectedPath.hasPrefix($0 + "/")
    }) else { return nil }
    let suffix = String(selectedPath.dropFirst(root.count))
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !suffix.isEmpty else { return "" }
    return url.hasDirectoryPath ? suffix + "/" : suffix
}

func logChangeAffectsPath(_ change: TreeChange, affectedPath rawPath: String) -> Bool {
    guard let affectedPath = normalizedLogAffectedPath(rawPath) else { return false }
    let candidates = [change.path] + (change.oldPath.map { [$0] } ?? [])
    return candidates.contains { candidate in
        let normalizedCandidate = normalizedLogAffectedPath(candidate) ?? candidate
        return normalizedCandidate == affectedPath
            || normalizedCandidate.hasPrefix(affectedPath + "/")
    }
}

func logChangeAffectsAnyPath(_ change: TreeChange, affectedPaths: [String]) -> Bool {
    affectedPaths.contains { logChangeAffectsPath(change, affectedPath: $0) }
}

func logChangeAffectsAnyPath(
    _ change: TreeChange,
    rootPath: String?,
    selections: [LogPathFilterSelection]
) -> Bool {
    let normalizedRoot = rootPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    return normalizedLogPathFilterSelections(selections).contains { selection in
        guard selection.rootPath == nil || selection.rootPath == normalizedRoot else {
            return false
        }
        return logChangeAffectsPath(change, affectedPath: selection.path)
    }
}

func logPathFilterSummary(_ paths: [String]) -> String {
    guard let first = paths.first else { return "" }
    guard paths.count > 1 else { return first }
    return "\(first) + \(paths.count - 1)"
}

func normalizedLogRootPaths(_ roots: [String]) -> [String] {
    var seen = Set<String>()
    return roots
        .map(canonicalExternalLogPath)
        .filter { !$0.isEmpty && seen.insert($0).inserted }
        .sorted()
}

/// Keeps an external Git Log window scoped to real roots after discovery is
/// refreshed. A newly opened window starts with every discovered root, while
/// an existing selection retains only roots that still exist and falls back
/// to one available root so the Log never becomes rootless by accident.
func reconciledExternalLogRootSelection(
    availableRoots: [String],
    selectedRoots: Set<String>,
    initialized: Bool
) -> Set<String> {
    let normalizedRoots = normalizedLogRootPaths(availableRoots)
    guard !normalizedRoots.isEmpty else { return [] }
    guard initialized else { return Set(normalizedRoots) }

    let retained = Set(normalizedLogRootPaths(Array(selectedRoots)))
        .intersection(normalizedRoots)
    if !retained.isEmpty { return retained }
    return [normalizedRoots[0]]
}

func logRootPathsDeepestFirst(_ roots: [String]) -> [String] {
    normalizedLogRootPaths(roots).sorted {
        if $0.count == $1.count { return $0 < $1 }
        return $0.count > $1.count
    }
}

func normalizedLogRootFilterValues(_ raw: String) -> [String] {
    normalizedLogRootPaths(
        raw.components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    )
}

func reconciledLogVisibleRootPaths(allRoots: [String], raw: String) -> Set<String> {
    let normalizedRoots = Set(normalizedLogRootPaths(allRoots))
    let selectedRoots = Set(normalizedLogRootFilterValues(raw))
        .intersection(normalizedRoots)
    return selectedRoots.isEmpty ? normalizedRoots : selectedRoots
}

func serializedLogVisibleRootPaths(selected: Set<String>, allRoots: [String]) -> String {
    let normalizedRoots = Set(normalizedLogRootPaths(allRoots))
    guard selected != normalizedRoots else { return "" }
    return normalizedLogRootPaths(Array(selected.intersection(normalizedRoots)))
        .joined(separator: "\n")
}

let logPathTreeSelectionLimit = 100

enum LogPathSelectionState: Equatable {
    case clear
    case selected
    case selectedAbove
    case selectedBelow
}

func logPathSelectionIsAncestor(
    _ ancestor: LogPathFilterSelection,
    of descendant: LogPathFilterSelection
) -> Bool {
    guard ancestor.rootPath == descendant.rootPath,
          ancestor.path != descendant.path else { return false }
    return descendant.path.hasPrefix(ancestor.path + "/")
}

func normalizedLogTreeSelections(
    _ selections: [LogPathFilterSelection]
) -> Set<LogPathFilterSelection> {
    let normalized = normalizedLogPathFilterSelections(selections).sorted {
        if $0.rootPath != $1.rootPath { return ($0.rootPath ?? "") < ($1.rootPath ?? "") }
        let leftDepth = $0.path.split(separator: "/").count
        let rightDepth = $1.path.split(separator: "/").count
        if leftDepth != rightDepth { return leftDepth < rightDepth }
        return $0.path < $1.path
    }
    var result = Set<LogPathFilterSelection>()
    for selection in normalized {
        guard !result.contains(where: { logPathSelectionIsAncestor($0, of: selection) }) else {
            continue
        }
        result.insert(selection)
    }
    return result
}

func logPathTreeSelectionState(
    _ selection: LogPathFilterSelection,
    in selections: Set<LogPathFilterSelection>
) -> LogPathSelectionState {
    let normalized = normalizedLogTreeSelections(Array(selections))
    if normalized.contains(selection) { return .selected }
    if normalized.contains(where: { logPathSelectionIsAncestor($0, of: selection) }) {
        return .selectedAbove
    }
    if normalized.contains(where: { logPathSelectionIsAncestor(selection, of: $0) }) {
        return .selectedBelow
    }
    return .clear
}

/// Mirrors IntelliJ SelectionManager: selecting a parent collapses selected
/// descendants, selecting a descendant below an active parent is ignored, and
/// a new independent node is rejected once the 100-node limit is reached.
func logPathTreeSelectionsAfterToggle(
    _ selection: LogPathFilterSelection,
    in selections: Set<LogPathFilterSelection>,
    maximum: Int = logPathTreeSelectionLimit
) -> Set<LogPathFilterSelection> {
    let normalized = normalizedLogTreeSelections(Array(selections))
    switch logPathTreeSelectionState(selection, in: normalized) {
    case .selected:
        return Set(normalized.filter {
            $0 != selection && !logPathSelectionIsAncestor(selection, of: $0)
        })
    case .selectedAbove:
        return normalized
    case .clear, .selectedBelow:
        var collapsed = Set(normalized.filter {
            !logPathSelectionIsAncestor(selection, of: $0)
        })
        collapsed.insert(selection)
        return collapsed.count <= maximum ? collapsed : normalized
    }
}

func normalizedLogPathFilterSelections(
    _ selections: [LogPathFilterSelection]
) -> [LogPathFilterSelection] {
    var seen = Set<String>()
    return selections.compactMap { selection in
        guard let path = normalizedLogAffectedPath(selection.path) else { return nil }
        let rootPath = selection.rootPath.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        let normalized = LogPathFilterSelection(rootPath: rootPath, path: path)
        return seen.insert(normalized.id).inserted ? normalized : nil
    }
}

func makeLogPathFilterSelections(from paths: [String], rootPath: String? = nil) -> [LogPathFilterSelection] {
    normalizedLogPathFilterSelections(
        paths.map { LogPathFilterSelection(rootPath: rootPath, path: $0) }
    )
}

/// Manual editing uses relative paths for shared filters and absolute paths
/// for root-qualified selections, so editing a multi-root selection cannot
/// silently collapse equal paths from different repositories.
func logPathFilterEditorText(_ selections: [LogPathFilterSelection]) -> String {
    normalizedLogPathFilterSelections(selections).map { selection in
        guard let rootPath = selection.rootPath else { return selection.path }
        return URL(fileURLWithPath: rootPath)
            .appendingPathComponent(selection.path)
            .standardizedFileURL
            .path
    }.joined(separator: "\n")
}

func parseLogPathFilterEditorText(
    _ raw: String,
    roots: [String]
) -> [LogPathFilterSelection] {
    let normalizedRoots = logRootPathsDeepestFirst(roots)
    let selections = raw.components(separatedBy: CharacterSet.newlines).compactMap {
        line -> LogPathFilterSelection? in
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let normalizedValue = value.replacingOccurrences(of: "\\", with: "/")
        if normalizedValue.hasPrefix("/") {
            let absolute = URL(fileURLWithPath: normalizedValue).standardizedFileURL.path
            guard let root = normalizedRoots.first(where: {
                absolute == $0 || absolute.hasPrefix($0 + "/")
            }) else { return nil }
            let relative = String(absolute.dropFirst(root.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let path = normalizedLogAffectedPath(relative) else { return nil }
            return LogPathFilterSelection(rootPath: root, path: path)
        }
        guard let path = normalizedLogAffectedPath(normalizedValue) else { return nil }
        return LogPathFilterSelection(rootPath: nil, path: path)
    }
    return normalizedLogPathFilterSelections(selections)
}

func logPathFilterSummary(_ selections: [LogPathFilterSelection]) -> String {
    let labels = normalizedLogPathFilterSelections(selections).map { selection in
        guard let rootPath = selection.rootPath else { return selection.path }
        let rootName = URL(fileURLWithPath: rootPath).lastPathComponent
        return rootName.isEmpty ? selection.path : "\(rootName)/\(selection.path)"
    }
    return logPathFilterSummary(labels)
}

/// Returns nil when no structure filter is active, an empty array when the
/// active filter belongs to another root, and concrete paths otherwise.
func logPathFilterPathsForRoot(
    _ selections: [LogPathFilterSelection],
    rootPath: String
) -> [String]? {
    let normalizedSelections = normalizedLogPathFilterSelections(selections)
    guard !normalizedSelections.isEmpty else { return nil }
    let normalizedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
    let matching = normalizedSelections.filter {
        $0.rootPath == nil || $0.rootPath == normalizedRoot
    }
    return matching.map(\.path)
}


func reflogEntryIdentifier(_ entry: ReflogEntry) -> String {
    // Reflog can contain multiple records for the same object in one second.
    // Keep the key stable across refreshes without relying on the row index.
    "\(entry.oldId)\u{0}\(entry.newId)\u{0}\(entry.time)\u{0}\(entry.refName)\u{0}\(entry.message)"
}

/// Keeps Reflog multi-selection in the displayed order, not Set iteration order.
func orderedReflogSelection(entries: [ReflogEntry], selectedIDs: Set<String>) -> [ReflogEntry] {
    entries.filter { selectedIDs.contains(reflogEntryIdentifier($0)) }
}

func orderedUniqueReflogCommitIDs(_ entries: [ReflogEntry]) -> [String] {
    var seen = Set<String>()
    return entries.compactMap { entry in
        seen.insert(entry.newId).inserted ? entry.newId : nil
    }
}

/// Appends a Reflog page in file order while keeping refresh/retry duplicates
/// out of the visible list. The row identity is the complete record identity,
/// not the current array offset.
func appendedReflogEntries(
    existing: [ReflogEntry],
    page: [ReflogEntry]
) -> [ReflogEntry] {
    let existingIDs = Set(existing.map(reflogEntryIdentifier))
    return page.filter { !existingIDs.contains(reflogEntryIdentifier($0)) }
}

/// Persist the Reflog selection without dropping a tab's pending selection
/// while its next root is still loading. Once rows are available, retain only
/// current identities and keep the visible Reflog order deterministic.
func persistedReflogSelectionIDs(
    entries: [ReflogEntry],
    selectedIDs: Set<String>
) -> [String] {
    guard !entries.isEmpty else {
        return selectedIDs.sorted()
    }
    return entries
        .filter { selectedIDs.contains(reflogEntryIdentifier($0)) }
        .map(reflogEntryIdentifier)
}

struct ReflogSelectionState: Equatable {
    let selection: String?
    let selectedIDs: Set<String>
}

/// Refreshing a root's reflog keeps visible rows selected when possible, but
/// never leaves a deleted reflog record selected.
func reconciledReflogSelection(
    entries: [ReflogEntry],
    previousSelection: String?,
    previousSelectedIDs: Set<String>
) -> ReflogSelectionState {
    let retained = entries.filter { entry in
        let id = reflogEntryIdentifier(entry)
        return previousSelectedIDs.contains(id) || id == previousSelection
    }
    if let first = retained.first {
        let id = reflogEntryIdentifier(first)
        return ReflogSelectionState(
            selection: id,
            selectedIDs: Set(retained.map(reflogEntryIdentifier))
        )
    }
    if let first = entries.first {
        let id = reflogEntryIdentifier(first)
        return ReflogSelectionState(selection: id, selectedIDs: [id])
    }
    return ReflogSelectionState(selection: nil, selectedIDs: [])
}

struct LogChangeRecord: Identifiable, Hashable {
    let commit: CommitInfo
    let parentIndex: UInt32?
    let change: TreeChange

    var id: String {
        let parent = parentIndex.map(String.init) ?? "root"
        let root = commit.repositoryPath ?? ""
        return "\(root)\u{1f}\(commit.id):\(parent):\(change.path)"
    }
}

struct LogSignatureBatchRequest {
    let repository: Repository
    let commitIDs: [String]
    let keyByCommitID: [String: String]
}

struct LogSignatureLoadResult {
    let statuses: [String: CommitSignatureInfo]
    let failedKeys: Set<String>
}

/// Mirrors GitDropSelectedChangesAction/GitExtractSelectedChangesAction:
/// the action is available for a partial selection of one commit, including
/// initialized submodule gitlinks when the Changes browser is showing the
/// first-parent diff. The engine performs the nested-worktree safety checks;
/// dirty or uninitialized gitlinks fail closed at execution time.
func canRewriteSelectedHistoryChanges(
    commitCount: Int,
    selectedCount: Int,
    totalChangeCount: Int
) -> Bool {
    commitCount == 1
        && selectedCount > 0
        && selectedCount < totalChangeCount
}

/// Applies the Changes Browser's directory-node selection semantics. A
/// directory node represents all of its visible leaf changes; a plain click
/// replaces the selection, Command toggles the whole group, and Shift keeps
/// the existing visible-row range-selection model while including the group.
func logChangeSelectionAfterGroupClick(
    currentSelection: Set<String>,
    groupIDs: Set<String>,
    visibleIDs: [String],
    anchorID: String?,
    command: Bool,
    shift: Bool
) -> Set<String> {
    guard !groupIDs.isEmpty else { return currentSelection }
    if shift,
       let anchorID,
       let anchorIndex = visibleIDs.firstIndex(of: anchorID) {
        let groupIndices = visibleIDs.indices.filter { groupIDs.contains(visibleIDs[$0]) }
        if let firstGroupIndex = groupIndices.min(),
           let lastGroupIndex = groupIndices.max() {
            let targetIndex = anchorIndex <= firstGroupIndex
                ? lastGroupIndex
                : firstGroupIndex
            let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
            return Set(visibleIDs[range])
        }
    }
    guard command else { return groupIDs }

    if groupIDs.isSubset(of: currentSelection) {
        return currentSelection.subtracting(groupIDs)
    }
    return currentSelection.union(groupIDs)
}

/// Drop/Extract always uses `commit~1`, matching IntelliJ's restore path. A
/// merge Changes view from another parent, or a view that mixes parents, must
/// therefore keep both actions disabled.
func logChangeSelectionUsesFirstParent(_ records: [LogChangeRecord]) -> Bool {
    records.allSatisfy { record in
        record.parentIndex == nil || record.parentIndex == 0
    }
}

/// Resolves the action scope for a row context menu. IntelliJ keeps a
/// multi-selection when the contextual row is already selected and the
/// selected Changes form a safe patch set. A right-click on an unselected row
/// or a mixed-parent selection acts on that row alone.
func contextualLogChangeSelection(
    context: LogChangeRecord,
    selected: [LogChangeRecord]
) -> [LogChangeRecord] {
    guard selected.count > 1,
          selected.contains(where: { $0.id == context.id }),
          canApplyLogChangeSelection(selected) else {
        return [context]
    }
    return selected
}

/// Mirrors VcsLogAsyncChangesTreeModel: parent groups are available only for
/// one selected merge commit; multi-commit Changes Browser selections use the
/// first parent for each commit.
func logChangeParentIndices(
    commit: CommitInfo,
    selectedCommitCount: Int,
    selectedParentIndex: Int,
    showsChangesFromParents: Bool
) -> [UInt32?] {
    if showsChangesFromParents,
       selectedCommitCount == 1,
       commit.parentIds.count > 1 {
        return commit.parentIds.indices.map { UInt32($0) }
    }
    if commit.parentIds.isEmpty {
        return [nil]
    }
    if selectedCommitCount == 1 {
        return [UInt32(selectedParentIndex)]
    }
    return [0]
}
