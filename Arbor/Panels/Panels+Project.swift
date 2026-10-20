import SwiftUI
import AppKit
import UniformTypeIdentifiers


/// IntelliJ's `Git.Ignore.File` action group is offered for unversioned files
/// only.  A tracked or already-staged path must not be turned into a
/// `.gitignore` rule: Git would keep tracking it and the action would present
/// a misleading success path.
func gitIgnoreActionAvailable(for entry: FileEntry) -> Bool {
    entry.unstaged == .untracked && entry.staged == .unchanged
}

/// IntelliJ offers existing `.gitignore` files from the target's directory
/// and its ancestors. Keep the result root-scoped and nearest-first so the
/// SwiftUI menu has the same candidate set as `IgnoreFileActionGroup`.
func gitIgnoreFileCandidates(for filePath: String, workdir: String) -> [String] {
    let root = URL(fileURLWithPath: workdir).standardizedFileURL
    let target = filePath.hasPrefix("/")
        ? URL(fileURLWithPath: filePath).standardizedFileURL
        : root.appendingPathComponent(filePath).standardizedFileURL
    guard target.path == root.path || target.path.hasPrefix(root.path + "/") else {
        return []
    }

    let fileManager = FileManager.default
    var isDirectory = ObjCBool(false)
    let targetIsDirectory = fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory)
        && isDirectory.boolValue
    var directory = targetIsDirectory ? target : target.deletingLastPathComponent()
    var candidates: [String] = []
    while directory.path == root.path || directory.path.hasPrefix(root.path + "/") {
        let candidate = directory.appendingPathComponent(".gitignore")
        var candidateIsDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: candidate.path, isDirectory: &candidateIsDirectory),
           !candidateIsDirectory.boolValue {
            candidates.append(candidate.path)
        }
        if directory.path == root.path { break }
        let parent = directory.deletingLastPathComponent()
        guard parent.path != directory.path else { break }
        directory = parent
    }
    return candidates
}

/// Return the ignore files suitable for every selected unversioned path with
/// existing candidates, preserving the nearest-first order of the first
/// non-empty candidate list.
func gitIgnoreFileCandidates(for filePaths: [String], workdir: String) -> [String] {
    guard !filePaths.isEmpty else { return [] }
    let candidateLists = filePaths.map {
        gitIgnoreFileCandidates(for: $0, workdir: workdir)
    }
    // IgnoreFileActionGroup drops selected paths with no existing candidate
    // before intersecting the remaining candidate sets. IgnoreFileAction then
    // filters those paths out again when writing to the selected file root.
    let nonEmptyCandidateLists = candidateLists.filter { !$0.isEmpty }
    guard let orderedCandidates = nonEmptyCandidateLists.first else { return [] }
    let candidateSets = nonEmptyCandidateLists.map(Set.init)
    return orderedCandidates.filter { candidate in
        candidateSets.allSatisfy { $0.contains(candidate) }
    }
}

/// IntelliJ asks before `CreateNewIgnoreFileAction` creates the repository
/// root `.gitignore`. Keep this decision separate from candidate discovery so
/// an existing root file never causes a redundant confirmation.
func gitIgnoreNeedsRootCreationConfirmation(
    ignoreFilePath: String?,
    workdir: String
) -> Bool {
    guard ignoreFilePath == nil else { return false }
    let root = URL(fileURLWithPath: workdir).standardizedFileURL
    let ignoreFile = root.appendingPathComponent(".gitignore")
    var isDirectory = ObjCBool(false)
    return !FileManager.default.fileExists(
        atPath: ignoreFile.path,
        isDirectory: &isDirectory
    )
}

func gitIgnoreFileDisplayName(_ path: String, workdir: String) -> String {
    let root = URL(fileURLWithPath: workdir).standardizedFileURL
    let file = URL(fileURLWithPath: path).standardizedFileURL
    return file.path == root.path || !file.path.hasPrefix(root.path + "/")
        ? file.lastPathComponent
        : String(file.path.dropFirst(root.path.count + 1))
}

