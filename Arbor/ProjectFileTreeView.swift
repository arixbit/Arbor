import SwiftUI

/// The file tree must reload when the selected Git root changes, even when
/// two repositories have the same display name.  Use the canonical worktree
/// path as the identity instead of a presentation-only label.
func projectFileTreeRepositoryIdentity(workdir: String?) -> String? {
    guard let workdir, !workdir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }
    return URL(fileURLWithPath: workdir)
        .resolvingSymlinksInPath()
        .standardizedFileURL
        .path
}

/// File-tree entries are repository-relative already.  Keep the clipboard
/// boundary fail-closed so an accidental absolute or parent-traversal path
/// cannot be presented as if it were relative to the selected Git root.
func normalizedRepositoryRelativePath(_ path: String) -> String? {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          !trimmed.hasPrefix("/"),
          !trimmed.contains("\0") else {
        return nil
    }
    let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
    guard !components.isEmpty,
          components.allSatisfy({ $0 != "." && $0 != ".." }) else {
        return nil
    }
    return components.joined(separator: "/")
}

/// `Show File History` is a file action in IntelliJ's Git file-action group;
/// directories keep the separate directory comparison action.  Normalize at
/// this boundary so a context-menu callback can never open history for an
/// absolute or parent-traversing path.
func projectFileTreeHistoryPath(_ path: String, isDirectory: Bool) -> String? {
    guard !isDirectory else { return nil }
    return normalizedRepositoryRelativePath(path)
}

/// `Annotate` needs a worktree file that Git can blame. Clean files do not
/// appear in the status list, so an absent entry is intentionally allowed;
/// known untracked/deleted/ignored/conflicted entries stay disabled.
func projectFileTreeCanAnnotate(path: String, entries: [FileEntry]) -> Bool {
    let matching = entries.filter { $0.path == path }
    guard !matching.isEmpty else { return true }
    for entry in matching {
        let kinds = [entry.staged, entry.unstaged]
        if kinds.contains(where: {
            $0 == .untracked
                || $0 == .deleted
                || $0 == .ignored
                || $0 == .conflicted
        }) {
            return false
        }
    }
    return true
}

/// `Compare.SameVersion` compares a tracked worktree file with its current
/// repository version. Files without a usable HEAD side keep the action
/// disabled; clean tracked files are absent from `status()` and are allowed.
func projectFileTreeCanCompareWithSameVersion(path: String, entries: [FileEntry]) -> Bool {
    let matching = entries.filter { $0.path == path }
    guard !matching.isEmpty else { return true }
    for entry in matching {
        let kinds = [entry.staged, entry.unstaged]
        if kinds.contains(where: {
            $0 == .untracked
                || $0 == .ignored
                || $0 == .conflicted
        }) {
            return false
        }
    }
    return true
}

/// `Show.Current.Revision` needs a committed revision for a worktree file;
/// untracked, ignored, and conflicted paths do not have a stable current
/// revision to describe.  Clean tracked files are absent from `status()` and
/// remain eligible.
func projectFileTreeCanShowCurrentRevision(path: String, entries: [FileEntry]) -> Bool {
    let matching = entries.filter { $0.path == path }
    guard !matching.isEmpty else { return true }
    for entry in matching {
        let kinds = [entry.staged, entry.unstaged]
        if kinds.contains(where: {
            $0 == .untracked
                || $0 == .ignored
                || $0 == .conflicted
        }) {
            return false
        }
    }
    return true
}

/// `Compare.Selected` needs a committed history side.  Untracked, ignored and
/// conflicted paths have no stable historical revision to offer; deleted
/// tracked paths remain valid because their history is still queryable.
func projectFileTreeCanCompareWithSelectedRevision(
    path: String,
    isDirectory: Bool,
    entries: [FileEntry]
) -> Bool {
    let prefix = path.hasSuffix("/") ? path : "\(path)/"
    let matching = entries.filter {
        $0.path == path || (isDirectory && $0.path.hasPrefix(prefix))
    }
    guard !matching.isEmpty else { return true }
    for entry in matching {
        let kinds = [entry.staged, entry.unstaged]
        if kinds.contains(where: {
            $0 == .untracked || $0 == .ignored || $0 == .conflicted
        }) {
            return false
        }
    }
    return true
}

