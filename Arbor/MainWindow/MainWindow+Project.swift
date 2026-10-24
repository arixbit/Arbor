import SwiftUI
import AppKit


/// Aggregate facts from the Find Merged report. Keeping this separate from
/// branch rows prevents a failed root from looking like a successful empty
/// result.
struct FindMergedScanSummary: Equatable {
    let targetBranch: String
    let prefix: String
    let repositoriesDiscovered: Int
    let repositoriesScanned: Int
    let candidateBranchesChecked: Int
    let mergedBranchesFound: Int
    let errors: [String]
    let elapsedMilliseconds: Int64
    let isCancelled: Bool

    var errorsCount: Int { errors.count }
}

/// A Changes Browser row must carry its owning Git root. The same relative
/// path is a different file when two nested repositories both contain, for
/// example, `README.md`.
struct MultiRootChangeSelection: Hashable, Sendable {
    let rootPath: String
    let path: String
    let oldPath: String?

    init(rootPath: String, path: String, oldPath: String? = nil) {
        self.rootPath = rootPath
        self.path = path
        self.oldPath = oldPath
    }

    var id: String { "\(rootPath)\u{1f}\(path)" }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rootPath == rhs.rootPath && lhs.path == rhs.path
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(rootPath)
        hasher.combine(path)
    }
}

struct MultiRootChangeGroup: Identifiable {
    let rootPath: String
    let displayName: String
    let relativePath: String
    let repository: Repository
    let entries: [FileEntry]

    var id: String { rootPath }

    var changedEntries: [FileEntry] {
        entries.filter {
            $0.staged != .unchanged
                || ($0.unstaged != .unchanged && $0.unstaged != .ignored)
        }
    }
}

struct StatusBadge: View {
    let kind: ChangeKind
    var body: some View {
        Text(ChangeBadge.label(kind))
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(kind == .unchanged ? .clear : .white)
            .frame(width: 16, height: 16)
            .background(ChangeBadge.color(kind), in: RoundedRectangle(cornerRadius: 3))
    }
}

#Preview {
    ContentView()
}

/// 常驻左栏：项目身份 + 轻量状态徽标 + 懒加载文件树。
/// 变更详情不再占据左栏，点击文件只负责把主区路由到 FileContentView。
struct ProjectTreePane: View {
    let repo: Repository?
    let projectPath: String?
    let entries: [FileEntry]
    @Binding var selection: String?
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onCopyPath: (String) -> Void
    let onCompareWithReference: (String, Bool) -> Void
    let onCompareWithSameVersion: (String) -> Void
    let onCompareWithSelectedRevision: (String, Bool) -> Void
    let onShowFileHistory: (String) -> Void
    let onShowCurrentRevision: (String) -> Void
    let onAnnotate: (String) -> Void
    let onCheckin: (String) -> Void
    let onAdd: (String) -> Void
    let onRevert: (String) -> Void
    /// IntelliJ `$Delete`：从磁盘删除该路径（不跑 `git rm`）。
    let onDelete: (String) -> Void
    let onResolveConflicts: (String) -> Void
    let resolvedConflictPaths: [String]
    let onRevertResolved: (String) -> Void
    let showHeader: Bool

    init(
        repo: Repository?,
        projectPath: String?,
        entries: [FileEntry],
        selection: Binding<String?>,
        onOpen: @escaping () -> Void,
        onReveal: @escaping () -> Void,
        onCopyPath: @escaping (String) -> Void,
        onCompareWithReference: @escaping (String, Bool) -> Void = { _, _ in },
        onCompareWithSameVersion: @escaping (String) -> Void = { _ in },
        onCompareWithSelectedRevision: @escaping (String, Bool) -> Void = { _, _ in },
        onShowFileHistory: @escaping (String) -> Void = { _ in },
        onShowCurrentRevision: @escaping (String) -> Void = { _ in },
        onAnnotate: @escaping (String) -> Void = { _ in },
        onCheckin: @escaping (String) -> Void = { _ in },
        onAdd: @escaping (String) -> Void = { _ in },
        onRevert: @escaping (String) -> Void = { _ in },
        onDelete: @escaping (String) -> Void = { _ in },
        onResolveConflicts: @escaping (String) -> Void = { _ in },
        resolvedConflictPaths: [String] = [],
        onRevertResolved: @escaping (String) -> Void = { _ in },
        showHeader: Bool = true
    ) {
        self.repo = repo
        self.projectPath = projectPath
        self.entries = entries
        self._selection = selection
        self.onOpen = onOpen
        self.onReveal = onReveal
        self.onCopyPath = onCopyPath
        self.onCompareWithReference = onCompareWithReference
        self.onCompareWithSameVersion = onCompareWithSameVersion
        self.onCompareWithSelectedRevision = onCompareWithSelectedRevision
        self.onShowFileHistory = onShowFileHistory
        self.onShowCurrentRevision = onShowCurrentRevision
        self.onAnnotate = onAnnotate
        self.onCheckin = onCheckin
        self.onAdd = onAdd
        self.onRevert = onRevert
        self.onDelete = onDelete
        self.onResolveConflicts = onResolveConflicts
        self.resolvedConflictPaths = resolvedConflictPaths
        self.onRevertResolved = onRevertResolved
        self.showHeader = showHeader
    }

    var body: some View {
        VStack(spacing: 0) {
            if showHeader {
                HStack(spacing: Design.Spacing.sm) {
                    Image(systemName: "square.stack.3d.up")
                        .foregroundStyle(Design.Colors.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repo?.displayName() ?? "未打开项目")
                            .font(.headline)
                            .lineLimit(1)
                        if let projectPath {
                            Text(projectPath)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer()
                    Button(action: onOpen) {
                        Image(systemName: "folder.badge.plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Open Project")
                    if repo != nil {
                        Button(action: onReveal) {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .buttonStyle(.borderless)
                        .help("Reveal Project Root in Finder")
                    }
                }
                .padding(.horizontal, Design.Spacing.md)
                .padding(.vertical, Design.Spacing.sm)
            }

            ProjectFileTreeView(
                repo: repo,
                entries: entries,
                selection: $selection,
                onCopyPath: onCopyPath,
                onCompareWithReference: onCompareWithReference,
                onCompareWithSameVersion: onCompareWithSameVersion,
                        onCompareWithSelectedRevision: onCompareWithSelectedRevision,
                        onShowFileHistory: onShowFileHistory,
                        onShowCurrentRevision: onShowCurrentRevision,
                        onAnnotate: onAnnotate,
                        onCheckin: onCheckin,
                        onAdd: onAdd,
                        onRevert: onRevert,
                        onDelete: onDelete,
                        onResolveConflicts: onResolveConflicts,
                        resolvedConflictPaths: resolvedConflictPaths,
                        onRevertResolved: onRevertResolved
                    )
        }
    }
}