func gitIgnoreRule(for targetPath: String, ignoreFile: String, workdir: String) -> String {
    let root = URL(fileURLWithPath: workdir).standardizedFileURL
    let target = targetPath.hasPrefix("/")
        ? URL(fileURLWithPath: targetPath).standardizedFileURL
        : root.appendingPathComponent(targetPath).standardizedFileURL
    let parent = URL(fileURLWithPath: ignoreFile)
        .standardizedFileURL
        .deletingLastPathComponent()
    guard target.path.hasPrefix(parent.path + "/") else { return targetPath }
    return String(target.path.dropFirst(parent.path.count + 1))
        .replacingOccurrences(of: "\\", with: "/")
}

func gitIgnoreTargetPaths(
    for targetPaths: [String],
    ignoreFile: String,
    workdir: String
) -> [String] {
    let root = URL(fileURLWithPath: workdir).standardizedFileURL
    let ignoreRoot = URL(fileURLWithPath: ignoreFile)
        .standardizedFileURL
        .deletingLastPathComponent()
    return targetPaths.filter { targetPath in
        let target = targetPath.hasPrefix("/")
            ? URL(fileURLWithPath: targetPath).standardizedFileURL
            : root.appendingPathComponent(targetPath).standardizedFileURL
        return target.path.hasPrefix(ignoreRoot.path + "/")
    }
}