/// File-level mutations in IntelliJ's Git context menu are status-scoped.
/// Keep the project tree fail-closed when the status snapshot has no matching
/// file or when the selected path is a directory whose recursive semantics
/// have not been verified by the engine.
func projectFileTreeCanCheckin(
    path: String,
    isDirectory: Bool,
    entries: [FileEntry]
) -> Bool {
    guard !isDirectory else { return false }
    let matching = entries.filter { $0.path == path }
    guard !matching.isEmpty else { return false }
    return matching.contains { entry in
        let kinds = [entry.staged, entry.unstaged]
        return kinds.contains {
            $0 != .unchanged && $0 != .ignored
        } && !kinds.contains(.conflicted)
    }
}

/// `Git.Add` is deliberately file-only here. Calling `git add <directory>`
/// would also stage tracked modifications under that directory, while
/// IntelliJ's Schedule-for-Addition action targets unversioned files.
func projectFileTreeCanAdd(
    path: String,
    isDirectory: Bool,
    entries: [FileEntry]
) -> Bool {
    guard !isDirectory else { return false }
    let matching = entries.filter { $0.path == path }
    return matching.contains { entry in
        entry.unstaged == .untracked
            && entry.staged != .conflicted
            && entry.unstaged != .conflicted
            && entry.staged != .ignored
            && entry.unstaged != .ignored
    }
}

/// `ChangesView.Revert` restores a tracked file from HEAD. Added, renamed,
/// copied, untracked, ignored, and conflicted entries are excluded because a
/// plain path restore cannot prove that the selected worktree path exists in
/// HEAD or preserve the operation-specific conflict state.
func projectFileTreeCanRevert(
    path: String,
    isDirectory: Bool,
    entries: [FileEntry]
) -> Bool {
    guard !isDirectory else { return false }
    let matching = entries.filter { $0.path == path }
    guard !matching.isEmpty else { return false }
    return matching.contains { entry in
        let kinds = [entry.staged, entry.unstaged]
        guard !kinds.contains(where: {
            $0 == .added
                || $0 == .renamed
                || $0 == .copied
                || $0 == .untracked
                || $0 == .ignored
                || $0 == .conflicted
        }) else { return false }
        return kinds.contains {
            $0 == .modified || $0 == .deleted || $0 == .typeChanged
        }
    }
}

func projectFileTreeFirstConflictedPath(
    path: String,
    isDirectory: Bool,
    entries: [FileEntry]
) -> String? {
    guard !isDirectory else { return nil }
    return entries.first {
        $0.path == path && ($0.staged == .conflicted || $0.unstaged == .conflicted)
    }?.path
}

func projectFileTreeCanRevertResolved(
    path: String,
    isDirectory: Bool,
    resolvedConflictPaths: [String]
) -> Bool {
    !isDirectory && resolvedConflictPaths.contains(path)
}

func resolvedFileHistoryRootPath(
    preferredRootPath: String?,
    selectedCommitRootPath: String?,
    activeLogRootPath: String?,
    repositoryRootPath: String?
) -> String? {
    preferredRootPath ?? selectedCommitRootPath ?? activeLogRootPath ?? repositoryRootPath
}

