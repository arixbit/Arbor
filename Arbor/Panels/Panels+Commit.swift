import SwiftUI
import AppKit
import UniformTypeIdentifiers


struct RebasedCommitWorkspace: View {
    let projectPath: String?
    let repo: Repository?
    let repositoryWorkdir: String?
    let shelfRepo: Repository?
    let entries: [FileEntry]
    let changeLists: [ChangeListInfo]
    let untrackedEntries: [FileEntry]
    let ignoredRules: [IgnoreRuleInfo]
    let stashes: [StashInfo]
    let shelves: [ShelveInfo]
    let deletedShelves: [ShelveInfo]
    let shelfChangeLists: [ChangeListInfo]
    /// Monotonic request from the VCS main menu to select the combined
    /// Shelf/Stash tab.
    var showShelfRequestID: Int = 0
    /// Keeps selection-scoped main-menu actions from using a stale Changes
    /// selection while the Shelf tab is active.
    var onWorkspaceTabChange: (Bool) -> Void = { _ in }
    let shelfRootPath: String?
    let shelfRootOptions: [GitRootInfo]
    let selectedShelfRootPath: String
    let isShelfRootReadOnly: Bool
    let canMutateShelfMetadata: Bool
    let canApplyShelfWorktree: Bool
    let isShelfRootLoading: Bool
    let shelfRootError: String?
    let onShelfRootChange: (String) -> Void
    let isLoading: Bool
    let isShowingCachedStatusSnapshot: Bool
    let hasStaged: Bool
    let commitFeedback: String?
    /// OPS-001 统一操作状态：非 nil 时显示 Operation Recovery Bar。
    let operationState: OperationState?
    let operationFeedback: String?
    /// IDX-001 二进制文件路径集合（staging model 提供，diff 降级展示）。
    let binaryPaths: Set<String>
    var lfsTrackedPaths: Set<String> = []
    var lfsPointerPaths: Set<String> = []
    /// HEAD/index/worktree presence facts from the staging model.
    var stagingPresence: [String: StagingVersionPresence] = [:]
    /// Invalidates the preview when an external status/index refresh changes
    /// file contents without changing the selected path or status kind.
    var refreshToken: Int = 0
    let recentMessages: [String]
    @Binding var commitMessage: String
    @Binding var amendMode: Bool
    @Binding var skipHooks: Bool
    @AppStorage(GitCommitHooksSettings.key)
    var alwaysSkipCommitHooks = GitCommitHooksSettings.defaultValue
    let onStage: (String) -> Void
    var onStageWithoutContent: (String) -> Void = { _ in }
    var onStageWithoutContentAll: () -> Void = {}
    let onUnstage: (String) -> Void
    let onPartial: (String) -> Void
    let onSelect: (String) -> Void
    let onPreviewPath: (String) -> Void
    /// Explicitly opens the stage diff preview. This is separate from
    /// `onPreviewPath`: the latter mirrors GitStagePanel's double-click/open
    /// source path, while the tree context menu's Show Diff action must keep
    /// the Commit/Stash workspace in place.
    let onShowDiffPath: (String) -> Void
    /// Reverse Local → Staged comparison; normal Show Diff remains Staged → Local.
    var onShowLocalStagedDiffPath: (String) -> Void = { _ in }
    var onShowLocalVersionPath: (String) -> Void = { _ in }
    var onShowStagedVersionPath: (String) -> Void = { _ in }
    let onShowStagedDiffPath: (String) -> Void
    let onShowThreeVersionsPath: (String) -> Void
    @Binding var previewMode: StagingPreviewMode
    let comparisonMode: DiffMode?
    @Binding var showThreeVersions: Bool
    @Binding var previewPath: String?
    @Binding var isPreviewVisible: Bool
    @Binding var selectionModePath: String?
    let onRestore: (String) -> Void
    let onRevertUnstaged: (String) -> Void
    let onRefresh: () -> Void
    let onStageAll: () -> Void
    let onStageEverything: () -> Void
    let onCreateChangeList: () -> Void
    let onRenameChangeList: (String) -> Void
    let onDeleteChangeList: (String) -> Void
    let onActivateChangeList: (String) -> Void
    let onMovePathsToChangeList: ([String], String) -> Void
    let onTemplate: () -> Void
    let onBeforeCommitSettings: () -> Void
    let onCommit: () -> Void
    let onCommitAll: () -> Void
    let onCommitAndRebase: () -> Void
    let autoSquashCommitKind: AutoSquashCommitKind?
    let onCommitAndPush: () -> Void
    let onOperationContinue: () -> Void
    let onOperationSkip: () -> Void
    let onOperationAbort: () -> Void
    let onOpenConflictResolver: () -> Void
    let onShelve: () -> Void
    /// Opens the repository-scoped Shelf storage settings.
    var onShelfSettings: () -> Void = {}
    let onShelvePaths: ([String]) -> Void
    let onImportShelve: (String?) -> Void
    let onPreview: () -> Void
    let onStash: () -> Void
    var onStashPaths: ([String]) -> Void = { _ in }
    let onStashSilently: () -> Void
    let onApplyStash: (String, Bool) -> Void
    let onPopStash: (String, Bool) -> Void
    let onDropStash: (String) -> Void
    let onStashBranch: (String) -> Void
    var onUnstashAs: (String) -> Void = { _ in }
    let onStashDiffPreview: (String) -> Void
    let stashDiffText: String?
    @Binding var stashPreviewStashID: String?
    @Binding var isStashPreviewVisible: Bool
    let onStashClear: () -> Void
    let onShelveDiffPreview: (String) -> Void
    let shelfDiffText: String?
    @Binding var shelfPreviewName: String?
    @Binding var shelfPreviewIsDeleted: Bool
    @Binding var isShelfPreviewVisible: Bool
    let onRenameShelve: (String, String) -> Void
    var onRenameShelveDescription: (String, String) -> Void = { _, _ in }
    let onExportShelve: (String) -> Void
    let onUnshelve: (String) -> Void
    let onUnshelveWithOptions: (String, Bool) -> Void
    let onUnshelvePathsWithOptions: (String, [String], Bool) -> Void
    var onUnshelvePathGroupsWithOptions: ([ShelfPathDeleteGroup], Bool, Bool) -> Void = { _, _, _ in }
    let onUnshelveSelectionsWithOptions: (String, [ShelvePatchSelection], Bool) -> Void
    var onUnshelvePathsWithBase: (String, [String], Bool, String, UInt32) -> Void = { _, _, _, _, _ in }
    var onUnshelveSelectionsWithBase: (String, [ShelvePatchSelection], Bool, String, UInt32) -> Void = { _, _, _, _, _ in }
    var onUnshelveShelvesIntoChangeList: ([String], String, Bool) -> Void = { _, _, _ in }
    var onUnshelvePathGroupsIntoChangeList: ([ShelfPathDeleteGroup], String, Bool) -> Void = { _, _, _ in }
    var onUnshelveShelvesSilently: ([String], Bool) -> Void = { _, _ in }
    var onUnshelveDeletedShelvesSilently: ([String], Bool) -> Void = { _, _ in }
    var onUnshelveDeletedPathsWithOptions: (String, [String], Bool) -> Void = { _, _, _ in }
    var onPopShelve: (String) -> Void = { _ in }
    var onPopShelves: ([String]) -> Void = { _ in }
    let onUnshelveIntoChangeList: (String, [String]?, String) -> Void
    var onUnshelveSelectionsIntoChangeList: (String, [ShelvePatchSelection], String, Bool) -> Void = { _, _, _, _ in }
    var onUnshelveIntoChangeListWithBase: (String, [String]?, String, Bool, String, UInt32) -> Void = { _, _, _, _, _, _ in }
    var onUnshelveSelectionsIntoChangeListWithBase: (String, [ShelvePatchSelection], String, Bool, String, UInt32) -> Void = { _, _, _, _, _, _ in }
    /// Persists an optional Unshelve comment on the explicit target
    /// Changelist after the apply operation has been dispatched.
    var onRecordUnshelveComment: (String, String) -> Void = { _, _ in }
    let onCleanRecycledShelves: () -> Void
    let onDropShelve: (String) -> Void
    var onDropShelves: ([String]) -> Void = { _ in }
    let onDropShelvePaths: (String, [String]) -> Void
    var onDropShelvePathGroups: ([ShelfPathDeleteGroup]) -> Void = { _ in }
    let onMoveShelfPaths: (String, String, [String]) -> Void
    let onRestoreDeletedShelve: (String) -> Void
    let onDeleteDeletedShelve: (String) -> Void
    var onDeleteDeletedShelfPaths: (String, [String]) -> Void = { _, _ in }
    var onDeleteDeletedShelfPathGroups: ([ShelfPathDeleteGroup]) -> Void = { _ in }
    var onRestoreDeletedShelves: ([String]) -> Void = { _ in }
    var onDeleteDeletedShelves: ([String], Bool) -> Void = { _, _ in }
    var onDeleteShelfPlan: (ShelfDeletePlan) -> Void = { _ in }
    let onIgnore: ([String], String?) -> Void
    let onExclude: ([String]) -> Void
    let onOpenConflict: (String) -> Void
    var resolvedConflictPaths: [String] = []
    var onRevertResolved: (String) -> Void = { _ in }
    var onShowHistory: (String) -> Void = { _ in }
    var onEditGitignore: () -> Void = {}
    var onEditGitExclude: () -> Void = {}

    @State var tab: Tab = .commit
    @State var stashesExpanded = true
    @State var shelvesExpanded = true
    @State var shelfGroupByDirectory = true
    @State var deletedShelvesExpanded = true
    @State var showRecycledShelves = false
    @State var removeAppliedFilesFromShelf = false
    @State var expandedShelfIDs: Set<String> = []
    @State var collapsedShelfFolders: Set<String> = []
    @State var selectedShelfIDs: Set<String> = []
    @State var selectedShelfMemberIDs: Set<String> = []
    @State var selectedDeletedShelfIDs: Set<String> = []
    @State var selectedDeletedShelfMemberIDs: Set<String> = []
    @State var selectedStashID: String?
    @State var pendingUnshelve: ShelfUnshelveRequest?
    @State var pendingUnshelveShelves: ShelfBatchUnshelveRequest?
    @State var pendingUnshelveMemberGroups: ShelfMemberBatchUnshelveRequest?
    @State var showClearStashesConfirmation = false
    @State var showCommitAllConfirmation = false
    @State var groupByDirectory = true
    @State var showIgnored = true
    @State var contextSelectedPaths: Set<String> = []
    @State var treeExpansionCommand = 0
    @State var treeExpansionTarget = true
    @State var editingShelfID: String?
    @State var editingShelfDescription = ""
    @State var lastAppliedShelfRequestID = 0
    @AppStorage(GitStashViewSettings.splitPreviewKey)
    var stashSplitPreviewEnabled = GitStashViewSettings.defaultSplitPreview
    @FocusState var focusedShelfID: String?

