import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {

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
var logInspector: some View {
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
                remotesForCommit: logRemotes(for:),
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
                remotesForCommit: logRemotes(for:),
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
                remotesForCommit: logRemotes(for:),
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


struct LogMultiMetadataView: View {
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


struct LogChangeNode: Identifiable {
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


enum LogChangesFilter: String, CaseIterable, Equatable {
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
struct LogChangesBrowserView: View {
    static let maximumCommitsPerSelection = 50

    let repo: Repository?
    let repositoryForCommit: (CommitInfo) -> Repository?
    let remotesForCommit: (CommitInfo) -> [RemoteInfo]
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

    @State var records: [LogChangeRecord] = []
    @State var selectedRecordID: String?
    @State var selectedRecordIDs: Set<String> = []
    @State var fileDiff: FileDiff?
    @State var diffError: String?
    @State var loadError: String?
    @State var isLoading = false
    @State var changesTask: Task<Void, Never>?
    @State var diffTask: Task<Void, Never>?
    @State var presentationMode: DiffPresentationMode = .sideBySide
    @State var selectedParentIndex = 0
    @State var groupByDirectory = true
    @State var collapsedChangeNodes: Set<String> = []
    @State var diffSource: LogDiffSource = .commit
    @State var activeFilter: LogChangesFilter?
    @State var filteredOutRecordIDs: Set<String> = []
    @State var pendingFilterRecordIDs: Set<String> = []
    @State var isFiltering = false
    @State var filterError: String?
    @State var filterTask: Task<Void, Never>?
    @State var submoduleChangeRequest: SubmoduleChangeRequest?
    @State var standaloneDiffRecord: LogChangeRecord?
    @FocusState var changesTreeFocused: Bool

    var hasAffectedPathFilter: Bool {
        !affectedPathSelections.isEmpty
    }

    var rows: [LogChangeRecord] {
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

    var filteredOutRecords: [LogChangeRecord] {
        records.filter { filteredOutRecordIDs.contains($0.id) }
    }

    var pendingFilterRecords: [LogChangeRecord] {
        records.filter { pendingFilterRecordIDs.contains($0.id) }
    }

    var selectedRecord: LogChangeRecord? {
        guard let selectedRecordID else { return nil }
        return rows.first { $0.id == selectedRecordID }
    }

    var selectedRecords: [LogChangeRecord] {
        rows.filter { selectedRecordIDs.contains($0.id) }
    }

    func hostedFileRemotes(for record: LogChangeRecord) -> [RemoteInfo] {
        guard let repository = repositoryForCommit(record.commit) else { return [] }
        let target = hostedFileRevisionTarget(for: record)
        return remotesForCommit(record.commit).filter { remote in
            repository.permalinkForPath(
                remoteUrl: remote.url,
                commitId: target.commitID,
                path: target.path
            ) != nil
        }
    }

    var canEditSelectedChanges: Bool {
        return canRewriteSelectedHistoryChanges(
            commitCount: commits.count,
            selectedCount: selectedRecords.count,
            totalChangeCount: records.count
        ) && logChangeSelectionUsesFirstParent(selectedRecords)
    }

    var canApplySelectedChanges: Bool {
        canApplyLogChangeSelection(selectedRecords)
    }

    var patchSelection: [LogChangeRecord] {
        selectedRecords.isEmpty ? rows : selectedRecords
    }

    var canCreatePatchSelection: Bool {
        if selectedRecords.isEmpty, commits.count == 1 {
            return !records.isEmpty
        }
        return canCreateLogPatchSelection(patchSelection)
    }

    func filterBinding(for filter: LogChangesFilter) -> Binding<Bool> {
        Binding(
            get: { activeFilter == filter },
            set: { enabled in
                setFilter(enabled ? filter : nil)
            }
        )
    }

    func normalizeSelectionAfterFiltering() {
        let validIDs = Set(rows.map(\.id))
        selectedRecordIDs = selectedRecordIDs.intersection(validIDs)
        if let selectedRecordID, !validIDs.contains(selectedRecordID) {
            self.selectedRecordID = nil
            fileDiff = nil
            diffError = nil
            diffSource = .commit
        }
    }

    func setFilter(_ filter: LogChangesFilter?) {
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

    func restartActiveFilter() {
        guard let activeFilter else {
            filterTask?.cancel()
            filteredOutRecordIDs = []
            pendingFilterRecordIDs = []
            isFiltering = false
            return
        }
        setFilter(activeFilter)
    }

    var changeTree: [LogChangeNode] {
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

    var flatChangeTree: [LogChangeNode] {
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

    var changesTree: some View {
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

    func changeNode(
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
    var diffPreview: some View {
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

    func isSubmodule(_ change: TreeChange) -> Bool {
        change.oldMode == 0o160000 || change.newMode == 0o160000
    }

    func showSubmoduleChanges(_ record: LogChangeRecord) {
        submoduleChangeRequest = SubmoduleChangeRequest(
            id: "\(logChangesCommitIdentity(record.commit)):\(record.parentIndex.map(String.init) ?? "root"):\(record.change.path)",
            commit: record.commit,
            revision1: parentRevision(for: record) ?? "",
            revision2: record.commit.id,
            path: record.change.path
        )
    }

    func openStandaloneDiff(_ record: LogChangeRecord) {
        select(record, extending: false)
        standaloneDiffRecord = record
    }

    func changeKindText(_ kind: TreeChangeKind) -> LocalizedStringKey {
        switch kind {
        case .added: return "Added"
        case .modified: return "Modified"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        }
    }

    func loadChanges() {
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

    func select(_ record: LogChangeRecord, extending: Bool? = nil) {
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

    var selectedRecordIndex: Int? {
        guard let selectedRecordID else { return nil }
        return rows.firstIndex(where: { $0.id == selectedRecordID })
    }

    func selectAdjacentChange(offset: Int) {
        guard let selectedRecordIndex,
              let nextIndex = adjacentChangeIndex(
                  count: rows.count,
                  current: selectedRecordIndex,
                  offset: offset
              ) else { return }
        select(rows[nextIndex], extending: false)
    }

    func moveSelection(by offset: Int) {
        guard let nextIndex = keyboardChangeIndex(
            count: rows.count,
            current: selectedRecordIndex,
            offset: offset
        ) else { return }
        select(rows[nextIndex], extending: false)
    }

    func handleUpKeyPress() -> KeyPress.Result {
        moveSelection(by: -1)
        return .handled
    }

    func handleDownKeyPress() -> KeyPress.Result {
        moveSelection(by: 1)
        return .handled
    }

    func handleReturnKeyPress() -> KeyPress.Result {
        guard let selectedRecord else { return .ignored }
        openStandaloneDiff(selectedRecord)
        return .handled
    }

    func copySelectedRecordPaths() {
        let paths = selectedRecords.map { $0.change.path }
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    func parentRevision(for record: LogChangeRecord) -> String? {
        if let parentIndex = record.parentIndex {
            let index = Int(parentIndex)
            if record.commit.parentIds.indices.contains(index) {
                return record.commit.parentIds[index]
            }
        }
        return record.commit.parentIds.first
    }

    func compareWithLocal(_ record: LogChangeRecord, revision: String) {
        let source = LogDiffSource.local(revision: revision)
        diffSource = source
        selectedRecordIDs = [record.id]
        if selectedRecordID == record.id {
            loadDiff(record.id, source: source)
        } else {
            selectedRecordID = record.id
        }
    }

    func loadDiff(_ id: String?, source: LogDiffSource? = nil) {
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


var logActionAvailability: LogActionAvailability {
    LogActionAvailability(
        hasLocalChanges: hasLocalChanges,
        activeOperationRootPath: operationState == nil ? nil : repo?.workdir(),
        hasRemotes: !remotes.isEmpty
    )
}


/// Route menu-level graph actions through a changing command identity so
/// repeated Collapse/Expand requests are delivered even when their action type
/// is unchanged.
func issueLogGraphCommand(_ action: LinearBekGraphActionType) {
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

    let requestBatch = requests
    let task = Task { @MainActor in
        let result = await Task.detached(priority: .userInitiated) {
            () -> LogSignatureLoadResult? in
            var statuses: [String: CommitSignatureInfo] = [:]
            var failedKeys: Set<String> = []
            for request in requestBatch {
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


var logColumnLayout: LogColumnLayout {
    LogColumnLayout(orderRaw: logColumnOrderRaw, widthsRaw: logColumnWidthsRaw)
}


func moveLogColumn(_ column: LogColumnID, by offset: Int) {
    logColumnOrderRaw = logColumnLayout.moving(column, by: offset).orderRaw
}


func canMoveLogColumn(_ column: LogColumnID, by offset: Int) -> Bool {
    guard let index = logColumnLayout.order.firstIndex(of: column) else { return false }
    return logColumnLayout.order.indices.contains(index + offset)
}


func resizeLogColumn(_ column: LogColumnID, by delta: CGFloat) {
    logColumnWidthsRaw = logColumnLayout
        .settingWidth(logColumnLayout.width(for: column) + delta, for: column)
        .widthsRaw
}


func setLogColumnWidth(_ column: LogColumnID, to width: CGFloat) {
    logColumnWidthsRaw = logColumnLayout.settingWidth(width, for: column).widthsRaw
}


var externalLogRootsMenu: some View {
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


var logRefreshButtonTitle: String {
    logViewMode == .reflog ? "Refresh Reflog" : "Refresh Log"
}


var shouldShowLogError: Bool {
    logViewMode != .command
}


var hasSelectedReflogEntries: Bool {
    !reflogSelectedIDs.isEmpty
}


var reflogHistoryContent: some View {
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


var logGraphPanel: some View {
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
                            Text("Target: \(cherryPickTargetBranchLabel)")
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


var logCommandFilterBar: some View {
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
var logGraphHistoryContent: some View {
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


struct LogTabBar: View {
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


struct LogWorkspaceEmptyView: View {
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


func logFilterField(
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


struct LogPathsTreeChooserView: View {
    let roots: [LogPathChooserRoot]
    @Binding var selections: Set<LogPathFilterSelection>
    let onCancel: () -> Void
    let onApply: () -> Void

    @State var expandedRoots: Set<String> = []
    @State var rootEntries: [String: [DirEntry]] = [:]
    @State var loadingRoots: Set<String> = []
    @State var rootErrors: [String: String] = [:]

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
    func rootSection(_ root: LogPathChooserRoot) -> some View {
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

    func loadRootEntries(_ root: LogPathChooserRoot) {
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


struct LogPathTreeNodeView: View {
    let repository: Repository
    let rootPath: String
    let entry: DirEntry
    let depth: Int
    @Binding var selections: Set<LogPathFilterSelection>

    @State var children: [DirEntry] = []
    @State var expanded = false
    @State var loaded = false
    @State var loading = false
    @State var error: String?

    var selection: LogPathFilterSelection {
        LogPathFilterSelection(rootPath: rootPath, path: entry.path)
    }

    var selectionState: LogPathSelectionState {
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

    func loadChildren() {
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


struct LogPathsEditorView: View {
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
