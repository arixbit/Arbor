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
    @State var notificationsPresented = false
    @State var workspaceTitlebarHeight: CGFloat = 0
    @StateObject var credentialAuth = CredentialAuthController()
    // ContentView is also hosted by the AppKit fallback window used when a
    // repository path is passed on the command line. SceneStorage is only
    // valid inside a SwiftUI Scene and causes repeated runtime warnings (and
    // unstable bindings) in that path. AppStorage keeps the same user-facing
    // persistence while remaining valid for both scene and AppKit hosting.
    @AppStorage("arbor.toolWindowExpanded") var toolWindowExpanded = true
    // The reference window shows the Project tool window below the Commit /
    // Stash tool window (see docs/visual-baseline.md), so it starts expanded.
    // The versioned key lets the new default reach existing installations.
    @AppStorage("arbor.projectPanelExpanded.v3") var projectPanelExpanded = true
    // With both tool windows expanded the Commit surface takes the upper half,
    // matching the reference split; the divider stays draggable.
    @AppStorage("arbor.toolWindowHeight.v3") var toolWindowHeight: Double = 466
    // 40pt activity rail + 582pt panel + 6pt divider = 628pt at the
    // matched reference size. The new key adopts this round's geometry.
    @AppStorage("arbor.workspaceSidebarWidth.v12") var savedWorkspaceSidebarWidth: Double = 582
    // The Log editor has its own graph/details splitter. Its graph/table side
    // is the dominant column in the reference frame; the details inspector is
    // the narrower right-hand column.
    // At 1642pt this leaves a 280pt inspector beside the dominant Log table.
    @AppStorage("arbor.logGraphWidth.v8") var savedLogGraphWidth: Double = 688
    // These are the same three persistent Log presentation properties exposed
    // by rebased's VcsLog UI actions. They are deliberately state, not layout
    // hacks: changing them must not reload or replace the selected commit.
    @AppStorage("arbor.log.showDetails.v1") var logShowDetails = true
    @AppStorage("arbor.log.showDiffPreview.v1") var logShowDiffPreview = true
    @AppStorage("arbor.log.diffPreviewVertical.v1") var logDiffPreviewVertical = false
    @AppStorage("arbor.log.compactReferences.v2") var logCompactReferences = true
    @AppStorage("arbor.log.commitColumns.v1") var logShowCommitColumns = false
    @AppStorage("arbor.log.authorColumn.v1") var logShowAuthorColumn = true
    @AppStorage("arbor.log.dateColumn.v1") var logShowDateColumn = true
    @AppStorage("arbor.log.columnHeaders.v1") var logShowColumnHeaders = false
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

    var body: some View {
        workspacePresentedView
    }
}