    enum Tab: String, CaseIterable {
        case commit = "Commit"
        case stash = "Stash"
    }

    var conflictedEntries: [FileEntry] {
        entries.filter { $0.staged == .conflicted || $0.unstaged == .conflicted }
    }

    var conflictedPaths: Set<String> {
        Set(conflictedEntries.map(\.path))
    }

    /// IntelliJ leaves the Commit tool window usable while an interactive
    /// rebase is paused at `edit`, but only for amending that paused commit.
    /// A conflict pause must continue to use the conflict resolver instead.
    var canAmendPausedRebase: Bool {
        rebaseEditPauseAllowsAmend(operationState)
    }

    /// GitStageTree keeps ordinary-sized untracked sets under Unstaged. It
    /// creates a separate Unversioned node only when IntelliJ's
    /// `vcs.unversioned.files.max.intree` threshold is exceeded.
    var standaloneUnversionedEntries: [FileEntry] {
        untrackedEntries.count > 1_000 ? untrackedEntries : []
    }

    var embeddedUntrackedPaths: Set<String> {
        Set(untrackedEntries.count > 1_000 ? [] : untrackedEntries.map(\.path))
    }

    var contextEligiblePaths: Set<String> {
        Set(entries.filter(gitIgnoreActionAvailable).map(\.path))
    }

    var unstagedEntries: [FileEntry] {
        entries.filter {
            guard $0.unstaged != .unchanged,
                  $0.unstaged != .ignored,
                  !conflictedPaths.contains($0.path) else { return false }
            if $0.unstaged == .untracked {
                return embeddedUntrackedPaths.contains($0.path)
            }
            return true
        }
    }

    var visibleChangedCount: Int {
        // A partially staged file is rendered in both Unstaged and Staged
        // groups, but Rebased's Changes counter represents files, not group
        // rows. Counting the three arrays directly made the header jump by
        // two for one physical file.
        Set((conflictedEntries + unstagedEntries + untrackedEntries + stagedEntries).map(\.path)).count
    }

    var ignoredEntries: [FileEntry] {
        entries.filter { $0.unstaged == .ignored }
    }

    var stagedEntries: [FileEntry] {
        entries.filter { $0.staged != .unchanged && !conflictedPaths.contains($0.path) }
    }

    var visibleChangeLists: [ChangeListInfo] {
        if !changeLists.isEmpty {
            return changeLists
        }
        // Keep the tree useful during the short interval before repository
        // metadata loads. The engine will replace this synthetic default with
        // the persisted list state on the next refresh.
        return [ChangeListInfo(
            name: "Default",
            paths: entries.map(\.path),
            isDefault: true,
            isActive: true
        )]
    }

    var visibleShelfChangeLists: [ChangeListInfo] {
        if !shelfChangeLists.isEmpty {
            return shelfChangeLists
        }
        return [ChangeListInfo(
            name: "Default",
            paths: [],
            isDefault: true,
            isActive: true
        )]
    }

    var visibleShelves: [ShelveInfo] {
        showRecycledShelves ? shelves : shelves.filter { !$0.isRecycled }
    }

    var showRecycledShelvesBinding: Binding<Bool> {
        Binding(
            get: { showRecycledShelves },
            set: { value in
                showRecycledShelves = value
                ShelfViewSettings.saveShowRecycled(value, for: projectPath)
            }
        )
    }

    func loadShelfViewSettings() {
        showRecycledShelves = ShelfViewSettings.showRecycled(for: projectPath)
        removeAppliedFilesFromShelf = ShelfViewSettings.removeAppliedFilesFromShelf(for: projectPath)
        shelvesExpanded = ShelfViewSettings.shelvesExpanded(for: projectPath)
        shelfGroupByDirectory = ShelfViewSettings.groupByDirectory(for: projectPath)
        deletedShelvesExpanded = ShelfViewSettings.deletedShelvesExpanded(for: projectPath)
    }

    func loadGitStageViewSettings() {
        showIgnored = GitStageViewSettings.ignoredFilesShown(for: projectPath)
    }

    func shelfDisplayDescription(_ shelf: ShelveInfo) -> String {
        shelf.description.isEmpty ? shelf.name : shelf.description
    }

    @ViewBuilder
    func shelfTitleView(_ shelf: ShelveInfo) -> some View {
        if editingShelfID == shelf.id {
            TextField("Shelf description", text: $editingShelfDescription)
                .textFieldStyle(.plain)
                .focused($focusedShelfID, equals: shelf.id)
                .onSubmit { commitShelfRename(shelf) }
                .onExitCommand { cancelShelfRename() }
        } else {
            Text(shelfDisplayDescription(shelf))
                .lineLimit(1)
                .onTapGesture(count: 2) { beginShelfRename(shelf) }
        }
    }

    func entries(_ source: [FileEntry], in list: ChangeListInfo) -> [FileEntry] {
        let members = Set(list.paths)
        return source.filter { members.contains($0.path) }
    }

    var hasTrackedUnstagedChanges: Bool {
        entries.contains {
            $0.unstaged != .unchanged
                && $0.unstaged != .untracked
                && $0.unstaged != .ignored
        }
    }

