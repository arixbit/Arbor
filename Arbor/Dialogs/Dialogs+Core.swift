import SwiftUI
import AppKit
import UniformTypeIdentifiers

import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
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
