import SwiftUI
import AppKit

extension ContentView {

    var workspacePresentedView: some View {
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
        .sheet(item: $fileWorkspace.blockHistoryRequest) { request in
            BlockHistoryView(
                request: request,
                onClose: { fileWorkspace.blockHistoryRequest = nil }
            )
        }
        .confirmationDialog(
            "Delete from Disk?",
            isPresented: Binding(
                get: { !projectWorkspace.pendingDeletePaths.isEmpty },
                set: { presented in
                    if !presented { cancelDeletePaths() }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: confirmDeletePaths)
            Button("Cancel", role: .cancel, action: cancelDeletePaths)
        } message: {
            Text(deleteConfirmationMessage(projectWorkspace.pendingDeletePaths))
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
        .alert("Open Another Project?", isPresented: $projectWorkspace.showSwitchAlert) {
            Button("Replace Current Window") { replacePendingProject() }
            Button("New Window") {
                openWindow(id: "project", value: projectWorkspace.pendingPath)
                projectWorkspace.pendingPath = nil
            }
            Button("Cancel", role: .cancel) { projectWorkspace.pendingPath = nil }
        } message: {
            Text("The current window is showing \(projectWorkspace.repository?.displayName() ?? String(localized: "a project")). Choose how to open the new project.")
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
                .environment(\.locale, appLocale)
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
            .environment(\.locale, appLocale)
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
            .environment(\.locale, appLocale)
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

    @ViewBuilder
    var beforeCommitSettingsSheet: some View {
        BeforeCommitSettingsView(
            commands: $commitWorkspace.beforeCommitCommands,
            onIdentity: { gitSettings.showIdentitySettings = true }
        )
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
}
