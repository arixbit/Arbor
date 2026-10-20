import SwiftUI
import AppKit


struct ContentView: View {
    @Environment(\.openWindow) var openWindow

    /// Stash / Unstash 工作页状态（对话框、预览、请求身份）。
    @StateObject var stashUI = StashWorkspaceState()

    /// Log 列表与过滤状态（过滤条件、分页、当前 root）。
    @StateObject var logList = LogListState()

    /// Log 运行期数据（命令日志 / 签名 / 多 root 聚合 / 图命令）。
    @StateObject var logRuntime: LogRuntimeState

    /// Log 的选中 / 详情 / tab / 导航状态。
    @StateObject var logSelectionState: LogSelectionState

    /// Reflog 列表与详情。
    @StateObject var reflog = ReflogState()

    /// Log 左侧分支面板（分组 / 只看我的）。
    @StateObject var logBranchesPanel: LogBranchesPanelState

    /// Cherry-pick 对比（日志里「已被挑过」标记）。
    @StateObject var logCherryPick = LogCherryPickState()

    /// Reword / Squash 对话框。
    @StateObject var logRewrite = LogRewriteState()
    let externalLogWindow: Bool
    let initialExternalLogRootPaths: Set<String>
    let externalLogProviderSession: ExternalLogProviderSession?
    let externalLogUIManager: ExternalLogManager?
    let externalLogTabsPersistenceKey: String?
    @StateObject var feedbackCenter = FeedbackCenter()
    @StateObject var credentialAuth = CredentialAuthController()
    @State var projectPath: String?
    @State var projectRepo: Repository?
    @State var path: String = ""
    @State var toolWindowMode: ToolWindowMode = .commit
    // ContentView is also hosted by the AppKit fallback window used when a
    // repository path is passed on the command line. SceneStorage is only
    // valid inside a SwiftUI Scene and causes repeated runtime warnings (and
    // unstable bindings) in that path. AppStorage keeps the same user-facing
    // persistence while remaining valid for both scene and AppKit hosting.
    @AppStorage("arbor.toolWindowExpanded") var toolWindowExpanded = true
    // Rebased opens the Project tool window as a compact bar; expanding it is
    // an explicit user action. Use a versioned key so the old default=true
    // cannot keep reopening a large tree below the Commit/Stash workspace.
    @AppStorage("arbor.projectPanelExpanded.v2") var projectPanelExpanded = false
    @AppStorage("arbor.toolWindowHeight") var toolWindowHeight: Double = 320
    // The reference workspace uses a ~470pt Commit/Stash column at a
    // 1640pt window width, with the Log editor occupying the remaining area.
    // Rebased keeps Commit/Stash in the left tool-window column while Git Log
    // occupies the editor workspace on the right. The reference frame is
    // roughly 470pt / 1170pt at a 1640pt window width.
    // 460pt subview + the 12pt native divider gives the ~472pt visible column.
    @AppStorage("arbor.workspaceSidebarWidth.v10") var savedWorkspaceSidebarWidth: Double = 460
    // The Log editor has its own graph/details splitter. Its graph/table side
    // is the dominant column in the reference frame; the details inspector is
    // the narrower right-hand column.
    // 748pt subview + the 12pt native divider leaves the ~358pt inspector.
    @AppStorage("arbor.logGraphWidth.v5") var savedLogGraphWidth: Double = 748
    // These are the same three persistent Log presentation properties exposed
    // by rebased's VcsLog UI actions. They are deliberately state, not layout
    // hacks: changing them must not reload or replace the selected commit.
    @AppStorage("arbor.log.showDetails.v1") var logShowDetails = true
    @AppStorage("arbor.log.showDiffPreview.v1") var logShowDiffPreview = true
    @AppStorage("arbor.log.diffPreviewVertical.v1") var logDiffPreviewVertical = false
    @AppStorage("arbor.log.compactReferences.v2") var logCompactReferences = true
    @AppStorage("arbor.log.commitColumns.v1") var logShowCommitColumns = false
    @AppStorage("arbor.log.authorColumn.v1") var logShowAuthorColumn = false
    @AppStorage("arbor.log.dateColumn.v1") var logShowDateColumn = false
    @AppStorage("arbor.log.hashColumn.v1") var logShowHashColumn = false
    @AppStorage("arbor.log.rootColumn.v1") var logShowRootColumn = false
    @AppStorage("arbor.log.signatureColumn.v1") var logShowSignatureColumn = false
    @AppStorage("arbor.log.columnOrder.v1") var logColumnOrderRaw = LogColumnLayout.defaultOrder.map(\.rawValue).joined(separator: ",")
    @AppStorage("arbor.log.columnWidths.v1") var logColumnWidthsRaw = ""
    // These mirror the graph actions exposed by VcsLogComponents. The first
    // three are presentation-only toggles that can be honored by the current
    // graph model; branch dashboard and session tabs are modeled locally so
    // changing presentation settings never resets the active history query.
    // VcsLogApplicationSettings defaults tag-name rendering to off. Branch,
    // HEAD and remote references are always part of the commit row.
    @AppStorage("arbor.log.showTagNames.v1") var logShowTagNames = false
    @AppStorage("arbor.log.alignLabels.v1") var logAlignLabels = false
    @AppStorage("arbor.log.showLongEdges.v1") var logShowLongEdges = true
    @AppStorage("arbor.log.collapseGraph.v1") var logCollapseGraph = false
    @AppStorage("arbor.log.noMerges.v1") var logNoMerges = false
    @AppStorage("arbor.log.branches.visible.v1") var logBranchesVisible = false
    @State var isLoadingMyBranches = false
    @AppStorage("arbor.log.highlightCherryPicked.v1") var logHighlightCherryPicked = false
    @AppStorage("arbor.log.highlightCherryPicked.branch.v1") var logCherryPickCompareBranch = ""
    /// Global fallback for IntelliJ's project-level FETCH/LS_REMOTE
    /// incoming-change strategy. Project overrides are loaded below by the
    /// normalized project path, so one window never changes another project.
    @AppStorage("arbor.git.autoFetch.v1") var gitAutoFetch = false
    @AppStorage(GitIncomingOutgoingInfoSettings.key)
    var incomingOutgoingInfoEnabled = GitIncomingOutgoingInfoSettings.defaultValue
    /// Custom Git clean/smudge filters are executable repository config. The
    /// engine keeps them disabled unless the user explicitly opts in from
    /// Settings, matching the fail-closed default used by IntelliJ's safety
    /// boundary for external Git tools.
    @AppStorage("arbor.git.externalConversion.v1") var gitExternalConversionEnabled = false
    @AppStorage(GitIncomingCheckStrategy.userDefaultsKey)
    var incomingCheckStrategyRaw = GitIncomingCheckStrategy.none.rawValue
    @AppStorage(GitProtectedBranchRules.userDefaultsKey)
    var globalProtectedBranchPatterns = GitProtectedBranchRules.defaultPatterns
    @AppStorage(GitProtectedBranchRules.synchronizeKey)
    var globalProtectedBranchSynchronize = GitProtectedBranchRules.defaultSynchronize
    @State var projectProtectedBranchPatterns: String?
    @State var projectProtectedBranchSynchronize: Bool?
    @State var projectIncomingCheckStrategyRaw: String?
    @State var projectFetchTagsMode: GitFetchTagsModeChoice = .default
    @State var projectUpdateMethod: GitUpdateMethodChoice = .merge
    @State var showProjectGitSettings = false
    @State var showUpdateProjectOptions = false
    @AppStorage("arbor.log.showChangesFromParents.v1") var logShowChangesFromParents = false
    @AppStorage("arbor.log.showOnlyAffectedChanges.v1") var logShowOnlyAffectedChanges = false
    @State var autoFetchFailureFingerprint: String?
    @State var autoFetchIncomingFingerprint: String?
    @State var autoFetchIncomingBranches: Set<GitIncomingBranch> = []
    /// Each retry creates a new task generation. The monitor always performs
    /// its first check immediately, matching IntelliJ when a strategy is
    /// enabled or a project is activated.
    @State var autoFetchRunGeneration = 0
    var repo: Repository? {
        projectRepo
    }

    var searchEverywhereGitRoots: [SearchEverywhereGitRoot] {
        if !multiRootBranchSnapshots.isEmpty {
            return multiRootBranchSnapshots.map { snapshot in
                SearchEverywhereGitRoot(
                    rootPath: snapshot.rootPath,
                    displayName: snapshot.displayName,
                    relativePath: snapshot.relativePath,
                    branches: snapshot.branches,
                    remoteBranches: snapshot.remoteBranches,
                    tags: snapshot.tags
                )
            }
        }
        guard let repositoryPath = repo?.workdir(), !repositoryPath.isEmpty else {
            return []
        }
        let displayName = URL(fileURLWithPath: repositoryPath).lastPathComponent
        return [SearchEverywhereGitRoot(
            rootPath: repositoryPath,
            displayName: displayName.isEmpty ? repositoryPath : displayName,
            relativePath: ".",
            branches: branches,
            remoteBranches: remoteBranches,
            tags: tags
        )]
    }

    var newWorktreeRepository: Repository? {
        guard let rootPath = newWorktreeRootPath, !rootPath.isEmpty else {
            return repo
        }
        return try? openRepository(path: rootPath)
    }

    var newWorktreeBranches: [BranchInfo] {
        guard let rootPath = newWorktreeRootPath,
              let snapshot = multiRootBranchSnapshots.first(where: { $0.rootPath == rootPath }) else {
            return branches
        }
        return snapshot.branches
    }

    var newWorktreeWorktrees: [WorktreeInfo] {
        guard let rootPath = newWorktreeRootPath,
              let snapshot = multiRootBranchSnapshots.first(where: { $0.rootPath == rootPath }) else {
            return worktrees
        }
        return snapshot.worktrees
    }

    var logRepository: Repository? {
        if let selectedCommit,
           let selectedRepository = logRepository(for: selectedCommit) {
            return selectedRepository
        }
        if isLogRootQualified {
            return nil
        }
        if logList.activeRootPath != nil {
            return logList.activeRepo
        }
        return logList.activeRepo ?? repo
    }

    var isLogAggregate: Bool {
        !logRuntime.aggregateBranchFilters.isEmpty
            || !logRuntime.aggregateRevisionRanges.isEmpty
            || !logRuntime.aggregateRootPaths.isEmpty
    }

    var isLogRootQualified: Bool {
        isLogAggregate || (logList.viewMode == .command && logRuntime.commandIsAggregate)
    }

    var availableReflogRootPaths: [String] {
        var paths: [String] = []
        if let primary = repo?.workdir(), !primary.isEmpty {
            paths.append(primary)
        }
        paths.append(contentsOf: multiRoots.map(\.path))
        if let active = logList.activeRootPath, !active.isEmpty {
            paths.append(active)
        }
        return Array(Set(paths)).sorted()
    }

    var primaryShelfRootPath: String? {
        if let workdir = repo?.workdir(), !workdir.isEmpty {
            return canonicalExternalLogPath(workdir)
        }
        if let projectPath, !projectPath.isEmpty {
            return canonicalExternalLogPath(projectPath)
        }
        return nil
    }

