import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {


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
        }
    }

    /// Sorting every intermediate tree on each insert used to make building a
    /// large commit's tree quadratic in `localizedStandardCompare` calls. The
    /// builder now appends in path order and sorts each directory once here.
    func sortedByName() -> LogChangeNode {
        var sorted = self
        sorted.children = children
            .map { $0.sortedByName() }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return sorted
    }
}

/// Rebuilding the Log Changes tree re-split every path and re-sorted every
/// directory, and the old `changeTree` computed property did that for every
/// SwiftUI body evaluation of the browser. The rows only change when the
/// loaded records, the active filters or the grouping change, so the tree is
/// memoized against those inputs.
final class LogChangeTreeCache {
    struct Key: Equatable {
        let rowDigest: Int
        let rowCount: Int
        let grouping: Int
        let commitDigest: Int
    }

    private var key: Key?
    private var roots: [LogChangeNode] = []

    func roots(for key: Key, build: () -> [LogChangeNode]) -> [LogChangeNode] {
        if self.key == key { return roots }
        let built = build()
        self.key = key
        self.roots = built
        return built
    }
}

static func logChangesTreeDigest(_ rows: [LogChangeRecord]) -> Int {
    logChangesTreeDigest(rows.map(\.id))
}

static func logChangesTreeDigest(_ ids: [String]) -> Int {
    var hasher = Hasher()
    for id in ids {
        hasher.combine(id)
    }
    return hasher.finalize()
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
    /// Non-nil only in a dedicated File History tab: enables IntelliJ's
    /// `VcsHistory.ShowAllAffected` entry (GitHistoryProvider additional
    /// action) on the single selected revision.
    var affectedHistoryPath: String? = nil

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
    @State var treeCache = LogChangeTreeCache()
    @State var diffSource: LogDiffSource = .commit
    @State var activeFilter: LogChangesFilter?
    @State var filteredOutRecordIDs: Set<String> = []
    @State var pendingFilterRecordIDs: Set<String> = []
    @State var isFiltering = false
    @State var filterError: String?
    @State var filterTask: Task<Void, Never>?
    @State var submoduleChangeRequest: SubmoduleChangeRequest?
    @State var standaloneDiffRecord: LogChangeRecord?
    @State var affectedHistoryResolveTask: Task<Void, Never>?
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
        let rows = self.rows
        let key = LogChangeTreeCache.Key(
            rowDigest: ContentView.logChangesTreeDigest(rows),
            rowCount: rows.count,
            grouping: (groupByDirectory ? 1 : 0)
                | (showsChangesFromParents ? 2 : 0)
                | (commits.count > 1 ? 4 : 0),
            commitDigest: ContentView.logChangesTreeDigest(commits.map(\.id))
        )
        return treeCache.roots(for: key) { buildChangeTree(rows: rows) }
    }

    func buildChangeTree(rows: [LogChangeRecord]) -> [LogChangeNode] {
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
                return group.sortedByName()
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
                return group.sortedByName()
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
        return roots
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { $0.sortedByName() }
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
            ScrollView(.horizontal) {
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
                if isShowAllAffectedFilesAvailable(
                    affectedHistoryPath: affectedHistoryPath,
                    commitCount: commits.count
                ) {
                    Button {
                        showAllAffectedHistoryFiles()
                    } label: {
                        Label("Show All Affected Files", systemImage: "rectangle.expand.vertical")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(isLoading || records.isEmpty)
                    .help("Show the complete changeset of this revision with the followed file highlighted")
                }
                Spacer()
                if showsDiffPreview && selectedRecordID != nil {
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
            }
            .scrollIndicators(.hidden)
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
            } else if showsDiffPreview && selectedRecordID != nil {
                GeometryReader { geometry in
                if diffPreviewVertical || geometry.size.width < 520 {
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
        let selection = selectedRecords
        return List {
            ForEach(groupByDirectory ? changeTree : flatChangeTree) { node in
                changeNode(node, depth: 0, selection: selection)
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
                            selection: selection,
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
                            selection: selection,
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
        selection: [LogChangeRecord],
        isFilteredOut: Bool = false,
        isPending: Bool = false
    ) -> AnyView {
        if let record = node.record, node.children.isEmpty {
            let contextActionRecords = contextualLogChangeSelection(
                context: record,
                selected: selection
            )
            let contextActionTitle = contextActionRecords.count > 1
                ? "Selected Changes"
                : "Change"
            let row = HStack(spacing: 7) {
                Image(systemName: repositoryFileSymbol(for: record.change.path))
                    .font(Design.Typography.interface(13))
                    .foregroundStyle(repositoryFileIconColor(for: record.change.path))
                    .frame(width: 16)
                Text(node.name)
                    .font(Design.Typography.interface(13))
                    .foregroundStyle(record.change.kind == .added ? Color.green : .primary)
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
                        selected: selection
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
                        selection: selection,
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

    /// IntelliJ 对照：`VcsHistory.ShowAllAffected`（Show All Affected Files）。
    /// fork 从 File History 打开该提交的完整 changeset 并选中受影响文件；
    /// Arbor 的 inspector 已展示完整 changeset，这里补齐 fork 的两个用户可见
    /// 行为：只看受影响变更的开关打开，以及选中/高亮 History 路径的记录 ——
    /// 路径不在 changeset 时用引擎 `pathAtRevision` 按首父链兑底解析当时路径
    /// （fork 用 `--after=commitTime` 文件历史）。解析失败保持过滤打开、
    /// 不高亮、不报错，与 fork 返回 (commit, filePath) 的降级一致。
    func showAllAffectedHistoryFiles() {
        guard let affectedHistoryPath,
              let commit = commits.first else { return }
        showsOnlyAffectedChanges = true
        if let match = logAffectedHistoryRecordID(
            records: records,
            historyPath: affectedHistoryPath
        ) {
            selectedRecordID = match
            selectedRecordIDs = [match]
            return
        }
        let expectedCommitID = commit.id
        let repository = repositoryForCommit(commit) ?? repo
        guard let repository else { return }
        affectedHistoryResolveTask?.cancel()
        affectedHistoryResolveTask = Task {
            let resolvedPath: String?
            do {
                resolvedPath = try await Task.detached(priority: .userInitiated) {
                    try repository.pathAtRevision(
                        revision: expectedCommitID,
                        path: affectedHistoryPath
                    )
                }.value
            } catch {
                resolvedPath = nil
            }
            guard !Task.isCancelled,
                  self.commits.first?.id == expectedCommitID else { return }
            guard let resolvedPath else { return }
            if let match = logAffectedHistoryRecordID(
                records: self.records,
                historyPath: resolvedPath
            ) {
                self.selectedRecordID = match
                self.selectedRecordIDs = [match]
            }
        }
    }

    func loadChanges() {
        changesTask?.cancel()
        diffTask?.cancel()
        filterTask?.cancel()
        affectedHistoryResolveTask?.cancel()
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

}
