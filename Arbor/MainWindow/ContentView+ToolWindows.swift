import SwiftUI
import AppKit

extension ContentView {

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
                Picker("Operations view", selection: $operationRecovery.viewMode) {
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

    var workspaceSidebar: some View {
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
                                .help("Open Project")
                                if repo != nil {
                                    Button(action: { if let repo { showInFinder(repo) } }) {
                                        Image(systemName: "arrow.up.forward.app")
                                    }
                                    .buttonStyle(.plain)
                                    .help("Reveal Project Root in Finder")
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
                                .help("Open Project")
                                if repo != nil {
                                    Button(action: { if let repo { showInFinder(repo) } }) {
                                        Image(systemName: "arrow.up.forward.app")
                                    }
                                    .buttonStyle(.plain)
                                    .help("Reveal Project Root in Finder")
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

    /// The Log editor stays in the window for both the Commit and the Log tool
    /// window, matching the reference layout where committing never hides the
    /// history. Only the Operations surface replaces it.
    var showsLogWorkspace: Bool {
        projectWorkspace.toolWindowMode != .operations
    }

    func toggleProjectToolWindow() {
        if showsLogWorkspace {
            projectPanelExpanded.toggle()
        } else {
            projectPanelExpanded = true
        }
    }

    @ViewBuilder
    var mainContext: some View {
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
        } else if showsLogWorkspace {
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
                Text("The conflicted file is open in Merge Revisions")
                    .foregroundStyle(.secondary)
                Button("Open Merge Revisions…") { operationRecovery.showConflictResolver = true }
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
                broker: credentialAuth.broker,
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
        } else if projectWorkspace.toolWindowMode == .commit {
            // Rebased keeps the Log editor in the centre of the window while
            // the Commit tool window is open. Only an explicit file, diff or
            // conflict selection above replaces it, so committing never leaves
            // the user staring at an empty editor area.
            logWorkspace
        } else {
            VStack(spacing: Design.Spacing.md) {
                Image(systemName: "rectangle.center.inset.filled")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Design.Colors.accent)
                Text("Select a context from the project tree or the tool window below")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