    var availableShelfRoots: [GitRootInfo] {
        guard multiRoots.count > 1 else { return [] }
        let primary = primaryShelfRootPath
        return multiRoots.sorted { lhs, rhs in
            let lhsIsPrimary = canonicalExternalLogPath(lhs.path) == primary
            let rhsIsPrimary = canonicalExternalLogPath(rhs.path) == primary
            if lhsIsPrimary != rhsIsPrimary { return lhsIsPrimary }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }

    var activeShelfRootPath: String? {
        if let shelfRootPath, !shelfRootPath.isEmpty {
            return canonicalExternalLogPath(shelfRootPath)
        }
        return primaryShelfRootPath
    }

    var isShelfRootReadOnly: Bool {
        !shelfRootSelectionIsPrimary(
            selectedRootPath: shelfRootPath,
            primaryRootPath: primaryShelfRootPath
        )
    }

    var canApplyShelfWorktree: Bool {
        !shelfRootLoading
            && shelfRootError == nil
            && activeShelfRootPath != nil
            && activeShelfRepository != nil
    }

    var canMutateShelfMetadata: Bool {
        canApplyShelfWorktree
    }

    var activeShelfSnapshot: ShelfRootSnapshot? {
        guard let rootPath = activeShelfRootPath,
              !shelfRootSelectionIsPrimary(
                  selectedRootPath: rootPath,
                  primaryRootPath: primaryShelfRootPath
              ) else { return nil }
        return shelfRootSnapshots[rootPath]
            ?? multiRootBranchSnapshots.first(where: {
                canonicalExternalLogPath($0.rootPath) == rootPath
            }).map {
                ShelfRootSnapshot(
                    rootPath: rootPath,
                    shelves: $0.shelves,
                    deletedShelves: []
                )
            }
    }

    var activeShelfList: [ShelveInfo] {
        guard let activeRoot = activeShelfRootPath,
              !shelfRootSelectionIsPrimary(
                  selectedRootPath: activeRoot,
                  primaryRootPath: primaryShelfRootPath
              ) else { return shelves }
        return activeShelfSnapshot?.shelves ?? []
    }

    var activeShelfChangeLists: [ChangeListInfo] {
        guard let activeRoot = activeShelfRootPath,
              !shelfRootSelectionIsPrimary(
                  selectedRootPath: activeRoot,
                  primaryRootPath: primaryShelfRootPath
              ) else { return changeLists }
        return activeShelfSnapshot?.changeLists ?? []
    }

    var activeDeletedShelfList: [ShelveInfo] {
        guard let activeRoot = activeShelfRootPath,
              !shelfRootSelectionIsPrimary(
                  selectedRootPath: activeRoot,
                  primaryRootPath: primaryShelfRootPath
              ) else { return deletedShelves }
        return activeShelfSnapshot?.deletedShelves ?? []
    }

    var activeShelfRepository: Repository? {
        guard let rootPath = activeShelfRootPath else { return repo }
        if shelfRootSelectionIsPrimary(
            selectedRootPath: rootPath,
            primaryRootPath: primaryShelfRootPath
        ) { return repo }
        return shelfRootRepository
    }

    var reflogRootTitle: String {
        guard let path = reflog.rootPath, !path.isEmpty else { return "Repository" }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    var reflogRepository: Repository? {
        reflog.rootRepo ?? (isLogAggregate ? nil : logRepository)
    }

    /// Graph selection is root-qualified only for an aggregate multi-root
    /// Log. Single-root behavior keeps the existing short-id-compatible
    /// selection model, while aggregate history cannot safely use a raw hash.
    func logCommitIdentity(_ commit: CommitInfo) -> String {
        logCommitIdentity(repositoryPath: commit.repositoryPath, id: commit.id)
    }

    func logCommitIdentity(repositoryPath: String?, id: String) -> String {
        logCommitDisplayIdentity(
            repositoryPath: repositoryPath,
            id: id,
            aggregate: isLogRootQualified
        )
    }

    func logRepository(for commit: CommitInfo) -> Repository? {
        guard let repositoryPath = commit.repositoryPath,
              !repositoryPath.isEmpty else {
            return logList.activeRepo ?? repo
        }
        if let aggregateRepository = logRuntime.aggregateRepositories[repositoryPath] {
            return aggregateRepository
        }
        if logList.activeRootPath == repositoryPath {
            return logList.activeRepo
        }
        if repo?.workdir() == repositoryPath {
            return repo
        }
        return try? openRepository(path: repositoryPath)
    }

    /// Mirrors IntelliJ's HostedGitRepositoryReference action group: only
    /// remotes that can produce a commit web reference participate, and the
    /// selected commit's repository path decides which root owns the remote.
    func hostedRemotesForCommit(_ commit: CommitInfo) -> [RemoteInfo] {
        guard let repository = logRepository(for: commit) else { return [] }
        return logRemotes(for: commit).filter { remote in
            repository.permalink(remoteUrl: remote.url, commitId: commit.id) != nil
        }
    }

    /// The Log "Open Pull Requests" action is a hosted reference action too,
    /// but it targets the provider's PR list rather than a commit permalink.
    /// Keep its remote candidates root-qualified and filter unsupported hosts.
    func pullRequestRemotesForCommit(_ commit: CommitInfo) -> [RemoteInfo] {
        return logRemotes(for: commit).filter { remote in
            HostingProvider.parse(remoteURL: remote.url) != nil
        }
    }

    func commentRemotesForCommit(_ commit: CommitInfo) -> [RemoteInfo] {
        pullRequestRemotesForCommit(commit)
    }

    func logRepository(for commits: [CommitInfo]) -> Repository? {
        guard let first = commits.first else { return nil }
        guard logCommitSelectionRepositoryPath(commits) != nil else { return nil }
        return logRepository(for: first)
    }

    func currentLogBranchName(for commit: CommitInfo) -> String? {
        // Context menus are built for every visible Log row. Reading the
        // current branch from Repository here performs a synchronous Git
        // operation during SwiftUI layout and can block the main thread while
        // the history task owns the repository mutex. Branch snapshots are
        // already kept in view state, so use them instead.
        if let repositoryPath = commit.repositoryPath,
           !repositoryPath.isEmpty {
            if let snapshot = multiRootBranchSnapshots.first(where: {
                $0.rootPath == repositoryPath
            }) {
                return snapshot.branches.first(where: \.isCurrent)?.name
            }
            if repositoryPath == logList.activeRootPath {
                return logRuntime.activeBranches.first(where: \.isCurrent)?.name
            }
            return nil
        }
        return activeLogBranches.first(where: \.isCurrent)?.name
    }

    func logRemotes(for commit: CommitInfo) -> [RemoteInfo] {
        if let repositoryPath = commit.repositoryPath,
           !repositoryPath.isEmpty {
            if let snapshot = multiRootBranchSnapshots.first(where: {
                $0.rootPath == repositoryPath
            }) {
                return snapshot.remotes
            }
            if repositoryPath == logList.activeRootPath {
                return logRuntime.activeRemotes
            }
            return []
        }
        return activeLogRemotes
    }

    var activeLogBranches: [BranchInfo] {
        logList.activeRootPath == nil ? branches : logRuntime.activeBranches
    }

    var activeLogRemoteBranches: [RemoteBranchInfo] {
        logList.activeRootPath == nil ? remoteBranches : logRuntime.activeRemoteBranches
    }

    var activeLogRemotes: [RemoteInfo] {
        logList.activeRootPath == nil ? remotes : logRuntime.activeRemotes
    }

    /// Include repository identity so a project restored before its
    /// repository finishes loading starts the monitor when the repo arrives,
    /// and a linked worktree switch replaces the watched Git directory.
    var repositoryIndexMonitorID: String {
        "\(projectPath ?? "")|\(repo?.gitDir() ?? "closed")"
    }

    var autoFetchRootPaths: [String] {
        mergedAutoFetchRootPaths(
            primary: repo?.workdir(),
            discovered: multiRoots.map(\.path)
        )
    }

    var autoFetchMonitorID: String {
        "\(repositoryIndexMonitorID)|\(autoFetchRootPaths.joined(separator: "|"))|\(incomingCheckStrategy.rawValue)|tags-\(fetchTagsMode)|run-\(autoFetchRunGeneration)"
    }

    var shelfLifecycleMonitorID: String {
        "\(repositoryIndexMonitorID)|\(autoFetchRootPaths.joined(separator: "|"))"
    }

    var autoFetchNotificationIDPrefix: String {
        let identity = projectPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "no-project"
        return "git.fetch.\(identity)"
    }

    var protectedBranchPatterns: String {
        projectProtectedBranchPatterns ?? globalProtectedBranchPatterns
    }

    var protectedBranchSynchronize: Bool {
        projectProtectedBranchSynchronize ?? globalProtectedBranchSynchronize
    }

    var incomingCheckStrategy: GitIncomingCheckStrategy {
        guard incomingOutgoingInfoEnabled else { return .none }
        if let projectIncomingCheckStrategyRaw {
            return GitIncomingCheckStrategy(rawValue: projectIncomingCheckStrategyRaw) ?? .none
        }
        return resolveGitIncomingCheckStrategy(
            storedRawValue: UserDefaults.standard.object(forKey: GitIncomingCheckStrategy.userDefaultsKey) == nil
                ? nil
                : incomingCheckStrategyRaw,
            legacyAutoFetch: gitAutoFetch
        )
    }

    var fetchTagsMode: FetchTagsMode {
        projectFetchTagsMode.engineValue
    }
    @State var entries: [FileEntry] = []
    @State var changeLists: [ChangeListInfo] = []
    @State var refreshGate = RepositoryRefreshGate()
    @State var repositoryChangeBatch = RepositoryChangeBatch()
    @State var repositoryExternalVCSActionManager = RepositoryExternalVCSActionManager()
    @State var repositoryDirtyScopeManager = RepositoryDirtyScopeManager()
    @State var repositoryDirtyFileManager = RepositoryDirtyFileManager()
    @State var repositoryChangeDeliveryTask: Task<Void, Never>?
    @State var ignoredRules: [IgnoreRuleInfo] = []
    @State var headId: String?
    @State var loadError: String?
    @State var isLoading = false
    @State var isShowingCachedStatusSnapshot = false
    @State var commitMessage: String = ""
    @State var commitFeedback: String?
    @State var amendMode = false
    @State var recentMessages: [String] = []
    @State var selection: String?
    @State var fileSelection: String?
    @State var fileSelectionVersion: FileContentVersion = .local
    /// Monotonic request used by the Project file-tree Annotate action. The
    /// file viewer owns the blame task; the parent only selects the path and
    /// asks the viewer to enter its existing Code/Blame mode.
    @State var fileContentBlameRequestID = 0
    @State var fileTreeDiffRequest: FileTreeDiffRequest?
    @State var fileReferenceComparisonRequest: FileReferenceComparisonRequest?
    @State var currentRevisionRequest: CurrentRevisionRequest?
    /// Commit workspace preview stays inside the left Stage panel, matching
    /// rebased's split diff preview; it must not replace the right Log editor.
    @State var commitPreviewPath: String?
    @State var commitPreviewVisible = false
    @State var commitPreviewMode: StagingPreviewMode = .unstaged
    @State var commitPreviewComparisonMode: DiffMode?
    @State var commitPreviewThreeVersions = false
    @State var pendingProjectPath: String?
    @State var showProjectSwitchAlert = false
    @State var showCloneDialog = false
    @State var cloneURL = ""
    @State var cloneParentDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    @State var cloneDirectoryName = ""
    @State var cloneShallow = false
    @State var cloneDepth = "1"
    @State var cloneInProgress = false
    @State var cloneCancelling = false
    @State var cloneCancelHandle: GitCancelHandle?
    @State var cloneRequestGeneration = 0
    // IntelliJ's git.clone.recurse.submodules advanced setting defaults to
    // true; persist the same preference instead of resetting it per dialog.
    @AppStorage(GitCloneSettings.recurseSubmodulesKey)
    var cloneRecursiveSubmodules = GitCloneSettings.defaultRecurseSubmodules
    /// 逐行暂存入口：侧栏「逐行」点击后选中文件并让 diff 视图进入选择模式
    @State var selectionModePath: String?
    // 日志模式
    /// IntelliJ shows an action-group popup when a commit has multiple
    /// parents or children. Keep the resolved records separate from the
    /// paged graph so the popup can include commits outside the viewport.
    /// IntelliJ's graph table is a real multi-selection table. Keep the
    /// active row in `logSelectionState.selection` for the details panel, while this set
    /// preserves Cmd/Shift selections for toolbar and future batch actions.
    @AppStorage("arbor.log.recentPathFilters.v1") var logRecentPathFiltersRaw = ""
    @AppStorage("arbor.log.visibleRootPaths.v1") var logVisibleRootPathsPersistedRaw = ""
    /// Phase 5:log 加载代际计数——切换条件后旧请求结果直接丢弃(取消行为)。
    /// Keep the active history request cancellable. Generation checks protect
    /// state correctness; cancelling the task also prevents superseded log
    /// loads from competing for CPU while the user changes filters or panes.
    /// Coalesce several filter/control mutations arriving in one main-actor
    /// turn before starting the expensive VisibleGraph refresh.
    /// A commit referenced by a notification or reflog may not be in the
    /// currently visible history page. Keep that detail record separate from
    /// the paged graph so the inspector never falls back to an empty pane.
    @State var revisionBrowserCommit: CommitInfo?
    @State var revisionBrowserPath: String?
    @State var showRevisionBrowser = false
    // Git LFS 面板状态（能力探测 / 跟踪规则 / 文件列表 / hooks）
    @State var showLfsPanel = false
    @State var lfsCapability: LfsCapability?
    @State var lfsPatterns: [LfsTrackedPattern] = []
    @State var lfsFiles: [LfsFileEntry] = []
    @State var lfsHooks: LfsHookState?
    @State var lfsBusy = false
    @State var lfsFeedback: String?
    @State var lfsTrackInput = ""
    @State var lfsRemoteName = ""
    @State var lfsShowAllRevisions = false
    @State var lfsSelectedPaths: Set<String> = []
    // Git hooks 面板状态（面板列表 / 选中脚本 / 编辑草稿）
    @State var showHooksPanel = false
    @State var gitHooks: [GitHookInfo] = []
    @State var gitHooksLocation: GitHooksLocation?
    @State var selectedGitHook: String?
    @State var gitHookContents: GitHookContents?
    @State var gitHookDraft = ""
    @State var gitHooksBusy = false
    @State var gitHooksFeedback: String?
    @State var lfsTrackedPaths: Set<String> = []
    @State var lfsPointerPaths: Set<String> = []
    @State var compareLoadTask: Task<Void, Never>?
    /// REPO-001:多 root 发现与聚合结果
    @State var multiRoots: [GitRootInfo] = []
    /// Keep root discovery cancellable so startup and filesystem events cannot
    /// queue several repository-wide scans at once.
    @State var multiRootLoadTask: Task<Void, Never>?
    @State var multiRootLoadGeneration = 0
    @State var multiRootLoadNeedsRefresh = false
    @State var multiRootLoadCompletion: (() -> Void)?
    @State var multiRootBranchSnapshots: [GitRootBranchSnapshot] = []
    @State var multiRootResults: [RootOperationResult] = []
    @State var multiRootChangeGroups: [MultiRootChangeGroup] = []
    @State var multiRootChangesLoading = false
    @State var multiRootChangesError: String?
    @State var multiRootChangesGeneration = 0
    @State var showMultiRootChanges = false
    @State var showMultiRootCommitDialog = false
    @State var multiRootCommitMessage = ""
    @State var multiRootCommitRecentMessages: [String] = []
    @State var multiRootCommitAmendMode = false
    @State var multiRootCommitSkipHooks = false
    @State var multiRootCommitAuthorName = ""
    @State var multiRootCommitAuthorEmail = ""
    @State var multiRootCommitCommitterName = ""
    @State var multiRootCommitCommitterEmail = ""
    @State var multiRootCommitSignOff = false
    @State var multiRootCommitCoAuthors = ""
    @State var multiRootCommitSelectedPaths: [MultiRootChangeSelection]?
    @State var multiRootUpstreamContext: MultiRootUpstreamContext?
    @State var multiRootConflictGroups: [MultiRootConflictGroup] = []
    @State var multiRootConflictBatchWorking = false
    @State var multiRootConflictBatchError: String?
    @State var showMultiRootNewBranchDialog = false
    @State var multiRootNewBranchName = ""
    @State var multiRootNewBranchBase = ""
    @State var multiRootNewBranchCheckout = true
    @State var multiRootNewBranchResetExisting = false
    @State var multiRootExistingBranchNames: [String: Set<String>] = [:]
    @State var multiRootSelectedRootPaths: Set<String> = []
    @State var showMultiRootRenameBranchDialog = false
    @State var multiRootRenameOldName = ""
    @State var multiRootRenameNewName = ""
    @State var multiRootRenameUnsetUpstream = false
    @State var multiRootRenameSelectedRootPaths: Set<String> = []
    @State var showSingleRootRenameBranchDialog = false
    @State var singleRootRenameRootPath = ""
    @State var singleRootRenameOldName = ""
    @State var singleRootRenameNewName = ""
    @State var singleRootRenameUnsetUpstream = false
    @State var singleRootRenameHasUpstream = false
    @State var showMultiRootDeleteBranchDialog = false
    @State var multiRootDeleteBranchName = ""
    @State var multiRootDeleteSelectedRootPaths: Set<String> = []
    @State var showMultiRootMergeDialog = false
    @State var multiRootMergeBranchName = ""
    @State var multiRootMergeSelectedRootPaths: Set<String> = []
    @State var multiRootMergeMergedBranchesByRoot: [String: Set<String>] = [:]
    @State var multiRootMergeDialogGeneration = 0
    @State var multiRootMergeRollbackContext: MultiRootMergeRollbackContext?
    @State var showMultiRootDeleteTagDialog = false
    @State var multiRootDeleteTagName = ""
    @State var multiRootDeleteTagSelectedRootPaths: Set<String> = []
    @State var showMultiRootRemoteDeleteDialog = false
    @State var multiRootRemoteDeleteBranchName = ""
    @State var multiRootRemoteDeleteSelectedRootPaths: Set<String> = []
    @State var multiRootRemoteDeleteTracking = false
    @State var multiRootRunning = false
    /// Closes the small discovery window before Update Project can publish
    /// its ordinary multi-root runner state. It is deliberately separate from
    /// `multiRootRunning` so single-root Update does not appear as a multi-root
    /// result while roots are being discovered.
    @State var updateProjectDiscoveryRunning = false
    @State var multiRootUpdateRebase = false
    /// Explicit per-root methods selected by the rebase-over-merge warning.
    /// A nil value means the project-wide method applies to every root.
    @State var multiRootUpdateRebaseRootPaths: Set<String>?
    @State var multiRootUpdateRetryAvailable = false
    @State var multiRootCheckoutUpdateRetryAvailable = false
    @State var multiRootCheckoutUpdateRetryContext: MultiRootCheckoutUpdateRetryContext?
    @State var multiRootPushRetryContext: MultiRootPushRetryContext?
    @State var multiRootStashConflicts: [String: [String]] = [:]
    @State var multiRootStashConflictIndexes: [String: Int] = [:]
    @State var multiRootStashConflictIDs: [String: String] = [:]
    @State var multiRootStashConflictPopModes: [String: Bool] = [:]
    /// 项目级统一冲突 resolver：一次维护所有 root 的 pending queue，
    /// 当前 root 的三栏编辑器由 active* 状态驱动。
    @State var showMultiRootConflictResolver = false
    @State var multiRootResolverRoots: [MultiRootConflictResolverRoot] = []
    @State var multiRootResolverActiveRootPath: String?
    @State var multiRootResolverActiveRepo: Repository?
    @State var multiRootResolverActiveEntries: [FileEntry] = []
    @State var multiRootResolverActiveInitialPath: String?
    @State var multiRootResolverActiveKind: MultiRootConflictResolverKind?
    @State var multiRootResolverWorking = false
    @State var multiRootResolverError: String?
    @State var multiRootResolverLoadGeneration = 0
    @State var multiRootUpdateStashedRoots: Set<String> = []
    /// The Log dashboard may be scoped to a nested Git root without changing
    /// the project's primary repository context used by Commit/Status panes.
    /// External Git Log windows can aggregate all or a selected subset of the
    /// project's discovered Git roots. An empty set means the selector has
    /// not been initialized yet (or discovery currently has no roots).
    @State var externalLogRootSelectionInitialized = false
    @State var externalLogRootRequestConsumed = false
    @State var externalLogAggregateLoadStarted = false
    @State var externalLogSessionDisposed = false
    /// Each aggregate-log root owns an independent engine pagination cursor.
    /// Keeping this separate from the merged row count prevents a later page
    /// from re-querying the entire root history just to discard its prefix.
    @State var compareRev1: String = ""
    @State var compareRev2: String = ""
    @State var compareRepositoryPath: String?
    @State var compareWithWorkingTree = false
    @State var activeCompareRepo: Repository?
    @State var treeChanges: [TreeChange] = []
    @State var compareSelection: String?
    @State var compareSelectedPaths: Set<String> = []
    @State var compareError: String?
    @State var branchCompareFirstEntries: [CommitInfo] = []
    @State var branchCompareSecondEntries: [CommitInfo] = []
    @State var branchCompareFirstFilter = BranchComparisonFilter()
    @State var branchCompareSecondFilter = BranchComparisonFilter()
    @State var branchCompareSelectionID: String?
    @State var branchCompareSelectionSide: BranchComparisonSide = .first
    @State var isLoadingBranchComparison = false
    @State var branchCompareFirstLoading = false
    @State var branchCompareSecondLoading = false
    @State var branchCompareFirstHasMore = false
    @State var branchCompareSecondHasMore = false
    @State var branchCompareGeneration = 0
    @State var branchCompareFirstRequestGeneration = 0
    @State var branchCompareSecondRequestGeneration = 0
    @State var branchCompareFirstLoadTask: Task<Void, Never>?
    @State var branchCompareSecondLoadTask: Task<Void, Never>?
    @State var branchCompareFirstError: String?
    @State var branchCompareSecondError: String?
    @State var branchCompareError: String?
    /// Reflog is a repository-local history. Keep its root separate from the
    /// aggregate VCS Log filters so switching from a multi-root graph cannot
    /// leave the Reflog panel showing an unrelated or stale repository.
    @State var rebasePaused = false
    /// OPS-001 统一操作状态（merge/rebase/cherry-pick/revert），Recovery Bar 数据源。
    @State var operationState: OperationState?
    /// 每个 Git root 最近一次已发布的 operation recovery 状态。外部 Git
    /// 操作会反复触发 metadata refresh，按 fingerprint 去重可避免同一
    /// 暂停操作不断重发通知，同时允许新冲突文件或操作阶段重新提示。
    @State var operationRecoveryNotificationFingerprints: [String: String] = [:]
    /// Per-root persisted Log Revert/Cherry-pick recovery notices. This is
    /// separate from operation_state(): Git may have completed or never
    /// started the sequencer while the app was being terminated.
    @State var resolvedConflictPaths: [String] = []
    @State var operationFeedback: String?
    /// REBASE-001 todo 编辑器状态
    @State var showRebaseTodoEditor = false
    @State var rebaseTodoItems: [RebaseTodoItem] = []
    @State var rebaseTodoOnto = ""
    @State var rebaseTodoPreserveMerges = false
    @State var rebaseTodoRoot = false
    /// Native Git todo fallback.  This keeps label/reset/merge/exec and any
    /// future Git commands as editable text instead of forcing them through
    /// the structured six-action model.
    @State var showRawRebaseTodoEditor = false
    @State var rebaseRawTodoText = ""
    @State var showRawRebaseMessageEditor = false
    @State var rawRebaseMessageText = ""
    @State var rawRebaseMessageRepository: Repository?
    /// Log HEAD Reword uses Git's `--amend --only` path so staged changes stay staged.
    /// Log Fixup/Squash keeps IntelliJ's optional Commit and Rebase executor
    /// available until the generated commit is created.
    @State var pendingAutoSquashRebase: PendingAutoSquashRebase?
    /// IntelliJ warns before editing the initial commit instead of silently
    /// rejecting the action.
    @State var showInitialCommitRewordAlert = false
    @State var pendingInitialCommitReword: CommitInfo?
    @State var showInitialCommitRewriteAlert = false
    @State var pendingInitialCommitRewrite: PendingInitialCommitRewrite?
    /// IDX-001 三层 staging 模型（二进制徽标/忽略入口数据源）。
    @State var stagingModel: StagingModel?
    /// index tracker：外部 Git 修改 index 后提示刷新。
    @State var lastIndexRevision: IndexRevision?
    /// Invalidates read-only version viewers and staging diff previews after
    /// any visible status refresh, including worktree-only changes where the
    /// index did not change.
    @State var fileContentRefreshToken = 0
    @State var rebasePauseReason: RebasePauseReason?
    @State var rebaseConflicts: [String] = []
    // 分支模式
    @State var mergeBranch: String = ""
    @State var mergeMergedBranches: Set<String> = []
    @State var mergeDialogGeneration = 0
    @State var mergeStrategyRaw = MergeStrategyChoice.automatic.rawValue
    @AppStorage(GitDeleteOnMergeOption.key) var mergeDeleteOnMergeRaw = GitDeleteOnMergeOption.defaultOption.rawValue
    @State var mergeCommitMessage = ""
    @State var mergeUseCustomCommitMessage = false
    @State var mergeNoCommit = false
    @State var mergeNoVerify = false
    @State var mergeAllowUnrelatedHistories = false
    @State var mergeFeedback: String?
    @State var newBranchName: String = ""
    /// A Log commit can belong to a non-primary Git root. Keep the branch
    /// dialog and its write operation pinned to that root instead of falling
    /// back to the window's primary repository.
    @State var newBranchRepositoryOverride: Repository?
    @State var newBranchDialogBranches: [BranchInfo] = []
    @State var renameOld: String = ""
    @State var renameNew: String = ""
    @State var branches: [BranchInfo] = []
    @State var branchComparisons: [String: BranchCompare] = [:]
    @State var shelveName: String = ""
    @State var shelves: [ShelveInfo] = []
    @State var deletedShelves: [ShelveInfo] = []
    /// Monotonic request used by VCS > Git > Local Changes > Show Shelf/Stash.
    /// RebasedCommitWorkspace owns the tab state, so the request crosses the
    /// workspace boundary without making the parent duplicate that state.
    @State var shelfTabRequestID = 0
    @State var isShelfWorkspaceTabActive = false
    @State var shelfRootPath: String?
    @State var shelfRootSnapshots: [String: ShelfRootSnapshot] = [:]
    @State var shelfRootRepository: Repository?
    @State var shelfRootLoading = false
    @State var shelfRootError: String?
    @State var shelfRootLoadGeneration = 0
    @State var stashes: [StashInfo] = []
    // 远程
    @State var remotes: [RemoteInfo] = []
    @State var isShallowRepository = false
    @State var remoteBranches: [RemoteBranchInfo] = []
    /// BRANCH-001 Recent 分组（HEAD reflog 最近检出）。
    @State var recentBranches: [String] = []
    @State var syncStatuses: [SyncStatus] = []
    @State var pushForce = false
    @State var remoteProtectedBranchPatterns: [String] = []
    /// Hosted protection is repository-scoped. Keep it separate from the
    /// primary root's legacy presentation state so a multi-root push cannot
    /// accidentally use another repository's cached rules.
    @State var remoteProtectedBranchPatternsByRoot: [String: [String]] = [:]
    @State var remoteName: String = ""
    @State var remoteUrl: String = ""
    /// REMOTE-001 Configure Remotes Dialog 状态
    @State var showSearchEverywhere = false
    @StateObject var vcsQuickActionsPanel = VCSQuickActionsPanelCoordinator()
    @State var searchEverywhereQuery = ""
    @State var showRemoteConfigDialog = false
    @State var remotePushUrl: String = ""
    @State var remoteFetchRefspec: String = ""
    @State var remotePushRefspec: String = ""
    @State var multiRootRemoteConfigContext: MultiRootRemoteConfigContext?
    @State var multiRootRemoteConfigAggregateContext: MultiRootRemoteConfigAggregateContext?
    @StateObject var branchCleanupWindow = BranchCleanupWindowCoordinator()
    @State var branchCleanupGeneration = 0
    @State var showFindMergedBranchesDialog = false
    @State var findMergedBranchesRoots: [BranchCleanupRoot] = []
    @State var findMergedTargetBranch = ""
    @State var findMergedPrefix = ""
    @State var findMergedRunning = false
    @State var findMergedHasCalculated = false
    @State var findMergedSummary: FindMergedScanSummary?
    @State var findMergedGeneration = 0
    @State var findMergedTask: Task<Void, Never>?
    @State var findMergedReportID: String?
    @State var findMergedReportText = ""
    @State var showFindMergedReport = false
    @State var multiRootRemoteName: String = ""
    @State var multiRootRemoteURL: String = ""
    @State var multiRootRemotePushURL: String = ""
    @State var multiRootRemoteFetchRefspec: String = ""
    @State var multiRootRemotePushRefspec: String = ""
    // 变基
    @State var rebaseOnto: String = ""
    @State var rebaseBranch: String = ""
    @State var rebaseRootPath: String = ""
    @State var rebaseRange: [CommitInfo] = []
    @State var rebaseActions: [RebaseAction] = []
    @State var rebaseRangeGeneration = 0
    @State var rebaseInteractive = false
    @State var rebasePreserveMerges = false
    @State var rebaseAutoSquash = false
    @State var rebaseKeepEmpty = false
    @State var rebaseUpdateRefs = false
    @State var rebaseRoot = false
    @State var rebaseApplyToAllRoots = false
    @State var showMultiRootRebaseEditor = false
    @State var multiRootRebaseDrafts: [MultiRootRebaseTodoDraft] = []
    @State var multiRootRawTodoContext: MultiRootRawTodoContext?
    @State var multiRootRawTodoText = ""
    @State var multiRootRebaseSession: MultiRootRebaseSession?
    @State var multiRootRebaseRollbackContext: MultiRootRebaseRollbackContext?
    @State var rebaseRetryContext: RebaseRetryContext?
    @State var rebaseUndoSeed: RebaseUndoSeed?
    @State var rebaseUndoTarget: RebaseUndoTarget?
    @State var rebaseFeedback: String?
    @State var tags: [TagInfo] = []
    @State var tagName: String = ""
    @State var tagAt: String = ""
    @State var tagMessage: String = ""
    @State var tagSignKey: String = ""
    @State var tagAnnotated = false
    @State var tagForce = false
    @State var tagFeedback: String?
    @State var tagRepositoryOverride: Repository?
    @State var submoduleUrl: String = ""
    @State var submodulePath: String = ""
    @State var submodules: [SubmoduleInfo] = []
    @State var submoduleFeedback: String?
    @State var showSubmoduleLog = false
    @State var submoduleLogPath = ""
    @State var submoduleLogEntries: [CommitInfo] = []
    @State var submoduleLogError: String?
    @State var shelfPreviewName: String?
    @State var shelfPreviewIsDeleted = false
    @State var shelfPreviewText: String?
    @State var showShelfPreview = false
    @State var shelfPreviewRootPath: String?
    @State var worktrees: [WorktreeInfo] = []
    @State var worktreeFeedback: String?
    @State var showNewWorktreeDialog = false
    /// Root selected by a Branches Popup worktree action. Keeping this
    /// separate from `repo` prevents a multi-root popup from silently
    /// creating the worktree in the primary repository.
    @State var newWorktreeRootPath: String?
    @State var newWorktreeReference = ""
    @State var newWorktreeIsTag = false
    @State var newWorktreePath = ""
    @State var newWorktreeBranch = ""
    @State var operationsViewMode: OperationsViewMode = .history
    @State var operationLogFocusNotificationID: String?
    @State var consoleResult: GitCommandResult?
    @State var skipHooks = false
    @State var beforeCommitCommands: [BeforeCommitCommand] = []
    @State var showBeforeCommitSettings = false
    @State var showIdentitySettings = false
    @State var pendingIdentityCommitRetry = false
    @State var showGpgAgentSettings = false
    @State var showGitSSHSettings = false
    @State var gitSSHCommand = ""
    @State var gitSSHKnownHostsFile = ""
    @State var gitSSHIdentityFile = ""
    @State var gitSSHHostKeyPolicy: SshHostKeyPolicy = .strict
    @State var gitSSHAuthMethod: SshAuthMethod = .auto
    @State var gitCredentialHelperConfig = ""
    @State var gitCredentialHelpers: [CredentialHelperInfo] = []
    @State var gitSSHAgentDiagnostics: SshAgentDiagnostics?
    @State var lastSuccessfulSSHAuthentications: [SSHAuthenticationRecord] = []
    @State var identityName = ""
    @State var identityEmail = ""
    @State var identitySetNameEmailGlobally = GitIdentityScopeSettings.defaultSetNameEmailGlobally
    @State var identitySigningKey = ""
    @State var identitySigningFormat = "gpg"
    @State var identitySignCommits = false
    @State var identityAuthorName = ""
    @State var identityAuthorEmail = ""
    @State var identityRecentAuthors: [String] = []
    @State var identityCommitterName = ""
    @State var identityCommitterEmail = ""
    @State var identitySignOff = false
    @State var identityCoAuthors = ""
    @State var showPushDialog = false
    @State var showMultiRootPushOptions = false
    @State var multiRootPushOptionsRootPaths: [String]?
    @State var multiRootPushOptionsFromCommit = false
    @State var multiRootPushContext: MultiRootPushContext?
    @State var addCommitsToRemoteBranchContext: AddCommitsToRemoteBranchContext?
    @State var pushDialogMode: PushDialogMode = .push
    /// IntelliJ's Commit and Push executor commits first and opens the Push
    /// options only after the commit succeeds. Keep that intent out of the
    /// push dialog so a failed commit can never publish anything.
    @State var pendingCommitAndPush = false
    @State var pushDialogRefspec: String?
    @State var pushDialogRemote: String?
    @State var pushDialogBranch: String?
    @State var pushDialogSourceRevision: String?
    @State var pushFeedback: String?
    @State var mergeInProgress = false
    /// Source local branch captured by an engine merge. Kept until the
    /// explicit finish path completes so Delete-on-Merge survives conflict
    /// resolution in the current app session.
    @State var pendingMergeDeleteBranch: String?
    /// ORIG_HEAD fallback covers a merge resumed after the view was recreated;
    /// the in-memory value is preferred while this session owns the boundary.
    @State var mergeInitialHead: String?
    @State var stashPopConflictInProgress = false
    @State var stashApplyConflictInProgress = false
    @State var shelveConflictInProgress = false
    @State var shelveConflictIsPop = false
    @State var shelveConflictIsDirectPatch = false
    @State var pendingShelveConflictName: String?
    @State var pendingShelveConflictRepository: Repository?
    @State var pendingShelveConflictChangeList: String?
    @State var pendingShelveConflictPatch: String?
    @State var pendingShelveConflictNotificationID: String?
    @State var pendingStashConflictNotificationID: String?
    /// Legacy stack position retained for compatibility with the multi-root
    /// resolver. Single-root conflict completion prefers the stable stash ID.
    @State var pendingStashPopIndex: Int?
    /// Stable stash object identity retained while a pop restore is paused.
    /// The stash stack can be reordered while the conflict resolver is open.
    @State var pendingStashPopID: String?
    @State var pendingPullStashPop = false
    /// Stable identity for the temporary Pull stash. The message remains as
    /// a compatibility fallback for markers written by older builds.
    @State var pendingPullStashID: String?
    @State var pendingPullStashMessage: String?
    @State var pendingPullShelfName: String?
    @State var showHostingSettings = false
    @State var showHostingHub = false
    @State var showHostingAuthPrompt = false
    @State var reviewCommentCommit: CommitInfo?
    @State var reviewCommentRepository: HostingRepository?
    @State var showReviewComment = false
    // Rebased 页面级弹出与对话框
    @State var showBranchesPopover = false
    @State var showUpstreamDialog = false
    @State var upstreamLocalBranch = ""
    @State var showNewBranchDialog = false
    @State var newBranchDialogTitle = "New Branch"
    @State var newBranchBase = ""
    @State var newBranchCheckout = true
    @State var newBranchResetExisting = false
    @State var newBranchAfterCreateRebase = false
    @State var showMergeActionDialog = false
    @State var showRebaseActionDialog = false
    @State var showPullDialog = false
    @State var pullDialogSnapshots: [GitRootBranchSnapshot] = []
    @State var pullDialogRebase = false
    @State var pullDialogGeneration = 0
    @State var uncommitRequest: RebasedUncommitRequest?
    @State var showNewTagDialog = false
    @State var showRemoteTagsDialog = false
    @State var showMultiRootRemoteTagsDialog = false
    @State var showShelveDialog = false
    @State var showShelfLocationDialog = false
    @State var shelfLocationValue = ""
    @State var shelfLocationCurrent = ""
    @State var shelfLocationMigrateExisting = true
    @State var pendingApplyPatch: RebasedApplyPatchRequest?
    @State var patchExportRequest: PatchExportRequest?
    @State var pendingIgnoreFileCreation: IgnoreFileCreationRequest?
    @State var showResetDialog = false
    @State var resetTargetCommit: CommitInfo?
    @State var resetTargetCommits: [CommitInfo] = []
    @State var resetMode: ResetMode = .mixed
    @State var showHeadResetDialog = false
    @State var headResetRootPath = ""
    @State var headResetTarget = "HEAD"
    @State var headResetMode: ResetMode = .mixed
    @State var smartOperationRequest: SmartOperationRequest?
    @State var showMergeRevisionsDialog = false
    /// The conflict dialog can be opened from the left Commit/Stash workspace
    /// while Git Log owns the right editor workspace. Keep its initial file
    /// independent from the main editor selection so opening the resolver does
    /// not replace the Log graph underneath it.
    @State var mergeInitialPath: String?
    @State var feedbackDetailMessage: FeedbackMessage?
    @State var branchDeleteRecovery: BranchDeleteRecoveryContext?
    @State var multiRootBranchDeleteRecovery: MultiRootBranchDeleteRecoveryContext?
    @State var tagDeleteRecovery: TagDeleteRecoveryContext?
    @State var multiRootTagDeleteRecovery: MultiRootTagDeleteRecoveryContext?

    init(
        projectPath: String? = nil,
        initialToolWindowMode: ToolWindowMode = .commit,
        externalLogWindow: Bool = false,
        initialExternalLogRootPaths: [String] = [],
        externalLogProviderSession: ExternalLogProviderSession? = nil,
        externalLogUIManager: ExternalLogManager? = nil
    ) {
        self.externalLogWindow = externalLogWindow
        self.externalLogProviderSession = externalLogProviderSession
        self.externalLogUIManager = externalLogUIManager
        let normalizedInitialExternalLogRoots = Set(normalizedLogRootPaths(initialExternalLogRootPaths))
        self.initialExternalLogRootPaths = normalizedInitialExternalLogRoots
        // 先算成本地值：StateObject 的 autoclosure 是 escaping 的，init 里不能
        // 捕获 self。
        let initialLogRepositories = externalLogUIManager?.repositories(
            for: Array(normalizedInitialExternalLogRoots)
        ) ?? externalLogProviderSession?.repositories(
            for: Array(normalizedInitialExternalLogRoots)
        ) ?? [:]
        _logRuntime = StateObject(wrappedValue: LogRuntimeState(
            aggregateRootPaths: normalizedInitialExternalLogRoots,
            aggregateRepositories: initialLogRepositories
        ))
        _externalLogRootSelectionInitialized = State(
            initialValue: externalLogWindow && !self.initialExternalLogRootPaths.isEmpty
        )
        _externalLogSessionDisposed = State(initialValue: false)
        // Rebased reopens the most recent project instead of dropping the
        // user into an empty welcome surface on every launch. An explicit
        // command-line project remains authoritative; otherwise choose the
        // first recent directory that still exists.
        let recoveredPath = projectPath ?? Self.recentProjectPath()
        self.externalLogTabsPersistenceKey = externalLogWindow
            ? recoveredPath.map {
                ExternalLogTabsStore.key(
                    projectPath: $0,
                    rootPaths: normalizedInitialExternalLogRoots
                )
            }
            : nil

        var restoredExternalTabs: [LogTabDescriptor] = []
        var restoredExternalActiveTabID: UUID?
        if externalLogWindow, let recoveredPath,
           let state = ExternalLogTabsStore.load(
               projectPath: recoveredPath,
               rootPaths: normalizedInitialExternalLogRoots
           ) {
            let sanitizedState = state.sanitized()
            restoredExternalTabs = sanitizedState.tabs
            restoredExternalActiveTabID = sanitizedState.activeTabID
        }
        if restoredExternalTabs.isEmpty {
            restoredExternalTabs = [LogTabDescriptor()]
        }
        let restoredActiveTabID = restoredExternalActiveTabID.flatMap { id in
            restoredExternalTabs.contains(where: { $0.id == id }) ? id : nil
        } ?? restoredExternalTabs[0].id
        if externalLogWindow {
            restoredExternalTabs.forEach { _ = externalLogUIManager?.registerUI($0.id) }
        }
        _logSelectionState = StateObject(wrappedValue: LogSelectionState(
            tabs: externalLogWindow ? restoredExternalTabs : [LogTabDescriptor()],
            activeTabID: externalLogWindow ? restoredActiveTabID : nil
        ))
        _projectPath = State(initialValue: recoveredPath)
        _path = State(initialValue: recoveredPath ?? "")
        _logBranchesPanel = StateObject(wrappedValue: LogBranchesPanelState(
            groupByDirectory: GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.groupByDirectoryKey,
                for: recoveredPath
            ),
            groupByRepository: GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.groupByRepositoryKey,
                for: recoveredPath
            ),
            selectionActionRaw: GitBranchesPopupSettings.stringValue(
                GitBranchesPopupSettings.logSelectionActionKey,
                for: recoveredPath
            )
        ))
        let rememberedMode = UserDefaults.standard.string(forKey: "arbor.toolWindowMode")
            .flatMap(ToolWindowMode.init(rawValue:))
        // --log is an explicit launch request; otherwise restore the last
        // workspace so reopening a project returns to the same Git surface.
        _toolWindowMode = State(initialValue: initialToolWindowMode == .log ? .log : (rememberedMode ?? initialToolWindowMode))
    }

