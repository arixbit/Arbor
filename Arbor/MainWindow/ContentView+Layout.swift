import SwiftUI
import AppKit

extension ContentView {

    /// 主内容（VStack 及其前置修饰符）。
    @ViewBuilder
    var mainView: some View {
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

            HStack(spacing: 0) {
            WorkspaceSplitLayout(
                persistedSidebarWidth: $savedWorkspaceSidebarWidth,
                selectedToolWindow: projectWorkspace.toolWindowMode,
                // Rebased keeps the selected Git tool window on the left and
                // opens Git Log in the editor workspace on the right. Log is
                // therefore a second workspace, not a replacement for the
                // Commit/Stash column.
                sidebarVisible: true,
                minimumMainWidth: repo != nil && showsLogWorkspace ? 540 : 420,
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
                    .background(Design.Colors.logSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack {
                Button {
                    notificationsPresented.toggle()
                } label: {
                    Image(systemName: "bell")
                        .font(.system(size: 17, weight: .regular))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Notifications")
                .accessibilityLabel("Notifications")
                .popover(isPresented: $notificationsPresented, arrowEdge: .leading) {
                    OperationLogView(
                        feedbackCenter: feedbackCenter,
                        focusNotificationID: $operationRecovery.logFocusNotificationID
                    )
                    .frame(width: 380, height: 480)
                }
                Spacer()
            }
            .padding(.top, 4)
            .frame(width: 40)
            }
            .padding(.bottom, 4)
            .background(Design.Colors.workspaceFrame)

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
        .frame(minWidth: 980, minHeight: 540 - workspaceTitlebarHeight)
        .font(Design.Typography.interface())
        .background(WorkspaceWindowChrome(titlebarHeight: $workspaceTitlebarHeight))
        .ignoresSafeArea(.container, edges: .top)
        .background(Design.Colors.canvas)
        .onChange(of: projectWorkspace.toolWindowMode, initial: false) { _, mode in
            UserDefaults.standard.set(mode.rawValue, forKey: "arbor.toolWindowMode")
            if mode == .commit {
                refreshAll()
            } else if !showsLogWorkspace {
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
}
