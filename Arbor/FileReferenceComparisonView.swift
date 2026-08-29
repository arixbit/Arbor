import SwiftUI

enum FileReferenceKind: String, CaseIterable, Hashable {
    case localBranch
    case remoteBranch
    case tag
    case history

    var title: String {
        switch self {
        case .localBranch: "Branches"
        case .remoteBranch: "Remote Branches"
        case .tag: "Tags"
        case .history: "File History"
        }
    }

    var systemImage: String {
        switch self {
        case .localBranch: "arrow.triangle.branch"
        case .remoteBranch: "cloud"
        case .tag: "tag"
        case .history: "clock.arrow.circlepath"
        }
    }
}

struct FileReferenceChoice: Identifiable, Hashable {
    let kind: FileReferenceKind
    let name: String
    let revisionID: String?
    let summary: String?
    let author: String?
    let timestamp: Int64?
    let message: String?

    init(
        kind: FileReferenceKind,
        name: String,
        revisionID: String? = nil,
        summary: String? = nil,
        author: String? = nil,
        timestamp: Int64? = nil,
        message: String? = nil
    ) {
        self.kind = kind
        self.name = name
        self.revisionID = revisionID
        self.summary = summary
        self.author = author
        self.timestamp = timestamp
        self.message = message
    }

    var id: String { "\(kind.rawValue):\(revision)" }
    var revision: String { revisionID ?? name }
}

private let fileHistoryPageSize: UInt32 = 200

private func fileHistoryChoice(for commit: CommitInfo) -> FileReferenceChoice {
    FileReferenceChoice(
        kind: .history,
        name: commit.shortId,
        revisionID: commit.id,
        summary: commit.summary,
        author: commit.authorName,
        timestamp: commit.time,
        message: commit.messageBody.isEmpty
            ? commit.summary
            : "\(commit.summary)\n\n\(commit.messageBody)"
    )
}

struct FileReferenceComparisonTarget: Equatable, Sendable {
    let rootPath: String
    let relativePath: String
}

enum FileReferenceComparisonMode: String, Hashable {
    case references
    case selectedRevision

    var title: String {
        switch self {
        case .references: "Compare with Branch or Tag"
        case .selectedRevision: "Compare with Selected Revision"
        }
    }

    var searchPlaceholder: String {
        switch self {
        case .references: "Search branches and tags"
        case .selectedRevision: "Search file history"
        }
    }
}

/// Resolve a project-tree path to the deepest discovered Git root.  The
/// project tree is rendered from the primary repository, but nested roots can
/// still appear in that filesystem tree; comparing those files against the
/// parent repository would select the wrong refs.
func fileReferenceComparisonTarget(
    path: String,
    primaryRootPath: String,
    roots: [GitRootInfo]
) -> FileReferenceComparisonTarget? {
    guard let normalizedPath = normalizedRepositoryRelativePath(path) else { return nil }
    let primaryRoot = canonicalExternalLogPath(primaryRootPath)
    guard !primaryRoot.isEmpty else { return nil }

    let absolutePath = canonicalExternalLogPath(
        URL(fileURLWithPath: primaryRoot)
            .appendingPathComponent(normalizedPath)
            .path
    )
    let candidateRoots = Set(
        [primaryRoot] + roots.map { canonicalExternalLogPath($0.path) }
    )
    guard let matchingRoot = candidateRoots
        .filter({ absolutePath == $0 || absolutePath.hasPrefix($0 + "/") })
        .max(by: { $0.count < $1.count }) else {
        return nil
    }

    let relativePath = String(absolutePath.dropFirst(matchingRoot.count))
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let safeRelativePath = normalizedRepositoryRelativePath(relativePath) else {
        return nil
    }
    return FileReferenceComparisonTarget(
        rootPath: matchingRoot,
        relativePath: safeRelativePath
    )
}