/// 项目文件树：每个目录只在第一次展开时调用一次 listDir。
struct ProjectFileTreeView: View {
    let repo: Repository?
    let entries: [FileEntry]
    @Binding var selection: String?
    var onCopyPath: (String) -> Void = { _ in }
    var onCompareWithReference: (String, Bool) -> Void = { _, _ in }
    var onCompareWithSameVersion: (String) -> Void = { _ in }
    var onCompareWithSelectedRevision: (String, Bool) -> Void = { _, _ in }
    var onShowFileHistory: (String) -> Void = { _ in }
    var onShowCurrentRevision: (String) -> Void = { _ in }
    var onAnnotate: (String) -> Void = { _ in }
    var onCheckin: (String) -> Void = { _ in }
    var onAdd: (String) -> Void = { _ in }
    var onRevert: (String) -> Void = { _ in }
    var onResolveConflicts: (String) -> Void = { _ in }
    var resolvedConflictPaths: [String] = []
    var onRevertResolved: (String) -> Void = { _ in }
    @State private var rootEntries: [DirEntry] = []
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        Group {
            if let repo {
                if loading && rootEntries.isEmpty {
                    ProgressView("读取项目目录…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error, rootEntries.isEmpty {
                    VStack(spacing: Design.Spacing.sm) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("重试") { loadRoot(repo) }
                    }
                    .padding(Design.Spacing.lg)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selection) {
                        Section("项目文件") {
                            ForEach(rootEntries, id: \.path) { entry in
                                FileTreeNodeView(
                                    repo: repo,
                                    entry: entry,
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
                                    onResolveConflicts: onResolveConflicts,
                                    resolvedConflictPaths: resolvedConflictPaths,
                                    onRevertResolved: onRevertResolved
                                )
                            }
                        }
                    }
                    .listStyle(.sidebar)
                }
            } else {
                Text("打开项目后显示文件树")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if let repo, rootEntries.isEmpty { loadRoot(repo) }
        }
        .onChange(of: projectFileTreeRepositoryIdentity(workdir: repo?.workdir())) { _, _ in
            rootEntries = []
            if let repo { loadRoot(repo) }
        }
    }

    private func loadRoot(_ repo: Repository) {
        guard !loading else { return }
        loading = true
        error = nil
        Task.detached(priority: .userInitiated) {
            do {
                let entries = try repo.listDir(relative: "")
                await MainActor.run {
                    rootEntries = entries
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

private struct FileTreeNodeView: View {
    let repo: Repository
    let entry: DirEntry
    let entries: [FileEntry]
    @Binding var selection: String?
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
    let onResolveConflicts: (String) -> Void
    let resolvedConflictPaths: [String]
    let onRevertResolved: (String) -> Void
    @State private var children: [DirEntry] = []
    @State private var expanded = false
    @State private var loaded = false
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        if entry.isDir {
            DisclosureGroup(isExpanded: $expanded) {
                if loading && !loaded {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, Design.Spacing.md)
                } else if let error, !loaded {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding(.leading, Design.Spacing.md)
                } else {
                    ForEach(children, id: \.path) { child in
                        FileTreeNodeView(
                            repo: repo,
                            entry: child,
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
                            onResolveConflicts: onResolveConflicts,
                            resolvedConflictPaths: resolvedConflictPaths,
                            onRevertResolved: onRevertResolved
                        )
                    }
                }
            } label: {
                treeLabel(systemImage: expanded ? "folder.fill" : "folder", name: entry.name, isDirectory: true)
            }
            .onChange(of: expanded) { _, isExpanded in
                if isExpanded && !loaded { loadChildren() }
            }
        } else {
            Button {
                selection = entry.path
            } label: {
                treeLabel(systemImage: fileSymbol(for: entry.name), name: entry.name, isDirectory: false)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(selection == entry.path ? Design.Colors.selection : .clear)
        }
    }

    private func treeLabel(systemImage: String, name: String, isDirectory: Bool) -> some View {
        let kind = statusKind
        return HStack(spacing: Design.Spacing.sm) {
            Image(systemName: systemImage)
                .foregroundStyle(isDirectory ? Design.Colors.accent : (statusColor(kind) ?? Design.Colors.secondary))
                .frame(width: 16)
            Text(name)
                .font(Design.Typography.codeSmall)
                .foregroundStyle(statusColor(kind) ?? .primary)
                .opacity(name.hasPrefix(".") ? 0.62 : 1)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Copy Relative Path") {
                onCopyPath(entry.path)
            }
            Divider()
            Button("Checkin Files…") {
                onCheckin(entry.path)
            }
            .disabled(!projectFileTreeCanCheckin(
                path: entry.path,
                isDirectory: isDirectory,
                entries: entries
            ))
            Button("Add") {
                onAdd(entry.path)
            }
            .disabled(!projectFileTreeCanAdd(
                path: entry.path,
                isDirectory: isDirectory,
                entries: entries
            ))
            if !isDirectory {
                Button("Compare with Branch or Tag…") {
                    onCompareWithReference(entry.path, false)
                }
                if let comparePath = projectFileTreeHistoryPath(
                    entry.path,
                    isDirectory: isDirectory
                ) {
                    Button("Compare with HEAD") {
                        onCompareWithSameVersion(comparePath)
                    }
                    .disabled(!projectFileTreeCanCompareWithSameVersion(
                        path: comparePath,
                        entries: entries
                    ))
                }
                Button("Compare with Selected Revision…") {
                    onCompareWithSelectedRevision(entry.path, false)
                }
                .disabled(!projectFileTreeCanCompareWithSelectedRevision(
                    path: entry.path,
                    isDirectory: false,
                    entries: entries
                ))
                if let historyPath = projectFileTreeHistoryPath(
                    entry.path,
                    isDirectory: isDirectory
                ) {
                    Button("Show File History") {
                        onShowFileHistory(historyPath)
                    }
                    Button("Annotate") {
                        onAnnotate(historyPath)
                    }
                    .disabled(!projectFileTreeCanAnnotate(path: historyPath, entries: entries))
                }
                Button("Show Current Revision") {
                    onShowCurrentRevision(entry.path)
                }
                .disabled(!projectFileTreeCanShowCurrentRevision(
                    path: entry.path,
                    entries: entries
                ))
            } else {
                Button("Compare Directory with Branch or Tag…") {
                    onCompareWithReference(entry.path, true)
                }
                Button("Compare Directory with Selected Revision…") {
                    onCompareWithSelectedRevision(entry.path, true)
                }
                .disabled(!projectFileTreeCanCompareWithSelectedRevision(
                    path: entry.path,
                    isDirectory: true,
                    entries: entries
                ))
            }
            Divider()
            Button("Revert", role: .destructive) {
                onRevert(entry.path)
            }
            .disabled(!projectFileTreeCanRevert(
                path: entry.path,
                isDirectory: isDirectory,
                entries: entries
            ))
            Button("Resolve Conflicts") {
                if let conflictPath = projectFileTreeFirstConflictedPath(
                    path: entry.path,
                    isDirectory: isDirectory,
                    entries: entries
                ) {
                    onResolveConflicts(conflictPath)
                }
            }
            .disabled(projectFileTreeFirstConflictedPath(
                path: entry.path,
                isDirectory: isDirectory,
                entries: entries
            ) == nil)
            Button("Revert Resolved", role: .destructive) {
                onRevertResolved(entry.path)
            }
            .disabled(!projectFileTreeCanRevertResolved(
                path: entry.path,
                isDirectory: isDirectory,
                resolvedConflictPaths: resolvedConflictPaths
            ))
        }
    }

    private var statusKind: ChangeKind? {
        let prefix = entry.isDir ? "\(entry.path)/" : entry.path
        let matching = entries.filter { $0.path == entry.path || $0.path.hasPrefix(prefix) }
        let kinds = matching.flatMap { [$0.staged, $0.unstaged] }
        return kinds.first(where: { $0 == .conflicted })
            ?? kinds.first(where: { $0 != .unchanged && $0 != .ignored })
    }

    private func statusColor(_ kind: ChangeKind?) -> Color? {
        switch kind {
        case .added, .untracked:
            return Design.Colors.success
        case .modified, .typeChanged:
            return Design.Colors.info
        case .deleted:
            return Design.Colors.error
        case .renamed, .copied:
            return Design.Colors.keyword
        case .conflicted:
            return .red
        default:
            return nil
        }
    }

    private func loadChildren() {
        guard !loading else { return }
        loading = true
        error = nil
        Task.detached(priority: .userInitiated) {
            do {
                let entries = try repo.listDir(relative: entry.path)
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

    private func fileSymbol(for name: String) -> String {
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "swift", "rs", "py", "js", "ts", "tsx", "jsx", "c", "h", "cpp", "cc", "java", "go":
            return "doc.text"
        case "json", "yaml", "yml", "toml", "xml":
            return "curlybraces"
        case "md", "txt", "rst":
            return "doc.plaintext"
        case "png", "jpg", "jpeg", "gif", "webp":
            return "photo"
        default:
            return "doc"
        }
    }
}

struct ProjectEmptyStateView: View {
    let recentPaths: [String]
    let onOpen: () -> Void
    let onInit: () -> Void
    let onClone: () -> Void
    let onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: Design.Spacing.lg) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Design.Colors.accent)
            VStack(spacing: Design.Spacing.xs) {
                Text("打开一个项目")
                    .font(.title2.weight(.semibold))
                Text("Arbor 每个窗口只显示一个项目")
                    .foregroundStyle(.secondary)
            }
            Button("选择项目文件夹…", action: onOpen)
                .buttonStyle(.borderedProminent)
            HStack(spacing: 10) {
                Button("初始化 Git 仓库…", action: onInit)
                Button("克隆 Git 仓库…", action: onClone)
            }
            if !recentPaths.isEmpty {
                VStack(alignment: .leading, spacing: Design.Spacing.sm) {
                    Text("最近项目")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(recentPaths.prefix(5), id: \.self) { path in
                        Button {
                            onSelect(path)
                        } label: {
                            Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "clock")
                                .frame(maxWidth: 320, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .help(path)
                    }
                }
                .padding(Design.Spacing.md)
                .background(Design.Colors.surface, in: RoundedRectangle(cornerRadius: Design.Radius.medium))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Design.Spacing.xl)
    }
}

/// A failed repository open must not silently fall back to the welcome pane.
/// The previous behavior made a broken log launch look like an empty project,
/// so users had no actionable explanation or retry path.
struct ProjectLoadErrorView: View {
    let message: String
    let onRetry: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: Design.Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.orange)
            Text("无法打开 Git 项目")
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 620)
            HStack(spacing: 10) {
                Button("重试", action: onRetry)
                    .buttonStyle(.borderedProminent)
                Button("选择其他项目…", action: onOpen)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Design.Spacing.xl)
    }
}

/// Read-only metadata popup for IntelliJ's `Show.Current.Revision` action.
/// It describes the last committed revision that owns the selected path; it
/// does not open a diff or change the worktree.
struct CurrentRevisionView: View {
    let path: String
    let commit: CommitInfo
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.md) {
            HStack(spacing: Design.Spacing.sm) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(Design.Colors.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Current Revision")
                        .font(.headline)
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Close", action: onClose)
            }

            Divider()

            VStack(alignment: .leading, spacing: Design.Spacing.sm) {
                revisionInfoRow("Revision", commit.id)
                revisionInfoRow("Author", "\(commit.authorName) <\(commit.authorEmail)>")
                revisionInfoRow("Date", dateStr(commit.time))
            }

            Divider()

            Text(commit.summary)
                .font(.headline)
                .textSelection(.enabled)
            if !commit.messageBody.isEmpty {
                ScrollView {
                    Text(commit.messageBody)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 180)
            }

            Spacer(minLength: 0)
        }
        .padding(Design.Spacing.lg)
        .frame(minWidth: 560, minHeight: 340)
    }

    private func revisionInfoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: Design.Spacing.sm) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}
