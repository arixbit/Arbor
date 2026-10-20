import SwiftUI
import AppKit


/// IntelliJ keeps committed-revision comparison separate from a revision
/// versus working-tree diff, even though both are launched from branch UI.
func branchComparisonLogViewMode(workingTreeDiff: Bool) -> LogViewMode {
    workingTreeDiff ? .compare : .compareBranches
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

/// A read-only file comparison keeps the owning Git root and the requested
/// engine mode together. This prevents a nested project-tree file from being
/// rendered through the primary repository after the async root lookup.
struct FileTreeDiffRequest: Identifiable {
    let repo: Repository
    let entry: FileEntry
    let initialMode: DiffMode

    var id: String { "\(repo.workdir() ?? ""):\(entry.path):\(initialMode)" }
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

    func isOldSelected(_ hindex: Int, _ row: DiffRow) -> Bool {
        guard let old = row.old, old.kind == .deletion, old.oldLine > 0 else { return false }
        return selectedLines.contains(SelectedDiffLine(hunkIndex: hindex, oldLine: old.oldLine))
    }

    func pairRows(_ hunk: DiffHunk) -> [DiffRow] {
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
    var oldCell: some View {
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

    func oldBackground(isDeletion: Bool) -> Color {
        if selectionMode && isDeletion && isOldSelected {
            return Design.Colors.accent.opacity(0.25)
        }
        return isDeletion ? Design.Colors.deletion : .clear
    }

    @ViewBuilder
    var newCell: some View {
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

    var isNewSelected: Bool {
        guard let line = row.new, line.kind == .addition, line.newLine > 0 else { return false }
        return selectedLines.contains(SelectedDiffLine(hunkIndex: hunkIndex, oldLine: 0, newLine: line.newLine))
    }

    func newBackground(isAddition: Bool) -> Color {
        if selectionMode && isAddition && isNewSelected {
            return Design.Colors.accent.opacity(0.25)
        }
        return isAddition ? Design.Colors.addition : .clear
    }

    /// 语法高亮（前景色）+ word-level spans（背景色）；字节偏移转 String.Index。
    func highlightedText(_ line: DiffLine?) -> AttributedString {
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
