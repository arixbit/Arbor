import SwiftUI
import AppKit


struct ContentView: View {
    @Environment(\.openWindow) var openWindow

    /// 项目路径、仓库与主窗口导航状态。
    @StateObject var projectWorkspace: ProjectWorkspaceState

    /// 工作区状态快照、刷新协调与暂存模型。
    @StateObject var repositoryStatus: RepositoryStatusState = RepositoryStatusState()

    /// 文件选择、版本查看、预览与补丁交互状态。
    @StateObject var fileWorkspace: FileWorkspaceState = FileWorkspaceState()

    /// 单 root 与多 root 提交草稿、提交选项和后续动作。
    @StateObject var commitWorkspace: CommitWorkspaceState = CommitWorkspaceState()

    /// 克隆对话框、取消句柄与请求代际。
    @StateObject var cloneWorkspace: CloneWorkspaceState = CloneWorkspaceState()

    /// LFS 面板的能力、文件、跟踪输入与加载反馈。
    @StateObject var lfsWorkspace: LfsWorkspaceState = LfsWorkspaceState()

    /// Git hooks 面板、脚本选择和编辑草稿。
    @StateObject var hooksWorkspace: HooksWorkspaceState = HooksWorkspaceState()

    /// Git root 发现、聚合快照与批量更新事务。
    @StateObject var multiRootWorkspace: MultiRootWorkspaceState = MultiRootWorkspaceState()

    /// 操作恢复、冲突解析与操作日志的窗口状态。
    @StateObject var operationRecovery: OperationRecoveryState = OperationRecoveryState()

    /// Merge 对话框选项、多 root 回滚和冲突收尾上下文。
    @StateObject var mergeWorkspace: MergeWorkspaceState = MergeWorkspaceState()

    /// Rebase 草稿、todo 编辑、进行中会话、重试与撤销上下文。
    @StateObject var rebaseWorkspace: RebaseWorkspaceState = RebaseWorkspaceState()

    /// 版本比较输入、来源仓库、文件列表与加载任务。
    @StateObject var comparisonWorkspace: ComparisonWorkspaceState = ComparisonWorkspaceState()

    /// 远程仓库列表与单 root、多 root 配置对话框。
    @StateObject var remoteWorkspace: RemoteWorkspaceState = RemoteWorkspaceState()

    /// 项目 Git 偏好、自动 fetch、身份、签名与 SSH 设置草稿。
    @StateObject var gitSettings: GitSettingsState = GitSettingsState()

    /// 托管平台设置、身份提示与代码评审入口。
    @StateObject var hostingWorkspace: HostingWorkspaceState = HostingWorkspaceState()

    /// 推送选项、目标引用与多 root 重试上下文。
    @StateObject var pushWorkspace: PushWorkspaceState = PushWorkspaceState()

    /// Pull 对话框的快照、更新方式和请求代际。
    @StateObject var pullWorkspace: PullWorkspaceState = PullWorkspaceState()

    /// 子模块列表、输入、反馈与独立日志预览。
    @StateObject var submoduleWorkspace: SubmoduleWorkspaceState = SubmoduleWorkspaceState()

    /// Worktree 列表与目标 root 下的新建对话框。
    @StateObject var worktreeWorkspace: WorktreeWorkspaceState = WorktreeWorkspaceState()

    /// 选中提交和指定 root 的 HEAD Reset 对话框。
    @StateObject var resetWorkspace: ResetWorkspaceState = ResetWorkspaceState()

    /// Stash / Unstash 工作页状态（对话框、预览、请求身份）。
    @StateObject var stashUI = StashWorkspaceState()

    /// Stash 恢复与冲突状态（multi-root stash、pull 现场保存）。
    @StateObject var stashRecovery = StashRecoveryState()

    /// 分支列表与创建、重命名、删除、上游设置的工作区状态。
    @StateObject var branchWorkspace = BranchWorkspaceState()

    /// 双栏分支比较的列表、过滤、选中与分页状态。
    @StateObject var branchComparison = BranchComparisonState()

    /// 分支清理窗口与 Find Merged 对话框的请求、扫描和报告状态。
    @StateObject var branchCleanup = BranchCleanupState()

    /// Tag 列表与创建/删除状态。
    @StateObject var tagWorkspace = TagWorkspaceState()

    /// Shelf 列表、预览、按 root 加载与冲突恢复状态。
    @StateObject var shelfWorkspace = ShelfWorkspaceState()

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
    @AppStorage("arbor.log.showChangesFromParents.v1") var logShowChangesFromParents = false
    @AppStorage("arbor.log.showOnlyAffectedChanges.v1") var logShowOnlyAffectedChanges = false
    var repo: Repository? {
        projectWorkspace.repository
    }

    var searchEverywhereGitRoots: [SearchEverywhereGitRoot] {
        if !multiRootWorkspace.branchSnapshots.isEmpty {
            return multiRootWorkspace.branchSnapshots.map { snapshot in
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
            branches: branchWorkspace.branches,
            remoteBranches: branchWorkspace.remoteBranches,
            tags: tagWorkspace.tags
        )]
    }

    var newWorktreeRepository: Repository? {
        guard let rootPath = worktreeWorkspace.rootPath, !rootPath.isEmpty else {
            return repo
        }
        return try? openRepository(path: rootPath)
    }

    var newWorktreeBranches: [BranchInfo] {
        guard let rootPath = worktreeWorkspace.rootPath,
              let snapshot = multiRootWorkspace.branchSnapshots.first(where: { $0.rootPath == rootPath }) else {
            return branchWorkspace.branches
        }
        return snapshot.branches
    }

