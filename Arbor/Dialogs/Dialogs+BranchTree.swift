import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

func toggledBranchFavoriteIDs(
    _ selection: [BranchDashboardReference],
    current: Set<String>
) -> Set<String> {
    var updated = current
    for reference in selection {
        if updated.contains(reference.favoriteID) {
            updated.remove(reference.favoriteID)
        } else {
            updated.insert(reference.favoriteID)
        }
    }
    return updated
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
func branchDirectoryRefName(_ row: BranchDirectoryRow) -> String? {
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
/// 分支弹窗右下角的拖拽手柄。尺寸在松手时写回项目级设置，等价于 IntelliJ
/// 分支弹窗的 resize；齿轮菜单里的 `Restore Default Size` 恢复默认。
struct BranchesPopupResizeHandle: View {
    @Binding var size: CGSize
    let minimum: CGSize
    let maximum: CGSize
    let onCommit: (CGSize) -> Void

    @State private var dragStart: CGSize?

    var body: some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.tertiary)
            .padding(5)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = dragStart ?? size
                        if dragStart == nil { dragStart = base }
                        size = CGSize(
                            width: min(max(base.width + value.translation.width, minimum.width), maximum.width),
                            height: min(max(base.height + value.translation.height, minimum.height), maximum.height)
                        )
                    }
                    .onEnded { _ in
                        dragStart = nil
                        onCommit(size)
                    }
            )
            .help("Drag to resize the popup")
    }
}
