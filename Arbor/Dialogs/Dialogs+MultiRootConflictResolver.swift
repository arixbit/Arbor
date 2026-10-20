import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
