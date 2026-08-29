import SwiftUI
import AppKit

func logNavigationChoiceTitle(_ commit: CommitInfo) -> String {
    let shortID = commit.shortId.isEmpty ? String(commit.id.prefix(7)) : commit.shortId
    let summary = commit.summary.isEmpty ? "(no subject)" : commit.summary
    let author = commit.authorName.isEmpty ? "—" : commit.authorName
    return "\(shortID)  \(summary) · \(author) · \(dateStr(commit.time))"
}

/// Match IntelliJ's BranchesDashboardTreeSelection.selectedBranchFilters:
/// branches (including remote branches) and HEAD participate in a branch
/// filter, while tags remain navigable refs but are not branch filters.
func logBranchFiltersForDashboardSelection(
    _ selection: [BranchDashboardReference]
) -> [LogRootBranchFilter] {
    var seen = Set<LogRootBranchFilter>()
    return selection.compactMap { reference in
        guard reference.kind == .head
            || reference.kind == .local
            || reference.kind == .remote else {
            return nil
        }
        let filter = LogRootBranchFilter(
            rootPath: reference.rootPath,
            branch: reference.name
        )
        return seen.insert(filter).inserted ? filter : nil
    }
}

/// Keeps multi-file compare actions deterministic and follows the order in
/// the Git tree diff rather than the unspecified order of a Set.
func orderedCompareSelection(changes: [TreeChange], selectedPaths: Set<String>) -> [TreeChange] {
    changes.filter { selectedPaths.contains($0.path) }
}

/// Returns the adjacent row used by a Changes Browser diff preview.
/// Keeping this independent of SwiftUI makes wrap/selection boundaries
/// explicit and testable.
func adjacentChangeIndex(count: Int, current: Int, offset: Int) -> Int? {
    guard count > 0, (0..<count).contains(current) else { return nil }
    let next = current + offset
    return (0..<count).contains(next) ? next : nil
}

/// Returns the first/last Changes Browser row when keyboard navigation starts
/// without an active row, or the adjacent row when one is already selected.
/// IntelliJ's changes tree keeps arrow navigation inside the visible file
/// rows instead of requiring a mouse click before the first diff can open.
func keyboardChangeIndex(count: Int, current: Int?, offset: Int) -> Int? {
    guard count > 0, offset != 0 else { return nil }
    guard let current else { return offset > 0 ? 0 : count - 1 }
    return adjacentChangeIndex(count: count, current: current, offset: offset)
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

private struct LogSignatureBatchRequest {
    let repository: Repository
    let commitIDs: [String]
    let keyByCommitID: [String: String]
}

private struct LogSignatureLoadResult {
    let statuses: [String: CommitSignatureInfo]
    let failedKeys: Set<String>
}

/// Partitions selected Changes Browser rows into the commit/parent patches
/// needed by IntelliJ's Apply/Revert actions. A root may contain several
/// selected commits, but one merge commit cannot mix parent diffs in the same
/// patch action. The root-qualified commit key keeps equal object IDs from
/// different repositories independent, so a cross-root selection can be
/// executed sequentially with each repository's own patch snapshot.
func logChangePatchGroups(_ records: [LogChangeRecord]) -> [[LogChangeRecord]] {
    guard !records.isEmpty else { return [] }

    var groups: [[LogChangeRecord]] = []
    var groupIndexByKey: [String: Int] = [:]
    var parentKeyByCommit: [String: String] = [:]

    for record in records {
        let parentKey = record.parentIndex.map(String.init) ?? "root"
        let rootKey = record.commit.repositoryPath.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        } ?? ""
        let commitKey = "\(rootKey)\u{1f}\(record.commit.id)"
        if let existingParentKey = parentKeyByCommit[commitKey], existingParentKey != parentKey {
            return []
        }
        parentKeyByCommit[commitKey] = parentKey

        let groupKey = "\(commitKey)\u{1f}\(parentKey)"
        if let index = groupIndexByKey[groupKey] {
            guard !groups[index].contains(where: { $0.change.path == record.change.path }) else {
                return []
            }
            groups[index].append(record)
        } else {
            groupIndexByKey[groupKey] = groups.count
            groups.append([record])
        }
    }
    return groups
}

func canApplyLogChangeSelection(_ records: [LogChangeRecord]) -> Bool {
    !logChangePatchGroups(records).isEmpty
}

/// Create Patch consumes the selected Changes as one patch file. A path may
/// not occur twice in that file: two revisions of the same path would require
/// commit ordering metadata that a plain Git patch does not carry. Renames
/// contribute both endpoints so the generated patch keeps the rename pair.
func canCreateLogPatchSelection(_ records: [LogChangeRecord]) -> Bool {
    let groups = logChangePatchGroups(records)
    guard !groups.isEmpty else { return false }

    var seenPaths = Set<String>()
    for record in groups.flatMap({ $0 }) {
        for path in [record.change.oldPath, record.change.path].compactMap({ $0 }) {
            guard !path.isEmpty, seenPaths.insert(path).inserted else {
                return false
            }
        }
    }
    return true
}

struct LogPatchGitCommand: Equatable {
    let command: String
    let args: [String]
}