struct RebasedIgnoredGroup: View {
    let entries: [FileEntry]
    let rules: [IgnoreRuleInfo]
    let onStage: (String) -> Void
    @State var isExpanded = true
    @State var pendingStagePath: String?
    @State var showStageConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                guard !entries.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: entries.isEmpty || !isExpanded ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.bold))
                    Text("Ignored Files")
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(entries.count) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            if entries.isEmpty {
                Text("No ignored files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
            } else if isExpanded {
                ForEach(entries, id: \.path) { entry in
                    HStack(spacing: 6) {
                        StatusBadge(kind: .ignored)
                        Text(entry.path)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let rule = rules.first(where: { entry.path == $0.path || entry.path.hasPrefix($0.pattern) }) {
                            Text("\(ignoreRuleSourceName(rule.source)) · \(rule.pattern)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .help("\(rule.sourcePath):\(rule.line)")
                        }
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Add to Git…") {
                            pendingStagePath = entry.path
                            showStageConfirmation = true
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Add Ignored File to Git?",
            isPresented: $showStageConfirmation,
            titleVisibility: .visible
        ) {
            if let pendingStagePath {
                Button("Add to Git") {
                    onStage(pendingStagePath)
                    self.pendingStagePath = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingStagePath = nil
            }
        } message: {
            if let pendingStagePath {
                Text("\(pendingStagePath) is ignored by Git. Adding it will explicitly track the file and commit its current contents.")
            }
        }
    }
}

func ignoreRuleSourceName(_ source: IgnoreRuleSource) -> String {
    switch source {
    case .gitignore: return ".gitignore"
    case .infoExclude: return ".git/info/exclude"
    case .global: return "global ignore"
    case .other: return "ignore rule"
    }
}

struct RebasedStatusBar: View {
    let branch: String
    let headID: String?
    let changedCount: Int
    let projectPath: String?
    let onBranch: () -> Void
    @ObservedObject var feedbackCenter: FeedbackCenter
    let syncStatus: SyncStatus?
    let hasUnfetchedIncoming: Bool
    let onOperationLog: () -> Void
    let onCancelOperation: () -> Void
    let onFeedbackDetails: (FeedbackMessage) -> Void
    @AppStorage(GitIncomingOutgoingInfoSettings.key)
    var incomingOutgoingInfoEnabled = GitIncomingOutgoingInfoSettings.defaultValue

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onBranch) {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .help("Open branches")
            if incomingOutgoingInfoEnabled, let syncStatus {
                if syncStatus.trackingExists {
                    HStack(spacing: 3) {
                        Text("↑\(syncStatus.ahead) ↓\(syncStatus.behind)")
                        if hasUnfetchedIncoming {
                            Text("↓?")
                                .foregroundStyle(.blue)
                        }
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(syncStatus.ahead > 0 || syncStatus.behind > 0 ? .orange : .secondary)
                    .help("Upstream: \(syncStatus.upstream)")
                } else {
                    Text("Missing upstream")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.orange)
                    .help("Upstream tracking branch is missing")
                }
            } else if incomingOutgoingInfoEnabled, hasUnfetchedIncoming {
                Text("↓?")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.blue)
                    .help("Remote has incoming commits not fetched locally")
            }
            Divider().frame(height: 14)
            Label("Git", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
            Button(action: onOperationLog) {
                Label("Operation Log", systemImage: "list.bullet.rectangle")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open Git tasks and operation log")
            if changedCount > 0 {
                Text("\(changedCount) changed")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let feedback = feedbackCenter.current {
                Divider().frame(height: 14)
                if feedbackCenter.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                FeedbackMessageView(
                    message: feedback,
                    isCompact: true,
                    onDetails: { onFeedbackDetails(feedback) }
                )
                .font(.caption)
                .frame(maxWidth: 480, alignment: .leading)
                if let progress = feedbackCenter.progress {
                    HStack(spacing: 5) {
                        if let percentage = progress.percentage {
                            ProgressView(value: Double(percentage), total: 100)
                                .frame(width: 72)
                            Text("\(percentage)%")
                                .monospacedDigit()
                        }
                        Text(progress.phase)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                            .help(progress.detail)
                        if !progress.rootName.isEmpty {
                            Text("· \(progress.rootName)")
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption2)
                }
                if let batchProgress = feedbackCenter.batchProgress {
                    HStack(spacing: 5) {
                        ProgressView(
                            value: Double(batchProgress.completed),
                            total: Double(max(batchProgress.total, 1))
                        )
                        .frame(width: 72)
                        if let percentage = batchProgress.percentage {
                            Text("\(percentage)%")
                                .monospacedDigit()
                        } else {
                            Text("\(batchProgress.completed)/\(batchProgress.total)")
                                .monospacedDigit()
                        }
                        Text(batchProgress.phase)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                            .help(batchProgress.detail ?? batchProgress.phase)
                    }
                    .font(.caption2)
                }
                if feedbackCenter.canCancel {
                    Button("Cancel") { onCancelOperation() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            if let permissionWarning = feedbackCenter.nativeNotificationPermissionWarning {
                Divider().frame(height: 14)
                Label(permissionWarning.title, systemImage: "bell.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(permissionWarning.detail ?? permissionWarning.title)
                if let actionTitle = permissionWarning.actionTitle,
                   let action = permissionWarning.action
                {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            Spacer()
            if let projectPath {
                Text(projectPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let headID {
                Text(String(headID.prefix(7)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Design.Colors.chrome)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }
}

/// An aggregate Changes Browser for projects containing nested Git roots.
/// Every staging mutation remains explicitly tied to the row's owning root;
/// the project-level view never falls back to the primary Repository.
struct MultiRootChangesBrowser: View {
    let groups: [MultiRootChangeGroup]
    let isLoading: Bool
    let error: String?
    let onRefresh: () -> Void
    let onStage: (String, String) -> Void
    let onUnstage: (String, String) -> Void
    let onStageSelected: ([MultiRootChangeSelection]) -> Void
    let onUnstageSelected: ([MultiRootChangeSelection]) -> Void
    let onCommitSelected: ([MultiRootChangeSelection]) -> Void
    let onStageAll: (String) -> Void
    let onUnstageAll: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State var detailSelection: MultiRootChangeSelection?
    @State var selectedRows = Set<MultiRootChangeSelection>()
    @State var refreshToken = 0

    var changedFileCount: Int {
        groups.reduce(0) { $0 + $1.changedEntries.count }
    }

    var selectedStageableRows: [MultiRootChangeSelection] {
        orderedSelections(selectedRows).filter { selection in
            guard let entry = entry(for: selection) else { return false }
            return canStage(entry)
        }
    }

    var selectedUnstageableRows: [MultiRootChangeSelection] {
        orderedSelections(selectedRows).filter { selection in
            guard let entry = entry(for: selection) else { return false }
            return canUnstage(entry)
        }
    }

    var selectedCommittableRows: [MultiRootChangeSelection] {
        orderedSelections(selectedRows).filter { selection in
            guard let entry = entry(for: selection) else { return false }
            return entry.staged != .unchanged
                && entry.staged != .ignored
                && entry.staged != .conflicted
                && entry.unstaged != .conflicted
        }
    }

    var selectedGroup: MultiRootChangeGroup? {
        guard let detailSelection else { return nil }
        return groups.first { $0.rootPath == detailSelection.rootPath }
    }

    var selectedEntry: FileEntry? {
        guard let detailSelection, let selectedGroup else { return nil }
        return selectedGroup.entries.first { $0.path == detailSelection.path }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(Design.Colors.accent)
                Text("Changes · All Git Roots")
                    .font(.headline)
                Text("\(groups.count) roots · \(changedFileCount) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !selectedRows.isEmpty {
                    Menu {
                        Button("Stage Selected (\(selectedStageableRows.count))") {
                            onStageSelected(selectedStageableRows)
                        }
                        .disabled(selectedStageableRows.isEmpty)
                        Button("Unstage Selected (\(selectedUnstageableRows.count))") {
                            onUnstageSelected(selectedUnstageableRows)
                        }
                        .disabled(selectedUnstageableRows.isEmpty)
                        Divider()
                        Button("Commit Selected (\(selectedCommittableRows.count))") {
                            onCommitSelected(selectedCommittableRows)
                        }
                        .disabled(selectedCommittableRows.isEmpty)
                    } label: {
                        Label("Selected", systemImage: "checklist")
                    }
                    .help("Stage or unstage the selected files across Git roots")
                }
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Refresh", action: onRefresh)
                    .disabled(isLoading)
                Button("Done", role: .cancel) { dismiss() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if let error, !error.isEmpty, !groups.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }

            if let error, !error.isEmpty, groups.isEmpty {
                ContentUnavailableView(
                    "Loading Changes Failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if isLoading && groups.isEmpty {
                ProgressView("Loading changes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.allSatisfy({ $0.changedEntries.isEmpty }) {
                ContentUnavailableView(
                    "No Changes",
                    systemImage: "checkmark.circle",
                    description: Text("All Git roots are clean.")
                )
            } else {
                NavigationSplitView {
                    List(selection: $selectedRows) {
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.changedEntries, id: \.path) { entry in
                                    let row = MultiRootChangeSelection(
                                        rootPath: group.rootPath,
                                        path: entry.path,
                                        oldPath: entry.oldPath
                                    )
                                    HStack(spacing: 8) {
                                        Image(systemName: icon(for: entry))
                                            .foregroundStyle(color(for: entry))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.path)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Text(statusText(for: entry))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 4)
                                        Menu {
                                            if canStage(entry) {
                                                Button("Stage") {
                                                    onStage(group.rootPath, entry.path)
                                                }
                                            }
                                            if canUnstage(entry) {
                                                Button("Unstage") {
                                                    onUnstage(group.rootPath, entry.path)
                                                }
                                            }
                                        } label: {
                                            Image(systemName: "ellipsis.circle")
                                        }
                                        .menuStyle(.borderlessButton)
                                        .help("Stage or unstage this file")
                                        .disabled(!canStage(entry) && !canUnstage(entry))
                                    }
                                    .contextMenu {
                                        if canStage(entry) {
                                            Button("Stage") {
                                                onStage(group.rootPath, entry.path)
                                            }
                                        }
                                        if canUnstage(entry) {
                                            Button("Unstage") {
                                                onUnstage(group.rootPath, entry.path)
                                            }
                                        }
                                    }
                                    .tag(row)
                                }
                            } header: {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(group.displayName)
                                            .font(.system(size: 13, weight: .semibold))
                                        Text(group.relativePath)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 4)
                                    Menu {
                                        Button("Stage All") {
                                            onStageAll(group.rootPath)
                                        }
                                        .disabled(!hasUnstagedChanges(in: group))
                                        Button("Unstage All") {
                                            onUnstageAll(group.rootPath)
                                        }
                                        .disabled(!hasStagedChanges(in: group))
                                    } label: {
                                        Image(systemName: "ellipsis.circle")
                                    }
                                    .menuStyle(.borderlessButton)
                                    .help("Stage or unstage all changes in this Git root")
                                }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: 300)
                } detail: {
                    if let selectedGroup, let selectedEntry {
                        DiffDetailView(
                            repo: selectedGroup.repository,
                            entry: selectedEntry,
                            onChanged: {
                                refreshToken &+= 1
                                onRefresh()
                            },
                            selectionModePath: nil,
                            refreshToken: refreshToken
                        )
                    } else {
                        ContentUnavailableView(
                            "Select a Change",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text("Select a file to inspect its root-scoped diff.")
                        )
                    }
                }
            }
        }
        .frame(minWidth: 1050, minHeight: 680)
        .onAppear {
            selectFirstChangeIfNeeded()
        }
        .onChange(of: groups.map(\.id)) { _, _ in
            selectFirstChangeIfNeeded()
        }
        .onChange(of: groups.map { group in
            "\(group.rootPath)\u{1f}\(group.changedEntries.map(\.path).joined(separator: "\u{1f}"))"
        }) { _, _ in
            selectFirstChangeIfNeeded()
        }
        .onChange(of: selectedRows) { _, newSelection in
            guard !newSelection.isEmpty else {
                detailSelection = nil
                return
            }
            if let detailSelection, newSelection.contains(detailSelection) { return }
            detailSelection = orderedSelections(newSelection).first
        }
    }

    func selectFirstChangeIfNeeded() {
        let validSelections = Set(groups.flatMap { group in
            group.changedEntries.map {
                MultiRootChangeSelection(rootPath: group.rootPath, path: $0.path)
            }
        })
        selectedRows = selectedRows.intersection(validSelections)
        if let detailSelection, validSelections.contains(detailSelection) {
            if !selectedRows.contains(detailSelection) {
                selectedRows.insert(detailSelection)
            }
            return
        }
        detailSelection = nil
        guard let group = groups.first(where: { !$0.changedEntries.isEmpty }),
              let entry = group.changedEntries.first else { return }
        let firstSelection = MultiRootChangeSelection(rootPath: group.rootPath, path: entry.path)
        detailSelection = firstSelection
        selectedRows = [firstSelection]
    }

    func orderedSelections(
        _ selections: Set<MultiRootChangeSelection>
    ) -> [MultiRootChangeSelection] {
        selections.sorted {
            if $0.rootPath == $1.rootPath { return $0.path < $1.path }
            return $0.rootPath < $1.rootPath
        }
    }

    func entry(for selection: MultiRootChangeSelection) -> FileEntry? {
        groups.first { $0.rootPath == selection.rootPath }?.entries.first {
            $0.path == selection.path
        }
    }

    func icon(for entry: FileEntry) -> String {
        if entry.staged == .conflicted || entry.unstaged == .conflicted {
            return "exclamationmark.triangle.fill"
        }
        if entry.staged == .added || entry.unstaged == .added || entry.unstaged == .untracked {
            return "plus"
        }
        if entry.staged == .deleted || entry.unstaged == .deleted {
            return "minus"
        }
        if entry.staged == .renamed || entry.unstaged == .renamed {
            return "arrow.right"
        }
        return "pencil"
    }

    func color(for entry: FileEntry) -> Color {
        if entry.staged == .conflicted || entry.unstaged == .conflicted { return .orange }
        if entry.staged == .added || entry.unstaged == .added || entry.unstaged == .untracked { return .green }
        if entry.staged == .deleted || entry.unstaged == .deleted { return .red }
        return .secondary
    }

    func statusText(for entry: FileEntry) -> String {
        var labels: [String] = []
        if entry.staged != .unchanged { labels.append("staged: \(kindText(entry.staged))") }
        if entry.unstaged != .unchanged { labels.append("local: \(kindText(entry.unstaged))") }
        return labels.joined(separator: " · ")
    }

    func kindText(_ kind: ChangeKind) -> String {
        switch kind {
        case .unchanged: return "unchanged"
        case .added: return "added"
        case .modified: return "modified"
        case .deleted: return "deleted"
        case .renamed: return "renamed"
        case .copied: return "copied"
        case .typeChanged: return "type changed"
        case .untracked: return "untracked"
        case .ignored: return "ignored"
        case .conflicted: return "conflicted"
        }
    }

    func canStage(_ entry: FileEntry) -> Bool {
        entry.unstaged != .unchanged
            && entry.unstaged != .ignored
            && entry.unstaged != .conflicted
            && entry.staged != .conflicted
    }

    func canUnstage(_ entry: FileEntry) -> Bool {
        entry.staged != .unchanged
            && entry.staged != .conflicted
            && entry.unstaged != .conflicted
    }

    func hasUnstagedChanges(in group: MultiRootChangeGroup) -> Bool {
        group.entries.contains(where: canStage)
    }

    func hasStagedChanges(in group: MultiRootChangeGroup) -> Bool {
        group.entries.contains(where: canUnstage)
    }
}