    var hasCommitAllEligibleChanges: Bool {
        entries.contains {
            $0.staged != .conflicted
                && $0.unstaged != .conflicted
                && $0.unstaged != .unchanged
                && $0.unstaged != .untracked
                && $0.unstaged != .ignored
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 22) {
                ForEach(Tab.allCases, id: \.self) { item in
                    Button(item.rawValue) {
                        tab = item
                        onWorkspaceTabChange(item == .stash)
                    }
                    .buttonStyle(RebasedTabButtonStyle(isSelected: tab == item))
                }
                Spacer()
                Menu {
                    Button("Refresh") { onRefresh() }
                    Button("Stash…") { onStash() }
                    Button("Shelve…") { onShelve() }
                        .disabled(isShelfRootReadOnly || isShelfRootLoading)
                    Button("Shelf Location…") { onShelfSettings() }
                        .disabled(!canMutateShelfMetadata || isShelfRootLoading)
                    Divider()
                    Button("Clear Already Unshelved", role: .destructive) {
                        onCleanRecycledShelves()
                    }
                    .disabled(
                        !canMutateShelfMetadata
                            || !shelves.contains(where: \.isRecycled)
                    )
                    Button("Clear All Stashes", role: .destructive) {
                        showClearStashesConfirmation = true
                    }
                        .disabled(stashes.isEmpty)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .background(rebasedSurface)

            Divider()

            if let operationState {
                OperationRecoveryBar(
                    state: operationState,
                    feedback: operationFeedback,
                    onContinue: onOperationContinue,
                    onSkip: onOperationSkip,
                    onAbort: onOperationAbort,
                    onOpenConflictResolver: onOpenConflictResolver,
                    onOpenConflict: onOpenConflict
                )
            }

            if tab == .commit {
                commitContent
            } else {
                stashContent
            }
        }
        .background(rebasedBackground)
        .foregroundStyle(.primary)
        .onAppear {
            loadShelfViewSettings()
            loadGitStageViewSettings()
            applyShowShelfRequest(showShelfRequestID)
            onWorkspaceTabChange(tab == .stash)
        }
        .onChange(of: showShelfRequestID) { _, requestID in
            applyShowShelfRequest(requestID)
        }
        .onChange(of: projectPath) { _, _ in
            loadShelfViewSettings()
            loadGitStageViewSettings()
            contextSelectedPaths.removeAll()
        }
        .onChange(of: repositoryWorkdir) { _, _ in
            contextSelectedPaths.removeAll()
        }
        .onChange(of: removeAppliedFilesFromShelf) { _, value in
            ShelfViewSettings.saveRemoveAppliedFilesFromShelf(value, for: projectPath)
        }
        .onChange(of: shelvesExpanded) { _, value in
            ShelfViewSettings.saveShelvesExpanded(value, for: projectPath)
        }
        .onChange(of: shelfGroupByDirectory) { _, value in
            ShelfViewSettings.saveGroupByDirectory(value, for: projectPath)
        }
        .onChange(of: deletedShelvesExpanded) { _, value in
            ShelfViewSettings.saveDeletedShelvesExpanded(value, for: projectPath)
        }
        .onChange(of: showIgnored) { _, value in
            GitStageViewSettings.saveIgnoredFilesShown(value, for: projectPath)
        }
        .confirmationDialog(
            "Clear all stashes?",
            isPresented: $showClearStashesConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All Stashes", role: .destructive, action: onStashClear)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently removes every local stash from this repository.")
        }
        .confirmationDialog(
            "Commit All",
            isPresented: $showCommitAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Commit All", action: onCommitAll)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Nothing is staged. Commit all tracked changes?")
        }
        .sheet(item: $pendingUnshelve) { request in
            let shelfPaths = shelves.first(where: { $0.name == request.name })?.paths
                ?? request.paths
                ?? []
            RebasedUnshelveDialog(
                name: request.name,
                paths: shelfPaths,
                initialPaths: request.paths ?? shelfPaths,
                changeLists: visibleShelfChangeLists,
                repo: shelfRepo,
                removeAppliedFilesFromShelf: $removeAppliedFilesFromShelf,
                onUnshelve: { selectedPaths, selections, targetName, removeApplied, basePath, pathStrip, comment in
                    guard shelfActionRootMatchesCurrentRoot(
                        requestedRootPath: request.rootPath,
                        currentRootPath: selectedShelfRootPath
                    ) else {
                        pendingUnshelve = nil
                        return
                    }
                    pendingUnshelve = nil
                    if let targetName, let comment, !comment.isEmpty {
                        onRecordUnshelveComment(targetName, comment)
                    }
                    let hasMapping = (basePath?.isEmpty == false) || pathStrip != 1
                    if let targetName {
                        if !selections.isEmpty {
                            if hasMapping {
                                onUnshelveSelectionsIntoChangeListWithBase(
                                    request.name,
                                    selections,
                                    targetName,
                                    removeApplied,
                                    basePath ?? "",
                                    pathStrip
                                )
                            } else {
                                onUnshelveSelectionsIntoChangeList(
                                    request.name,
                                    selections,
                                    targetName,
                                    removeApplied
                                )
                            }
                        } else {
                            if hasMapping {
                                onUnshelveIntoChangeListWithBase(
                                    request.name,
                                    selectedPaths,
                                    targetName,
                                    removeApplied,
                                    basePath ?? "",
                                    pathStrip
                                )
                            } else {
                                onUnshelveIntoChangeList(request.name, selectedPaths, targetName)
                            }
                        }
                    } else if !selections.isEmpty {
                        if hasMapping {
                            onUnshelveSelectionsWithBase(
                                request.name,
                                selections,
                                removeApplied,
                                basePath ?? "",
                                pathStrip
                            )
                        } else {
                            onUnshelveSelectionsWithOptions(
                                request.name,
                                selections,
                                removeApplied
                            )
                        }
                    } else if Set(selectedPaths) == Set(shelfPaths) {
                        if hasMapping {
                            onUnshelvePathsWithBase(
                                request.name,
                                selectedPaths,
                                removeApplied,
                                basePath ?? "",
                                pathStrip
                            )
                        } else {
                            onUnshelveWithOptions(request.name, removeApplied)
                        }
                    } else if hasMapping {
                        onUnshelvePathsWithBase(
                            request.name,
                            selectedPaths,
                            removeApplied,
                            basePath ?? "",
                            pathStrip
                        )
                    } else {
                        onUnshelvePathsWithOptions(request.name, selectedPaths, removeApplied)
                    }
                },
                onCancel: { pendingUnshelve = nil }
            )
        }
        .sheet(item: $pendingUnshelveShelves) { request in
            RebasedUnshelveMultipleDialog(
                names: request.names,
                changeLists: visibleShelfChangeLists,
                suggestedName: request.names.first.flatMap { name in
                    shelves.first(where: { $0.name == name })?.description
                },
                removeAppliedFilesFromShelf: $removeAppliedFilesFromShelf,
                onUnshelve: { targetName, removeApplied in
                    guard shelfActionRootMatchesCurrentRoot(
                        requestedRootPath: request.rootPath,
                        currentRootPath: selectedShelfRootPath
                    ) else {
                        pendingUnshelveShelves = nil
                        return
                    }
                    pendingUnshelveShelves = nil
                    onUnshelveShelvesIntoChangeList(request.names, targetName, removeApplied)
                },
                onCancel: { pendingUnshelveShelves = nil }
            )
        }
        .sheet(item: $pendingUnshelveMemberGroups) { request in
            RebasedUnshelveMultipleDialog(
                names: request.groups.map(\.shelfName),
                changeLists: visibleShelfChangeLists,
                suggestedName: request.groups.first.flatMap { group in
                    shelves.first(where: { $0.name == group.shelfName })?.description
                },
                removeAppliedFilesFromShelf: $removeAppliedFilesFromShelf,
                onUnshelve: { targetName, removeApplied in
                    guard shelfActionRootMatchesCurrentRoot(
                        requestedRootPath: request.rootPath,
                        currentRootPath: selectedShelfRootPath
                    ) else {
                        pendingUnshelveMemberGroups = nil
                        return
                    }
                    pendingUnshelveMemberGroups = nil
                    onUnshelvePathGroupsIntoChangeList(
                        request.groups,
                        targetName,
                        removeApplied
                    )
                },
                onCancel: { pendingUnshelveMemberGroups = nil }
            )
        }
    }

    var commitContent: some View {
        Group {
            if isPreviewVisible {
                HSplitView {
                    commitPanel
                        .frame(minWidth: 250, idealWidth: 360, maxWidth: .infinity, maxHeight: .infinity)

                    Group {
                        if let comparisonMode,
                           let previewPath,
                           let entry = entries.first(where: { $0.path == previewPath }) {
                            DiffDetailView(
                                repo: repo,
                                entry: entry,
                                onChanged: onRefresh,
                                selectionModePath: nil,
                                initialMode: comparisonMode,
                                refreshToken: refreshToken
                            )
                        } else {
                            StagingDiffPreviewView(
                                repo: repo,
                                path: previewPath,
                                entry: entries.first(where: { $0.path == previewPath }),
                                refreshToken: refreshToken,
                                selectionModePath: $selectionModePath,
                                previewMode: $previewMode,
                                showThreeVersions: $showThreeVersions,
                                onStage: onStage,
                                onUnstage: onUnstage,
                                onRevertUnstaged: onRevertUnstaged,
                                onChanged: onRefresh,
                                onClose: {
                                    isPreviewVisible = false
                                    showThreeVersions = false
                                    selectionModePath = nil
                                }
                            )
                        }
                    }
                    .frame(minWidth: 260, idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                commitPanel
            }
        }
    }

    /// rebased 的 PreviewDiffSplitterComponent 包住的是整个 Stage panel，
    /// 而不是把 diff 插进 Changes 和 Commit Message 中间。保留这个边界
    /// 后，提交编辑器的高度和操作按钮不会随着 diff 预览被挤成不可用的
    /// 小条，左右两个工作区也各自保持独立的滚动上下文。
    var commitPanel: some View {
        VSplitView {
            stagingTreePanel
                // Rebased keeps the Changes tree as the dominant region;
                // the commit editor is a compact footer, not an equal-sized
                // second pane. The tree therefore absorbs extra height.
                .frame(minHeight: 180, idealHeight: 640, maxHeight: .infinity)

            commitEditorPanel
                .frame(minHeight: 180, idealHeight: 180, maxHeight: 240)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// GitStagePanel's first splitter component: toolbar + the staged tree.
    /// The commit message is deliberately not inside this scroll view; the
    /// divider between the two components is a real workspace affordance.
    var stagingTreePanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                // Keep the same action order as GitStagePanel's
                // Git.Stage.Toolbar: preview, refresh, stage tracked, stash,
                // then the grouping/ignored settings popup.
                compactButton(
                    isPreviewVisible ? "eye.fill" : "eye",
                    help: isPreviewVisible ? "Hide changes preview" : "Show changes preview",
                    action: onPreview
                )
                .disabled(visibleChangedCount == 0)
                compactButton("arrow.clockwise", help: "Refresh", action: onRefresh)
                compactButton("arrow.right", help: "Stage tracked changes", action: onStageAll)
                    .disabled(operationState != nil || !hasTrackedUnstagedChanges)
                compactButton("arrow.right.to.line", help: "Stage all changes", action: onStageEverything)
                    .disabled(operationState != nil || visibleChangedCount == 0)
                compactButton("doc.badge.plus", help: "Stage untracked without content", action: onStageWithoutContentAll)
                    .disabled(operationState != nil || untrackedEntries.isEmpty)
                if !resolvedConflictPaths.isEmpty {
                    Menu {
                        ForEach(resolvedConflictPaths, id: \.self) { path in
                            Button("Revert \(path)") { onRevertResolved(path) }
                        }
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 22, height: 22)
                    }
                    .menuStyle(.borderlessButton)
                    .foregroundStyle(.secondary)
                    .help("Revert resolved conflict")
                }
                compactButton("tray.and.arrow.down", help: "Stash changes silently", action: onStashSilently)
                    .disabled(operationState != nil || visibleChangedCount == 0)
                Menu {
                    Toggle("Group by Directory", isOn: $groupByDirectory)
                    Divider()
                    Toggle("Show Ignored", isOn: $showIgnored)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(.secondary)
                .help("Stage view settings")
                compactButton("list.bullet.indent", help: "New Changelist", action: onCreateChangeList)
                // GitStagePanel appends TreeActionsToolbarPanel to the stage
                // toolbar. These are first-class toolbar actions in rebased,
                // not settings-menu-only commands: they must work while the
                // tree has focus and remain discoverable beside the other
                // stage actions.
                compactButton("chevron.down", help: "Expand All", action: {
                    treeExpansionTarget = true
                    treeExpansionCommand += 1
                })
                compactButton("chevron.up", help: "Collapse All", action: {
                    treeExpansionTarget = false
                    treeExpansionCommand += 1
                })
                Spacer()
                if isShowingCachedStatusSnapshot {
                    ProgressView()
                        .controlSize(.small)
                        .help("Refreshing cached changes")
                }
                if isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            HStack {
                Text("Changes")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(visibleChangedCount) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if showIgnored, !ignoredEntries.isEmpty {
                    Text("· \(ignoredEntries.count) ignored")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            ScrollView {
                // The change list is the one place that can hold thousands of
                // rows (a full worktree of edits). A lazy stack keeps row
                // views, checkboxes and context menus bounded to the visible
                // range instead of materializing every change.
                LazyVStack(alignment: .leading, spacing: 4) {
                    if !conflictedEntries.isEmpty {
                        RebasedConflictGroup(
                            entries: conflictedEntries,
                            onOpen: onOpenConflict
                        )
                    }
                    changeGroups
                    if !standaloneUnversionedEntries.isEmpty {
                        RebasedChangeGroup(
                            title: "Unversioned Files",
                            entries: standaloneUnversionedEntries,
                            changeListName: visibleChangeLists.first(where: { $0.isDefault })?.name ?? "Default",
                            changeLists: visibleChangeLists,
                            emptyLabel: "No files",
                            statusKind: { $0.unstaged },
                            isChecked: { _ in false },
                            onToggle: { entry, checked in
                                if checked { onStage(entry.path) } else { onUnstage(entry.path) }
                            },
                            onStageWithoutContent: onStageWithoutContent,
                            onSelect: onSelect,
                            onPreviewPath: onPreviewPath,
                            onShowDiffPath: onShowDiffPath,
                            onShowLocalStagedDiffPath: onShowLocalStagedDiffPath,
                            onShowLocalVersionPath: onShowLocalVersionPath,
                            onShowStagedVersionPath: onShowStagedVersionPath,
                            onShowStagedDiffPath: onShowStagedDiffPath,
                            onShowThreeVersionsPath: onShowThreeVersionsPath,
                            selectedPath: previewPath,
                            onPartial: onPartial,
                            binaryPaths: binaryPaths,
                            lfsTrackedPaths: lfsTrackedPaths,
                            lfsPointerPaths: lfsPointerPaths,
                            stagingPresence: stagingPresence,
                            contextSelectedPaths: $contextSelectedPaths,
                            contextEligiblePaths: contextEligiblePaths,
                            onIgnore: onIgnore,
                            onExclude: onExclude,
                            repositoryWorkdir: repositoryWorkdir,
                            onRestore: onRestore,
                            groupByDirectory: groupByDirectory,
                            expansionCommand: treeExpansionCommand,
                            expansionTarget: treeExpansionTarget,
                            onDropPaths: { paths in paths.forEach(onStage) },
                            onDropShelf: onUnshelve,
                            onDropShelfIntoChangeList: onUnshelveIntoChangeList,
                            onMovePathsToChangeList: onMovePathsToChangeList,
                            onStashPaths: onStashPaths,
                            onShowHistory: onShowHistory,
                            onEditGitignore: onEditGitignore,
                            onEditGitExclude: onEditGitExclude
                        )
                    }
                    if showIgnored {
                        RebasedIgnoredGroup(
                            entries: ignoredEntries,
                            rules: ignoredRules,
                            onStage: onStage
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// GitStagePanel's second splitter component: commit message and actions.
    var commitEditorPanel: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 8) {
                Toggle("Amend", isOn: $amendMode)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .disabled(operationState != nil && !canAmendPausedRebase)
                Text("Last commit")
                    .font(.caption)
                    .foregroundStyle(.blue)
                if canAmendPausedRebase {
                    Label("Rebase edit", systemImage: "pencil.line")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("Stage the changes for this paused commit, then Amend before continuing the rebase.")
                }
                Menu {
                    if recentMessages.isEmpty {
                        Text("No recent commit messages")
                    } else {
                        ForEach(recentMessages, id: \.self) { message in
                            Button(message) { commitMessage = message }
                        }
                    }
                } label: {
                    Image(systemName: "clock")
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            TextEditor(text: $commitMessage)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 66, maxHeight: 92)
                .background(Design.Colors.chromeInset, in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if commitMessage.isEmpty {
                        Text("Commit message")
                            .foregroundStyle(.secondary)
                            .padding(.leading, 16)
                            .padding(.top, 16)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)

            HStack(spacing: 8) {
                Button("Template", action: onTemplate)
                Menu {
                    Button("Template") { onTemplate() }
                    Button("Before Commit Checks") { onBeforeCommitSettings() }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                Spacer()
                Toggle(
                    "Skip hooks",
                    isOn: Binding(
                        get: { skipHooks || alwaysSkipCommitHooks },
                        set: { skipHooks = $0 }
                    )
                )
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .disabled(alwaysSkipCommitHooks)
                Button(amendMode ? "Amend" : "Commit", action: onCommit)
                    .buttonStyle(.bordered)
                    .disabled(
                        repo == nil
                            || !hasStaged
                            || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || (operationState != nil && (!canAmendPausedRebase || !amendMode))
                    )
                if !amendMode && !hasStaged && hasCommitAllEligibleChanges {
                    Button("Commit All") {
                        showCommitAllConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(operationState != nil || repo == nil || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if autoSquashCommitKind != nil {
                    Button("Commit and Rebase", action: onCommitAndRebase)
                        .buttonStyle(.borderedProminent)
                        .disabled(operationState != nil || repo == nil || amendMode || !hasStaged || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Button("Commit and Push…", action: onCommitAndPush)
                    .buttonStyle(.bordered)
                    .disabled(operationState != nil || repo == nil || amendMode || !hasStaged || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if let commitFeedback {
                Text(commitFeedback)
                    .font(.caption)
                    .foregroundStyle(commitFeedback.hasPrefix("已") ? .green : .red)
                    .lineLimit(1)
                    .padding(.bottom, 7)
            }
        }
    }

    /// GitStageTree's model creates staged before unstaged when both contain
    /// files. With an empty/one-sided tree the reference UI keeps the stable
    /// Unstaged → Staged order, which is also what the empty state displays.
    @ViewBuilder
    var changeGroups: some View {
        ForEach(visibleChangeLists, id: \.name) { list in
            RebasedChangeListHeader(
                list: list,
                onRename: onRenameChangeList,
                onDelete: onDeleteChangeList,
                onActivate: onActivateChangeList,
                onMovePaths: onMovePathsToChangeList,
                onDropShelfIntoChangeList: onUnshelveIntoChangeList
            )
            let listUnstaged = entries(unstagedEntries, in: list)
            let listStaged = entries(stagedEntries, in: list)
            if !listUnstaged.isEmpty {
                unstagedChangeGroup(for: list, entries: listUnstaged)
            }
            if !listStaged.isEmpty {
                stagedChangeGroup(for: list, entries: listStaged)
            }
            if listUnstaged.isEmpty && listStaged.isEmpty {
                Text("No files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
            }
        }
    }

    func unstagedChangeGroup(for list: ChangeListInfo, entries: [FileEntry]) -> some View {
        RebasedChangeGroup(
            title: "Unstaged Files",
            entries: entries,
            changeListName: list.name,
            changeLists: visibleChangeLists,
            emptyLabel: "No files",
            statusKind: { $0.unstaged },
            // This checkbox stages the currently unstaged side of the file.
            // A partially staged file can appear in both groups, so this must
            // not mirror the staged bit here.
            isChecked: { _ in false },
            onToggle: { entry, checked in
                if checked { onStage(entry.path) } else { onUnstage(entry.path) }
            },
            onStageWithoutContent: onStageWithoutContent,
            onSelect: onSelect,
            onPreviewPath: onPreviewPath,
            onShowDiffPath: onShowDiffPath,
            onShowLocalStagedDiffPath: onShowLocalStagedDiffPath,
            onShowLocalVersionPath: onShowLocalVersionPath,
            onShowStagedVersionPath: onShowStagedVersionPath,
            onShowStagedDiffPath: onShowStagedDiffPath,
            onShowThreeVersionsPath: onShowThreeVersionsPath,
            selectedPath: previewPath,
            onPartial: onPartial,
            binaryPaths: binaryPaths,
            lfsTrackedPaths: lfsTrackedPaths,
            lfsPointerPaths: lfsPointerPaths,
            stagingPresence: stagingPresence,
            contextSelectedPaths: $contextSelectedPaths,
            contextEligiblePaths: contextEligiblePaths,
            onIgnore: onIgnore,
            onExclude: onExclude,
            repositoryWorkdir: repositoryWorkdir,
            onRestore: onRestore,
            groupByDirectory: groupByDirectory,
            expansionCommand: treeExpansionCommand,
            expansionTarget: treeExpansionTarget,
            onDropPaths: { paths in paths.forEach(onUnstage) },
            onDropShelf: onUnshelve,
            onDropShelfIntoChangeList: onUnshelveIntoChangeList,
            onMovePathsToChangeList: onMovePathsToChangeList,
            onStashPaths: onStashPaths,
            onShowHistory: onShowHistory,
            onEditGitignore: onEditGitignore,
            onEditGitExclude: onEditGitExclude
        )
    }

    func stagedChangeGroup(for list: ChangeListInfo, entries: [FileEntry]) -> some View {
        RebasedChangeGroup(
            title: "Staged Files",
            entries: entries,
            changeListName: list.name,
            changeLists: visibleChangeLists,
            emptyLabel: "No files",
            statusKind: { $0.staged },
            isChecked: { _ in true },
            onToggle: { entry, checked in
                if !checked { onUnstage(entry.path) }
            },
            onStageWithoutContent: onStageWithoutContent,
            onSelect: onSelect,
            onPreviewPath: onPreviewPath,
            onShowDiffPath: onShowDiffPath,
            onShowLocalStagedDiffPath: onShowLocalStagedDiffPath,
            onShowLocalVersionPath: onShowLocalVersionPath,
            onShowStagedVersionPath: onShowStagedVersionPath,
            onShowStagedDiffPath: onShowStagedDiffPath,
            onShowThreeVersionsPath: onShowThreeVersionsPath,
            selectedPath: previewPath,
            onPartial: onPartial,
            binaryPaths: binaryPaths,
            lfsTrackedPaths: lfsTrackedPaths,
            lfsPointerPaths: lfsPointerPaths,
            stagingPresence: stagingPresence,
            contextSelectedPaths: $contextSelectedPaths,
            contextEligiblePaths: contextEligiblePaths,
            onIgnore: onIgnore,
            onExclude: onExclude,
            repositoryWorkdir: repositoryWorkdir,
            onRestore: onRestore,
            groupByDirectory: groupByDirectory,
            expansionCommand: treeExpansionCommand,
            expansionTarget: treeExpansionTarget,
            onDropPaths: { paths in paths.forEach(onStage) },
            onDropShelf: onUnshelve,
            onDropShelfIntoChangeList: onUnshelveIntoChangeList,
            onMovePathsToChangeList: onMovePathsToChangeList,
            onStashPaths: onStashPaths,
            onShowHistory: onShowHistory,
            onEditGitignore: onEditGitignore,
            onEditGitExclude: onEditGitExclude
        )
    }

    var stashContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onStash) {
                    Label("Stash…", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Refresh Stashes")
                Spacer()
                Toggle(isOn: $stashSplitPreviewEnabled) {
                    Image(systemName: "rectangle.split.2x1")
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(stashSplitPreviewEnabled ? "Hide split preview" : "Show split preview")
                Button("Clear All", role: .destructive) {
                    showClearStashesConfirmation = true
                }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(stashes.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if isShelfPreviewVisible || (isStashPreviewVisible && stashSplitPreviewEnabled) {
                HSplitView {
                    stashList
                        .frame(minWidth: 170, idealWidth: 220, maxWidth: 300)
                    Group {
                        if isStashPreviewVisible {
                            stashDiffPreview
                        } else {
                            PatchDiffPreviewView(
                                title: shelfPreviewTitle,
                                diffText: shelfDiffText,
                                repo: repo,
                                shelfRepo: shelfRepo,
                                shelfRootPath: shelfRootPath,
                                commitID: shelfPreviewID,
                                stashID: nil,
                                shelfName: shelfPreviewName,
                                isDeletedShelf: shelfPreviewIsDeleted,
                                onClose: {
                                    isShelfPreviewVisible = false
                                    shelfPreviewName = nil
                                    shelfPreviewIsDeleted = false
                                }
                            )
                        }
                    }
                    .frame(minWidth: 180, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                stashList
            }
        }
        .sheet(
            isPresented: Binding(
                get: {
                    isStashPreviewVisible
                        && !stashSplitPreviewEnabled
                        && resolvedStashPreviewIndex != nil
                },
                set: { isPresented in
                    guard !isPresented else { return }
                    isStashPreviewVisible = false
                    stashPreviewStashID = nil
                }
            )
        ) {
            stashDiffPreview
                .frame(minWidth: 720, minHeight: 480)
        }
    }

    var stashDiffPreview: some View {
        PatchDiffPreviewView(
            title: stashPreviewTitle,
            diffText: stashDiffText,
            repo: repo,
            shelfRepo: nil,
            shelfRootPath: nil,
            commitID: nil,
            stashID: stashPreviewStashID,
            shelfName: nil,
            isDeletedShelf: false,
            onClose: {
                isStashPreviewVisible = false
                stashPreviewStashID = nil
            }
        )
    }

    func applyShowShelfRequest(_ requestID: Int) {
        guard requestID > 0, requestID != lastAppliedShelfRequestID else { return }
        lastAppliedShelfRequestID = requestID
        tab = .stash
        onWorkspaceTabChange(true)
    }

    var stashPreviewTitle: String {
        guard let index = resolvedStashPreviewIndex else {
            return String(localized: "Stash Diff")
        }
        let stash = stashes[index]
        let label = stash.message.isEmpty ? stash.shortId : stash.message
        return String(localized: "Stash Diff") + " · " + label
    }

    var resolvedStashPreviewIndex: Int? {
        guard let stashPreviewStashID else { return nil }
        return stashIndex(forID: stashPreviewStashID, in: stashes)
    }

    var shelfPreviewTitle: String {
        guard let name = shelfPreviewName else {
            return String(localized: "Shelf Diff")
        }
        return String(localized: "Shelf Diff") + " · " + name
    }

    var shelfPreviewID: String? {
        guard let name = shelfPreviewName else { return nil }
        return shelves.first(where: { $0.name == name })?.id
            ?? deletedShelves.first(where: { $0.name == name })?.id
    }

    var stashList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                stashSection
                shelfSection
            }
            .padding(12)
        }
    }

    var stashSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                guard !stashes.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    stashesExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: stashes.isEmpty || !stashesExpanded ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.bold))
                    Text("Stashes")
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(stashes.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            if stashes.isEmpty {
                Text("No stashed changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
            } else if stashesExpanded {
                ForEach(stashes, id: \.id) { stash in
                    HStack(spacing: 7) {
                        Image(systemName: "tray.full")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(stash.message.isEmpty ? "WIP" : stash.message)
                                .lineLimit(1)
                            Text(stash.shortId)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Menu {
                            Button("Apply (Keep)") { onApplyStash(stash.id, false) }
                            Button("Apply + Restore Index (Keep)") { onApplyStash(stash.id, true) }
                            Button("Pop (Apply and Remove)") { onPopStash(stash.id, false) }
                            Button("Pop + Restore Index") { onPopStash(stash.id, true) }
                            Button("Unstash As…") { onUnstashAs(stash.id) }
                            Button("Create Branch from Stash…") { onStashBranch(stash.id) }
                            Button("View Diff") { onStashDiffPreview(stash.id) }
                            Divider()
                            Button("Drop", role: .destructive) { onDropStash(stash.id) }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 24, height: 24)
                        }
                        .menuStyle(.borderlessButton)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 5)
                    .background(
                        selectedStashID == stash.id || stashPreviewStashID == stash.id
                            ? Color.accentColor.opacity(0.16)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedStashID = stash.id
                        if stashSplitPreviewEnabled {
                            onStashDiffPreview(stash.id)
                        }
                    }
                }
            }
        }
        .onChange(of: stashes.map(\.id), initial: false) { _, ids in
            if let selectedStashID, !ids.contains(selectedStashID) {
                self.selectedStashID = nil
            }
            if let stashPreviewStashID, !ids.contains(stashPreviewStashID) {
                self.stashPreviewStashID = nil
                self.isStashPreviewVisible = false
            }
        }
        .onDeleteCommand {
            guard let selectedStashID,
                  stashes.contains(where: { $0.id == selectedStashID }) else { return }
            self.selectedStashID = nil
            onDropStash(selectedStashID)
        }
    }

    func toggleShelfExpansion(_ id: String) {
        if expandedShelfIDs.contains(id) {
            expandedShelfIDs.remove(id)
        } else {
            expandedShelfIDs.insert(id)
        }
    }

    func beginShelfRename(_ shelf: ShelveInfo) {
        guard canMutateShelfMetadata else { return }
        editingShelfID = shelf.id
        editingShelfDescription = shelfDisplayDescription(shelf)
        DispatchQueue.main.async {
            focusedShelfID = shelf.id
        }
    }

    func cancelShelfRename() {
        editingShelfID = nil
        editingShelfDescription = ""
        focusedShelfID = nil
    }

    func commitShelfRename(_ shelf: ShelveInfo) {
        guard canMutateShelfMetadata,
              editingShelfID == shelf.id else { return }
        let description = editingShelfDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldDescription = shelfDisplayDescription(shelf)
        cancelShelfRename()
        guard !description.isEmpty, description != oldDescription else { return }
        onRenameShelveDescription(shelf.name, description)
    }

    func handleShelfRenameKeyPress() -> KeyPress.Result {
        guard editingShelfID == nil else { return .ignored }
        let selected: ShelveInfo? = if selectedShelfIDs.count == 1 {
            shelves.first { selectedShelfIDs.contains($0.id) }
        } else if selectedDeletedShelfIDs.count == 1 {
            deletedShelves.first { selectedDeletedShelfIDs.contains($0.id) }
        } else {
            nil
        }
        guard let selected else { return .ignored }
        beginShelfRename(selected)
        return .handled
    }

    var shelfRenameKeyEquivalent: KeyEquivalent {
        KeyEquivalent(Character(UnicodeScalar(NSF2FunctionKey)!))
    }

    func shelfFolderID(shelfID: String, path: String) -> String {
        "\(shelfID)\u{1F}\(path)"
    }

    func toggleShelfFolder(_ shelfID: String, _ path: String) {
        let id = shelfFolderID(shelfID: shelfID, path: path)
        if collapsedShelfFolders.contains(id) {
            collapsedShelfFolders.remove(id)
        } else {
            collapsedShelfFolders.insert(id)
        }
    }

    func visibleShelfRows(for shelf: ShelveInfo) -> [ShelfTreeRow] {
        let rows = shelfTreeRows(paths: shelf.paths, groupByDirectory: shelfGroupByDirectory)
        guard shelfGroupByDirectory else { return rows }
        return rows.filter { row in
            !rows.contains { folder in
                folder.isFolder
                    && row.path.hasPrefix(folder.path + "/")
                    && collapsedShelfFolders.contains(
                        shelfFolderID(shelfID: shelf.id, path: folder.path)
                    )
            }
        }
    }

    func selectedShelfPaths(for shelf: ShelveInfo) -> [String] {
        shelf.paths.filter {
            selectedShelfMemberIDs.contains(shelfMemberSelectionID(shelfID: shelf.id, path: $0))
        }
    }

    func requestUnshelve(_ shelf: ShelveInfo, paths: [String]? = nil) {
        pendingUnshelve = ShelfUnshelveRequest(
            name: shelf.name,
            paths: paths,
            rootPath: selectedShelfRootPath
        )
    }

    func selectShelf(_ shelfID: String) {
        if NSEvent.modifierFlags.contains(.command) {
            if selectedShelfIDs.contains(shelfID) {
                selectedShelfIDs.remove(shelfID)
            } else {
                selectedShelfIDs.insert(shelfID)
            }
        } else {
            selectedShelfIDs = [shelfID]
        }
    }

    func selectShelfMember(_ shelfID: String, _ path: String) {
        let id = shelfMemberSelectionID(shelfID: shelfID, path: path)
        if NSEvent.modifierFlags.contains(.command) {
            if selectedShelfMemberIDs.contains(id) {
                selectedShelfMemberIDs.remove(id)
            } else {
                selectedShelfMemberIDs.insert(id)
            }
        } else {
            selectedShelfMemberIDs = [id]
        }
    }

    /// IntelliJ exposes the Shelf tree through a DeleteProvider, so Delete
    /// must use the current tree selection rather than only the visible menu
    /// button. A list selection takes precedence over child selections from
    /// that list; selections from different lists are all preserved.
    func deleteSelectedShelfItems() {
        guard canMutateShelfMetadata else { return }
        let plan = shelfDeletePlan(
            visibleShelves: visibleShelves,
            deletedShelves: deletedShelves,
            selectedShelfIDs: selectedShelfIDs,
            selectedShelfMemberIDs: selectedShelfMemberIDs,
            selectedDeletedShelfIDs: selectedDeletedShelfIDs,
            selectedDeletedShelfMemberIDs: selectedDeletedShelfMemberIDs
        )
        guard !plan.isEmpty else { return }

        selectedShelfIDs.removeAll()
        selectedShelfMemberIDs.removeAll()
        selectedDeletedShelfIDs.removeAll()
        selectedDeletedShelfMemberIDs.removeAll()

        // IntelliJ's DeleteProvider submits one mixed plan to
        // ShelvedChangesViewManager. Keep this as one callback so the
        // operation layer can serialize all four scopes and publish one
        // notification/undo lifecycle.
        onDeleteShelfPlan(plan)
    }

    func selectDeletedShelf(_ shelfID: String) {
        if NSEvent.modifierFlags.contains(.command) {
            if selectedDeletedShelfIDs.contains(shelfID) {
                selectedDeletedShelfIDs.remove(shelfID)
            } else {
                selectedDeletedShelfIDs.insert(shelfID)
            }
        } else {
            selectedDeletedShelfIDs = [shelfID]
        }
    }

    func selectedDeletedShelfPaths(for shelf: ShelveInfo) -> [String] {
        shelf.paths.filter {
            selectedDeletedShelfMemberIDs.contains(
                shelfMemberSelectionID(shelfID: shelf.id, path: $0)
            )
        }
    }

    func selectDeletedShelfMember(_ shelfID: String, _ path: String) {
        let id = shelfMemberSelectionID(shelfID: shelfID, path: path)
        if NSEvent.modifierFlags.contains(.command) {
            if selectedDeletedShelfMemberIDs.contains(id) {
                selectedDeletedShelfMemberIDs.remove(id)
            } else {
                selectedDeletedShelfMemberIDs.insert(id)
            }
        } else {
            selectedDeletedShelfMemberIDs = [id]
        }
    }

    func unshelveDeletedMember(
        _ name: String,
        paths: [String],
        removeApplied: Bool
    ) {
        selectedDeletedShelfMemberIDs.removeAll()
        onUnshelveDeletedPathsWithOptions(name, paths, removeApplied)
    }

    @ViewBuilder
    func shelfMemberContextMenu(for shelf: ShelveInfo, path: String) -> some View {
        Button("Unshelve Changes") {
            onUnshelvePathsWithOptions(shelf.name, [path], false)
        }
        .disabled(!canApplyShelfWorktree)
        Button("Unshelve Changes and Remove") {
            onUnshelvePathsWithOptions(shelf.name, [path], true)
        }
        .disabled(!canApplyShelfWorktree)
        Divider()
        Button("Unshelve") {
            requestUnshelve(shelf, paths: [path])
        }
        .disabled(!canApplyShelfWorktree)
        Button("Drop", role: .destructive) {
            onDropShelvePaths(shelf.name, [path])
        }
        .disabled(!canMutateShelfMetadata)
        if visibleShelves.count > 1 {
            Menu("Move to Shelf") {
                ForEach(visibleShelves, id: \.id) { target in
                    if target.name != shelf.name {
                        Button(target.name) {
                            onMoveShelfPaths(shelf.name, target.name, [path])
                        }
                        .disabled(!canMutateShelfMetadata)
                    }
                }
            }
        }
    }

    @ViewBuilder
    func deletedShelfMemberContextMenu(for shelf: ShelveInfo, path: String) -> some View {
        Button("Unshelve Changes") {
            unshelveDeletedMember(shelf.name, paths: [path], removeApplied: false)
        }
        .disabled(!canApplyShelfWorktree)
        Button("Unshelve Changes and Remove") {
            unshelveDeletedMember(shelf.name, paths: [path], removeApplied: true)
        }
        .disabled(!canApplyShelfWorktree)
        let selectedPaths = selectedDeletedShelfPaths(for: shelf)
        if selectedPaths.count > 1 {
            Divider()
            Button("Unshelve Selected Changes") {
                unshelveDeletedMember(shelf.name, paths: selectedPaths, removeApplied: false)
            }
            .disabled(!canApplyShelfWorktree)
            Button("Unshelve Selected Changes and Remove") {
                unshelveDeletedMember(shelf.name, paths: selectedPaths, removeApplied: true)
            }
            .disabled(!canApplyShelfWorktree)
        }
        Divider()
        let pathsToDelete = selectedPaths.contains(path) ? selectedPaths : [path]
        Button(
            pathsToDelete.count > 1 ? "Delete Selected Permanently" : "Delete Permanently",
            role: .destructive
        ) {
            onDeleteDeletedShelfPaths(shelf.name, pathsToDelete)
        }
        .disabled(!canMutateShelfMetadata)
        Button("View Diff") { onShelveDiffPreview(shelf.name) }
    }

    @ViewBuilder
    func shelfTreeRowView(_ row: ShelfTreeRow, shelf: ShelveInfo) -> some View {
        if row.isFolder {
            Button {
                toggleShelfFolder(shelf.id, row.path)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsedShelfFolders.contains(
                        shelfFolderID(shelfID: shelf.id, path: row.path)
                    ) ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.bold))
                    Image(systemName: "folder")
                        .font(.caption2)
                    Text(row.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.leading, 34 + CGFloat(row.depth * 14))
            .padding(.vertical, 2)
        } else {
            let selected = selectedShelfMemberIDs.contains(
                shelfMemberSelectionID(shelfID: shelf.id, path: row.path)
            )
            Button {
                selectShelfMember(shelf.id, row.path)
                onShelveDiffPreview(shelf.name)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(row.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.leading, 34 + CGFloat(row.depth * 14))
            .padding(.vertical, 2)
            .background(
                selected ? Color.accentColor.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
            .draggable("arbor-shelf-member:\(shelf.name)\u{1F}\(row.path)")
            .contextMenu {
                shelfMemberContextMenu(for: shelf, path: row.path)
            }
        }
    }

    func moveDroppedShelfMember(_ payloads: [String], to targetShelfName: String) -> Bool {
        guard canMutateShelfMetadata else { return false }
        guard let payload = payloads.first(where: {
            $0.hasPrefix("arbor-shelf-member:")
        }) else { return false }
        let body = String(payload.dropFirst("arbor-shelf-member:".count))
        let components = body.split(separator: "\u{1F}", maxSplits: 1)
        guard components.count == 2 else { return false }
        let sourceShelfName = String(components[0])
        let path = String(components[1])
        guard sourceShelfName != targetShelfName else { return false }
        onMoveShelfPaths(sourceShelfName, targetShelfName, [path])
        return true
    }

    @ViewBuilder
    func shelfItemView(_ shelf: ShelveInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Button {
                    selectShelf(shelf.id)
                } label: {
                    Image(systemName: selectedShelfIDs.contains(shelf.id)
                        ? "checkmark.circle.fill"
                        : "circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    selectedShelfIDs.contains(shelf.id)
                        ? Color.accentColor
                        : Color.secondary
                )
                Button {
                    toggleShelfExpansion(shelf.id)
                } label: {
                    Image(systemName: expandedShelfIDs.contains(shelf.id) ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                        .frame(width: 14, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Image(systemName: shelf.isRecycled ? "arrow.uturn.backward.circle" : "archivebox")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    shelfTitleView(shelf)
                    HStack(spacing: 6) {
                        Text(shelf.shortId)
                            .font(.system(size: 10, design: .monospaced))
                        Text("· \(shelf.paths.count) files")
                            .font(.caption2)
                        if !shelfTimestampLabel(shelf.timestamp).isEmpty {
                            Text("· \(shelfTimestampLabel(shelf.timestamp))")
                                .font(.caption2)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Menu {
                    Button("Apply (Keep)") {
                        onUnshelve(shelf.name)
                    }
                    .disabled(!canApplyShelfWorktree)
                    Button("Pop (Apply and Remove)") {
                        onPopShelve(shelf.name)
                    }
                    .disabled(!canApplyShelfWorktree)
                    Divider()
                    Button("View Diff") { onShelveDiffPreview(shelf.name) }
                    Button("Export Patch…") { onExportShelve(shelf.name) }
                        .disabled(!canMutateShelfMetadata)
                    Button("Rename…") {
                        onRenameShelve(shelf.name, shelfDisplayDescription(shelf))
                    }
                    .disabled(!canMutateShelfMetadata)
                    Button("Unshelve") { requestUnshelve(shelf) }
                        .disabled(!canApplyShelfWorktree)
                    if !selectedShelfPaths(for: shelf).isEmpty {
                        Divider()
                        Button("Unshelve Selected Changes") {
                            onUnshelvePathsWithOptions(
                                shelf.name,
                                selectedShelfPaths(for: shelf),
                                false
                            )
                        }
                        .disabled(!canApplyShelfWorktree)
                        Button("Unshelve Selected Changes and Remove") {
                            onUnshelvePathsWithOptions(
                                shelf.name,
                                selectedShelfPaths(for: shelf),
                                true
                            )
                        }
                        .disabled(!canApplyShelfWorktree)
                        Button("Unshelve Selected") {
                            requestUnshelve(shelf, paths: selectedShelfPaths(for: shelf))
                        }
                        .disabled(!canApplyShelfWorktree)
                        Button("Drop Selected", role: .destructive) {
                            onDropShelvePaths(shelf.name, selectedShelfPaths(for: shelf))
                        }
                        .disabled(!canMutateShelfMetadata)
                    }
                    Button("Drop", role: .destructive) { onDropShelve(shelf.name) }
                        .disabled(!canMutateShelfMetadata)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 5)
            .background(
                shelfPreviewName == shelf.name
                    ? Color.accentColor.opacity(0.16)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
            .contentShape(Rectangle())
            .draggable("arbor-shelf:\(shelf.name)")
            .dropDestination(for: String.self) { payloads, _ in
                moveDroppedShelfMember(payloads, to: shelf.name)
            }
            .onTapGesture { onShelveDiffPreview(shelf.name) }

            if expandedShelfIDs.contains(shelf.id) {
                ForEach(visibleShelfRows(for: shelf)) { row in
                    shelfTreeRowView(row, shelf: shelf)
                }
            }
        }
    }

    @ViewBuilder
    func deletedShelfTreeRowView(_ row: ShelfTreeRow, shelf: ShelveInfo) -> some View {
        if row.isFolder {
            Button {
                toggleShelfFolder(shelf.id, row.path)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsedShelfFolders.contains(
                        shelfFolderID(shelfID: shelf.id, path: row.path)
                    ) ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.bold))
                    Image(systemName: "folder")
                        .font(.caption2)
                    Text(row.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.leading, 55 + CGFloat(row.depth * 14))
            .padding(.vertical, 2)
        } else {
            let selected = selectedDeletedShelfMemberIDs.contains(
                shelfMemberSelectionID(shelfID: shelf.id, path: row.path)
            )
            Button {
                selectDeletedShelfMember(shelf.id, row.path)
                onShelveDiffPreview(shelf.name)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(row.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.leading, 55 + CGFloat(row.depth * 14))
            .padding(.vertical, 2)
            .background(
                selected ? Color.accentColor.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
            .contextMenu {
                deletedShelfMemberContextMenu(for: shelf, path: row.path)
            }
        }
    }

    @ViewBuilder
    func recentlyDeletedShelfSection() -> some View {
        if !deletedShelves.isEmpty {
            Divider()
                .padding(.vertical, 3)
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        deletedShelvesExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: deletedShelvesExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.bold))
                        Image(systemName: "trash")
                            .font(.caption2)
                        Text("Recently Deleted")
                            .font(.system(size: 12, weight: .semibold))
                        Text("\(deletedShelves.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .foregroundStyle(.secondary)

            if deletedShelvesExpanded {
                ForEach(deletedShelves, id: \.id) { shelf in
                    HStack(spacing: 7) {
                        Button {
                            selectDeletedShelf(shelf.id)
                        } label: {
                            Image(systemName: selectedDeletedShelfIDs.contains(shelf.id)
                                ? "checkmark.circle.fill"
                                : "circle")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(
                            selectedDeletedShelfIDs.contains(shelf.id)
                                ? Color.accentColor
                                : Color.secondary
                        )
                        Button {
                            toggleShelfExpansion(shelf.id)
                        } label: {
                            Image(systemName: expandedShelfIDs.contains(shelf.id)
                                ? "chevron.down"
                                : "chevron.right")
                                .font(.caption2.weight(.bold))
                                .frame(width: 14, height: 20)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        Image(systemName: "archivebox.fill")
                            .font(.caption)
                        .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            shelfTitleView(shelf)
                            HStack(spacing: 5) {
                                Text("\(shelf.paths.count) files")
                                if !shelfTimestampLabel(shelf.timestamp).isEmpty {
                                    Text("· \(shelfTimestampLabel(shelf.timestamp))")
                                }
                            }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Menu {
                            Button("Unshelve Silently") {
                                selectedDeletedShelfIDs.remove(shelf.id)
                                onUnshelveDeletedShelvesSilently(
                                    [shelf.name],
                                    removeAppliedFilesFromShelf
                                )
                            }
                            .disabled(!canApplyShelfWorktree)
                            let selectedPaths = selectedDeletedShelfPaths(for: shelf)
                            if !selectedPaths.isEmpty {
                                Divider()
                                Button("Unshelve Selected Changes") {
                                    unshelveDeletedMember(
                                        shelf.name,
                                        paths: selectedPaths,
                                        removeApplied: false
                                    )
                                }
                                .disabled(!canApplyShelfWorktree)
                                Button("Unshelve Selected Changes and Remove") {
                                    unshelveDeletedMember(
                                        shelf.name,
                                        paths: selectedPaths,
                                        removeApplied: true
                                    )
                                }
                                .disabled(!canApplyShelfWorktree)
                            }
                            Divider()
                            Button("Rename…") {
                                onRenameShelve(shelf.name, shelfDisplayDescription(shelf))
                            }
                            .disabled(!canMutateShelfMetadata)
                            Button("Restore") { onRestoreDeletedShelve(shelf.name) }
                                .disabled(!canMutateShelfMetadata)
                            Button("Delete Permanently", role: .destructive) {
                                onDeleteDeletedShelve(shelf.name)
                            }
                            .disabled(!canMutateShelfMetadata)
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 24, height: 24)
                        }
                        .menuStyle(.borderlessButton)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .padding(.leading, 20)

                    if expandedShelfIDs.contains(shelf.id) {
                        ForEach(visibleShelfRows(for: shelf)) { row in
                            deletedShelfTreeRowView(row, shelf: shelf)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    var shelfRows: some View {
        if visibleShelves.isEmpty {
            Text("No shelves")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
        } else if shelvesExpanded {
            ForEach(visibleShelves, id: \.id, content: shelfItemView)
        }
    }

    @ViewBuilder
    var selectedShelfActionsMenu: some View {
        let plan = shelfDeletePlan(
            visibleShelves: visibleShelves,
            deletedShelves: deletedShelves,
            selectedShelfIDs: selectedShelfIDs,
            selectedShelfMemberIDs: selectedShelfMemberIDs,
            selectedDeletedShelfIDs: selectedDeletedShelfIDs,
            selectedDeletedShelfMemberIDs: selectedDeletedShelfMemberIDs
        )
        if !plan.isEmpty {
            Menu {
                if !plan.activeShelfNames.isEmpty {
                    Button("Apply (Keep)") {
                        let names = plan.activeShelfNames
                        selectedShelfIDs.removeAll()
                        selectedShelfMemberIDs.removeAll()
                        onUnshelveShelvesSilently(names, false)
                    }
                    .disabled(!canApplyShelfWorktree)
                    Button("Pop (Apply and Remove)") {
                        let names = plan.activeShelfNames
                        selectedShelfIDs.removeAll()
                        selectedShelfMemberIDs.removeAll()
                        onPopShelves(names)
                    }
                    .disabled(!canApplyShelfWorktree)
                    Button("Drop Selected Shelves", role: .destructive) {
                        let names = plan.activeShelfNames
                        selectedShelfIDs.removeAll()
                        selectedShelfMemberIDs.removeAll()
                        onDropShelves(names)
                    }
                    .disabled(!canMutateShelfMetadata)
                    if plan.activeShelfNames.count > 1 {
                        Divider()
                        Button("Unshelve Selected Shelves…") {
                            pendingUnshelveShelves = ShelfBatchUnshelveRequest(
                                names: plan.activeShelfNames,
                                rootPath: selectedShelfRootPath
                            )
                        }
                        .disabled(!canApplyShelfWorktree)
                    }
                }
                if !plan.activePathGroups.isEmpty {
                    Divider()
                    if plan.activePathGroups.count > 1 {
                        Button("Unshelve Selected Changes into Changelist…") {
                            pendingUnshelveMemberGroups = ShelfMemberBatchUnshelveRequest(
                                groups: plan.activePathGroups,
                                rootPath: selectedShelfRootPath
                            )
                        }
                        .disabled(!canApplyShelfWorktree)
                    }
                    Button("Unshelve Selected Changes") {
                        selectedShelfMemberIDs.removeAll()
                        onUnshelvePathGroupsWithOptions(plan.activePathGroups, false, false)
                    }
                    .disabled(!canApplyShelfWorktree)
                    Button("Unshelve Selected Changes and Remove") {
                        selectedShelfMemberIDs.removeAll()
                        onUnshelvePathGroupsWithOptions(plan.activePathGroups, true, false)
                    }
                    .disabled(!canApplyShelfWorktree)
                    Button("Drop Selected Changes", role: .destructive) {
                        selectedShelfMemberIDs.removeAll()
                        onDropShelvePathGroups(plan.activePathGroups)
                    }
                    .disabled(!canMutateShelfMetadata)
                }
                if !plan.deletedShelfNames.isEmpty {
                    Divider()
                    Button("Unshelve Deleted Shelves Silently") {
                        let names = plan.deletedShelfNames
                        selectedDeletedShelfIDs.removeAll()
                        selectedDeletedShelfMemberIDs.removeAll()
                        onUnshelveDeletedShelvesSilently(
                            names,
                            removeAppliedFilesFromShelf
                        )
                    }
                    .disabled(!canApplyShelfWorktree)
                    .keyboardShortcut("u", modifiers: [.control, .option])
                    Button("Restore Selected") {
                        let names = plan.deletedShelfNames
                        selectedDeletedShelfIDs.removeAll()
                        onRestoreDeletedShelves(names)
                    }
                    .disabled(!canMutateShelfMetadata)
                    Button("Delete Permanently Selected", role: .destructive) {
                        let names = plan.deletedShelfNames
                        selectedDeletedShelfIDs.removeAll()
                        onDeleteDeletedShelves(names, true)
                    }
                    .disabled(!canMutateShelfMetadata)
                }
                if !plan.deletedPathGroups.isEmpty {
                    Divider()
                    Button("Unshelve Deleted Changes") {
                        selectedDeletedShelfMemberIDs.removeAll()
                        onUnshelvePathGroupsWithOptions(plan.deletedPathGroups, false, true)
                    }
                    .disabled(!canApplyShelfWorktree)
                    Button("Unshelve Deleted Changes and Remove") {
                        selectedDeletedShelfMemberIDs.removeAll()
                        onUnshelvePathGroupsWithOptions(plan.deletedPathGroups, true, true)
                    }
                    .disabled(!canApplyShelfWorktree)
                    Button("Delete Selected Permanently", role: .destructive) {
                        selectedDeletedShelfMemberIDs.removeAll()
                        onDeleteDeletedShelfPathGroups(plan.deletedPathGroups)
                    }
                    .disabled(!canMutateShelfMetadata)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(.secondary)
            .help("Actions for selected Shelves and changes")
        }
    }

    var shelfHeaderView: some View {
        HStack(spacing: 6) {
            Button {
                guard !visibleShelves.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    shelvesExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: visibleShelves.isEmpty || !shelvesExpanded ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.bold))
                    Text("Shelves")
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(visibleShelves.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            if shelfRootOptions.count > 1 {
                Picker("Shelf Root", selection: Binding(
                    get: { selectedShelfRootPath },
                    set: { onShelfRootChange($0) }
                )) {
                    ForEach(shelfRootOptions, id: \.path) { root in
                        let path = canonicalExternalLogPath(root.path)
                        Text(root.relativePath == "."
                            ? root.displayName
                            : root.displayName + " · " + root.relativePath)
                            .tag(path)
                            .help(path)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(maxWidth: 190)
                if isShelfRootLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Spacer()
            selectedShelfActionsMenu
            Menu {
                Button("Import Patches…") { onImportShelve(shelfRootPath) }
                    .disabled(!canMutateShelfMetadata)
                Divider()
                Toggle("Group by Directory", isOn: $shelfGroupByDirectory)
                    Toggle("Show Already Unshelved", isOn: showRecycledShelvesBinding)
                Divider()
                Button("Clear Already Unshelved", role: .destructive) {
                    onCleanRecycledShelves()
                }
                .disabled(!canMutateShelfMetadata
                    || !shelves.contains(where: \.isRecycled))
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(.secondary)
            .help("Shelf view settings")
        }
    }

    var shelfSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            shelfHeaderView
            if isShelfRootReadOnly || shelfRootError != nil {
                HStack(spacing: 6) {
                    Image(systemName: isShelfRootReadOnly ? "lock" : "exclamationmark.triangle")
                    if isShelfRootReadOnly {
                        Text(canMutateShelfMetadata
                            ? "Secondary root: whole/member Apply, Pop, Unshelve, Drop, Restore, Delete, target-Changelist dialog, Patch import/export and recycled cleanup are available"
                            : "Secondary root is read-only until its Shelf repository is loaded")
                    } else if let shelfRootError {
                        Text(shelfRootError)
                            .lineLimit(2)
                    }
                }
                .font(.caption2)
                .foregroundStyle(isShelfRootReadOnly ? .secondary : Design.Colors.error)
                .padding(.horizontal, 22)
            }
            shelfRows

            recentlyDeletedShelfSection()
        }
        .onChange(of: shelves.map(\.id)) { _, ids in
            selectedShelfIDs.formIntersection(Set(ids))
        }
        .onChange(of: shelves.map { shelf in
            "\(shelf.id)\u{1E}\(shelf.paths.joined(separator: "\u{1F}"))"
        }) { _, _ in
            pruneShelfMemberSelection()
        }
        .onChange(of: deletedShelves.map(\.id)) { _, ids in
            selectedDeletedShelfIDs.formIntersection(Set(ids))
            pruneDeletedShelfMemberSelection()
        }
        .onChange(of: deletedShelves.map { shelf in
            "\(shelf.id)\u{1E}\(shelf.paths.joined(separator: "\u{1F}"))"
        }) { _, _ in
            pruneDeletedShelfMemberSelection()
        }
        .onKeyPress(shelfRenameKeyEquivalent, action: handleShelfRenameKeyPress)
        .onDeleteCommand(perform: deleteSelectedShelfItems)
        .dropDestination(for: String.self) { paths, _ in
            guard !isShelfRootReadOnly, !isShelfRootLoading else { return false }
            let changedPaths = Set(entries.map(\.path))
            let validPaths = paths.filter { changedPaths.contains($0) }
            guard !validPaths.isEmpty else { return false }
            onShelvePaths(validPaths)
            return true
        }
    }

    func pruneShelfMemberSelection() {
        let validMemberIDs = Set(
            shelves.flatMap { shelf in
                shelf.paths.map {
                    shelfMemberSelectionID(shelfID: shelf.id, path: $0)
                }
            }
        )
        selectedShelfMemberIDs.formIntersection(validMemberIDs)
    }

    func pruneDeletedShelfMemberSelection() {
        let validMemberIDs = Set(
            deletedShelves.flatMap { shelf in
                shelf.paths.map {
                    shelfMemberSelectionID(shelfID: shelf.id, path: $0)
                }
            }
        )
        selectedDeletedShelfMemberIDs.formIntersection(validMemberIDs)
    }

/// Stash/Shelf 的 diff 留在同一个 Saved Patches 工作区内，复用文件列表与
/// patch 承载区。两者都优先使用提交树的结构化 FileDiff，支持真正的
/// side-by-side/unified 切换；原始 patch 只作为 binary、路径解析或旧对象
/// 不可读取时的安全 fallback。
struct PatchDiffPreviewView: View {
    let title: String
    let diffText: String?
    let repo: Repository?
    let shelfRepo: Repository?
    let shelfRootPath: String?
    let commitID: String?
    let stashID: String?
    let shelfName: String?
    let isDeletedShelf: Bool
    let onClose: () -> Void
    @State var selectedFilePath: String?
    @State var structuredDiff: FileDiff?
    @State var structuredDiffError: String?
    @State var presentationMode: DiffPresentationMode = .sideBySide
    @State var compareShelfWithLocal = false

    struct PatchFile: Identifiable, Hashable {
        let path: String
        let patch: String

        var id: String { path }
    }

    var patchFiles: [PatchFile] {
        Self.parsePatchFiles(diffText ?? "")
    }

    var visiblePatch: String {
        guard let selectedFilePath,
              let file = patchFiles.first(where: { $0.path == selectedFilePath }) else {
            return diffText ?? ""
        }
        return file.patch
    }

    var supportsStructuredDiff: Bool {
        repo != nil && (commitID != nil || stashID != nil || shelfName != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if shelfName != nil {
                    Button {
                        compareShelfWithLocal.toggle()
                    } label: {
                        Label(
                            compareShelfWithLocal ? "View Diff" : "Compare with Local",
                            systemImage: "arrow.left.arrow.right"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Compare with Local")
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Hide patch preview")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Design.Colors.surface)

            if diffText != nil {
                if patchFiles.count > 1 {
                    HSplitView {
                        List(patchFiles, selection: $selectedFilePath) { file in
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.secondary)
                                Text(file.path)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .tag(file.path as String?)
                        }
                        .listStyle(.inset)
                        .frame(minWidth: 150, idealWidth: 210, maxWidth: 300)

                        selectedFilePreview
                    }
                } else {
                    selectedFilePreview
                }
            } else {
                ProgressView("Loading diff…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Design.Colors.canvas)
        .onChange(of: diffText) { _, _ in
            selectedFilePath = patchFiles.first?.path
        }
        .onChange(of: selectedFilePath) { _, path in
            loadStructuredDiff(path)
        }
        .onChange(of: commitID) { _, _ in
            loadStructuredDiff(selectedFilePath)
        }
        .onChange(of: stashID) { _, _ in
            loadStructuredDiff(selectedFilePath)
        }
        .onChange(of: shelfName) { _, _ in
            compareShelfWithLocal = false
            loadStructuredDiff(selectedFilePath)
        }
        .onChange(of: isDeletedShelf) { _, _ in
            loadStructuredDiff(selectedFilePath)
        }
        .onChange(of: compareShelfWithLocal) { _, _ in
            loadStructuredDiff(selectedFilePath)
        }
        .onAppear {
            compareShelfWithLocal = false
            selectedFilePath = patchFiles.first?.path
            loadStructuredDiff(patchFiles.first?.path)
        }
    }

    @ViewBuilder
    var selectedFilePreview: some View {
        if let structuredDiff {
            if structuredDiff.binary {
                patchTextView(visiblePatch)
            } else if structuredDiff.hunks.isEmpty {
                Text("No changes")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Picker("Diff View", selection: $presentationMode) {
                            ForEach(DiffPresentationMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Design.Colors.surface)
                    if presentationMode == .sideBySide {
                        SideBySideDiffView(fileDiff: structuredDiff)
                    } else {
                        UnifiedDiffView(fileDiff: structuredDiff)
                    }
                }
            }
        } else if let structuredDiffError {
            VStack(alignment: .leading, spacing: 8) {
                Label("Unable to load diff", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Design.Colors.error)
                Text(structuredDiffError)
                    .font(.caption)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                patchTextView(visiblePatch)
            }
            .padding(10)
        } else if supportsStructuredDiff, !patchFiles.isEmpty {
            ProgressView("Loading diff…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            patchTextView(visiblePatch)
        }
    }

    func loadStructuredDiff(_ path: String?) {
        structuredDiff = nil
        structuredDiffError = nil
        guard let repo, let path else { return }
        let expectedCommitID = commitID
        let expectedStashID = stashID
        let expectedShelfName = shelfName
        let expectedShelfRootPath = shelfRootPath
        let expectedIsDeletedShelf = isDeletedShelf
        let expectedCompareShelfWithLocal = compareShelfWithLocal
        let expectedPath = path
        Task.detached(priority: .userInitiated) {
            do {
                let diff: FileDiff
                if let expectedShelfName {
                    guard let shelfRepo else {
                        throw EngineError.GitOperation(message: "Shelf root repository is unavailable")
                    }
                    if expectedIsDeletedShelf {
                        diff = try shelfRepo.shelveDeletedFileDiffWithSettings(
                            name: expectedShelfName,
                            path: expectedPath,
                            withLocal: expectedCompareShelfWithLocal,
                            settings: makeArborGitDiffSettings()
                        )
                    } else {
                        diff = try shelfRepo.shelveFileDiffWithSettings(
                            name: expectedShelfName,
                            path: expectedPath,
                            withLocal: expectedCompareShelfWithLocal,
                            settings: makeArborGitDiffSettings()
                        )
                    }
                } else if let expectedStashID {
                    let currentStashes = try repo.stashList()
                    guard let currentIndex = currentStashes.firstIndex(where: { $0.id == expectedStashID }) else {
                        throw NSError(
                            domain: "Arbor.StashPreview",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "The selected stash no longer exists."]
                        )
                    }
                    diff = try repo.stashFileDiffWithSettings(
                        index: UInt32(currentIndex),
                        path: expectedPath,
                        settings: makeArborGitDiffSettings()
                    )
                } else if let expectedCommitID {
                    diff = try repo.commitFileDiffWithSettings(
                        commitId: expectedCommitID,
                        parentIndex: 0,
                        path: expectedPath,
                        settings: makeArborGitDiffSettings()
                    )
                } else {
                    return
                }
                await MainActor.run {
                    guard self.commitID == expectedCommitID,
                          self.stashID == expectedStashID,
                          self.shelfName == expectedShelfName,
                          self.shelfRootPath == expectedShelfRootPath,
                          self.isDeletedShelf == expectedIsDeletedShelf,
                          self.compareShelfWithLocal == expectedCompareShelfWithLocal,
                          self.selectedFilePath == expectedPath else { return }
                    self.structuredDiff = diff
                }
            } catch {
                await MainActor.run {
                    guard self.commitID == expectedCommitID,
                          self.stashID == expectedStashID,
                          self.shelfName == expectedShelfName,
                          self.shelfRootPath == expectedShelfRootPath,
                          self.isDeletedShelf == expectedIsDeletedShelf,
                          self.compareShelfWithLocal == expectedCompareShelfWithLocal,
                          self.selectedFilePath == expectedPath else { return }
                    self.structuredDiffError = "\(error)"
                }
            }
        }
    }

    func patchTextView(_ patch: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(patch.isEmpty ? "No changes" : patch)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(10)
        }
    }

    static func parsePatchFiles(_ patch: String) -> [PatchFile] {
        guard !patch.isEmpty else { return [] }
        var files: [PatchFile] = []
        var currentPath: String?
        var currentLines: [String] = []

        func flush() {
            guard let currentPath, !currentLines.isEmpty else { return }
            files.append(PatchFile(path: currentPath, patch: currentLines.joined(separator: "\n")))
        }

        for line in patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("diff --git ") {
                flush()
                currentPath = pathFromDiffHeader(line)
                currentLines = [line]
            } else if currentPath != nil {
                currentLines.append(line)
            }
        }
        flush()
        return files
    }

    static func pathFromDiffHeader(_ line: String) -> String? {
        // Git's normal header is `diff --git a/path b/path`. Use the second
        // side as the display path; rename/copy headers still get a useful
        // destination path. Quoted paths are unwrapped for presentation.
        guard let separator = line.range(of: " b/") else { return nil }
        let prefix = line[..<separator.lowerBound]
        guard prefix.hasPrefix("diff --git a/") else { return nil }
        let path = String(line[separator.upperBound...])
        return path.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}

    func compactButton(_ image: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    var rebasedBackground: Color {
        Design.Colors.canvas
    }

    var rebasedSurface: Color {
        Design.Colors.surface
    }
}