/// Keeps revision arguments and pathspec arguments in the exact order needed
/// by Git. In particular, `--` must precede every selected path, and a merge
/// Changes row must use the parent that produced that row.
func logPatchGitCommand(
    commit: CommitInfo,
    parentIndex: UInt32?,
    paths: [String]
) -> LogPatchGitCommand? {
    guard !paths.isEmpty, paths.allSatisfy({ !$0.isEmpty }) else { return nil }
    if let parentIndex {
        let index = Int(parentIndex)
        guard commit.parentIds.indices.contains(index) else { return nil }
        return LogPatchGitCommand(
            command: "diff",
            args: [
                "--binary",
                "--no-ext-diff",
                commit.parentIds[index],
                commit.id,
                "--"
            ] + paths
        )
    }

    return LogPatchGitCommand(
        command: "show",
        args: [
            "--format=",
            "--binary",
            "--no-ext-diff",
            "--root",
            commit.id,
            "--"
        ] + paths
    )
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

enum LogBranchesGroupingMode: Equatable {
    case repository
    case refKind
}

/// Mirrors IntelliJ's GroupBranchByRepositoryAction visibility and toggle.
/// The repository grouping control is meaningful only for a multi-root Log
/// dashboard; single-root views remain grouped by ref kind internally.
func logBranchesGroupingMode(
    repositoryCount: Int,
    groupByRepository: Bool
) -> LogBranchesGroupingMode {
    repositoryCount > 1 && groupByRepository ? .repository : .refKind
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

/// `Get Version` is a file-content action, not a single-commit patch action.
/// IntelliJ keeps every selected change for it, including selections spanning
/// commits and Git roots; an unselected contextual row falls back to itself.
func contextualLogChangeRestoreSelection(
    context: LogChangeRecord,
    selected: [LogChangeRecord]
) -> [LogChangeRecord] {
    guard selected.count > 1,
          selected.contains(where: { $0.id == context.id }) else {
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

/// Changes Browser rows keep the owning Git root in their identity. A commit
/// object ID is only repository-local, so using the bare ID here would merge
/// two independent repositories when an aggregate Log selection contains the
/// same object ID in both roots.
func logChangesCommitIdentity(_ commit: CommitInfo) -> String {
    logCommitDisplayIdentity(
        repositoryPath: commit.repositoryPath,
        id: commit.id,
        aggregate: true
    )
}

func logChangesCommitRecords(
    _ records: [LogChangeRecord],
    for commit: CommitInfo
) -> [LogChangeRecord] {
    let identity = logChangesCommitIdentity(commit)
    return records.filter {
        logChangesCommitIdentity($0.commit) == identity
    }
}

func logChangesCommitGroupName(
    _ commit: CommitInfo,
    among commits: [CommitInfo]
) -> String {
    let rootPath = commit.repositoryPath?.trimmingCharacters(in: .whitespacesAndNewlines)
    let rootName = rootPath.map {
        URL(fileURLWithPath: $0).lastPathComponent
    }.flatMap { $0.isEmpty ? nil : $0 }
    let hasAmbiguousRootName = rootName.map { name in
        commits.compactMap { other in
            other.repositoryPath.map {
                URL(fileURLWithPath: $0).lastPathComponent
            }
        }.filter { $0 == name }.count > 1
    } ?? false
    let displayRoot = hasAmbiguousRootName ? rootPath : rootName
    let commitTitle = "\(commit.shortId)  \(commit.summary)"
    return displayRoot.map { "\($0) · \(commitTitle)" } ?? commitTitle
}

extension ContentView {
// MARK: Git 日志工作区

@ViewBuilder
private func pushTagAction(for tag: String) -> some View {
    let remoteNames = remotes.map(\.name)
    if remoteNames.count == 1 {
        Button("推送") { pushTag(tag, remote: remoteNames[0]) }
    } else if remoteNames.count > 1 {
        Menu("推送") {
            ForEach(remoteNames, id: \.self) { remote in
                Button(remote) {
                    pushTag(tag, remote: remote)
                }
            }
        }
    }
}

/// Git Log is the editor workspace to the right of the selected Git tool
/// window. It owns the graph, the changes browser, and the commit details
/// panel; Commit/Stash remains visible as the left tool-window column just as
/// it does in rebased.
private var branchComparisonPagination: BranchComparisonPagination {
    BranchComparisonPagination(
        onRefresh: refreshBranchComparison,
        onLoadMore: loadMoreBranchComparison,
        hasMore: { side in
            side == .first ? branchCompareFirstHasMore : branchCompareSecondHasMore
        },
        isLoading: { side in
            side == .first ? branchCompareFirstLoading : branchCompareSecondLoading
        },
        error: { side in
            side == .first ? branchCompareFirstError : branchCompareSecondError
        }
    )
}

private var branchComparisonLogActions: BranchComparisonLogActions {
    BranchComparisonLogActions(
        availability: logActionAvailability,
        pullRequestRemotesForCommit: pullRequestRemotesForCommit,
        onOpenPullRequest: openPullRequestsForCommit,
        commentRemotesForCommit: commentRemotesForCommit,
        onComment: beginReviewComment,
        onCreateTag: beginCreateTagFromLog,
        onCherryPickSelected: cherryPickCommitsFromLog,
        onRevertSelected: revertCommitsFromLog,
        onResetSelected: { commits in resetFromLog(commits) },
        currentBranchNameForCommit: currentLogBranchName,
        onReferenceAction: performLogReferenceAction,
        onRebaseOntoCommit: rebaseOntoCommitFromLog,
        onCreateAutoSquashCommit: beginAutoSquashCommitFromLog,
        onRewriteCommit: { commit, action in
            rewriteCommitFromLog(commit, action: action)
        },
        onRewriteSelected: { commits, action in
            rewriteSelectedCommitsFromLog(commits, action: action)
        },
        onPushUpToCommit: pushUpToCommitFromLog,
        onAddCommitsToRemoteBranch: addCommitsToRemoteBranchFromLog,
        hostedRemotesForCommit: hostedRemotesForCommit,
        onBrowseHostedRevision: browseHostedRevisionFromLog,
        onBrowseRevision: browseRevisionFromLog,
        onCopyRevisionLink: copyRevisionLinkFromLog,
        onUncommit: uncommitFromLog
    )
}

@ViewBuilder
var logWorkspace: some View {
    // MainFrame keeps the Changes browser in the right-hand details splitter
    // even when commit metadata and the diff preview are toggled off. Only the
    // corresponding child component disappears; the graph must not suddenly
    // take over the entire editor and make the existing selection appear lost.
    WorkspaceHorizontalSplit(
        persistedLeftWidth: $savedLogGraphWidth,
        minimumLeftWidth: 420,
        // The details inspector must remain wide enough for its compact
        // changes-tree/diff split. Rebased never lets that inspector collapse
        // into a single unusable strip while the graph is still open.
        minimumRightWidth: 340
    ) {
        // MainFrame's graph toolbar belongs to the graph/table side of the
        // split. Keeping it outside the inspector prevents the right commit
        // details workspace from acquiring a stray blank header row.
        logGraphPanel
            .frame(minWidth: 300, idealWidth: 940, maxWidth: .infinity, maxHeight: .infinity)
    } rightContent: {
        logInspector
            .frame(minWidth: 240, idealWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
    }
}

@ViewBuilder
private var logInspector: some View {
    ZStack {
        switch logViewMode {
        case .compare:
            TreeCompareDetailView(
                repo: activeCompareRepo ?? repo,
                change: selectedTreeChange,
                selectedChanges: selectedTreeChanges,
                selectedPaths: compareSelectedPaths,
                rev1: compareRev1,
                rev2: compareRev2,
                comparesWithWorkingTree: compareWithWorkingTree,
                projectPath: projectPath,
                onSelectPath: { path in
                    guard treeChanges.contains(where: { $0.path == path }) else { return }
                    compareSelection = path
                }
            )
        case .compareBranches:
            LogCommitInspectorView(
                repo: activeCompareRepo ?? repo,
                repositoryForCommit: logRepository(for:),
                commits: selectedBranchComparisonCommit.map { [$0] } ?? [],
                onReverted: { loadBranchComparison() },
                onCherryPicked: { loadBranchComparison(); refreshAll(showFeedback: false) },
                onRevertRequested: revertFromLog,
                onCherryPickRequested: cherryPickFromLog,
                onDropSelectedChanges: dropSelectedChangesFromLog,
                onExtractSelectedChanges: extractSelectedChangesFromLog,
                onShowFileHistory: { path in showFileHistory(path) },
                onShowFileHistoryForRevision: showFileHistoryForRevision,
                onOpenRepositoryVersion: browseFileRevisionFromLog,
                onBrowseHostedFileRevision: browseHostedFileRevisionFromLog,
                onCopyHostedFileRevision: copyHostedFileRevisionFromLog,
                onRestoreRepositoryVersion: restoreSelectedFilesFromRevisions,
                onEditSource: editSourceFromLog,
                onApplySelectedChanges: applySelectedChangesFromLog,
                onCreatePatch: createPatchFromLog,
                onCreatePatchSelection: createPatchFromLogSelection,
                onCopyPatchSelection: copyPatchFromLogSelection,
                onCreateBranch: createBranchFromCommit,
                showsMetadata: logShowDetails,
                showsDiffPreview: logShowDiffPreview,
                diffPreviewVertical: logDiffPreviewVertical,
                showsChangesFromParents: $logShowChangesFromParents,
                showsOnlyAffectedChanges: $logShowOnlyAffectedChanges,
                affectedPathSelections: activeLogPathFilterSelections()
            )
        case .tags:
            LogWorkspaceEmptyView(message: "选择 History 查看提交详情")
        case .reflog:
            LogCommitInspectorView(
                repo: logRepository,
                repositoryForCommit: logRepository(for:),
                commits: selectedReflogCommits,
                onReverted: { reloadLogView() },
                onCherryPicked: { reloadLogView(); refreshAll(showFeedback: false) },
                onRevertRequested: revertFromLog,
                onCherryPickRequested: cherryPickFromLog,
                onDropSelectedChanges: dropSelectedChangesFromLog,
                onExtractSelectedChanges: extractSelectedChangesFromLog,
                onShowFileHistory: { path in showFileHistory(path) },
                onShowFileHistoryForRevision: showFileHistoryForRevision,
                onOpenRepositoryVersion: browseFileRevisionFromLog,
                onBrowseHostedFileRevision: browseHostedFileRevisionFromLog,
                onCopyHostedFileRevision: copyHostedFileRevisionFromLog,
                onRestoreRepositoryVersion: restoreSelectedFilesFromRevisions,
                onEditSource: editSourceFromLog,
                onApplySelectedChanges: applySelectedChangesFromLog,
                onCreatePatch: createPatchFromLog,
                onCreatePatchSelection: createPatchFromLogSelection,
                onCopyPatchSelection: copyPatchFromLogSelection,
                onCreateBranch: createBranchFromCommit,
                showsMetadata: logShowDetails,
                showsDiffPreview: logShowDiffPreview,
                diffPreviewVertical: logDiffPreviewVertical,
                showsChangesFromParents: $logShowChangesFromParents,
                showsOnlyAffectedChanges: $logShowOnlyAffectedChanges,
                affectedPathSelections: activeLogPathFilterSelections()
            )
        default:
            LogCommitInspectorView(
                repo: logRepository,
                repositoryForCommit: logRepository(for:),
                commits: selectedLogCommits,
                onReverted: { loadLog() },
                onCherryPicked: { loadLog(); refreshAll(showFeedback: false) },
                onRevertRequested: revertFromLog,
                onCherryPickRequested: cherryPickFromLog,
                onDropSelectedChanges: dropSelectedChangesFromLog,
                onExtractSelectedChanges: extractSelectedChangesFromLog,
                onShowFileHistory: { path in showFileHistory(path) },
                onShowFileHistoryForRevision: showFileHistoryForRevision,
                onOpenRepositoryVersion: browseFileRevisionFromLog,
                onBrowseHostedFileRevision: browseHostedFileRevisionFromLog,
                onCopyHostedFileRevision: copyHostedFileRevisionFromLog,
                onRestoreRepositoryVersion: restoreSelectedFilesFromRevisions,
                onEditSource: editSourceFromLog,
                onApplySelectedChanges: applySelectedChangesFromLog,
                onCreatePatch: createPatchFromLog,
                onCreatePatchSelection: createPatchFromLogSelection,
                onCopyPatchSelection: copyPatchFromLogSelection,
                onCreateBranch: createBranchFromCommit,
                showsMetadata: logShowDetails,
                showsDiffPreview: logShowDiffPreview,
                diffPreviewVertical: logDiffPreviewVertical,
                showsChangesFromParents: $logShowChangesFromParents,
                showsOnlyAffectedChanges: $logShowOnlyAffectedChanges,
                affectedPathSelections: activeLogPathFilterSelections()
            )
        }

    }
}

/// The real Vcs Log frame has three independent pieces of state:
///
///   graph selection -> commit metadata/details
///   graph selection -> async Changes browser
///   Changes selection -> async file diff preview
///
/// Keeping those pieces in one `CommitDetailView` made a stale detail load
/// able to replace or hide the Changes browser. This wrapper mirrors
/// `MainFrame`: metadata is one splitter component and the Changes browser is
/// another, with its own selected path and diff task.
private struct LogCommitInspectorView: View {
    let repo: Repository?
    let repositoryForCommit: (CommitInfo) -> Repository?
    let commits: [CommitInfo]
    let onReverted: () -> Void
    let onCherryPicked: () -> Void
    let onRevertRequested: (CommitInfo) -> Void
    let onCherryPickRequested: (CommitInfo) -> Void
    let onDropSelectedChanges: (CommitInfo, [String]) -> Void
    let onExtractSelectedChanges: (CommitInfo, [String]) -> Void
    let onShowFileHistory: (String) -> Void
    let onShowFileHistoryForRevision: (CommitInfo, String) -> Void
    let onOpenRepositoryVersion: (CommitInfo, String) -> Void
    let onBrowseHostedFileRevision: (LogChangeRecord, RemoteInfo) -> Void
    let onCopyHostedFileRevision: (LogChangeRecord, RemoteInfo) -> Void
    let onRestoreRepositoryVersion: ([LogChangeRecord]) -> Void
    let onEditSource: (String) -> Void
    let onApplySelectedChanges: ([LogChangeRecord], Bool) -> Void
    let onCreatePatch: (CommitInfo) -> Void
    let onCreatePatchSelection: ([LogChangeRecord]) -> Void
    let onCopyPatchSelection: ([LogChangeRecord]) -> Void
    let onCreateBranch: (CommitInfo) -> Void
    let showsMetadata: Bool
    let showsDiffPreview: Bool
    let diffPreviewVertical: Bool
    @Binding var showsChangesFromParents: Bool
    @Binding var showsOnlyAffectedChanges: Bool
    let affectedPathSelections: [LogPathFilterSelection]

    var body: some View {
        Group {
            if commits.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.left.circle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("选择一个提交查看 Changes")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showsMetadata {
                VSplitView {
                    Group {
                        if commits.count == 1 {
                            CommitDetailsMetadataView(
                                commit: commits[0],
                                repositoryForCommit: repositoryForCommit,
                                onReverted: onReverted,
                                onCherryPicked: onCherryPicked,
                                onRevertRequested: onRevertRequested,
                                onCherryPickRequested: onCherryPickRequested,
                                onCreateBranch: onCreateBranch
                            )
                        } else {
                            LogMultiMetadataView(
                                commits: commits,
                                onCreateBranch: onCreateBranch
                            )
                        }
                    }
                    .frame(minHeight: 170, idealHeight: commits.count > 1 ? 250 : 300, maxHeight: .infinity)

                    LogChangesBrowserView(
                        repo: repo,
                        repositoryForCommit: repositoryForCommit,
                        commits: commits,
                        showsDiffPreview: showsDiffPreview,
                        diffPreviewVertical: diffPreviewVertical,
                        showsChangesFromParents: $showsChangesFromParents,
                        showsOnlyAffectedChanges: $showsOnlyAffectedChanges,
                        affectedPathSelections: affectedPathSelections,
                        onDropSelectedChanges: onDropSelectedChanges,
                        onExtractSelectedChanges: onExtractSelectedChanges,
                        onShowFileHistory: onShowFileHistory,
                        onShowFileHistoryForRevision: onShowFileHistoryForRevision,
                        onOpenRepositoryVersion: onOpenRepositoryVersion,
                        onBrowseHostedFileRevision: onBrowseHostedFileRevision,
                        onCopyHostedFileRevision: onCopyHostedFileRevision,
                        onRestoreRepositoryVersion: onRestoreRepositoryVersion,
                        onEditSource: onEditSource,
                        onApplySelectedChanges: onApplySelectedChanges,
                        onCreatePatch: onCreatePatch,
                        onCreatePatchSelection: onCreatePatchSelection,
                        onCopyPatchSelection: onCopyPatchSelection
                    )
                    .frame(minHeight: 180, idealHeight: 390, maxHeight: .infinity)
                }
            } else {
                LogChangesBrowserView(
                    repo: repo,
                    repositoryForCommit: repositoryForCommit,
                    commits: commits,
                    showsDiffPreview: showsDiffPreview,
                    diffPreviewVertical: diffPreviewVertical,
                    showsChangesFromParents: $showsChangesFromParents,
                    showsOnlyAffectedChanges: $showsOnlyAffectedChanges,
                    affectedPathSelections: affectedPathSelections,
                    onDropSelectedChanges: onDropSelectedChanges,
                    onExtractSelectedChanges: onExtractSelectedChanges,
                    onShowFileHistory: onShowFileHistory,
                    onShowFileHistoryForRevision: onShowFileHistoryForRevision,
                    onOpenRepositoryVersion: onOpenRepositoryVersion,
                    onBrowseHostedFileRevision: onBrowseHostedFileRevision,
                    onCopyHostedFileRevision: onCopyHostedFileRevision,
                    onRestoreRepositoryVersion: onRestoreRepositoryVersion,
                    onEditSource: onEditSource,
                    onApplySelectedChanges: onApplySelectedChanges,
                    onCreatePatch: onCreatePatch,
                    onCreatePatchSelection: onCreatePatchSelection,
                    onCopyPatchSelection: onCopyPatchSelection
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// IntelliJ's Compare Branches action shows the commits unique to each ref in
/// two synchronized log panes. The file-level Show Files Diff action remains
/// the separate TreeCompareDetailView path.
private enum BranchComparisonCommitAction {
    case checkout
    case reset
    case createBranch
    case compare
    case interactiveRebase
    case cherryPick
    case revert
}

private struct BranchComparisonPagination {
    let onRefresh: (BranchComparisonSide) -> Void
    let onLoadMore: (BranchComparisonSide) -> Void
    let hasMore: (BranchComparisonSide) -> Bool
    let isLoading: (BranchComparisonSide) -> Bool
    let error: (BranchComparisonSide) -> String?
}

private struct BranchComparisonLogActions {
    let availability: LogActionAvailability
    let pullRequestRemotesForCommit: (CommitInfo) -> [RemoteInfo]
    let onOpenPullRequest: (CommitInfo, RemoteInfo) -> Void
    let commentRemotesForCommit: (CommitInfo) -> [RemoteInfo]
    let onComment: (CommitInfo, RemoteInfo) -> Void
    let onCreateTag: (CommitInfo) -> Void
    let onCherryPickSelected: ([CommitInfo]) -> Void
    let onRevertSelected: ([CommitInfo]) -> Void
    let onResetSelected: ([CommitInfo]) -> Void
    let currentBranchNameForCommit: (CommitInfo) -> String?
    let onReferenceAction: (CommitInfo, LogReferenceActionTarget, LogReferenceAction) -> Void
    let onRebaseOntoCommit: (CommitInfo) -> Void
    let onCreateAutoSquashCommit: (CommitInfo, AutoSquashCommitKind) -> Void
    let onRewriteCommit: (CommitInfo, RebaseTodoAction) -> Void
    let onRewriteSelected: ([CommitInfo], RebaseTodoAction) -> Void
    let onPushUpToCommit: (CommitInfo) -> Void
    let onAddCommitsToRemoteBranch: ([CommitInfo]) -> Void
    let hostedRemotesForCommit: (CommitInfo) -> [RemoteInfo]
    let onBrowseHostedRevision: (CommitInfo, RemoteInfo) -> Void
    let onBrowseRevision: (CommitInfo) -> Void
    let onCopyRevisionLink: (CommitInfo, RemoteInfo) -> Void
    let onUncommit: (CommitInfo) -> Void
}

private struct BranchCommitComparisonView: View {
    let firstBranch: String
    let secondBranch: String
    let firstCommits: [CommitInfo]
    let secondCommits: [CommitInfo]
    @Binding var firstFilter: BranchComparisonFilter
    @Binding var secondFilter: BranchComparisonFilter
    let isLoading: Bool
    let error: String?
    @Binding var selectedID: String?
    @Binding var selectedSide: BranchComparisonSide
    let onFilterChanged: (BranchComparisonSide) -> Void
    let pagination: BranchComparisonPagination
    let onSelect: (BranchComparisonSide, String) -> Void
    let onAction: (BranchComparisonCommitAction, CommitInfo) -> Void
    let logActions: BranchComparisonLogActions
    @State private var firstGraphSelectedIDs: Set<String> = []
    @State private var secondGraphSelectedIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error,
               pagination.error(.first) == nil,
               pagination.error(.second) == nil {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .padding(10)
            }
            HStack(spacing: 0) {
                comparisonColumn(
                    title: firstBranch,
                    commits: firstCommits,
                    side: .first,
                    filter: $firstFilter,
                    selection: $selectedID,
                    selectedIDs: $firstGraphSelectedIDs
                )
                Divider()
                comparisonColumn(
                    title: secondBranch,
                    commits: secondCommits,
                    side: .second,
                    filter: $secondFilter,
                    selection: $selectedID,
                    selectedIDs: $secondGraphSelectedIDs
                )
            }
            .overlay {
                if isLoading && firstCommits.isEmpty && secondCommits.isEmpty {
                    ProgressView("Loading branch comparison…")
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func comparisonColumn(
        title: String,
        commits: [CommitInfo],
        side: BranchComparisonSide,
        filter: Binding<BranchComparisonFilter>,
        selection: Binding<String?>,
        selectedIDs: Binding<Set<String>>
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text("\(commits.count) unique")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    pagination.onRefresh(side)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh comparison pane")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Design.Colors.chrome.opacity(0.72))
            HStack(spacing: 6) {
                TextField("Message or hash", text: filter.message)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { onFilterChanged(side) }
                TextField("Author", text: filter.author)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { onFilterChanged(side) }
                Menu {
                    Toggle("Regex", isOn: filter.messageRegex)
                    Toggle("Match Case", isOn: filter.messageMatchCase)
                    Toggle("No Merges", isOn: filter.noMerges)
                    Divider()
                    Button("Clear Filters") {
                        filter.wrappedValue = BranchComparisonFilter()
                        onFilterChanged(side)
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton)
                .help("Compare pane filter settings")
                .onChange(of: filter.wrappedValue.messageRegex) { _, _ in onFilterChanged(side) }
                .onChange(of: filter.wrappedValue.messageMatchCase) { _, _ in onFilterChanged(side) }
                .onChange(of: filter.wrappedValue.noMerges) { _, _ in onFilterChanged(side) }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .background(Design.Colors.chrome.opacity(0.72))
            HStack(spacing: 6) {
                TextField("Since (YYYY-MM-DD)", text: filter.since)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { onFilterChanged(side) }
                TextField("Until (YYYY-MM-DD)", text: filter.until)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { onFilterChanged(side) }
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .background(Design.Colors.chrome.opacity(0.72))

            if let paneError = pagination.error(side) {
                Text(paneError)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            if commits.isEmpty && !pagination.isLoading(side) {
                Text("No unique commits")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if commits.isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LogGraphView(
                    commits: commits,
                    selection: selection,
                    selectedIDs: selectedIDs,
                    commitIdentity: { $0.id },
                    compactReferences: true,
                    showCommitColumns: false,
                    showAuthorColumn: true,
                    showDateColumn: true,
                    showHashColumn: true,
                    showRootColumn: false,
                    showSignatureColumn: false,
                    signatureStatuses: [:],
                    signatureLoadingIDs: [],
                    signatureFailedIDs: [],
                    columnLayout: LogColumnLayout(
                        order: [.commit, .author, .date, .hash]
                    ),
                    showTagNames: false,
                    alignLabels: false,
                    showLongEdges: true,
                    collapseGraph: false,
                    highlightCherryPickedCommits: false,
                    actionAvailability: logActions.availability,
                    onReachedEnd: { pagination.onLoadMore(side) },
                    hasMore: pagination.hasMore(side),
                    isLoadingMore: pagination.isLoading(side),
                    pullRequestRemotesForCommit: logActions.pullRequestRemotesForCommit,
                    onOpenPullRequest: logActions.onOpenPullRequest,
                    commentRemotesForCommit: logActions.commentRemotesForCommit,
                    onComment: logActions.onComment,
                    onCreateBranch: { onAction(.createBranch, $0) },
                    onCreateTag: logActions.onCreateTag,
                    onCherryPick: { onAction(.cherryPick, $0) },
                    onCherryPickSelected: logActions.onCherryPickSelected,
                    onRevert: { onAction(.revert, $0) },
                    onRevertSelected: logActions.onRevertSelected,
                    onCheckout: { onAction(.checkout, $0) },
                    onReset: { onAction(.reset, $0) },
                    onResetSelected: logActions.onResetSelected,
                    onCompare: { onAction(.compare, $0) },
                    currentBranchNameForCommit: logActions.currentBranchNameForCommit,
                    onReferenceAction: logActions.onReferenceAction,
                    onRebaseOntoCommit: logActions.onRebaseOntoCommit,
                    onInteractiveRebase: { onAction(.interactiveRebase, $0) },
                    onCreateAutoSquashCommit: logActions.onCreateAutoSquashCommit,
                    onRewriteCommit: logActions.onRewriteCommit,
                    onRewriteSelected: logActions.onRewriteSelected,
                    onPushUpToCommit: logActions.onPushUpToCommit,
                    onAddCommitsToRemoteBranch: logActions.onAddCommitsToRemoteBranch,
                    hostedRemotesForCommit: logActions.hostedRemotesForCommit,
                    onBrowseHostedRevision: logActions.onBrowseHostedRevision,
                    onBrowseRevision: logActions.onBrowseRevision,
                    onCopyRevisionLink: logActions.onCopyRevisionLink,
                    onUncommit: logActions.onUncommit
                )
                .onChange(of: selection.wrappedValue) { _, id in
                    let validIDs = Set(commits.map(\.id))
                    guard let nextSelection = branchComparisonGraphSelection(
                        current: selectedIDs.wrappedValue,
                        selectedID: id,
                        validIDs: validIDs
                    ) else {
                        selectedIDs.wrappedValue = []
                        return
                    }
                    selectedIDs.wrappedValue = nextSelection
                    guard let id else { return }
                    onSelect(side, id)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Metadata-only adapter for the existing action-rich commit inspector.
/// `CommitDetailView` intentionally does not load changed files in this mode;
/// the sibling `LogChangesBrowserView` owns that model, matching rebased's
/// `CommitDetailsListPanel` + `VcsLogChangesBrowser` split.
private struct CommitDetailsMetadataView: View {
    let commit: CommitInfo?
    let repositoryForCommit: (CommitInfo) -> Repository?
    let onReverted: () -> Void
    let onCherryPicked: () -> Void
    let onRevertRequested: (CommitInfo) -> Void
    let onCherryPickRequested: (CommitInfo) -> Void
    let onCreateBranch: (CommitInfo) -> Void

    private var selectedRepository: Repository? {
        guard let commit else { return nil }
        return repositoryForCommit(commit)
    }

    private var selectedRemotes: [RemoteInfo] {
        guard let selectedRepository else { return [] }
        return (try? selectedRepository.remoteList()) ?? []
    }

    var body: some View {
        CommitDetailView(
            repo: selectedRepository,
            commit: commit,
            remotes: selectedRemotes,
            onReverted: onReverted,
            onCherryPicked: onCherryPicked,
            onCreateBranch: onCreateBranch,
            onRevertRequested: onRevertRequested,
            onCherryPickRequested: onCherryPickRequested,
            showsMetadata: true,
            showsDiffPreview: false,
            showsChanges: false
        )
    }
}

private struct LogMultiMetadataView: View {
    let commits: [CommitInfo]
    let onCreateBranch: (CommitInfo) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("\(commits.count) commits selected")
                        .font(.headline)
                    Spacer()
                    Text("Cmd-click / Shift-click")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)

                ForEach(commits, id: \.self) { commit in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(commit.summary)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(2)
                        Text(commit.id)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("\(commit.authorName) · \(dateStr(commit.time))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            if let parent = commit.parentIds.first {
                                Text("Parent \(String(parent.prefix(7)))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Create Branch…") { onCreateBranch(commit) }
                                .buttonStyle(.borderless)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) { Divider() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SubmoduleChangeRequest: Identifiable {
    let id: String
    let commit: CommitInfo
    let revision1: String
    let revision2: String
    let path: String
}

private struct LogChangeNode: Identifiable {
    let name: String
    let path: String
    var record: LogChangeRecord?
    var children: [LogChangeNode] = []

    var id: String { path }

    var leafRecords: [LogChangeRecord] {
        if let record, children.isEmpty {
            return [record]
        }
        return children.flatMap(\.leafRecords)
    }

    mutating func insert(components: Array<Substring>, record: LogChangeRecord) {
        guard let first = components.first else {
            self.record = record
            return
        }
        let childName = String(first)
        let childPath = "\(path)/\(childName)"
        if let index = children.firstIndex(where: { $0.name == childName }) {
            children[index].insert(components: Array(components.dropFirst()), record: record)
        } else {
            var child = LogChangeNode(name: childName, path: childPath)
            child.insert(components: Array(components.dropFirst()), record: record)
            children.append(child)
            children.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
}

private enum LogDiffSource: Equatable {
    case commit
    case local(revision: String)
}

private enum LogChangesFilter: String, CaseIterable, Equatable {
    case movedWithoutChanges
    case nonImportant

    var title: LocalizedStringKey {
        switch self {
        case .movedWithoutChanges: "Moved without changes"
        case .nonImportant: "With non-important changes"
        }
    }
}

/// First-class Log Changes browser. A selection change clears the old tree
/// immediately, loads the selected commit set off the main actor, and only
/// then enables file-level diff loading. This prevents the previous commit's
/// files from remaining actionable while the new commit is still loading.
private struct LogChangesBrowserView: View {
    private static let maximumCommitsPerSelection = 50

    let repo: Repository?
    let repositoryForCommit: (CommitInfo) -> Repository?
    let commits: [CommitInfo]
    let showsDiffPreview: Bool
    let diffPreviewVertical: Bool
    @Binding var showsChangesFromParents: Bool
    @Binding var showsOnlyAffectedChanges: Bool
    let affectedPathSelections: [LogPathFilterSelection]
    let onDropSelectedChanges: (CommitInfo, [String]) -> Void
    let onExtractSelectedChanges: (CommitInfo, [String]) -> Void
    let onShowFileHistory: (String) -> Void
    let onShowFileHistoryForRevision: (CommitInfo, String) -> Void
    let onOpenRepositoryVersion: (CommitInfo, String) -> Void
    let onBrowseHostedFileRevision: (LogChangeRecord, RemoteInfo) -> Void
    let onCopyHostedFileRevision: (LogChangeRecord, RemoteInfo) -> Void
    let onRestoreRepositoryVersion: ([LogChangeRecord]) -> Void
    let onEditSource: (String) -> Void
    let onApplySelectedChanges: ([LogChangeRecord], Bool) -> Void
    let onCreatePatch: (CommitInfo) -> Void
    let onCreatePatchSelection: ([LogChangeRecord]) -> Void
    let onCopyPatchSelection: ([LogChangeRecord]) -> Void

    @State private var records: [LogChangeRecord] = []
    @State private var selectedRecordID: String?
    @State private var selectedRecordIDs: Set<String> = []
    @State private var fileDiff: FileDiff?
    @State private var diffError: String?
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var changesTask: Task<Void, Never>?
    @State private var diffTask: Task<Void, Never>?
    @State private var presentationMode: DiffPresentationMode = .sideBySide
    @State private var selectedParentIndex = 0
    @State private var groupByDirectory = true
    @State private var collapsedChangeNodes: Set<String> = []
    @State private var diffSource: LogDiffSource = .commit
    @State private var activeFilter: LogChangesFilter?
    @State private var filteredOutRecordIDs: Set<String> = []
    @State private var pendingFilterRecordIDs: Set<String> = []
    @State private var isFiltering = false
    @State private var filterError: String?
    @State private var filterTask: Task<Void, Never>?
    @State private var submoduleChangeRequest: SubmoduleChangeRequest?
    @State private var standaloneDiffRecord: LogChangeRecord?
    @FocusState private var changesTreeFocused: Bool

    private var hasAffectedPathFilter: Bool {
        !affectedPathSelections.isEmpty
    }

    private var rows: [LogChangeRecord] {
        // VcsLogAsyncChangesTreeModel keeps every Change in a multi-selection.
        // De-duplicating by path made Cmd-click/Shift-click look successful
        // while silently dropping the same file's change from later commits.
        let filteredRecords: [LogChangeRecord]
        if activeFilter == nil {
            filteredRecords = records
        } else {
            filteredRecords = records.filter {
                !filteredOutRecordIDs.contains($0.id)
                    && !pendingFilterRecordIDs.contains($0.id)
            }
        }
        guard showsOnlyAffectedChanges, hasAffectedPathFilter else {
            return filteredRecords
        }
        return filteredRecords.filter {
            logChangeAffectsAnyPath(
                $0.change,
                rootPath: $0.commit.repositoryPath,
                selections: affectedPathSelections
            )
        }
    }

    private var filteredOutRecords: [LogChangeRecord] {
        records.filter { filteredOutRecordIDs.contains($0.id) }
    }

    private var pendingFilterRecords: [LogChangeRecord] {
        records.filter { pendingFilterRecordIDs.contains($0.id) }
    }

    private var selectedRecord: LogChangeRecord? {
        guard let selectedRecordID else { return nil }
        return rows.first { $0.id == selectedRecordID }
    }

    private var selectedRecords: [LogChangeRecord] {
        rows.filter { selectedRecordIDs.contains($0.id) }
    }

    private func hostedFileRemotes(for record: LogChangeRecord) -> [RemoteInfo] {
        guard let repository = repositoryForCommit(record.commit) else { return [] }
        let target = hostedFileRevisionTarget(for: record)
        return (try? repository.remoteList())?.filter { remote in
            repository.permalinkForPath(
                remoteUrl: remote.url,
                commitId: target.commitID,
                path: target.path
            ) != nil
        } ?? []
    }

    private var canEditSelectedChanges: Bool {
        return canRewriteSelectedHistoryChanges(
            commitCount: commits.count,
            selectedCount: selectedRecords.count,
            totalChangeCount: records.count
        ) && logChangeSelectionUsesFirstParent(selectedRecords)
    }

    private var canApplySelectedChanges: Bool {
        canApplyLogChangeSelection(selectedRecords)
    }

    private var patchSelection: [LogChangeRecord] {
        selectedRecords.isEmpty ? rows : selectedRecords
    }

    private var canCreatePatchSelection: Bool {
        if selectedRecords.isEmpty, commits.count == 1 {
            return !records.isEmpty
        }
        return canCreateLogPatchSelection(patchSelection)
    }

    private func filterBinding(for filter: LogChangesFilter) -> Binding<Bool> {
        Binding(
            get: { activeFilter == filter },
            set: { enabled in
                setFilter(enabled ? filter : nil)
            }
        )
    }

    private func normalizeSelectionAfterFiltering() {
        let validIDs = Set(rows.map(\.id))
        selectedRecordIDs = selectedRecordIDs.intersection(validIDs)
        if let selectedRecordID, !validIDs.contains(selectedRecordID) {
            self.selectedRecordID = nil
            fileDiff = nil
            diffError = nil
            diffSource = .commit
        }
    }

    private func setFilter(_ filter: LogChangesFilter?) {
        filterTask?.cancel()
        activeFilter = filter
        filteredOutRecordIDs = []
        pendingFilterRecordIDs = []
        filterError = nil
        isFiltering = false
        guard let filter, !records.isEmpty else {
            normalizeSelectionAfterFiltering()
            return
        }

        switch filter {
        case .movedWithoutChanges:
            filteredOutRecordIDs = Set(
                records
                    .filter { $0.change.kind == .renamed && $0.change.isPureMove }
                    .map(\.id)
            )
            normalizeSelectionAfterFiltering()
        case .nonImportant:
            let snapshot = records
            let expectedIDs = snapshot.map(\.id)
            let repositoryResolver = repositoryForCommit
            pendingFilterRecordIDs = Set(expectedIDs)
            isFiltering = true
            filterTask = Task.detached(priority: .utility) {
                var filteredIDs: Set<String> = []
                var pendingIDs = Set(expectedIDs)
                for record in snapshot {
                    guard !Task.isCancelled else { return }
                    do {
                        if let repo = repositoryResolver(record.commit) {
                            let diff = try repo.commitFileDiffWithSettings(
                                commitId: record.commit.id,
                                parentIndex: record.parentIndex,
                                path: record.change.path,
                                settings: makeArborGitDiffSettings(ignoreWhitespace: true)
                            )
                            // Binary changes have no hunks but are always important.
                            if !diff.binary && diff.hunks.isEmpty {
                                filteredIDs.insert(record.id)
                            }
                        }
                    } catch {
                        // Match IntelliJ's fail-open behavior: an unreadable
                        // revision remains visible instead of disappearing.
                    }
                    pendingIDs.remove(record.id)
                    let currentFilteredIDs = filteredIDs
                    let currentPendingIDs = pendingIDs
                    await MainActor.run {
                        guard self.records.map(\.id) == expectedIDs,
                              self.activeFilter == filter else { return }
                        self.filteredOutRecordIDs = currentFilteredIDs
                        self.pendingFilterRecordIDs = currentPendingIDs
                        self.normalizeSelectionAfterFiltering()
                    }
                }
                guard !Task.isCancelled else { return }
                let finalFilteredIDs = filteredIDs
                await MainActor.run {
                    guard self.records.map(\.id) == expectedIDs,
                          self.activeFilter == filter else { return }
                    self.filteredOutRecordIDs = finalFilteredIDs
                    self.pendingFilterRecordIDs = []
                    self.isFiltering = false
                    self.normalizeSelectionAfterFiltering()
                }
            }
        }
    }

    private func restartActiveFilter() {
        guard let activeFilter else {
            filterTask?.cancel()
            filteredOutRecordIDs = []
            pendingFilterRecordIDs = []
            isFiltering = false
            return
        }
        setFilter(activeFilter)
    }

    private var changeTree: [LogChangeNode] {
        if showsChangesFromParents,
           commits.count == 1,
           let commit = commits.first,
           commit.parentIds.count > 1 {
            return commit.parentIds.indices.compactMap { index in
                let parentRecords = rows.filter { $0.parentIndex == UInt32(index) }
                guard !parentRecords.isEmpty else { return nil }
                var group = LogChangeNode(
                    name: "Parent \(index + 1)  \(String(commit.parentIds[index].prefix(7)))",
                    path: "parent:\(index)"
                )
                for record in parentRecords {
                    let parts = record.change.path.split(separator: "/")
                    group.insert(components: Array(parts), record: record)
                }
                return group
            }
        }

        if commits.count > 1 {
            // The reference Changes browser exposes the selected commit set as
            // one model, but still preserves the source commit for duplicate
            // paths. A root-qualified commit group gives the same invariant
            // without merging two different repositories that happen to use
            // the same object ID.
            return commits.compactMap { commit in
                let commitIdentity = logChangesCommitIdentity(commit)
                let commitRecords = logChangesCommitRecords(rows, for: commit)
                guard !commitRecords.isEmpty else { return nil }
                var group = LogChangeNode(
                    name: logChangesCommitGroupName(commit, among: commits),
                    path: "commit:\(commitIdentity)"
                )
                for record in commitRecords {
                    let parts = record.change.path.split(separator: "/")
                    group.insert(components: Array(parts), record: record)
                }
                return group
            }
        }

        var roots: [LogChangeNode] = []
        for record in rows {
            let parts = record.change.path.split(separator: "/")
            guard let first = parts.first else { continue }
            if let index = roots.firstIndex(where: { $0.name == first }) {
                roots[index].insert(components: Array(parts.dropFirst()), record: record)
            } else {
                var node = LogChangeNode(name: String(first), path: String(first))
                node.insert(components: Array(parts.dropFirst()), record: record)
                roots.append(node)
            }
        }
        return roots.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var flatChangeTree: [LogChangeNode] {
        rows.map { record in
            LogChangeNode(
                name: record.change.path,
                path: "file:\(record.id)",
                record: record
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Changes")
                    .font(.headline)
                Text(activeFilter == nil && !(showsOnlyAffectedChanges && hasAffectedPathFilter)
                     ? "\(rows.count) files"
                     : "\(rows.count)/\(records.count) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if showsOnlyAffectedChanges, !affectedPathSelections.isEmpty {
                    Text("Affected: \(logPathFilterSummary(affectedPathSelections))")
                        .font(.caption2)
                        .foregroundStyle(Design.Colors.accent)
                }
                if !filteredOutRecords.isEmpty {
                    Text("\(filteredOutRecords.count) filtered out")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !pendingFilterRecords.isEmpty {
                    Text("\(pendingFilterRecords.count) not filtered")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if commits.count == 1, let commit = commits.first {
                    if commit.parentIds.count > 1, showsChangesFromParents {
                        Text("All parents")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if commit.parentIds.count > 1 {
                        Picker("Parent", selection: $selectedParentIndex) {
                            ForEach(Array(commit.parentIds.enumerated()), id: \.offset) { index, parentID in
                                let shortParentID = String(parentID.prefix(7))
                                Text("Parent \(index + 1) (\(shortParentID))")
                                    .tag(index)
                            }
                        }
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .frame(width: 190)
                    } else if commit.parentIds.isEmpty {
                        Text("Root commit — 与空 tree 比较")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if commits.count > Self.maximumCommitsPerSelection {
                    Text("前 \(Self.maximumCommitsPerSelection)/\(commits.count) 个提交")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("多选 Changes 最多加载 50 个提交，避免阻塞 Log 工作区")
                }
                if isLoading { ProgressView().controlSize(.small) }
                if isFiltering {
                    ProgressView().controlSize(.small)
                    Text("Filtering changes…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let filterError {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Design.Colors.error)
                        .help(filterError)
                }
                Spacer()
                if showsDiffPreview {
                    if case .local = diffSource {
                        Text("Compare with Local")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("Diff View", selection: $presentationMode) {
                        ForEach(DiffPresentationMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                        .frame(width: 150)
                }
                Button {
                    guard let selectedRecord, selectedRecords.count == 1 else { return }
                    onShowFileHistoryForRevision(
                        selectedRecord.commit,
                        selectedRecord.change.path
                    )
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Show History for Revision")
                .disabled(selectedRecords.count != 1)
                if let selectedRecordIndex {
                    Button {
                        selectAdjacentChange(offset: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .help("Previous File")
                    .disabled(adjacentChangeIndex(count: rows.count, current: selectedRecordIndex, offset: -1) == nil)
                    Button {
                        selectAdjacentChange(offset: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .help("Next File")
                    .disabled(adjacentChangeIndex(count: rows.count, current: selectedRecordIndex, offset: 1) == nil)
                }
                if canApplySelectedChanges {
                    Button {
                        onApplySelectedChanges(selectedRecords, true)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Revert Selected Changes")
                }
                Menu {
                    Text("Hide Files")
                        .font(.caption)
                    Toggle(
                        LogChangesFilter.movedWithoutChanges.title,
                        isOn: filterBinding(for: .movedWithoutChanges)
                    )
                    Toggle(
                        LogChangesFilter.nonImportant.title,
                        isOn: filterBinding(for: .nonImportant)
                    )
                    if activeFilter != nil {
                        Divider()
                        Button("Clear Filter") { setFilter(nil) }
                    }
                } label: {
                    Image(systemName: activeFilter == nil
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(activeFilter == nil ? .secondary : Design.Colors.accent)
                .help("Filter By")
                .disabled(records.isEmpty || isLoading)
                if canEditSelectedChanges, let commit = commits.first {
                    Text("\(selectedRecords.count) selected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Menu {
                        Button("Drop Selected Changes…") {
                            onDropSelectedChanges(commit, selectedRecords.map(\.change.path))
                        }
                        Button("Extract Selected Changes…") {
                            onExtractSelectedChanges(commit, selectedRecords.map(\.change.path))
                        }
                    } label: {
                        Image(systemName: "wand.and.stars")
                    }
                    .menuStyle(.borderlessButton)
                    .foregroundStyle(.secondary)
                    .help("Rewrite the selected files in this commit")
                }
                Menu {
                    Toggle("Group by Directory", isOn: $groupByDirectory)
                    Toggle("Show Changes from Parents", isOn: $showsChangesFromParents)
                    if hasAffectedPathFilter {
                        Toggle("Show Only Affected Changes", isOn: $showsOnlyAffectedChanges)
                    }
                    Divider()
                        Button("Refresh Changes") { loadChanges() }
                    if let selectedRecord {
                        Button("Show Diff") {
                            openStandaloneDiff(selectedRecord)
                        }
                        if isSubmodule(selectedRecord.change) {
                            Button("Show Submodule Changes") {
                                showSubmoduleChanges(selectedRecord)
                            }
                        }
                        Button("Compare with Local") {
                            compareWithLocal(selectedRecord, revision: selectedRecord.commit.id)
                        }
                        if let beforeRevision = parentRevision(for: selectedRecord) {
                            Button("Compare Before with Local") {
                                compareWithLocal(selectedRecord, revision: beforeRevision)
                            }
                        }
                        Button("Edit Source") {
                            onEditSource(selectedRecord.change.path)
                        }
                        Button("Show File History") {
                            onShowFileHistory(selectedRecord.change.path)
                        }
                        Button("Show History for Revision") {
                            onShowFileHistoryForRevision(
                                selectedRecord.commit,
                                selectedRecord.change.path
                            )
                        }
                        Button("Show File at Revision") {
                            onOpenRepositoryVersion(
                                selectedRecord.commit,
                                selectedRecord.change.path
                            )
                        }
                        let hostedRemotes = hostedFileRemotes(for: selectedRecord)
                        switch hostedRemoteActionPresentation(for: hostedRemotes.count) {
                        case .direct where hostedRemotes.count == 1:
                            let remote = hostedRemotes[0]
                            Button("Browse File in Browser") {
                                onBrowseHostedFileRevision(selectedRecord, remote)
                            }
                            Button("Copy File Link") {
                                onCopyHostedFileRevision(selectedRecord, remote)
                            }
                        case .submenu:
                            Menu("Browse File in Browser") {
                                ForEach(hostedRemotes, id: \.name) { remote in
                                    Button(remote.name) {
                                        onBrowseHostedFileRevision(selectedRecord, remote)
                                    }
                                }
                            }
                            Menu("Copy File Link") {
                                ForEach(hostedRemotes, id: \.name) { remote in
                                    Button(remote.name) {
                                        onCopyHostedFileRevision(selectedRecord, remote)
                                    }
                                }
                            }
                        case .direct, .hidden:
                            EmptyView()
                        }
                        Button(selectedRecords.count > 1 ? "Get Versions" : "Get Version") {
                            onRestoreRepositoryVersion(
                                selectedRecords.isEmpty ? [selectedRecord] : selectedRecords
                            )
                        }
                        if canApplySelectedChanges {
                            Divider()
                            Button("Apply Selected Changes") {
                                onApplySelectedChanges(selectedRecords, false)
                            }
                            Button("Revert Selected Changes") {
                                onApplySelectedChanges(selectedRecords, true)
                            }
                        }
                        Divider()
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(selectedRecord.change.path, forType: .string)
                        }
                        Button("Copy Paths") {
                            copySelectedRecordPaths()
                        }
                        .disabled(selectedRecords.isEmpty)
                    }
                    if canCreatePatchSelection {
                        Divider()
                        Button("Create Patch…") {
                            if selectedRecords.isEmpty,
                               commits.count == 1,
                               let commit = commits.first {
                                onCreatePatch(commit)
                            } else {
                                onCreatePatchSelection(patchSelection)
                            }
                        }
                        Button("Copy Patch") {
                            onCopyPatchSelection(patchSelection)
                        }
                    }
                    if canEditSelectedChanges, let commit = commits.first {
                        Divider()
                        Button("Drop Selected Changes…") {
                            onDropSelectedChanges(commit, selectedRecords.map(\.change.path))
                        }
                        Button("Extract Selected Changes…") {
                            onExtractSelectedChanges(commit, selectedRecords.map(\.change.path))
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .overlay(alignment: .bottom) { Divider() }

            if let loadError {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Unable to load changed files", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Design.Colors.error)
                    Text(loadError)
                        .font(.caption)
                        .textSelection(.enabled)
                    Button("Retry") { loadChanges() }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
            } else if isLoading && rows.isEmpty {
                ProgressView("Loading changed files…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty && filteredOutRecords.isEmpty && pendingFilterRecords.isEmpty {
                Text(commits.isEmpty
                     ? "选择一个提交查看 Changes"
                     : (showsOnlyAffectedChanges && hasAffectedPathFilter
                        ? "No changes affect the selected path"
                        : (activeFilter == nil ? "No changed files" : "No files remain after filtering")))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showsDiffPreview {
                if diffPreviewVertical {
                    VSplitView {
                        changesTree
                        diffPreview
                            .frame(minHeight: 120, idealHeight: 240, maxHeight: .infinity)
                    }
                } else {
                    HSplitView {
                        changesTree
                        diffPreview
                            .frame(minWidth: 220, idealWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                changesTree
            }
        }
        .background(Design.Colors.canvas)
        .onAppear { loadChanges() }
        .onChange(of: commits.map { "\($0.repositoryPath ?? "")\u{1f}\($0.id)" }) { _, _ in
            selectedParentIndex = 0
            collapsedChangeNodes = []
            selectedRecordIDs = []
            loadChanges()
        }
        .onChange(of: selectedParentIndex) { _, _ in
            guard commits.count == 1 else { return }
            selectedRecordIDs = []
            loadChanges()
        }
        .onChange(of: showsChangesFromParents) { _, _ in
            selectedRecordIDs = []
            loadChanges()
        }
        .onChange(of: showsOnlyAffectedChanges) { _, _ in
            selectedRecordIDs = []
            selectedRecordID = nil
            fileDiff = nil
            diffError = nil
            diffSource = .commit
            normalizeSelectionAfterFiltering()
        }
        .onChange(of: affectedPathSelections) { _, _ in
            guard showsOnlyAffectedChanges else { return }
            selectedRecordIDs = []
            selectedRecordID = nil
            fileDiff = nil
            diffError = nil
            diffSource = .commit
            normalizeSelectionAfterFiltering()
        }
        .onChange(of: selectedRecordID) { _, id in loadDiff(id, source: diffSource) }
        .sheet(item: $submoduleChangeRequest) { request in
            if let repo = repositoryForCommit(request.commit) {
                SubmoduleChangeView(
                    repo: repo,
                    revision1: request.revision1,
                    revision2: request.revision2,
                    path: request.path,
                    onClose: { submoduleChangeRequest = nil }
                )
            } else {
                ContentUnavailableView {
                    Label("Submodule change unavailable", systemImage: "exclamationmark.triangle")
                }
            }
        }
        .sheet(item: $standaloneDiffRecord) { record in
            LogStandaloneDiffView(
                record: record,
                repositoryForCommit: repositoryForCommit
            )
        }
        .onDisappear {
            changesTask?.cancel()
            diffTask?.cancel()
            filterTask?.cancel()
        }
    }

    private var changesTree: some View {
        List {
            ForEach(groupByDirectory ? changeTree : flatChangeTree) { node in
                changeNode(node, depth: 0)
            }
            if !pendingFilterRecords.isEmpty {
                DisclosureGroup {
                    ForEach(pendingFilterRecords) { record in
                        changeNode(
                            LogChangeNode(
                                name: record.change.path,
                                path: "pending:\(record.id)",
                                record: record
                            ),
                            depth: 1,
                            isPending: true
                        )
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text("Not filtered")
                        Text("(\(pendingFilterRecords.count))")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !filteredOutRecords.isEmpty {
                DisclosureGroup("Filtered out (\(filteredOutRecords.count))") {
                    ForEach(filteredOutRecords) { record in
                        changeNode(
                            LogChangeNode(
                                name: record.change.path,
                                path: "filtered:\(record.id)",
                                record: record
                            ),
                            depth: 1,
                            isFilteredOut: true
                        )
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
        .focusable()
        .focused($changesTreeFocused)
        .onKeyPress(.upArrow, action: handleUpKeyPress)
        .onKeyPress(.downArrow, action: handleDownKeyPress)
        .onKeyPress(.return, action: handleReturnKeyPress)
        .frame(minWidth: 104, idealWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func changeNode(
        _ node: LogChangeNode,
        depth: Int,
        isFilteredOut: Bool = false,
        isPending: Bool = false
    ) -> AnyView {
        if let record = node.record, node.children.isEmpty {
            let contextActionRecords = contextualLogChangeSelection(
                context: record,
                selected: selectedRecords
            )
            let contextActionTitle = contextActionRecords.count > 1
                ? "Selected Changes"
                : "Change"
            let row = HStack(spacing: 7) {
                Text(changeKindText(record.change.kind))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .leading)
                Text(node.name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if commits.count > 1 {
                    Text(record.commit.shortId)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, CGFloat(min(depth, 8)) * 10)
            .padding(.vertical, 2)
            .background(
                !isFilteredOut && selectedRecordIDs.contains(record.id)
                    ? Color.accentColor.opacity(0.16)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
            if isFilteredOut || isPending {
                return AnyView(row.opacity(0.55))
            }
            let interactiveRow = row
                .contentShape(Rectangle())
                .onTapGesture { select(record) }
                .onTapGesture(count: 2) { openStandaloneDiff(record) }
                .contextMenu {
                    Button("Show Diff") { openStandaloneDiff(record) }
                    if isSubmodule(record.change) {
                        Button("Show Submodule Changes") {
                            showSubmoduleChanges(record)
                        }
                    }
                    Button("Compare with Local") {
                        compareWithLocal(record, revision: record.commit.id)
                    }
                    if let beforeRevision = parentRevision(for: record) {
                        Button("Compare Before with Local") {
                            compareWithLocal(record, revision: beforeRevision)
                        }
                    }
                    Button("Edit Source") {
                        onEditSource(record.change.path)
                    }
                    Button("Show File History") {
                        onShowFileHistory(record.change.path)
                    }
                    Button("Show History for Revision") {
                        onShowFileHistoryForRevision(record.commit, record.change.path)
                    }
                    Button("Show File at Revision") {
                        onOpenRepositoryVersion(record.commit, record.change.path)
                    }
                    let hostedRemotes = hostedFileRemotes(for: record)
                    switch hostedRemoteActionPresentation(for: hostedRemotes.count) {
                    case .direct where hostedRemotes.count == 1:
                        let remote = hostedRemotes[0]
                        Button("Browse File in Browser") {
                            onBrowseHostedFileRevision(record, remote)
                        }
                        Button("Copy File Link") {
                            onCopyHostedFileRevision(record, remote)
                        }
                    case .submenu:
                        Menu("Browse File in Browser") {
                            ForEach(hostedRemotes, id: \.name) { remote in
                                Button(remote.name) {
                                    onBrowseHostedFileRevision(record, remote)
                                }
                            }
                        }
                        Menu("Copy File Link") {
                            ForEach(hostedRemotes, id: \.name) { remote in
                                Button(remote.name) {
                                    onCopyHostedFileRevision(record, remote)
                                }
                            }
                        }
                    case .direct, .hidden:
                        EmptyView()
                    }
                    let restoreRecords = contextualLogChangeRestoreSelection(
                        context: record,
                        selected: selectedRecords
                    )
                    Button(restoreRecords.count > 1 ? "Get Versions" : "Get Version") {
                        onRestoreRepositoryVersion(restoreRecords)
                    }
                    Divider()
                    Button("Apply \(contextActionTitle)") {
                        onApplySelectedChanges(contextActionRecords, false)
                    }
                    Button("Revert \(contextActionTitle)") {
                        onApplySelectedChanges(contextActionRecords, true)
                    }
                    Divider()
                    Button("Copy path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(record.change.path, forType: .string)
                    }
                }
            return AnyView(interactiveRow)
        } else {
            let groupRecords = node.leafRecords
            let groupIDs = Set(groupRecords.map(\.id))
            let groupFullySelected = !groupIDs.isEmpty
                && groupIDs.isSubset(of: selectedRecordIDs)
            let groupPartiallySelected = !groupIDs.isEmpty
                && !groupFullySelected
                && !groupIDs.isDisjoint(with: selectedRecordIDs)
            let group = DisclosureGroup(isExpanded: Binding(
                get: { !collapsedChangeNodes.contains(node.id) },
                set: { expanded in
                    if expanded {
                        collapsedChangeNodes.remove(node.id)
                    } else {
                        collapsedChangeNodes.insert(node.id)
                    }
                }
            )) {
                ForEach(node.children) { child in
                    changeNode(
                        child,
                        depth: depth + 1,
                        isFilteredOut: isFilteredOut,
                        isPending: isPending
                    )
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: groupFullySelected
                          ? "checkmark.square.fill"
                          : groupPartiallySelected
                            ? "minus.square"
                            : "square")
                        .foregroundStyle(groupFullySelected || groupPartiallySelected
                                         ? Design.Colors.accent
                                         : .secondary)
                    Label(node.name, systemImage: node.record == nil ? "folder" : "doc.text")
                }
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !isFilteredOut, !isPending else { return }
                        let flags = NSEvent.modifierFlags
                        let selected = logChangeSelectionAfterGroupClick(
                            currentSelection: selectedRecordIDs,
                            groupIDs: groupIDs,
                            visibleIDs: rows.map(\.id),
                            anchorID: selectedRecordID,
                            command: flags.contains(.command),
                            shift: flags.contains(.shift)
                        )
                        selectedRecordIDs = selected
                        selectedRecordID = groupRecords.first(where: {
                            selected.contains($0.id)
                        })?.id
                        changesTreeFocused = true
                        diffSource = .commit
                    }
            }
            return AnyView(group)
        }
    }

    @ViewBuilder
    private var diffPreview: some View {
        VStack(spacing: 0) {
            if let selectedRecord, isSubmodule(selectedRecord.change) {
                HStack(spacing: 8) {
                    Label("Submodule gitlink", systemImage: "square.stack.3d.up")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show Submodule Changes") {
                        showSubmoduleChanges(selectedRecord)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(8)
                Divider()
            }

            Group {
                if let diffError {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Unable to load diff", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Design.Colors.error)
                        Text(diffError).font(.caption).textSelection(.enabled)
                        if let selectedRecordID {
                            Button("Retry") { loadDiff(selectedRecordID) }
                                .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12)
                } else if let fileDiff {
                    if presentationMode == .unified {
                        UnifiedDiffView(fileDiff: fileDiff)
                    } else {
                        SideBySideDiffView(fileDiff: fileDiff)
                    }
                } else if selectedRecordID != nil {
                    ProgressView("Loading diff…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("Select a changed file to view its diff")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func isSubmodule(_ change: TreeChange) -> Bool {
        change.oldMode == 0o160000 || change.newMode == 0o160000
    }

    private func showSubmoduleChanges(_ record: LogChangeRecord) {
        submoduleChangeRequest = SubmoduleChangeRequest(
            id: "\(logChangesCommitIdentity(record.commit)):\(record.parentIndex.map(String.init) ?? "root"):\(record.change.path)",
            commit: record.commit,
            revision1: parentRevision(for: record) ?? "",
            revision2: record.commit.id,
            path: record.change.path
        )
    }

    private func openStandaloneDiff(_ record: LogChangeRecord) {
        select(record, extending: false)
        standaloneDiffRecord = record
    }

    private func changeKindText(_ kind: TreeChangeKind) -> String {
        switch kind {
        case .added: return "新增"
        case .modified: return "修改"
        case .deleted: return "删除"
        case .renamed: return "重命名"
        }
    }

    private func loadChanges() {
        changesTask?.cancel()
        diffTask?.cancel()
        filterTask?.cancel()
        records = []
        filteredOutRecordIDs = []
        pendingFilterRecordIDs = []
        isFiltering = false
        filterError = nil
        selectedRecordID = nil
        selectedRecordIDs = []
        fileDiff = nil
        diffError = nil
        loadError = nil
        diffSource = .commit
        guard !commits.isEmpty else {
            isLoading = false
            return
        }

        let expectedIDs = commits.map { "\($0.repositoryPath ?? "")\u{1f}\($0.id)" }
        let selectedCommits = Array(commits.prefix(Self.maximumCommitsPerSelection))
        let selectedParent = selectedParentIndex
        let showAllParents = showsChangesFromParents
        let repositoryResolver = repositoryForCommit
        isLoading = true
        changesTask = Task.detached(priority: .utility) {
            do {
                var loaded: [LogChangeRecord] = []
                for commit in selectedCommits {
                    guard !Task.isCancelled else { return }
                    guard let repo = repositoryResolver(commit) else { continue }
                    let parentIndices = logChangeParentIndices(
                        commit: commit,
                        selectedCommitCount: selectedCommits.count,
                        selectedParentIndex: selectedParent,
                        showsChangesFromParents: showAllParents
                    )
                    for parentIndex in parentIndices {
                        let diff = try repo.commitDiff(commitId: commit.id, parentIndex: parentIndex)
                        loaded.append(contentsOf: diff.changes.map {
                            LogChangeRecord(commit: commit, parentIndex: parentIndex, change: $0)
                        })
                    }
                }
                guard !Task.isCancelled else { return }
                let loadedRecords = loaded
                await MainActor.run {
                    guard self.commits.map({ "\($0.repositoryPath ?? "")\u{1f}\($0.id)" }) == expectedIDs else { return }
                    self.records = loadedRecords
                    self.isLoading = false
                    self.restartActiveFilter()
                }
            } catch {
                await MainActor.run {
                    guard self.commits.map({ "\($0.repositoryPath ?? "")\u{1f}\($0.id)" }) == expectedIDs else { return }
                    self.isLoading = false
                    self.loadError = "\(error)"
                }
            }
        }
    }

    private func select(_ record: LogChangeRecord, extending: Bool? = nil) {
        changesTreeFocused = true
        diffSource = .commit
        let flags = NSEvent.modifierFlags
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        let shouldExtend = extending ?? (command || shift)
        if shift,
           let anchor = selectedRecordID,
           let start = rows.firstIndex(where: { $0.id == anchor }),
           let end = rows.firstIndex(where: { $0.id == record.id }) {
            let range = start <= end ? start...end : end...start
            selectedRecordIDs = Set(range.map { rows[$0].id })
        } else if command || shouldExtend {
            if selectedRecordIDs.contains(record.id) {
                selectedRecordIDs.remove(record.id)
            } else {
                selectedRecordIDs.insert(record.id)
            }
        } else {
            selectedRecordIDs = [record.id]
        }
        if selectedRecordIDs.isEmpty {
            selectedRecordID = nil
        } else if selectedRecordIDs.contains(record.id) {
            // Keep the clicked row as the active diff even when other files
            // remain selected for a batch action.
            selectedRecordID = record.id
        } else {
            selectedRecordID = rows.first(where: { selectedRecordIDs.contains($0.id) })?.id
        }
    }

    private var selectedRecordIndex: Int? {
        guard let selectedRecordID else { return nil }
        return rows.firstIndex(where: { $0.id == selectedRecordID })
    }

    private func selectAdjacentChange(offset: Int) {
        guard let selectedRecordIndex,
              let nextIndex = adjacentChangeIndex(
                  count: rows.count,
                  current: selectedRecordIndex,
                  offset: offset
              ) else { return }
        select(rows[nextIndex], extending: false)
    }

    private func moveSelection(by offset: Int) {
        guard let nextIndex = keyboardChangeIndex(
            count: rows.count,
            current: selectedRecordIndex,
            offset: offset
        ) else { return }
        select(rows[nextIndex], extending: false)
    }

    private func handleUpKeyPress() -> KeyPress.Result {
        moveSelection(by: -1)
        return .handled
    }

    private func handleDownKeyPress() -> KeyPress.Result {
        moveSelection(by: 1)
        return .handled
    }

    private func handleReturnKeyPress() -> KeyPress.Result {
        guard let selectedRecord else { return .ignored }
        openStandaloneDiff(selectedRecord)
        return .handled
    }

    private func copySelectedRecordPaths() {
        let paths = selectedRecords.map { $0.change.path }
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    private func parentRevision(for record: LogChangeRecord) -> String? {
        if let parentIndex = record.parentIndex {
            let index = Int(parentIndex)
            if record.commit.parentIds.indices.contains(index) {
                return record.commit.parentIds[index]
            }
        }
        return record.commit.parentIds.first
    }

    private func compareWithLocal(_ record: LogChangeRecord, revision: String) {
        let source = LogDiffSource.local(revision: revision)
        diffSource = source
        selectedRecordIDs = [record.id]
        if selectedRecordID == record.id {
            loadDiff(record.id, source: source)
        } else {
            selectedRecordID = record.id
        }
    }

    private func loadDiff(_ id: String?, source: LogDiffSource? = nil) {
        diffTask?.cancel()
        fileDiff = nil
        diffError = nil
        guard let id, let record = rows.first(where: { $0.id == id }),
              let repo = repositoryForCommit(record.commit) else { return }
        let expectedID = id
        let requestedSource = source ?? diffSource
        diffTask = Task.detached(priority: .userInitiated) {
            do {
                let diff: FileDiff
                switch requestedSource {
                case .commit:
                    diff = try repo.commitFileDiffWithSettings(
                        commitId: record.commit.id,
                        parentIndex: record.parentIndex,
                        path: record.change.path,
                        settings: makeArborGitDiffSettings()
                    )
                case let .local(revision):
                    diff = try repo.diffRevisionPathWithWorktreeWithSettings(
                        revision: revision,
                        revisionPath: record.change.path,
                        worktreePath: record.change.path,
                        settings: makeArborGitDiffSettings()
                    )
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.selectedRecordID == expectedID,
                          self.diffSource == requestedSource else { return }
                    self.fileDiff = diff
                }
            } catch {
                await MainActor.run {
                    guard self.selectedRecordID == expectedID,
                          self.diffSource == requestedSource else { return }
                    self.diffError = "\(error)"
                }
            }
        }
    }
}

/// Standalone Changes Browser diff action. The inline preview is optional in
/// IntelliJ, but Show Diff, double-click, and Enter remain meaningful when
/// that preview is hidden; keep the same distinction instead of making the
/// action silently reselect the current row.
private struct LogStandaloneDiffView: View {
    let record: LogChangeRecord
    let repositoryForCommit: (CommitInfo) -> Repository?

    @Environment(\.dismiss) private var dismiss
    @State private var fileDiff: FileDiff?
    @State private var diffError: String?
    @State private var presentationMode: DiffPresentationMode = .sideBySide
    @State private var diffTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Diff")
                    .font(.headline)
                Text(record.change.path)
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(1)
                Text(record.commit.shortId)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Diff View", selection: $presentationMode) {
                    ForEach(DiffPresentationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 150)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            .overlay(alignment: .bottom) { Divider() }

            if let diffError {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Unable to load diff", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Design.Colors.error)
                    Text(diffError)
                        .font(.caption)
                        .textSelection(.enabled)
                    Button("Retry") { load() }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
            } else if let fileDiff {
                if fileDiff.binary && fileDiff.hunks.isEmpty {
                    ContentUnavailableView(
                        "Binary File",
                        systemImage: "doc.zipper",
                        description: Text("Git reported a binary change for this path.")
                    )
                } else if presentationMode == .unified {
                    UnifiedDiffView(fileDiff: fileDiff)
                } else {
                    SideBySideDiffView(fileDiff: fileDiff)
                }
            } else {
                ProgressView("Loading diff…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .task(id: record.id) { load() }
        .onDisappear { diffTask?.cancel() }
    }

    private func load() {
        diffTask?.cancel()
        fileDiff = nil
        diffError = nil
        guard let repo = repositoryForCommit(record.commit) else {
            diffError = "The repository for this change is no longer available."
            return
        }
        let commitID = record.commit.id
        let parentIndex = record.parentIndex
        let path = record.change.path
        let expectedID = record.id
        diffTask = Task.detached(priority: .userInitiated) {
            do {
                let diff = try repo.commitFileDiffWithSettings(
                    commitId: commitID,
                    parentIndex: parentIndex,
                    path: path,
                    settings: makeArborGitDiffSettings()
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.record.id == expectedID else { return }
                    self.fileDiff = diff
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.record.id == expectedID else { return }
                    self.diffError = "\(error)"
                }
            }
        }
    }
}

/// IntelliJ's details panel is a list panel, not a single-commit inspector:
/// Cmd/Shift selection in the graph produces one details card per selected
/// commit while the changes browser remains usable below it. The old Arbor
/// view highlighted several rows but silently kept showing only the active
/// row, which made multi-selection look broken. Keep the common changes and
/// diff surface lightweight, and load each selected commit's tree off the
/// main actor.
private var selectedLogCommits: [CommitInfo] {
    let entries = logViewMode == .command ? logCommandEntries : logEntries
    let selected = entries.filter { logSelectedIDs.contains(logCommitIdentity($0)) }
    if selected.count > 1 { return selected }
    if let selectedCommit { return [selectedCommit] }
    return []
}

private var logActionAvailability: LogActionAvailability {
    LogActionAvailability(
        hasLocalChanges: hasLocalChanges,
        activeOperationRootPath: operationState == nil ? nil : repo?.workdir(),
        hasRemotes: !remotes.isEmpty
    )
}

/// Route menu-level graph actions through a changing command identity so
/// repeated Collapse/Expand requests are delivered even when their action type
/// is unchanged.
private func issueLogGraphCommand(_ action: LinearBekGraphActionType) {
    logGraphCommand = LinearBekGraphCommand(
        id: (logGraphCommand?.id ?? 0) + 1,
        action: action
    )
}

/// Mirrors IntelliJ's windowed VCS Log status loader. Signature verification
/// is deliberately not part of the main log query: GPG/SSH verification can
/// be slow or unavailable, so only the currently loaded rows request a
/// cancellable background batch and stale generations are discarded.
func loadLogSignatureStatuses() {
    guard logShowSignatureColumn, logViewMode == .graph else {
        logSignatureLoadTask?.cancel()
        logSignatureLoadingIDs.removeAll()
        logSignatureFailedIDs.removeAll()
        return
    }

    let commits = logEntries
    guard !commits.isEmpty else {
        logSignatureLoadTask?.cancel()
        logSignatureLoadingIDs.removeAll()
        logSignatureFailedIDs.removeAll()
        return
    }

    logSignatureLoadTask?.cancel()
    logSignatureGeneration += 1
    let generation = logSignatureGeneration
    let aggregate = isLogAggregate
    let grouped = Dictionary(grouping: commits) { $0.repositoryPath ?? "" }
    var requests: [LogSignatureBatchRequest] = []
    var unavailableKeys: Set<String> = []

    for (_, rootCommits) in grouped {
        let pending = rootCommits.filter { commit in
            let key = logCommitDisplayIdentity(
                repositoryPath: commit.repositoryPath,
                id: commit.id,
                aggregate: aggregate
            )
            return logSignatureStatuses[key] == nil
        }
        guard !pending.isEmpty else { continue }
        guard let repository = logRepository(for: pending) else {
            unavailableKeys.formUnion(pending.map { commit in
                logCommitDisplayIdentity(
                    repositoryPath: commit.repositoryPath,
                    id: commit.id,
                    aggregate: aggregate
                )
            })
            continue
        }
        requests.append(LogSignatureBatchRequest(
            repository: repository,
            commitIDs: pending.map(\.id),
            keyByCommitID: Dictionary(uniqueKeysWithValues: pending.map { commit in
                let key = logCommitDisplayIdentity(
                    repositoryPath: commit.repositoryPath,
                    id: commit.id,
                    aggregate: aggregate
                )
                return (commit.id, key)
            })
        ))
    }

    let requestedKeys = Set(requests.flatMap { $0.keyByCommitID.values })
    logSignatureLoadingIDs = requestedKeys
    logSignatureFailedIDs.formUnion(unavailableKeys)
    guard !requests.isEmpty else {
        return
    }
    logSignatureFailedIDs.subtract(requestedKeys)

    let task = Task { @MainActor in
        let result = await Task.detached(priority: .userInitiated) {
            () -> LogSignatureLoadResult? in
            var statuses: [String: CommitSignatureInfo] = [:]
            var failedKeys: Set<String> = []
            for request in requests {
                guard !Task.isCancelled else { return nil }
                do {
                    let loaded = try request.repository.commitSignatureStatuses(
                        commitIds: request.commitIDs
                    )
                    let loadedKeys = Set(loaded.compactMap {
                        request.keyByCommitID[$0.commitId]
                    })
                    for info in loaded {
                        if let key = request.keyByCommitID[info.commitId] {
                            statuses[key] = info
                        }
                    }
                    failedKeys.formUnion(
                        request.keyByCommitID.values.filter { !loadedKeys.contains($0) }
                    )
                } catch {
                    failedKeys.formUnion(request.keyByCommitID.values)
                }
            }
            return LogSignatureLoadResult(statuses: statuses, failedKeys: failedKeys)
        }.value

        guard !Task.isCancelled,
              generation == logSignatureGeneration,
              let result else { return }
        logSignatureStatuses.merge(result.statuses) { _, new in new }
        logSignatureLoadingIDs.subtract(requestedKeys)
        logSignatureFailedIDs.formUnion(result.failedKeys)
    }
    logSignatureLoadTask = task
}

func copySelectedComparePaths() {
    let paths = orderedCompareSelection(
        changes: treeChanges,
        selectedPaths: compareSelectedPaths
    ).map(\.path)
    guard !paths.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
}

func synchronizeReflogSelection() {
    let validIDs = Set(reflogEntries.map(reflogEntryIdentifier))
    let normalized = reflogSelectedIDs.intersection(validIDs)
    if normalized != reflogSelectedIDs {
        reflogSelectedIDs = normalized
        return
    }
    if let reflogSelection, normalized.contains(reflogSelection) {
        return
    }
    reflogSelection = orderedReflogSelection(
        entries: reflogEntries,
        selectedIDs: normalized
    ).first.map(reflogEntryIdentifier)
}

func copySelectedReflogIDs() {
    let ids = orderedUniqueReflogCommitIDs(selectedReflogEntries)
    guard !ids.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(ids.joined(separator: "\n"), forType: .string)
}

private var cherryPickCompareBranchChoices: [String] {
    var names: [String]
    if isLogAggregate {
        // An aggregate Log has no single active Repository. Apply the chosen
        // source name independently to every root that exposes that ref.
        let aggregateRootPaths = Set(
            logAggregateBranchFilters.map(\.rootPath)
                + logAggregateRevisionRanges.map(\.rootPath)
                + Array(logAggregateRootPaths)
        )
        let eligibleSnapshots = multiRootBranchSnapshots.filter {
            aggregateRootPaths.contains($0.rootPath)
        }
        names = eligibleSnapshots.flatMap { snapshot in
            snapshot.branches.map(\.name) + snapshot.remoteBranches.map(\.name)
        }
    } else {
        names = branches.map(\.name) + remoteBranches.map(\.name)
    }
    if !logCherryPickCompareBranch.isEmpty && !names.contains(logCherryPickCompareBranch) {
        names.append(logCherryPickCompareBranch)
    }
    return Array(Set(names)).sorted()
}

private var cherryPickTargetBranch: String {
    if isLogAggregate {
        return "each repository's current branch"
    }
    return Arbor.cherryPickTargetBranch(
        mode: logViewMode,
        sourceBranch: logCherryPickCompareBranch,
        firstBranch: compareRev1,
        secondBranch: compareRev2,
        currentBranch: branches.first(where: \.isCurrent)?.name
    )
}

private var logColumnLayout: LogColumnLayout {
    LogColumnLayout(orderRaw: logColumnOrderRaw, widthsRaw: logColumnWidthsRaw)
}

private var showAuthorAndDateBinding: Binding<Bool> {
    Binding(
        get: {
            (logShowCommitColumns || logShowAuthorColumn)
                && (logShowCommitColumns || logShowDateColumn)
        },
        set: { visible in
            logShowCommitColumns = visible
            logShowAuthorColumn = visible
            logShowDateColumn = visible
        }
    )
}

private var showAuthorColumnBinding: Binding<Bool> {
    Binding(
        get: { logShowCommitColumns || logShowAuthorColumn },
        set: { visible in
            logShowAuthorColumn = visible
            if !visible { logShowCommitColumns = false }
        }
    )
}

private var showDateColumnBinding: Binding<Bool> {
    Binding(
        get: { logShowCommitColumns || logShowDateColumn },
        set: { visible in
            logShowDateColumn = visible
            if !visible { logShowCommitColumns = false }
        }
    )
}

private func moveLogColumn(_ column: LogColumnID, by offset: Int) {
    logColumnOrderRaw = logColumnLayout.moving(column, by: offset).orderRaw
}

private func canMoveLogColumn(_ column: LogColumnID, by offset: Int) -> Bool {
    guard let index = logColumnLayout.order.firstIndex(of: column) else { return false }
    return logColumnLayout.order.indices.contains(index + offset)
}

private func resizeLogColumn(_ column: LogColumnID, by delta: CGFloat) {
    logColumnWidthsRaw = logColumnLayout
        .settingWidth(logColumnLayout.width(for: column) + delta, for: column)
        .widthsRaw
}

private func setLogColumnWidth(_ column: LogColumnID, to width: CGFloat) {
    logColumnWidthsRaw = logColumnLayout.settingWidth(width, for: column).widthsRaw
}

private var externalLogRootsMenu: some View {
    Menu {
        if multiRoots.isEmpty {
            Text("No Git roots available")
        } else {
            Button("Select All Roots") {
                selectAllExternalLogRoots()
            }
            Button("Select Current Project Root") {
                selectPrimaryExternalLogRoot()
            }
            Divider()
            ForEach(multiRoots, id: \.path) { root in
                let normalizedPath = canonicalExternalLogPath(root.path)
                let title = root.relativePath == "."
                    ? root.displayName
                    : "\(root.displayName) · \(root.relativePath)"
                Toggle(
                    isOn: Binding(
                        get: { logAggregateRootPaths.contains(normalizedPath) },
                        set: { setExternalLogRootSelection(root.path, selected: $0) }
                    )
                ) {
                    Text(title)
                }
                .disabled(logAggregateRootPaths.count == 1 && logAggregateRootPaths.contains(normalizedPath))
            }
        }
    } label: {
        Label(
            "Git Roots \(logAggregateRootPaths.count)/\(multiRoots.count)",
            systemImage: "folder"
        )
    }
    .menuStyle(.borderlessButton)
    .help("Choose which Git roots appear in this external Log window")
}

private var logRefreshButtonTitle: String {
    logViewMode == .reflog ? "Refresh Reflog" : "Refresh Log"
}

private var shouldShowLogError: Bool {
    logViewMode != .command
}

private var hasSelectedReflogEntries: Bool {
    !reflogSelectedIDs.isEmpty
}

private var reflogHistoryContent: some View {
    VStack(spacing: 0) {
        HStack(spacing: 8) {
            Text("Reflog")
                .font(.headline)
            Text("\(reflogEntries.count) entries")
                .font(.caption)
                .foregroundStyle(.secondary)
            if hasSelectedReflogEntries {
                Text("\(reflogSelectedIDs.count) selected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ForEach(availableReflogRootPaths, id: \.self) { rootPath in
                    Button {
                        selectReflogRoot(rootPath)
                    } label: {
                        Text(rootPath)
                    }
                }
            } label: {
                Label(reflogRootTitle, systemImage: "externaldrive")
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .help("Reflog repository")
            Button {
                loadReflog()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh Reflog")
            Menu {
                Button("Select All") {
                    reflogSelectedIDs = Set(reflogEntries.map(reflogEntryIdentifier))
                    reflogSelection = reflogEntries.first.map(reflogEntryIdentifier)
                }
                .disabled(reflogEntries.isEmpty)
                Button("Clear") {
                    reflogSelectedIDs = []
                    reflogSelection = nil
                }
                .disabled(reflogSelectedIDs.isEmpty)
                Divider()
                Button("Copy Selected Revision IDs") {
                    copySelectedReflogIDs()
                }
                .disabled(reflogSelectedIDs.isEmpty)
                if !selectedReflogCommits.isEmpty {
                    Divider()
                    Menu("Reflog actions") {
                        if selectedReflogCommits.count == 1,
                           let commit = selectedReflogCommits.first {
                            Button("Checkout Revision") {
                                checkoutFromLog(commit)
                            }
                            Button("Reset Current Branch to Here…") {
                                resetFromLog(commit)
                            }
                            Button("Create Branch from Commit") {
                                createBranchFromCommit(commit)
                            }
                            Button("Compare with Current…") {
                                compareFromLog(commit)
                            }
                            Button("Interactive Rebase from Here…") {
                                interactiveRebaseFromLog(commit)
                            }
                            .disabled(!isInteractiveRebaseAvailable(for: commit))
                            Divider()
                            Button("Cherry-pick") {
                                cherryPickFromLog(commit)
                            }
                            Button("Revert Commit") {
                                revertFromLog(commit)
                            }
                            .disabled(commit.parentIds.count != 1)
                        } else {
                            Button("Cherry-pick Selected Commits") {
                                cherryPickCommitsFromLog(selectedReflogCommits)
                            }
                            Button("Revert Selected Commits") {
                                revertCommitsFromLog(selectedReflogCommits)
                            }
                            .disabled(
                                selectedReflogCommits.contains { $0.parentIds.count != 1 }
                            )
                            Text("Checkout, reset, branch, compare and rebase require one selected revision.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .help("Reflog actions")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .overlay(alignment: .bottom) { Divider() }

        List(selection: $reflogSelectedIDs) {
            ForEach(reflogEntries, id: \.self) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.message).lineLimit(1)
                    Text("\(entry.oldId.prefix(7)) → \(entry.newId.prefix(7)) · \(dateStr(entry.time))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(reflogEntryIdentifier(entry))
                .simultaneousGesture(TapGesture().onEnded {
                    reflogSelection = reflogEntryIdentifier(entry)
                })
                .contextMenu {
                    Button("View Commit Details") {
                        let id = reflogEntryIdentifier(entry)
                        reflogSelection = id
                        reflogSelectedIDs = [id]
                    }
                    Button("Copy Revision ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.newId, forType: .string)
                    }
                    if let commit = reflogCommit(for: entry) {
                        Divider()
                        Button("Checkout Revision") { checkoutFromLog(commit) }
                        Button("Reset Current Branch to Here…") { resetFromLog(commit) }
                        Button("Create Branch from Commit") { createBranchFromCommit(commit) }
                        Button("Compare with Current…") { compareFromLog(commit) }
                        Button("Interactive Rebase from Here…") {
                            interactiveRebaseFromLog(commit)
                        }
                        .disabled(!isInteractiveRebaseAvailable(for: commit))
                        Divider()
                        Button("Cherry-pick") { cherryPickFromLog(commit) }
                        Button("Revert Commit") { revertFromLog(commit) }
                            .disabled(commit.parentIds.count != 1)
                    }
                }
            }
        }
        .listStyle(.inset)
        if reflogHasMore || isLoadingMoreReflog {
            HStack(spacing: 8) {
                Spacer()
                if isLoadingMoreReflog {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading older entries…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Load Older Entries") {
                        loadMoreReflog()
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .background(Design.Colors.canvas)
        }
    }
}

private var logGraphPanel: some View {
    VStack(spacing: 0) {
        HStack(spacing: 10) {
            Button {
                logViewMode = .graph
            } label: {
                Label("Log", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 32)
            }
            .buttonStyle(.borderedProminent)
            .tint(Design.Colors.accent)

            if externalLogWindow {
                externalLogRootsMenu
            }

            Menu {
                Picker("Log view", selection: $logViewMode) {
                    Text("History").tag(LogViewMode.graph)
                    Text("Git Log Command").tag(LogViewMode.command)
                    Text("Compare").tag(LogViewMode.compare)
                    Text("Tags").tag(LogViewMode.tags)
                    Text("Reflog").tag(LogViewMode.reflog)
                }
                Picker("Sort", selection: $logGraphSortModeRaw) {
                    ForEach(LogGraphSortChoice.allCases) { choice in
                        Text(choice.title).tag(choice.rawValue)
                    }
                }
                Divider()
                Toggle("Show Commit Details", isOn: $logShowDetails)
                Toggle("Show Diff Preview", isOn: $logShowDiffPreview)
                Toggle("Diff Preview on Bottom", isOn: $logDiffPreviewVertical)
                Divider()
                Toggle("Compact References", isOn: $logCompactReferences)
                Menu("Log Columns") {
                    Toggle("Show Author and Date", isOn: showAuthorAndDateBinding)
                    Toggle("Show Author", isOn: showAuthorColumnBinding)
                    Toggle("Show Date", isOn: showDateColumnBinding)
                    Toggle("Show Commit Hash", isOn: $logShowHashColumn)
                    Toggle("Show Root Names", isOn: $logShowRootColumn)
                    Toggle("Show Commit Signature", isOn: $logShowSignatureColumn)
                    Divider()
                    ForEach(LogColumnID.allCases) { column in
                        Menu(column.title) {
                            Button("Wider") { resizeLogColumn(column, by: 16) }
                                .disabled(!column.isResizable)
                            Button("Narrower") { resizeLogColumn(column, by: -16) }
                                .disabled(!column.isResizable)
                            Divider()
                            Button("Move Left") { moveLogColumn(column, by: -1) }
                                .disabled(!canMoveLogColumn(column, by: -1))
                            Button("Move Right") { moveLogColumn(column, by: 1) }
                                .disabled(!canMoveLogColumn(column, by: 1))
                        }
                    }
                    Divider()
                    Button("Reset Column Order") {
                        logColumnOrderRaw = LogColumnLayout.defaultOrder.map(\.rawValue).joined(separator: ",")
                    }
                    Button("Reset Column Widths") {
                        logColumnWidthsRaw = ""
                    }
                }
                Toggle("Show Tag Names", isOn: $logShowTagNames)
                Toggle("Align Labels", isOn: $logAlignLabels)
                Toggle("Show Long Edges", isOn: $logShowLongEdges)
                Button("Collapse All Graph") {
                    issueLogGraphCommand(.buttonCollapse)
                }
                .disabled(logViewMode != .graph)
                Button("Expand All Graph") {
                    issueLogGraphCommand(.buttonExpand)
                }
                .disabled(logViewMode != .graph)
                Toggle("Collapse Graph", isOn: $logCollapseGraph)
                Toggle("No Merges", isOn: $logNoMerges)
                Toggle("Show Branches", isOn: $logBranchesVisible)
                Divider()
                Button("Go to Parent") { selectParentLogCommit() }
                    .disabled(selectedCommit?.parentIds.isEmpty ?? true)
                Button("Go to Child") { selectChildLogCommit() }
                    .disabled(selectedCommit == nil)
                Button("Copy Selected Revision IDs") { copySelectedLogIDs() }
                    .disabled(logSelectedIDs.isEmpty)
                Divider()
                Menu("More Log Actions") {
                    Button("Show Git Log Command…") {
                        logCommandFilter = ""
                        logCommandEntries = []
                        logCommandError = nil
                        logViewMode = .command
                    }
                    Button("Create Patch…") {
                        if let selectedCommit { createPatchFromLog(selectedCommit) }
                    }
                    .disabled(selectedCommit == nil || logSelectedIDs.count > 1)
                    .help("Create a patch for one selected commit")
                    Button("Reset Selected Revisions…") {
                        resetFromLog(selectedLogCommits)
                    }
                    .disabled(
                        !isResetSelectionAvailable(for: selectedLogCommits)
                            || !logActionAvailability.allowsMutation(for: selectedLogCommits)
                    )
                    .help("Reset one selected revision per Git root")
                    Button("Create Fixup Commit…") {
                        if let selectedCommit {
                            beginAutoSquashCommitFromLog(selectedCommit, kind: .fixup)
                        }
                    }
                    .disabled(
                        selectedCommit == nil
                            || !logActionAvailability.hasLocalChanges
                            || (selectedCommit.map { !logActionAvailability.allowsHistoryRewrite(for: [$0]) } ?? true)
                    )
                    Button("Create Squash Commit…") {
                        if let selectedCommit {
                            beginAutoSquashCommitFromLog(selectedCommit, kind: .squash)
                        }
                    }
                    .disabled(
                        selectedCommit == nil
                            || !logActionAvailability.hasLocalChanges
                            || (selectedCommit.map { !logActionAvailability.allowsHistoryRewrite(for: [$0]) } ?? true)
                    )
                    Button("Squash Selected Commits…") {
                        rewriteSelectedCommitsFromLog(selectedLogCommits, action: .squash)
                    }
                    .disabled(
                        !areLogRewriteSelectionActionsAvailable(for: selectedLogCommits)
                            || !logActionAvailability.allowsSingleRootHistoryRewrite(for: selectedLogCommits)
                    )
                    Button("Reword Selected Commits…") {
                        rewriteSelectedCommitsFromLog(selectedLogCommits, action: .reword)
                    }
                    .disabled(
                        !areLogRewriteSelectionActionsAvailable(for: selectedLogCommits)
                            || !logActionAvailability.allowsSingleRootHistoryRewrite(for: selectedLogCommits)
                    )
                    Button("Drop Selected Commits…", role: .destructive) {
                        rewriteSelectedCommitsFromLog(selectedLogCommits, action: .drop)
                    }
                    .disabled(
                        !areLogRewriteSelectionActionsAvailable(for: selectedLogCommits)
                            || !logActionAvailability.allowsSingleRootHistoryRewrite(for: selectedLogCommits)
                    )
                    Button("Toggle Log Columns") {
                        showAuthorAndDateBinding.wrappedValue.toggle()
                    }
                    Menu("Highlight Cherry-Picked Commits") {
                        Picker("Compared branch", selection: $logCherryPickCompareBranch) {
                            Text("Choose source branch…").tag("")
                            ForEach(cherryPickCompareBranchChoices, id: \.self) { branch in
                                Text(branch).tag(branch)
                            }
                        }
                        Toggle("Enable Highlighting", isOn: $logHighlightCherryPicked)
                            .disabled(logCherryPickCompareBranch.isEmpty)
                        if !logCherryPickCompareBranch.isEmpty {
                            Text("Target: \(cherryPickTargetBranch)")
                        }
                        if logCherryPickComparisonInProgress {
                            Label(
                                "Comparing cherry-picked commits… (\(logCherryPickComparisonCompletedRoots)/\(logCherryPickComparisonTotalRoots))",
                                systemImage: "hourglass"
                            )
                            Button("Cancel Comparison") {
                                cancelCherryPickedHighlighting()
                            }
                        }
                    }
                    Toggle("Show Changes from Parents", isOn: $logShowChangesFromParents)
                    if logViewMode == .graph, !activeLogPathFilterSelections().isEmpty {
                        Toggle("Show Only Affected Changes", isOn: $logShowOnlyAffectedChanges)
                    }
                    Button("Open Log in New Window") {
                        guard let projectPath,
                              let request = chooseExternalLogWindowRequest(for: projectPath) else {
                            return
                        }
                        openWindow(id: "git-log", value: request)
                    }
                    .disabled(projectRepo == nil || projectPath == nil)
                    Button("Open Another Log Tab") { openAnotherLogTab() }
                }
                Divider()
                Button(logRefreshButtonTitle) {
                    reloadLogView()
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "ellipsis")
                    Image(systemName: "chevron.down")
                }
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 32)
            }
            .menuStyle(.borderlessButton)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Design.Colors.chrome)
        .overlay(alignment: .bottom) { Divider() }
        .onChange(of: logViewMode) { _, mode in
            if mode == .graph {
                activeCompareRepo = nil
                compareRepositoryPath = nil
                loadLog()
            } else if mode == .reflog {
                activeCompareRepo = nil
                compareRepositoryPath = nil
                prepareReflogRoot()
            } else if mode == .command {
                activeCompareRepo = nil
                compareRepositoryPath = nil
                runLogCommand()
            } else if mode == .tags {
                activeCompareRepo = nil
                compareRepositoryPath = nil
                // Tags is its own Log sub-view. Do not leave the last History
                // commit rendered in the inspector while the left workspace
                // has already switched to tag management.
                logSelection = nil
                logSelectedIDs = []
            }
        }
        .onChange(of: logGraphSortModeRaw) { _, _ in
            guard logViewMode == .graph else { return }
            scheduleLogRefresh()
        }
        .onChange(of: logMessageRegex) { _, _ in
            guard logViewMode == .graph else { return }
            scheduleLogRefresh()
        }
        .onChange(of: logMessageMatchCase) { _, _ in
            guard logViewMode == .graph else { return }
            scheduleLogRefresh()
        }
        .onChange(of: logNoMerges) { _, _ in
            guard logViewMode == .graph else { return }
            scheduleLogRefresh()
        }
        .onChange(of: logCherryPickCompareBranch) { _, branch in
            logHighlightCherryPicked = cherryPickHighlightEnabledAfterSourceChange(
                sourceBranch: branch,
                currentlyEnabled: logHighlightCherryPicked
            )
            refreshCherryPickedHighlights()
        }
        .onChange(of: logHighlightCherryPicked) { _, _ in
            refreshCherryPickedHighlights()
        }

        if logTabs.count > 1 {
            LogTabBar(
                tabs: logTabs,
                activeID: currentLogTabID,
                onSelect: switchLogTab,
                onClose: closeLogTab,
                onNew: openAnotherLogTab
            )
        }

        if logViewMode == .command {
            logCommandFilterBar
        } else if logViewMode == .graph {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                logFilterField("Text or hash", text: $logMessageFilter, width: 215)
                    .onSubmit { scheduleLogRefresh() }
                Menu {
                    Toggle("Regex", isOn: $logMessageRegex)
                    Toggle("Match Case", isOn: $logMessageMatchCase)
                    Divider()
                    Button("Clear Text Filter") {
                        logMessageFilter = ""
                        scheduleLogRefresh()
                    }
                    .disabled(logMessageFilter.isEmpty)
                } label: {
                    Label("Text Filter Settings", systemImage: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle((logMessageRegex || logMessageMatchCase) ? Design.Colors.accent : .secondary)
                .help("Text Filter Settings")
                HStack(spacing: 4) {
                    let currentPathSelections = activeLogPathFilterSelections()
                    if currentPathSelections.count > 1 {
                        Button {
                            openLogPathsEditor()
                        } label: {
                            Text(logPathFilterSummary(currentPathSelections))
                                .lineLimit(1)
                                .frame(width: 150, height: 32, alignment: .leading)
                                .padding(.horizontal, 10)
                                .background(Design.Colors.surface, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    } else {
                        logFilterField("Paths", text: $logPathFilter, width: 150)
                            .onSubmit { applyManualLogPathFilter() }
                    }
                    Menu {
                        Button("Edit Paths…") { openLogPathsEditor() }
                        Button("Select Paths in Tree…") { openLogPathsTreeChooser() }
                            .disabled(logStructureFilterRootPaths.isEmpty && availableReflogRootPaths.isEmpty)
                        Button("Choose…") { chooseLogPathFilter() }
                            .disabled(availableReflogRootPaths.isEmpty)
                        if logStructureFilterRootPaths.count > 1 {
                            Divider()
                            Section("Repositories") {
                                ForEach(logStructureFilterRootPaths, id: \.self) { rootPath in
                                    Toggle(
                                        isOn: Binding(
                                            get: { visibleLogStructureFilterRootPaths.contains(rootPath) },
                                            set: { setLogStructureFilterRoot(rootPath, visible: $0) }
                                        )
                                    ) {
                                        Text(URL(fileURLWithPath: rootPath).lastPathComponent)
                                            .help(rootPath)
                                    }
                                }
                            }
                        }
                        let recent = recentLogPathFilterSelections()
                        if !recent.isEmpty {
                            Divider()
                            Section("Recent Filters") {
                                ForEach(Array(recent.enumerated()), id: \.offset) { _, paths in
                                    Button(logPathFilterSummary(paths)) {
                                        setLogPathFilterSelections(paths, remember: false)
                                    }
                                }
                                Button("Clear Recent Filters") {
                                    clearRecentLogPathFilters()
                                }
                            }
                        }
                        if !currentPathSelections.isEmpty {
                            Divider()
                            Button("Clear") { clearLogPathFilter() }
                        }
                    } label: {
                        Image(systemName: currentPathSelections.isEmpty
                              ? "folder"
                              : "folder.fill")
                    }
                    .menuStyle(.borderlessButton)
                    .foregroundStyle(currentPathSelections.isEmpty ? .secondary : Design.Colors.accent)
                    .help("Choose or clear Paths filter")
                }
                Menu {
                    Button("HEAD") { setLogStartRevisions([]) }
                    Button("Enter branch, tag, or commit") {
                        logRevisionFilterInput = ""
                        showLogRevisionFilterAlert = true
                    }
                    Divider()
                    Section("Local Branches") {
                        ForEach(branches, id: \.name) { branch in
                            Toggle(
                                isOn: logStartRevisionBinding(for: branch.name)
                            ) {
                                Text(branch.name)
                            }
                        }
                    }
                    if !remoteBranches.isEmpty {
                        Section("Remote Branches") {
                            ForEach(remoteBranches, id: \.name) { branch in
                                Toggle(
                                    isOn: logStartRevisionBinding(for: branch.name)
                                ) {
                                    Text(branch.name)
                                }
                            }
                        }
                    }
                    if !tags.isEmpty {
                        Section("Tags") {
                            ForEach(tags, id: \.name) { tag in
                                Toggle(
                                    isOn: logStartRevisionBinding(for: tag.name)
                                ) {
                                    Text(tag.name)
                                }
                            }
                        }
                    }
                } label: {
                    Label(logBranchFilterTitle,
                          systemImage: "arrow.triangle.branch")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 8)
                .frame(height: 32)
                .background(Design.Colors.surface, in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: logStartRevisions) { _, _ in scheduleLogRefresh() }
                logFilterField("User", text: $logAuthorFilter, width: 110)
                    .onSubmit { scheduleLogRefresh() }
                logFilterField("Since", text: $logSinceText, width: 120)
                    .onSubmit { scheduleLogRefresh() }
                logFilterField("Until", text: $logUntilText, width: 120)
                    .onSubmit { scheduleLogRefresh() }
                Toggle(isOn: $logFollow) {
                    Image(systemName: "arrow.right.to.line.compact")
                }
                .toggleStyle(.checkbox)
                .help("Follow current branch")
                Button {
                    loadLog()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh log")
                if isShowingCachedLogSnapshot {
                    ProgressView()
                        .controlSize(.small)
                        .help("Refreshing cached history")
                }
            }
            // The filter row belongs to the commit-table column, not to the
            // graph gutter. Rebased keeps the fields aligned with the first
            // commit summary while the colored lanes remain visible below.
            .padding(.leading, 10)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
        }
        .frame(height: 48)
        .onChange(of: logFollow) { _, _ in scheduleLogRefresh() }
        }
        if shouldShowLogError {
            if let logError {
                Text(logError).foregroundStyle(.red).font(.callout).padding(8)
            }
        }
        switch logViewMode {
        case .graph:
            logGraphHistoryContent
        case .command:
            logGraphHistoryContent
        case .compareBranches:
            BranchCommitComparisonView(
                firstBranch: compareRev1,
                secondBranch: compareRev2,
                firstCommits: branchCompareFirstEntries,
                secondCommits: branchCompareSecondEntries,
                firstFilter: $branchCompareFirstFilter,
                secondFilter: $branchCompareSecondFilter,
                isLoading: isLoadingBranchComparison,
                error: branchCompareError,
                selectedID: $branchCompareSelectionID,
                selectedSide: $branchCompareSelectionSide,
                onFilterChanged: refreshBranchComparison,
                pagination: branchComparisonPagination,
                onSelect: { side, id in
                    branchCompareSelectionSide = side
                    branchCompareSelectionID = id
                },
                onAction: { action, commit in
                    switch action {
                    case .checkout:
                        checkoutFromLog(commit)
                    case .reset:
                        resetFromLog(commit)
                    case .createBranch:
                        createBranchFromCommit(commit)
                    case .compare:
                        compareFromLog(commit)
                    case .interactiveRebase:
                        interactiveRebaseFromLog(commit)
                    case .cherryPick:
                        cherryPickFromLog(commit)
                    case .revert:
                        revertFromLog(commit)
                    }
                },
                logActions: branchComparisonLogActions
            )
        case .compare:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("旧版本 / 分支", text: $compareRev1)
                        .textFieldStyle(.roundedBorder)
                    Text("→").foregroundStyle(.secondary)
                    TextField("新版本 / 分支", text: $compareRev2)
                        .textFieldStyle(.roundedBorder)
                    Button("比较") {
                        compareWithWorkingTree = false
                        loadTreeChanges()
                    }
                    Menu {
                        Button("Select All") {
                            compareSelectedPaths = Set(treeChanges.map(\.path))
                            compareSelection = treeChanges.first?.path
                        }
                        .disabled(treeChanges.isEmpty)
                        Button("Clear") {
                            compareSelectedPaths = []
                            compareSelection = nil
                        }
                        .disabled(compareSelectedPaths.isEmpty)
                        Divider()
                        Button("Copy Selected Paths") {
                            copySelectedComparePaths()
                        }
                        .disabled(compareSelectedPaths.isEmpty)
                        Divider()
                        Button("Create Patch…") {
                            createPatchFromCompare()
                        }
                        .disabled(compareSelectedPaths.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .help("Compare actions")
                }
                .padding(.horizontal, 8)
                HStack(spacing: 8) {
                    Text("\(treeChanges.count) files")
                    if !compareSelectedPaths.isEmpty {
                        Text("\(compareSelectedPaths.count) selected")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .font(.caption2)
                .padding(.horizontal, 8)
                if let compareError {
                    Text(compareError).foregroundStyle(.red).font(.caption).padding(.horizontal, 8)
                }
                List(treeChanges, id: \.path, selection: $compareSelectedPaths) { change in
                    HStack {
                        Text(treeChangeKindText(change.kind))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)
                        Text(change.path).font(.system(.body, design: .monospaced))
                    }
                    .tag(change.path)
                    .simultaneousGesture(TapGesture().onEnded {
                        compareSelection = change.path
                    })
                }
                .listStyle(.inset)
                .onChange(of: compareSelectedPaths) { _, selectedPaths in
                    let validPaths = Set(treeChanges.map(\.path))
                    let normalized = selectedPaths.intersection(validPaths)
                    if normalized != selectedPaths {
                        compareSelectedPaths = normalized
                        return
                    }
                    if let compareSelection, normalized.contains(compareSelection) {
                        return
                    }
                    compareSelection = orderedCompareSelection(
                        changes: treeChanges,
                        selectedPaths: normalized
                    ).first?.path
                }
            }
        case .tags:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("tag 名称", text: $tagName)
                        .textFieldStyle(.roundedBorder)
                    TextField("指向 rev（空=HEAD）", text: $tagAt)
                        .textFieldStyle(.roundedBorder)
                    Button("创建") { createTag() }
                }
                .padding(.horizontal, 8)
                if let tagFeedback {
                    Text(tagFeedback).font(.caption)
                        .foregroundStyle(tagFeedback.hasPrefix("已") ? .green : .red)
                        .padding(.horizontal, 8)
                }
                List(tags, id: \.name) { tag in
                    HStack {
                        Text(tag.name).font(.system(.body, design: .monospaced))
                        Text(tag.shortId).font(.caption).foregroundStyle(.secondary)
                        Text(tag.kind == .lightweight ? "lightweight" : tag.kind == .signed ? "signed" : "annotated")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help(tag.message)
                        Spacer()
                        pushTagAction(for: tag.name)
                        Button("删除") { deleteTag(tag.name) }
                    }
                }
                .listStyle(.inset)
            }
        case .reflog:
            reflogHistoryContent
        }
    }
        .onChange(of: logSelection) { _, id in
            guard let id else { return }
            loadCommitDetailsIfNeeded(id)
        }
    .onChange(of: reflogSelection) { _, selection in
        guard logViewMode == .reflog, let selection else { return }
        if !reflogSelectedIDs.contains(selection) {
            reflogSelectedIDs.insert(selection)
        }
    }
    .onChange(of: reflogSelectedIDs) { _, _ in
        synchronizeReflogSelection()
        loadReflogCommitDetails()
        if externalLogWindow {
            persistExternalLogTabs()
        }
    }
        .onChange(of: reflogEntries.map(reflogEntryIdentifier)) { _, _ in
            synchronizeReflogSelection()
            loadReflogCommitDetails()
        }
        .onAppear {
            loadLogSignatureStatuses()
        }
        .onChange(of: logShowSignatureColumn) { _, _ in
            loadLogSignatureStatuses()
        }
        .onChange(of: logEntries.map(logCommitIdentity)) { _, _ in
            loadLogSignatureStatuses()
        }
        .sheet(isPresented: $isLogPathsEditorPresented) {
            LogPathsEditorView(
                text: $logPathsEditorText,
                onCancel: { isLogPathsEditorPresented = false },
                onApply: applyLogPathsEditor
            )
        }
        .sheet(isPresented: $isLogPathsTreeChooserPresented) {
            LogPathsTreeChooserView(
                roots: logPathsTreeChooserRoots,
                selections: $logPathsTreeChooserSelections,
                onCancel: { isLogPathsTreeChooserPresented = false },
                onApply: applyLogPathsTreeChooser
            )
        }
    .alert("Enter branch, tag, or commit", isPresented: $showLogRevisionFilterAlert) {
        TextField("branch or revision", text: $logRevisionFilterInput)
        Button("Cancel", role: .cancel) {}
        Button("Add") {
            let value = logRevisionFilterInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            // A typed value is a complete filter expression. Replacing the
            // popup selection prevents a branch head and an A..B range from
            // being accidentally treated as a union when IntelliJ would keep
            // range/revision filters as a separate filter category.
            setLogStartRevisions([value])
        }
        .disabled(logRevisionFilterInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .confirmationDialog(
        logNavigationChoosesParent ? "Select Parent Commit" : "Select Child Commit",
        isPresented: $isLogNavigationChoicePresented,
        titleVisibility: .visible
    ) {
        ForEach(Array(pendingLogNavigationCommits.enumerated()), id: \.offset) { _, commit in
            Button(logNavigationChoiceTitle(commit)) {
                choosePendingLogNavigationCommit(commit)
            }
        }
        Button("Cancel", role: .cancel) {
            pendingLogNavigationCommits = []
            pendingLogNavigationSelection = nil
            pendingLogNavigationGeneration = nil
        }
    } message: {
        Text(logNavigationChoosesParent ? "Choose a parent commit" : "Choose a child commit")
    }
}

private var logCommandFilterBar: some View {
    HStack(spacing: 8) {
        Text("git log")
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.secondary)
        TextField("command and arguments", text: $logCommandFilter)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .onSubmit { runLogCommand() }
        Button("Run") { runLogCommand() }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        Button("History") { logViewMode = .graph }
            .buttonStyle(.bordered)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(height: 48)
    .background(Design.Colors.surface.opacity(0.55))
}

@ViewBuilder
private var logGraphHistoryContent: some View {
    let isCommand = logViewMode == .command
    let isFileHistory = logTabs.first { $0.id == currentLogTabID }?.historyPath != nil
    let entries = isCommand ? logCommandEntries : logEntries
    let isLoading = isCommand ? isLoadingLogCommand : isLoadingLog
    if isLoading && entries.isEmpty {
        ProgressView("Loading history…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if entries.isEmpty {
        HStack(spacing: 0) {
            if logBranchesVisible && !isCommand {
                logBranchesPanelView
                Divider()
            }
            VStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                Text(isCommand
                    ? (logCommandError ?? "No commits match the command")
                    : (logError ?? "No commits match the current filters"))
                    .foregroundStyle(.secondary)
                Button("Refresh") {
                    if isCommand { runLogCommand() } else { loadLog() }
                }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
        HStack(spacing: 0) {
            if logBranchesVisible && !isCommand {
                logBranchesPanelView
                Divider()
            }
            LogGraphView(
                commits: entries,
                selection: $logSelection,
                selectedIDs: $logSelectedIDs,
                commitIdentity: logCommitIdentity,
                compactReferences: logCompactReferences,
                showCommitColumns: logShowCommitColumns,
                showAuthorColumn: logShowAuthorColumn,
                showDateColumn: logShowDateColumn,
                showHashColumn: logShowHashColumn,
                showRootColumn: logShowRootColumn,
                showSignatureColumn: logShowSignatureColumn,
                signatureStatuses: logSignatureStatuses,
                signatureLoadingIDs: logSignatureLoadingIDs,
                signatureFailedIDs: logSignatureFailedIDs,
                columnLayout: LogColumnLayout(
                    orderRaw: logColumnOrderRaw,
                    widthsRaw: logColumnWidthsRaw
                ),
                showTagNames: logShowTagNames,
                alignLabels: logAlignLabels,
                showLongEdges: logShowLongEdges,
                collapseGraph: logCollapseGraph,
                graphCommand: logGraphCommand,
                highlightCherryPickedCommits: logHighlightCherryPicked,
                actionAvailability: logActionAvailability,
                isFileHistory: isFileHistory,
                onReachedEnd: loadMoreLog,
                hasMore: isCommand ? hasMoreLogCommand : hasMoreLog,
                isLoadingMore: isCommand ? isLoadingLogCommand : isLoadingMoreLog,
                pullRequestRemotesForCommit: pullRequestRemotesForCommit,
                onOpenPullRequest: openPullRequestsForCommit,
                commentRemotesForCommit: commentRemotesForCommit,
                onComment: beginReviewComment,
                onCreateBranch: createBranchFromCommit,
                onCreateTag: beginCreateTagFromLog,
                onCherryPick: cherryPickFromLog,
                onCherryPickSelected: cherryPickCommitsFromLog,
                onRevert: revertFromLog,
                onRevertSelected: revertCommitsFromLog,
                onCheckout: checkoutFromLog,
                onReset: resetFromLog,
                onResetSelected: { commits in
                    resetFromLog(commits)
                },
                onCompare: compareFromLog,
                currentBranchNameForCommit: currentLogBranchName,
                onReferenceAction: performLogReferenceAction,
                onRebaseOntoCommit: rebaseOntoCommitFromLog,
                onInteractiveRebase: interactiveRebaseFromLog,
                onCreateAutoSquashCommit: beginAutoSquashCommitFromLog,
                onRewriteCommit: { commit, action in
                    rewriteCommitFromLog(commit, action: action)
                },
                onRewriteSelected: { commits, action in
                    rewriteSelectedCommitsFromLog(commits, action: action)
                },
                onPushUpToCommit: pushUpToCommitFromLog,
                onAddCommitsToRemoteBranch: addCommitsToRemoteBranchFromLog,
                highlightedCherryPickedCommitIDs: logCherryPickedCommitIDs,
                cherryPickComparisonReady: logCherryPickComparisonReady,
                hostedRemotesForCommit: hostedRemotesForCommit,
                onBrowseHostedRevision: browseHostedRevisionFromLog,
                onBrowseRevision: browseRevisionFromLog,
                onCopyRevisionLink: copyRevisionLinkFromLog,
                onUncommit: uncommitFromLog,
                onColumnOrderChanged: { order in
                    logColumnOrderRaw = order.map(\.rawValue).joined(separator: ",")
                },
                onColumnWidthChanged: { column, width in
                    setLogColumnWidth(column, to: width)
                }
            )
        }
        .frame(minHeight: 0, maxHeight: .infinity)
    }
}

@ViewBuilder
private var logBranchesPanelView: some View {
    if multiRootBranchSnapshots.count > 1 {
        MultiRootLogBranchesPanel(
            projectPath: projectPath,
            snapshots: multiRootBranchSnapshots,
            groupByDirectory: $logBranchesGroupByDirectory,
            groupByRepository: $logBranchesGroupByRepository,
            selectionActionRaw: $logBranchesSelectionActionRaw,
            showOnlyMy: $logBranchesShowOnlyMy,
            myBranchIDs: logMyBranchIDs,
            isLoadingMyBranches: isLoadingMyBranches,
            onShowOnlyMyChanged: setLogBranchesShowOnlyMy,
            onNavigate: navigateLogToBranch,
            onCompare: compareLogBranch,
            onFilter: applyLogBranchFilters,
            onNewBranch: presentMultiRootNewBranchDialog,
            onCleanup: deleteMergedBranches,
            onFindMerged: beginFindMergedBranches,
            onHide: { logBranchesVisible = false },
            onDelete: { rootPath, name in
                deleteBranchInRoot(rootPath: rootPath, name: name)
            },
            onCheckout: { rootPath, name, isRemote in
                checkoutBranchInRoot(rootPath: rootPath, reference: name, isRemote: isRemote)
            },
            onCheckoutAsNewBranch: { rootPath, name, isRemote in
                presentMultiRootNewBranchFromReference(
                    rootPath: rootPath,
                    reference: name,
                    isRemote: isRemote
                )
            },
            onOpenWorktree: { path in
                openWindow(value: path)
            },
            onCreateWorktreeFromReference: { rootPath, reference, isTag in
                presentNewWorktreeFromReference(
                    reference,
                    isTag: isTag,
                    rootPath: rootPath
                )
            },
            onCheckoutTag: { rootPath, name in
                checkoutTagInRoot(rootPath: rootPath, name: name)
            },
            onCheckoutAndUpdate: { rootPath, name, _ in
                executeMultiRootCheckoutAndUpdate(
                    reference: name,
                    rootPath: rootPath,
                    detach: false,
                    rebase: false
                )
            },
            onCheckoutWithRebase: { rootPath, name, isRemote in
                if isRemote {
                    presentNewBranchFromReference(
                        name,
                        isRemote: true,
                        afterCreateRebase: true,
                        rootPath: rootPath
                    )
                } else {
                    executeMultiRootCheckoutWithRebase(rootPath: rootPath, branch: name)
                }
            },
            onPullBranch: { rootPath, branch, rebase in
                pullBranchInRoot(rootPath: rootPath, branch: branch, rebase: rebase)
            },
            onUpdate: { rootPath, name in
                updateBranchInRoot(rootPath: rootPath, branch: name)
            },
            onMerge: { rootPath, name in
                mergeBranchInRoot(rootPath: rootPath, branch: name)
            },
            onRebase: { rootPath, name in
                rebaseCurrentInRoot(rootPath: rootPath, onto: name)
            },
            onShowDiffWithWorkingTree: { rootPath, branch in
                showBranchDiffWithWorkingTree(rootPath: rootPath, branch: branch)
            },
            onDeleteTag: { rootPath, name in
                deleteTagInRoot(rootPath: rootPath, name: name)
            },
            onPushTag: { rootPath, name in
                pushTagInRoot(rootPath: rootPath, name: name)
            },
            onPushTagToRemote: { rootPath, name, remote in
                pushTagInRoot(rootPath: rootPath, name: name, remote: remote)
            },
            onCompareSelected: { rootPath, first, second in
                compareBranchesCommitWiseInRoot(rootPath: rootPath, first: first, second: second)
            },
            onCompareSelectedFiles: { rootPath, first, second in
                compareBranchesInRoot(rootPath: rootPath, first: first, second: second)
            },
            onUpdateSelected: { targets in
                updateSelectedBranchesInRoots(targets)
            },
            onDeleteSelected: { targets in
                deleteSelectedBranchesInRoots(targets)
            },
            onEditRemote: { rootPath, name in
                beginMultiRootRemoteConfig(rootPath: rootPath, selectedRemote: name)
            },
            onRemoveRemote: { rootPath, name in
                removeRemoteInRoot(rootPath: rootPath, name: name)
            },
            onRemoveRemoteSelected: { groups in
                removeSelectedRemotesInRoots(groups)
            },
            onConfigureRemotes: beginConfigureRemotes,
            onPush: { rootPath, name in
                beginMultiRootPushDialog(rootPath: rootPath, branch: name)
            },
            onFetch: { rootPath, name in
                fetchRemoteBranchInRoot(rootPath: rootPath, branch: name)
            },
            onFetchAll: { doFetchAll() },
            onSetUpstream: { rootPath, name in
                setBranchUpstreamInRoot(rootPath: rootPath, branch: name)
            },
            onUnsetUpstream: { rootPath, name in
                unsetBranchUpstreamInRoot(rootPath: rootPath, branch: name)
            },
            onRename: { rootPath, name in
                renameBranchInRoot(rootPath: rootPath, oldName: name)
            },
            onDeleteRemote: { rootPath, name in
                deleteRemoteBranchInRoot(rootPath: rootPath, branch: name)
            },
            protectedBranchPatterns: effectiveProtectedBranchPatterns
        )
    } else {
        LogBranchesPanel(
            projectPath: projectPath,
            branches: branches,
            remoteBranches: remoteBranches,
            remotes: remotes,
            tags: tags,
            hasHeadCommit: headId != nil,
            syncStatuses: syncStatuses,
            protectedBranchPatterns: effectiveProtectedBranchPatterns,
            groupByDirectory: $logBranchesGroupByDirectory,
            selectionActionRaw: $logBranchesSelectionActionRaw,
            showOnlyMy: $logBranchesShowOnlyMy,
            myBranchIDs: logMyBranchIDs,
            isLoadingMyBranches: isLoadingMyBranches,
            onShowOnlyMyChanged: setLogBranchesShowOnlyMy,
            onNavigate: { branch in
                navigateLogToBranch(rootPath: nil, branch: branch)
            },
            onFilter: { filters in
                applyLogBranchFilters(filters)
            },
            onCompare: { branch in
                compareLogBranch(rootPath: nil, branch: branch)
            },
            onNewBranch: { presentNewBranchDialog() },
            onCleanup: deleteMergedBranches,
            onFindMerged: beginFindMergedBranches,
            onHide: { logBranchesVisible = false },
            onDelete: branchDelete,
            onCheckout: { reference, isRemote in
                if isRemote {
                    guard let branch = remoteBranches.first(where: { $0.name == reference }) else { return }
                    checkoutRemoteBranch(branch)
                } else {
                    switchBranch(reference)
                }
            },
            onCheckoutAsNewBranch: { reference, isRemote in
                presentNewBranchFromReference(reference, isRemote: isRemote)
            },
            worktrees: worktrees,
            onOpenWorktree: { path in
                openWindow(value: path)
            },
            onCreateWorktreeFromReference: { reference, isTag in
                presentNewWorktreeFromReference(reference, isTag: isTag)
            },
            onCheckoutTag: checkoutTag,
            onCheckoutAndUpdate: { reference, rebase in
                checkoutAndUpdate(reference, rebase: rebase)
            },
            onCheckoutWithRebase: { reference, isRemote in
                if isRemote {
                    presentNewBranchFromReference(reference, isRemote: true, afterCreateRebase: true)
                } else {
                    checkoutAndUpdate(reference, rebase: true)
                }
            },
            onPullBranch: { branch, rebase in
                pullSelectedBranch(branch, rebase: rebase)
            },
            onUpdate: updateSelectedBranch,
            onMerge: { branch in
                openMergeDialog(branch)
            },
            onRebase: { branch in
                openRebaseDialog(branch)
            },
            onShowDiffWithWorkingTree: { branch in
                showBranchDiffWithWorkingTree(rootPath: nil, branch: branch)
            },
            onDeleteTag: { tag in tagDelete(tag.name) },
            onPushTag: { tag in tagPushToRemote(tag) },
            onPushTagToRemote: { name, remote in
                tagPushToRemote(name, remote: remote)
            },
            onCompareSelected: { selection in
                guard let pair = branchDashboardComparisonPair(selection: selection),
                      let rootPath = projectPath,
                      pair.rootPath == rootPath else { return }
                compareBranchesCommitWiseInRoot(
                    rootPath: rootPath,
                    first: pair.first,
                    second: pair.second
                )
            },
            onCompareSelectedFiles: { selection in
                guard let pair = branchDashboardComparisonPair(selection: selection),
                      let rootPath = projectPath,
                      pair.rootPath == rootPath else { return }
                compareBranchesInRoot(
                    rootPath: rootPath,
                    first: pair.first,
                    second: pair.second
                )
            },
            onUpdateSelected: updateSelectedBranchesInRoots,
            onDeleteSelected: deleteSelectedBranchesInRoots,
            onPush: { branch in
                beginPushDialog(branch: branch)
            },
            onFetch: { reference in
                guard let branch = remoteBranches.first(where: { $0.name == reference }) else { return }
                fetchRemoteBranch(branch)
            },
            onFetchAll: { doFetchAll() },
            onSetUpstream: { branch in
                upstreamLocalBranch = branch
                showUpstreamDialog = true
            },
            onUnsetUpstream: unsetBranchUpstream,
            onRename: renameBranchFromPopup,
            onDeleteRemote: deleteRemoteBranch
        )
    }
}

private struct LogTabBar: View {
    let tabs: [LogTabDescriptor]
    let activeID: UUID
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onNew: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                HStack(spacing: 4) {
                    Button(tab.title) { onSelect(tab.id) }
                        .buttonStyle(.plain)
                        .font(.caption.weight(tab.id == activeID ? .semibold : .regular))
                        .foregroundStyle(tab.id == activeID ? .primary : .secondary)
                    Button { onClose(tab.id) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(tabs.count == 1)
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(
                    tab.id == activeID
                        ? Design.Colors.surface
                        : Design.Colors.surface.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 5)
                )
            }
            Button(action: onNew) {
                Image(systemName: "plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)
            .help("Open another Log tab")
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(Design.Colors.chrome.opacity(0.7))
    }
}

/// IntelliJ 的 Log 分支 dashboard：分支树与历史过滤处于同一工作区，
/// 而不是把用户强制带回顶部 Branches popup。
private struct MultiRootLogBranchesPanel: View {
    let projectPath: String?
    let snapshots: [GitRootBranchSnapshot]
    @Binding var groupByDirectory: Bool
    @Binding var groupByRepository: Bool
    @Binding var selectionActionRaw: String
    @Binding var showOnlyMy: Bool
    let myBranchIDs: Set<String>
    let isLoadingMyBranches: Bool
    let onShowOnlyMyChanged: (Bool) -> Void
    let onNavigate: (String, String) -> Void
    let onCompare: (String, String) -> Void
    let onFilter: ([LogRootBranchFilter]) -> Void
    let onNewBranch: () -> Void
    let onCleanup: () -> Void
    let onFindMerged: () -> Void
    let onHide: () -> Void
    let onDelete: (String, String) -> Void
    let onCheckout: (String, String, Bool) -> Void
    let onCheckoutAsNewBranch: (String, String, Bool) -> Void
    let onOpenWorktree: (String) -> Void
    let onCreateWorktreeFromReference: (String, String, Bool) -> Void
    let onCheckoutTag: (String, String) -> Void
    let onCheckoutAndUpdate: (String, String, Bool) -> Void
    let onCheckoutWithRebase: (String, String, Bool) -> Void
    let onPullBranch: (String, String, Bool) -> Void
    let onUpdate: (String, String) -> Void
    let onMerge: (String, String) -> Void
    let onRebase: (String, String) -> Void
    let onShowDiffWithWorkingTree: (String, String) -> Void
    let onDeleteTag: (String, String) -> Void
    let onPushTag: (String, String) -> Void
    let onPushTagToRemote: (String, String, String) -> Void
    let onCompareSelected: (String, String, String) -> Void
    let onCompareSelectedFiles: (String, String, String) -> Void
    let onUpdateSelected: ([BranchDashboardReference]) -> Void
    let onDeleteSelected: ([BranchDashboardReference]) -> Void
    let onEditRemote: (String, String) -> Void
    let onRemoveRemote: (String, String) -> Void
    let onRemoveRemoteSelected: ([BranchDashboardRemoteGroup]) -> Void
    let onConfigureRemotes: () -> Void
    let onPush: (String, String) -> Void
    let onFetch: (String, String) -> Void
    let onFetchAll: () -> Void
    let onSetUpstream: (String, String) -> Void
    let onUnsetUpstream: (String, String) -> Void
    let onRename: (String, String) -> Void
    let onDeleteRemote: (String, String) -> Void
    let protectedBranchPatterns: [String]

    @State private var query = ""
    @State private var collapsedDirectoryGroups: Set<String> = []
    @State private var selectedBranchTargetID: String?
    @State private var selectedBranchTargetIDs: Set<String> = []
    @State private var branchSelectionAnchorID: String?
    @State private var selectedRemoteGroupIDs: Set<String> = []
    @State private var favoriteReferenceIDs: Set<String> = []
    @State private var showTags = GitBranchesPopupSettings.defaultShowTags

    private var dashboardRemoteGroups: [BranchDashboardRemoteGroup] {
        filteredSnapshots.flatMap { snapshot in
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

    private var selectedDashboardRemoteGroups: [BranchDashboardRemoteGroup] {
        dashboardRemoteGroups.filter { group in
            selectedRemoteGroupIDs.contains(remoteGroupTargetID(
                rootPath: group.rootPath,
                name: group.name
            ))
        }
    }

    private var hasMixedDashboardSelection: Bool {
        !selectedDashboardReferences.isEmpty && !selectedDashboardRemoteGroups.isEmpty
    }

    private var selectionAction: LogBranchSelectionAction {
        get { LogBranchSelectionAction(rawValue: selectionActionRaw) ?? .navigate }
        set { selectionActionRaw = newValue.rawValue }
    }

    private var selectionActionBinding: Binding<LogBranchSelectionAction> {
        Binding(
            get: { LogBranchSelectionAction(rawValue: selectionActionRaw) ?? .navigate },
            set: {
                selectionActionRaw = $0.rawValue
                GitBranchesPopupSettings.save(
                    $0.rawValue,
                    GitBranchesPopupSettings.logSelectionActionKey,
                    for: projectPath
                )
            }
        )
    }

    private var filteredSnapshots: [GitRootBranchSnapshot] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !showOnlyMy && normalized.isEmpty && showTags {
            return snapshots
        }
        return snapshots.compactMap { snapshot in
            let localCandidates = showOnlyMy
                ? snapshot.branches.filter {
                    myBranchIDs.contains(BranchDashboardReference.referenceID(
                        rootPath: snapshot.rootPath,
                        name: $0.name,
                        kind: .local
                    ))
                }
                : snapshot.branches
            let remoteCandidates = showOnlyMy
                ? snapshot.remoteBranches.filter {
                    myBranchIDs.contains(BranchDashboardReference.referenceID(
                        rootPath: snapshot.rootPath,
                        name: $0.name,
                        kind: .remote
                    ))
                }
                : snapshot.remoteBranches
            let local = normalized.isEmpty
                ? localCandidates
                : localCandidates.filter { branchSearchMatches($0.name, query: query) }
            let remote = normalized.isEmpty
                ? remoteCandidates
                : remoteCandidates.filter { branchSearchMatches($0.name, query: query) }
            let remotes = showOnlyMy
                ? snapshot.remotes.filter { Set(remoteCandidates.map(\.remote)).contains($0.name) }
                : snapshot.remotes.filter { branchSearchMatches($0.name, query: query) }
            let tags = showTags && !showOnlyMy
                ? (normalized.isEmpty
                    ? snapshot.tags
                    : snapshot.tags.filter { branchSearchMatches($0.name, query: query) })
                : []
            // IntelliJ keeps the synthetic HEAD node visible for every
            // repository, including detached and unborn roots, even when
            // the selected filter hides every named ref.
            return GitRootBranchSnapshot(
                rootPath: snapshot.rootPath,
                displayName: snapshot.displayName,
                relativePath: snapshot.relativePath,
                headBranch: snapshot.headBranch,
                headId: snapshot.headId,
                branches: local,
                remoteBranches: remote,
                remotes: remotes,
                syncStatuses: snapshot.syncStatuses,
                recentBranches: snapshot.recentBranches,
                tags: tags,
                stashes: snapshot.stashes,
                shelves: snapshot.shelves,
                worktrees: snapshot.worktrees
            )
        }
    }

    private var keyboardTargets: [BranchTreeTarget] {
        filteredSnapshots.flatMap { snapshot in
            let head = BranchTreeTarget(
                id: targetID(rootPath: snapshot.rootPath, kind: .head, value: "HEAD"),
                value: "HEAD",
                title: "HEAD",
                kind: .head,
                rootPath: snapshot.rootPath
            )
            let local = visibleBranchDirectoryRefNames(
                snapshot.branches.map(\.name),
                grouped: groupByDirectory,
                scope: "\(snapshot.rootPath).log.local",
                collapsedGroups: collapsedDirectoryGroups
            ).map {
                BranchTreeTarget(
                    id: targetID(rootPath: snapshot.rootPath, kind: .local, value: $0),
                    value: $0,
                    title: $0,
                    kind: .local,
                    rootPath: snapshot.rootPath
                )
            }
            let remote = visibleBranchDirectoryRefNames(
                snapshot.remoteBranches.map(\.name),
                grouped: groupByDirectory,
                scope: "\(snapshot.rootPath).log.remote",
                collapsedGroups: collapsedDirectoryGroups
            ).map {
                BranchTreeTarget(
                    id: targetID(rootPath: snapshot.rootPath, kind: .remote, value: $0),
                    value: $0,
                    title: $0,
                    kind: .remote,
                    rootPath: snapshot.rootPath
                )
            }
            let remoteGroups = remoteGroupNames(snapshot).map { name in
                BranchTreeTarget(
                    id: remoteGroupTargetID(rootPath: snapshot.rootPath, name: name),
                    value: name,
                    title: name,
                    kind: .remoteGroup,
                    rootPath: snapshot.rootPath
                )
            }
            let tags = visibleBranchDirectoryRefNames(
                snapshot.tags.map(\.name),
                grouped: groupByDirectory,
                scope: "\(snapshot.rootPath).log.tags",
                collapsedGroups: collapsedDirectoryGroups
            ).map {
                BranchTreeTarget(
                    id: targetID(rootPath: snapshot.rootPath, kind: .tag, value: $0),
                    value: $0,
                    title: $0,
                    kind: .tag,
                    rootPath: snapshot.rootPath
                )
            }
            return [head] + local + remoteGroups + remote + tags
        }
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

    private var dashboardReferences: [BranchDashboardReference] {
        filteredSnapshots.flatMap { snapshot in
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
                worktreePath: snapshot.headBranch.flatMap { branch in
                    linkedWorktreePathForBranch(
                        branch: branch,
                        worktrees: snapshot.worktrees,
                        currentRootPath: snapshot.rootPath
                    )
                },
                headBranchName: snapshot.headBranch
            )
            let locals = snapshot.branches.map { branch in
                let sync = snapshot.syncStatuses.first { $0.branch == branch.name }
                return BranchDashboardReference(
                    rootPath: snapshot.rootPath,
                    name: branch.name,
                    kind: .local,
                    remote: nil,
                    isCurrent: branch.isCurrent,
                    hasUpstream: sync != nil,
                    hasTracking: sync?.trackingExists == true,
                    hasRemote: hasConfiguredRemote(in: snapshot.rootPath) || sync != nil,
                    isProtected: GitProtectedBranchRules.matches(
                        branch.name,
                        patterns: protectedBranchPatterns
                    ),
                    worktreePath: linkedWorktreePathForBranch(
                        branch: branch.name,
                        worktrees: snapshot.worktrees,
                        currentRootPath: snapshot.rootPath
                    )
                )
            }
            let remotes = snapshot.remoteBranches.map { branch in
                let branchName = branch.name.split(separator: "/", maxSplits: 1)
                    .dropFirst()
                    .joined(separator: "/")
                let localBranchName = snapshot.syncStatuses
                    .first { $0.upstream == branch.name }?
                    .branch
                return BranchDashboardReference(
                    rootPath: snapshot.rootPath,
                    name: branch.name,
                    kind: .remote,
                    remote: branch.remote,
                    localBranchName: localBranchName,
                    isCurrent: false,
                    hasUpstream: false,
                    hasTracking: false,
                    hasRemote: true,
                    isProtected: GitProtectedBranchRules.matches(
                        branchName.isEmpty ? branch.name : branchName,
                        patterns: protectedBranchPatterns
                    )
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
                    hasRemote: hasConfiguredRemote(in: snapshot.rootPath),
                    isProtected: false
                )
            }
            return [head] + locals + remotes + tags
        }
    }

    private func dashboardReference(
        rootPath: String,
        name: String,
        kind: BranchDashboardReferenceKind
    ) -> BranchDashboardReference? {
        dashboardReferences.first {
            $0.rootPath == rootPath && $0.name == name && $0.kind == kind
        }
    }

    private func hasConfiguredRemote(in rootPath: String) -> Bool {
        snapshots.first(where: { $0.rootPath == rootPath })?.remotes.isEmpty == false
    }

    private func dashboardTargetKind(
        for kind: BranchDashboardReferenceKind
    ) -> BranchTreeTargetKind {
        switch kind {
        case .head: return .head
        case .local: return .local
        case .remote: return .remote
        case .tag: return .tag
        }
    }

    private var selectedDashboardReferences: [BranchDashboardReference] {
        dashboardReferences.filter { reference in
            selectedBranchTargetIDs.contains(
                targetID(
                    rootPath: reference.rootPath,
                    kind: dashboardTargetKind(for: reference.kind),
                    value: reference.name
                )
            )
        }
    }

    private var selectedBranchReferencesForCurrentComparison: [BranchDashboardReference] {
        selectedDashboardReferences.filter { reference in
            (reference.kind == .local || reference.kind == .remote) && !reference.isCurrent
        }
    }

    private func dashboardSelection(
        for reference: BranchDashboardReference
    ) -> [BranchDashboardReference] {
        let selected = dashboardReferences.filter { target in
            selectedBranchTargetIDs.contains(
                targetID(
                    rootPath: target.rootPath,
                    kind: dashboardTargetKind(for: target.kind),
                    value: target.name
                )
            )
        }
        return selected.contains(reference) ? selected : [reference]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    .foregroundStyle(.blue)
                Text("Branches")
                    .font(.headline)
                Text("\(filteredSnapshots.count) repositories")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { createNewBranchFromSelection() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("New branch")
                Button { onHide() } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(.borderless)
                    .help("Hide branches")
            }
            TextField("Filter branches", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { activateSelectedBranch() }
                .onKeyPress(.downArrow, action: handleDownKeyPress)
                .onKeyPress(.upArrow, action: handleUpKeyPress)
            HStack(spacing: 6) {
                Toggle("Group by repository", isOn: $groupByRepository)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Toggle("Group by directory", isOn: $groupByDirectory)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Toggle("Show My Branches", isOn: $showOnlyMy)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Toggle("Show Tags", isOn: $showTags)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                if isLoadingMyBranches {
                    ProgressView()
                        .controlSize(.small)
                }
                Picker("On selection", selection: selectionActionBinding) {
                    ForEach(LogBranchSelectionAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .help("Choose what selecting a branch does")
                Spacer()
                Button("Filter Selected") { filterSelectedBranches() }
                    .controlSize(.small)
                    .disabled(selectedDashboardReferences.isEmpty)
                Menu("Actions…") {
                    if !selectedDashboardRemoteGroups.isEmpty,
                       selectedDashboardReferences.isEmpty {
                        remoteGroupActionMenu(for: selectedDashboardRemoteGroups)
                    } else if selectedDashboardRemoteGroups.isEmpty {
                        BranchDashboardActionMenu(
                            selection: selectedDashboardReferences,
                            handlers: dashboardActionHandlers,
                            allowsWorktreeAction: true
                        )
                    }
                }
                .controlSize(.small)
                .disabled(
                    (selectedDashboardReferences.isEmpty && selectedDashboardRemoteGroups.isEmpty)
                        || hasMixedDashboardSelection
                )
                Button("Find Merged…") { onFindMerged() }
                    .controlSize(.small)
                Button("Cleanup…") { onCleanup() }
                    .controlSize(.small)
            }
            dashboardActionToolbar
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if filteredSnapshots.isEmpty {
                        Text("No matching branches")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if logBranchesGroupingMode(
                        repositoryCount: snapshots.count,
                        groupByRepository: groupByRepository
                    ) == .repository {
                        ForEach(filteredSnapshots, id: \.rootPath) { snapshot in
                            rootSection(snapshot)
                        }
                    } else {
                        refKindSections
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(10)
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Colors.surface.opacity(0.55))
        .onAppear {
            groupByRepository = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.groupByRepositoryKey,
                for: projectPath
            )
            groupByDirectory = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.groupByDirectoryKey,
                for: projectPath
            )
            favoriteReferenceIDs = GitBranchesPopupSettings.favorites(for: projectPath)
            showTags = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.showTagsKey,
                for: projectPath
            )
            selectedBranchTargetID = bestBranchTreeTargetID(
                query: query,
                targets: keyboardTargets,
                preserving: selectedBranchTargetID
            )
            if selectedBranchTargetIDs.isEmpty, let selectedBranchTargetID {
                if visibleBranchSelectionIDs.contains(selectedBranchTargetID) {
                    selectedBranchTargetIDs = [selectedBranchTargetID]
                } else if selectedRemoteGroupIDs.isEmpty {
                    selectedRemoteGroupIDs = [selectedBranchTargetID]
                }
            }
            reconcileDashboardSelection()
            collapsedDirectoryGroups = GitBranchesPopupSettings.collapsedDirectoryGroups(
                for: projectPath,
                setting: GitBranchesPopupSettings.logCollapsedDirectoryGroupsKey
            )
        }
        .onChange(of: projectPath) { _, path in
            groupByRepository = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.groupByRepositoryKey,
                for: path
            )
            groupByDirectory = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.groupByDirectoryKey,
                for: path
            )
            collapsedDirectoryGroups = GitBranchesPopupSettings.collapsedDirectoryGroups(
                for: path,
                setting: GitBranchesPopupSettings.logCollapsedDirectoryGroupsKey
            )
            reconcileDashboardSelection()
        }
        .onChange(of: query) { _, _ in
            selectedBranchTargetID = bestBranchTreeTargetID(
                query: query,
                targets: keyboardTargets,
                preserving: selectedBranchTargetID
            )
            reconcileDashboardSelection()
        }
        .onChange(of: showOnlyMy) { _, value in
            onShowOnlyMyChanged(value)
            selectedBranchTargetID = bestBranchTreeTargetID(
                query: query,
                targets: keyboardTargets,
                preserving: selectedBranchTargetID
            )
            reconcileDashboardSelection()
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
            reconcileDashboardSelection()
        }
        .onChange(of: groupByRepository) { _, value in
            GitBranchesPopupSettings.save(
                value,
                GitBranchesPopupSettings.groupByRepositoryKey,
                for: projectPath
            )
            reconcileDashboardSelection()
        }
        .onChange(of: groupByDirectory) { _, value in
            GitBranchesPopupSettings.save(
                value,
                GitBranchesPopupSettings.groupByDirectoryKey,
                for: projectPath
            )
            reconcileDashboardSelection()
        }
        .onChange(of: snapshots) { _, _ in
            reconcileDashboardSelection()
        }
        .onChange(of: collapsedDirectoryGroups) { _, value in
            GitBranchesPopupSettings.saveCollapsedDirectoryGroups(
                value,
                for: projectPath,
                setting: GitBranchesPopupSettings.logCollapsedDirectoryGroupsKey
            )
        }
    }

    private var dashboardActionToolbar: some View {
        let selection = selectedDashboardReferences
        let availability = BranchDashboardActionAvailability.resolve(selection: selection)
        let compareTargets = selectedBranchReferencesForCurrentComparison
        let canToggleFavorite = !selection.isEmpty
            && selection.allSatisfy { $0.kind != .head }
            && selectedDashboardRemoteGroups.isEmpty

        return HStack(spacing: 5) {
            Button {
                onFetchAll()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
            .help("Fetch All Remotes")

            Button {
                toggleFavorites(selection)
            } label: {
                Image(systemName: "star")
            }
            .buttonStyle(.borderless)
            .disabled(!canToggleFavorite)
            .help("Mark/Unmark As Favorite")

            Button {
                compareTargets.forEach { onCompare($0.rootPath, $0.name) }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.borderless)
            .disabled(compareTargets.isEmpty)
            .help("Compare with Current")

            Button {
                onUpdateSelected(selection)
            } label: {
                Image(systemName: "arrow.down.to.line.compact")
            }
            .buttonStyle(.borderless)
            .disabled(!availability.isEnabled(.updateSelected))
            .help("Update Selected Branches")

            Button(role: .destructive) {
                onDeleteSelected(selection)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!availability.isEnabled(.deleteSelected))
            .help("Delete Selected")

            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    private func createNewBranchFromSelection() {
        guard selectedDashboardReferences.count == 1,
              let reference = selectedDashboardReferences.first else {
            onNewBranch()
            return
        }
        onCheckoutAsNewBranch(
            reference.rootPath,
            reference.name,
            reference.kind == .remote
        )
    }

    private func targetID(rootPath: String, kind: BranchTreeTargetKind, value: String) -> String {
        let kindValue: String
        switch kind {
        case .action: kindValue = "action"
        case .repository: kindValue = "repository"
        case .head: kindValue = "head"
        case .local: kindValue = "local"
        case .remote: kindValue = "remote"
        case .remoteGroup: kindValue = "remote-group"
        case .recent: kindValue = "recent"
        case .tag: kindValue = "tag"
        }
        return "log.multi:\(rootPath):\(kindValue):\(value)"
    }

    private func remoteGroupTargetID(rootPath: String, name: String) -> String {
        targetID(rootPath: rootPath, kind: .remoteGroup, value: name)
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
        } else if let nextID,
                  keyboardTargets.first(where: { $0.id == nextID })?.kind == .remoteGroup {
            selectedBranchTargetIDs = []
            selectedRemoteGroupIDs = [nextID]
            branchSelectionAnchorID = nil
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

    private func activateSelectedBranch() {
        guard let selectedBranchTargetID,
              let target = keyboardTargets.first(where: { $0.id == selectedBranchTargetID }) else { return }
        if target.kind == .remoteGroup {
            selectRemoteGroupTarget(id: target.id)
            return
        }
        performSelectionAction()
    }

    private func reconcileDashboardSelection() {
        let visibleBranchIDs = Set(visibleBranchSelectionIDs)
        selectedBranchTargetIDs.formIntersection(visibleBranchIDs)
        if let branchSelectionAnchorID,
           !visibleBranchIDs.contains(branchSelectionAnchorID) {
            self.branchSelectionAnchorID = nil
        }
        let visibleRemoteGroupIDs = Set(filteredSnapshots.flatMap { snapshot in
            remoteGroupNames(snapshot).map {
                remoteGroupTargetID(rootPath: snapshot.rootPath, name: $0)
            }
        })
        selectedRemoteGroupIDs.formIntersection(visibleRemoteGroupIDs)
        if selectedBranchTargetIDs.isEmpty,
           selectedRemoteGroupIDs.isEmpty,
           let selectedBranchTargetID {
            if visibleBranchIDs.contains(selectedBranchTargetID) {
                selectedBranchTargetIDs = [selectedBranchTargetID]
                if branchSelectionAnchorID == nil {
                    branchSelectionAnchorID = selectedBranchTargetID
                }
            } else if visibleRemoteGroupIDs.contains(selectedBranchTargetID) {
                selectedRemoteGroupIDs = [selectedBranchTargetID]
            }
        }
    }

    private func filterSelectedBranches() {
        let filters = logBranchFiltersForDashboardSelection(selectedDashboardReferences)
        guard !filters.isEmpty else { return }
        onFilter(filters)
    }

    private func toggleFavorites(_ selection: [BranchDashboardReference]) {
        var updated = favoriteReferenceIDs
        for reference in selection {
            if updated.contains(reference.favoriteID) {
                updated.remove(reference.favoriteID)
            } else {
                updated.insert(reference.favoriteID)
            }
        }
        favoriteReferenceIDs = updated
        GitBranchesPopupSettings.saveFavorites(updated, for: projectPath)
    }

    private func performSelectionAction() {
        guard let reference = selectedDashboardReferences.first else { return }
        switch selectionAction {
        case .navigate:
            onNavigate(reference.rootPath, reference.name)
        case .filter:
            let filters = logBranchFiltersForDashboardSelection(selectedDashboardReferences)
            guard !filters.isEmpty else { return }
            onFilter(filters)
        case .none:
            break
        }
    }

    @ViewBuilder
    private var refKindSections: some View {
        refKindSectionHeader("HEAD")
        ForEach(filteredSnapshots, id: \.rootPath) { snapshot in
            repositoryLabel(snapshot)
            headRow(snapshot)
        }

        refKindSectionHeader("LOCAL")
        ForEach(filteredSnapshots, id: \.rootPath) { snapshot in
            repositoryLabel(snapshot)
            branchSection(
                title: "",
                names: snapshot.branches.map(\.name),
                rootPath: snapshot.rootPath,
                isRemote: false,
                snapshot: snapshot
            )
        }

        remoteRefKindSectionHeader
        ForEach(filteredSnapshots, id: \.rootPath) { snapshot in
            repositoryLabel(snapshot)
            remoteBranchRows(snapshot)
        }

        if filteredSnapshots.contains(where: { !$0.tags.isEmpty }) {
            refKindSectionHeader("TAGS")
            ForEach(filteredSnapshots, id: \.rootPath) { snapshot in
                if !snapshot.tags.isEmpty {
                    repositoryLabel(snapshot)
                    tagRows(snapshot)
                }
            }
        }
    }

    private func refKindSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private var remoteRefKindSectionHeader: some View {
        HStack(spacing: 6) {
            Text("REMOTE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Configure…") { onConfigureRemotes() }
                .buttonStyle(.borderless)
                .font(.caption2)
        }
        .padding(.top, 4)
    }

    private func repositoryLabel(_ snapshot: GitRootBranchSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(snapshot.displayName)
                .font(.caption2.weight(.semibold))
            Text(snapshot.relativePath)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func rootSection(_ snapshot: GitRootBranchSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.displayName)
                    .font(.system(size: 12, weight: .semibold))
                Text(snapshot.relativePath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            headRow(snapshot)
            branchSection(
                title: "LOCAL",
                names: snapshot.branches.map(\.name),
                rootPath: snapshot.rootPath,
                isRemote: false,
                snapshot: snapshot
            )
            remoteSection(snapshot)
            tagSection(snapshot)
        }
        .padding(.bottom, 4)
    }

    private func headRow(_ snapshot: GitRootBranchSnapshot) -> some View {
        let id = targetID(rootPath: snapshot.rootPath, kind: .head, value: "HEAD")
        return Button {
            selectBranchTarget(id: id, rootPath: snapshot.rootPath, branch: "HEAD")
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "circle.hexagongrid.fill")
                    .foregroundStyle(.blue)
                Text("HEAD")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.semibold)
                if let headBranch = snapshot.headBranch, !headBranch.isEmpty {
                    Text("(\(headBranch))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("(detached)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            selectedBranchTargetIDs.contains(id) ? Color.accentColor.opacity(0.22) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .help("Navigate Log to HEAD")
        .contextMenu {
            if let reference = dashboardReference(
                rootPath: snapshot.rootPath,
                name: "HEAD",
                kind: .head
            ) {
                BranchDashboardActionMenu(
                    selection: dashboardSelection(for: reference),
                    handlers: dashboardActionHandlers,
                    allowsWorktreeAction: true
                )
            }
        }
    }

    @ViewBuilder
    private func remoteSection(_ snapshot: GitRootBranchSnapshot) -> some View {
        HStack(spacing: 6) {
            Text("REMOTE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Configure…") { onConfigureRemotes() }
                .buttonStyle(.borderless)
                .font(.caption2)
        }
        .padding(.top, 4)

        remoteBranchRows(snapshot)
    }

    @ViewBuilder
    private func remoteBranchRows(_ snapshot: GitRootBranchSnapshot) -> some View {
        ForEach(remoteGroupNames(snapshot), id: \.self) { remoteName in
            remoteGroupRow(
                rootPath: snapshot.rootPath,
                name: remoteName,
                branchCount: snapshot.remoteBranches.filter { $0.remote == remoteName }.count
            )
            branchSection(
                title: "",
                names: snapshot.remoteBranches
                    .filter { $0.remote == remoteName }
                    .map(\.name),
                rootPath: snapshot.rootPath,
                isRemote: true,
                snapshot: snapshot,
                scopeSuffix: remoteName
            )
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

    @ViewBuilder
    private func tagSection(_ snapshot: GitRootBranchSnapshot) -> some View {
        if !snapshot.tags.isEmpty {
            Text("TAGS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            tagRows(snapshot)
        }
    }

    @ViewBuilder
    private func tagRows(_ snapshot: GitRootBranchSnapshot) -> some View {
            ForEach(visibleBranchDirectoryRows(
                branchDirectoryRows(
                    for: snapshot.tags.map(\.name),
                    grouped: groupByDirectory,
                    scope: "\(snapshot.rootPath).log.tags"
                ),
                collapsedGroups: collapsedDirectoryGroups
            )) { row in
                if row.isGroup {
                    directoryGroupRow(row)
                } else if let tagName = branchReferenceName(row),
                          let tag = snapshot.tags.first(where: { $0.name == tagName }) {
                    tagRow(
                        tag,
                        title: row.name,
                        depth: row.depth,
                        rootPath: snapshot.rootPath
                    )
                }
            }
    }

    @ViewBuilder
    private func branchSection(
        title: String,
        names: [String],
        rootPath: String,
        isRemote: Bool,
        snapshot: GitRootBranchSnapshot,
        scopeSuffix: String? = nil
    ) -> some View {
        if !title.isEmpty {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        ForEach(visibleBranchDirectoryRows(
            branchDirectoryRows(
                for: names,
                grouped: groupByDirectory,
                scope: "\(rootPath).log.\(isRemote ? "remote" : "local")\(scopeSuffix.map { ".\($0)" } ?? "")"
            ),
            collapsedGroups: collapsedDirectoryGroups
        )) { row in
            if row.isGroup {
                directoryGroupRow(row)
            } else if let branchName = branchReferenceName(row) {
                if isRemote,
                   let branch = snapshot.remoteBranches.first(where: { $0.name == branchName }) {
                    remoteBranchRow(branch, title: row.name, depth: row.depth, rootPath: rootPath)
                } else if !isRemote,
                          let branch = snapshot.branches.first(where: { $0.name == branchName }) {
                    localBranchRow(branch, title: row.name, depth: row.depth, rootPath: rootPath)
                }
            }
        }
    }

    private func localBranchRow(
        _ branch: BranchInfo,
        title: String,
        depth: Int,
        rootPath: String
    ) -> some View {
        let id = targetID(rootPath: rootPath, kind: .local, value: branch.name)
        let isFavorite = dashboardReference(rootPath: rootPath, name: branch.name, kind: .local)
            .map { favoriteReferenceIDs.contains($0.favoriteID) } == true
        return Button {
            selectBranchTarget(id: id, rootPath: rootPath, branch: branch.name)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: branch.isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch")
                    .foregroundStyle(branch.isCurrent ? .blue : .secondary)
                Text(title)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(branch.isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                Spacer()
                if isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                }
                Text(branch.shortId)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, CGFloat(depth) * 14)
        .background(
            selectedBranchTargetIDs.contains(id) ? Color.accentColor.opacity(0.22) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .help(branch.isCurrent ? "Current branch" : "Navigate Log to \(branch.name)")
        .contextMenu {
            if let reference = dashboardReference(
                rootPath: rootPath,
                name: branch.name,
                kind: .local
            ) {
                branchActionMenu(for: reference)
            }
        }
    }

    private func remoteBranchRow(
        _ branch: RemoteBranchInfo,
        title: String,
        depth: Int,
        rootPath: String
    ) -> some View {
        let id = targetID(rootPath: rootPath, kind: .remote, value: branch.name)
        let isFavorite = dashboardReference(rootPath: rootPath, name: branch.name, kind: .remote)
            .map { favoriteReferenceIDs.contains($0.favoriteID) } == true
        return Button {
            selectBranchTarget(id: id, rootPath: rootPath, branch: branch.name)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cloud")
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                if isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                }
                Text(branch.shortId)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, CGFloat(depth) * 14)
        .background(
            selectedBranchTargetIDs.contains(id) ? Color.accentColor.opacity(0.22) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .help("Navigate Log to \(branch.name)")
        .contextMenu {
            if let reference = dashboardReference(
                rootPath: rootPath,
                name: branch.name,
                kind: .remote
            ) {
                branchActionMenu(for: reference)
            }
        }
    }

    private func tagRow(
        _ tag: TagInfo,
        title: String,
        depth: Int,
        rootPath: String
    ) -> some View {
        let id = targetID(rootPath: rootPath, kind: .tag, value: tag.name)
        let isFavorite = dashboardReference(rootPath: rootPath, name: tag.name, kind: .tag)
            .map { favoriteReferenceIDs.contains($0.favoriteID) } == true
        return Button {
            selectBranchTarget(id: id, rootPath: rootPath, branch: tag.name)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "tag")
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                if isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                }
                Text(tag.shortId)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, CGFloat(depth) * 14)
        .background(
            selectedBranchTargetIDs.contains(id) ? Color.accentColor.opacity(0.22) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .help("Navigate Log to \(tag.name)")
        .contextMenu {
            if let reference = dashboardReference(
                rootPath: rootPath,
                name: tag.name,
                kind: .tag
            ) {
                BranchDashboardActionMenu(
                    selection: dashboardSelection(for: reference),
                    handlers: dashboardActionHandlers,
                    allowsWorktreeAction: true
                )
            }
        }
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
            HStack(spacing: 6) {
                Image(systemName: "network")
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                Text("\(branchCount)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            selectedRemoteGroupIDs.contains(id) ? Color.accentColor.opacity(0.22) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .help("Remote \(name)")
        .contextMenu {
            remoteGroupActionMenu(for: [
                BranchDashboardRemoteGroup(rootPath: rootPath, name: name)
            ])
        }
    }

    private var dashboardActionHandlers: BranchDashboardActionHandlers {
        BranchDashboardActionHandlers(
            onFilterLog: { reference in
                onFilter([
                    LogRootBranchFilter(rootPath: reference.rootPath, branch: reference.name)
                ])
            },
            onCompareWithCurrent: { reference in
                onCompare(reference.rootPath, reference.name)
            },
            onShowDiffWithWorkingTree: { reference in
                onShowDiffWithWorkingTree(reference.rootPath, reference.name)
            },
            onDeleteTag: { reference in
                onDeleteTag(reference.rootPath, reference.name)
            },
            onPushTag: { reference in
                onPushTag(reference.rootPath, reference.name)
            },
            onPushTagToRemote: { reference, remote in
                onPushTagToRemote(reference.rootPath, reference.name, remote)
            },
            tagPushRemotes: { reference in
                snapshots.first(where: { $0.rootPath == reference.rootPath })?.remotes.map(\.name) ?? []
            },
            trackedReference: { reference in
                guard let snapshot = snapshots.first(where: { $0.rootPath == reference.rootPath }),
                      let sync = snapshot.syncStatuses.first(where: {
                          $0.branch == reference.name && $0.trackingExists
                      }),
                      let remoteBranch = snapshot.remoteBranches.first(where: {
                          $0.name == sync.upstream
                      }) else { return nil }
                let shortName = remoteBranch.name.split(separator: "/", maxSplits: 1)
                    .dropFirst()
                    .joined(separator: "/")
                return BranchDashboardReference(
                    rootPath: snapshot.rootPath,
                    name: remoteBranch.name,
                    kind: .remote,
                    remote: remoteBranch.remote,
                    localBranchName: reference.name,
                    isCurrent: false,
                    hasUpstream: false,
                    hasTracking: false,
                    hasRemote: true,
                    isProtected: GitProtectedBranchRules.matches(
                        shortName.isEmpty ? remoteBranch.name : shortName,
                        patterns: protectedBranchPatterns
                    )
                )
            },
            onCompareSelected: { selection in
                guard let pair = branchDashboardComparisonPair(selection: selection) else { return }
                onCompareSelected(pair.rootPath, pair.first, pair.second)
            },
            onCompareSelectedFiles: { selection in
                guard let pair = branchDashboardComparisonPair(selection: selection) else { return }
                onCompareSelectedFiles(pair.rootPath, pair.first, pair.second)
            },
            onUpdateSelected: onUpdateSelected,
            onDeleteSelected: onDeleteSelected,
            onCheckout: { reference in
                if reference.kind == .tag {
                    onCheckoutTag(reference.rootPath, reference.name)
                } else {
                    onCheckout(reference.rootPath, reference.name, reference.kind == .remote)
                }
            },
            onCheckoutAsNewBranch: { reference in
                onCheckoutAsNewBranch(reference.rootPath, reference.name, reference.kind == .remote)
            },
            onOpenWorktree: { reference in
                guard let path = reference.worktreePath else { return }
                onOpenWorktree(path)
            },
            onCreateWorktreeFromReference: { reference in
                let source = reference.kind == .head
                    ? snapshots.first(where: { $0.rootPath == reference.rootPath })?.headBranch ?? "HEAD"
                    : reference.name
                onCreateWorktreeFromReference(
                    reference.rootPath,
                    source,
                    reference.kind == .tag
                )
            },
            onCheckoutAndUpdate: { reference in
                onCheckoutAndUpdate(reference.rootPath, reference.name, false)
            },
            onCheckoutWithRebase: { reference in
                onCheckoutWithRebase(reference.rootPath, reference.name, reference.kind == .remote)
            },
            onUpdate: { reference in
                onUpdate(reference.rootPath, reference.name)
            },
            onMerge: { reference in
                onMerge(reference.rootPath, reference.name)
            },
            onRebase: { reference in
                onRebase(reference.rootPath, reference.name)
            },
            onPush: { reference in
                onPush(reference.rootPath, reference.name)
            },
            onFetch: { reference in
                onFetch(reference.rootPath, reference.name)
            },
            onPull: { reference, rebase in
                guard let localBranchName = reference.localBranchName else { return }
                onPullBranch(reference.rootPath, localBranchName, rebase)
            },
            onSetUpstream: { reference in
                onSetUpstream(reference.rootPath, reference.name)
            },
            onUnsetUpstream: { reference in
                onUnsetUpstream(reference.rootPath, reference.name)
            },
            onRename: { reference in
                onRename(reference.rootPath, reference.name)
            },
            onDelete: { reference in
                onDelete(reference.rootPath, reference.name)
            },
            onDeleteRemote: { reference in
                onDeleteRemote(reference.rootPath, reference.name)
            }
        )
    }

    @ViewBuilder
    private func branchActionMenu(for reference: BranchDashboardReference) -> some View {
        BranchDashboardActionMenu(
            selection: dashboardSelection(for: reference),
            handlers: dashboardActionHandlers,
            allowsWorktreeAction: true
        )
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
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, CGFloat(row.depth) * 14)
        }
        .buttonStyle(.plain)
    }

    private func selectBranchTarget(id: String, rootPath: String, branch: String) {
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
        performSelectionAction()
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

    private func branchReferenceName(_ row: BranchDirectoryRow) -> String? {
        guard !row.isGroup, row.id.hasPrefix("branch:") else { return nil }
        return String(row.id.dropFirst("branch:".count))
    }
}

private struct BranchDashboardActionHandlers {
    let onFilterLog: (BranchDashboardReference) -> Void
    let onCompareWithCurrent: (BranchDashboardReference) -> Void
    let onShowDiffWithWorkingTree: (BranchDashboardReference) -> Void
    let onDeleteTag: (BranchDashboardReference) -> Void
    let onPushTag: (BranchDashboardReference) -> Void
    let onPushTagToRemote: (BranchDashboardReference, String) -> Void
    let tagPushRemotes: (BranchDashboardReference) -> [String]
    let trackedReference: (BranchDashboardReference) -> BranchDashboardReference?
    let onCompareSelected: ([BranchDashboardReference]) -> Void
    let onCompareSelectedFiles: ([BranchDashboardReference]) -> Void
    let onUpdateSelected: ([BranchDashboardReference]) -> Void
    let onDeleteSelected: ([BranchDashboardReference]) -> Void
    let onCheckout: (BranchDashboardReference) -> Void
    let onCheckoutAsNewBranch: (BranchDashboardReference) -> Void
    let onOpenWorktree: (BranchDashboardReference) -> Void
    let onCreateWorktreeFromReference: (BranchDashboardReference) -> Void
    let onCheckoutAndUpdate: (BranchDashboardReference) -> Void
    let onCheckoutWithRebase: (BranchDashboardReference) -> Void
    let onUpdate: (BranchDashboardReference) -> Void
    let onMerge: (BranchDashboardReference) -> Void
    let onRebase: (BranchDashboardReference) -> Void
    let onPush: (BranchDashboardReference) -> Void
    let onFetch: (BranchDashboardReference) -> Void
    let onPull: (BranchDashboardReference, Bool) -> Void
    let onSetUpstream: (BranchDashboardReference) -> Void
    let onUnsetUpstream: (BranchDashboardReference) -> Void
    let onRename: (BranchDashboardReference) -> Void
    let onDelete: (BranchDashboardReference) -> Void
    let onDeleteRemote: (BranchDashboardReference) -> Void
}

private struct BranchDashboardActionMenu: View {
    let selection: [BranchDashboardReference]
    let handlers: BranchDashboardActionHandlers
    var allowsWorktreeAction = true

    var body: some View {
        let availability = BranchDashboardActionAvailability.resolve(selection: selection)
        let reference = selection.first

        Group {
            if let reference, availability.contains(.filterLog) {
                Button("Filter Log Here") {
                    handlers.onFilterLog(reference)
                }
            }
            if let reference, availability.contains(.compareWithCurrent) {
                Button("Compare with Current…") {
                    handlers.onCompareWithCurrent(reference)
                }
            }
            if let reference, availability.contains(.showDiffWithWorkingTree) {
                Button("Show Diff with Working Tree") {
                    handlers.onShowDiffWithWorkingTree(reference)
                }
            }
            if let reference,
               reference.kind == .local,
               reference.hasTracking,
               let tracked = handlers.trackedReference(reference) {
                Divider()
                Menu("Tracked Branch ((tracked.name))") {
                    AnyView(
                        BranchDashboardActionMenu(
                            selection: [tracked],
                            handlers: handlers,
                            allowsWorktreeAction: allowsWorktreeAction
                        )
                    )
                }
            }
            if let reference, availability.contains(.deleteTag) || availability.contains(.pushTag) {
                Divider()
                if availability.contains(.pushTag) {
                    let pushRemotes = handlers.tagPushRemotes(reference)
                    if pushRemotes.count > 1 {
                        Menu("Push Tag…") {
                            ForEach(pushRemotes, id: \.self) { remote in
                                Button(remote) {
                                    handlers.onPushTagToRemote(reference, remote)
                                }
                            }
                        }
                    } else {
                        Button("Push Tag…") {
                            handlers.onPushTag(reference)
                        }
                    }
                }
                if availability.contains(.deleteTag) {
                    Button("Delete Tag…", role: .destructive) {
                        handlers.onDeleteTag(reference)
                    }
                }
            }
            if availability.contains(.compareSelected), selection.count == 2 {
                Button("Compare Branches") {
                    handlers.onCompareSelected(selection)
                }
                .disabled(!availability.isEnabled(.compareSelected))
            }
            if availability.contains(.compareSelectedFiles), selection.count == 2 {
                Button("Show Files Diff") {
                    handlers.onCompareSelectedFiles(selection)
                }
                .disabled(!availability.isEnabled(.compareSelectedFiles))
            }

            if availability.contains(.updateSelected) {
                Button("Update Selected Branches") {
                    handlers.onUpdateSelected(selection)
                }
                .disabled(!availability.isEnabled(.updateSelected))
                .help(
                    availability.disabledDescription(for: .updateSelected)
                        ?? "Update Selected Branches"
                )
            }
            if availability.contains(.deleteSelected) {
                Button("Delete Selected Branches…", role: .destructive) {
                    handlers.onDeleteSelected(selection)
                }
                .disabled(!availability.isEnabled(.deleteSelected))
            }

            if availability.contains(.checkout)
                || availability.contains(.checkoutAsNewBranch)
                || (allowsWorktreeAction && availability.contains(.openWorktree))
                || availability.contains(.checkoutWithUpdate)
                || availability.contains(.checkoutWithRebase)
                || availability.contains(.update)
                || availability.contains(.merge)
                || availability.contains(.rebase)
                || (allowsWorktreeAction && availability.contains(.createWorktree))
                || availability.contains(.push)
                || availability.contains(.fetch)
                || availability.contains(.pull)
                || availability.contains(.pullWithRebase) {
                Divider()
            }
            if let reference, availability.contains(.checkout) {
                Button(reference.kind == .remote ? "Checkout as Local Branch" : "Checkout") {
                    handlers.onCheckout(reference)
                }
            }
            if let reference, availability.contains(.checkoutAsNewBranch) {
                Button(reference.kind == .head ? "New Branch from HEAD…" : "Checkout as New Branch…") {
                    handlers.onCheckoutAsNewBranch(reference)
                }
                .disabled(!availability.isEnabled(.checkoutAsNewBranch))
            }
            if let reference,
               allowsWorktreeAction,
               availability.contains(.openWorktree),
               reference.worktreePath != nil {
                Button("Open Worktree…") {
                    handlers.onOpenWorktree(reference)
                }
            }
            if let reference, availability.contains(.checkoutWithUpdate) {
                Button("Checkout and Update") {
                    handlers.onCheckoutAndUpdate(reference)
                }
                .disabled(!availability.isEnabled(.checkoutWithUpdate))
                .help(
                    availability.disabledDescription(for: .checkoutWithUpdate)
                        ?? "Checkout and Update"
                )
            }
            if let reference, availability.contains(.checkoutWithRebase) {
                Button("Checkout with Rebase") {
                    handlers.onCheckoutWithRebase(reference)
                }
                .disabled(!availability.isEnabled(.checkoutWithRebase))
            }
            if let reference, availability.contains(.update) {
                Button("Update") {
                    handlers.onUpdate(reference)
                }
                .disabled(!availability.isEnabled(.update))
                .help(
                    availability.disabledDescription(for: .update)
                        ?? "Update Branch"
                )
            }
            if let reference, availability.contains(.merge) {
                Button("Merge into Current…") {
                    handlers.onMerge(reference)
                }
            }
            if let reference, availability.contains(.rebase) {
                Button("Rebase Current onto…") {
                    handlers.onRebase(reference)
                }
            }
            if let reference,
               allowsWorktreeAction,
               availability.contains(.createWorktree) {
                Button(
                    reference.kind == .tag
                        ? "New Working Tree from Tag…"
                        : reference.kind == .head
                            ? "New Working Tree from HEAD…"
                            : "New Working Tree from Branch…"
                ) {
                    handlers.onCreateWorktreeFromReference(reference)
                }
                .disabled(!availability.isEnabled(.createWorktree))
            }
            if let reference, availability.contains(.push) {
                Button("Push…") {
                    handlers.onPush(reference)
                }
            }
            if let reference, availability.contains(.fetch) {
                Button("Fetch") {
                    handlers.onFetch(reference)
                }
            }
            if let reference, availability.contains(.pull), let localBranchName = reference.localBranchName {
                Button("Pull Local Branch (\(localBranchName))") {
                    handlers.onPull(reference, false)
                }
            }
            if let reference,
               availability.contains(.pullWithRebase),
               let localBranchName = reference.localBranchName {
                Button("Pull Local Branch (\(localBranchName)) with Rebase") {
                    handlers.onPull(reference, true)
                }
            }

            if let reference,
               availability.contains(.setUpstream) || availability.contains(.unsetUpstream) {
                Divider()
                if availability.contains(.setUpstream) {
                    Button("Set Upstream…") {
                        handlers.onSetUpstream(reference)
                    }
                }
                if availability.contains(.unsetUpstream) {
                    Button("Unset Upstream") {
                        handlers.onUnsetUpstream(reference)
                    }
                }
            }

            if let reference,
               availability.contains(.rename)
                || availability.contains(.deleteLocal)
                || availability.contains(.deleteRemote) {
                Divider()
                if availability.contains(.rename) {
                    Button("Rename Branch…") {
                        handlers.onRename(reference)
                    }
                }
                if availability.contains(.deleteLocal) {
                    Button("Delete Branch…", role: .destructive) {
                        handlers.onDelete(reference)
                    }
                }
                if availability.contains(.deleteRemote) {
                    Button("Delete Remote Branch…", role: .destructive) {
                        handlers.onDeleteRemote(reference)
                    }
                }
            }
        }
    }
}

private struct LogBranchesPanel: View {
    let projectPath: String?
    let branches: [BranchInfo]
    let remoteBranches: [RemoteBranchInfo]
    let remotes: [RemoteInfo]
    let tags: [TagInfo]
    let hasHeadCommit: Bool
    let syncStatuses: [SyncStatus]
    let protectedBranchPatterns: [String]
    @Binding var groupByDirectory: Bool
    @Binding var selectionActionRaw: String
    @Binding var showOnlyMy: Bool
    let myBranchIDs: Set<String>
    let isLoadingMyBranches: Bool
    let onShowOnlyMyChanged: (Bool) -> Void
    let onNavigate: (String) -> Void
    let onFilter: ([LogRootBranchFilter]) -> Void
    let onCompare: (String) -> Void
    let onNewBranch: () -> Void
    let onCleanup: () -> Void
    let onFindMerged: () -> Void
    let onHide: () -> Void
    let onDelete: (String) -> Void
    let onCheckout: (String, Bool) -> Void
    let onCheckoutAsNewBranch: (String, Bool) -> Void
    let worktrees: [WorktreeInfo]
    let onOpenWorktree: (String) -> Void
    let onCreateWorktreeFromReference: (String, Bool) -> Void
    let onCheckoutTag: (String) -> Void
    let onCheckoutAndUpdate: (String, Bool) -> Void
    let onCheckoutWithRebase: (String, Bool) -> Void
    let onPullBranch: (String, Bool) -> Void
    let onUpdate: (String) -> Void
    let onMerge: (String) -> Void
    let onRebase: (String) -> Void
    let onShowDiffWithWorkingTree: (String) -> Void
    let onDeleteTag: (TagInfo) -> Void
    let onPushTag: (String) -> Void
    let onPushTagToRemote: (String, String) -> Void
    let onCompareSelected: ([BranchDashboardReference]) -> Void
    let onCompareSelectedFiles: ([BranchDashboardReference]) -> Void
    let onUpdateSelected: ([BranchDashboardReference]) -> Void
    let onDeleteSelected: ([BranchDashboardReference]) -> Void
    let onPush: (String) -> Void
    let onFetch: (String) -> Void
    let onFetchAll: () -> Void
    let onSetUpstream: (String) -> Void
    let onUnsetUpstream: (String) -> Void
    let onRename: (String) -> Void
    let onDeleteRemote: (RemoteBranchInfo) -> Void

    @State private var query = ""
    @State private var pendingDelete: String?
    @State private var collapsedDirectoryGroups: Set<String> = []
    @State private var selectedBranchTargetID: String?
    @State private var selectedBranchTargetIDs: Set<String> = []
    @State private var favoriteReferenceIDs: Set<String> = []
    @State private var showTags = GitBranchesPopupSettings.defaultShowTags

    private var dashboardReferences: [BranchDashboardReference] {
        let rootPath = projectPath ?? ""
        let headReference = BranchDashboardReference(
            rootPath: rootPath,
            name: "HEAD",
            kind: .head,
            remote: nil,
            isCurrent: true,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false,
            hasHeadCommit: hasHeadCommit,
            worktreePath: branches.first(where: { $0.isCurrent }).flatMap { branch in
                linkedWorktreePathForBranch(
                    branch: branch.name,
                    worktrees: worktrees,
                    currentRootPath: rootPath
                )
            },
            headBranchName: branches.first(where: { $0.isCurrent })?.name
        )
        let localReferences = filteredBranches.map { branch in
            let sync = syncStatuses.first { $0.branch == branch.name }
            return BranchDashboardReference(
                rootPath: rootPath,
                name: branch.name,
                kind: .local,
                remote: nil,
                isCurrent: branch.isCurrent,
                hasUpstream: sync != nil,
                hasTracking: sync?.trackingExists == true,
                hasRemote: !remoteBranches.isEmpty || sync != nil,
                isProtected: GitProtectedBranchRules.matches(
                    branch.name,
                    patterns: protectedBranchPatterns
                ),
                worktreePath: linkedWorktreePathForBranch(
                    branch: branch.name,
                    worktrees: worktrees,
                    currentRootPath: rootPath
                )
            )
        }
        let remoteReferences = filteredRemoteBranches.map { branch in
            let localBranchName = syncStatuses.first { $0.upstream == branch.name }?.branch
            let shortName = branch.name.split(separator: "/", maxSplits: 1)
                .dropFirst()
                .joined(separator: "/")
            return BranchDashboardReference(
                rootPath: rootPath,
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
        let tagReferences = filteredTags.map { tag in
            BranchDashboardReference(
                rootPath: rootPath,
                name: tag.name,
                kind: .tag,
                remote: nil,
                isCurrent: tag.isCurrent,
                hasUpstream: false,
                hasTracking: false,
                hasRemote: !remotes.isEmpty,
                isProtected: false
            )
        }
        return [headReference] + localReferences + remoteReferences + tagReferences
    }

    private var selectedDashboardReferences: [BranchDashboardReference] {
        dashboardReferences.filter { reference in
            selectedBranchTargetIDs.contains(dashboardTargetID(for: reference))
        }
    }

    private var selectedBranchReferencesForCurrentComparison: [BranchDashboardReference] {
        selectedDashboardReferences.filter { reference in
            (reference.kind == .local || reference.kind == .remote) && !reference.isCurrent
        }
    }

    private func dashboardTargetID(for reference: BranchDashboardReference) -> String {
        let kind: String
        switch reference.kind {
        case .head: kind = "head"
        case .local: kind = "local"
        case .remote: kind = "remote"
        case .tag: kind = "tag"
        }
        return "log.\(kind):\(reference.name)"
    }

    private func dashboardSelection(
        for reference: BranchDashboardReference
    ) -> [BranchDashboardReference] {
        let selected = selectedDashboardReferences
        return selected.contains(reference) ? selected : [reference]
    }

    private var dashboardActionHandlers: BranchDashboardActionHandlers {
        BranchDashboardActionHandlers(
            onFilterLog: { reference in
                guard let rootPath = projectPath, !rootPath.isEmpty else { return }
                onFilter([
                    LogRootBranchFilter(rootPath: rootPath, branch: reference.name)
                ])
            },
            onCompareWithCurrent: { reference in
                onCompare(reference.name)
            },
            onShowDiffWithWorkingTree: { reference in
                onShowDiffWithWorkingTree(reference.name)
            },
            onDeleteTag: { reference in
                guard let tag = tags.first(where: { $0.name == reference.name }) else { return }
                onDeleteTag(tag)
            },
            onPushTag: { reference in
                guard let tag = tags.first(where: { $0.name == reference.name }) else { return }
                onPushTag(tag.name)
            },
            onPushTagToRemote: { reference, remote in
                onPushTagToRemote(reference.name, remote)
            },
            tagPushRemotes: { _ in remotes.map(\.name) },
            trackedReference: { reference in
                guard let sync = syncStatuses.first(where: {
                    $0.branch == reference.name && $0.trackingExists
                }),
                      let remoteBranch = remoteBranches.first(where: {
                          $0.name == sync.upstream
                      }) else { return nil }
                let shortName = remoteBranch.name.split(separator: "/", maxSplits: 1)
                    .dropFirst()
                    .joined(separator: "/")
                return BranchDashboardReference(
                    rootPath: reference.rootPath,
                    name: remoteBranch.name,
                    kind: .remote,
                    remote: remoteBranch.remote,
                    localBranchName: reference.name,
                    isCurrent: false,
                    hasUpstream: false,
                    hasTracking: false,
                    hasRemote: true,
                    isProtected: GitProtectedBranchRules.matches(
                        shortName.isEmpty ? remoteBranch.name : shortName,
                        patterns: protectedBranchPatterns
                    )
                )
            },
            onCompareSelected: onCompareSelected,
            onCompareSelectedFiles: onCompareSelectedFiles,
            onUpdateSelected: onUpdateSelected,
            onDeleteSelected: onDeleteSelected,
            onCheckout: { reference in
                if reference.kind == .tag {
                    onCheckoutTag(reference.name)
                } else {
                    onCheckout(reference.name, reference.kind == .remote)
                }
            },
            onCheckoutAsNewBranch: { reference in
                onCheckoutAsNewBranch(reference.name, reference.kind == .remote)
            },
            onOpenWorktree: { reference in
                guard let path = reference.worktreePath else { return }
                onOpenWorktree(path)
            },
            onCreateWorktreeFromReference: { reference in
                let source = reference.kind == .head
                    ? branches.first(where: { $0.isCurrent })?.name ?? "HEAD"
                    : reference.name
                onCreateWorktreeFromReference(source, reference.kind == .tag)
            },
            onCheckoutAndUpdate: { reference in
                onCheckoutAndUpdate(reference.name, false)
            },
            onCheckoutWithRebase: { reference in
                onCheckoutWithRebase(reference.name, reference.kind == .remote)
            },
            onUpdate: { reference in
                onUpdate(reference.name)
            },
            onMerge: { reference in
                onMerge(reference.name)
            },
            onRebase: { reference in
                onRebase(reference.name)
            },
            onPush: { reference in
                onPush(reference.name)
            },
            onFetch: { reference in
                onFetch(reference.name)
            },
            onPull: { reference, rebase in
                guard let localBranchName = reference.localBranchName else { return }
                onPullBranch(localBranchName, rebase)
            },
            onSetUpstream: { reference in
                onSetUpstream(reference.name)
            },
            onUnsetUpstream: { reference in
                onUnsetUpstream(reference.name)
            },
            onRename: { reference in
                onRename(reference.name)
            },
            onDelete: { reference in
                pendingDelete = reference.name
            },
            onDeleteRemote: { reference in
                guard let branch = remoteBranches.first(where: { $0.name == reference.name }) else { return }
                onDeleteRemote(branch)
            }
        )
    }

    private var filteredBranches: [BranchInfo] {
        branches.filter { branch in
            branchSearchMatches(branch.name, query: query)
                && (!showOnlyMy || myBranchIDs.contains(BranchDashboardReference.referenceID(
                    rootPath: projectPath ?? "",
                    name: branch.name,
                    kind: .local
                )))
        }
    }

    private var filteredRemoteBranches: [RemoteBranchInfo] {
        remoteBranches.filter { branch in
            branchSearchMatches(branch.name, query: query)
                && (!showOnlyMy || myBranchIDs.contains(BranchDashboardReference.referenceID(
                    rootPath: projectPath ?? "",
                    name: branch.name,
                    kind: .remote
                )))
        }
    }

    private var filteredTags: [TagInfo] {
        guard showTags, !showOnlyMy else { return [] }
        return tags.filter { branchSearchMatches($0.name, query: query) }
    }

    private var selectionAction: LogBranchSelectionAction {
        get { LogBranchSelectionAction(rawValue: selectionActionRaw) ?? .navigate }
        set { selectionActionRaw = newValue.rawValue }
    }

    private var selectionActionBinding: Binding<LogBranchSelectionAction> {
        Binding(
            get: { LogBranchSelectionAction(rawValue: selectionActionRaw) ?? .navigate },
            set: {
                selectionActionRaw = $0.rawValue
                GitBranchesPopupSettings.save(
                    $0.rawValue,
                    GitBranchesPopupSettings.logSelectionActionKey,
                    for: projectPath
                )
            }
        )
    }

    private var keyboardTargets: [BranchTreeTarget] {
        let head = BranchTreeTarget(
            id: "log.head:HEAD",
            value: "HEAD",
            title: "HEAD",
            kind: .head
        )
        let localNames = visibleBranchDirectoryRefNames(
            filteredBranches.map(\.name),
            grouped: groupByDirectory,
            scope: "log.local",
            collapsedGroups: collapsedDirectoryGroups
        )
        let remoteNames = visibleBranchDirectoryRefNames(
            filteredRemoteBranches.map(\.name),
            grouped: groupByDirectory,
            scope: "log.remote",
            collapsedGroups: collapsedDirectoryGroups
        )
        let tagNames = visibleBranchDirectoryRefNames(
            filteredTags.map(\.name),
            grouped: groupByDirectory,
            scope: "log.tags",
            collapsedGroups: collapsedDirectoryGroups
        )
        return [head] + localNames.map {
            BranchTreeTarget(id: "log.local:\($0)", value: $0, title: $0, kind: .local)
        } + remoteNames.map {
            BranchTreeTarget(id: "log.remote:\($0)", value: $0, title: $0, kind: .remote)
        } + tagNames.map {
            BranchTreeTarget(id: "log.tag:\($0)", value: $0, title: $0, kind: .tag)
        }
    }

    private var localDirectoryRows: [BranchDirectoryRow] {
        branchDirectoryRows(
            for: filteredBranches.map(\.name),
            grouped: groupByDirectory,
            scope: "log.local"
        )
    }

    private var remoteDirectoryRows: [BranchDirectoryRow] {
        branchDirectoryRows(
            for: filteredRemoteBranches.map(\.name),
            grouped: groupByDirectory,
            scope: "log.remote"
        )
    }

    private var tagDirectoryRows: [BranchDirectoryRow] {
        branchDirectoryRows(
            for: filteredTags.map(\.name),
            grouped: groupByDirectory,
            scope: "log.tags"
        )
    }

    private var pendingDeleteBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerView
            filterView
            optionsView
            dashboardActionToolbar

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    headRow
                    Text("LOCAL")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(visibleBranchDirectoryRows(
                        localDirectoryRows,
                        collapsedGroups: collapsedDirectoryGroups
                    )) { row in
                        if row.isGroup {
                            directoryGroupRow(row)
                        } else if let branchName = branchDirectoryRefNameForLog(row),
                                  let branch = filteredBranches.first(where: { $0.name == branchName }) {
                            branchRow(
                                branch,
                                title: row.name,
                                depth: row.depth,
                                selected: selectedBranchTargetIDs.contains("log.local:\(branch.name)")
                            )
                        }
                    }

                    Text("REMOTE")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    ForEach(visibleBranchDirectoryRows(
                        remoteDirectoryRows,
                        collapsedGroups: collapsedDirectoryGroups
                    )) { row in
                        if row.isGroup {
                            directoryGroupRow(row)
                        } else if let branchName = branchDirectoryRefNameForLog(row),
                                  let branch = filteredRemoteBranches.first(where: { $0.name == branchName }) {
                            remoteBranchRow(
                                branch,
                                title: row.name,
                                depth: row.depth,
                                selected: selectedBranchTargetIDs.contains("log.remote:\(branch.name)")
                            )
                        }
                    }
                    if !filteredTags.isEmpty {
                        Text("TAGS")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        ForEach(visibleBranchDirectoryRows(
                            tagDirectoryRows,
                            collapsedGroups: collapsedDirectoryGroups
                        )) { row in
                            if row.isGroup {
                                directoryGroupRow(row)
                            } else if let tagName = branchDirectoryRefNameForLog(row),
                                      let tag = filteredTags.first(where: { $0.name == tagName }) {
                                tagRow(
                                    tag,
                                    title: row.name,
                                    depth: row.depth,
                                    selected: selectedBranchTargetIDs.contains("log.tag:\(tag.name)")
                                )
                            }
                        }
                    }
                    if filteredBranches.isEmpty && filteredRemoteBranches.isEmpty && filteredTags.isEmpty {
                        Text("No matching branches")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(10)
        .frame(width: 230)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Colors.surface.opacity(0.55))
        .onAppear {
            groupByDirectory = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.groupByDirectoryKey,
                for: projectPath
            )
            favoriteReferenceIDs = GitBranchesPopupSettings.favorites(for: projectPath)
            showTags = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.showTagsKey,
                for: projectPath
            )
            selectedBranchTargetID = bestBranchTreeTargetID(
                query: query,
                targets: keyboardTargets,
                preserving: selectedBranchTargetID
            )
            if selectedBranchTargetIDs.isEmpty, let selectedBranchTargetID {
                selectedBranchTargetIDs = [selectedBranchTargetID]
            }
            collapsedDirectoryGroups = GitBranchesPopupSettings.collapsedDirectoryGroups(
                for: projectPath,
                setting: GitBranchesPopupSettings.logCollapsedDirectoryGroupsKey
            )
        }
        .onChange(of: collapsedDirectoryGroups) { _, value in
            GitBranchesPopupSettings.saveCollapsedDirectoryGroups(
                value,
                for: projectPath,
                setting: GitBranchesPopupSettings.logCollapsedDirectoryGroupsKey
            )
        }
        .onChange(of: groupByDirectory) { _, value in
            GitBranchesPopupSettings.save(
                value,
                GitBranchesPopupSettings.groupByDirectoryKey,
                for: projectPath
            )
            selectedBranchTargetID = bestBranchTreeTargetID(
                query: query,
                targets: keyboardTargets,
                preserving: selectedBranchTargetID
            )
            let visibleIDs = Set(keyboardTargets.map(\.id))
            selectedBranchTargetIDs = selectedBranchTargetIDs.intersection(visibleIDs)
        }
        .onChange(of: query) { _, _ in
            selectedBranchTargetID = bestBranchTreeTargetID(
                query: query,
                targets: keyboardTargets,
                preserving: selectedBranchTargetID
            )
            let visibleIDs = Set(keyboardTargets.map(\.id))
            selectedBranchTargetIDs = selectedBranchTargetIDs.intersection(visibleIDs)
            if selectedBranchTargetIDs.isEmpty, let selectedBranchTargetID {
                selectedBranchTargetIDs = [selectedBranchTargetID]
            }
        }
        .onChange(of: showOnlyMy) { _, value in
            onShowOnlyMyChanged(value)
            selectedBranchTargetID = bestBranchTreeTargetID(
                query: query,
                targets: keyboardTargets,
                preserving: selectedBranchTargetID
            )
            let visibleIDs = Set(keyboardTargets.map(\.id))
            selectedBranchTargetIDs = selectedBranchTargetIDs.intersection(visibleIDs)
            if selectedBranchTargetIDs.isEmpty, let selectedBranchTargetID {
                selectedBranchTargetIDs = [selectedBranchTargetID]
            }
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
            let visibleIDs = Set(keyboardTargets.map(\.id))
            selectedBranchTargetIDs = selectedBranchTargetIDs.intersection(visibleIDs)
            if selectedBranchTargetIDs.isEmpty, let selectedBranchTargetID,
               visibleIDs.contains(selectedBranchTargetID) {
                selectedBranchTargetIDs = [selectedBranchTargetID]
            }
        }
        .alert("Delete branch?", isPresented: pendingDeleteBinding) {
            Button("Delete", role: .destructive) {
                if let pendingDelete { onDelete(pendingDelete) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Only the local branch reference will be removed. Unmerged commits remain in the repository until garbage collection.")
        }
    }

    private var headerView: some View {
        HStack(spacing: 6) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .foregroundStyle(.blue)
            Text("Branches")
                .font(.headline)
            Spacer()
            Button { createNewBranchFromSelection() } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New branch")
            Button { onHide() } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .help("Hide branches")
        }
    }

    private var headRow: some View {
        let id = "log.head:HEAD"
        return Button {
            selectBranchTarget(id: id, branch: "HEAD")
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "circle.hexagongrid.fill")
                    .foregroundStyle(.blue)
                Text("HEAD")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.semibold)
                if let current = branches.first(where: { $0.isCurrent })?.name {
                    Text("(\(current))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("(detached)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            selectedBranchTargetIDs.contains(id) ? Color.accentColor.opacity(0.22) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .help("Navigate Log to HEAD")
        .contextMenu {
            if let reference = dashboardReferences.first(where: {
                $0.kind == .head && $0.name == "HEAD"
            }) {
                BranchDashboardActionMenu(
                    selection: dashboardSelection(for: reference),
                    handlers: dashboardActionHandlers
                )
            }
        }
    }

    private var filterView: some View {
        TextField("Filter branches", text: $query)
            .textFieldStyle(.roundedBorder)
            .onSubmit { activateSelectedBranch() }
            .onKeyPress(.downArrow, action: handleDownKeyPress)
            .onKeyPress(.upArrow, action: handleUpKeyPress)
    }

    private var optionsView: some View {
        HStack(spacing: 6) {
            Toggle("Group by directory", isOn: $groupByDirectory)
                .toggleStyle(.checkbox)
                .font(.caption)
            Toggle("Show My Branches", isOn: $showOnlyMy)
                .toggleStyle(.checkbox)
                .font(.caption)
            Toggle("Show Tags", isOn: $showTags)
                .toggleStyle(.checkbox)
                .font(.caption)
            if isLoadingMyBranches {
                ProgressView()
                    .controlSize(.small)
            }
            Picker("On selection", selection: selectionActionBinding) {
                ForEach(LogBranchSelectionAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .help("Choose what selecting a branch does")
            Spacer()
            Menu("Actions…") {
                BranchDashboardActionMenu(
                    selection: selectedDashboardReferences,
                    handlers: dashboardActionHandlers
                )
            }
            .controlSize(.small)
            .disabled(selectedDashboardReferences.isEmpty)
            Button("Find Merged…") { onFindMerged() }
                .controlSize(.small)
            Button("Cleanup…") { onCleanup() }
                .controlSize(.small)
        }
    }

    private var dashboardActionToolbar: some View {
        let selection = selectedDashboardReferences
        let availability = BranchDashboardActionAvailability.resolve(selection: selection)
        let compareTargets = selectedBranchReferencesForCurrentComparison
        let canToggleFavorite = !selection.isEmpty
            && selection.allSatisfy { $0.kind != .head }

        return HStack(spacing: 5) {
            Button {
                onFetchAll()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
            .help("Fetch All Remotes")

            Button {
                toggleFavorites(selection)
            } label: {
                Image(systemName: "star")
            }
            .buttonStyle(.borderless)
            .disabled(!canToggleFavorite)
            .help("Mark/Unmark As Favorite")

            Button {
                compareTargets.forEach { onCompare($0.name) }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.borderless)
            .disabled(compareTargets.isEmpty)
            .help("Compare with Current")

            Button {
                onUpdateSelected(selection)
            } label: {
                Image(systemName: "arrow.down.to.line.compact")
            }
            .buttonStyle(.borderless)
            .disabled(!availability.isEnabled(.updateSelected))
            .help("Update Selected Branches")

            Button(role: .destructive) {
                onDeleteSelected(selection)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!availability.isEnabled(.deleteSelected))
            .help("Delete Selected")

            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    private func createNewBranchFromSelection() {
        guard selectedDashboardReferences.count == 1,
              let reference = selectedDashboardReferences.first,
              reference.kind != .head else {
            onNewBranch()
            return
        }
        onCheckoutAsNewBranch(reference.name, reference.kind == .remote)
    }

    @ViewBuilder
    private func branchRow(
        _ branch: BranchInfo,
        title: String? = nil,
        depth: Int = 0,
        selected: Bool = false
    ) -> some View {
        let isFavorite = dashboardReferences.first {
            $0.kind == .local && $0.name == branch.name
        }.map { favoriteReferenceIDs.contains($0.favoriteID) } == true
        Button {
            selectBranchTarget(
                id: "log.local:\(branch.name)",
                branch: branch.name
            )
        } label: {
            HStack(spacing: 6) {
                Image(systemName: branch.isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch")
                    .foregroundStyle(branch.isCurrent ? .blue : .secondary)
                Text(title ?? branch.name)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(branch.isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                Spacer()
                if isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                }
                Text(branch.shortId)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, CGFloat(depth) * 14)
        .background(selected ? Color.accentColor.opacity(0.22) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .help(branch.isCurrent ? "Current branch" : "Navigate Log to \(branch.name)")
        .contextMenu {
            if let reference = dashboardReferences.first(where: {
                $0.kind == .local && $0.name == branch.name
            }) {
                BranchDashboardActionMenu(
                    selection: dashboardSelection(for: reference),
                    handlers: dashboardActionHandlers
                )
            }
        }
    }

    @ViewBuilder
    private func remoteBranchRow(
        _ branch: RemoteBranchInfo,
        title: String? = nil,
        depth: Int = 0,
        selected: Bool = false
    ) -> some View {
        let isFavorite = dashboardReferences.first {
            $0.kind == .remote && $0.name == branch.name
        }.map { favoriteReferenceIDs.contains($0.favoriteID) } == true
        Button {
            selectBranchTarget(
                id: "log.remote:\(branch.name)",
                branch: branch.name
            )
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cloud")
                    .foregroundStyle(.secondary)
                Text(title ?? branch.name)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                if isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                }
                Text(branch.shortId)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, CGFloat(depth) * 14)
        .background(selected ? Color.accentColor.opacity(0.22) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .help("Navigate Log to \(branch.name)")
        .contextMenu {
            if let reference = dashboardReferences.first(where: {
                $0.kind == .remote && $0.name == branch.name
            }) {
                BranchDashboardActionMenu(
                    selection: dashboardSelection(for: reference),
                    handlers: dashboardActionHandlers
                )
            }
        }
    }

    @ViewBuilder
    private func tagRow(
        _ tag: TagInfo,
        title: String? = nil,
        depth: Int = 0,
        selected: Bool = false
    ) -> some View {
        let isFavorite = dashboardReferences.first {
            $0.kind == .tag && $0.name == tag.name
        }.map { favoriteReferenceIDs.contains($0.favoriteID) } == true
        Button {
            selectBranchTarget(
                id: "log.tag:\(tag.name)",
                branch: tag.name
            )
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "tag")
                    .foregroundStyle(.secondary)
                Text(title ?? tag.name)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                if isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                }
                Text(tag.shortId)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, CGFloat(depth) * 14)
        .background(selected ? Color.accentColor.opacity(0.22) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .help("Navigate Log to \(tag.name)")
        .contextMenu {
            if let reference = dashboardReferences.first(where: {
                $0.kind == .tag && $0.name == tag.name
            }) {
                BranchDashboardActionMenu(
                    selection: dashboardSelection(for: reference),
                    handlers: dashboardActionHandlers
                )
            }
        }
    }

    @ViewBuilder
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
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, CGFloat(row.depth) * 14)
        }
        .buttonStyle(.plain)
    }

    private func branchDirectoryRefNameForLog(_ row: BranchDirectoryRow) -> String? {
        guard !row.isGroup, row.id.hasPrefix("branch:") else { return nil }
        return String(row.id.dropFirst("branch:".count))
    }

    private func selectBranchTarget(id: String, branch: String) {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let anchor = selectedBranchTargetID
        selectedBranchTargetID = id
        if flags.contains(.shift),
           let anchor,
           let start = keyboardTargets.firstIndex(where: { $0.id == anchor }),
           let end = keyboardTargets.firstIndex(where: { $0.id == id }) {
            let range = start <= end ? start...end : end...start
            selectedBranchTargetIDs = Set(range.map { keyboardTargets[$0].id })
            performSelectionAction()
            return
        }
        if flags.contains(.command) {
            if selectedBranchTargetIDs.contains(id) {
                selectedBranchTargetIDs.remove(id)
            } else {
                selectedBranchTargetIDs.insert(id)
            }
            performSelectionAction()
            return
        }
        selectedBranchTargetIDs = [id]
        performSelectionAction()
    }

    private func moveSelectedBranch(by offset: Int) {
        let nextID = movedBranchTreeSelection(
            currentID: selectedBranchTargetID,
            selectableIDs: keyboardTargets.map(\.id),
            offset: offset
        )
        selectedBranchTargetID = nextID
        if let nextID {
            selectedBranchTargetIDs = [nextID]
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

    private func activateSelectedBranch() {
        guard let selectedBranchTargetID,
              keyboardTargets.contains(where: { $0.id == selectedBranchTargetID }) else { return }
        performSelectionAction()
    }

    private func performSelectionAction() {
        guard let reference = selectedDashboardReferences.first else { return }
        switch selectionAction {
        case .navigate:
            onNavigate(reference.name)
        case .filter:
            let filters = logBranchFiltersForDashboardSelection(selectedDashboardReferences)
            guard !filters.isEmpty else { return }
            onFilter(filters)
        case .none:
            break
        }
    }

    private func toggleFavorites(_ selection: [BranchDashboardReference]) {
        var updated = favoriteReferenceIDs
        for reference in selection {
            if updated.contains(reference.favoriteID) {
                updated.remove(reference.favoriteID)
            } else {
                updated.insert(reference.favoriteID)
            }
        }
        favoriteReferenceIDs = updated
        GitBranchesPopupSettings.saveFavorites(updated, for: projectPath)
    }
}

private struct LogWorkspaceEmptyView: View {
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "sidebar.right")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private func logFilterField(
    _ title: LocalizedStringKey,
    text: Binding<String>,
    width: CGFloat
) -> some View {
    TextField(title, text: text)
        .textFieldStyle(.plain)
        .padding(.horizontal, 10)
        .frame(width: width, height: 32)
        .background(Design.Colors.surface, in: RoundedRectangle(cornerRadius: 8))
}

private struct LogPathsTreeChooserView: View {
    let roots: [LogPathChooserRoot]
    @Binding var selections: Set<LogPathFilterSelection>
    let onCancel: () -> Void
    let onApply: () -> Void

    @State private var expandedRoots: Set<String> = []
    @State private var rootEntries: [String: [DirEntry]] = [:]
    @State private var loadingRoots: Set<String> = []
    @State private var rootErrors: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select Paths")
                .font(.headline)
            Text("Select files or folders from the Git roots")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(roots) { root in
                        rootSection(root)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(Design.Colors.surface, in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                Text("Selected paths: \(selections.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if selections.count >= logPathTreeSelectionLimit {
                    Text("Maximum 100 paths can be selected")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Apply", action: onApply)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selections.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 620, height: 520)
        .onAppear {
            let paths = Set(roots.map(\.path))
            expandedRoots = paths
            for root in roots {
                loadRootEntries(root)
            }
        }
    }

    @ViewBuilder
    private func rootSection(_ root: LogPathChooserRoot) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expandedRoots.contains(root.path) },
                set: { expanded in
                    if expanded {
                        expandedRoots.insert(root.path)
                        loadRootEntries(root)
                    } else {
                        expandedRoots.remove(root.path)
                    }
                }
            )
        ) {
            if let error = rootErrors[root.path], (rootEntries[root.path] ?? []).isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 22)
            } else if loadingRoots.contains(root.path) && (rootEntries[root.path] ?? []).isEmpty {
                ProgressView("Loading…")
                    .controlSize(.small)
                    .padding(.leading, 22)
            } else {
                ForEach(rootEntries[root.path] ?? [], id: \.path) { entry in
                    LogPathTreeNodeView(
                        repository: root.repository,
                        rootPath: root.path,
                        entry: entry,
                        depth: 0,
                        selections: $selections
                    )
                }
            }
        } label: {
            Label(root.displayName, systemImage: "externaldrive.connected.to.line.below")
                .font(.system(size: 13, weight: .semibold))
                .help(root.path)
        }
        .onAppear { loadRootEntries(root) }
    }

    private func loadRootEntries(_ root: LogPathChooserRoot) {
        guard rootEntries[root.path] == nil, !loadingRoots.contains(root.path) else { return }
        loadingRoots.insert(root.path)
        rootErrors[root.path] = nil
        Task.detached(priority: .userInitiated) {
            do {
                let entries = try root.repository.listDir(relative: "")
                await MainActor.run {
                    rootEntries[root.path] = entries
                    loadingRoots.remove(root.path)
                }
            } catch {
                await MainActor.run {
                    rootErrors[root.path] = "\(error)"
                    loadingRoots.remove(root.path)
                }
            }
        }
    }
}

private struct LogPathTreeNodeView: View {
    let repository: Repository
    let rootPath: String
    let entry: DirEntry
    let depth: Int
    @Binding var selections: Set<LogPathFilterSelection>

    @State private var children: [DirEntry] = []
    @State private var expanded = false
    @State private var loaded = false
    @State private var loading = false
    @State private var error: String?

    private var selection: LogPathFilterSelection {
        LogPathFilterSelection(rootPath: rootPath, path: entry.path)
    }

    private var selectionState: LogPathSelectionState {
        logPathTreeSelectionState(selection, in: selections)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if entry.isDir {
                    Button {
                        expanded.toggle()
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.bold))
                            .frame(width: 14)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 14, height: 14)
                }
                Toggle(
                    "",
                    isOn: Binding(
                        get: { selectionState != .clear },
                        set: { _ in
                            selections = logPathTreeSelectionsAfterToggle(
                                selection,
                                in: selections
                            )
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(selectionState == .selectedAbove)
                .help(selectionState == .selectedAbove
                    ? "A parent path is already selected"
                    : "Select this path")
                Image(systemName: entry.isDir ? (expanded ? "folder.fill" : "folder") : "doc")
                    .foregroundStyle(entry.isDir ? Design.Colors.accent : .secondary)
                Text(entry.name)
                    .font(Design.Typography.codeSmall)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 18)
            .padding(.vertical, 3)

            if entry.isDir && expanded {
                if let error, !loaded {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding(.leading, CGFloat(depth + 1) * 18 + 22)
                } else if loading && !loaded {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, CGFloat(depth + 1) * 18 + 22)
                } else {
                    ForEach(children, id: \.path) { child in
                        LogPathTreeNodeView(
                            repository: repository,
                            rootPath: rootPath,
                            entry: child,
                            depth: depth + 1,
                            selections: $selections
                        )
                    }
                }
            }
        }
        .onChange(of: expanded) { _, isExpanded in
            if isExpanded && !loaded {
                loadChildren()
            }
        }
    }

    private func loadChildren() {
        guard !loading else { return }
        loading = true
        error = nil
        Task.detached(priority: .userInitiated) {
            do {
                let entries = try repository.listDir(relative: entry.path)
                await MainActor.run {
                    children = entries
                    loaded = true
                    loading = false
                }
            } catch {
                await MainActor.run {
                    self.error = "\(error)"
                    loading = false
                }
            }
        }
    }
}

private struct LogPathsEditorView: View {
    @Binding var text: String
    let onCancel: () -> Void
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Paths")
                .font(.headline)
            Text("Enter one path per line")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Design.Colors.surface, in: RoundedRectangle(cornerRadius: 8))
                .frame(minHeight: 190)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Apply", action: onApply)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 520, height: 320)
    }
}


}