/// Creates the same reference set used by the file-level Compare with Ref
/// popup. Kind-qualified IDs are important: a branch and tag may share a
/// display name while still resolving to different Git refs.
func fileReferenceChoices(
    localBranches: [BranchInfo],
    remoteBranches: [RemoteBranchInfo],
    tags: [TagInfo]
) -> [FileReferenceChoice] {
    let local = localBranches
        .map { FileReferenceChoice(kind: .localBranch, name: $0.name) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    let remote = remoteBranches
        .map { FileReferenceChoice(kind: .remoteBranch, name: $0.name) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    let tag = tags
        .map { FileReferenceChoice(kind: .tag, name: $0.name) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    return local + remote + tag
}

/// Keep both sides of a rename when filtering the repository-wide working-tree
/// changes down to a directory.  A rename can enter or leave the selected
/// directory, so checking only the new path would lose one side of the action.
func fileReferenceDirectoryChanges(
    _ changes: [TreeChange],
    under path: String
) -> [TreeChange] {
    guard let normalizedPath = normalizedRepositoryRelativePath(path) else { return [] }
    let prefix = normalizedPath + "/"
    return changes.filter { change in
        change.path.hasPrefix(prefix) || change.oldPath?.hasPrefix(prefix) == true
    }
}

private func fileReferenceChangeSystemImage(_ kind: TreeChangeKind) -> String {
    switch kind {
    case .added: "plus.circle"
    case .modified: "pencil.circle"
    case .deleted: "minus.circle"
    case .renamed: "arrow.left.arrow.right.circle"
    }
}

private func fileReferenceChangeColor(_ kind: TreeChangeKind) -> Color {
    switch kind {
    case .added: .green
    case .modified: .secondary
    case .deleted: .red
    case .renamed: .blue
    }
}

/// Equivalent of IntelliJ's GitCompareWithRefAction for project-tree files
/// and directories.  The repository is supplied by the project-tree owner,
/// so identically named branches in another Git root cannot accidentally be
/// used.
struct FileReferenceComparisonView: View {
    let repo: Repository
    let path: String
    let isDirectory: Bool
    let mode: FileReferenceComparisonMode
    let onClose: () -> Void

    @State private var choices: [FileReferenceChoice] = []
    @State private var selectedChoiceID: String?
    @State private var query = ""
    @State private var fileDiff: FileDiff?
    @State private var treeChanges: [TreeChange] = []
    @State private var selectedTreeChangePath: String?
    @State private var diffError: String?
    @State private var referenceLoadError: String?
    @State private var isLoadingReferences = false
    @State private var isLoadingDiff = false
    @State private var presentationMode: DiffPresentationMode = .sideBySide
    @State private var loadGeneration = 0
    @State private var historyAfterID: String?
    @State private var canLoadMoreHistory = false
    @State private var isLoadingMoreHistory = false
    @State private var historyTask: Task<Void, Never>?

    private var selectedChoice: FileReferenceChoice? {
        guard let selectedChoiceID else { return nil }
        return choices.first { $0.id == selectedChoiceID }
    }

    private var filteredChoices: [FileReferenceChoice] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return choices }
        return choices.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
                || $0.kind.title.localizedCaseInsensitiveContains(needle)
        }
    }

    private var visibleKinds: [FileReferenceKind] {
        switch mode {
        case .references: [.localBranch, .remoteBranch, .tag]
        case .selectedRevision: [.history]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title)
                        .font(.title3.weight(.semibold))
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()

            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(mode.searchPlaceholder, text: $query)
                        .textFieldStyle(.roundedBorder)
                    if let referenceLoadError {
                        Label(
                            mode == .selectedRevision
                                ? "Unable to load file history"
                                : "Some references could not be loaded",
                            systemImage: "exclamationmark.triangle"
                        )
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help(referenceLoadError)
                    }
                    if isLoadingReferences && choices.isEmpty {
                        ProgressView("Loading references…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let diffError, choices.isEmpty {
                        ContentUnavailableView(
                            mode == .selectedRevision
                                ? "Unable to load file history"
                                : "Unable to load references",
                            systemImage: "exclamationmark.triangle",
                            description: Text(diffError)
                        )
                    } else if filteredChoices.isEmpty {
                        ContentUnavailableView(
                            query.isEmpty
                                ? (mode == .selectedRevision ? "No file history" : "No branches or tags")
                                : "No matching references",
                            systemImage: "magnifyingglass"
                        )
                    } else {
                        List(selection: $selectedChoiceID) {
                            ForEach(visibleKinds, id: \.self) { kind in
                                let rows = filteredChoices.filter { $0.kind == kind }
                                if !rows.isEmpty {
                                    Section(kind.title) {
                                        ForEach(rows) { choice in
                                            if kind == .history {
                                                VStack(alignment: .leading, spacing: 3) {
                                                    Text(choice.summary ?? choice.name)
                                                        .lineLimit(1)
                                                    HStack(spacing: 5) {
                                                        Text(choice.name)
                                                            .font(.system(.caption2, design: .monospaced))
                                                        if let author = choice.author, !author.isEmpty {
                                                            Text("· \(author)")
                                                        }
                                                        if let timestamp = choice.timestamp {
                                                            Text("· \(dateStr(timestamp))")
                                                        }
                                                    }
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                                }
                                                .tag(choice.id as String?)
                                                .help(choice.message ?? choice.summary ?? choice.name)
                                            } else {
                                                Label(choice.name, systemImage: kind.systemImage)
                                                    .tag(choice.id as String?)
                                                    .help(choice.name)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .listStyle(.sidebar)
                    }
                    if mode == .selectedRevision,
                       !choices.isEmpty,
                       canLoadMoreHistory || isLoadingMoreHistory {
                        Button {
                            loadMoreHistory()
                        } label: {
                            HStack {
                                if isLoadingMoreHistory {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(isLoadingMoreHistory ? "Loading More…" : "Load More History")
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(isLoadingMoreHistory)
                        .padding(.horizontal, 4)
                    }
                }
                .padding(12)
                .frame(minWidth: 270, idealWidth: 300, maxWidth: 360)

                comparisonContent
                    .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 940, minHeight: 620)
        .task { loadReferences() }
        .onChange(of: selectedChoiceID) { _, newValue in
            guard let newValue,
                  let choice = choices.first(where: { $0.id == newValue }) else {
                fileDiff = nil
                treeChanges = []
                selectedTreeChangePath = nil
                diffError = nil
                isLoadingDiff = false
                return
            }
            if isDirectory {
                loadDirectoryChanges(for: choice)
            } else {
                loadDiff(for: choice)
            }
        }
        .onDisappear {
            loadGeneration &+= 1
            historyTask?.cancel()
        }
    }

    @ViewBuilder
    private var comparisonContent: some View {
        VStack(spacing: 0) {
            if let selectedChoice {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(selectedChoice.summary ?? selectedChoice.name) → Local")
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(isDirectory
                             ? "Compare changes under this directory with the current working tree"
                             : "Compare the selected revision with the current working tree")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if mode == .selectedRevision,
                           let message = selectedChoice.message,
                           !message.isEmpty {
                            Text(message)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .truncationMode(.tail)
                        }
                    }
                    Spacer()
                    if !isDirectory {
                        Picker("Diff View", selection: $presentationMode) {
                            ForEach(DiffPresentationMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 190)
                    }
                }
                .padding(12)
                Divider()

                if isDirectory {
                    directoryComparisonContent(for: selectedChoice)
                } else if isLoadingDiff {
                    ProgressView("Loading file diff…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let diffError {
                    ContentUnavailableView(
                        "Unable to compare file",
                        systemImage: "exclamationmark.triangle",
                        description: Text(diffError)
                    )
                } else if let fileDiff {
                    if fileDiff.binary {
                        ContentUnavailableView(
                            "Binary file",
                            systemImage: "doc.zipper",
                            description: Text("Binary file diff preview is unavailable.")
                        )
                    } else if fileDiff.hunks.isEmpty {
                        ContentUnavailableView(
                            "No differences",
                            systemImage: "checkmark.circle",
                            description: Text("The selected revision and the local file have identical content.")
                        )
                    } else if presentationMode == .unified {
                        UnifiedDiffView(fileDiff: fileDiff)
                    } else {
                        SideBySideDiffView(fileDiff: fileDiff)
                    }
                } else {
                    ContentUnavailableView(
                        "Select a reference",
                        systemImage: "arrow.left.arrow.right",
                        description: Text(mode == .selectedRevision
                                           ? "Choose a historical revision to compare with the local file."
                                           : "Choose a branch or tag to compare this file.")
                    )
                }
            } else {
                ContentUnavailableView(
                    "Select a branch or tag",
                    systemImage: "arrow.left.arrow.right",
                    description: Text(mode == .selectedRevision
                                       ? "Choose a historical revision to compare with the local file."
                                       : "Choose a reference to compare with the local file.")
                )
            }
        }
    }

    @ViewBuilder
    private func directoryComparisonContent(for choice: FileReferenceChoice) -> some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                if isLoadingDiff && treeChanges.isEmpty {
                    ProgressView("Loading directory changes…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let diffError {
                    ContentUnavailableView(
                        "Unable to compare directory",
                        systemImage: "exclamationmark.triangle",
                        description: Text(diffError)
                    )
                } else if treeChanges.isEmpty {
                    ContentUnavailableView(
                        "No differences",
                        systemImage: "checkmark.circle",
                        description: Text("The selected revision and the local directory have identical contents.")
                    )
                } else {
                    List(selection: $selectedTreeChangePath) {
                        ForEach(treeChanges, id: \.path) { change in
                            HStack(spacing: 8) {
                                Image(systemName: fileReferenceChangeSystemImage(change.kind))
                                    .foregroundStyle(fileReferenceChangeColor(change.kind))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(change.path)
                                        .font(.system(.body, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if let oldPath = change.oldPath, oldPath != change.path {
                                        Text("from \(oldPath)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .tag(change.path as String?)
                            .help(change.oldPath.map { "\($0) → \(change.path)" } ?? change.path)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minWidth: 280, idealWidth: 340, maxWidth: 420)

            if treeChanges.isEmpty {
                ContentUnavailableView(
                    "Select a changed file",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Changed files under this directory will appear here.")
                )
            } else {
                TreeCompareDetailView(
                    repo: repo,
                    change: treeChanges.first { $0.path == selectedTreeChangePath },
                    selectedChanges: treeChanges,
                    selectedPaths: Set(treeChanges.map(\.path)),
                    rev1: choice.revision,
                    rev2: "",
                    comparesWithWorkingTree: true,
                    onSelectPath: { selectedTreeChangePath = $0 }
                )
            }
        }
    }

    private func loadReferences() {
        guard !isLoadingReferences else { return }
        isLoadingReferences = true
        diffError = nil
        referenceLoadError = nil
        let generation = loadGeneration
        let requestedRepo = repo
        let requestedPath = path
        let requestedMode = mode
        historyAfterID = nil
        canLoadMoreHistory = false
        isLoadingMoreHistory = false
        historyTask?.cancel()
        Task.detached(priority: .userInitiated) {
            if requestedMode == .selectedRevision {
                do {
                    let history = try requestedRepo.logFiltered(
                        path: requestedPath,
                        limit: fileHistoryPageSize,
                        follow: true,
                        startRev: "HEAD",
                        author: nil,
                        since: nil
                    )
                    let loadedChoices = history.map(fileHistoryChoice)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard generation == self.loadGeneration else { return }
                        self.choices = loadedChoices
                        self.isLoadingReferences = false
                        self.referenceLoadError = nil
                        self.selectedChoiceID = loadedChoices.first?.id
                        self.historyAfterID = history.last?.id
                        self.canLoadMoreHistory = history.count == Int(fileHistoryPageSize)
                        if loadedChoices.isEmpty {
                            self.diffError = "No file history is available for this path."
                        }
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard generation == self.loadGeneration else { return }
                        self.choices = []
                        self.isLoadingReferences = false
                        self.referenceLoadError = "\(error)"
                        self.diffError = "Unable to load file history."
                    }
                }
                return
            }

            var failures: [String] = []
            let localBranches: [BranchInfo]
            do {
                localBranches = try requestedRepo.branchList()
            } catch {
                localBranches = []
                failures.append("Branches: \(error)")
            }
            let remoteBranches: [RemoteBranchInfo]
            do {
                remoteBranches = try requestedRepo.remoteBranchList()
            } catch {
                remoteBranches = []
                failures.append("Remote branches: \(error)")
            }
            let tags: [TagInfo]
            do {
                tags = try requestedRepo.tagList()
            } catch {
                tags = []
                failures.append("Tags: \(error)")
            }
            let loadedChoices = fileReferenceChoices(
                localBranches: localBranches,
                remoteBranches: remoteBranches,
                tags: tags
            )
            let failureMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
            await MainActor.run {
                guard generation == self.loadGeneration else { return }
                self.choices = loadedChoices
                self.isLoadingReferences = false
                self.referenceLoadError = failureMessage
                if loadedChoices.isEmpty {
                    self.diffError = failureMessage
                        ?? "This repository has no local branches, remote branches, or tags."
                }
            }
        }
    }

    private func loadMoreHistory() {
        guard mode == .selectedRevision,
              !isLoadingMoreHistory,
              let afterID = historyAfterID else { return }
        let generation = loadGeneration
        let requestedRepo = repo
        let requestedPath = path
        isLoadingMoreHistory = true
        historyTask?.cancel()
        historyTask = Task.detached(priority: .userInitiated) {
            do {
                let history = try requestedRepo.logFilteredWithMessageAndDateOptionsForRevisionsWithAfterId(
                    path: requestedPath,
                    limit: fileHistoryPageSize,
                    follow: true,
                    startRevs: ["HEAD"],
                    author: nil,
                    since: nil,
                    until: nil,
                    message: nil,
                    messageRegex: false,
                    messageMatchCase: false,
                    noMerges: false,
                    sortMode: .byCommitDate,
                    afterId: afterID
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard generation == self.loadGeneration,
                          self.mode == .selectedRevision,
                          self.historyAfterID == afterID else { return }
                    let existingIDs = Set(self.choices.map(\.id))
                    let newChoices = history
                        .map(fileHistoryChoice)
                        .filter { !existingIDs.contains($0.id) }
                    self.choices.append(contentsOf: newChoices)
                    self.historyAfterID = history.last?.id
                    self.canLoadMoreHistory = history.count == Int(fileHistoryPageSize)
                    self.isLoadingMoreHistory = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard generation == self.loadGeneration,
                          self.mode == .selectedRevision,
                          self.historyAfterID == afterID else { return }
                    self.referenceLoadError = "\(error)"
                    self.isLoadingMoreHistory = false
                }
            }
        }
    }

    private func loadDiff(for choice: FileReferenceChoice) {
        loadGeneration &+= 1
        let generation = loadGeneration
        let requestedPath = path
        let requestedRevision = choice.revision
        fileDiff = nil
        treeChanges = []
        selectedTreeChangePath = nil
        diffError = nil
        isLoadingDiff = true
        let requestedRepo = repo
        Task.detached(priority: .userInitiated) {
            do {
                let result = try requestedRepo.diffRevisionPathWithWorktreeWithSettings(
                    revision: requestedRevision,
                    revisionPath: requestedPath,
                    worktreePath: requestedPath,
                    settings: makeArborGitDiffSettings()
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard generation == self.loadGeneration,
                          self.selectedChoiceID == choice.id else { return }
                    self.fileDiff = result
                    self.isLoadingDiff = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard generation == self.loadGeneration,
                          self.selectedChoiceID == choice.id else { return }
                    self.diffError = "\(error)"
                    self.isLoadingDiff = false
                }
            }
        }
    }

    private func loadDirectoryChanges(for choice: FileReferenceChoice) {
        loadGeneration &+= 1
        let generation = loadGeneration
        let requestedPath = path
        let requestedRevision = choice.revision
        fileDiff = nil
        treeChanges = []
        selectedTreeChangePath = nil
        diffError = nil
        isLoadingDiff = true
        let requestedRepo = repo
        Task.detached(priority: .userInitiated) {
            do {
                let changes = try requestedRepo.treeChangesWithWorktree(revision: requestedRevision)
                let directoryChanges = fileReferenceDirectoryChanges(changes, under: requestedPath)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard generation == self.loadGeneration,
                          self.selectedChoiceID == choice.id else { return }
                    self.treeChanges = directoryChanges
                    self.selectedTreeChangePath = directoryChanges.first?.path
                    self.isLoadingDiff = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard generation == self.loadGeneration,
                          self.selectedChoiceID == choice.id else { return }
                    self.diffError = "\(error)"
                    self.isLoadingDiff = false
                }
            }
        }
    }
}