    // Kept internal so the AppKit/WindowGroup lifecycle recovery can repeat
    // the same valid-repository selection after state restoration.
    static func recentProjectPath() -> String? {
        let paths = UserDefaults.standard.stringArray(forKey: "lastOpenedPaths") ?? []
        let gitDirectories = paths.filter { candidate in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return false
            }
            // A recent folder is not automatically a Git project. Rebased
            // restores the last usable VCS workspace; reopening an arbitrary
            // source folder here would send the user back to the empty-state
            // shell with no log, branches, or Commit workspace data.
            var isGitMarkerDirectory: ObjCBool = false
            let gitMarker = URL(fileURLWithPath: candidate)
                .appendingPathComponent(".git")
                .path
            return FileManager.default.fileExists(
                atPath: gitMarker,
                isDirectory: &isGitMarkerDirectory
            )
        }

        return gitDirectories.first
    }

    var hasStaged: Bool { entries.contains { $0.staged != .unchanged } }
    var hasLocalChanges: Bool {
        entries.contains {
            $0.staged != .unchanged || $0.unstaged != .unchanged
        }
    }
    /// 未暂存组：unstaged 维度有变更（含冲突文件，冲突显示在 unstaged 维度）
    var unstagedEntries: [FileEntry] {
        entries.filter {
            $0.unstaged != .unchanged
                && $0.unstaged != .untracked
                && $0.unstaged != .ignored
        }
    }
    var untrackedEntries: [FileEntry] {
        entries.filter { $0.unstaged == .untracked }
    }
    /// Rebased-style pull preserves the complete local workspace, including
    /// files that Git has not started tracking yet.
    var hasTrackedChanges: Bool {
        entries.contains {
            $0.staged != .unchanged
                || ($0.unstaged != .unchanged
                    && $0.unstaged != .untracked
                    && $0.unstaged != .ignored)
        }
    }
    /// Local-only files are also preserved by the pull workflow. This keeps
    /// the operation entirely automatic instead of waiting for the engine to
    /// discover a remote path collision after the pull has already started.
    var hasUntrackedOrIgnoredFiles: Bool {
        entries.contains { $0.unstaged == .untracked || $0.unstaged == .ignored }
    }
    /// 已暂存组：staged 维度有变更
    var stagedEntries: [FileEntry] { entries.filter { $0.staged != .unchanged } }
    var selectedEntry: FileEntry? {
        guard let selection else { return nil }
        return entries.first { $0.path == selection }
    }
    var selectedEntryIsConflicted: Bool {
        guard let selectedEntry else { return false }
        return selectedEntry.staged == .conflicted || selectedEntry.unstaged == .conflicted
    }
    var selectedLocalChangePath: String? {
        // `restore --source HEAD --staged --worktree` is only valid when the
        // selected path exists in HEAD. Until the asynchronous staging model
        // has supplied that fact, keep the destructive main-menu action off.
        guard !isShelfWorkspaceTabActive, stagingModel != nil else { return nil }
        return arborSelectedRevertPath(
            entries: entries,
            candidates: [commitPreviewPath, selection, fileSelection],
            headPresentByPath: stagingPresenceByPath.mapValues(\.head)
        )
    }
    var selectedWorkspacePath: String? {
        guard !isShelfWorkspaceTabActive else { return nil }
        return [commitPreviewPath, selection, fileSelection]
            .compactMap { $0 }
            .first { !$0.isEmpty }
    }
    var selectedFileActionContext: ArborSelectedGitFileContext? {
        guard let selectedPath = selectedWorkspacePath,
              let normalizedPath = normalizedRepositoryRelativePath(selectedPath),
              let primaryRootPath = repo?.workdir(),
              !primaryRootPath.isEmpty else { return nil }

        let isDirectory: Bool
        if selectedPath == fileSelection, let projectPath {
            var directory = ObjCBool(false)
            _ = FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: projectPath)
                    .appendingPathComponent(normalizedPath)
                    .path,
                isDirectory: &directory
            )
            isDirectory = directory.boolValue
        } else {
            isDirectory = false
        }

        let roots: [GitRootInfo]
        if !multiRoots.isEmpty {
            roots = multiRoots
        } else {
            roots = [GitRootInfo(
                path: primaryRootPath,
                displayName: URL(fileURLWithPath: primaryRootPath).lastPathComponent,
                relativePath: ".",
                isSubmodule: false,
                headBranch: currentBranchName,
                headId: headId,
                dirty: hasLocalChanges,
                operation: operationState?.kind
            )]
        }
        guard let target = fileReferenceComparisonTarget(
            path: normalizedPath,
            primaryRootPath: primaryRootPath,
            roots: roots
        ) else { return nil }

        let matchingEntries = entries.filter { $0.path == normalizedPath }
        let statuses = matchingEntries.flatMap { [$0.staged, $0.unstaged] }
        let hasConflict = statuses.contains(.conflicted)
        let hasIgnored = statuses.contains(.ignored)
        let hasChange = statuses.contains {
            $0 != .unchanged && $0 != .ignored
        }
        let hasUntracked = matchingEntries.contains { $0.unstaged == .untracked }
        let isPrimaryRoot = canonicalExternalLogPath(target.rootPath)
            == canonicalExternalLogPath(primaryRootPath)

        return ArborSelectedGitFileContext(
            path: normalizedPath,
            rootRelativePath: target.relativePath,
            isDirectory: isDirectory,
            owningRootPath: target.rootPath,
            isPrimaryRoot: isPrimaryRoot,
            canCheckin: isPrimaryRoot && !isDirectory && hasChange && !hasConflict,
            canAdd: !isDirectory && hasUntracked && !hasIgnored && !hasConflict,
            canAnnotate: isPrimaryRoot
                && !isDirectory
                && projectFileTreeCanAnnotate(path: normalizedPath, entries: entries),
            canCompareWithHead: !isDirectory
                && projectFileTreeCanCompareWithSameVersion(
                    path: normalizedPath,
                    entries: entries
                ),
            canCompareWithSelectedRevision: !isDirectory
                && projectFileTreeCanCompareWithSelectedRevision(
                    path: normalizedPath,
                    isDirectory: false,
                    entries: entries
                )
        )
    }
    var selectedCommit: CommitInfo? {
        guard let selectedID = logSelectionState.selection else { return nil }
        let visibleEntries = logList.viewMode == .command ? logRuntime.commandEntries : logList.entries
        return visibleEntries.first {
            let identity = logCommitIdentity($0)
            return identity == selectedID
                || identity.hasPrefix(selectedID)
                || selectedID.hasPrefix(identity)
        }
            ?? (logSelectionState.detailCommit.map {
                let identity = logCommitIdentity($0)
                return identity == selectedID
                    || identity.hasPrefix(selectedID)
                    || selectedID.hasPrefix(identity) ? $0 : nil
            } ?? nil)
    }
    var selectedTreeChange: TreeChange? {
        guard let compareSelection else { return nil }
        return treeChanges.first { $0.path == compareSelection }
    }
    var selectedTreeChanges: [TreeChange] {
        orderedCompareSelection(changes: treeChanges, selectedPaths: compareSelectedPaths)
    }
    var selectedBranchComparisonCommit: CommitInfo? {
        let commits = branchCompareSelectionSide == .first
            ? branchCompareFirstEntries
            : branchCompareSecondEntries
        return commits.first { $0.id == branchCompareSelectionID }
    }
    var selectedReflogEntry: ReflogEntry? {
        guard let selection = reflog.selection else { return nil }
        return reflog.entries.first { reflogEntryIdentifier($0) == reflog.selection }
    }
    var selectedReflogEntries: [ReflogEntry] {
        orderedReflogSelection(entries: reflog.entries, selectedIDs: reflog.selectedIDs)
    }
    var selectedReflogCommits: [CommitInfo] {
        if !reflog.detailCommits.isEmpty {
            return reflog.detailCommits
        }
        var seen = Set<String>()
        return selectedReflogEntries.compactMap { entry in
            guard let commit = logList.entries.first(where: {
                $0.id == entry.newId || $0.id.hasPrefix(entry.newId) || entry.newId.hasPrefix($0.id)
            }), seen.insert(commit.id).inserted else { return nil }
            return commit
        }
    }
    var selectedReflogCommit: CommitInfo? {
        selectedReflogCommits.first
    }

    func reflogCommit(for entry: ReflogEntry) -> CommitInfo? {
        let matches: (CommitInfo) -> Bool = { commit in
            commit.id == entry.newId
                || commit.id.hasPrefix(entry.newId)
                || entry.newId.hasPrefix(commit.id)
        }
        return reflog.detailCommits.first(where: matches)
            ?? reflog.detailCommit.flatMap { matches($0) ? $0 : nil }
            ?? logList.entries.first(where: matches)
    }

    var hostingRepositories: [HostingRepository] {
        hostingRepositories(for: remotes)
    }

    var hostingRepository: HostingRepository? {
        hostingRepositories.first
    }

    var effectiveProtectedBranchPatterns: [String] {
        effectiveProtectedBranchPatterns(forRootPath: nil)
    }

    func effectiveProtectedBranchPatterns(forRootPath rootPath: String?) -> [String] {
        let cachedPatterns = GitProtectedBranchRules.remotePatterns(
            forRootPath: rootPath,
            primaryPatterns: remoteProtectedBranchPatterns,
            patternsByRoot: remoteProtectedBranchPatternsByRoot
        )
        let remotePatterns: [String] = {
            guard let rootPath,
                  !remoteProtectedBranchPatternsByRoot.keys.contains(
                    canonicalExternalLogPath(rootPath)
                  ) else {
                return cachedPatterns
            }
            let key = canonicalExternalLogPath(rootPath)
            return GitProtectedBranchRules.loadRemotePatterns(for: key)
        }()
        return GitProtectedBranchRules.combinedPatterns(
            localRawValue: protectedBranchPatterns,
            remotePatterns: remotePatterns,
            synchronize: protectedBranchSynchronize
        )
    }

    var mergeDeleteOnMergeOption: GitDeleteOnMergeOption {
        GitDeleteOnMergeOption(rawValue: mergeDeleteOnMergeRaw)
            ?? GitDeleteOnMergeOption.defaultOption
    }

    var currentSyncStatus: SyncStatus? {
        syncStatuses.first(where: { $0.branch == currentBranchName })
    }

    var currentBranchHasUnfetchedIncoming: Bool {
        hasUnfetchedIncomingBranch(
            rootPath: repo?.workdir() ?? projectPath,
            branch: currentBranchName,
            in: autoFetchIncomingBranches
        )
    }

    private var multiRootMergePresentedView: some View {
        mainView
            .modifier(
                MultiRootMergePresentationModifier(
                    isPresented: $showMultiRootMergeDialog,
                    selectedRootPaths: $multiRootMergeSelectedRootPaths,
                    strategy: Binding(
                        get: { MergeStrategyChoice(rawValue: mergeStrategyRaw) ?? .automatic },
                        set: { mergeStrategyRaw = $0.rawValue }
                    ),
                    commitMessage: $mergeCommitMessage,
                    useCustomCommitMessage: $mergeUseCustomCommitMessage,
                    noCommit: $mergeNoCommit,
                    noVerify: $mergeNoVerify,
                    allowUnrelatedHistories: $mergeAllowUnrelatedHistories,
                    rollbackContext: $multiRootMergeRollbackContext,
                    branchName: multiRootMergeBranchName,
                    snapshots: multiRootBranchSnapshots,
                    mergedBranchesByRoot: multiRootMergeMergedBranchesByRoot,
                    onMerge: startMultiRootMergeFromDialog,
                    onCancel: dismissMultiRootMergeDialog,
                    onRollback: { targets in rollbackMultiRootMerge(targets) },
                    onKeep: keepMultiRootMergePartial,
                    onDone: dismissMultiRootMergeRollback
                )
            )
            .onReceive(
                NotificationCenter.default.publisher(for: .arborDeleteMergedBranch),
                perform: handleMergeDeleteNotification
            )
    }

    private var repositoryIndexMonitoredView: some View {
        multiRootMergePresentedView
        .background {
            RepositoryIndexRevisionMonitor(
                repo: repo,
                repositoryID: "\(repositoryIndexMonitorID)|\(autoFetchRootPaths.joined(separator: "|"))",
                rootPaths: autoFetchRootPaths,
                onChanged: handleRepositoryChange
            )
        }
    }

    private var workspaceLifecycleView: some View {
        repositoryIndexMonitoredView
        .background {
            let expectedGitDir = repo?.gitDir()
            let expectedMonitorID = autoFetchMonitorID
            GitAutoFetchMonitor(
                rootPaths: autoFetchRootPaths,
                repositoryID: autoFetchMonitorID,
                broker: credentialAuth.broker,
                strategy: feedbackCenter.isRunning ? .none : incomingCheckStrategy,
                tagMode: fetchTagsMode,
                onUpdated: { updatedRefs in
                    guard !updatedRefs.isEmpty,
                          self.repo?.gitDir() == expectedGitDir,
                          self.autoFetchMonitorID == expectedMonitorID else { return }
                    autoFetchIncomingFingerprint = nil
                    autoFetchFailureFingerprint = nil
                    DiagnosticsLogger.shared.record(
                        operation: "auto-fetch",
                        repositoryPath: projectPath,
                        code: "updated-\(updatedRefs.count)-refs"
                    )
                    loadRepoData(includeComparisons: false)
                    loadMultiRoots()
                    refreshAll(showFeedback: false)
                },
                onUnfetched: { snapshot in
                    guard self.repo?.gitDir() == expectedGitDir,
                          self.autoFetchMonitorID == expectedMonitorID else { return }
                    autoFetchIncomingBranches = applyingAutoFetchIncomingSnapshot(
                        snapshot,
                        to: autoFetchIncomingBranches
                    )
                    guard !autoFetchIncomingBranches.isEmpty else {
                        feedbackCenter.expire(notificationID: "\(autoFetchNotificationIDPrefix).incoming")
                        autoFetchIncomingFingerprint = nil
                        return
                    }
                    let displayValues = groupedAutoFetchIncomingBranches(
                        Array(autoFetchIncomingBranches)
                    ).map(\.displayValue)
                    let fingerprint = autoFetchNotificationFingerprint(displayValues)
                    guard fingerprint != autoFetchIncomingFingerprint else { return }
                    autoFetchIncomingFingerprint = fingerprint
                    feedbackCenter.warning(
                        "Incoming changes available",
                        detail: displayValues.joined(separator: "\n"),
                        nextStep: "Run Fetch to update the local remote-tracking refs.",
                        additionalActions: [
                            self.autoFetchRecoveryFeedbackAction(
                                .fetchAll,
                                rootPaths: self.autoFetchRootPaths
                            )
                        ],
                        notificationID: "\(autoFetchNotificationIDPrefix).incoming",
                        localized: false
                    )
                },
                onFailure: { failures in
                    guard self.repo?.gitDir() == expectedGitDir,
                          self.autoFetchMonitorID == expectedMonitorID else { return }
                    guard !failures.isEmpty else {
                        feedbackCenter.expire(notificationID: "\(autoFetchNotificationIDPrefix).error")
                        autoFetchFailureFingerprint = nil
                        return
                    }
                    let fingerprint = autoFetchNotificationFingerprint(failures)
                    guard fingerprint != autoFetchFailureFingerprint else { return }
                    autoFetchFailureFingerprint = fingerprint
                    let retryAction = self.autoFetchRecoveryFeedbackAction(
                        .retryCheck,
                        rootPaths: self.autoFetchRootPaths
                    )
                    let fetchAction = self.autoFetchRecoveryFeedbackAction(
                        .fetchAll,
                        rootPaths: self.autoFetchRootPaths
                    )
                    feedbackCenter.warning(
                        incomingCheckStrategy == .fetch
                            ? "Auto-fetch failed"
                            : "Incoming changes check failed",
                        detail: failures.joined(separator: "\n"),
                        nextStep: "Check the remote and authentication settings, then retry.",
                        additionalActions: incomingCheckStrategy == .fetch
                            ? [retryAction]
                            : [retryAction, fetchAction],
                        notificationID: "\(autoFetchNotificationIDPrefix).error",
                        localized: false
                    )
                }
            )
        }
        .background {
            GitShelfLifecycleMonitor(
                rootPaths: autoFetchRootPaths,
                repositoryID: shelfLifecycleMonitorID
            )
        }
        .onChange(of: autoFetchMonitorID) { _, _ in
            autoFetchFailureFingerprint = nil
            autoFetchIncomingFingerprint = nil
            autoFetchIncomingBranches = []
        }
        .onChange(of: incomingOutgoingInfoEnabled) { _, enabled in
            guard !enabled else { return }
            feedbackCenter.expire(notificationID: "\(autoFetchNotificationIDPrefix).incoming")
            feedbackCenter.expire(notificationID: "\(autoFetchNotificationIDPrefix).error")
            autoFetchFailureFingerprint = nil
            autoFetchIncomingFingerprint = nil
            autoFetchIncomingBranches = []
        }
        .onAppear {
            setExternalConversionEnabled(enabled: gitExternalConversionEnabled)
            applyExternalConversionSetting()
        }
        .onChange(of: gitExternalConversionEnabled) { _, enabled in
            setExternalConversionEnabled(enabled: enabled)
            applyExternalConversionSetting()
            refreshAll(showFeedback: false)
        }
        .focusedValue(\.arborRepositoryIsShallow, projectRepo == nil ? nil : isShallowRepository)
        .focusedValue(\.arborRepositoryAvailable, repo != nil)
        .focusedValue(\.arborVCSActionContext, vcsActionContext)
        .focusedValue(
            \.arborVCSOperationContext,
            operationState.flatMap { state in
                repo?.workdir().map {
                    ArborVCSOperationContext(
                        rootPath: $0,
                        kind: state.kind,
                        hasConflicts: !state.conflictedFiles.isEmpty
                    )
                }
            }
        )
        .background {
            if externalLogWindow {
                ExternalLogWindowLifecycleView(onClosed: disposeExternalLogSession)
            }
        }
        .onDisappear {
            vcsQuickActionsPanel.close()
            if externalLogWindow {
                disposeExternalLogSession()
            }
        }
    }

    var body: some View {
        workspaceLifecycleView
        // 后半段修饰符链（拆分以降低单表达式类型检查复杂度）
        .overlay(alignment: .trailing) {
            conflictResolverOverlays
        }
        .sheet(isPresented: $showHooksPanel) {
            HooksPanelView(
                hooks: gitHooks,
                location: gitHooksLocation,
                contents: gitHookContents,
                busy: gitHooksBusy,
                feedback: gitHooksFeedback,
                selectedName: $selectedGitHook,
                draft: $gitHookDraft,
                onRefresh: { reloadGitHooks() },
                onSelect: { selectGitHook($0) },
                onSave: { saveGitHookDraft() },
                onRevert: { revertGitHookDraft() },
                onToggleEnabled: { toggleGitHookEnabled($0) },
                onInstallSample: { installGitHookSample($0) },
                onDelete: { deleteGitHook($0) },
                onDismiss: { showHooksPanel = false }
            )
        }
        .sheet(isPresented: $showLfsPanel) {
            LfsPanelView(
                capability: lfsCapability,
                patterns: lfsPatterns,
                files: lfsFiles,
                hooks: lfsHooks,
                busy: lfsBusy,
                feedback: lfsFeedback,
                selectedPaths: $lfsSelectedPaths,
                trackInput: $lfsTrackInput,
                showAllRevisions: $lfsShowAllRevisions,
                remoteName: $lfsRemoteName,
                onRefresh: { reloadLfsState() },
                onTrack: { lfsTrackCurrentInput() },
                onUntrack: { lfsUntrack($0) },
                onInstall: { lfsInstallHooks() },
                onUninstall: { lfsUninstallHooks() },
                onFetch: { lfsFetchObjects() },
                onPull: { lfsPullObjects() },
                onPush: { lfsPushObjects() },
                onPrune: { lfsPruneObjects() },
                onCheckout: { lfsCheckoutPointers() },
                onDismiss: { showLfsPanel = false }
            )
        }
        .sheet(isPresented: $showRevisionBrowser) {
            if let repo = logRepository, let commit = revisionBrowserCommit {
                RevisionBrowserView(
                    repo: repo,
                    revision: commit.id,
                    commitTitle: commit.summary,
                    initialPath: revisionBrowserPath
                )
            }
        }
        .sheet(item: $fileReferenceComparisonRequest) { request in
            FileReferenceComparisonView(
                repo: request.repo,
                path: request.path,
                isDirectory: request.isDirectory,
                mode: request.mode,
                onClose: { fileReferenceComparisonRequest = nil }
            )
        }
        .sheet(item: $currentRevisionRequest) { request in
            CurrentRevisionView(
                path: request.path,
                commit: request.commit,
                onClose: { currentRevisionRequest = nil }
            )
        }
        .sheet(isPresented: $showSubmoduleLog) {
            SubmoduleLogView(
                path: submoduleLogPath,
                commits: submoduleLogEntries,
                error: submoduleLogError,
                onClose: { showSubmoduleLog = false }
            )
        }
        .sheet(item: $branchDeleteRecovery) { context in
            BranchDeleteRecoveryView(
                preview: context.preview,
                rootPath: context.rootPath,
                trackedRemoteBranch: context.trackedRemoteBranch,
                onRestore: {
                    restoreDeletedBranch(context)
                },
                onDeleteTrackedRemote: {
                    deleteTrackedRemoteBranch(context)
                },
                onDone: {
                    branchDeleteRecovery = nil
                }
            )
        }
        .sheet(item: $multiRootBranchDeleteRecovery) { context in
            RebasedMultiRootBranchDeleteRecoveryView(
                branchName: context.branchName,
                contexts: context.contexts,
                onRestore: {
                    restoreDeletedBranches(context.contexts)
                },
                onDeleteTrackedRemote: { remoteBranch in
                    deleteTrackedRemoteBranch(remoteBranch, contexts: context.contexts)
                },
                onDone: {
                    multiRootBranchDeleteRecovery = nil
                }
            )
        }
        .sheet(item: $tagDeleteRecovery) { context in
            TagDeleteRecoveryView(
                tag: context.tag,
                rootPath: context.rootPath,
                remotes: context.remotes,
                onRestore: {
                    restoreDeletedTag(context)
                },
                onDeleteRemote: {
                    deleteRemoteTagFromRecovery(context)
                },
                onDone: {
                    tagDeleteRecovery = nil
                }
            )
        }
        .sheet(isPresented: $showRemoteTagsDialog) {
            if let repo {
                RemoteTagsDialogView(
                    repo: repo,
                    broker: credentialAuth.broker,
                    remotes: remotes,
                    onDeleted: { remote, tag in
                        feedbackCenter.success("Remote tag deleted", detail: "\(remote)/\(tag)")
                        refreshAll(showFeedback: false)
                    },
                    onDone: {
                        showRemoteTagsDialog = false
                    }
                )
            } else {
                ProgressView()
                    .frame(width: 640, height: 500)
            }
        }
        .sheet(isPresented: $showMultiRootRemoteTagsDialog) {
            MultiRootRemoteTagsDialogView(
                roots: multiRoots,
                broker: credentialAuth.broker,
                onResult: { successes, failures, cancelled in
                    loadMultiRoots()
                    refreshAll(showFeedback: false)
                    if cancelled {
                        feedbackCenter.warning(
                            "Remote tag deletion canceled",
                            detail: "Deleted \(successes.count) before cancellation; remaining selections were kept."
                        )
                    } else if failures.isEmpty {
                        feedbackCenter.success(
                            "Remote tags deleted",
                            detail: successes.joined(separator: " | ")
                        )
                    } else {
                        feedbackCenter.warning(
                            "Remote tag deletion partially completed",
                            detail: "Deleted \(successes.count); failed \(failures.count)",
                            actionTitle: "Open Remote Tags",
                            action: { showMultiRootRemoteTagsDialog = true }
                        )
                    }
                },
                onDone: {
                    showMultiRootRemoteTagsDialog = false
                }
            )
        }
        .sheet(item: $multiRootTagDeleteRecovery) { context in
            RebasedMultiRootTagDeleteRecoveryView(
                tagName: context.tagName,
                contexts: context.contexts,
                onRestore: {
                    restoreDeletedTags(context.contexts)
                },
                onDeleteRemote: {
                    deleteRemoteTagsFromRecovery(context.contexts)
                },
                onDone: {
                    multiRootTagDeleteRecovery = nil
                }
            )
        }
        .sheet(isPresented: $showFindMergedBranchesDialog, onDismiss: dismissFindMergedBranches) {
            FindMergedBranchesDialogView(
                roots: findMergedBranchesRoots,
                projectName: projectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "",
                targetBranch: $findMergedTargetBranch,
                prefix: $findMergedPrefix,
                isRunning: findMergedRunning,
                hasCalculated: findMergedHasCalculated,
                summary: findMergedSummary,
                onCalculate: calculateFindMergedBranches,
                onOpenReport: openFindMergedReport,
                onCopy: copyFindMergedBranches,
                onDone: dismissFindMergedBranches,
                onCancel: cancelFindMergedBranches
            )
        }
        .sheet(isPresented: $showFindMergedReport) {
            FindMergedReportEditorView(report: findMergedReportText)
        }
        .sheet(isPresented: $showMultiRootChanges) {
            MultiRootChangesBrowser(
                groups: multiRootChangeGroups,
                isLoading: multiRootChangesLoading,
                error: multiRootChangesError,
                onRefresh: loadMultiRootChanges,
                onStage: stageMultiRootPath,
                onUnstage: unstageMultiRootPath,
                onStageSelected: stageMultiRootPaths,
                onUnstageSelected: unstageMultiRootPaths,
                onCommitSelected: { selectedChanges in
                    showMultiRootChanges = false
                    DispatchQueue.main.async {
                        openMultiRootCommitDialog(selectedChanges)
                    }
                },
                onStageAll: stageAllMultiRootPath,
                onUnstageAll: unstageAllMultiRootPath
            )
        }
        .sheet(isPresented: $showMultiRootCommitDialog) {
            MultiRootCommitDialogView(
                groups: multiRootChangeGroups.map(MultiRootCommitGroup.init(changeGroup:)),
                isLoading: multiRootChangesLoading,
                error: multiRootChangesError,
                recentMessages: multiRootCommitRecentMessages,
                onTemplate: loadMultiRootCommitTemplate,
                onBeforeCommitSettings: { showBeforeCommitSettings = true },
                onIdentitySettings: { showIdentitySettings = true },
                message: $multiRootCommitMessage,
                amendMode: $multiRootCommitAmendMode,
                skipHooks: $multiRootCommitSkipHooks,
                authorName: $multiRootCommitAuthorName,
                authorEmail: $multiRootCommitAuthorEmail,
                committerName: $multiRootCommitCommitterName,
                committerEmail: $multiRootCommitCommitterEmail,
                signOff: $multiRootCommitSignOff,
                coAuthors: $multiRootCommitCoAuthors,
                selectedChanges: multiRootCommitSelectedPaths,
                onCommit: commitMultiRootSelectedRoots,
                onCommitAndPush: commitAndPushMultiRootSelectedRoots,
                onCommitSelectedChanges: commitMultiRootSelectedChanges,
                onCommitAndPushSelectedChanges: commitAndPushMultiRootSelectedChanges,
                onCancel: { showMultiRootCommitDialog = false }
            )
        }
        .onChange(of: showMergeRevisionsDialog) { _, isPresented in
            if !isPresented { mergeInitialPath = nil }
        }
        .alert("打开另一个项目？", isPresented: $showProjectSwitchAlert) {
            Button("替换当前窗口") { replacePendingProject() }
            Button("新窗口") {
                openWindow(id: "project", value: pendingProjectPath)
                pendingProjectPath = nil
            }
            Button("取消", role: .cancel) { pendingProjectPath = nil }
        } message: {
            Text("当前窗口正在显示 \(projectRepo?.displayName() ?? "一个项目")。选择如何打开新项目。")
        }
        .alert("Create .gitignore?", isPresented: Binding(
            get: { pendingIgnoreFileCreation != nil },
            set: { isPresented in
                if !isPresented { pendingIgnoreFileCreation = nil }
            }
        )) {
            Button("Create") {
                confirmPendingIgnoreFileCreation()
            }
            Button("Cancel", role: .cancel) {
                pendingIgnoreFileCreation = nil
            }
        } message: {
            if let request = pendingIgnoreFileCreation {
                Text(
                    "No suitable .gitignore exists in the repository root. "
                        + "Create one and ignore \(request.paths.count) selected "
                        + (request.paths.count == 1 ? "path" : "paths") + "?"
                )
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleProjectDrop)
        .onAppear {
            handleContentViewAppearAndLoadRoots()
        }
        .onChange(of: branchCleanupWindow.action) { _, action in
            handleBranchCleanupAction(action)
        }
        .sheet(isPresented: $credentialAuth.isPresented) {
            CredentialDialogView(controller: credentialAuth)
        }
        .sheet(item: $multiRootRemoteConfigAggregateContext) { context in
            MultiRootRemoteConfigDialogView(
                roots: context.roots,
                onAdd: { rootPath, name, url, fetchAfterAdd, completion in
                    addRemoteInRoot(
                        rootPath: rootPath,
                        name: name,
                        url: url,
                        fetchAfterAdd: fetchAfterAdd,
                        completion: completion
                    )
                },
                onEdit: { rootPath, oldName, name, url, pushURL, fetchRefspec, pushRefspec, fetchAfterEdit, completion in
                    updateRemoteInRoot(
                        rootPath: rootPath,
                        oldName: oldName,
                        name: name,
                        url: url,
                        pushURL: pushURL,
                        fetchRefspec: fetchRefspec,
                        pushRefspec: pushRefspec,
                        fetchAfterUpdate: fetchAfterEdit,
                        completion: completion
                    )
                },
                onRemove: { rootPath, name in
                    removeRemoteInRoot(rootPath: rootPath, name: name)
                },
                onRefresh: loadMultiRootRemoteConfigAggregate,
                onCancel: {
                    multiRootRemoteConfigAggregateContext = nil
                }
            )
        }
        .sheet(isPresented: $showRemoteConfigDialog) {
            remoteConfigSheet
        }
        .sheet(isPresented: $showUpstreamDialog) {
            SetUpstreamDialogView(
                localBranch: upstreamLocalBranch,
                remoteBranches: remoteBranches,
                currentUpstream: syncStatuses.first {
                    $0.branch == upstreamLocalBranch && $0.trackingExists
                }?.upstream,
                onCancel: { showUpstreamDialog = false },
                onSave: saveUpstreamFromDialog
            )
        }
        .sheet(item: $multiRootUpstreamContext) { context in
            SetUpstreamDialogView(
                localBranch: context.localBranch,
                remoteBranches: context.remoteBranches,
                currentUpstream: context.currentUpstream,
                repositoryName: context.displayName,
                onCancel: { multiRootUpstreamContext = nil },
                onSave: { upstream in
                    multiRootUpstreamContext = nil
                    setBranchUpstreamInRoot(
                        rootPath: context.rootPath,
                        branch: context.localBranch,
                        upstream: upstream,
                        requireCurrentBranch: true
                    )
                }
            )
        }
        .sheet(isPresented: $showRebaseTodoEditor) {
            rebaseTodoSheet
        }
        .sheet(isPresented: $showRawRebaseTodoEditor) {
            rebaseRawTodoSheet
        }
        .sheet(isPresented: $showRawRebaseMessageEditor) {
            RawRebaseMessageEditorView(
                message: $rawRebaseMessageText,
                onSave: submitRawRebaseMessage,
                onCancel: cancelRawRebaseMessage
            )
        }
        .sheet(isPresented: $logRewrite.showRewordDialog) {
            if let commit = logRewrite.rewordCommit {
                LogRewordDialogView(
                    commit: commit,
                    message: $logRewrite.rewordMessage,
                    onCancel: {
                        logRewrite.showRewordDialog = false
                        logRewrite.rewordCommit = nil
                        logRewrite.rewordUsesRootRebase = false
                    },
                    onConfirm: submitLogHeadReword
                )
            }
        }
        .sheet(isPresented: $logRewrite.showSquashDialog) {
            LogSquashDialogView(
                commitSummaries: logRewrite.squashSummaries,
                message: $logRewrite.squashMessage,
                onCancel: {
                    logRewrite.showSquashDialog = false
                    logRewrite.squashIndexes = []
                    logRewrite.squashSummaries = []
                },
                onConfirm: submitLogSquash
            )
        }
        .alert("Rewrite Initial Commit?", isPresented: $showInitialCommitRewordAlert) {
            Button("Continue") {
                confirmInitialCommitReword()
            }
            Button("Cancel", role: .cancel) {
                pendingInitialCommitReword = nil
                logRewrite.rewordCommit = nil
                logRewrite.rewordUsesRootRebase = false
            }
        } message: {
            Text("The initial commit has no parent. Continue with this history rewrite?")
        }
        .alert("Rewrite Initial Commit?", isPresented: $showInitialCommitRewriteAlert) {
            Button("Continue") {
                confirmInitialCommitRewrite()
            }
            Button("Cancel", role: .cancel) {
                pendingInitialCommitRewrite = nil
            }
        } message: {
            Text("The selected history includes the initial commit. Continue with this history rewrite?")
        }
        .onReceive(NotificationCenter.default.publisher(for: .arborOpenProjectPanel)) { _ in
            showOpenPanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .arborInitProjectPanel)) { _ in
            showInitializePanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .arborCloneProjectDialog)) { _ in
            showCloneDialog = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .arborOpenCommitDetail)) { notification in
            guard let id = notification.object as? String else { return }
            toolWindowMode = .log
            toolWindowExpanded = true
            projectPanelExpanded = false
            logList.viewMode = .graph
            // A commit-detail notification can originate from the Commit
            // workspace (for example, Show History on a changed file). The
            // Log editor owns this context after the hand-off; leaving the
            // old staging/file selection alive makes mainContext render a
            // diff viewer over the Log workspace and looks like the history
            // page disappeared.
            selection = nil
            fileSelection = nil
            selectionModePath = nil
            commitPreviewPath = nil
            commitPreviewVisible = false
            commitPreviewThreeVersions = false
            logSelectionState.selection = id
            logSelectionState.selectedIDs = [id]
            loadCommitDetailsIfNeeded(id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .arborOpenMultiRootConflictResolver)) { notification in
            openMultiRootConflictResolver(
                preferredRootPath: notification.userInfo?["rootPath"] as? String,
                preferredPath: notification.userInfo?["path"] as? String
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .arborRollbackMerge)) { notification in
            guard let request = notification.object as? MergeRollbackRequest else { return }
            rollbackMerge(request)
        }
        .onReceive(NotificationCenter.default.publisher(for: .arborVCSAction)) { notification in
            handleArborVCSActionNotification(notification)
        }
        .sheet(isPresented: $showSearchEverywhere) {
            SearchEverywhereView(
                roots: searchEverywhereGitRoots,
                query: $searchEverywhereQuery,
                onSelect: { item in
                    showSearchEverywhere = false
                    searchEverywhereQuery = ""
                    switch item.kind {
                    case .localBranch, .remoteBranch, .tag:
                        navigateLogToBranch(rootPath: item.rootPath, branch: item.revision)
                    case .commitByHash, .commitByMessage:
                        navigateLogToRevision(rootPath: item.rootPath, revision: item.revision)
                    }
                },
                onCancel: {
                    showSearchEverywhere = false
                    searchEverywhereQuery = ""
                }
            )
        }
    }

    func presentVCSQuickActionsPanel() {
        let hasUnstagedChanges = entries.contains {
            $0.unstaged != .unchanged
                && $0.unstaged != .ignored
                && $0.unstaged != .conflicted
        }
        vcsQuickActionsPanel.present(
            items: vcsQuickActionItems(
                isShallowRepository: isShallowRepository,
                hasCurrentBranch: hasCurrentBranch,
                hasConflicts: hasConflicts,
                hasUnstagedTrackedChanges: vcsActionContext.hasUnstagedTrackedChanges,
                hasUnstagedChanges: hasUnstagedChanges,
                hasRepository: repo != nil,
                hasCommitChanges: vcsActionContext.hasLocalChanges,
                hasFetchInProgress: vcsActionContext.hasFetchInProgress
            ),
            onAction: { action in
                NotificationCenter.default.post(
                    name: .arborVCSAction,
                    object: action.rawValue
                )
            }
        )
    }

    private var hasCurrentBranch: Bool {
        branches.contains { $0.isCurrent }
    }

    private var hasConflicts: Bool {
        entries.contains {
            $0.staged == .conflicted || $0.unstaged == .conflicted
        }
    }

    var vcsActionContext: ArborVCSActionContext {
        let hasLocalChanges = entries.contains {
            ($0.staged != .unchanged && $0.staged != .ignored)
                || ($0.unstaged != .unchanged && $0.unstaged != .ignored)
        }
        let hasUnstagedTrackedChanges = entries.contains {
            $0.unstaged != .unchanged
                && $0.unstaged != .untracked
                && $0.unstaged != .ignored
                && $0.unstaged != .conflicted
        }
        let hasStagedChanges = entries.contains {
            $0.staged != .unchanged && $0.staged != .ignored
        }
        let hasProjectCommitChanges = multiRootChangeGroups.contains { group in
            group.entries.contains {
                $0.staged != .unchanged
                    && $0.staged != .ignored
                    && $0.staged != .conflicted
            }
        }
        let allRepositoriesHaveHeadCommit: Bool
        if multiRoots.isEmpty {
            allRepositoriesHaveHeadCommit = headId != nil
        } else {
            allRepositoriesHaveHeadCommit = multiRoots.allSatisfy { $0.headId != nil }
        }
        return ArborVCSActionContext(
            hasRepository: repo != nil,
            allRepositoriesHaveHeadCommit: allRepositoriesHaveHeadCommit,
            hasCurrentBranch: hasCurrentBranch,
            hasLocalChanges: hasLocalChanges,
            hasUnstagedTrackedChanges: hasUnstagedTrackedChanges,
            hasStagedChanges: hasStagedChanges,
            hasConflicts: hasConflicts,
            isShallowRepository: isShallowRepository,
            hasRemotes: !remotes.isEmpty,
            hasFetchInProgress: isArborFetchInProgress(
                isRunning: feedbackCenter.isRunning,
                operationName: feedbackCenter.operationName
            ),
            hasBackgroundVCSOperation: isArborBackgroundVCSOperationInProgress(
                feedbackIsRunning: feedbackCenter.isRunning,
                multiRootIsRunning: multiRootRunning || updateProjectDiscoveryRunning
            ),
            projectPath: projectPath,
            hasMultipleGitRoots: multiRoots.count > 1,
            hasProjectCommitChanges: hasProjectCommitChanges || hasStagedChanges,
            hasTrackedUpstream: currentSyncStatus.map {
                $0.trackingExists && !$0.upstream.isEmpty
            } ?? false,
            hasSingleGitRoot: multiRoots.count == 1,
            hasRepositoryOperationInProgress: operationState != nil
                || multiRoots.contains { $0.operation != nil },
            hasMergeInProgress: isArborMergeInProgress(
                currentOperation: operationState?.kind,
                roots: multiRoots
            ),
            hasRebaseInProgress: isArborRebaseInProgress(
                currentOperation: operationState?.kind,
                roots: multiRoots,
                hasMultiRootSession: multiRootRebaseSession != nil
            ),
            hasNormalOrDetachedRepository: hasArborNormalOrDetachedRepository(
                currentOperation: operationState?.kind,
                currentRootPath: repo?.workdir(),
                roots: multiRoots
            ),
            selectedLocalChangePath: selectedLocalChangePath,
            selectedResolvedConflictPath: selectedWorkspacePath.flatMap {
                resolvedConflictPaths.contains($0) ? $0 : nil
            },
            selectedFileAction: selectedFileActionContext
        )
    }

    var resetHeadRootOptions: [GitRootInfo] {
        if !multiRoots.isEmpty {
            return multiRoots.filter { $0.operation == nil }
        }
        guard let rootPath = repo?.workdir(), !rootPath.isEmpty else { return [] }
        return [GitRootInfo(
            path: rootPath,
            displayName: URL(fileURLWithPath: rootPath).lastPathComponent,
            relativePath: ".",
            isSubmodule: false,
            headBranch: branches.first(where: { $0.isCurrent })?.name,
            headId: nil,
            dirty: entries.contains {
                $0.staged != .unchanged || $0.unstaged != .unchanged
            },
            operation: operationState?.kind
        )]
    }

    var stashRootOptions: [GitRootInfo] {
        if !multiRoots.isEmpty {
            return multiRoots
        }
        return resetHeadRootOptions
    }

    private func applyExternalConversionSetting() {
        _ = try? repo?.setExternalConversionEnabled(enabled: gitExternalConversionEnabled)
    }

    /// 主内容（VStack 及其前置修饰符）。
    @ViewBuilder
    private var mainView: some View {
        if externalLogWindow {
            logWorkspace
                .frame(minWidth: 980, minHeight: 540)
                .background(Design.Colors.canvas)
        } else {
            fullMainView
        }
    }

    private var fullMainView: some View {
        VStack(spacing: 0) {
            RebasedTopBar(
                // Keep the requested/recovered project identity visible while
                // the repository is opening. Showing the generic Arbor shell
                // during that interval makes a valid project launch look like
                // the welcome page and differs from rebased's project window.
                projectName: projectRepo?.displayName()
                    ?? projectPath.map { URL(fileURLWithPath: $0).lastPathComponent }
                    ?? "Arbor",
                projectPath: projectPath,
                currentBranch: currentBranchName,
                hasRepository: repo != nil,
                isLoading: isLoading || feedbackCenter.isRunning,
                onOpenProject: showOpenPanel,
                onRefresh: refreshAll,
                onUpdate: { doPull(nil, rebase: false) },
                onCommit: {
                    toolWindowMode = .commit
                    toolWindowExpanded = true
                },
                onPush: { beginPushDialog() },
                onFetch: { doFetch(nil) },
                onHosting: { showHostingHub = true },
                isShallowRepository: isShallowRepository,
                hasCurrentBranch: branches.contains { $0.isCurrent },
                hasConflicts: entries.contains {
                    $0.staged == .conflicted || $0.unstaged == .conflicted
                },
                onQuickAction: { action in
                    NotificationCenter.default.post(
                        name: .arborVCSAction,
                        object: action.rawValue
                    )
                },
                onSearch: {
                    searchEverywhereQuery = ""
                    showSearchEverywhere = true
                },
                recentProjects: loadRecentPaths(),
                onOpenRecent: requestOpenProject,
                operationItems: gitMergeRebaseWidgetItems(
                    currentRootPath: repo?.workdir(),
                    currentOperation: operationState?.kind,
                    roots: multiRoots
                ),
                currentOperationState: operationState,
                resolvedConflictPaths: resolvedConflictPaths,
                onRevertResolved: revertResolvedPath,
                onOperationAction: { action, rootPath in
                    handleVCSActionRequest(
                        ArborVCSActionRequest(
                            kind: .operationRecovery,
                            projectPath: projectPath,
                            rootPath: rootPath,
                            shelfName: "",
                            operationRecoveryAction: action
                        )
                    )
                }
            ) {
                branchPopup
            }

            WorkspaceSplitLayout(
                persistedSidebarWidth: $savedWorkspaceSidebarWidth,
                selectedToolWindow: toolWindowMode,
                // Rebased keeps the selected Git tool window on the left and
                // opens Git Log in the editor workspace on the right. Log is
                // therefore a second workspace, not a replacement for the
                // Commit/Stash column.
                sidebarVisible: true,
                onSelectToolWindow: { mode in
                    toolWindowMode = mode
                    toolWindowExpanded = true
                    if mode == .log {
                        projectPanelExpanded = false
                        // Git Log is an editor-like workspace, not a narrow
                        // tool-window table. Clear file context so the main
                        // workspace can own the history graph and inspector.
                        selection = nil
                        fileSelection = nil
                        selectionModePath = nil
                        logList.viewMode = .graph
                        loadLog()
                    }
                },
                onOpenProject: toggleProjectToolWindow
            ) {
                workspaceSidebar
            } mainContent: {
                mainContext
            }

            RebasedStatusBar(
                branch: currentBranchName,
                headID: headId,
                changedCount: entries.filter {
                    $0.staged != .unchanged
                        || ($0.unstaged != .unchanged && $0.unstaged != .ignored)
                }.count,
                projectPath: projectPath,
                onBranch: { showBranchesPopover = true },
                feedbackCenter: feedbackCenter,
                syncStatus: currentSyncStatus,
                hasUnfetchedIncoming: currentBranchHasUnfetchedIncoming,
                onOperationLog: {
                    operationsViewMode = feedbackCenter.isRunning ? .tasks : .history
                    toolWindowMode = .operations
                    toolWindowExpanded = true
                },
                onCancelOperation: feedbackCenter.cancel,
                onFeedbackDetails: { feedbackDetailMessage = $0 }
            )
        }
        .frame(minWidth: 980, minHeight: 540)
        .background(Design.Colors.canvas)
        .onChange(of: toolWindowMode, initial: false) { _, mode in
            UserDefaults.standard.set(mode.rawValue, forKey: "arbor.toolWindowMode")
            if mode == .commit {
                refreshAll()
            } else if mode != .log {
                // Do not let a history scan continue while another tool
                // window owns the main workspace.
                logList.refreshTask?.cancel()
                logList.refreshTask = nil
                logList.loadTask?.cancel()
                logList.loadTask = nil
                logList.generation += 1
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let toast = feedbackCenter.toast {
                FeedbackToastView(
                    message: toast,
                    onDetails: { feedbackDetailMessage = toast },
                    onDismiss: feedbackCenter.dismissToast
                )
                .padding(.trailing, 18)
                .padding(.bottom, 42)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .sheet(item: $feedbackDetailMessage) { message in
            FeedbackDetailView(
                message: message,
                onDismiss: { feedbackDetailMessage = nil },
                onOpenSSHSettings: {
                    feedbackDetailMessage = nil
                    loadGitSSHSettings()
                }
            )
        }
        .alert("GitHub authentication failed", isPresented: $showHostingAuthPrompt) {
            Button("Configure GitHub token") { showHostingSettings = true }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Configure a GitHub token in Settings, then retry the git operation.")
        }
        .sheet(isPresented: $showHostingSettings) {
            if let hostingRepository {
                HostingSettingsView(repository: hostingRepository)
            } else {
                Text("No supported hosting remote is configured.")
                    .padding(24)
            }
        }
        .sheet(isPresented: $showHostingHub) {
            HostingHubView(
                remoteURL: remotes.first(where: { HostingProvider.parse(remoteURL: $0.url) != nil })?.url,
                showSettings: $showHostingSettings,
                onCheckoutIncomingBranch: { detail in
                    guard let projectPath,
                          let branch = detail.pullRequest.headBranch,
                          !branch.isEmpty,
                          let remote = remotes.first(where: { HostingProvider.parse(remoteURL: $0.url) != nil }) else {
                        feedbackCenter.error(
                            "Checkout incoming branch failed",
                            detail: "The hosting change request is not connected to an available Git root or remote."
                        )
                        return
                    }
                    showHostingHub = false
                    checkoutBranchInRoot(
                        rootPath: projectPath,
                        reference: "\(remote.name)/\(branch)",
                        isRemote: true
                    )
                },
                onShowInGitLog: { detail in
                    guard let projectPath,
                          let revision = detail.headRevision,
                          !revision.isEmpty else {
                        feedbackCenter.error(
                            "Open in Git Log failed",
                            detail: "The hosting provider did not return a head revision."
                        )
                        return
                    }
                    showHostingHub = false
                    toolWindowMode = .log
                    toolWindowExpanded = true
                    navigateLogToRevision(rootPath: projectPath, revision: revision)
                }
            )
            .frame(minWidth: 980, minHeight: 620)
        }
        .sheet(isPresented: $showReviewComment) {
            if let commit = reviewCommentCommit,
               let repository = reviewCommentRepository ?? hostingRepository {
                ReviewCommentSheet(
                    repository: repository,
                    commitID: commit.id,
                    client: HostingClientFactory.make(for: repository)
                )
        }
    }
        .sheet(item: $addCommitsToRemoteBranchContext) { context in
            RebasedRemoteBranchSelectionDialog(
                commits: context.commits,
                remoteBranches: context.remoteBranches,
                onCancel: { addCommitsToRemoteBranchContext = nil },
                onSelect: { remoteBranch in
                    addCommitsToRemoteBranchContext = nil
                    prepareAddCommitsToRemoteBranch(remoteBranch, commits: context.commits)
                }
            )
        }
        .sheet(isPresented: $showMultiRootPushOptions) {
            MultiRootPushOptionsDialog(
                snapshots: multiRootBranchSnapshots.filter { snapshot in
                    guard let selected = multiRootPushOptionsRootPaths else { return true }
                    return selected.contains(snapshot.rootPath)
                },
                onCancel: {
                    showMultiRootPushOptions = false
                    multiRootPushOptionsRootPaths = nil
                    multiRootPushOptionsFromCommit = false
                },
                onPush: { targets, tagMode, skipHooks, force, forceWithLease in
                    let rootPaths = multiRootPushOptionsRootPaths
                    let fromCommit = multiRootPushOptionsFromCommit
                    showMultiRootPushOptions = false
                    multiRootPushOptionsRootPaths = nil
                    multiRootPushOptionsFromCommit = false
                    runMultiRootPush(
                        selectedRootPaths: rootPaths,
                        explicitTargets: targets,
                        tagMode: tagMode,
                        skipHooks: skipHooks,
                        force: force,
                        forceWithLease: forceWithLease,
                        fromCommit: fromCommit
                    )
                }
            )
        }
        .sheet(isPresented: $showPushDialog) {
            PushDialogView(
                remotes: remotes,
                branches: branches,
                commits: logList.entries,
                mode: pushDialogMode,
                defaultRemote: pushDialogRemote,
                defaultBranch: pushDialogBranch
                    ?? branches.first(where: { $0.isCurrent })?.name,
                defaultSourceRevision: pushDialogSourceRevision,
                currentHasUpstream: syncStatuses.first(where: {
                    $0.branch == (pushDialogSourceRevision ?? currentBranchName)
                })?.trackingExists ?? false,
                protectedBranchPatterns: effectiveProtectedBranchPatterns,
                defaultRefspec: pushDialogRefspec,
                defaultPushTagMode: GitPushTagSettings.projectTagMode(for: projectPath),
                defaultRunHooks: true,
                onCancel: {
                    showPushDialog = false
                    pushDialogRefspec = nil
                    pushDialogRemote = nil
                    pushDialogBranch = nil
                    pushDialogSourceRevision = nil
                },
                onPush: { remote, branch, force, setUpstream, forceWithLease, refspec, tagMode, skipHooks in
                    showPushDialog = false
                    pushDialogRefspec = nil
                    pushDialogRemote = nil
                    pushDialogBranch = nil
                    pushDialogSourceRevision = nil
                    if pushDialogMode == .commitAndPush {
                        commitAndPush(
                            remote: remote,
                            branch: branch,
                            force: force,
                            forceWithLease: forceWithLease,
                            setUpstream: setUpstream
                        )
                    } else {
                        doPush(
                            remote,
                            branch: branch,
                            force: force,
                            forceWithLease: forceWithLease,
                            setUpstream: setUpstream,
                            refspec: refspec,
                            tagMode: tagMode,
                            skipHooks: skipHooks
                        )
                    }
                },
                onConfigureRemotes: {
                    showPushDialog = false
                    beginConfigureRemotes()
                },
                onConfigureSSH: {
                    showPushDialog = false
                    loadGitSSHSettings()
                },
                repo: repo
            )
        }
        .sheet(item: $multiRootPushContext) { context in
            PushDialogView(
                remotes: context.remotes,
                branches: context.branches,
                commits: context.commits,
                mode: .push,
                defaultRemote: context.defaultRemote,
                defaultBranch: context.defaultBranch,
                defaultSourceRevision: context.defaultSourceRevision,
                currentHasUpstream: context.currentHasUpstream,
                protectedBranchPatterns: context.protectedBranchPatterns,
                defaultRefspec: nil,
                defaultPushTagMode: context.defaultPushTagMode,
                defaultRunHooks: true,
                onCancel: {
                    multiRootPushContext = nil
                },
                onPush: { remote, branch, force, setUpstream, forceWithLease, refspec, tagMode, skipHooks in
                    multiRootPushContext = nil
                    pushInRoot(
                        rootPath: context.rootPath,
                        remote: remote,
                        branch: branch,
                        force: force,
                        forceWithLease: forceWithLease,
                        setUpstream: setUpstream,
                        refspec: refspec,
                        tagMode: tagMode,
                        skipHooks: skipHooks
                    )
                },
                onConfigureRemotes: {
                    multiRootPushContext = nil
                    DispatchQueue.main.async {
                        beginMultiRootRemoteConfig(rootPath: context.rootPath)
                    }
                },
                onConfigureSSH: {},
                showsConfigurationActions: true,
                showsSSHConfigurationAction: false,
                repo: context.repo
            )
        }
        .sheet(item: $multiRootRemoteConfigContext) { context in
            RemoteConfigDialogView(
                remotes: context.remotes,
                name: $multiRootRemoteName,
                url: $multiRootRemoteURL,
                pushUrl: $multiRootRemotePushURL,
                fetchRefspec: $multiRootRemoteFetchRefspec,
                pushRefspec: $multiRootRemotePushRefspec,
                initialSelectedName: multiRootRemoteName,
                onAdd: { fetchAfterAdd in
                    addRemoteInRoot(rootPath: context.rootPath, fetchAfterAdd: fetchAfterAdd)
                },
                onRemove: { name in
                    removeRemoteInRoot(rootPath: context.rootPath, name: name)
                },
                onRename: { old, new in
                    renameRemoteInRoot(rootPath: context.rootPath, old: old, new: new)
                },
                onSave: {
                    saveRemoteConfigInRoot(rootPath: context.rootPath)
                },
                onCancel: {
                    multiRootRemoteConfigContext = nil
                },
                onRefresh: {
                    loadMultiRootRemoteConfig(rootPath: context.rootPath)
                }
            )
        }
        .sheet(isPresented: $showBeforeCommitSettings) {
            beforeCommitSettingsSheet
        }
        .sheet(isPresented: $showProjectGitSettings) {
            if let projectPath {
                ProjectGitIncomingChangesSettingsView(
                    projectPath: projectPath,
                    rootPaths: GitExecutableSettings.registeredRoots(
                        projectPath: projectPath,
                        repositoryRoot: repo?.workdir(),
                        discoveredRoots: multiRoots.map(\.path)
                    ),
                    onSaved: {
                        if let repo {
                            _ = try? repo.setGitExecutableOverride(
                                path: GitExecutableSettings.projectOverride(for: projectPath)
                            )
                        }
                        projectIncomingCheckStrategyRaw = GitIncomingCheckStrategySettings.projectRawValue(
                            for: projectPath
                        )
                        projectFetchTagsMode = GitFetchTagsSettings.mode(for: projectPath)
                        projectUpdateMethod = GitUpdateMethodSettings.method(for: projectPath)
                    }
                )
            } else {
                Text("Open a Git project before changing project Git settings.")
                    .padding(24)
            }
        }
        .sheet(isPresented: $showUpdateProjectOptions) {
            if let projectPath {
                UpdateProjectOptionsDialogView(
                    projectPath: projectPath,
                    rootCount: max(1, multiRoots.count),
                    initialUpdateMethod: projectUpdateMethod,
                    showsResetAction: multiRoots.count == 1,
                    onUpdate: { method, shouldShowNextTime in
                        projectUpdateMethod = method
                        GitUpdateMethodSettings.save(method, for: projectPath)
                        GitUpdateOptionsDialogSettings.saveShouldShow(
                            shouldShowNextTime,
                            for: projectPath
                        )
                        showUpdateProjectOptions = false
                        executeMultiRootUpdate(rebase: method == .rebase)
                    },
                    onResetToRemote: {
                        showUpdateProjectOptions = false
                        DispatchQueue.main.async {
                            resetCurrentBranchToRemote()
                        }
                    },
                    onCancel: {
                        showUpdateProjectOptions = false
                    }
                )
            } else {
                Text("Open a Git project before updating it.")
                    .padding(24)
            }
        }
        .sheet(isPresented: $showIdentitySettings) {
            GitIdentitySettingsView(
                name: $identityName,
                email: $identityEmail,
                setNameEmailGlobally: $identitySetNameEmailGlobally,
                signingKey: $identitySigningKey,
                signingFormat: $identitySigningFormat,
                signCommits: $identitySignCommits,
                authorName: $identityAuthorName,
                authorEmail: $identityAuthorEmail,
                committerName: $identityCommitterName,
                committerEmail: $identityCommitterEmail,
                signOff: $identitySignOff,
                coAuthors: $identityCoAuthors,
                recentAuthors: identityRecentAuthors,
                onSelectRecentAuthor: { author in
                    guard let parsed = GitCommitAuthorHistorySettings.parse(author) else { return }
                    identityAuthorName = parsed.name
                    identityAuthorEmail = parsed.email
                },
                onSave: { setGitIdentity(); showIdentitySettings = false },
                onCancel: {
                    pendingIdentityCommitRetry = false
                    showIdentitySettings = false
                },
                onGpgAgent: {
                    showIdentitySettings = false
                    DispatchQueue.main.async { showGpgAgentSettings = true }
                }
            )
        }
        .sheet(isPresented: $showGpgAgentSettings) {
            GpgAgentSettingsView()
        }
        .onChange(of: showIdentitySettings) { _, isPresented in
            if isPresented {
                identitySetNameEmailGlobally = GitIdentityScopeSettings.setNameEmailGlobally(
                    for: projectPath
                )
                identityRecentAuthors = GitCommitAuthorHistorySettings.authors(for: projectPath)
            }
            if !isPresented && showMultiRootCommitDialog {
                syncMultiRootCommitIdentityDraftFromSettings()
            }
        }
        .sheet(isPresented: $showGitSSHSettings) {
            GitSSHSettingsView(
                command: $gitSSHCommand,
                knownHostsFile: $gitSSHKnownHostsFile,
                identityFile: $gitSSHIdentityFile,
                hostKeyPolicy: $gitSSHHostKeyPolicy,
                authMethod: $gitSSHAuthMethod,
                credentialHelperConfig: $gitCredentialHelperConfig,
                credentialHelpers: gitCredentialHelpers,
                onRefreshCredentialHelpers: loadGitCredentialHelpers,
                sshAgentDiagnostics: gitSSHAgentDiagnostics,
                onRefreshSSHAgentDiagnostics: loadGitSSHAgentDiagnostics,
                lastSuccessfulAuthentications: lastSuccessfulSSHAuthentications,
                onClearLastSuccessfulAuthentications: {
                    credentialAuth.clearSSHAuthenticationRecords()
                    lastSuccessfulSSHAuthentications = []
                },
                onSave: { saveGitSSHSettings(); showGitSSHSettings = false },
                onCancel: { showGitSSHSettings = false }
            )
        }
        .sheet(isPresented: $stashUI.showDiff) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Stash Diff").font(.title3.weight(.semibold))
                ScrollView {
                    Text(stashUI.diffText ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
                HStack {
                    Spacer()
                    Button("Done") {
                        stashUI.showDiff = false
                        stashUI.diffText = nil
                        stashUI.diffStashID = nil
                        stashUI.diffRootPath = nil
                    }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
            .frame(minWidth: 700, minHeight: 460)
        }
        .sheet(isPresented: $showNewBranchDialog) {
            RebasedNewBranchDialog(
                title: newBranchDialogTitle,
                name: $newBranchName,
                baseRevision: $newBranchBase,
                checkout: $newBranchCheckout,
                resetExisting: $newBranchResetExisting,
                validateName: { value in
                    guard let branchRepo = newBranchRepositoryOverride ?? repo else { return nil }
                    do {
                        try branchRepo.validateBranchName(name: value)
                        return nil
                    } catch {
                        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if newBranchResetExisting,
                           newBranchDialogBranches.contains(where: { $0.name == normalized }) {
                            return nil
                        }
                        return errorMessage(error)
                    }
                },
                branches: newBranchDialogBranches,
                onCreate: {
                    let base = newBranchBase.trimmingCharacters(in: .whitespacesAndNewlines)
                    if newBranchAfterCreateRebase {
                        branchCreateAndRebase(
                            at: base.isEmpty ? nil : base,
                            reset: newBranchResetExisting,
                            repository: newBranchRepositoryOverride
                        )
                    } else {
                        branchCreate(
                            at: base.isEmpty ? nil : base,
                            checkout: newBranchCheckout,
                            reset: newBranchResetExisting,
                            repository: newBranchRepositoryOverride
                        )
                    }
                    dismissNewBranchDialog()
                },
                onCancel: dismissNewBranchDialog
            )
        }
        .sheet(isPresented: $showNewWorktreeDialog) {
            RebasedNewWorktreeDialog(
                rootPath: newWorktreeRootPath ?? repo?.workdir(),
                reference: newWorktreeReference,
                isTag: newWorktreeIsTag,
                occupiedBranches: Set(newWorktreeWorktrees.map(\.branch).filter { !$0.isEmpty }),
                validateBranchName: { value in
                    guard let targetRepo = newWorktreeRepository else { return nil }
                    do {
                        try targetRepo.validateBranchName(name: value)
                        if newWorktreeBranches.contains(where: { $0.name == value }) {
                            return "该分支已存在。"
                        }
                        return nil
                    } catch {
                        return errorMessage(error)
                    }
                },
                path: $newWorktreePath,
                branch: $newWorktreeBranch,
                onCreate: { path, branch in
                    createWorktree(
                        path: path,
                        branch: branch,
                        revision: newWorktreeReference,
                        rootPath: newWorktreeRootPath
                    )
                    dismissNewWorktreeDialog()
                },
                onCancel: dismissNewWorktreeDialog
            )
        }
        .sheet(isPresented: $showMultiRootNewBranchDialog) {
            RebasedMultiRootNewBranchDialog(
                name: $multiRootNewBranchName,
                baseRevision: $multiRootNewBranchBase,
                checkout: $multiRootNewBranchCheckout,
                resetExisting: $multiRootNewBranchResetExisting,
                selectedRootPaths: $multiRootSelectedRootPaths,
                roots: multiRoots,
                existingBranchNames: multiRootExistingBranchNames,
                validateName: { value in
                    let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !candidate.isEmpty else { return nil }
                    let selectedPaths = multiRootSelectedRootPaths.isEmpty
                        ? multiRoots.map(\.path)
                        : Array(multiRootSelectedRootPaths)
                    for rootPath in selectedPaths {
                        let exists = multiRootExistingBranchNames[rootPath]?.contains(candidate) == true
                        if multiRootNewBranchResetExisting && exists {
                            continue
                        }
                        guard let rootRepo = try? openRepository(path: rootPath) else { continue }
                        do {
                            try rootRepo.validateBranchName(name: candidate)
                        } catch {
                            return errorMessage(error)
                        }
                    }
                    return nil
                },
                onCreate: {
                    createMultiRootBranch(
                        name: multiRootNewBranchName,
                        baseRevision: multiRootNewBranchBase,
                        checkout: multiRootNewBranchCheckout,
                        reset: multiRootNewBranchResetExisting,
                        selectedRootPaths: multiRootSelectedRootPaths
                    )
                    dismissMultiRootNewBranchDialog()
                },
                onCancel: dismissMultiRootNewBranchDialog
            )
        }
        .sheet(isPresented: $showMultiRootRenameBranchDialog) {
            RebasedMultiRootRenameBranchDialog(
                oldName: multiRootRenameOldName,
                newName: $multiRootRenameNewName,
                unsetUpstream: $multiRootRenameUnsetUpstream,
                selectedRootPaths: $multiRootRenameSelectedRootPaths,
                snapshots: multiRootBranchSnapshots,
                validateName: validateMultiRootRenameName,
                onRename: {
                    renameMultiRootBranch(
                        oldName: multiRootRenameOldName,
                        newName: multiRootRenameNewName,
                        unsetUpstream: multiRootRenameUnsetUpstream,
                        selectedRootPaths: multiRootRenameSelectedRootPaths
                    )
                },
                onCancel: dismissMultiRootRenameBranchDialog
            )
        }
        .sheet(isPresented: $showSingleRootRenameBranchDialog) {
            RebasedSingleRootRenameBranchDialog(
                oldName: singleRootRenameOldName,
                newName: $singleRootRenameNewName,
                unsetUpstream: $singleRootRenameUnsetUpstream,
                hasUpstream: singleRootRenameHasUpstream,
                validateName: { value in
                    validateSingleRootRenameName(
                        rootPath: singleRootRenameRootPath,
                        oldName: singleRootRenameOldName,
                        value: value
                    )
                },
                onRename: {
                    renameBranchInRoot(
                        rootPath: singleRootRenameRootPath,
                        oldName: singleRootRenameOldName,
                        newName: singleRootRenameNewName,
                        unsetUpstream: singleRootRenameUnsetUpstream
                    )
                },
                onCancel: dismissSingleRootRenameBranchDialog
            )
        }
        .sheet(isPresented: $showMultiRootDeleteBranchDialog) {
            RebasedMultiRootDeleteBranchDialog(
                branchName: multiRootDeleteBranchName,
                selectedRootPaths: $multiRootDeleteSelectedRootPaths,
                snapshots: multiRootBranchSnapshots,
                onDelete: {
                    deleteMultiRootBranch(
                        name: multiRootDeleteBranchName,
                        selectedRootPaths: multiRootDeleteSelectedRootPaths
                    )
                },
                onCancel: dismissMultiRootDeleteBranchDialog
            )
        }
        .sheet(isPresented: $showMultiRootDeleteTagDialog) {
            RebasedMultiRootDeleteTagDialog(
                tagName: multiRootDeleteTagName,
                selectedRootPaths: $multiRootDeleteTagSelectedRootPaths,
                snapshots: multiRootBranchSnapshots,
                onDelete: {
                    deleteMultiRootTag(
                        name: multiRootDeleteTagName,
                        selectedRootPaths: multiRootDeleteTagSelectedRootPaths
                    )
                },
                onCancel: dismissMultiRootDeleteTagDialog
            )
        }
        .sheet(isPresented: $showMultiRootRemoteDeleteDialog) {
            RebasedMultiRootRemoteDeleteBranchDialog(
                remoteBranch: multiRootRemoteDeleteBranchName,
                selectedRootPaths: $multiRootRemoteDeleteSelectedRootPaths,
                deleteTracking: $multiRootRemoteDeleteTracking,
                snapshots: multiRootBranchSnapshots,
                onDelete: {
                    deleteMultiRootRemoteBranch(
                        remoteBranch: multiRootRemoteDeleteBranchName,
                        deleteTracking: multiRootRemoteDeleteTracking,
                        selectedRootPaths: multiRootRemoteDeleteSelectedRootPaths
                    )
                },
                onCancel: dismissMultiRootRemoteDeleteDialog
            )
        }
        .sheet(isPresented: $showMergeActionDialog) {
            RebasedMergeDialog(
                branch: $mergeBranch,
                strategy: Binding(
                    get: { MergeStrategyChoice(rawValue: mergeStrategyRaw) ?? .automatic },
                    set: { mergeStrategyRaw = $0.rawValue }
                ),
                commitMessage: $mergeCommitMessage,
                useCustomCommitMessage: $mergeUseCustomCommitMessage,
                noCommit: $mergeNoCommit,
                noVerify: $mergeNoVerify,
                allowUnrelatedHistories: $mergeAllowUnrelatedHistories,
                branches: branches,
                mergedBranches: mergeMergedBranches,
                onMerge: {
                    showMergeActionDialog = false
                    doMerge()
                },
                onCancel: { showMergeActionDialog = false }
            )
        }
        .sheet(isPresented: $showPullDialog) {
            PullDialogView(
                snapshots: pullDialogSnapshots,
                defaultRootPath: repo?.workdir() ?? multiRoots.first?.path,
                defaultRebase: pullDialogRebase,
                initialOptions: GitPullDialogSettingsStore.load(for: projectPath).options,
                blockedRootPaths: Set(
                    multiRoots
                        .filter { $0.operation != nil }
                        .map { canonicalExternalLogPath($0.path) }
                ).union(
                    operationState != nil
                        ? Set([repo?.workdir()].compactMap { $0 }.map(canonicalExternalLogPath))
                        : []
                ),
                fetchInProgress: isArborFetchInProgress(
                    isRunning: feedbackCenter.isRunning,
                    operationName: feedbackCenter.operationName
                ),
                onCancel: {
                    showPullDialog = false
                    pullDialogSnapshots = []
                },
                onPull: { selection in
                    showPullDialog = false
                    pullDialogSnapshots = []
                    savePullDialogSettings(selection.options)
                    executePullDialogSelection(selection)
                },
                onFetch: fetchPullDialogRemote
            )
        }
        .sheet(isPresented: $showRebaseActionDialog) {
            RebasedRebaseDialog(
                onto: $rebaseOnto,
                branch: $rebaseBranch,
                repositoryPath: $rebaseRootPath,
                interactive: $rebaseInteractive,
                preserveMerges: $rebasePreserveMerges,
                autoSquash: $rebaseAutoSquash,
                keepEmpty: $rebaseKeepEmpty,
                updateRefs: $rebaseUpdateRefs,
                root: $rebaseRoot,
                applyToAllRepositories: $rebaseApplyToAllRoots,
                rangeCount: rebaseRange.count,
                repositories: rebaseRepositories,
                branches: rebaseBranchOptions,
                onLoadRange: loadRebaseRange,
                onRangeInputsChanged: invalidateLoadedRebaseRange,
                onRepositoryChanged: selectRebaseRepository,
                onStart: {
                    showRebaseActionDialog = false
                    saveRebaseDialogSettings()
                    if rebaseApplyToAllRoots {
                        if rebaseInteractive {
                            prepareMultiRootRebaseEditor()
                        } else {
                            doMultiRootRebase(drafts: nil)
                        }
                    } else {
                        doRebase()
                    }
                },
                onCancel: { showRebaseActionDialog = false }
            )
        }
        .sheet(isPresented: $showMultiRootRebaseEditor) {
            MultiRootRebaseTodoEditorView(
                onto: rebaseOnto,
                branch: rebaseBranch,
                drafts: $multiRootRebaseDrafts,
                preserveMerges: rebasePreserveMerges,
                autoSquash: rebaseAutoSquash,
                keepEmpty: rebaseKeepEmpty,
                updateRefs: rebaseUpdateRefs,
                root: rebaseRoot,
                onStart: {
                    showMultiRootRebaseEditor = false
                    doMultiRootRebase(drafts: multiRootRebaseDrafts)
                },
                onCancel: {
                    showMultiRootRebaseEditor = false
                    multiRootRebaseDrafts = []
                },
                onOpenRawTodo: prepareMultiRootRawTodoEditor
            )
        }
        .sheet(item: $multiRootRawTodoContext) { context in
            RawRebaseTodoEditorView(
                onto: context.onto,
                text: $multiRootRawTodoText,
                preserveMerges: context.preserveMerges,
                root: context.root,
                onStart: { finishMultiRootRawTodoEditor(context) },
                onCancel: {
                    multiRootRawTodoContext = nil
                    multiRootRawTodoText = ""
                }
            )
        }
        .sheet(item: $multiRootRebaseRollbackContext) { context in
            RebasedMultiRootRebaseRollbackView(
                branch: context.branch,
                targets: context.targets,
                failures: context.failures,
                onRollback: {
                    rollbackMultiRootRebase(context.targets)
                },
                onKeep: {
                    keepMultiRootRebasePartial(context)
                },
                onDone: {
                    multiRootRebaseRollbackContext = nil
                }
            )
        }
        .sheet(isPresented: $stashUI.showCreateDialog) {
            RebasedStashDialog(
                roots: stashRootOptions,
                selectedRootPath: $stashUI.rootPath,
                currentBranch: $stashUI.currentBranch,
                isLoadingRoot: $stashUI.rootLoading,
                message: $stashUI.message,
                keepIndex: $stashUI.keepIndex,
                onSelectRoot: selectStashRoot,
                onSave: {
                    stashUI.showCreateDialog = false
                    stashSave(rootPath: stashUI.rootPath)
                },
                onCancel: { stashUI.showCreateDialog = false }
            )
        }
        .sheet(isPresented: $stashUI.showUnstashDialog) {
            RebasedUnstashDialog(
                roots: multiRoots,
                selectedRootPath: stashUI.unstashRootPath,
                isLoadingRoot: stashUI.unstashRootLoading,
                stashes: stashUI.unstashStashes,
                currentBranch: stashUI.unstashCurrentBranch,
                onSelectRoot: selectUnstashRoot,
                validateBranchName: { rootPath, value in
                    guard let rootRepo = try? openRepository(path: rootPath) else { return nil }
                    do {
                        try rootRepo.validateBranchName(name: value)
                        return nil
                    } catch {
                        return errorMessage(error)
                    }
                },
                onApply: { rootPath, stashID, restoreIndex in
                    stashUI.showUnstashDialog = false
                    if useRootScopedUnstashActions {
                        applyStashInRoot(rootPath: rootPath, stashID: stashID, restoreIndex: restoreIndex)
                    } else {
                        stashApply(stashID: stashID, restoreIndex: restoreIndex)
                    }
                },
                onPop: { rootPath, stashID, restoreIndex in
                    stashUI.showUnstashDialog = false
                    if useRootScopedUnstashActions {
                        popStashInRoot(rootPath: rootPath, stashID: stashID, restoreIndex: restoreIndex)
                    } else {
                        stashPop(stashID: stashID, restoreIndex: restoreIndex)
                    }
                },
                onStashBranch: { rootPath, stashID, branch in
                    stashUI.showUnstashDialog = false
                    if useRootScopedUnstashActions {
                        stashBranchInRoot(rootPath: rootPath, stashID: stashID, branch: branch)
                    } else {
                        stashBranch(stashID: stashID, branch: branch)
                    }
                },
                onViewDiff: { rootPath, stashID in
                    if useRootScopedUnstashActions {
                        showStashDiffInRoot(rootPath: rootPath, stashID: stashID)
                    } else {
                        showStashPreviewFor(stashID: stashID)
                    }
                },
                onDrop: { rootPath, stashID in
                    if useRootScopedUnstashActions {
                        dropStashInRootConfirmed(rootPath: rootPath, stashID: stashID)
                    } else {
                        stashDrop(stashID: stashID)
                    }
                },
                onClear: { rootPath in
                    if useRootScopedUnstashActions {
                        clearStashesInRootConfirmed(rootPath: rootPath)
                    } else {
                        stashClearAll()
                    }
                },
                onCancel: { stashUI.showUnstashDialog = false }
            )
        }
        .sheet(isPresented: $stashUI.showUnstashAsDialog) {
            if let stash = stashes.first(where: { $0.id == stashUI.unstashAsStashID }) {
                RebasedUnstashAsDialog(
                    stash: stash,
                    currentBranch: currentBranchName,
                    validateBranchName: { value in
                        guard let repo else { return nil }
                        do {
                            try repo.validateBranchName(name: value)
                            return nil
                        } catch {
                            return errorMessage(error)
                        }
                    },
                    onApply: { restoreIndex in
                        stashUI.showUnstashAsDialog = false
                        stashUI.unstashAsStashID = nil
                        stashApply(stashID: stash.id, restoreIndex: restoreIndex)
                    },
                    onPop: { restoreIndex in
                        stashUI.showUnstashAsDialog = false
                        stashUI.unstashAsStashID = nil
                        stashPop(stashID: stash.id, restoreIndex: restoreIndex)
                    },
                    onStashBranch: { branch in
                        stashUI.showUnstashAsDialog = false
                        stashUI.unstashAsStashID = nil
                        stashBranch(stashID: stash.id, branch: branch)
                    },
                    onCancel: {
                        stashUI.showUnstashAsDialog = false
                        stashUI.unstashAsStashID = nil
                    }
                )
            } else {
                Color.clear
                    .onAppear {
                        stashUI.showUnstashAsDialog = false
                        stashUI.unstashAsStashID = nil
                    }
            }
        }
        .sheet(isPresented: $stashUI.showFilesDialog) {
            RebasedStashFilesDialog(
                message: $stashUI.filesMessage,
                entries: entries.filter {
                    $0.unstaged != .ignored &&
                    $0.unstaged != .conflicted &&
                    $0.staged != .conflicted
                },
                initialPaths: stashUI.filesInitialPaths,
                onStash: { paths in
                    stashUI.showFilesDialog = false
                    stashSelectedFiles(paths)
                },
                onCancel: { stashUI.showFilesDialog = false }
            )
        }
        .sheet(isPresented: $showCloneDialog) {
            RebasedCloneDialog(
                url: $cloneURL,
                parentDirectory: $cloneParentDirectory,
                directoryName: $cloneDirectoryName,
                recursiveSubmodules: $cloneRecursiveSubmodules,
                shallowClone: $cloneShallow,
                depth: $cloneDepth,
                isRunning: cloneInProgress,
                isCancelling: cloneCancelling,
                onChooseParent: chooseCloneParentDirectory,
                onClone: cloneRepositoryFromDialog,
                onCancel: cancelCloneRepositoryFromDialog
            )
            .interactiveDismissDisabled(cloneInProgress)
        }
        .sheet(isPresented: $showNewTagDialog) {
            RebasedTagDialog(
                name: $tagName,
                revision: $tagAt,
                message: $tagMessage,
                signKey: $tagSignKey,
                annotated: $tagAnnotated,
                force: $tagForce,
                onCreate: {
                    showNewTagDialog = false
                    createTag()
                },
                onCancel: {
                    showNewTagDialog = false
                    tagRepositoryOverride = nil
                    tagForce = false
                }
            )
        }
        .sheet(isPresented: $showShelveDialog) {
            RebasedShelveDialog(
                name: $shelveName,
                repo: repo,
                entries: entries,
                onShelve: { paths, includeUntracked, includeIgnored in
                    showShelveDialog = false
                    doShelve(
                        paths: paths,
                        includeUntracked: includeUntracked,
                        includeIgnored: includeIgnored
                    )
                },
                onCancel: { showShelveDialog = false }
            )
        }
        .sheet(isPresented: $showShelfLocationDialog) {
            RebasedShelfLocationDialog(
                location: $shelfLocationValue,
                migrateExisting: $shelfLocationMigrateExisting,
                currentLocation: shelfLocationCurrent,
                onSave: {
                    showShelfLocationDialog = false
                    setShelfLocation(
                        shelfLocationValue,
                        migrateExisting: shelfLocationMigrateExisting,
                        rootPath: activeShelfRootPath
                    )
                },
                onCancel: { showShelfLocationDialog = false }
            )
        }
        .sheet(item: $pendingApplyPatch) { request in
            if let repo {
                RebasedUnshelveDialog(
                    name: request.fileName,
                    paths: request.paths,
                    initialPaths: request.paths,
                    changeLists: changeLists,
                    repo: repo,
                    patchText: request.patch,
                    removeAppliedFilesFromShelf: .constant(false),
                    onUnshelve: { _, _, _, _, _, _, _ in },
                    onApplyPatch: { paths, selections, targetName, basePath, pathStrip in
                        pendingApplyPatch = nil
                        applyImportedPatch(
                            fileName: request.fileName,
                            patch: request.patch,
                            paths: paths,
                            selections: selections,
                            targetName: targetName,
                            basePath: basePath,
                            pathStrip: pathStrip
                        )
                    },
                    onCancel: { pendingApplyPatch = nil }
                )
            }
        }
        .sheet(item: $patchExportRequest) { request in
            RebasedPatchExportDialog(
                request: request,
                onExport: { options in
                    patchExportRequest = nil
                    DispatchQueue.main.async {
                        request.onExport(options)
                    }
                },
                onCancel: { patchExportRequest = nil }
            )
        }
        .sheet(isPresented: $showHeadResetDialog) {
            RebasedHeadResetDialog(
                roots: resetHeadRootOptions,
                selectedRootPath: $headResetRootPath,
                target: $headResetTarget,
                mode: $headResetMode,
                onValidate: { target, rootPath in
                    validateResetHeadTarget(target, rootPath: rootPath)
                },
                onReset: {
                    showHeadResetDialog = false
                    resetHead(
                        rootPath: headResetRootPath,
                        target: headResetTarget,
                        mode: headResetMode
                    )
                },
                onCancel: { showHeadResetDialog = false }
            )
        }
        .sheet(isPresented: $showResetDialog) {
            if let resetTargetCommit {
                RebasedResetDialog(
                    commit: resetTargetCommit,
                    targetCommits: resetTargetCommits,
                    mode: $resetMode,
                    onReset: {
                        showResetDialog = false
                        if resetTargetCommits.count > 1 {
                            resetCommitsAcrossRoots(resetTargetCommits, mode: resetMode)
                        } else {
                            resetCommit(resetTargetCommit, mode: resetMode)
                        }
                    },
                    onCancel: { showResetDialog = false },
                    multiRootResetAvailable: resetTargetCommits.count > 1,
                    onResetAcrossRoots: { mode in
                        showResetDialog = false
                        resetCommitsAcrossRoots(resetTargetCommits, mode: mode)
                    }
                )
            }
        }
        .sheet(item: $uncommitRequest) { request in
            RebasedUncommitDialog(
                request: request,
                onUncommit: { targetName in
                    uncommitRequest = nil
                    performUncommit(request, targetName: targetName)
                },
                onCancel: { uncommitRequest = nil }
            )
        }
        .sheet(item: $smartOperationRequest) { request in
            RebasedSmartOperationDialog(
                request: request,
                onSmart: {
                    smartOperationRequest = nil
                    request.onSmart()
                },
                onForce: {
                    smartOperationRequest = nil
                    request.onForce?()
                },
                onCancel: {
                    smartOperationRequest = nil
                    feedbackCenter.warning(
                        "Git operation cancelled",
                        detail: "Local changes were kept."
                    )
                }
            )
        }
    }

    @ViewBuilder
    private var beforeCommitSettingsSheet: some View {
        BeforeCommitSettingsView(
            commands: $beforeCommitCommands,
            onIdentity: { showIdentitySettings = true }
        )
    }

    private func selectChangedFile(_ path: String) {
        commitPreviewPath = path
        commitPreviewComparisonMode = nil
        commitPreviewThreeVersions = false
        selectionModePath = nil
        selection = nil
        fileSelection = nil
        // GitStagePanel separates selection from the Show Diff Preview action.
        // Changing a row updates an already-open preview, but does not
        // silently reopen a preview the user explicitly hid.
    }

    private func previewChangedFile(_ path: String) {
        // GitStagePanel reserves double-click/Enter for Open Source. Arbor has
        // no IDE editor. When Log owns the editor workspace, preserve that
        // workspace and keep the source action inside the Commit/Stash side
        // instead of replacing the selected history with a file viewer.
        if toolWindowMode == .log {
            commitPreviewPath = path
            commitPreviewComparisonMode = nil
            commitPreviewThreeVersions = false
            fileSelectionVersion = .local
            selectionModePath = nil
            selection = nil
            fileSelection = nil
            commitPreviewVisible = true
            feedbackCenter.warning(
                "Open Source is not an IDE editor",
                detail: "The Commit/Stash preview remains open so Git Log is not replaced.",
                nextStep: "Use the single-click diff or open the file from Project."
            )
            return
        }
        commitPreviewPath = nil
        commitPreviewComparisonMode = nil
        commitPreviewThreeVersions = false
        selection = nil
        selectionModePath = nil
        fileSelection = path
        fileSelectionVersion = .local
        commitPreviewVisible = false
    }

    private func previewFirstChangedFile() {
        if commitPreviewVisible {
            commitPreviewVisible = false
            commitPreviewThreeVersions = false
            return
        }
        commitPreviewPath = entries.first(where: {
            $0.staged != .unchanged
                || ($0.unstaged != .unchanged && $0.unstaged != .ignored)
        })?.path
        commitPreviewComparisonMode = nil
        commitPreviewThreeVersions = false
        commitPreviewVisible = true
    }

    private func showCommitDiffPreview(_ path: String) {
        // This is the stage-tree equivalent of Git.Stage.Tree.Menu's
        // Diff.ShowDiff action. It deliberately does not enter the editor
        // file-selection path: when Log is active, the right workspace must
        // remain the graph/details inspector and the diff belongs beside the
        // Commit/Stash tree on the left.
        commitPreviewPath = path
        commitPreviewComparisonMode = nil
        commitPreviewMode = .unstaged
        commitPreviewThreeVersions = false
        selectionModePath = nil
        selection = nil
        fileSelection = nil
        commitPreviewVisible = true
    }

    private func showCommitStagedDiffPreview(_ path: String) {
        commitPreviewPath = path
        commitPreviewComparisonMode = nil
        commitPreviewMode = .staged
        commitPreviewThreeVersions = false
        selectionModePath = nil
        selection = nil
        fileSelection = nil
        commitPreviewVisible = true
    }

    private func showCommitLocalStagedDiffPreview(_ path: String) {
        commitPreviewPath = path
        commitPreviewComparisonMode = stagingComparisonDiffMode(for: .localWithStaged)
        commitPreviewMode = .unstaged
        commitPreviewThreeVersions = false
        selectionModePath = nil
        selection = nil
        fileSelection = nil
        commitPreviewVisible = true
    }

    private func showCommitThreeVersionsPreview(_ path: String) {
        commitPreviewPath = path
        commitPreviewComparisonMode = nil
        commitPreviewThreeVersions = true
        selectionModePath = nil
        selection = nil
        fileSelection = nil
        commitPreviewVisible = true
    }

    private func showCommitLocalVersion(_ path: String) {
        showCommitFileVersion(path, version: .local)
    }

    private func showCommitStagedVersion(_ path: String) {
        showCommitFileVersion(path, version: .staged)
    }

    private func showCommitFileVersion(_ path: String, version: FileContentVersion) {
        commitPreviewPath = nil
        commitPreviewComparisonMode = nil
        commitPreviewVisible = false
        commitPreviewThreeVersions = false
        fileTreeDiffRequest = nil
        selection = nil
        selectionModePath = nil
        fileSelectionVersion = version
        fileSelection = path
    }

    func annotateProjectFile(_ path: String) {
        guard let normalizedPath = normalizedRepositoryRelativePath(path) else { return }
        toolWindowMode = .commit
        fileTreeDiffRequest = nil
        selection = nil
        selectionModePath = nil
        logSelectionState.selection = nil
        fileSelectionVersion = .local
        fileSelection = normalizedPath
        fileContentBlameRequestID &+= 1
    }

    func openFirstConflictFromAction() {
        guard let conflictedPath = firstConflictedPath(in: entries) else { return }
        openConflictFromStage(conflictedPath)
    }

    private func openConflictFromStage(_ path: String) {
        // The resolver is a sheet over the current workspace. In Log mode the
        // right editor must remain the Log graph, so pass the initial file via
        // a dedicated dialog context instead of the global editor selection.
        mergeInitialPath = path
        if toolWindowMode != .log { selection = path }
        fileSelection = nil
        selectionModePath = nil
        commitPreviewPath = nil
        commitPreviewComparisonMode = nil
        commitPreviewVisible = false
        commitPreviewThreeVersions = false
        showMergeRevisionsDialog = true
    }

    @ViewBuilder
    private var activeToolWindowContent: some View {
        switch toolWindowMode {
        case .commit, .log:
            RebasedCommitWorkspace(
                projectPath: projectPath,
                repo: repo,
                repositoryWorkdir: repo?.workdir(),
                shelfRepo: activeShelfRepository,
                entries: entries,
                changeLists: changeLists,
                untrackedEntries: untrackedEntries,
                ignoredRules: ignoredRules,
                stashes: stashes,
                shelves: activeShelfList,
                deletedShelves: activeDeletedShelfList,
                shelfChangeLists: activeShelfChangeLists,
                showShelfRequestID: shelfTabRequestID,
                onWorkspaceTabChange: { isShelfWorkspaceTabActive = $0 },
                shelfRootPath: activeShelfRootPath,
                shelfRootOptions: availableShelfRoots,
                selectedShelfRootPath: activeShelfRootPath ?? "",
                isShelfRootReadOnly: isShelfRootReadOnly,
                canMutateShelfMetadata: canMutateShelfMetadata,
                canApplyShelfWorktree: canApplyShelfWorktree,
                isShelfRootLoading: shelfRootLoading,
                shelfRootError: shelfRootError,
                onShelfRootChange: setShelfRoot,
                isLoading: isLoading,
                isShowingCachedStatusSnapshot: isShowingCachedStatusSnapshot,
                hasStaged: hasStaged,
                commitFeedback: commitFeedback,
                operationState: operationState,
                operationFeedback: operationFeedback,
                binaryPaths: stagingBinaryPaths,
                lfsTrackedPaths: lfsTrackedPaths,
                lfsPointerPaths: lfsPointerPaths,
                stagingPresence: stagingPresenceByPath,
                refreshToken: fileContentRefreshToken,
                recentMessages: recentMessages,
                commitMessage: $commitMessage,
                amendMode: $amendMode,
                skipHooks: $skipHooks,
                onStage: stagePath,
                onStageWithoutContent: stageWithoutContent,
                onStageWithoutContentAll: stageWithoutContentAll,
                onUnstage: unstagePath,
                onPartial: partialMode,
                onSelect: selectChangedFile,
                onPreviewPath: previewChangedFile,
                onShowDiffPath: showCommitDiffPreview,
                onShowLocalStagedDiffPath: showCommitLocalStagedDiffPreview,
                onShowLocalVersionPath: showCommitLocalVersion,
                onShowStagedVersionPath: showCommitStagedVersion,
                onShowStagedDiffPath: showCommitStagedDiffPreview,
                onShowThreeVersionsPath: showCommitThreeVersionsPreview,
                previewMode: $commitPreviewMode,
                comparisonMode: commitPreviewComparisonMode,
                showThreeVersions: $commitPreviewThreeVersions,
                previewPath: $commitPreviewPath,
                isPreviewVisible: $commitPreviewVisible,
                selectionModePath: $selectionModePath,
                onRestore: { path in restoreFileFromHead(path) },
                onRevertUnstaged: revertUnstagedPath,
                onRefresh: refreshAll,
                onStageAll: stageAll,
                onStageEverything: stageEverything,
                onCreateChangeList: createChangeList,
                onRenameChangeList: renameChangeList,
                onDeleteChangeList: deleteChangeList,
                onActivateChangeList: activateChangeList,
                onMovePathsToChangeList: movePathsToChangeList,
                onTemplate: loadTemplate,
                onBeforeCommitSettings: { showBeforeCommitSettings = true },
                onCommit: { doCommit() },
                onCommitAll: commitAllTrackedChanges,
                onCommitAndRebase: { doCommit(rebaseAfterCommit: true) },
                autoSquashCommitKind: pendingAutoSquashRebase?.kind,
                onCommitAndPush: beginCommitAndPush,
                onOperationContinue: doOperationContinue,
                onOperationSkip: doOperationSkip,
                onOperationAbort: doOperationAbort,
                onOpenConflictResolver: openActiveOperationConflictResolver,
                onShelve: { showShelveDialog = true },
                onShelfSettings: presentShelfLocationSettings,
                onShelvePaths: shelveDraggedPaths,
                onImportShelve: { rootPath in
                    importShelvePatches(rootPath: rootPath)
                },
                onPreview: previewFirstChangedFile,
                onStash: presentStashDialog,
                onStashPaths: { paths in showStashFiles(paths: paths) },
                onStashSilently: stashSilently,
                onApplyStash: { stashID, restoreIndex in stashApply(stashID: stashID, restoreIndex: restoreIndex) },
                onPopStash: { stashID, restoreIndex in stashPop(stashID: stashID, restoreIndex: restoreIndex) },
                onDropStash: stashDrop(stashID:),
                onStashBranch: stashBranch(stashID:),
                onUnstashAs: presentUnstashAsDialog,
                onStashDiffPreview: showStashPreviewFor(stashID:),
                stashDiffText: stashUI.previewText,
                stashPreviewStashID: $stashUI.previewStashID,
                isStashPreviewVisible: $stashUI.showPreview,
                onStashClear: stashClearAll,
                onShelveDiffPreview: showShelvePreviewFor,
                shelfDiffText: shelfPreviewText,
                shelfPreviewName: $shelfPreviewName,
                shelfPreviewIsDeleted: $shelfPreviewIsDeleted,
                isShelfPreviewVisible: $showShelfPreview,
                onRenameShelve: { name, description in
                    renameShelve(
                        name,
                        currentDescription: description,
                        rootPath: activeShelfRootPath
                    )
                },
                onRenameShelveDescription: { name, description in
                    renameShelveDescription(
                        name,
                        description,
                        rootPath: activeShelfRootPath
                    )
                },
                onExportShelve: { name in
                    exportShelve(name, rootPath: activeShelfRootPath)
                },
                onUnshelve: { name in
                    doShelveUnshelve(name, rootPath: activeShelfRootPath)
                },
                onUnshelveWithOptions: { name, removeApplied in
                    doShelveUnshelve(
                        name,
                        removeApplied: removeApplied,
                        rootPath: activeShelfRootPath
                    )
                },
                onUnshelvePathsWithOptions: { name, paths, removeApplied in
                    doShelveUnshelvePaths(
                        name,
                        paths,
                        removeApplied: removeApplied,
                        rootPath: activeShelfRootPath
                    )
                },
                onUnshelvePathGroupsWithOptions: { groups, removeApplied, sourceIsDeleted in
                    doShelveUnshelvePathGroups(
                        groups,
                        removeApplied: removeApplied,
                        sourceIsDeleted: sourceIsDeleted,
                        rootPath: activeShelfRootPath
                    )
                },
                onUnshelveSelectionsWithOptions: { name, selections, removeApplied in
                    doShelveUnshelveSelections(
                        name,
                        selections: selections,
                        removeApplied: removeApplied,
                        rootPath: activeShelfRootPath
                    )
                },
                onUnshelvePathsWithBase: { name, paths, removeApplied, basePath, pathStrip in
                    doShelveUnshelvePaths(
                        name,
                        paths,
                        removeApplied: removeApplied,
                        basePath: basePath,
                        pathStrip: pathStrip,
                        rootPath: activeShelfRootPath
                    )
                },
                onUnshelveSelectionsWithBase: { name, selections, removeApplied, basePath, pathStrip in
                    doShelveUnshelveSelections(
                        name,
                        selections: selections,
                        removeApplied: removeApplied,
                        basePath: basePath,
                        pathStrip: pathStrip,
                        rootPath: activeShelfRootPath
                    )
                },
                onUnshelveShelvesIntoChangeList: { names, targetName, removeApplied in
                    doShelveUnshelveShelvesIntoChangeList(
                        names,
                        targetName: targetName,
                        removeApplied: removeApplied,
                        rootPath: activeShelfRootPath
                    )
                },
                onUnshelvePathGroupsIntoChangeList: { groups, targetName, removeApplied in
                    doShelveUnshelvePathGroupsIntoChangeList(
                        groups,
                        targetName: targetName,
                        removeApplied: removeApplied,
                        rootPath: activeShelfRootPath
                    )
                },
                onUnshelveShelvesSilently: { names, removeApplied in
                    doShelveUnshelveSilently(
                        names,
                        removeApplied: removeApplied,
                        rootPath: activeShelfRootPath
                    )
                },
                onUnshelveDeletedShelvesSilently: { names, removeApplied in
                    doShelveUnshelveSilently(
                        names,
                        removeApplied: removeApplied,
                        rootPath: activeShelfRootPath
                    )
                },
                onUnshelveDeletedPathsWithOptions: { name, paths, removeApplied in
                    doShelveUnshelvePaths(
                        name,
                        paths,
                        removeApplied: removeApplied,
                        sourceIsDeleted: true,
                        rootPath: activeShelfRootPath
                    )
                },
                onPopShelve: { name in
                    doShelvePop(name, rootPath: activeShelfRootPath)
                },
                onPopShelves: { names in
                    doShelvePopShelves(names, rootPath: activeShelfRootPath)
                },
                onUnshelveIntoChangeList: { name, paths, targetName in
                    doShelveUnshelveIntoChangeList(
                        name,
                        paths: paths,
                        targetName: targetName,
                        rootPath: activeShelfRootPath
                    )
                },
                onUnshelveSelectionsIntoChangeList: { name, selections, targetName, removeApplied in
                    doShelveUnshelveIntoChangeList(
                        name,
                        paths: nil,
                        selections: selections,
                        targetName: targetName,
                        removeApplied: removeApplied,
                        rootPath: activeShelfRootPath
                    )
                },
                onUnshelveIntoChangeListWithBase: { name, paths, targetName, removeApplied, basePath, pathStrip in
                    doShelveUnshelveIntoChangeList(
                        name,
                        paths: paths,
                        targetName: targetName,
                        removeApplied: removeApplied,
                        basePath: basePath,
                        pathStrip: pathStrip,
                        rootPath: activeShelfRootPath
                    )
                },
                onUnshelveSelectionsIntoChangeListWithBase: { name, selections, targetName, removeApplied, basePath, pathStrip in
                    doShelveUnshelveIntoChangeList(
                        name,
                        paths: nil,
                        selections: selections,
                        targetName: targetName,
                        removeApplied: removeApplied,
                        basePath: basePath,
                        pathStrip: pathStrip,
                        rootPath: activeShelfRootPath
                    )
                },
                onRecordUnshelveComment: { targetName, comment in
                    recordUnshelveComment(
                        targetName: targetName,
                        comment: comment,
                        rootPath: activeShelfRootPath
                    )
                },
                onCleanRecycledShelves: {
                    cleanRecycledShelves(rootPath: activeShelfRootPath)
                },
                onDropShelve: { name in
                    doShelveDrop(name, rootPath: activeShelfRootPath)
                },
                onDropShelves: { names in
                    doShelveDropShelves(names, rootPath: activeShelfRootPath)
                },
                onDropShelvePaths: { name, paths in
                    doShelveDropPaths(name, paths, rootPath: activeShelfRootPath)
                },
                onDropShelvePathGroups: { groups in
                    doShelveDropPathGroups(groups, rootPath: activeShelfRootPath)
                },
                onMoveShelfPaths: { sourceName, targetName, paths in
                    moveShelfPaths(
                        sourceName,
                        targetName,
                        paths,
                        rootPath: activeShelfRootPath
                    )
                },
                onRestoreDeletedShelve: { name in
                    restoreDeletedShelve(name, rootPath: activeShelfRootPath)
                },
                onDeleteDeletedShelve: { name in
                    deleteDeletedShelve(name, rootPath: activeShelfRootPath)
                },
                onDeleteDeletedShelfPaths: { name, paths in
                    doShelveDeleteDeletedPaths(name, paths, rootPath: activeShelfRootPath)
                },
                onDeleteDeletedShelfPathGroups: { groups in
                    doShelveDeleteDeletedPathGroups(groups, rootPath: activeShelfRootPath)
                },
                onRestoreDeletedShelves: { names in
                    restoreDeletedShelves(names, rootPath: activeShelfRootPath)
                },
                onDeleteDeletedShelves: { names, confirm in
                    deleteDeletedShelves(
                        names,
                        confirm: confirm,
                        rootPath: activeShelfRootPath
                    )
                },
                onDeleteShelfPlan: { plan in
                    deleteShelfPlan(plan, rootPath: activeShelfRootPath)
                },
                onIgnore: { paths, ignoreFilePath in
                    ignorePaths(paths, ignoreFilePath: ignoreFilePath)
                },
                onExclude: { paths in
                    paths.forEach(excludePathFromRepo)
                },
                onOpenConflict: openConflictFromStage,
                resolvedConflictPaths: resolvedConflictPaths,
                onRevertResolved: revertResolvedPath,
                onShowHistory: { path in showFileHistory(path) },
                onEditGitignore: editGitignore,
                onEditGitExclude: editGitExclude
            )
        case .operations:
            VStack(spacing: 0) {
                Picker("操作视图", selection: $operationsViewMode) {
                    ForEach(OperationsViewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider()
                switch operationsViewMode {
                case .tasks:
                    GitTasksView(
                        feedbackCenter: feedbackCenter,
                        focusNotificationID: $operationLogFocusNotificationID,
                        onOpenHistory: { operationsViewMode = .history }
                    )
                case .history:
                    OperationLogView(
                        feedbackCenter: feedbackCenter,
                        focusNotificationID: $operationLogFocusNotificationID
                    )
                case .console:
                    GitConsoleView(
                        result: consoleResult,
                        onRun: runGitConsole,
                        onClear: { consoleResult = nil }
                    )
                case .roots:
                    MultiRootPanel(
                        roots: multiRoots,
                        results: multiRootResults,
                        conflictGroups: multiRootConflictGroups,
                        isRunning: multiRootRunning,
                        canRetryFailedUpdate: multiRootUpdateRetryAvailable,
                        canRetryFailedCheckoutUpdate: multiRootCheckoutUpdateRetryAvailable,
                        canRetryFailedPush: multiRootPushRetryContext != nil,
                        onOperation: { op in executeMultiRootOperation(op, message: nil) },
                        onCommitAll: { openMultiRootCommitDialog() },
                        onCheckout: { reference, detach in
                            executeMultiRootCheckout(reference: reference, detach: detach)
                        },
                        onRecovery: { rootPath, action in
                            executeMultiRootRecovery(rootPath: rootPath, action: action)
                        },
                        onRetryFailedUpdate: { retryMultiRootUpdateFailedRoots() },
                        onRetryFailedCheckoutUpdate: { retryMultiRootCheckoutAndUpdateFailedRoots() },
                        onRetryFailedPush: { retryMultiRootPushFailedRoots() },
                        onResolveOperationConflict: openMultiRootOperationConflict,
                        onAcceptConflicts: { targets, pick in
                            acceptMultiRootConflicts(targets, pick: pick)
                        },
                        conflictBatchWorking: multiRootConflictBatchWorking,
                        conflictBatchError: multiRootConflictBatchError,
                        stashConflicts: multiRootStashConflicts,
                        onResolveStashConflict: openMultiRootStashConflict,
                        updateStashRoots: multiRootUpdateStashedRoots,
                        onRestoreUpdateStash: restoreMultiRootUpdateStash,
                        onRefresh: { loadMultiRoots() },
                        onShowChanges: openMultiRootChanges
                    )
                case .submodules:
                    SubmodulePanel(
                        submodules: submodules,
                        feedback: submoduleFeedback,
                        onAdd: submoduleAdd,
                        onUpdate: submoduleUpdate,
                        onSync: submoduleSync,
                        onUpdatePath: submoduleUpdatePath,
                        onUpdateOptions: submoduleUpdateWithOptions,
                        onDeinit: submoduleDeinit,
                        onRemove: submoduleRemove,
                        onSetBranch: submoduleSetBranch,
                        onLog: openSubmoduleLog,
                        onPush: beginSubmodulePushDialog,
                        onConfigureRemotes: beginSubmoduleRemoteConfig,
                        onRefresh: refreshAll
                    )
                case .worktrees:
                    WorktreePanel(
                        worktrees: worktrees,
                        feedback: worktreeFeedback,
                        onRefresh: loadWorktrees,
                        onCreate: { path, branch, revision in
                            createWorktree(path: path, branch: branch, revision: revision)
                        },
                        onOpen: { openWindow(value: $0) },
                        onRemove: removeWorktree,
                        onLock: lockWorktree,
                        onUnlock: unlockWorktree,
                        onPrune: pruneWorktrees
                    )
                }
            }
        }
    }

    private var workspaceSidebar: some View {
        GeometryReader { proxy in
            let panelHeight = proxy.size.height
            let headerHeight: CGFloat = 32
            let resizeHandleHeight: CGFloat = 7
            let minimumToolHeight: CGFloat = 220
            let minimumProjectHeight: CGFloat = 140
            let bothExpanded = toolWindowExpanded && projectPanelExpanded
            let separatorHeight = bothExpanded ? resizeHandleHeight : 1
            let maximumToolHeight = max(
                minimumToolHeight,
                panelHeight - headerHeight - separatorHeight - minimumProjectHeight
            )
            let expandedToolHeight = min(
                max(CGFloat(toolWindowHeight), minimumToolHeight),
                maximumToolHeight
            )
            let toolPanelHeight: CGFloat = {
                if !toolWindowExpanded { return headerHeight }
                if projectPanelExpanded { return expandedToolHeight }
                return max(headerHeight, panelHeight - headerHeight - separatorHeight)
            }()
            let projectPanelHeight: CGFloat = {
                if !projectPanelExpanded { return headerHeight }
                if toolWindowExpanded {
                    return max(headerHeight, panelHeight - toolPanelHeight - separatorHeight)
                }
                return max(headerHeight, panelHeight - headerHeight - separatorHeight)
            }()

            VStack(spacing: 0) {
            if !projectPanelExpanded {
                // GitStagePanel/OperationLogView own their own first row
                // (Commit/Stash or the operations tabs). Rebased does not
                // add a second generic tool-window title above that row;
                // doing so shifts the entire left workspace down and makes
                // the Commit/Stash surface structurally different.
                if toolWindowExpanded || toolWindowMode == .log {
                    activeToolWindowContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    WorkspacePanelHeader(
                        title: LocalizedStringKey(toolWindowMode.title),
                        systemImage: toolWindowMode.systemImage,
                        isExpanded: false,
                        onToggle: {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                toolWindowExpanded = true
                            }
                        }
                    )
                }
            } else if toolWindowMode == .log {
                // The activity-rail folder is the Project tool-window
                // switch in Rebased. Keep the Log workspace on the right,
                // while replacing the left Commit/Stash surface with the
                // project tree until the folder button is pressed again.
                VStack(spacing: 0) {
                    WorkspacePanelHeader(
                        title: "Project",
                        systemImage: "folder",
                        isExpanded: true,
                        onToggle: { projectPanelExpanded = false },
                        trailing: AnyView(
                            HStack(spacing: 8) {
                                Button(action: showOpenPanel) {
                                    Image(systemName: "folder.badge.plus")
                                }
                                .buttonStyle(.plain)
                                .help("打开项目")
                                if repo != nil {
                                    Button(action: { if let repo { showInFinder(repo) } }) {
                                        Image(systemName: "arrow.up.forward.app")
                                    }
                                    .buttonStyle(.plain)
                                    .help("在 Finder 中显示项目根目录")
                                }
                            }
                        )
                    )
                    ProjectTreePane(
                        repo: repo,
                        projectPath: projectPath,
                        headId: headId,
                        entries: entries,
                        selection: Binding(
                            get: { fileSelection },
                            set: { value in
                                fileTreeDiffRequest = nil
                                fileSelection = value
                                fileSelectionVersion = .local
                                if value != nil {
                                    selection = nil
                                    selectionModePath = nil
                                    logSelectionState.selection = nil
                                }
                            }
                        ),
                        onOpen: showOpenPanel,
                        onReveal: { if let repo { showInFinder(repo) } },
                        onCopyPath: copyRepositoryRelativePath,
                        onCompareWithReference: openFileReferenceComparison,
                        onCompareWithSameVersion: openFileSameVersionComparison,
                        onCompareWithSelectedRevision: openFileSelectedRevisionComparison,
                        onShowFileHistory: { path in
                            showFileHistory(path, rootPath: repo?.workdir())
                        },
                        onShowCurrentRevision: showCurrentRevision,
                        onAnnotate: annotateProjectFile,
                        onCheckin: beginFileCheckin,
                        onAdd: stageProjectTreePath,
                        onRevert: restoreProjectTreePath,
                        onResolveConflicts: openConflictFromStage,
                        resolvedConflictPaths: resolvedConflictPaths,
                        onRevertResolved: revertResolvedPath,
                        showHeader: false
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                    WorkspacePanelHeader(
                        title: LocalizedStringKey(toolWindowMode.title),
                        systemImage: toolWindowMode.systemImage,
                        isExpanded: toolWindowExpanded,
                        onToggle: {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                toolWindowExpanded.toggle()
                            }
                        }
                    )
                    if toolWindowExpanded {
                        activeToolWindowContent
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: toolPanelHeight)

                if bothExpanded {
                    WorkspacePanelResizeHandle(
                        topHeight: $toolWindowHeight,
                        minimumTopHeight: Double(minimumToolHeight),
                        maximumTopHeight: Double(maximumToolHeight)
                    )
                } else {
                    Divider()
                }

                VStack(spacing: 0) {
                    WorkspacePanelHeader(
                        title: "Project",
                        systemImage: "folder",
                        isExpanded: projectPanelExpanded,
                        onToggle: {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                projectPanelExpanded.toggle()
                            }
                        },
                        trailing: AnyView(
                            HStack(spacing: 8) {
                                Button(action: showOpenPanel) {
                                    Image(systemName: "folder.badge.plus")
                                }
                                .buttonStyle(.plain)
                                .help("打开项目")
                                if repo != nil {
                                    Button(action: { if let repo { showInFinder(repo) } }) {
                                        Image(systemName: "arrow.up.forward.app")
                                    }
                                    .buttonStyle(.plain)
                                    .help("在 Finder 中显示项目根目录")
                                }
                            }
                        )
                    )
                    if projectPanelExpanded {
                        ProjectTreePane(
                            repo: repo,
                            projectPath: projectPath,
                            headId: headId,
                            entries: entries,
                            selection: Binding(
                            get: { fileSelection },
                            set: { value in
                                fileTreeDiffRequest = nil
                                fileSelection = value
                                fileSelectionVersion = .local
                                if value != nil {
                                        selection = nil
                                        selectionModePath = nil
                                        logSelectionState.selection = nil
                                    }
                                }
                            ),
                            onOpen: showOpenPanel,
                            onReveal: { if let repo { showInFinder(repo) } },
                            onCopyPath: copyRepositoryRelativePath,
                            onCompareWithReference: openFileReferenceComparison,
                            onCompareWithSameVersion: openFileSameVersionComparison,
                            onCompareWithSelectedRevision: openFileSelectedRevisionComparison,
                            onShowFileHistory: { path in
                                showFileHistory(path, rootPath: repo?.workdir())
                            },
                            onShowCurrentRevision: showCurrentRevision,
                            onAnnotate: annotateProjectFile,
                            onCheckin: beginFileCheckin,
                            onAdd: stageProjectTreePath,
                            onRevert: restoreProjectTreePath,
                            onResolveConflicts: openConflictFromStage,
                            resolvedConflictPaths: resolvedConflictPaths,
                            onRevertResolved: revertResolvedPath,
                            showHeader: false
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    }
                    .frame(height: projectPanelHeight)

                    Spacer(minLength: 0)
                }
            }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func toggleProjectToolWindow() {
        if toolWindowMode == .log {
            projectPanelExpanded.toggle()
        } else {
            projectPanelExpanded = true
        }
    }

    @ViewBuilder
    private var mainContext: some View {
        if let loadError, projectRepo == nil {
            ProjectLoadErrorView(
                message: loadError,
                onRetry: {
                    guard let projectPath else {
                        showOpenPanel()
                        return
                    }
                    openProjectPath(projectPath)
                },
                onOpen: showOpenPanel
            )
        } else if projectRepo == nil {
            ProjectEmptyStateView(
                recentPaths: loadRecentPaths(),
                onOpen: showOpenPanel,
                onInit: showInitializePanel,
                onClone: { showCloneDialog = true },
                onSelect: requestOpenProject
            )
        } else if toolWindowMode == .log {
            // Git Log is an editor workspace. A stale file selection (most
            // commonly a conflicted path left by the Commit tool window) must
            // never replace the graph/details workspace with Merge Revisions.
            // Rebased keeps the staging workbench on the left and the Log
            // editor on the right until the user explicitly opens the
            // resolver from that workbench.
            logWorkspace
        } else if selectedEntryIsConflicted {
            VStack(spacing: 12) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.orange)
                Text("冲突文件已进入 Merge Revisions")
                    .foregroundStyle(.secondary)
                Button("打开 Merge Revisions…") { showMergeRevisionsDialog = true }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let fileTreeDiffRequest,
                  selection == nil,
                  selectionModePath == nil,
                  fileSelection == nil {
            DiffDetailView(
                repo: fileTreeDiffRequest.repo,
                entry: fileTreeDiffRequest.entry,
                onChanged: { },
                selectionModePath: nil,
                initialMode: fileTreeDiffRequest.initialMode,
                refreshToken: fileContentRefreshToken
            )
        } else if selection != nil || selectionModePath != nil {
            DiffDetailView(
                repo: repo,
                entry: selectedEntry,
                onChanged: refreshAll,
                selectionModePath: selectionModePath,
                refreshToken: fileContentRefreshToken
            )
        } else if let fileSelection {
            let versionOptions = fileContentVersionOptions
            let effectiveVersion = resolvedFileContentVersion(
                current: fileSelectionVersion,
                available: versionOptions
            ) ?? fileSelectionVersion
            FileContentView(
                repo: repo,
                path: fileSelection,
                version: effectiveVersion,
                availableVersions: versionOptions,
                onVersionChange: { fileSelectionVersion = $0 },
                onShowFileHistory: { path in
                    showFileHistory(path, rootPath: repo?.workdir())
                },
                blameRequestID: fileContentBlameRequestID,
                refreshToken: fileContentRefreshToken
            )
            .onAppear {
                if effectiveVersion != fileSelectionVersion {
                    fileSelectionVersion = effectiveVersion
                }
            }
            .onChange(of: versionOptions) { _, updatedOptions in
                guard let resolved = resolvedFileContentVersion(
                    current: fileSelectionVersion,
                    available: updatedOptions
                ) else { return }
                if resolved != fileSelectionVersion {
                    fileSelectionVersion = resolved
                }
            }
        } else {
            VStack(spacing: Design.Spacing.md) {
                Image(systemName: "rectangle.center.inset.filled")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Design.Colors.accent)
                Text("从左侧项目树或底部工具窗选择上下文")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ToolbarContentBuilder
    private var projectToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Menu {
                Button("打开项目…", action: showOpenPanel)
                Button("初始化 Git 仓库…", action: showInitializePanel)
                Button("克隆 Git 仓库…") { showCloneDialog = true }
                let recent = loadRecentPaths()
                if !recent.isEmpty {
                    Divider()
                    ForEach(recent, id: \.self) { recentPath in
                        Button(URL(fileURLWithPath: recentPath).lastPathComponent) {
                            requestOpenProject(recentPath)
                        }
                    }
                }
            } label: {
                Label("项目", systemImage: "folder.badge.gearshape")
            }
            .help("打开项目")

            Button(action: refreshAll) {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(repo == nil || isLoading)
            .help("刷新状态")
        }
        ToolbarItem(placement: .principal) {
            branchPopup
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Update", systemImage: "arrow.down.circle") {
                requestUpdateProject()
            }
            .keyboardShortcut("t", modifiers: [.command])
            .disabled(repo == nil)
            .help("Update / pull (⌘T)")
            Menu {
                Button("Reset to Remote Branch…") {
                    resetCurrentBranchToRemote()
                }
                .disabled(!isArborVCSActionEnabled(.resetToRemoteBranch, in: vcsActionContext))
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help("Update options")
            Button("提交", systemImage: "checkmark.circle") {
                toolWindowMode = .commit
                toolWindowExpanded = true
            }
            .keyboardShortcut("k", modifiers: [.command])
            .disabled(repo == nil)
            .help("打开提交工具窗 (⌘K)")
            Button("Push", systemImage: "arrow.up.circle") {
                beginPushDialog()
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(repo == nil || remotes.isEmpty)
            .help("Push (⌘⇧K)")
            Button("Fetch", systemImage: "arrow.triangle.2.circlepath") {
                doFetch(nil)
            }
            .disabled(repo == nil || remotes.isEmpty)
            .help("Fetch")
        }
    }

    var currentBranchName: String {
        branches.first(where: { $0.isCurrent })?.name ?? "（无分支）"
    }

    private var hasAnyMultiRootCommitChanges: Bool {
        multiRootChangeGroups.contains { !$0.changedEntries.isEmpty }
    }

    private func openCommitWorkspaceFromBranchPopup() {
        showBranchesPopover = false
        toolWindowMode = .commit
        toolWindowExpanded = true
        projectPanelExpanded = false
    }

    /// The top-level Unstash dialog must switch to the root-qualified
    /// operations once the project has more than one discovered repository.
    /// A single-root window keeps the existing stash conflict surface.
    var useRootScopedUnstashActions: Bool {
        multiRoots.count > 1
    }

    var rebaseRepositories: [GitRootInfo] {
        multiRoots.count > 1 ? multiRoots : []
    }

    var rebaseBranchOptions: [BranchInfo] {
        guard let snapshot = multiRootBranchSnapshots.first(where: {
            $0.rootPath == rebaseRootPath
        }) else {
            return branches
        }
        return snapshot.branches
    }

    @ViewBuilder
    private var branchPopup: some View {
        Button {
            loadRepoData()
            if multiRoots.count > 1 {
                // The Branches Popup action group needs a current project-wide
                // status snapshot to update Commit Changes enablement. Do not
                // leave a stale empty multi-root snapshot looking clean.
                loadMultiRootChanges()
            }
            showBranchesPopover = true
        } label: {
            HStack(spacing: 7) {
                Label(currentBranchName, systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
                if incomingOutgoingInfoEnabled,
                   let sync = currentSyncStatus, sync.trackingExists,
                   sync.ahead > 0 || sync.behind > 0 {
                    HStack(spacing: 3) {
                        if sync.ahead > 0 {
                            Image(systemName: "arrow.up")
                            Text("\(sync.ahead)")
                        }
                        if sync.behind > 0 {
                            Image(systemName: "arrow.down")
                            Text("\(sync.behind)")
                        }
                        if currentBranchHasUnfetchedIncoming {
                            Image(systemName: "arrow.down")
                            Text("?")
                        }
                    }
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(sync.behind > 0 ? .blue : .green)
                } else if incomingOutgoingInfoEnabled, currentBranchHasUnfetchedIncoming {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down")
                        Text("?")
                    }
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.blue)
                    .help("Remote has incoming commits not fetched locally")
                }
            }
        }
        .buttonStyle(.borderless)
        .disabled(repo == nil)
        .help("Branches: checkout / pull / push / fetch / merge / rebase / stash")
        .popover(isPresented: $showBranchesPopover, arrowEdge: .bottom) {
            if multiRoots.count > 1 && !multiRootBranchSnapshots.isEmpty {
                MultiRootBranchesPopover(
                    projectPath: projectPath,
                    protectedBranchPatterns: effectiveProtectedBranchPatterns,
                    snapshots: multiRootBranchSnapshots,
                    incomingBranches: autoFetchIncomingBranches,
                    operationContexts: multiRoots.compactMap { root in
                        guard let kind = root.operation else { return nil }
                        return BranchPopupOperationContext(
                            rootPath: root.path,
                            displayName: root.displayName,
                            relativePath: root.relativePath,
                            kind: kind,
                            hasConflicts: multiRootConflictGroups.contains {
                                $0.rootPath == root.path && !$0.paths.isEmpty
                            }
                        )
                    },
                    onOperationAction: { rootPath, action in
                        handleVCSActionRequest(
                            ArborVCSActionRequest(
                                kind: .operationRecovery,
                                projectPath: projectPath,
                                rootPath: rootPath,
                                shelfName: "",
                                operationRecoveryAction: action.recoveryAction
                            )
                        )
                    },
                    onCommitChanges: {
                        showBranchesPopover = false
                        openMultiRootCommitDialog()
                    },
                    hasCommitChanges: hasAnyMultiRootCommitChanges,
                    onNewBranch: {
                        presentMultiRootNewBranchDialog()
                        showBranchesPopover = false
                    },
                    onFindMerged: {
                        beginFindMergedBranches()
                        showBranchesPopover = false
                    },
                    onRemoteTags: {
                        showBranchesPopover = false
                        showMultiRootRemoteTagsDialog = true
                    },
                    onCheckout: { rootPath, reference, isRemote in
                        checkoutBranchInRoot(
                            rootPath: rootPath,
                            reference: reference,
                            isRemote: isRemote
                        )
                        showBranchesPopover = false
                    },
                    onCheckoutAsNewBranch: { rootPath, reference, isRemote in
                        presentMultiRootNewBranchFromReference(
                            rootPath: rootPath,
                            reference: reference,
                            isRemote: isRemote
                        )
                    },
                    onCheckoutAndUpdate: { rootPath, reference, _, rebase in
                        executeMultiRootCheckoutAndUpdate(
                            reference: reference,
                            rootPath: rootPath,
                            detach: false,
                            rebase: rebase
                        )
                        showBranchesPopover = false
                    },
                    onCheckoutWithRebase: { rootPath, reference, isRemote in
                        if isRemote {
                            presentNewBranchFromReference(
                                reference,
                                isRemote: true,
                                afterCreateRebase: true,
                                rootPath: rootPath
                            )
                        } else {
                            executeMultiRootCheckoutWithRebase(
                                rootPath: rootPath,
                                branch: reference
                            )
                        }
                        showBranchesPopover = false
                    },
                    onCheckoutRecent: { rootPath, name in
                        checkoutRecentBranchInRoot(rootPath: rootPath, name: name)
                        showBranchesPopover = false
                    },
                    onCheckoutTag: { rootPath, name in
                        checkoutTagInRoot(rootPath: rootPath, name: name)
                        showBranchesPopover = false
                    },
                    onDeleteTag: { rootPath, name in
                        deleteTagInRoot(rootPath: rootPath, name: name)
                    },
                    onDeleteTagAcrossRoots: { name in
                        presentMultiRootDeleteTagDialog(name: name)
                        showBranchesPopover = false
                    },
                    onRenameTag: { rootPath, name in
                        renameTagInRoot(rootPath: rootPath, name: name)
                    },
                    onPushTag: { rootPath, name in
                        pushTagInRoot(rootPath: rootPath, name: name)
                    },
                    onPushTagToRemote: { rootPath, name, remote in
                        pushTagInRoot(rootPath: rootPath, name: name, remote: remote)
                    },
                    onShowDiffWithWorkingTree: { rootPath, name in
                        showBranchDiffWithWorkingTree(rootPath: rootPath, branch: name)
                    },
                    onPushAllTags: { rootPath, remote in
                        pushAllTagsInRoot(rootPath: rootPath, remote: remote)
                    },
                    onApplyStash: { rootPath, stashID, restoreIndex in
                        applyStashInRoot(rootPath: rootPath, stashID: stashID, restoreIndex: restoreIndex)
                    },
                    onPopStash: { rootPath, stashID, restoreIndex in
                        popStashInRoot(rootPath: rootPath, stashID: stashID, restoreIndex: restoreIndex)
                    },
                    onDropStash: { rootPath, stashID in
                        dropStashInRoot(rootPath: rootPath, stashID: stashID)
                    },
                    onStashBranch: { rootPath, stashID in
                        stashBranchInRoot(rootPath: rootPath, stashID: stashID)
                    },
                    onStashDiff: { rootPath, stashID in
                        showStashDiffInRoot(rootPath: rootPath, stashID: stashID)
                    },
                    onStashClear: { rootPath in
                        clearStashesInRoot(rootPath: rootPath)
                    },
                    onUpdateBranch: { rootPath, branch in
                        updateBranchInRoot(rootPath: rootPath, branch: branch)
                        showBranchesPopover = false
                    },
                    onForcePushedUpdate: { rootPath, branch in
                        updateForcePushedBranchInRoot(rootPath: rootPath, branch: branch)
                        showBranchesPopover = false
                    },
                    onForcePushedUpdateAcrossRoots: { branch in
                        updateForcePushedBranchAcrossRoots(branch)
                        showBranchesPopover = false
                    },
                    onPullBranch: { rootPath, branch, rebase in
                        pullBranchInRoot(rootPath: rootPath, branch: branch, rebase: rebase)
                        showBranchesPopover = false
                    },
                    onPullRemoteBranch: { rootPath, branch, rebase in
                        pullRemoteBranchInRoot(
                            rootPath: rootPath,
                            remoteBranch: branch,
                            rebase: rebase
                        )
                        showBranchesPopover = false
                    },
                    onDeleteRemote: { rootPath, branch in
                        deleteRemoteBranchInRoot(rootPath: rootPath, branch: branch)
                        showBranchesPopover = false
                    },
                    onDeleteRemoteAcrossRoots: { branch in
                        presentMultiRootRemoteDeleteDialog(branch: branch)
                        showBranchesPopover = false
                    },
                    onMerge: { rootPath, branch in
                        mergeBranchInRoot(rootPath: rootPath, branch: branch)
                        showBranchesPopover = false
                    },
                    onMergeAcrossRoots: presentMultiRootMergeFromPopup,
                    onRebase: { rootPath, branch in
                        rebaseCurrentInRoot(rootPath: rootPath, onto: branch)
                        showBranchesPopover = false
                    },
                    onCompare: { rootPath, branch in
                        compareBranchInRoot(rootPath: rootPath, branch: branch)
                        showBranchesPopover = false
                    },
                    onCompareSelected: { selection in
                        guard selection.count == 2,
                              let first = selection.first,
                              selection.allSatisfy({ $0.rootPath == first.rootPath }) else { return }
                        compareBranchesCommitWiseInRoot(
                            rootPath: first.rootPath,
                            first: first.name,
                            second: selection[1].name
                        )
                        showBranchesPopover = false
                    },
                    onCompareSelectedFiles: { selection in
                        guard selection.count == 2,
                              let first = selection.first,
                              selection.allSatisfy({ $0.rootPath == first.rootPath }) else { return }
                        compareBranchesInRoot(
                            rootPath: first.rootPath,
                            first: first.name,
                            second: selection[1].name
                        )
                        showBranchesPopover = false
                    },
                    onUpdateSelected: { selection in
                        updateSelectedBranchesInRoots(selection)
                        showBranchesPopover = false
                    },
                    onDeleteSelected: { selection in
                        deleteSelectedBranchesInRoots(selection)
                        showBranchesPopover = false
                    },
                    onPushDialog: { rootPath, branch in
                        beginMultiRootPushDialog(rootPath: rootPath, branch: branch)
                        showBranchesPopover = false
                    },
                    onEditRemote: { rootPath, name in
                        beginMultiRootRemoteConfig(rootPath: rootPath, selectedRemote: name)
                        showBranchesPopover = false
                    },
                    onRemoveRemote: { rootPath, name in
                        removeRemoteInRoot(rootPath: rootPath, name: name)
                    },
                    onRemoveRemoteSelected: { groups in
                        removeSelectedRemotesInRoots(groups)
                    },
                    onConfigureRemotes: {
                        beginConfigureRemotes()
                    },
                    onSetUpstream: { rootPath, branch in
                        setBranchUpstreamInRoot(rootPath: rootPath, branch: branch)
                        showBranchesPopover = false
                    },
                    onUnsetUpstream: { rootPath, branch in
                        unsetBranchUpstreamInRoot(rootPath: rootPath, branch: branch)
                        showBranchesPopover = false
                    },
                    onRenameBranch: { rootPath, branch in
                        renameBranchInRoot(rootPath: rootPath, oldName: branch)
                        showBranchesPopover = false
                    },
                    onRenameBranchAcrossRoots: { name in
                        presentMultiRootRenameBranchDialog(name: name)
                        showBranchesPopover = false
                    },
                    onDeleteBranchAcrossRoots: { name in
                        presentMultiRootDeleteBranchDialog(name: name)
                        showBranchesPopover = false
                    },
                    onDeleteBranch: { rootPath, branch in
                        deleteBranchInRoot(rootPath: rootPath, name: branch)
                        showBranchesPopover = false
                    },
                    onCheckoutReference: { rootPath in
                        checkoutReferenceFromInput(rootPath: rootPath)
                    },
                    onOpenWorktree: { path in
                        showBranchesPopover = false
                        openWindow(value: path)
                    },
                    onCreateWorktreeFromReference: { rootPath, reference, isTag in
                        showBranchesPopover = false
                        presentNewWorktreeFromReference(
                            reference,
                            isTag: isTag,
                            rootPath: rootPath
                        )
                    },
                    onProjectGitSettings: {
                        showBranchesPopover = false
                        showProjectGitSettings = true
                    },
                    onCancel: { showBranchesPopover = false }
                )
            } else {
                RebasedBranchesPopover(
                projectPath: projectPath,
                branches: branches,
                remoteBranches: remoteBranches,
                recentBranches: recentBranches,
                tags: tags,
                comparisons: branchComparisons,
                syncStatuses: syncStatuses,
                incomingBranches: autoFetchIncomingBranches,
                stashes: stashes,
                worktrees: worktrees,
                hasRemote: !remotes.isEmpty,
                protectedBranchPatterns: effectiveProtectedBranchPatterns,
                isShallow: isShallowRepository,
                hasHeadCommit: headId != nil,
                hasCommitChanges: vcsActionContext.hasLocalChanges,
                onCheckout: switchBranch,
                onRenameBranch: renameBranchFromPopup,
                onDeleteBranch: deleteBranchFromPopup,
                onCheckoutRecent: checkoutRecentBranch,
                onCheckoutTag: checkoutTag,
                onCheckoutAsNewBranch: { reference, isRemote in
                    presentNewBranchFromReference(reference, isRemote: isRemote)
                },
                onDeleteTag: tagDelete,
                onRenameTag: { old in
                    let alert = NSAlert()
                    alert.messageText = "Rename Tag"
                    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
                    field.stringValue = old
                    alert.accessoryView = field
                    alert.addButton(withTitle: "Rename")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        tagRename(old, field.stringValue)
                    }
                },
                onPushTag: { tag in tagPushToRemote(tag) },
                tagPushRemotes: remotes.map(\.name),
                onPushTagToRemote: { tag, remote in
                    tagPushToRemote(tag, remote: remote)
                },
                onShowDiffWithWorkingTree: { branch in
                    showBranchDiffWithWorkingTree(rootPath: nil, branch: branch)
                },
                onPushAllTags: { remote in
                    pushAllTagsToRemote(remote: remote)
                },
                onRemoteTags: {
                    showBranchesPopover = false
                    showRemoteTagsDialog = true
                },
                onCheckoutAndUpdate: { branch, rebase in checkoutAndUpdate(branch, rebase: rebase) },
                onUpdateBranch: updateSelectedBranch,
                onPushBranch: { branch in beginPushDialog(branch: branch) },
                onForcePushedUpdate: updateForcePushedBranch,
                onPullRemoteBranch: { branch, rebase in pullRemoteBranch(branch, rebase: rebase) },
                onCheckoutRemote: checkoutRemoteBranch,
                onCheckoutRemoteWithRebase: { branch in
                    presentNewBranchFromReference(
                        branch.name,
                        isRemote: true,
                        afterCreateRebase: true
                    )
                },
                onDeleteRemote: deleteRemoteBranch,
                onNewBranch: { presentNewBranchDialog() },
                onCommitChanges: openCommitWorkspaceFromBranchPopup,
                onFindMerged: {
                    beginFindMergedBranches()
                    showBranchesPopover = false
                },
                onCheckoutReference: checkoutReferenceFromInput,
                onOpenWorktree: { path in
                    showBranchesPopover = false
                    openWindow(value: path)
                },
                onCreateWorktreeFromReference: { reference, isTag in
                    showBranchesPopover = false
                    presentNewWorktreeFromReference(reference, isTag: isTag)
                },
                onCompare: compareBranchFromPopup,
                onMerge: openMergeDialog,
                onRebase: openRebaseDialog,
                onStash: presentStashDialog,
                onApplyStash: { stashID, restoreIndex in stashApply(stashID: stashID, restoreIndex: restoreIndex) },
                onPopStash: { stashID, restoreIndex in stashPop(stashID: stashID, restoreIndex: restoreIndex) },
                onDropStash: stashDrop(stashID:),
                onStashBranch: stashBranch(stashID:),
                onStashDiff: showStashDiffFor(stashID:),
                onStashClear: stashClearAll,
                onNewTag: beginNewTagDialog,
                onShelve: { showShelveDialog = true },
                onUpdate: { doPull(nil, rebase: $0) },
                onPush: { beginPushDialog() },
                onFetch: { doFetch(nil) },
                onRefresh: { loadRepoData() },
                onConfigureRemotes: beginConfigureRemotes,
                onProjectGitSettings: {
                    showBranchesPopover = false
                    showProjectGitSettings = true
                },
                onFetchAll: { doFetchAll() },
                onFetchPrune: doFetchPrune,
                onFetchUnshallow: doFetchUnshallow,
                onSetUpstream: { branch in
                    upstreamLocalBranch = branch
                    showUpstreamDialog = true
                },
                onUnsetUpstream: unsetBranchUpstream,
                operationState: operationState,
                onOperationContinue: {
                    doOperationContinue()
                    showBranchesPopover = false
                },
                onOperationSkip: {
                    doOperationSkip()
                    showBranchesPopover = false
                },
                onOperationAbort: {
                    doOperationAbort()
                    showBranchesPopover = false
                }
                )
            }
        }
    }

    private var remoteConfigSheet: some View {
        Group {
            if repo != nil {
                RemoteConfigDialogView(
                    remotes: remotes,
                    name: $remoteName,
                    url: $remoteUrl,
                    pushUrl: $remotePushUrl,
                    fetchRefspec: $remoteFetchRefspec,
                    pushRefspec: $remotePushRefspec,
                    initialSelectedName: nil,
                    onAdd: remoteAdd,
                    onRemove: remoteRemove,
                    onRename: remoteRename,
                    onSave: saveRemoteConfig,
                    onCancel: { showRemoteConfigDialog = false },
                    onRefresh: loadRemotes
                )
            }
        }
    }

    private func saveUpstreamFromDialog(_ upstream: String) {
        let branch = upstreamLocalBranch
        showUpstreamDialog = false
        setBranchUpstream(branch, upstream: upstream)
    }

    private var rebaseTodoSheet: some View {
        Group {
            if let repo {
                RebaseTodoEditorView(
                    repo: repo,
                    onto: rebaseTodoOnto,
                    items: $rebaseTodoItems,
                    preserveMerges: rebaseTodoPreserveMerges,
                    root: rebaseTodoRoot,
                    onStart: startTodoRebase,
                    onOpenRawTodo: prepareRawRebaseTodoEditor,
                    onCancel: { showRebaseTodoEditor = false }
                )
            }
        }
    }

    private var rebaseRawTodoSheet: some View {
        RawRebaseTodoEditorView(
            onto: rebaseTodoOnto,
            text: $rebaseRawTodoText,
            preserveMerges: rebaseTodoPreserveMerges,
            root: rebaseTodoRoot,
            onStart: startRawTodoRebase,
            onCancel: {
                showRawRebaseTodoEditor = false
                rebaseRawTodoText = ""
            }
        )
    }

    /// IDX-001 二进制文件路径集合（staging model 提供）。
    private var stagingBinaryPaths: Set<String> {
        Set((stagingModel?.entries ?? []).filter { $0.binary }.map { $0.path })
    }

    /// IDX-001: expose exact HEAD/index/worktree presence to Changes actions;
    /// status kinds alone cannot distinguish an empty file from a missing side.
    private var stagingPresenceByPath: [String: StagingVersionPresence] {
        Dictionary(
            uniqueKeysWithValues: (stagingModel?.entries ?? []).map { entry in
                (entry.path, stagingVersionPresence(for: entry))
            }
        )
    }

    private var fileContentVersionOptions: [FileContentVersion] {
        guard let path = fileSelection,
              let entry = entries.first(where: { $0.path == path }) else {
            return [fileSelectionVersion]
        }
        return fileContentVersions(
            for: stagingVersionActions(
                for: entry,
                presence: stagingPresenceByPath[path]
            ),
            current: fileSelectionVersion
        )
    }

    /// CONFLICT-001：merge/rebase/cherry-pick/revert 进入同一冲突工作台。
    private var mergeRevisionsMode: MergeRevisionsDialogView.Mode {
        if stashPopConflictInProgress || stashApplyConflictInProgress {
            return .stashRestore
        }
        if shelveConflictInProgress {
            if shelveConflictIsDirectPatch {
                return .applyPatch
            }
            return .shelveRestore(isPop: shelveConflictIsPop)
        }
        switch operationState?.kind {
        case .rebase: return .rebase
        case .cherryPick: return .cherryPick
        case .revert: return .revert
        default: return .merge
        }
    }

    private var mergeRevisionsAbortAction: (() -> Void)? {
        if shelveConflictInProgress {
            return { abortShelveConflict() }
        }
        if stashPopConflictInProgress || stashApplyConflictInProgress {
            return nil
        }
        return {
            doOperationAbort()
            showMergeRevisionsDialog = false
        }
    }

    /// IntelliJ keeps the conflict resolver in a non-modal tool window: the
    /// user can hide it, inspect the rest of the project, and reopen it from
    /// the operation bar or conflict notification without changing the
    /// in-progress Git state. Keep
    /// the resolver itself as the single source of truth and only change its
    /// presentation here.
    @ViewBuilder
    private var conflictResolverOverlays: some View {
        if showMergeRevisionsDialog {
            singleRootConflictResolverPanel
        }
        if showMultiRootConflictResolver {
            multiRootConflictResolverPanel
        }
    }

    @ViewBuilder
    private var singleRootConflictResolverPanel: some View {
        if let repo = pendingShelveConflictRepository ?? self.repo {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Resolve Conflicts")
                        .font(.headline)
                    Text(mergeRevisionsMode.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Close") {
                        showMergeRevisionsDialog = false
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                Divider()
                MergeRevisionsDialogView(
                    repo: repo,
                    entries: $entries,
                    initialPath: mergeInitialPath ?? selection,
                    mode: mergeRevisionsMode,
                    directPatchText: shelveConflictIsDirectPatch ? pendingShelveConflictPatch : nil,
                    directPatchRestoreName: shelveConflictIsDirectPatch ? pendingShelveConflictName : nil,
                    onChanged: {
                        if shelveConflictInProgress {
                            refreshShelveConflictStatus()
                        } else {
                            refreshAll()
                        }
                    },
                    onComplete: {
                        if shelveConflictInProgress {
                            finishShelveConflict()
                        } else {
                            doOperationContinue()
                            showMergeRevisionsDialog = false
                            mergeInitialPath = nil
                        }
                    },
                    onAbort: mergeRevisionsAbortAction,
                    onSkip: nil,
                    compact: true
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 1000, height: 680)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.16), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
            .padding(14)
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .zIndex(20)
        }
    }

    @ViewBuilder
    private var multiRootConflictResolverPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Git Roots Conflicts")
                    .font(.headline)
                Spacer()
                Button("Close", action: closeMultiRootResolver)
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()
            MultiRootConflictResolverView(
                roots: multiRootResolverRoots,
                activeRootPath: multiRootResolverActiveRootPath,
                activeRepo: multiRootResolverActiveRepo,
                entries: $multiRootResolverActiveEntries,
                initialPath: multiRootResolverActiveInitialPath,
                activeKind: multiRootResolverActiveKind,
                isWorking: multiRootResolverWorking,
                error: multiRootResolverError,
                onSelectRoot: selectMultiRootResolverRoot,
                onChanged: refreshMultiRootResolverActiveRoot,
                onComplete: completeMultiRootResolverRoot,
                onSkip: skipMultiRootResolverRoot,
                onAbort: abortMultiRootResolverRoot,
                onClose: closeMultiRootResolver,
                compact: true
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 1060, height: 700)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.16), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        .padding(14)
        .transition(.move(edge: .trailing).combined(with: .opacity))
        .zIndex(21)
    }

    func openMergeDialog(_ branch: String?) {
        guard operationState?.kind == nil,
              isArborVCSActionVisible(.merge, in: vcsActionContext),
              isArborVCSActionEnabled(.merge, in: vcsActionContext) else { return }
        loadMergeDialogSettings(for: projectPath)
        if let branch { mergeBranch = branch }
        mergeDialogGeneration &+= 1
        let generation = mergeDialogGeneration
        mergeMergedBranches = []
        showMergeActionDialog = true
        guard let repo else { return }
        Task.detached(priority: .userInitiated) {
            let mergedBranches = (try? repo.branchListMerged().map(\.name)) ?? []
            await MainActor.run {
                guard generation == self.mergeDialogGeneration else { return }
                self.mergeMergedBranches = Set(mergedBranches)
            }
        }
    }

    func loadMergeDialogSettings(for projectPath: String?) {
        let settings = GitMergeDialogSettingsStore.load(for: projectPath)
        mergeBranch = settings.branch
        mergeStrategyRaw = settings.strategyRaw
        mergeUseCustomCommitMessage = settings.useCustomCommitMessage
        mergeNoCommit = settings.noCommit
        mergeNoVerify = settings.noVerify
        mergeAllowUnrelatedHistories = settings.allowUnrelatedHistories
        if !mergeUseCustomCommitMessage {
            mergeCommitMessage = ""
        }
    }

    func saveMergeDialogSettings() {
        GitMergeDialogSettingsStore.save(
            GitMergeDialogSettings(
                branch: mergeBranch,
                strategyRaw: mergeStrategyRaw,
                useCustomCommitMessage: mergeUseCustomCommitMessage,
                noCommit: mergeNoCommit,
                noVerify: mergeNoVerify,
                allowUnrelatedHistories: mergeAllowUnrelatedHistories
            ),
            for: projectPath
        )
    }

    func loadRebaseDialogSettings(for projectPath: String?) {
        let settings = GitRebaseDialogSettingsStore.load(for: projectPath)
        rebaseOnto = settings.onto
        rebaseInteractive = settings.interactive
        rebasePreserveMerges = settings.preserveMerges
        rebaseAutoSquash = settings.autoSquash
        rebaseKeepEmpty = settings.keepEmpty
        rebaseUpdateRefs = settings.updateRefs
        rebaseRoot = settings.root
    }

    func saveRebaseDialogSettings() {
        GitRebaseDialogSettingsStore.save(
            GitRebaseDialogSettings(
                onto: rebaseOnto,
                interactive: rebaseInteractive,
                preserveMerges: rebasePreserveMerges,
                autoSquash: rebaseAutoSquash,
                keepEmpty: rebaseKeepEmpty,
                updateRefs: rebaseUpdateRefs,
                root: rebaseRoot
            ),
            for: projectPath
        )
    }

    func openRebaseDialog(_ branch: String?) {
        guard operationState?.kind == nil,
              isArborVCSActionVisible(.rebase, in: vcsActionContext),
              isArborVCSActionEnabled(.rebase, in: vcsActionContext) else { return }
        loadRebaseDialogSettings(for: projectPath)
        if let branch { rebaseOnto = branch }
        rebaseRootPath = repo?.workdir() ?? multiRoots.first?.path ?? ""
        rebaseBranch = rebaseBranchOptions.first(where: { $0.isCurrent })?.name
            ?? rebaseBranchOptions.first?.name
            ?? ""
        rebaseApplyToAllRoots = false
        rebaseRange = []
        rebaseActions = []
        rebaseFeedback = nil
        showRebaseActionDialog = true
    }

    private func selectRebaseRepository() {
        let snapshot = multiRootBranchSnapshots.first(where: {
            $0.rootPath == rebaseRootPath
        })
        rebaseBranch = snapshot?.headBranch
            ?? snapshot?.branches.first(where: { $0.isCurrent })?.name
            ?? snapshot?.branches.first?.name
            ?? ""
        invalidateLoadedRebaseRange()
    }

    private func compareBranchFromPopup(_ branch: String) {
        toolWindowMode = .log
        toolWindowExpanded = true
        projectPanelExpanded = false
        compareLogBranch(rootPath: nil, branch: branch)
        showBranchesPopover = false
    }

    func renameBranchFromPopup(_ oldName: String) {
        let alert = NSAlert()
        alert.messageText = "Rename Branch"
        let field = NSTextField(string: oldName)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != oldName else { return }
        renameOld = oldName
        renameNew = newName
        branchRename()
    }

    private func deleteBranchFromPopup(_ name: String) {
        let alert = NSAlert()
        alert.messageText = "Delete branch \(name)?"
        alert.informativeText = "This removes the local branch reference. Unmerged commits are not deleted from the object database immediately."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        branchDelete(name)
    }

    private func handleBranchCleanupAction(_ action: BranchCleanupWindowAction?) {
        guard let action else { return }
        branchCleanupWindow.action = nil
        switch action {
        case let .calculate(target, prefix):
            calculateBranchCleanup(target: target, prefix: prefix)
        case let .delete(selections):
            deleteBranchCleanup(selections)
        case .refresh:
            refreshBranchCleanup()
        }
    }

}