    var newWorktreeWorktrees: [WorktreeInfo] {
        guard let rootPath = worktreeWorkspace.rootPath,
              let snapshot = multiRootWorkspace.branchSnapshots.first(where: { $0.rootPath == rootPath }) else {
            return worktreeWorkspace.worktrees
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
        paths.append(contentsOf: multiRootWorkspace.roots.map(\.path))
        if let active = logList.activeRootPath, !active.isEmpty {
            paths.append(active)
        }
        return Array(Set(paths)).sorted()
    }

    var primaryShelfRootPath: String? {
        if let workdir = repo?.workdir(), !workdir.isEmpty {
            return canonicalExternalLogPath(workdir)
        }
        if let projectPath = projectWorkspace.path, !projectPath.isEmpty {
            return canonicalExternalLogPath(projectPath)
        }
        return nil
    }

    var availableShelfRoots: [GitRootInfo] {
        guard multiRootWorkspace.roots.count > 1 else { return [] }
        let primary = primaryShelfRootPath
        return multiRootWorkspace.roots.sorted { lhs, rhs in
            let lhsIsPrimary = canonicalExternalLogPath(lhs.path) == primary
            let rhsIsPrimary = canonicalExternalLogPath(rhs.path) == primary
            if lhsIsPrimary != rhsIsPrimary { return lhsIsPrimary }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }

    var activeShelfRootPath: String? {
        if let rootPath = shelfWorkspace.rootPath, !rootPath.isEmpty {
            return canonicalExternalLogPath(rootPath)
        }
        return primaryShelfRootPath
    }

    var isShelfRootReadOnly: Bool {
        !shelfRootSelectionIsPrimary(
            selectedRootPath: shelfWorkspace.rootPath,
            primaryRootPath: primaryShelfRootPath
        )
    }

    var canApplyShelfWorktree: Bool {
        !shelfWorkspace.rootLoading
            && shelfWorkspace.rootError == nil
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
        return shelfWorkspace.rootSnapshots[rootPath]
            ?? multiRootWorkspace.branchSnapshots.first(where: {
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
              ) else { return shelfWorkspace.shelves }
        return activeShelfSnapshot?.shelves ?? []
    }

    var activeShelfChangeLists: [ChangeListInfo] {
        guard let activeRoot = activeShelfRootPath,
              !shelfRootSelectionIsPrimary(
                  selectedRootPath: activeRoot,
                  primaryRootPath: primaryShelfRootPath
              ) else { return repositoryStatus.changeLists }
        return activeShelfSnapshot?.changeLists ?? []
    }

    var activeDeletedShelfList: [ShelveInfo] {
        guard let activeRoot = activeShelfRootPath,
              !shelfRootSelectionIsPrimary(
                  selectedRootPath: activeRoot,
                  primaryRootPath: primaryShelfRootPath
              ) else { return shelfWorkspace.deletedShelves }
        return activeShelfSnapshot?.deletedShelves ?? []
    }

    var activeShelfRepository: Repository? {
        guard let rootPath = activeShelfRootPath else { return repo }
        if shelfRootSelectionIsPrimary(
            selectedRootPath: rootPath,
            primaryRootPath: primaryShelfRootPath
        ) { return repo }
        return shelfWorkspace.rootRepository
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
            if let snapshot = multiRootWorkspace.branchSnapshots.first(where: {
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
            if let snapshot = multiRootWorkspace.branchSnapshots.first(where: {
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
        logList.activeRootPath == nil ? branchWorkspace.branches : logRuntime.activeBranches
    }

    var activeLogRemoteBranches: [RemoteBranchInfo] {
        logList.activeRootPath == nil ? branchWorkspace.remoteBranches : logRuntime.activeRemoteBranches
    }

    var activeLogRemotes: [RemoteInfo] {
        logList.activeRootPath == nil ? remoteWorkspace.remotes : logRuntime.activeRemotes
    }

    /// Include repository identity so a project restored before its
    /// repository finishes loading starts the monitor when the repo arrives,
    /// and a linked worktree switch replaces the watched Git directory.
    var repositoryIndexMonitorID: String {
        "\(projectWorkspace.path ?? "")|\(repo?.gitDir() ?? "closed")"
    }

    var autoFetchRootPaths: [String] {
        mergedAutoFetchRootPaths(
            primary: repo?.workdir(),
            discovered: multiRootWorkspace.roots.map(\.path)
        )
    }

    var autoFetchMonitorID: String {
        "\(repositoryIndexMonitorID)|\(autoFetchRootPaths.joined(separator: "|"))|\(incomingCheckStrategy.rawValue)|tags-\(fetchTagsMode)|run-\(gitSettings.autoFetchRunGeneration)"
    }

    var shelfLifecycleMonitorID: String {
        "\(repositoryIndexMonitorID)|\(autoFetchRootPaths.joined(separator: "|"))"
    }

    var autoFetchNotificationIDPrefix: String {
        let identity = projectWorkspace.path.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "no-project"
        return "git.fetch.\(identity)"
    }

    var protectedBranchPatterns: String {
        gitSettings.projectProtectedBranchPatterns ?? globalProtectedBranchPatterns
    }

    var protectedBranchSynchronize: Bool {
        gitSettings.projectProtectedBranchSynchronize ?? globalProtectedBranchSynchronize
    }

    var incomingCheckStrategy: GitIncomingCheckStrategy {
        guard incomingOutgoingInfoEnabled else { return .none }
        if let projectIncomingCheckStrategyRaw = gitSettings.projectIncomingCheckStrategyRaw {
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
        gitSettings.projectFetchTagsMode.engineValue
    }
    // IntelliJ's git.clone.recurse.submodules advanced setting defaults to
    // true; persist the same preference instead of resetting it per dialog.
    @AppStorage(GitCloneSettings.recurseSubmodulesKey)
    var cloneRecursiveSubmodules = GitCloneSettings.defaultRecurseSubmodules
    // 日志模式
    /// IntelliJ shows an action-group popup when a commit has multiple
    /// parents or children. Keep the resolved records separate from the
    /// paged graph so the popup can include commits outside the viewport.
    /// IntelliJ's graph table is a real multi-selection table. Keep the
    /// active row in `logSelectionState.selection` for the details panel, while this set
    /// preserves Cmd/Shift selections for toolbar and future batch actions.
    @AppStorage("arbor.log.recentPathFilters.v1") var logRecentPathFiltersRaw = ""
    @AppStorage("arbor.log.visibleRootPaths.v1") var logVisibleRootPathsPersistedRaw = ""
    // 分支模式
    @AppStorage(GitDeleteOnMergeOption.key) var mergeDeleteOnMergeRaw = GitDeleteOnMergeOption.defaultOption.rawValue
    @StateObject var vcsQuickActionsPanel = VCSQuickActionsPanelCoordinator()
    @StateObject var branchCleanupWindow = BranchCleanupWindowCoordinator()

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
            aggregateRepositories: initialLogRepositories,
            externalRootSelectionInitialized: externalLogWindow && !normalizedInitialExternalLogRoots.isEmpty
        ))
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
        _projectWorkspace = StateObject(wrappedValue: ProjectWorkspaceState(
            path: recoveredPath,
            inputPath: recoveredPath ?? "",
            toolWindowMode: initialToolWindowMode == .log ? .log : (rememberedMode ?? initialToolWindowMode)
        ))
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

    var hasStaged: Bool { repositoryStatus.entries.contains { $0.staged != .unchanged } }
    var hasLocalChanges: Bool {
        repositoryStatus.entries.contains {
            $0.staged != .unchanged || $0.unstaged != .unchanged
        }
    }
    /// 未暂存组：unstaged 维度有变更（含冲突文件，冲突显示在 unstaged 维度）
    var unstagedEntries: [FileEntry] {
        repositoryStatus.entries.filter {
            $0.unstaged != .unchanged
                && $0.unstaged != .untracked
                && $0.unstaged != .ignored
        }
    }
    var untrackedEntries: [FileEntry] {
        repositoryStatus.entries.filter { $0.unstaged == .untracked }
    }
    /// Rebased-style pull preserves the complete local workspace, including
    /// files that Git has not started tracking yet.
    var hasTrackedChanges: Bool {
        repositoryStatus.entries.contains {
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
        repositoryStatus.entries.contains { $0.unstaged == .untracked || $0.unstaged == .ignored }
    }
    /// 已暂存组：staged 维度有变更
    var stagedEntries: [FileEntry] { repositoryStatus.entries.filter { $0.staged != .unchanged } }
    var selectedEntry: FileEntry? {
        guard let selection = fileWorkspace.selection else { return nil }
        return repositoryStatus.entries.first { $0.path == selection }
    }
    var selectedEntryIsConflicted: Bool {
        guard let selectedEntry else { return false }
        return selectedEntry.staged == .conflicted || selectedEntry.unstaged == .conflicted
    }
    var selectedLocalChangePath: String? {
        // `restore --source HEAD --staged --worktree` is only valid when the
        // selected path exists in HEAD. Until the asynchronous staging model
        // has supplied that fact, keep the destructive main-menu action off.
        guard !shelfWorkspace.isWorkspaceTabActive, repositoryStatus.stagingModel != nil else { return nil }
        return arborSelectedRevertPath(
            entries: repositoryStatus.entries,
            candidates: [fileWorkspace.previewPath, fileWorkspace.selection, fileWorkspace.fileSelection],
            headPresentByPath: stagingPresenceByPath.mapValues(\.head)
        )
    }
    var selectedWorkspacePath: String? {
        guard !shelfWorkspace.isWorkspaceTabActive else { return nil }
        return [fileWorkspace.previewPath, fileWorkspace.selection, fileWorkspace.fileSelection]
            .compactMap { $0 }
            .first { !$0.isEmpty }
    }
    var selectedFileActionContext: ArborSelectedGitFileContext? {
        guard let selectedPath = selectedWorkspacePath,
              let normalizedPath = normalizedRepositoryRelativePath(selectedPath),
              let primaryRootPath = repo?.workdir(),
              !primaryRootPath.isEmpty else { return nil }

        let isDirectory: Bool
        if selectedPath == fileWorkspace.fileSelection, let projectPath = projectWorkspace.path {
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
        if !multiRootWorkspace.roots.isEmpty {
            roots = multiRootWorkspace.roots
        } else {
            roots = [GitRootInfo(
                path: primaryRootPath,
                displayName: URL(fileURLWithPath: primaryRootPath).lastPathComponent,
                relativePath: ".",
                isSubmodule: false,
                headBranch: currentBranchName,
                headId: repositoryStatus.headId,
                dirty: hasLocalChanges,
                operation: operationRecovery.operation?.kind
            )]
        }
        guard let target = fileReferenceComparisonTarget(
            path: normalizedPath,
            primaryRootPath: primaryRootPath,
            roots: roots
        ) else { return nil }

        let matchingEntries = repositoryStatus.entries.filter { $0.path == normalizedPath }
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
                && projectFileTreeCanAnnotate(path: normalizedPath, entries: repositoryStatus.entries),
            canCompareWithHead: !isDirectory
                && projectFileTreeCanCompareWithSameVersion(
                    path: normalizedPath,
                    entries: repositoryStatus.entries
                ),
            canCompareWithSelectedRevision: !isDirectory
                && projectFileTreeCanCompareWithSelectedRevision(
                    path: normalizedPath,
                    isDirectory: false,
                    entries: repositoryStatus.entries
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
        guard let compareSelection = comparisonWorkspace.selection else { return nil }
        return comparisonWorkspace.treeChanges.first { $0.path == compareSelection }
    }
    var selectedTreeChanges: [TreeChange] {
        orderedCompareSelection(changes: comparisonWorkspace.treeChanges, selectedPaths: comparisonWorkspace.selectedPaths)
    }
    var selectedBranchComparisonCommit: CommitInfo? {
        let commits = branchComparison.selectionSide == .first
            ? branchComparison.firstEntries
            : branchComparison.secondEntries
        return commits.first { $0.id == branchComparison.selectionID }
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
        hostingRepositories(for: remoteWorkspace.remotes)
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
            primaryPatterns: gitSettings.remoteProtectedBranchPatterns,
            patternsByRoot: gitSettings.remoteProtectedBranchPatternsByRoot
        )
        let remotePatterns: [String] = {
            guard let rootPath,
                  !gitSettings.remoteProtectedBranchPatternsByRoot.keys.contains(
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
        branchWorkspace.syncStatuses.first(where: { $0.branch == currentBranchName })
    }

    var currentBranchHasUnfetchedIncoming: Bool {
        hasUnfetchedIncomingBranch(
            rootPath: repo?.workdir() ?? projectWorkspace.path,
            branch: currentBranchName,
            in: gitSettings.autoFetchIncomingBranches
        )
    }

    private var multiRootMergePresentedView: some View {
        mainView
            .modifier(
                MultiRootMergePresentationModifier(
                    isPresented: $mergeWorkspace.showMultiRootDialog,
                    selectedRootPaths: $mergeWorkspace.multiRootSelectedRootPaths,
                    strategy: Binding(
                        get: { MergeStrategyChoice(rawValue: mergeWorkspace.strategyRaw) ?? .automatic },
                        set: { mergeWorkspace.strategyRaw = $0.rawValue }
                    ),
                    commitMessage: $mergeWorkspace.commitMessage,
                    useCustomCommitMessage: $mergeWorkspace.useCustomCommitMessage,
                    noCommit: $mergeWorkspace.noCommit,
                    noVerify: $mergeWorkspace.noVerify,
                    allowUnrelatedHistories: $mergeWorkspace.allowUnrelatedHistories,
                    rollbackContext: $mergeWorkspace.multiRootRollbackContext,
                    branchName: mergeWorkspace.multiRootBranchName,
                    snapshots: multiRootWorkspace.branchSnapshots,
                    mergedBranchesByRoot: mergeWorkspace.multiRootMergedBranchesByRoot,
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
                    gitSettings.autoFetchIncomingFingerprint = nil
                    gitSettings.autoFetchFailureFingerprint = nil
                    DiagnosticsLogger.shared.record(
                        operation: "auto-fetch",
                        repositoryPath: projectWorkspace.path,
                        code: "updated-\(updatedRefs.count)-refs"
                    )
                    loadRepoData(includeComparisons: false)
                    loadMultiRoots()
                    refreshAll(showFeedback: false)
                },
                onUnfetched: { snapshot in
                    guard self.repo?.gitDir() == expectedGitDir,
                          self.autoFetchMonitorID == expectedMonitorID else { return }
                    gitSettings.autoFetchIncomingBranches = applyingAutoFetchIncomingSnapshot(
                        snapshot,
                        to: gitSettings.autoFetchIncomingBranches
                    )
                    guard !gitSettings.autoFetchIncomingBranches.isEmpty else {
                        feedbackCenter.expire(notificationID: "\(autoFetchNotificationIDPrefix).incoming")
                        gitSettings.autoFetchIncomingFingerprint = nil
                        return
                    }
                    let displayValues = groupedAutoFetchIncomingBranches(
                        Array(gitSettings.autoFetchIncomingBranches)
                    ).map(\.displayValue)
                    let fingerprint = autoFetchNotificationFingerprint(displayValues)
                    guard fingerprint != gitSettings.autoFetchIncomingFingerprint else { return }
                    gitSettings.autoFetchIncomingFingerprint = fingerprint
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
                        gitSettings.autoFetchFailureFingerprint = nil
                        return
                    }
                    let fingerprint = autoFetchNotificationFingerprint(failures)
                    guard fingerprint != gitSettings.autoFetchFailureFingerprint else { return }
                    gitSettings.autoFetchFailureFingerprint = fingerprint
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
            gitSettings.autoFetchFailureFingerprint = nil
            gitSettings.autoFetchIncomingFingerprint = nil
            gitSettings.autoFetchIncomingBranches = []
        }
        .onChange(of: incomingOutgoingInfoEnabled) { _, enabled in
            guard !enabled else { return }
            feedbackCenter.expire(notificationID: "\(autoFetchNotificationIDPrefix).incoming")
            feedbackCenter.expire(notificationID: "\(autoFetchNotificationIDPrefix).error")
            gitSettings.autoFetchFailureFingerprint = nil
            gitSettings.autoFetchIncomingFingerprint = nil
            gitSettings.autoFetchIncomingBranches = []
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
        .focusedValue(\.arborRepositoryIsShallow, projectWorkspace.repository == nil ? nil : repositoryStatus.isShallowRepository)
        .focusedValue(\.arborRepositoryAvailable, repo != nil)
        .focusedValue(\.arborVCSActionContext, vcsActionContext)
        .focusedValue(
            \.arborVCSOperationContext,
            operationRecovery.operation.flatMap { state in
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
        .sheet(isPresented: $hooksWorkspace.showPanel) {
            HooksPanelView(
                hooks: hooksWorkspace.hooks,
                location: hooksWorkspace.location,
                contents: hooksWorkspace.contents,
                busy: hooksWorkspace.busy,
                feedback: hooksWorkspace.feedback,
                selectedName: $hooksWorkspace.selection,
                draft: $hooksWorkspace.draft,
                onRefresh: { reloadGitHooks() },
                onSelect: { selectGitHook($0) },
                onSave: { saveGitHookDraft() },
                onRevert: { revertGitHookDraft() },
                onToggleEnabled: { toggleGitHookEnabled($0) },
                onInstallSample: { installGitHookSample($0) },
                onDelete: { deleteGitHook($0) },
                onDismiss: { hooksWorkspace.showPanel = false }
            )
        }
        .sheet(isPresented: $lfsWorkspace.showPanel) {
            LfsPanelView(
                capability: lfsWorkspace.capability,
                patterns: lfsWorkspace.patterns,
                files: lfsWorkspace.files,
                hooks: lfsWorkspace.hooks,
                busy: lfsWorkspace.busy,
                feedback: lfsWorkspace.feedback,
                selectedPaths: $lfsWorkspace.selectedPaths,
                trackInput: $lfsWorkspace.trackInput,
                showAllRevisions: $lfsWorkspace.showAllRevisions,
                remoteName: $lfsWorkspace.remoteName,
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
                onDismiss: { lfsWorkspace.showPanel = false }
            )
        }
        .sheet(isPresented: $fileWorkspace.showRevisionBrowser) {
            if let repo = logRepository, let commit = fileWorkspace.revisionBrowserCommit {
                RevisionBrowserView(
                    repo: repo,
                    revision: commit.id,
                    commitTitle: commit.summary,
                    initialPath: fileWorkspace.revisionBrowserPath
                )
            }
        }
        .sheet(item: $fileWorkspace.referenceComparisonRequest) { request in
            FileReferenceComparisonView(
                repo: request.repo,
                path: request.path,
                isDirectory: request.isDirectory,
                mode: request.mode,
                onClose: { fileWorkspace.referenceComparisonRequest = nil }
            )
        }
        .sheet(item: $fileWorkspace.currentRevisionRequest) { request in
            CurrentRevisionView(
                path: request.path,
                commit: request.commit,
                onClose: { fileWorkspace.currentRevisionRequest = nil }
            )
        }
        .sheet(isPresented: $submoduleWorkspace.showLog) {
            SubmoduleLogView(
                path: submoduleWorkspace.logPath,
                commits: submoduleWorkspace.logEntries,
                error: submoduleWorkspace.logError,
                onClose: { submoduleWorkspace.showLog = false }
            )
        }
        .sheet(item: $branchWorkspace.deleteRecovery) { context in
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
                    branchWorkspace.deleteRecovery = nil
                }
            )
        }
        .sheet(item: $branchWorkspace.multiRootDeleteRecovery) { context in
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
                    branchWorkspace.multiRootDeleteRecovery = nil
                }
            )
        }
        .sheet(item: $tagWorkspace.deleteRecovery) { context in
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
                    tagWorkspace.deleteRecovery = nil
                }
            )
        }
        .sheet(isPresented: $tagWorkspace.showRemoteTagsDialog) {
            if let repo {
                RemoteTagsDialogView(
                    repo: repo,
                    broker: credentialAuth.broker,
                    remotes: remoteWorkspace.remotes,
                    onDeleted: { remote, tag in
                        feedbackCenter.success("Remote tag deleted", detail: "\(remote)/\(tag)")
                        refreshAll(showFeedback: false)
                    },
                    onDone: {
                        tagWorkspace.showRemoteTagsDialog = false
                    }
                )
            } else {
                ProgressView()
                    .frame(width: 640, height: 500)
            }
        }
        .sheet(isPresented: $tagWorkspace.showMultiRootRemoteTagsDialog) {
            MultiRootRemoteTagsDialogView(
                roots: multiRootWorkspace.roots,
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
                            action: { tagWorkspace.showMultiRootRemoteTagsDialog = true }
                        )
                    }
                },
                onDone: {
                    tagWorkspace.showMultiRootRemoteTagsDialog = false
                }
            )
        }
        .sheet(item: $tagWorkspace.multiRootDeleteRecovery) { context in
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
                    tagWorkspace.multiRootDeleteRecovery = nil
                }
            )
        }
        .sheet(isPresented: $branchCleanup.showFindMergedDialog, onDismiss: dismissFindMergedBranches) {
            FindMergedBranchesDialogView(
                roots: branchCleanup.roots,
                projectName: projectWorkspace.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "",
                targetBranch: $branchCleanup.targetBranch,
                prefix: $branchCleanup.prefix,
                isRunning: branchCleanup.isRunning,
                hasCalculated: branchCleanup.hasCalculated,
                summary: branchCleanup.summary,
                onCalculate: calculateFindMergedBranches,
                onOpenReport: openFindMergedReport,
                onCopy: copyFindMergedBranches,
                onDone: dismissFindMergedBranches,
                onCancel: cancelFindMergedBranches
            )
        }
        .sheet(isPresented: $branchCleanup.showReport) {
            FindMergedReportEditorView(report: branchCleanup.reportText)
        }
        .sheet(isPresented: $multiRootWorkspace.showChanges) {
            MultiRootChangesBrowser(
                groups: multiRootWorkspace.changeGroups,
                isLoading: multiRootWorkspace.changesLoading,
                error: multiRootWorkspace.changesError,
                onRefresh: loadMultiRootChanges,
                onStage: stageMultiRootPath,
                onUnstage: unstageMultiRootPath,
                onStageSelected: stageMultiRootPaths,
                onUnstageSelected: unstageMultiRootPaths,
                onCommitSelected: { selectedChanges in
                    multiRootWorkspace.showChanges = false
                    DispatchQueue.main.async {
                        openMultiRootCommitDialog(selectedChanges)
                    }
                },
                onStageAll: stageAllMultiRootPath,
                onUnstageAll: unstageAllMultiRootPath
            )
        }
        .sheet(isPresented: $commitWorkspace.showMultiRootDialog) {
            MultiRootCommitDialogView(
                groups: multiRootWorkspace.changeGroups.map(MultiRootCommitGroup.init(changeGroup:)),
                isLoading: multiRootWorkspace.changesLoading,
                error: multiRootWorkspace.changesError,
                recentMessages: commitWorkspace.multiRootRecentMessages,
                onTemplate: loadMultiRootCommitTemplate,
                onBeforeCommitSettings: { commitWorkspace.showBeforeCommitSettings = true },
                onIdentitySettings: { gitSettings.showIdentitySettings = true },
                message: $commitWorkspace.multiRootMessage,
                amendMode: $commitWorkspace.multiRootAmendMode,
                skipHooks: $commitWorkspace.multiRootSkipHooks,
                authorName: $commitWorkspace.multiRootAuthorName,
                authorEmail: $commitWorkspace.multiRootAuthorEmail,
                committerName: $commitWorkspace.multiRootCommitterName,
                committerEmail: $commitWorkspace.multiRootCommitterEmail,
                signOff: $commitWorkspace.multiRootSignOff,
                coAuthors: $commitWorkspace.multiRootCoAuthors,
                selectedChanges: commitWorkspace.multiRootSelectedPaths,
                onCommit: commitMultiRootSelectedRoots,
                onCommitAndPush: commitAndPushMultiRootSelectedRoots,
                onCommitSelectedChanges: commitMultiRootSelectedChanges,
                onCommitAndPushSelectedChanges: commitAndPushMultiRootSelectedChanges,
                onCancel: { commitWorkspace.showMultiRootDialog = false }
            )
        }
        .onChange(of: operationRecovery.showConflictResolver) { _, isPresented in
            if !isPresented { operationRecovery.initialPath = nil }
        }
        .alert("打开另一个项目？", isPresented: $projectWorkspace.showSwitchAlert) {
            Button("替换当前窗口") { replacePendingProject() }
            Button("新窗口") {
                openWindow(id: "project", value: projectWorkspace.pendingPath)
                projectWorkspace.pendingPath = nil
            }
            Button("取消", role: .cancel) { projectWorkspace.pendingPath = nil }
        } message: {
            Text("当前窗口正在显示 \(projectWorkspace.repository?.displayName() ?? "一个项目")。选择如何打开新项目。")
        }
        .alert("Create .gitignore?", isPresented: Binding(
            get: { fileWorkspace.pendingIgnoreFileCreation != nil },
            set: { isPresented in
                if !isPresented { fileWorkspace.pendingIgnoreFileCreation = nil }
            }
        )) {
            Button("Create") {
                confirmPendingIgnoreFileCreation()
            }
            Button("Cancel", role: .cancel) {
                fileWorkspace.pendingIgnoreFileCreation = nil
            }
        } message: {
            if let request = fileWorkspace.pendingIgnoreFileCreation {
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
        .sheet(item: $remoteWorkspace.multiRootRemoteConfigAggregateContext) { context in
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
                    remoteWorkspace.multiRootRemoteConfigAggregateContext = nil
                }
            )
        }
        .sheet(isPresented: $remoteWorkspace.showConfigDialog) {
            remoteConfigSheet
        }
        .sheet(isPresented: $branchWorkspace.showUpstreamDialog) {
            SetUpstreamDialogView(
                localBranch: branchWorkspace.upstreamLocalBranch,
                remoteBranches: branchWorkspace.remoteBranches,
                currentUpstream: branchWorkspace.syncStatuses.first {
                    $0.branch == branchWorkspace.upstreamLocalBranch && $0.trackingExists
                }?.upstream,
                onCancel: { branchWorkspace.showUpstreamDialog = false },
                onSave: saveUpstreamFromDialog
            )
        }
        .sheet(item: $branchWorkspace.multiRootUpstreamContext) { context in
            SetUpstreamDialogView(
                localBranch: context.localBranch,
                remoteBranches: context.remoteBranches,
                currentUpstream: context.currentUpstream,
                repositoryName: context.displayName,
                onCancel: { branchWorkspace.multiRootUpstreamContext = nil },
                onSave: { upstream in
                    branchWorkspace.multiRootUpstreamContext = nil
                    setBranchUpstreamInRoot(
                        rootPath: context.rootPath,
                        branch: context.localBranch,
                        upstream: upstream,
                        requireCurrentBranch: true
                    )
                }
            )
        }
        .sheet(isPresented: $rebaseWorkspace.showTodoEditor) {
            rebaseTodoSheet
        }
        .sheet(isPresented: $rebaseWorkspace.showRawTodoEditor) {
            rebaseRawTodoSheet
        }
        .sheet(isPresented: $rebaseWorkspace.showRawMessageEditor) {
            RawRebaseMessageEditorView(
                message: $rebaseWorkspace.rawMessageText,
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
        .alert("Rewrite Initial Commit?", isPresented: $logRewrite.showInitialCommitRewordAlert) {
            Button("Continue") {
                confirmInitialCommitReword()
            }
            Button("Cancel", role: .cancel) {
                logRewrite.pendingInitialCommitReword = nil
                logRewrite.rewordCommit = nil
                logRewrite.rewordUsesRootRebase = false
            }
        } message: {
            Text("The initial commit has no parent. Continue with this history rewrite?")
        }
        .alert("Rewrite Initial Commit?", isPresented: $logRewrite.showInitialCommitRewriteAlert) {
            Button("Continue") {
                confirmInitialCommitRewrite()
            }
            Button("Cancel", role: .cancel) {
                logRewrite.pendingInitialCommitRewrite = nil
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
            cloneWorkspace.showDialog = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .arborOpenCommitDetail)) { notification in
            guard let id = notification.object as? String else { return }
            projectWorkspace.toolWindowMode = .log
            toolWindowExpanded = true
            projectPanelExpanded = false
            logList.viewMode = .graph
            // A commit-detail notification can originate from the Commit
            // workspace (for example, Show History on a changed file). The
            // Log editor owns this context after the hand-off; leaving the
            // old staging/file selection alive makes mainContext render a
            // diff viewer over the Log workspace and looks like the history
            // page disappeared.
            fileWorkspace.selection = nil
            fileWorkspace.fileSelection = nil
            fileWorkspace.selectionModePath = nil
            fileWorkspace.previewPath = nil
            fileWorkspace.previewVisible = false
            fileWorkspace.previewThreeVersions = false
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
        .sheet(isPresented: $projectWorkspace.showSearchEverywhere) {
            SearchEverywhereView(
                roots: searchEverywhereGitRoots,
                query: $projectWorkspace.searchQuery,
                onSelect: { item in
                    projectWorkspace.showSearchEverywhere = false
                    projectWorkspace.searchQuery = ""
                    switch item.kind {
                    case .localBranch, .remoteBranch, .tag:
                        navigateLogToBranch(rootPath: item.rootPath, branch: item.revision)
                    case .commitByHash, .commitByMessage:
                        navigateLogToRevision(rootPath: item.rootPath, revision: item.revision)
                    }
                },
                onCancel: {
                    projectWorkspace.showSearchEverywhere = false
                    projectWorkspace.searchQuery = ""
                }
            )
        }
    }

    func presentVCSQuickActionsPanel() {
        let hasUnstagedChanges = repositoryStatus.entries.contains {
            $0.unstaged != .unchanged
                && $0.unstaged != .ignored
                && $0.unstaged != .conflicted
        }
        vcsQuickActionsPanel.present(
            items: vcsQuickActionItems(
                isShallowRepository: repositoryStatus.isShallowRepository,
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
        branchWorkspace.branches.contains { $0.isCurrent }
    }

    private var hasConflicts: Bool {
        repositoryStatus.entries.contains {
            $0.staged == .conflicted || $0.unstaged == .conflicted
        }
    }

    var vcsActionContext: ArborVCSActionContext {
        let hasLocalChanges = repositoryStatus.entries.contains {
            ($0.staged != .unchanged && $0.staged != .ignored)
                || ($0.unstaged != .unchanged && $0.unstaged != .ignored)
        }
        let hasUnstagedTrackedChanges = repositoryStatus.entries.contains {
            $0.unstaged != .unchanged
                && $0.unstaged != .untracked
                && $0.unstaged != .ignored
                && $0.unstaged != .conflicted
        }
        let hasStagedChanges = repositoryStatus.entries.contains {
            $0.staged != .unchanged && $0.staged != .ignored
        }
        let hasProjectCommitChanges = multiRootWorkspace.changeGroups.contains { group in
            group.entries.contains {
                $0.staged != .unchanged
                    && $0.staged != .ignored
                    && $0.staged != .conflicted
            }
        }
        let allRepositoriesHaveHeadCommit: Bool
        if multiRootWorkspace.roots.isEmpty {
            allRepositoriesHaveHeadCommit = repositoryStatus.headId != nil
        } else {
            allRepositoriesHaveHeadCommit = multiRootWorkspace.roots.allSatisfy { $0.headId != nil }
        }
        return ArborVCSActionContext(
            hasRepository: repo != nil,
            allRepositoriesHaveHeadCommit: allRepositoriesHaveHeadCommit,
            hasCurrentBranch: hasCurrentBranch,
            hasLocalChanges: hasLocalChanges,
            hasUnstagedTrackedChanges: hasUnstagedTrackedChanges,
            hasStagedChanges: hasStagedChanges,
            hasConflicts: hasConflicts,
            isShallowRepository: repositoryStatus.isShallowRepository,
            hasRemotes: !remoteWorkspace.remotes.isEmpty,
            hasFetchInProgress: isArborFetchInProgress(
                isRunning: feedbackCenter.isRunning,
                operationName: feedbackCenter.operationName
            ),
            hasBackgroundVCSOperation: isArborBackgroundVCSOperationInProgress(
                feedbackIsRunning: feedbackCenter.isRunning,
                multiRootIsRunning: multiRootWorkspace.running || multiRootWorkspace.updateDiscoveryRunning
            ),
            projectPath: projectWorkspace.path,
            hasMultipleGitRoots: multiRootWorkspace.roots.count > 1,
            hasProjectCommitChanges: hasProjectCommitChanges || hasStagedChanges,
            hasTrackedUpstream: currentSyncStatus.map {
                $0.trackingExists && !$0.upstream.isEmpty
            } ?? false,
            hasSingleGitRoot: multiRootWorkspace.roots.count == 1,
            hasRepositoryOperationInProgress: operationRecovery.operation != nil
                || multiRootWorkspace.roots.contains { $0.operation != nil },
            hasMergeInProgress: isArborMergeInProgress(
                currentOperation: operationRecovery.operation?.kind,
                roots: multiRootWorkspace.roots
            ),
            hasRebaseInProgress: isArborRebaseInProgress(
                currentOperation: operationRecovery.operation?.kind,
                roots: multiRootWorkspace.roots,
                hasMultiRootSession: rebaseWorkspace.multiRootSession != nil
            ),
            hasNormalOrDetachedRepository: hasArborNormalOrDetachedRepository(
                currentOperation: operationRecovery.operation?.kind,
                currentRootPath: repo?.workdir(),
                roots: multiRootWorkspace.roots
            ),
            selectedLocalChangePath: selectedLocalChangePath,
            selectedResolvedConflictPath: selectedWorkspacePath.flatMap {
                operationRecovery.resolvedConflictPaths.contains($0) ? $0 : nil
            },
            selectedFileAction: selectedFileActionContext
        )
    }

    var resetHeadRootOptions: [GitRootInfo] {
        if !multiRootWorkspace.roots.isEmpty {
            return multiRootWorkspace.roots.filter { $0.operation == nil }
        }
        guard let rootPath = repo?.workdir(), !rootPath.isEmpty else { return [] }
        return [GitRootInfo(
            path: rootPath,
            displayName: URL(fileURLWithPath: rootPath).lastPathComponent,
            relativePath: ".",
            isSubmodule: false,
            headBranch: branchWorkspace.branches.first(where: { $0.isCurrent })?.name,
            headId: nil,
            dirty: repositoryStatus.entries.contains {
                $0.staged != .unchanged || $0.unstaged != .unchanged
            },
            operation: operationRecovery.operation?.kind
        )]
    }

    var stashRootOptions: [GitRootInfo] {
        if !multiRootWorkspace.roots.isEmpty {
            return multiRootWorkspace.roots
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
                projectName: projectWorkspace.repository?.displayName()
                    ?? projectWorkspace.path.map { URL(fileURLWithPath: $0).lastPathComponent }
                    ?? "Arbor",
                projectPath: projectWorkspace.path,
                currentBranch: currentBranchName,
                hasRepository: repo != nil,
                isLoading: repositoryStatus.isLoading || feedbackCenter.isRunning,
                onOpenProject: showOpenPanel,
                onRefresh: refreshAll,
                onUpdate: { doPull(nil, rebase: false) },
                onCommit: {
                    projectWorkspace.toolWindowMode = .commit
                    toolWindowExpanded = true
                },
                onPush: { beginPushDialog() },
                onFetch: { doFetch(nil) },
                onHosting: { hostingWorkspace.showHostingHub = true },
                isShallowRepository: repositoryStatus.isShallowRepository,
                hasCurrentBranch: branchWorkspace.branches.contains { $0.isCurrent },
                hasConflicts: repositoryStatus.entries.contains {
                    $0.staged == .conflicted || $0.unstaged == .conflicted
                },
                onQuickAction: { action in
                    NotificationCenter.default.post(
                        name: .arborVCSAction,
                        object: action.rawValue
                    )
                },
                onSearch: {
                    projectWorkspace.searchQuery = ""
                    projectWorkspace.showSearchEverywhere = true
                },
                recentProjects: loadRecentPaths(),
                onOpenRecent: requestOpenProject,
                operationItems: gitMergeRebaseWidgetItems(
                    currentRootPath: repo?.workdir(),
                    currentOperation: operationRecovery.operation?.kind,
                    roots: multiRootWorkspace.roots
                ),
                currentOperationState: operationRecovery.operation,
                resolvedConflictPaths: operationRecovery.resolvedConflictPaths,
                onRevertResolved: revertResolvedPath,
                onOperationAction: { action, rootPath in
                    handleVCSActionRequest(
                        ArborVCSActionRequest(
                            kind: .operationRecovery,
                            projectPath: projectWorkspace.path,
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
                selectedToolWindow: projectWorkspace.toolWindowMode,
                // Rebased keeps the selected Git tool window on the left and
                // opens Git Log in the editor workspace on the right. Log is
                // therefore a second workspace, not a replacement for the
                // Commit/Stash column.
                sidebarVisible: true,
                onSelectToolWindow: { mode in
                    projectWorkspace.toolWindowMode = mode
                    toolWindowExpanded = true
                    if mode == .log {
                        projectPanelExpanded = false
                        // Git Log is an editor-like workspace, not a narrow
                        // tool-window table. Clear file context so the main
                        // workspace can own the history graph and inspector.
                        fileWorkspace.selection = nil
                        fileWorkspace.fileSelection = nil
                        fileWorkspace.selectionModePath = nil
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
                headID: repositoryStatus.headId,
                changedCount: repositoryStatus.entries.filter {
                    $0.staged != .unchanged
                        || ($0.unstaged != .unchanged && $0.unstaged != .ignored)
                }.count,
                projectPath: projectWorkspace.path,
                onBranch: { branchWorkspace.showPopover = true },
                feedbackCenter: feedbackCenter,
                syncStatus: currentSyncStatus,
                hasUnfetchedIncoming: currentBranchHasUnfetchedIncoming,
                onOperationLog: {
                    operationRecovery.viewMode = feedbackCenter.isRunning ? .tasks : .history
                    projectWorkspace.toolWindowMode = .operations
                    toolWindowExpanded = true
                },
                onCancelOperation: feedbackCenter.cancel,
                onFeedbackDetails: { projectWorkspace.feedbackDetailMessage = $0 }
            )
        }
        .frame(minWidth: 980, minHeight: 540)
        .background(Design.Colors.canvas)
        .onChange(of: projectWorkspace.toolWindowMode, initial: false) { _, mode in
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
                    onDetails: { projectWorkspace.feedbackDetailMessage = toast },
                    onDismiss: feedbackCenter.dismissToast
                )
                .padding(.trailing, 18)
                .padding(.bottom, 42)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .sheet(item: $projectWorkspace.feedbackDetailMessage) { message in
            FeedbackDetailView(
                message: message,
                onDismiss: { projectWorkspace.feedbackDetailMessage = nil },
                onOpenSSHSettings: {
                    projectWorkspace.feedbackDetailMessage = nil
                    loadGitSSHSettings()
                }
            )
        }
        .alert("GitHub authentication failed", isPresented: $hostingWorkspace.showHostingAuthPrompt) {
            Button("Configure GitHub token") { hostingWorkspace.showHostingSettings = true }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Configure a GitHub token in Settings, then retry the git operation.")
        }
        .sheet(isPresented: $hostingWorkspace.showHostingSettings) {
            if let hostingRepository {
                HostingSettingsView(repository: hostingRepository)
            } else {
                Text("No supported hosting remote is configured.")
                    .padding(24)
            }
        }
        .sheet(isPresented: $hostingWorkspace.showHostingHub) {
            HostingHubView(
                remoteURL: remoteWorkspace.remotes.first(where: { HostingProvider.parse(remoteURL: $0.url) != nil })?.url,
                showSettings: $hostingWorkspace.showHostingSettings,
                onCheckoutIncomingBranch: { detail in
                    guard let projectPath = projectWorkspace.path,
                          let branch = detail.pullRequest.headBranch,
                          !branch.isEmpty,
                          let remote = remoteWorkspace.remotes.first(where: { HostingProvider.parse(remoteURL: $0.url) != nil }) else {
                        feedbackCenter.error(
                            "Checkout incoming branch failed",
                            detail: "The hosting change request is not connected to an available Git root or remote."
                        )
                        return
                    }
                    hostingWorkspace.showHostingHub = false
                    checkoutBranchInRoot(
                        rootPath: projectPath,
                        reference: "\(remote.name)/\(branch)",
                        isRemote: true
                    )
                },
                onShowInGitLog: { detail in
                    guard let projectPath = projectWorkspace.path,
                          let revision = detail.headRevision,
                          !revision.isEmpty else {
                        feedbackCenter.error(
                            "Open in Git Log failed",
                            detail: "The hosting provider did not return a head revision."
                        )
                        return
                    }
                    hostingWorkspace.showHostingHub = false
                    projectWorkspace.toolWindowMode = .log
                    toolWindowExpanded = true
                    navigateLogToRevision(rootPath: projectPath, revision: revision)
                }
            )
            .frame(minWidth: 980, minHeight: 620)
        }
        .sheet(isPresented: $hostingWorkspace.showReviewComment) {
            if let commit = hostingWorkspace.reviewCommentCommit,
               let repository = hostingWorkspace.reviewCommentRepository ?? hostingRepository {
                ReviewCommentSheet(
                    repository: repository,
                    commitID: commit.id,
                    client: HostingClientFactory.make(for: repository)
                )
        }
    }
        .sheet(item: $pushWorkspace.addCommitsToRemoteBranchContext) { context in
            RebasedRemoteBranchSelectionDialog(
                commits: context.commits,
                remoteBranches: context.remoteBranches,
                onCancel: { pushWorkspace.addCommitsToRemoteBranchContext = nil },
                onSelect: { remoteBranch in
                    pushWorkspace.addCommitsToRemoteBranchContext = nil
                    prepareAddCommitsToRemoteBranch(remoteBranch, commits: context.commits)
                }
            )
        }
        .sheet(isPresented: $pushWorkspace.showMultiRootPushOptions) {
            MultiRootPushOptionsDialog(
                snapshots: multiRootWorkspace.branchSnapshots.filter { snapshot in
                    guard let selected = pushWorkspace.multiRootPushOptionsRootPaths else { return true }
                    return selected.contains(snapshot.rootPath)
                },
                onCancel: {
                    pushWorkspace.showMultiRootPushOptions = false
                    pushWorkspace.multiRootPushOptionsRootPaths = nil
                    pushWorkspace.multiRootPushOptionsFromCommit = false
                },
                onPush: { targets, tagMode, skipHooks, force, forceWithLease in
                    let rootPaths = pushWorkspace.multiRootPushOptionsRootPaths
                    let fromCommit = pushWorkspace.multiRootPushOptionsFromCommit
                    pushWorkspace.showMultiRootPushOptions = false
                    pushWorkspace.multiRootPushOptionsRootPaths = nil
                    pushWorkspace.multiRootPushOptionsFromCommit = false
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
        .sheet(isPresented: $pushWorkspace.showDialog) {
            PushDialogView(
                remotes: remoteWorkspace.remotes,
                branches: branchWorkspace.branches,
                commits: logList.entries,
                mode: pushWorkspace.dialogMode,
                defaultRemote: pushWorkspace.dialogRemote,
                defaultBranch: pushWorkspace.dialogBranch
                    ?? branchWorkspace.branches.first(where: { $0.isCurrent })?.name,
                defaultSourceRevision: pushWorkspace.dialogSourceRevision,
                currentHasUpstream: branchWorkspace.syncStatuses.first(where: {
                    $0.branch == (pushWorkspace.dialogSourceRevision ?? currentBranchName)
                })?.trackingExists ?? false,
                protectedBranchPatterns: effectiveProtectedBranchPatterns,
                defaultRefspec: pushWorkspace.dialogRefspec,
                defaultPushTagMode: GitPushTagSettings.projectTagMode(for: projectWorkspace.path),
                defaultRunHooks: true,
                onCancel: {
                    pushWorkspace.showDialog = false
                    pushWorkspace.dialogRefspec = nil
                    pushWorkspace.dialogRemote = nil
                    pushWorkspace.dialogBranch = nil
                    pushWorkspace.dialogSourceRevision = nil
                },
                onPush: { remote, branch, force, setUpstream, forceWithLease, refspec, tagMode, skipHooks in
                    pushWorkspace.showDialog = false
                    pushWorkspace.dialogRefspec = nil
                    pushWorkspace.dialogRemote = nil
                    pushWorkspace.dialogBranch = nil
                    pushWorkspace.dialogSourceRevision = nil
                    if pushWorkspace.dialogMode == .commitAndPush {
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
                    pushWorkspace.showDialog = false
                    beginConfigureRemotes()
                },
                onConfigureSSH: {
                    pushWorkspace.showDialog = false
                    loadGitSSHSettings()
                },
                repo: repo
            )
        }
        .sheet(item: $pushWorkspace.multiRootPushContext) { context in
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
                    pushWorkspace.multiRootPushContext = nil
                },
                onPush: { remote, branch, force, setUpstream, forceWithLease, refspec, tagMode, skipHooks in
                    pushWorkspace.multiRootPushContext = nil
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
                    pushWorkspace.multiRootPushContext = nil
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
        .sheet(item: $remoteWorkspace.multiRootRemoteConfigContext) { context in
            RemoteConfigDialogView(
                remotes: context.remotes,
                name: $remoteWorkspace.multiRootRemoteName,
                url: $remoteWorkspace.multiRootRemoteURL,
                pushUrl: $remoteWorkspace.multiRootRemotePushURL,
                fetchRefspec: $remoteWorkspace.multiRootRemoteFetchRefspec,
                pushRefspec: $remoteWorkspace.multiRootRemotePushRefspec,
                initialSelectedName: remoteWorkspace.multiRootRemoteName,
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
                    remoteWorkspace.multiRootRemoteConfigContext = nil
                },
                onRefresh: {
                    loadMultiRootRemoteConfig(rootPath: context.rootPath)
                }
            )
        }
        .sheet(isPresented: $commitWorkspace.showBeforeCommitSettings) {
            beforeCommitSettingsSheet
        }
        .sheet(isPresented: $gitSettings.showProjectGitSettings) {
            if let projectPath = projectWorkspace.path {
                ProjectGitIncomingChangesSettingsView(
                    projectPath: projectPath,
                    rootPaths: GitExecutableSettings.registeredRoots(
                        projectPath: projectPath,
                        repositoryRoot: repo?.workdir(),
                        discoveredRoots: multiRootWorkspace.roots.map(\.path)
                    ),
                    onSaved: {
                        if let repo {
                            _ = try? repo.setGitExecutableOverride(
                                path: GitExecutableSettings.projectOverride(for: projectPath)
                            )
                        }
                        gitSettings.projectIncomingCheckStrategyRaw = GitIncomingCheckStrategySettings.projectRawValue(
                            for: projectPath
                        )
                        gitSettings.projectFetchTagsMode = GitFetchTagsSettings.mode(for: projectPath)
                        gitSettings.projectUpdateMethod = GitUpdateMethodSettings.method(for: projectPath)
                    }
                )
            } else {
                Text("Open a Git project before changing project Git settings.")
                    .padding(24)
            }
        }
        .sheet(isPresented: $gitSettings.showUpdateProjectOptions) {
            if let projectPath = projectWorkspace.path {
                UpdateProjectOptionsDialogView(
                    projectPath: projectPath,
                    rootCount: max(1, multiRootWorkspace.roots.count),
                    initialUpdateMethod: gitSettings.projectUpdateMethod,
                    showsResetAction: multiRootWorkspace.roots.count == 1,
                    onUpdate: { method, shouldShowNextTime in
                        gitSettings.projectUpdateMethod = method
                        GitUpdateMethodSettings.save(method, for: projectPath)
                        GitUpdateOptionsDialogSettings.saveShouldShow(
                            shouldShowNextTime,
                            for: projectPath
                        )
                        gitSettings.showUpdateProjectOptions = false
                        executeMultiRootUpdate(rebase: method == .rebase)
                    },
                    onResetToRemote: {
                        gitSettings.showUpdateProjectOptions = false
                        DispatchQueue.main.async {
                            resetCurrentBranchToRemote()
                        }
                    },
                    onCancel: {
                        gitSettings.showUpdateProjectOptions = false
                    }
                )
            } else {
                Text("Open a Git project before updating it.")
                    .padding(24)
            }
        }
        .sheet(isPresented: $gitSettings.showIdentitySettings) {
            GitIdentitySettingsView(
                name: $gitSettings.identityName,
                email: $gitSettings.identityEmail,
                setNameEmailGlobally: $gitSettings.identitySetNameEmailGlobally,
                signingKey: $gitSettings.identitySigningKey,
                signingFormat: $gitSettings.identitySigningFormat,
                signCommits: $gitSettings.identitySignCommits,
                authorName: $gitSettings.identityAuthorName,
                authorEmail: $gitSettings.identityAuthorEmail,
                committerName: $gitSettings.identityCommitterName,
                committerEmail: $gitSettings.identityCommitterEmail,
                signOff: $gitSettings.identitySignOff,
                coAuthors: $gitSettings.identityCoAuthors,
                recentAuthors: gitSettings.identityRecentAuthors,
                onSelectRecentAuthor: { author in
                    guard let parsed = GitCommitAuthorHistorySettings.parse(author) else { return }
                    gitSettings.identityAuthorName = parsed.name
                    gitSettings.identityAuthorEmail = parsed.email
                },
                onSave: { setGitIdentity(); gitSettings.showIdentitySettings = false },
                onCancel: {
                    gitSettings.pendingIdentityCommitRetry = false
                    gitSettings.showIdentitySettings = false
                },
                onGpgAgent: {
                    gitSettings.showIdentitySettings = false
                    DispatchQueue.main.async { gitSettings.showGpgAgentSettings = true }
                }
            )
        }
        .sheet(isPresented: $gitSettings.showGpgAgentSettings) {
            GpgAgentSettingsView()
        }
        .onChange(of: gitSettings.showIdentitySettings) { _, isPresented in
            if isPresented {
                gitSettings.identitySetNameEmailGlobally = GitIdentityScopeSettings.setNameEmailGlobally(
                    for: projectWorkspace.path
                )
                gitSettings.identityRecentAuthors = GitCommitAuthorHistorySettings.authors(for: projectWorkspace.path)
            }
            if !isPresented && commitWorkspace.showMultiRootDialog {
                syncMultiRootCommitIdentityDraftFromSettings()
            }
        }
        .sheet(isPresented: $gitSettings.showGitSSHSettings) {
            GitSSHSettingsView(
                command: $gitSettings.gitSSHCommand,
                knownHostsFile: $gitSettings.gitSSHKnownHostsFile,
                identityFile: $gitSettings.gitSSHIdentityFile,
                hostKeyPolicy: $gitSettings.gitSSHHostKeyPolicy,
                authMethod: $gitSettings.gitSSHAuthMethod,
                credentialHelperConfig: $gitSettings.gitCredentialHelperConfig,
                credentialHelpers: gitSettings.gitCredentialHelpers,
                onRefreshCredentialHelpers: loadGitCredentialHelpers,
                sshAgentDiagnostics: gitSettings.gitSSHAgentDiagnostics,
                onRefreshSSHAgentDiagnostics: loadGitSSHAgentDiagnostics,
                lastSuccessfulAuthentications: gitSettings.lastSuccessfulSSHAuthentications,
                onClearLastSuccessfulAuthentications: {
                    credentialAuth.clearSSHAuthenticationRecords()
                    gitSettings.lastSuccessfulSSHAuthentications = []
                },
                onSave: { saveGitSSHSettings(); gitSettings.showGitSSHSettings = false },
                onCancel: { gitSettings.showGitSSHSettings = false }
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
        .sheet(isPresented: $branchWorkspace.showNewDialog) {
            RebasedNewBranchDialog(
                title: branchWorkspace.newDialogTitle,
                name: $branchWorkspace.newName,
                baseRevision: $branchWorkspace.newBase,
                checkout: $branchWorkspace.newCheckout,
                resetExisting: $branchWorkspace.newResetExisting,
                validateName: { value in
                    guard let branchRepo = branchWorkspace.newRepositoryOverride ?? repo else { return nil }
                    do {
                        try branchRepo.validateBranchName(name: value)
                        return nil
                    } catch {
                        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if branchWorkspace.newResetExisting,
                           branchWorkspace.newDialogBranches.contains(where: { $0.name == normalized }) {
                            return nil
                        }
                        return errorMessage(error)
                    }
                },
                branches: branchWorkspace.newDialogBranches,
                onCreate: {
                    let base = branchWorkspace.newBase.trimmingCharacters(in: .whitespacesAndNewlines)
                    if branchWorkspace.newAfterCreateRebase {
                        branchCreateAndRebase(
                            at: base.isEmpty ? nil : base,
                            reset: branchWorkspace.newResetExisting,
                            repository: branchWorkspace.newRepositoryOverride
                        )
                    } else {
                        branchCreate(
                            at: base.isEmpty ? nil : base,
                            checkout: branchWorkspace.newCheckout,
                            reset: branchWorkspace.newResetExisting,
                            repository: branchWorkspace.newRepositoryOverride
                        )
                    }
                    dismissNewBranchDialog()
                },
                onCancel: dismissNewBranchDialog
            )
        }
        .sheet(isPresented: $worktreeWorkspace.showCreateDialog) {
            RebasedNewWorktreeDialog(
                rootPath: worktreeWorkspace.rootPath ?? repo?.workdir(),
                reference: worktreeWorkspace.reference,
                isTag: worktreeWorkspace.isTag,
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
                path: $worktreeWorkspace.path,
                branch: $worktreeWorkspace.branch,
                onCreate: { path, branch in
                    createWorktree(
                        path: path,
                        branch: branch,
                        revision: worktreeWorkspace.reference,
                        rootPath: worktreeWorkspace.rootPath
                    )
                    dismissNewWorktreeDialog()
                },
                onCancel: dismissNewWorktreeDialog
            )
        }
        .sheet(isPresented: $branchWorkspace.showMultiRootNewDialog) {
            RebasedMultiRootNewBranchDialog(
                name: $branchWorkspace.multiRootNewName,
                baseRevision: $branchWorkspace.multiRootNewBase,
                checkout: $branchWorkspace.multiRootNewCheckout,
                resetExisting: $branchWorkspace.multiRootNewResetExisting,
                selectedRootPaths: $branchWorkspace.multiRootNewSelectedRootPaths,
                roots: multiRootWorkspace.roots,
                existingBranchNames: branchWorkspace.multiRootExistingNames,
                validateName: { value in
                    let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !candidate.isEmpty else { return nil }
                    let selectedPaths = branchWorkspace.multiRootNewSelectedRootPaths.isEmpty
                        ? multiRootWorkspace.roots.map(\.path)
                        : Array(branchWorkspace.multiRootNewSelectedRootPaths)
                    for rootPath in selectedPaths {
                        let exists = branchWorkspace.multiRootExistingNames[rootPath]?.contains(candidate) == true
                        if branchWorkspace.multiRootNewResetExisting && exists {
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
                        name: branchWorkspace.multiRootNewName,
                        baseRevision: branchWorkspace.multiRootNewBase,
                        checkout: branchWorkspace.multiRootNewCheckout,
                        reset: branchWorkspace.multiRootNewResetExisting,
                        selectedRootPaths: branchWorkspace.multiRootNewSelectedRootPaths
                    )
                    dismissMultiRootNewBranchDialog()
                },
                onCancel: dismissMultiRootNewBranchDialog
            )
        }
        .sheet(isPresented: $branchWorkspace.showMultiRootRenameDialog) {
            RebasedMultiRootRenameBranchDialog(
                oldName: branchWorkspace.multiRootRenameOldName,
                newName: $branchWorkspace.multiRootRenameNewName,
                unsetUpstream: $branchWorkspace.multiRootRenameUnsetUpstream,
                selectedRootPaths: $branchWorkspace.multiRootRenameSelectedRootPaths,
                snapshots: multiRootWorkspace.branchSnapshots,
                validateName: validateMultiRootRenameName,
                onRename: {
                    renameMultiRootBranch(
                        oldName: branchWorkspace.multiRootRenameOldName,
                        newName: branchWorkspace.multiRootRenameNewName,
                        unsetUpstream: branchWorkspace.multiRootRenameUnsetUpstream,
                        selectedRootPaths: branchWorkspace.multiRootRenameSelectedRootPaths
                    )
                },
                onCancel: dismissMultiRootRenameBranchDialog
            )
        }
        .sheet(isPresented: $branchWorkspace.showRenameDialog) {
            RebasedSingleRootRenameBranchDialog(
                oldName: branchWorkspace.renameOldName,
                newName: $branchWorkspace.renameNewName,
                unsetUpstream: $branchWorkspace.renameUnsetUpstream,
                hasUpstream: branchWorkspace.renameHasUpstream,
                validateName: { value in
                    validateSingleRootRenameName(
                        rootPath: branchWorkspace.renameRootPath,
                        oldName: branchWorkspace.renameOldName,
                        value: value
                    )
                },
                onRename: {
                    renameBranchInRoot(
                        rootPath: branchWorkspace.renameRootPath,
                        oldName: branchWorkspace.renameOldName,
                        newName: branchWorkspace.renameNewName,
                        unsetUpstream: branchWorkspace.renameUnsetUpstream
                    )
                },
                onCancel: dismissSingleRootRenameBranchDialog
            )
        }
        .sheet(isPresented: $branchWorkspace.showMultiRootDeleteDialog) {
            RebasedMultiRootDeleteBranchDialog(
                branchName: branchWorkspace.multiRootDeleteName,
                selectedRootPaths: $branchWorkspace.multiRootDeleteSelectedRootPaths,
                snapshots: multiRootWorkspace.branchSnapshots,
                onDelete: {
                    deleteMultiRootBranch(
                        name: branchWorkspace.multiRootDeleteName,
                        selectedRootPaths: branchWorkspace.multiRootDeleteSelectedRootPaths
                    )
                },
                onCancel: dismissMultiRootDeleteBranchDialog
            )
        }
        .sheet(isPresented: $tagWorkspace.showMultiRootDeleteDialog) {
            RebasedMultiRootDeleteTagDialog(
                tagName: tagWorkspace.multiRootDeleteName,
                selectedRootPaths: $tagWorkspace.multiRootDeleteSelectedRootPaths,
                snapshots: multiRootWorkspace.branchSnapshots,
                onDelete: {
                    deleteMultiRootTag(
                        name: tagWorkspace.multiRootDeleteName,
                        selectedRootPaths: tagWorkspace.multiRootDeleteSelectedRootPaths
                    )
                },
                onCancel: dismissMultiRootDeleteTagDialog
            )
        }
        .sheet(isPresented: $branchWorkspace.showMultiRootRemoteDeleteDialog) {
            RebasedMultiRootRemoteDeleteBranchDialog(
                remoteBranch: branchWorkspace.multiRootRemoteDeleteName,
                selectedRootPaths: $branchWorkspace.multiRootRemoteDeleteSelectedRootPaths,
                deleteTracking: $branchWorkspace.multiRootRemoteDeleteTracking,
                snapshots: multiRootWorkspace.branchSnapshots,
                onDelete: {
                    deleteMultiRootRemoteBranch(
                        remoteBranch: branchWorkspace.multiRootRemoteDeleteName,
                        deleteTracking: branchWorkspace.multiRootRemoteDeleteTracking,
                        selectedRootPaths: branchWorkspace.multiRootRemoteDeleteSelectedRootPaths
                    )
                },
                onCancel: dismissMultiRootRemoteDeleteDialog
            )
        }
        .sheet(isPresented: $mergeWorkspace.showActionDialog) {
            RebasedMergeDialog(
                branch: $mergeWorkspace.branch,
                strategy: Binding(
                    get: { MergeStrategyChoice(rawValue: mergeWorkspace.strategyRaw) ?? .automatic },
                    set: { mergeWorkspace.strategyRaw = $0.rawValue }
                ),
                commitMessage: $mergeWorkspace.commitMessage,
                useCustomCommitMessage: $mergeWorkspace.useCustomCommitMessage,
                noCommit: $mergeWorkspace.noCommit,
                noVerify: $mergeWorkspace.noVerify,
                allowUnrelatedHistories: $mergeWorkspace.allowUnrelatedHistories,
                branches: branchWorkspace.branches,
                mergedBranches: mergeWorkspace.mergedBranches,
                onMerge: {
                    mergeWorkspace.showActionDialog = false
                    doMerge()
                },
                onCancel: { mergeWorkspace.showActionDialog = false }
            )
        }
        .sheet(isPresented: $pullWorkspace.showDialog) {
            PullDialogView(
                snapshots: pullWorkspace.snapshots,
                defaultRootPath: repo?.workdir() ?? multiRootWorkspace.roots.first?.path,
                defaultRebase: pullWorkspace.rebase,
                initialOptions: GitPullDialogSettingsStore.load(for: projectWorkspace.path).options,
                blockedRootPaths: Set(
                    multiRootWorkspace.roots
                        .filter { $0.operation != nil }
                        .map { canonicalExternalLogPath($0.path) }
                ).union(
                    operationRecovery.operation != nil
                        ? Set([repo?.workdir()].compactMap { $0 }.map(canonicalExternalLogPath))
                        : []
                ),
                fetchInProgress: isArborFetchInProgress(
                    isRunning: feedbackCenter.isRunning,
                    operationName: feedbackCenter.operationName
                ),
                onCancel: {
                    pullWorkspace.showDialog = false
                    pullWorkspace.snapshots = []
                },
                onPull: { selection in
                    pullWorkspace.showDialog = false
                    pullWorkspace.snapshots = []
                    savePullDialogSettings(selection.options)
                    executePullDialogSelection(selection)
                },
                onFetch: fetchPullDialogRemote
            )
        }
        .sheet(isPresented: $rebaseWorkspace.showActionDialog) {
            RebasedRebaseDialog(
                onto: $rebaseWorkspace.onto,
                branch: $rebaseWorkspace.branch,
                repositoryPath: $rebaseWorkspace.rootPath,
                interactive: $rebaseWorkspace.interactive,
                preserveMerges: $rebaseWorkspace.preserveMerges,
                autoSquash: $rebaseWorkspace.autoSquash,
                keepEmpty: $rebaseWorkspace.keepEmpty,
                updateRefs: $rebaseWorkspace.updateRefs,
                root: $rebaseWorkspace.root,
                applyToAllRepositories: $rebaseWorkspace.applyToAllRoots,
                rangeCount: rebaseWorkspace.range.count,
                repositories: rebaseRepositories,
                branches: rebaseBranchOptions,
                onLoadRange: loadRebaseRange,
                onRangeInputsChanged: invalidateLoadedRebaseRange,
                onRepositoryChanged: selectRebaseRepository,
                onStart: {
                    rebaseWorkspace.showActionDialog = false
                    saveRebaseDialogSettings()
                    if rebaseWorkspace.applyToAllRoots {
                        if rebaseWorkspace.interactive {
                            prepareMultiRootRebaseEditor()
                        } else {
                            doMultiRootRebase(drafts: nil)
                        }
                    } else {
                        doRebase()
                    }
                },
                onCancel: { rebaseWorkspace.showActionDialog = false }
            )
        }
        .sheet(isPresented: $rebaseWorkspace.showMultiRootEditor) {
            MultiRootRebaseTodoEditorView(
                onto: rebaseWorkspace.onto,
                branch: rebaseWorkspace.branch,
                drafts: $rebaseWorkspace.multiRootDrafts,
                preserveMerges: rebaseWorkspace.preserveMerges,
                autoSquash: rebaseWorkspace.autoSquash,
                keepEmpty: rebaseWorkspace.keepEmpty,
                updateRefs: rebaseWorkspace.updateRefs,
                root: rebaseWorkspace.root,
                onStart: {
                    rebaseWorkspace.showMultiRootEditor = false
                    doMultiRootRebase(drafts: rebaseWorkspace.multiRootDrafts)
                },
                onCancel: {
                    rebaseWorkspace.showMultiRootEditor = false
                    rebaseWorkspace.multiRootDrafts = []
                },
                onOpenRawTodo: prepareMultiRootRawTodoEditor
            )
        }
        .sheet(item: $rebaseWorkspace.multiRootRawTodoContext) { context in
            RawRebaseTodoEditorView(
                onto: context.onto,
                text: $rebaseWorkspace.multiRootRawTodoText,
                preserveMerges: context.preserveMerges,
                root: context.root,
                onStart: { finishMultiRootRawTodoEditor(context) },
                onCancel: {
                    rebaseWorkspace.multiRootRawTodoContext = nil
                    rebaseWorkspace.multiRootRawTodoText = ""
                }
            )
        }
        .sheet(item: $rebaseWorkspace.multiRootRollbackContext) { context in
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
                    rebaseWorkspace.multiRootRollbackContext = nil
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
                roots: multiRootWorkspace.roots,
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
            if let stash = stashUI.stashes.first(where: { $0.id == stashUI.unstashAsStashID }) {
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
                entries: repositoryStatus.entries.filter {
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
        .sheet(isPresented: $cloneWorkspace.showDialog) {
            RebasedCloneDialog(
                url: $cloneWorkspace.url,
                parentDirectory: $cloneWorkspace.parentDirectory,
                directoryName: $cloneWorkspace.directoryName,
                recursiveSubmodules: $cloneRecursiveSubmodules,
                shallowClone: $cloneWorkspace.shallow,
                depth: $cloneWorkspace.depth,
                isRunning: cloneWorkspace.inProgress,
                isCancelling: cloneWorkspace.cancelling,
                onChooseParent: chooseCloneParentDirectory,
                onClone: cloneRepositoryFromDialog,
                onCancel: cancelCloneRepositoryFromDialog
            )
            .interactiveDismissDisabled(cloneWorkspace.inProgress)
        }
        .sheet(isPresented: $tagWorkspace.showCreateDialog) {
            RebasedTagDialog(
                name: $tagWorkspace.name,
                revision: $tagWorkspace.at,
                message: $tagWorkspace.message,
                signKey: $tagWorkspace.signKey,
                annotated: $tagWorkspace.annotated,
                force: $tagWorkspace.force,
                onCreate: {
                    tagWorkspace.showCreateDialog = false
                    createTag()
                },
                onCancel: {
                    tagWorkspace.showCreateDialog = false
                    tagWorkspace.repositoryOverride = nil
                    tagWorkspace.force = false
                }
            )
        }
        .sheet(isPresented: $shelfWorkspace.showCreateDialog) {
            RebasedShelveDialog(
                name: $shelfWorkspace.name,
                repo: repo,
                entries: repositoryStatus.entries,
                onShelve: { paths, includeUntracked, includeIgnored in
                    shelfWorkspace.showCreateDialog = false
                    doShelve(
                        paths: paths,
                        includeUntracked: includeUntracked,
                        includeIgnored: includeIgnored
                    )
                },
                onCancel: { shelfWorkspace.showCreateDialog = false }
            )
        }
        .sheet(isPresented: $shelfWorkspace.showLocationDialog) {
            RebasedShelfLocationDialog(
                location: $shelfWorkspace.locationValue,
                migrateExisting: $shelfWorkspace.locationMigrateExisting,
                currentLocation: shelfWorkspace.locationCurrent,
                onSave: {
                    shelfWorkspace.showLocationDialog = false
                    setShelfLocation(
                        shelfWorkspace.locationValue,
                        migrateExisting: shelfWorkspace.locationMigrateExisting,
                        rootPath: activeShelfRootPath
                    )
                },
                onCancel: { shelfWorkspace.showLocationDialog = false }
            )
        }
        .sheet(item: $fileWorkspace.pendingApplyPatch) { request in
            if let repo {
                RebasedUnshelveDialog(
                    name: request.fileName,
                    paths: request.paths,
                    initialPaths: request.paths,
                    changeLists: repositoryStatus.changeLists,
                    repo: repo,
                    patchText: request.patch,
                    removeAppliedFilesFromShelf: .constant(false),
                    onUnshelve: { _, _, _, _, _, _, _ in },
                    onApplyPatch: { paths, selections, targetName, basePath, pathStrip in
                        fileWorkspace.pendingApplyPatch = nil
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
                    onCancel: { fileWorkspace.pendingApplyPatch = nil }
                )
            }
        }
        .sheet(item: $fileWorkspace.patchExportRequest) { request in
            RebasedPatchExportDialog(
                request: request,
                onExport: { options in
                    fileWorkspace.patchExportRequest = nil
                    DispatchQueue.main.async {
                        request.onExport(options)
                    }
                },
                onCancel: { fileWorkspace.patchExportRequest = nil }
            )
        }
        .sheet(isPresented: $resetWorkspace.showHeadDialog) {
            RebasedHeadResetDialog(
                roots: resetHeadRootOptions,
                selectedRootPath: $resetWorkspace.headRootPath,
                target: $resetWorkspace.headTarget,
                mode: $resetWorkspace.headMode,
                onValidate: { target, rootPath in
                    validateResetHeadTarget(target, rootPath: rootPath)
                },
                onReset: {
                    resetWorkspace.showHeadDialog = false
                    resetHead(
                        rootPath: resetWorkspace.headRootPath,
                        target: resetWorkspace.headTarget,
                        mode: resetWorkspace.headMode
                    )
                },
                onCancel: { resetWorkspace.showHeadDialog = false }
            )
        }
        .sheet(isPresented: $resetWorkspace.showDialog) {
            if let resetTargetCommit = resetWorkspace.targetCommit {
                RebasedResetDialog(
                    commit: resetTargetCommit,
                    targetCommits: resetWorkspace.targetCommits,
                    mode: $resetWorkspace.mode,
                    onReset: {
                        resetWorkspace.showDialog = false
                        if resetWorkspace.targetCommits.count > 1 {
                            resetCommitsAcrossRoots(resetWorkspace.targetCommits, mode: resetWorkspace.mode)
                        } else {
                            resetCommit(resetTargetCommit, mode: resetWorkspace.mode)
                        }
                    },
                    onCancel: { resetWorkspace.showDialog = false },
                    multiRootResetAvailable: resetWorkspace.targetCommits.count > 1,
                    onResetAcrossRoots: { mode in
                        resetWorkspace.showDialog = false
                        resetCommitsAcrossRoots(resetWorkspace.targetCommits, mode: mode)
                    }
                )
            }
        }
        .sheet(item: $commitWorkspace.uncommitRequest) { request in
            RebasedUncommitDialog(
                request: request,
                onUncommit: { targetName in
                    commitWorkspace.uncommitRequest = nil
                    performUncommit(request, targetName: targetName)
                },
                onCancel: { commitWorkspace.uncommitRequest = nil }
            )
        }
        .sheet(item: $operationRecovery.smartOperationRequest) { request in
            RebasedSmartOperationDialog(
                request: request,
                onSmart: {
                    operationRecovery.smartOperationRequest = nil
                    request.onSmart()
                },
                onForce: {
                    operationRecovery.smartOperationRequest = nil
                    request.onForce?()
                },
                onCancel: {
                    operationRecovery.smartOperationRequest = nil
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
            commands: $commitWorkspace.beforeCommitCommands,
            onIdentity: { gitSettings.showIdentitySettings = true }
        )
    }

    private func selectChangedFile(_ path: String) {
        fileWorkspace.previewPath = path
        fileWorkspace.previewComparisonMode = nil
        fileWorkspace.previewThreeVersions = false
        fileWorkspace.selectionModePath = nil
        fileWorkspace.selection = nil
        fileWorkspace.fileSelection = nil
        // GitStagePanel separates selection from the Show Diff Preview action.
        // Changing a row updates an already-open preview, but does not
        // silently reopen a preview the user explicitly hid.
    }

    private func previewChangedFile(_ path: String) {
        // GitStagePanel reserves double-click/Enter for Open Source. Arbor has
        // no IDE editor. When Log owns the editor workspace, preserve that
        // workspace and keep the source action inside the Commit/Stash side
        // instead of replacing the selected history with a file viewer.
        if projectWorkspace.toolWindowMode == .log {
            fileWorkspace.previewPath = path
            fileWorkspace.previewComparisonMode = nil
            fileWorkspace.previewThreeVersions = false
            fileWorkspace.version = .local
            fileWorkspace.selectionModePath = nil
            fileWorkspace.selection = nil
            fileWorkspace.fileSelection = nil
            fileWorkspace.previewVisible = true
            feedbackCenter.warning(
                "Open Source is not an IDE editor",
                detail: "The Commit/Stash preview remains open so Git Log is not replaced.",
                nextStep: "Use the single-click diff or open the file from Project."
            )
            return
        }
        fileWorkspace.previewPath = nil
        fileWorkspace.previewComparisonMode = nil
        fileWorkspace.previewThreeVersions = false
        fileWorkspace.selection = nil
        fileWorkspace.selectionModePath = nil
        fileWorkspace.fileSelection = path
        fileWorkspace.version = .local
        fileWorkspace.previewVisible = false
    }

    private func previewFirstChangedFile() {
        if fileWorkspace.previewVisible {
            fileWorkspace.previewVisible = false
            fileWorkspace.previewThreeVersions = false
            return
        }
        fileWorkspace.previewPath = repositoryStatus.entries.first(where: {
            $0.staged != .unchanged
                || ($0.unstaged != .unchanged && $0.unstaged != .ignored)
        })?.path
        fileWorkspace.previewComparisonMode = nil
        fileWorkspace.previewThreeVersions = false
        fileWorkspace.previewVisible = true
    }

    private func showCommitDiffPreview(_ path: String) {
        // This is the stage-tree equivalent of Git.Stage.Tree.Menu's
        // Diff.ShowDiff action. It deliberately does not enter the editor
        // file-selection path: when Log is active, the right workspace must
        // remain the graph/details inspector and the diff belongs beside the
        // Commit/Stash tree on the left.
        fileWorkspace.previewPath = path
        fileWorkspace.previewComparisonMode = nil
        fileWorkspace.previewMode = .unstaged
        fileWorkspace.previewThreeVersions = false
        fileWorkspace.selectionModePath = nil
        fileWorkspace.selection = nil
        fileWorkspace.fileSelection = nil
        fileWorkspace.previewVisible = true
    }

    private func showCommitStagedDiffPreview(_ path: String) {
        fileWorkspace.previewPath = path
        fileWorkspace.previewComparisonMode = nil
        fileWorkspace.previewMode = .staged
        fileWorkspace.previewThreeVersions = false
        fileWorkspace.selectionModePath = nil
        fileWorkspace.selection = nil
        fileWorkspace.fileSelection = nil
        fileWorkspace.previewVisible = true
    }

    private func showCommitLocalStagedDiffPreview(_ path: String) {
        fileWorkspace.previewPath = path
        fileWorkspace.previewComparisonMode = stagingComparisonDiffMode(for: .localWithStaged)
        fileWorkspace.previewMode = .unstaged
        fileWorkspace.previewThreeVersions = false
        fileWorkspace.selectionModePath = nil
        fileWorkspace.selection = nil
        fileWorkspace.fileSelection = nil
        fileWorkspace.previewVisible = true
    }

    private func showCommitThreeVersionsPreview(_ path: String) {
        fileWorkspace.previewPath = path
        fileWorkspace.previewComparisonMode = nil
        fileWorkspace.previewThreeVersions = true
        fileWorkspace.selectionModePath = nil
        fileWorkspace.selection = nil
        fileWorkspace.fileSelection = nil
        fileWorkspace.previewVisible = true
    }

    private func showCommitLocalVersion(_ path: String) {
        showCommitFileVersion(path, version: .local)
    }

    private func showCommitStagedVersion(_ path: String) {
        showCommitFileVersion(path, version: .staged)
    }

    private func showCommitFileVersion(_ path: String, version: FileContentVersion) {
        fileWorkspace.previewPath = nil
        fileWorkspace.previewComparisonMode = nil
        fileWorkspace.previewVisible = false
        fileWorkspace.previewThreeVersions = false
        fileWorkspace.treeDiffRequest = nil
        fileWorkspace.selection = nil
        fileWorkspace.selectionModePath = nil
        fileWorkspace.version = version
        fileWorkspace.fileSelection = path
    }

    func annotateProjectFile(_ path: String) {
        guard let normalizedPath = normalizedRepositoryRelativePath(path) else { return }
        projectWorkspace.toolWindowMode = .commit
        fileWorkspace.treeDiffRequest = nil
        fileWorkspace.selection = nil
        fileWorkspace.selectionModePath = nil
        logSelectionState.selection = nil
        fileWorkspace.version = .local
        fileWorkspace.fileSelection = normalizedPath
        fileWorkspace.blameRequestID &+= 1
    }

    func openFirstConflictFromAction() {
        guard let conflictedPath = firstConflictedPath(in: repositoryStatus.entries) else { return }
        openConflictFromStage(conflictedPath)
    }

    private func openConflictFromStage(_ path: String) {
        // The resolver is a sheet over the current workspace. In Log mode the
        // right editor must remain the Log graph, so pass the initial file via
        // a dedicated dialog context instead of the global editor selection.
        operationRecovery.initialPath = path
        if projectWorkspace.toolWindowMode != .log { fileWorkspace.selection = path }
        fileWorkspace.fileSelection = nil
        fileWorkspace.selectionModePath = nil
        fileWorkspace.previewPath = nil
        fileWorkspace.previewComparisonMode = nil
        fileWorkspace.previewVisible = false
        fileWorkspace.previewThreeVersions = false
        operationRecovery.showConflictResolver = true
    }

    @ViewBuilder
    private var activeToolWindowContent: some View {
        switch projectWorkspace.toolWindowMode {
        case .commit, .log:
            RebasedCommitWorkspace(
                projectPath: projectWorkspace.path,
                repo: repo,
                repositoryWorkdir: repo?.workdir(),
                shelfRepo: activeShelfRepository,
                entries: repositoryStatus.entries,
                changeLists: repositoryStatus.changeLists,
                untrackedEntries: untrackedEntries,
                ignoredRules: repositoryStatus.ignoredRules,
                stashes: stashUI.stashes,
                shelves: activeShelfList,
                deletedShelves: activeDeletedShelfList,
                shelfChangeLists: activeShelfChangeLists,
                showShelfRequestID: shelfWorkspace.tabRequestID,
                onWorkspaceTabChange: { shelfWorkspace.isWorkspaceTabActive = $0 },
                shelfRootPath: activeShelfRootPath,
                shelfRootOptions: availableShelfRoots,
                selectedShelfRootPath: activeShelfRootPath ?? "",
                isShelfRootReadOnly: isShelfRootReadOnly,
                canMutateShelfMetadata: canMutateShelfMetadata,
                canApplyShelfWorktree: canApplyShelfWorktree,
                isShelfRootLoading: shelfWorkspace.rootLoading,
                shelfRootError: shelfWorkspace.rootError,
                onShelfRootChange: setShelfRoot,
                isLoading: repositoryStatus.isLoading,
                isShowingCachedStatusSnapshot: repositoryStatus.isShowingCachedStatusSnapshot,
                hasStaged: hasStaged,
                commitFeedback: commitWorkspace.feedback,
                operationState: operationRecovery.operation,
                operationFeedback: operationRecovery.feedback,
                binaryPaths: stagingBinaryPaths,
                lfsTrackedPaths: lfsWorkspace.trackedPaths,
                lfsPointerPaths: lfsWorkspace.pointerPaths,
                stagingPresence: stagingPresenceByPath,
                refreshToken: fileWorkspace.refreshToken,
                recentMessages: commitWorkspace.recentMessages,
                commitMessage: $commitWorkspace.message,
                amendMode: $commitWorkspace.amendMode,
                skipHooks: $commitWorkspace.skipHooks,
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
                previewMode: $fileWorkspace.previewMode,
                comparisonMode: fileWorkspace.previewComparisonMode,
                showThreeVersions: $fileWorkspace.previewThreeVersions,
                previewPath: $fileWorkspace.previewPath,
                isPreviewVisible: $fileWorkspace.previewVisible,
                selectionModePath: $fileWorkspace.selectionModePath,
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
                onBeforeCommitSettings: { commitWorkspace.showBeforeCommitSettings = true },
                onCommit: { doCommit() },
                onCommitAll: commitAllTrackedChanges,
                onCommitAndRebase: { doCommit(rebaseAfterCommit: true) },
                autoSquashCommitKind: rebaseWorkspace.pendingAutoSquash?.kind,
                onCommitAndPush: beginCommitAndPush,
                onOperationContinue: doOperationContinue,
                onOperationSkip: doOperationSkip,
                onOperationAbort: doOperationAbort,
                onOpenConflictResolver: openActiveOperationConflictResolver,
                onShelve: { shelfWorkspace.showCreateDialog = true },
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
                shelfDiffText: shelfWorkspace.previewText,
                shelfPreviewName: $shelfWorkspace.previewName,
                shelfPreviewIsDeleted: $shelfWorkspace.previewIsDeleted,
                isShelfPreviewVisible: $shelfWorkspace.showPreview,
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
                resolvedConflictPaths: operationRecovery.resolvedConflictPaths,
                onRevertResolved: revertResolvedPath,
                onShowHistory: { path in showFileHistory(path) },
                onEditGitignore: editGitignore,
                onEditGitExclude: editGitExclude
            )
        case .operations:
            VStack(spacing: 0) {
                Picker("操作视图", selection: $operationRecovery.viewMode) {
                    ForEach(OperationsViewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider()
                switch operationRecovery.viewMode {
                case .tasks:
                    GitTasksView(
                        feedbackCenter: feedbackCenter,
                        focusNotificationID: $operationRecovery.logFocusNotificationID,
                        onOpenHistory: { operationRecovery.viewMode = .history }
                    )
                case .history:
                    OperationLogView(
                        feedbackCenter: feedbackCenter,
                        focusNotificationID: $operationRecovery.logFocusNotificationID
                    )
                case .console:
                    GitConsoleView(
                        result: operationRecovery.consoleResult,
                        onRun: runGitConsole,
                        onClear: { operationRecovery.consoleResult = nil }
                    )
                case .roots:
                    MultiRootPanel(
                        roots: multiRootWorkspace.roots,
                        results: multiRootWorkspace.results,
                        conflictGroups: operationRecovery.multiRootConflictGroups,
                        isRunning: multiRootWorkspace.running,
                        canRetryFailedUpdate: multiRootWorkspace.updateRetryAvailable,
                        canRetryFailedCheckoutUpdate: multiRootWorkspace.checkoutUpdateRetryAvailable,
                        canRetryFailedPush: pushWorkspace.multiRootPushRetryContext != nil,
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
                        conflictBatchWorking: operationRecovery.multiRootConflictBatchWorking,
                        conflictBatchError: operationRecovery.multiRootConflictBatchError,
                        stashConflicts: stashRecovery.multiRootConflicts,
                        onResolveStashConflict: openMultiRootStashConflict,
                        updateStashRoots: stashRecovery.multiRootUpdateStashedRoots,
                        onRestoreUpdateStash: restoreMultiRootUpdateStash,
                        onRefresh: { loadMultiRoots() },
                        onShowChanges: openMultiRootChanges
                    )
                case .submodules:
                    SubmodulePanel(
                        submodules: submoduleWorkspace.submodules,
                        feedback: submoduleWorkspace.feedback,
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
                        worktrees: worktreeWorkspace.worktrees,
                        feedback: worktreeWorkspace.feedback,
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
                if toolWindowExpanded || projectWorkspace.toolWindowMode == .log {
                    activeToolWindowContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    WorkspacePanelHeader(
                        title: LocalizedStringKey(projectWorkspace.toolWindowMode.title),
                        systemImage: projectWorkspace.toolWindowMode.systemImage,
                        isExpanded: false,
                        onToggle: {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                toolWindowExpanded = true
                            }
                        }
                    )
                }
            } else if projectWorkspace.toolWindowMode == .log {
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
                        projectPath: projectWorkspace.path,
                        headId: repositoryStatus.headId,
                        entries: repositoryStatus.entries,
                        selection: Binding(
                            get: { fileWorkspace.fileSelection },
                            set: { value in
                                fileWorkspace.treeDiffRequest = nil
                                fileWorkspace.fileSelection = value
                                fileWorkspace.version = .local
                                if value != nil {
                                    fileWorkspace.selection = nil
                                    fileWorkspace.selectionModePath = nil
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
                        resolvedConflictPaths: operationRecovery.resolvedConflictPaths,
                        onRevertResolved: revertResolvedPath,
                        showHeader: false
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                    WorkspacePanelHeader(
                        title: LocalizedStringKey(projectWorkspace.toolWindowMode.title),
                        systemImage: projectWorkspace.toolWindowMode.systemImage,
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
                            projectPath: projectWorkspace.path,
                            headId: repositoryStatus.headId,
                            entries: repositoryStatus.entries,
                            selection: Binding(
                            get: { fileWorkspace.fileSelection },
                            set: { value in
                                fileWorkspace.treeDiffRequest = nil
                                fileWorkspace.fileSelection = value
                                fileWorkspace.version = .local
                                if value != nil {
                                        fileWorkspace.selection = nil
                                        fileWorkspace.selectionModePath = nil
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
                            resolvedConflictPaths: operationRecovery.resolvedConflictPaths,
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
        if projectWorkspace.toolWindowMode == .log {
            projectPanelExpanded.toggle()
        } else {
            projectPanelExpanded = true
        }
    }

    @ViewBuilder
    private var mainContext: some View {
        if let loadError = repositoryStatus.loadError, projectWorkspace.repository == nil {
            ProjectLoadErrorView(
                message: loadError,
                onRetry: {
                    guard let projectPath = projectWorkspace.path else {
                        showOpenPanel()
                        return
                    }
                    openProjectPath(projectPath)
                },
                onOpen: showOpenPanel
            )
        } else if projectWorkspace.repository == nil {
            ProjectEmptyStateView(
                recentPaths: loadRecentPaths(),
                onOpen: showOpenPanel,
                onInit: showInitializePanel,
                onClone: { cloneWorkspace.showDialog = true },
                onSelect: requestOpenProject
            )
        } else if projectWorkspace.toolWindowMode == .log {
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
                Button("打开 Merge Revisions…") { operationRecovery.showConflictResolver = true }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let fileTreeDiffRequest = fileWorkspace.treeDiffRequest,
                  fileWorkspace.selection == nil,
                  fileWorkspace.selectionModePath == nil,
                  fileWorkspace.fileSelection == nil {
            DiffDetailView(
                repo: fileTreeDiffRequest.repo,
                entry: fileTreeDiffRequest.entry,
                onChanged: { },
                selectionModePath: nil,
                initialMode: fileTreeDiffRequest.initialMode,
                refreshToken: fileWorkspace.refreshToken
            )
        } else if fileWorkspace.selection != nil || fileWorkspace.selectionModePath != nil {
            DiffDetailView(
                repo: repo,
                entry: selectedEntry,
                onChanged: refreshAll,
                selectionModePath: fileWorkspace.selectionModePath,
                refreshToken: fileWorkspace.refreshToken
            )
        } else if let fileSelection = fileWorkspace.fileSelection {
            let versionOptions = fileContentVersionOptions
            let effectiveVersion = resolvedFileContentVersion(
                current: fileWorkspace.version,
                available: versionOptions
            ) ?? fileWorkspace.version
            FileContentView(
                repo: repo,
                path: fileSelection,
                version: effectiveVersion,
                availableVersions: versionOptions,
                onVersionChange: { fileWorkspace.version = $0 },
                onShowFileHistory: { path in
                    showFileHistory(path, rootPath: repo?.workdir())
                },
                blameRequestID: fileWorkspace.blameRequestID,
                refreshToken: fileWorkspace.refreshToken
            )
            .onAppear {
                if effectiveVersion != fileWorkspace.version {
                    fileWorkspace.version = effectiveVersion
                }
            }
            .onChange(of: versionOptions) { _, updatedOptions in
                guard let resolved = resolvedFileContentVersion(
                    current: fileWorkspace.version,
                    available: updatedOptions
                ) else { return }
                if resolved != fileWorkspace.version {
                    fileWorkspace.version = resolved
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
                Button("克隆 Git 仓库…") { cloneWorkspace.showDialog = true }
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
            .disabled(repo == nil || repositoryStatus.isLoading)
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
                projectWorkspace.toolWindowMode = .commit
                toolWindowExpanded = true
            }
            .keyboardShortcut("k", modifiers: [.command])
            .disabled(repo == nil)
            .help("打开提交工具窗 (⌘K)")
            Button("Push", systemImage: "arrow.up.circle") {
                beginPushDialog()
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(repo == nil || remoteWorkspace.remotes.isEmpty)
            .help("Push (⌘⇧K)")
            Button("Fetch", systemImage: "arrow.triangle.2.circlepath") {
                doFetch(nil)
            }
            .disabled(repo == nil || remoteWorkspace.remotes.isEmpty)
            .help("Fetch")
        }
    }

    var currentBranchName: String {
        branchWorkspace.branches.first(where: { $0.isCurrent })?.name ?? "（无分支）"
    }

    private var hasAnyMultiRootCommitChanges: Bool {
        multiRootWorkspace.changeGroups.contains { !$0.changedEntries.isEmpty }
    }

    private func openCommitWorkspaceFromBranchPopup() {
        branchWorkspace.showPopover = false
        projectWorkspace.toolWindowMode = .commit
        toolWindowExpanded = true
        projectPanelExpanded = false
    }

    /// The top-level Unstash dialog must switch to the root-qualified
    /// operations once the project has more than one discovered repository.
    /// A single-root window keeps the existing stash conflict surface.
    var useRootScopedUnstashActions: Bool {
        multiRootWorkspace.roots.count > 1
    }

    var rebaseRepositories: [GitRootInfo] {
        multiRootWorkspace.roots.count > 1 ? multiRootWorkspace.roots : []
    }

    var rebaseBranchOptions: [BranchInfo] {
        guard let snapshot = multiRootWorkspace.branchSnapshots.first(where: {
            $0.rootPath == rebaseWorkspace.rootPath
        }) else {
            return branchWorkspace.branches
        }
        return snapshot.branches
    }

    @ViewBuilder
    private var branchPopup: some View {
        Button {
            loadRepoData()
            if multiRootWorkspace.roots.count > 1 {
                // The Branches Popup action group needs a current project-wide
                // status snapshot to update Commit Changes enablement. Do not
                // leave a stale empty multi-root snapshot looking clean.
                loadMultiRootChanges()
            }
            branchWorkspace.showPopover = true
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
        .popover(isPresented: $branchWorkspace.showPopover, arrowEdge: .bottom) {
            if multiRootWorkspace.roots.count > 1 && !multiRootWorkspace.branchSnapshots.isEmpty {
                MultiRootBranchesPopover(
                    projectPath: projectWorkspace.path,
                    protectedBranchPatterns: effectiveProtectedBranchPatterns,
                    snapshots: multiRootWorkspace.branchSnapshots,
                    incomingBranches: gitSettings.autoFetchIncomingBranches,
                    operationContexts: multiRootWorkspace.roots.compactMap { root in
                        guard let kind = root.operation else { return nil }
                        return BranchPopupOperationContext(
                            rootPath: root.path,
                            displayName: root.displayName,
                            relativePath: root.relativePath,
                            kind: kind,
                            hasConflicts: operationRecovery.multiRootConflictGroups.contains {
                                $0.rootPath == root.path && !$0.paths.isEmpty
                            }
                        )
                    },
                    onOperationAction: { rootPath, action in
                        handleVCSActionRequest(
                            ArborVCSActionRequest(
                                kind: .operationRecovery,
                                projectPath: projectWorkspace.path,
                                rootPath: rootPath,
                                shelfName: "",
                                operationRecoveryAction: action.recoveryAction
                            )
                        )
                    },
                    onCommitChanges: {
                        branchWorkspace.showPopover = false
                        openMultiRootCommitDialog()
                    },
                    hasCommitChanges: hasAnyMultiRootCommitChanges,
                    onNewBranch: {
                        presentMultiRootNewBranchDialog()
                        branchWorkspace.showPopover = false
                    },
                    onFindMerged: {
                        beginFindMergedBranches()
                        branchWorkspace.showPopover = false
                    },
                    onRemoteTags: {
                        branchWorkspace.showPopover = false
                        tagWorkspace.showMultiRootRemoteTagsDialog = true
                    },
                    onCheckout: { rootPath, reference, isRemote in
                        checkoutBranchInRoot(
                            rootPath: rootPath,
                            reference: reference,
                            isRemote: isRemote
                        )
                        branchWorkspace.showPopover = false
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
                        branchWorkspace.showPopover = false
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
                        branchWorkspace.showPopover = false
                    },
                    onCheckoutRecent: { rootPath, name in
                        checkoutRecentBranchInRoot(rootPath: rootPath, name: name)
                        branchWorkspace.showPopover = false
                    },
                    onCheckoutTag: { rootPath, name in
                        checkoutTagInRoot(rootPath: rootPath, name: name)
                        branchWorkspace.showPopover = false
                    },
                    onDeleteTag: { rootPath, name in
                        deleteTagInRoot(rootPath: rootPath, name: name)
                    },
                    onDeleteTagAcrossRoots: { name in
                        presentMultiRootDeleteTagDialog(name: name)
                        branchWorkspace.showPopover = false
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
                        branchWorkspace.showPopover = false
                    },
                    onForcePushedUpdate: { rootPath, branch in
                        updateForcePushedBranchInRoot(rootPath: rootPath, branch: branch)
                        branchWorkspace.showPopover = false
                    },
                    onForcePushedUpdateAcrossRoots: { branch in
                        updateForcePushedBranchAcrossRoots(branch)
                        branchWorkspace.showPopover = false
                    },
                    onPullBranch: { rootPath, branch, rebase in
                        pullBranchInRoot(rootPath: rootPath, branch: branch, rebase: rebase)
                        branchWorkspace.showPopover = false
                    },
                    onPullRemoteBranch: { rootPath, branch, rebase in
                        pullRemoteBranchInRoot(
                            rootPath: rootPath,
                            remoteBranch: branch,
                            rebase: rebase
                        )
                        branchWorkspace.showPopover = false
                    },
                    onDeleteRemote: { rootPath, branch in
                        deleteRemoteBranchInRoot(rootPath: rootPath, branch: branch)
                        branchWorkspace.showPopover = false
                    },
                    onDeleteRemoteAcrossRoots: { branch in
                        presentMultiRootRemoteDeleteDialog(branch: branch)
                        branchWorkspace.showPopover = false
                    },
                    onMerge: { rootPath, branch in
                        mergeBranchInRoot(rootPath: rootPath, branch: branch)
                        branchWorkspace.showPopover = false
                    },
                    onMergeAcrossRoots: presentMultiRootMergeFromPopup,
                    onRebase: { rootPath, branch in
                        rebaseCurrentInRoot(rootPath: rootPath, onto: branch)
                        branchWorkspace.showPopover = false
                    },
                    onCompare: { rootPath, branch in
                        compareBranchInRoot(rootPath: rootPath, branch: branch)
                        branchWorkspace.showPopover = false
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
                        branchWorkspace.showPopover = false
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
                        branchWorkspace.showPopover = false
                    },
                    onUpdateSelected: { selection in
                        updateSelectedBranchesInRoots(selection)
                        branchWorkspace.showPopover = false
                    },
                    onDeleteSelected: { selection in
                        deleteSelectedBranchesInRoots(selection)
                        branchWorkspace.showPopover = false
                    },
                    onPushDialog: { rootPath, branch in
                        beginMultiRootPushDialog(rootPath: rootPath, branch: branch)
                        branchWorkspace.showPopover = false
                    },
                    onEditRemote: { rootPath, name in
                        beginMultiRootRemoteConfig(rootPath: rootPath, selectedRemote: name)
                        branchWorkspace.showPopover = false
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
                        branchWorkspace.showPopover = false
                    },
                    onUnsetUpstream: { rootPath, branch in
                        unsetBranchUpstreamInRoot(rootPath: rootPath, branch: branch)
                        branchWorkspace.showPopover = false
                    },
                    onRenameBranch: { rootPath, branch in
                        renameBranchInRoot(rootPath: rootPath, oldName: branch)
                        branchWorkspace.showPopover = false
                    },
                    onRenameBranchAcrossRoots: { name in
                        presentMultiRootRenameBranchDialog(name: name)
                        branchWorkspace.showPopover = false
                    },
                    onDeleteBranchAcrossRoots: { name in
                        presentMultiRootDeleteBranchDialog(name: name)
                        branchWorkspace.showPopover = false
                    },
                    onDeleteBranch: { rootPath, branch in
                        deleteBranchInRoot(rootPath: rootPath, name: branch)
                        branchWorkspace.showPopover = false
                    },
                    onCheckoutReference: { rootPath in
                        checkoutReferenceFromInput(rootPath: rootPath)
                    },
                    onOpenWorktree: { path in
                        branchWorkspace.showPopover = false
                        openWindow(value: path)
                    },
                    onCreateWorktreeFromReference: { rootPath, reference, isTag in
                        branchWorkspace.showPopover = false
                        presentNewWorktreeFromReference(
                            reference,
                            isTag: isTag,
                            rootPath: rootPath
                        )
                    },
                    onProjectGitSettings: {
                        branchWorkspace.showPopover = false
                        gitSettings.showProjectGitSettings = true
                    },
                    onCancel: { branchWorkspace.showPopover = false }
                )
            } else {
                RebasedBranchesPopover(
                projectPath: projectWorkspace.path,
                branches: branchWorkspace.branches,
                remoteBranches: branchWorkspace.remoteBranches,
                recentBranches: branchWorkspace.recentBranches,
                tags: tagWorkspace.tags,
                comparisons: branchWorkspace.comparisons,
                syncStatuses: branchWorkspace.syncStatuses,
                incomingBranches: gitSettings.autoFetchIncomingBranches,
                stashes: stashUI.stashes,
                worktrees: worktreeWorkspace.worktrees,
                hasRemote: !remoteWorkspace.remotes.isEmpty,
                protectedBranchPatterns: effectiveProtectedBranchPatterns,
                isShallow: repositoryStatus.isShallowRepository,
                hasHeadCommit: repositoryStatus.headId != nil,
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
                tagPushRemotes: remoteWorkspace.remotes.map(\.name),
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
                    branchWorkspace.showPopover = false
                    tagWorkspace.showRemoteTagsDialog = true
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
                    branchWorkspace.showPopover = false
                },
                onCheckoutReference: checkoutReferenceFromInput,
                onOpenWorktree: { path in
                    branchWorkspace.showPopover = false
                    openWindow(value: path)
                },
                onCreateWorktreeFromReference: { reference, isTag in
                    branchWorkspace.showPopover = false
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
                onShelve: { shelfWorkspace.showCreateDialog = true },
                onUpdate: { doPull(nil, rebase: $0) },
                onPush: { beginPushDialog() },
                onFetch: { doFetch(nil) },
                onRefresh: { loadRepoData() },
                onConfigureRemotes: beginConfigureRemotes,
                onProjectGitSettings: {
                    branchWorkspace.showPopover = false
                    gitSettings.showProjectGitSettings = true
                },
                onFetchAll: { doFetchAll() },
                onFetchPrune: doFetchPrune,
                onFetchUnshallow: doFetchUnshallow,
                onSetUpstream: { branch in
                    branchWorkspace.upstreamLocalBranch = branch
                    branchWorkspace.showUpstreamDialog = true
                },
                onUnsetUpstream: unsetBranchUpstream,
                operationState: operationRecovery.operation,
                onOperationContinue: {
                    doOperationContinue()
                    branchWorkspace.showPopover = false
                },
                onOperationSkip: {
                    doOperationSkip()
                    branchWorkspace.showPopover = false
                },
                onOperationAbort: {
                    doOperationAbort()
                    branchWorkspace.showPopover = false
                }
                )
            }
        }
    }

    private var remoteConfigSheet: some View {
        Group {
            if repo != nil {
                RemoteConfigDialogView(
                    remotes: remoteWorkspace.remotes,
                    name: $remoteWorkspace.name,
                    url: $remoteWorkspace.url,
                    pushUrl: $remoteWorkspace.pushUrl,
                    fetchRefspec: $remoteWorkspace.fetchRefspec,
                    pushRefspec: $remoteWorkspace.pushRefspec,
                    initialSelectedName: nil,
                    onAdd: remoteAdd,
                    onRemove: remoteRemove,
                    onRename: remoteRename,
                    onSave: saveRemoteConfig,
                    onCancel: { remoteWorkspace.showConfigDialog = false },
                    onRefresh: loadRemotes
                )
            }
        }
    }

    private func saveUpstreamFromDialog(_ upstream: String) {
        let branch = branchWorkspace.upstreamLocalBranch
        branchWorkspace.showUpstreamDialog = false
        setBranchUpstream(branch, upstream: upstream)
    }

    private var rebaseTodoSheet: some View {
        Group {
            if let repo {
                RebaseTodoEditorView(
                    repo: repo,
                    onto: rebaseWorkspace.todoOnto,
                    items: $rebaseWorkspace.todoItems,
                    preserveMerges: rebaseWorkspace.todoPreserveMerges,
                    root: rebaseWorkspace.todoRoot,
                    onStart: startTodoRebase,
                    onOpenRawTodo: prepareRawRebaseTodoEditor,
                    onCancel: { rebaseWorkspace.showTodoEditor = false }
                )
            }
        }
    }

    private var rebaseRawTodoSheet: some View {
        RawRebaseTodoEditorView(
            onto: rebaseWorkspace.todoOnto,
            text: $rebaseWorkspace.rawTodoText,
            preserveMerges: rebaseWorkspace.todoPreserveMerges,
            root: rebaseWorkspace.todoRoot,
            onStart: startRawTodoRebase,
            onCancel: {
                rebaseWorkspace.showRawTodoEditor = false
                rebaseWorkspace.rawTodoText = ""
            }
        )
    }

    /// IDX-001 二进制文件路径集合（staging model 提供）。
    private var stagingBinaryPaths: Set<String> {
        Set((repositoryStatus.stagingModel?.entries ?? []).filter { $0.binary }.map { $0.path })
    }

    /// IDX-001: expose exact HEAD/index/worktree presence to Changes actions;
    /// status kinds alone cannot distinguish an empty file from a missing side.
    private var stagingPresenceByPath: [String: StagingVersionPresence] {
        Dictionary(
            uniqueKeysWithValues: (repositoryStatus.stagingModel?.entries ?? []).map { entry in
                (entry.path, stagingVersionPresence(for: entry))
            }
        )
    }

    private var fileContentVersionOptions: [FileContentVersion] {
        guard let path = fileWorkspace.fileSelection,
              let entry = repositoryStatus.entries.first(where: { $0.path == path }) else {
            return [fileWorkspace.version]
        }
        return fileContentVersions(
            for: stagingVersionActions(
                for: entry,
                presence: stagingPresenceByPath[path]
            ),
            current: fileWorkspace.version
        )
    }

    /// CONFLICT-001：merge/rebase/cherry-pick/revert 进入同一冲突工作台。
    private var mergeRevisionsMode: MergeRevisionsDialogView.Mode {
        if stashRecovery.popConflictInProgress || stashRecovery.applyConflictInProgress {
            return .stashRestore
        }
        if shelfWorkspace.conflictInProgress {
            if shelfWorkspace.conflictIsDirectPatch {
                return .applyPatch
            }
            return .shelveRestore(isPop: shelfWorkspace.conflictIsPop)
        }
        switch operationRecovery.operation?.kind {
        case .rebase: return .rebase
        case .cherryPick: return .cherryPick
        case .revert: return .revert
        default: return .merge
        }
    }

    private var mergeRevisionsAbortAction: (() -> Void)? {
        if shelfWorkspace.conflictInProgress {
            return { abortShelveConflict() }
        }
        if stashRecovery.popConflictInProgress || stashRecovery.applyConflictInProgress {
            return nil
        }
        return {
            doOperationAbort()
            operationRecovery.showConflictResolver = false
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
        if operationRecovery.showConflictResolver {
            singleRootConflictResolverPanel
        }
        if operationRecovery.showMultiRootConflictResolver {
            multiRootConflictResolverPanel
        }
    }

    @ViewBuilder
    private var singleRootConflictResolverPanel: some View {
        if let repo = shelfWorkspace.pendingConflictRepository ?? self.repo {
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
                        operationRecovery.showConflictResolver = false
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                Divider()
                MergeRevisionsDialogView(
                    repo: repo,
                    entries: $repositoryStatus.entries,
                    initialPath: operationRecovery.initialPath ?? fileWorkspace.selection,
                    mode: mergeRevisionsMode,
                    directPatchText: shelfWorkspace.conflictIsDirectPatch ? shelfWorkspace.pendingConflictPatch : nil,
                    directPatchRestoreName: shelfWorkspace.conflictIsDirectPatch ? shelfWorkspace.pendingConflictName : nil,
                    onChanged: {
                        if shelfWorkspace.conflictInProgress {
                            refreshShelveConflictStatus()
                        } else {
                            refreshAll()
                        }
                    },
                    onComplete: {
                        if shelfWorkspace.conflictInProgress {
                            finishShelveConflict()
                        } else {
                            doOperationContinue()
                            operationRecovery.showConflictResolver = false
                            operationRecovery.initialPath = nil
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
                roots: operationRecovery.multiRootResolverRoots,
                activeRootPath: operationRecovery.multiRootResolverActiveRootPath,
                activeRepo: operationRecovery.multiRootResolverActiveRepo,
                entries: $operationRecovery.multiRootResolverActiveEntries,
                initialPath: operationRecovery.multiRootResolverActiveInitialPath,
                activeKind: operationRecovery.multiRootResolverActiveKind,
                isWorking: operationRecovery.multiRootResolverWorking,
                error: operationRecovery.multiRootResolverError,
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
        guard operationRecovery.operation?.kind == nil,
              isArborVCSActionVisible(.merge, in: vcsActionContext),
              isArborVCSActionEnabled(.merge, in: vcsActionContext) else { return }
        loadMergeDialogSettings(for: projectWorkspace.path)
        if let branch { mergeWorkspace.branch = branch }
        mergeWorkspace.dialogGeneration &+= 1
        let generation = mergeWorkspace.dialogGeneration
        mergeWorkspace.mergedBranches = []
        mergeWorkspace.showActionDialog = true
        guard let repo else { return }
        Task.detached(priority: .userInitiated) {
            let mergedBranches = (try? repo.branchListMerged().map(\.name)) ?? []
            await MainActor.run {
                guard generation == self.mergeWorkspace.dialogGeneration else { return }
                self.mergeWorkspace.mergedBranches = Set(mergedBranches)
            }
        }
    }

    func loadMergeDialogSettings(for projectPath: String?) {
        let settings = GitMergeDialogSettingsStore.load(for: projectPath)
        mergeWorkspace.branch = settings.branch
        mergeWorkspace.strategyRaw = settings.strategyRaw
        mergeWorkspace.useCustomCommitMessage = settings.useCustomCommitMessage
        mergeWorkspace.noCommit = settings.noCommit
        mergeWorkspace.noVerify = settings.noVerify
        mergeWorkspace.allowUnrelatedHistories = settings.allowUnrelatedHistories
        if !mergeWorkspace.useCustomCommitMessage {
            mergeWorkspace.commitMessage = ""
        }
    }

    func saveMergeDialogSettings() {
        GitMergeDialogSettingsStore.save(
            GitMergeDialogSettings(
                branch: mergeWorkspace.branch,
                strategyRaw: mergeWorkspace.strategyRaw,
                useCustomCommitMessage: mergeWorkspace.useCustomCommitMessage,
                noCommit: mergeWorkspace.noCommit,
                noVerify: mergeWorkspace.noVerify,
                allowUnrelatedHistories: mergeWorkspace.allowUnrelatedHistories
            ),
            for: projectWorkspace.path
        )
    }

    func loadRebaseDialogSettings(for projectPath: String?) {
        let settings = GitRebaseDialogSettingsStore.load(for: projectPath)
        rebaseWorkspace.onto = settings.onto
        rebaseWorkspace.interactive = settings.interactive
        rebaseWorkspace.preserveMerges = settings.preserveMerges
        rebaseWorkspace.autoSquash = settings.autoSquash
        rebaseWorkspace.keepEmpty = settings.keepEmpty
        rebaseWorkspace.updateRefs = settings.updateRefs
        rebaseWorkspace.root = settings.root
    }

    func saveRebaseDialogSettings() {
        GitRebaseDialogSettingsStore.save(
            GitRebaseDialogSettings(
                onto: rebaseWorkspace.onto,
                interactive: rebaseWorkspace.interactive,
                preserveMerges: rebaseWorkspace.preserveMerges,
                autoSquash: rebaseWorkspace.autoSquash,
                keepEmpty: rebaseWorkspace.keepEmpty,
                updateRefs: rebaseWorkspace.updateRefs,
                root: rebaseWorkspace.root
            ),
            for: projectWorkspace.path
        )
    }

    func openRebaseDialog(_ branch: String?) {
        guard operationRecovery.operation?.kind == nil,
              isArborVCSActionVisible(.rebase, in: vcsActionContext),
              isArborVCSActionEnabled(.rebase, in: vcsActionContext) else { return }
        loadRebaseDialogSettings(for: projectWorkspace.path)
        if let branch { rebaseWorkspace.onto = branch }
        rebaseWorkspace.rootPath = repo?.workdir() ?? multiRootWorkspace.roots.first?.path ?? ""
        rebaseWorkspace.branch = rebaseBranchOptions.first(where: { $0.isCurrent })?.name
            ?? rebaseBranchOptions.first?.name
            ?? ""
        rebaseWorkspace.applyToAllRoots = false
        rebaseWorkspace.range = []
        rebaseWorkspace.actions = []
        rebaseWorkspace.feedback = nil
        rebaseWorkspace.showActionDialog = true
    }

    private func selectRebaseRepository() {
        let snapshot = multiRootWorkspace.branchSnapshots.first(where: {
            $0.rootPath == rebaseWorkspace.rootPath
        })
        rebaseWorkspace.branch = snapshot?.headBranch
            ?? snapshot?.branches.first(where: { $0.isCurrent })?.name
            ?? snapshot?.branches.first?.name
            ?? ""
        invalidateLoadedRebaseRange()
    }

    private func compareBranchFromPopup(_ branch: String) {
        projectWorkspace.toolWindowMode = .log
        toolWindowExpanded = true
        projectPanelExpanded = false
        compareLogBranch(rootPath: nil, branch: branch)
        branchWorkspace.showPopover = false
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
        branchWorkspace.renameOld = oldName
        branchWorkspace.renameNew = newName
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
