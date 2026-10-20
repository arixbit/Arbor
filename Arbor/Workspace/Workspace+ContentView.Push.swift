import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// 顶部工具栏/Branches 弹出的普通 Push 入口；提交工具窗的
/// “Commit and Push…” 则仍由 beginCommitAndPush 进入同一对话框的另一模式。
func beginPushDialog(branch: String? = nil) {
    // GitPushBranchAction remains reachable for a local branch without a
    // configured remote; let the dialog explain that state and offer remote
    // configuration instead of silently discarding the click.
    guard self.repo != nil else { return }
    let sourceBranch = branch ?? currentBranchName
    let configuredTarget = branchWorkspace.syncStatuses
        .first(where: { $0.branch == sourceBranch && $0.trackingExists })
        .flatMap {
            remoteBranchTargetForConfiguredUpstream($0.upstream, remotes: remoteWorkspace.remotes)
        }
    pushWorkspace.dialogRemote = configuredTarget?.remote
    pushWorkspace.dialogRefspec = nil
    pushWorkspace.dialogBranch = configuredTarget?.branch ?? sourceBranch
    pushWorkspace.dialogSourceRevision = sourceBranch
    pushWorkspace.dialogMode = .push
    pushWorkspace.showDialog = true
}

/// LOG-003：将 Log 中选中的提交作为 source 推送到目标分支。
/// IntelliJ 会打开 Push 对话框；有包含该提交的本地分支时预填它，
/// 否则使用 detached source，并让用户编辑远程目标分支。
func pushUpToCommitFromLog(_ commit: CommitInfo) {
    guard let repo = logRepository(for: commit) else {
        feedbackCenter.error("Push unavailable", detail: "No remote is configured.", nextStep: "Add a remote before pushing.")
        return
    }
    let commitRemotes = (try? repo.remoteList()) ?? activeLogRemotes
    guard !commitRemotes.isEmpty else {
        feedbackCenter.error("Push unavailable", detail: "No remote is configured.", nextStep: "Add a remote before pushing.")
        return
    }
    let commitID = commit.id
    let localBranches = activeLogBranches
    Task.detached(priority: .userInitiated) {
        // Match GitPushUpToCommitAction: prefer the current branch only when
        // it actually contains the selected commit; otherwise use the first
        // local branch that contains it. Query the repository's live permanent
        // graph once instead of walking every local branch independently. The
        // old implementation always pushed to the checked-out branch, which
        // could move an unrelated branch when the Log view was showing another
        // branch's history.
        let containingBranches = Set(
            (try? repo.commitContainingBranches(commitId: commitID)) ?? []
        )
        let current = localBranches.first(where: { $0.isCurrent })
        let candidate = [current].compactMap { $0 }
            .first { containingBranches.contains($0.name) }
            ?? localBranches.first {
                !$0.isCurrent
                    && containingBranches.contains($0.name)
            }
        await MainActor.run {
            self.pushWorkspace.dialogMode = .pushUpToCommit
            self.pushWorkspace.dialogRemote = nil
            self.pushWorkspace.dialogBranch = candidate?.name
            self.pushWorkspace.dialogSourceRevision = commitID
            self.pushWorkspace.dialogRefspec = nil
            self.pushWorkspace.showDialog = true
        }
    }
}

func pushNotificationID(rootPath: String) -> String {
    let normalizedPath = URL(fileURLWithPath: rootPath).standardizedFileURL.path
    let encoded = Data(normalizedPath.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "arbor.push.v1.\(encoded)"
}

func singleRootPushRequest(
    rootPath: String,
    remote: String,
    branch: String,
    force: Bool,
    forceWithLease: Bool,
    setUpstream: Bool,
    refspec: String?,
    tagMode: PushDialogTagMode?,
    skipHooks: Bool,
    viewCommitRanges: [PersistedLogRevisionRange] = []
) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: .retryPush,
        projectPath: projectWorkspace.path,
        rootPath: rootPath,
        shelfName: "",
        pushRecovery: PersistedPushRecovery(
            remote: remote,
            branch: branch,
            force: force,
            forceWithLease: forceWithLease,
            setUpstream: setUpstream,
            refspec: refspec,
            tagModeRaw: tagMode?.rawValue,
            skipHooks: skipHooks,
            rebase: false
        ),
        logRevisionRanges: viewCommitRanges.isEmpty ? nil : viewCommitRanges
    )
}

/// 从 root-scoped Push 对话框执行完整 push 选择：remote、branch、force、
/// force-with-lease、publish/upstream 和 custom refspec 都固定在该 root。
func pushInRoot(
    rootPath: String,
    remote requestedRemote: String?,
    branch requestedBranch: String?,
    force: Bool,
    forceWithLease: Bool,
    setUpstream: Bool,
    refspec: String?,
    tagMode: PushDialogTagMode?,
    skipHooks: Bool,
    viewCommitRanges: [PersistedLogRevisionRange] = []
) {
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    let protectedPatterns = effectiveProtectedBranchPatterns(forRootPath: rootPath)
    let notificationID = pushNotificationID(rootPath: rootPath)
    beginFeedbackOperation("Push", cancelHandle: cancel, notificationID: notificationID)
    Task.detached(priority: .userInitiated) {
        var resolvedRemote = requestedRemote
        var resolvedBranch = requestedBranch
        do {
            let rootRepo = try openRepository(path: rootPath)
            let rootRemotes = try rootRepo.remoteList()
            guard let remote = resolveSelectedRemoteName(
                selectedRemote: requestedRemote,
                availableRemoteNames: rootRemotes.map(\.name)
            ) else {
                throw NSError(
                    domain: "Arbor.MultiRootPush",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey: rootRemotes.count > 1
                            ? "该 Git root 配置了多个 remote，请先选择目标 remote。"
                            : "该 Git root 没有可用的 remote。"
                    ]
                )
            }
            resolvedRemote = remote
            let rootBranches = try rootRepo.branchList()
            let branch = requestedBranch
                ?? rootBranches.first(where: { $0.isCurrent })?.name
                ?? ""
            let hasCustomRefspec = !(refspec?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            guard hasCustomRefspec || !branch.isEmpty else {
                throw NSError(
                    domain: "Arbor.MultiRootPush",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Push 需要一个本地分支。"]
                )
            }
            resolvedBranch = branch
            let effectiveForce = force || PushDialogRefspec.requestsForce(refspec)
            let protectedTarget = PushDialogRefspec.targetBranch(refspec) ?? branch
            guard !effectiveForce || !GitProtectedBranchRules.matches(
                protectedTarget,
                patterns: protectedPatterns
            ) else {
                throw NSError(
                    domain: "Arbor.MultiRootPush",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "\(protectedTarget) is protected by Git settings."]
                )
            }
            let engineTagMode = tagMode.map { mode in
                switch mode {
                case .all: PushTagMode.all
                case .currentBranch: PushTagMode.follow
                }
            }
            if let refspec, !refspec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if engineTagMode != nil || skipHooks {
                    try rootRepo.pushRefspecWithOptionsAndAuthAndCancel(
                        remote: remote,
                        refspec: refspec,
                        force: effectiveForce,
                        forceWithLease: effectiveForce && forceWithLease,
                        tagMode: engineTagMode,
                        skipHooks: skipHooks,
                        broker: broker,
                        cancel: cancel
                    )
                } else {
                    try rootRepo.pushRefspecWithAuthAndCancel(
                        remote: remote,
                        refspec: refspec,
                        force: effectiveForce,
                        forceWithLease: effectiveForce && forceWithLease,
                        broker: broker,
                        cancel: cancel
                    )
                }
            } else {
                let trackingExists = (try rootRepo.syncStatus())
                    .first(where: { $0.branch == branch })?.trackingExists ?? false
                try rootRepo.pushWithOptionsAndAuthAndCancel(
                    remote: remote,
                    branch: branch,
                    force: effectiveForce,
                    forceWithLease: effectiveForce && forceWithLease,
                    setUpstream: setUpstream || !trackingExists,
                    tagMode: engineTagMode,
                    skipHooks: skipHooks,
                    broker: broker,
                    cancel: cancel
                )
            }
            await MainActor.run {
                self.loadMultiRoots()
                let viewCommitsAction = self.multiRootUpdateViewCommitsAction(
                    ranges: viewCommitRanges
                )
                self.feedbackCenter.success(
                    "Push completed",
                    detail: "\(remote)/\(branch) · \(rootPath)",
                    additionalActions: viewCommitsAction.map { [$0] } ?? [],
                    notificationID: notificationID
                )
                self.autoOpenUpdateInfoIfEnabled(viewCommitRanges)
            }
        } catch {
            let retryRemote = resolvedRemote
            let retryBranch = resolvedBranch
            let recoveryRepo = try? openRepository(path: rootPath)
            let recoveryBranches = recoveryRepo.flatMap { try? $0.branchList() } ?? []
            let recoveryStatuses = recoveryRepo.flatMap { try? $0.syncStatus() } ?? []
            let currentBranchForPush = recoveryBranches.first(where: { $0.isCurrent })?.name
            let hasTrackingForPush = recoveryStatuses
                .first(where: { $0.branch == retryBranch })?.trackingExists ?? false
            await MainActor.run {
                self.loadMultiRoots()
                if let stale = stalePushRejectionDetails(error) {
                    let viewCommitsAction = self.multiRootUpdateViewCommitsAction(
                        ranges: viewCommitRanges
                    )
                    let actions = self.directPushRetryActions(
                        rootPath: rootPath,
                        remote: stale.remote,
                        branch: stale.branch,
                        force: force,
                        forceWithLease: forceWithLease,
                        setUpstream: setUpstream,
                        refspec: refspec,
                        tagMode: tagMode,
                        skipHooks: skipHooks,
                        viewCommitRanges: viewCommitRanges,
                        includeForce: true
                    ) + (viewCommitsAction.map { [$0] } ?? []) + [
                        self.showOperationDetailsAction(notificationID: notificationID)
                    ]
                    self.feedbackCenter.warning(
                        "Push rejected by force-with-lease",
                        detail: "\(rootPath): \(stale.remote)/\(stale.branch): \(stale.message)",
                        nextStep: "The remote branch changed after the lease was recorded. Verify the remote history before overwriting it.",
                        additionalActions: actions,
                        notificationID: notificationID,
                        notificationGroup: .important,
                        localized: false
                    )
                } else if case let .PushRejected(kind, rejectedRemote, rejectedBranch, message) = error as? EngineError,
                          kind == .nonFastForward,
                          !force,
                          refspec == nil {
                    let autoUpdate = gitPushAutoUpdateIsEligible(
                        enabled: GitPushAutoUpdateSettings.value(for: self.projectWorkspace.path),
                        force: force,
                        refspec: refspec,
                        currentBranch: currentBranchForPush,
                        rejectedBranch: rejectedBranch,
                        hasTracking: hasTrackingForPush
                    )
                    if autoUpdate {
                        self.updateRootForPushRecovery(
                            rootPath: rootPath,
                            remote: rejectedRemote,
                            branch: rejectedBranch,
                            force: force,
                            forceWithLease: forceWithLease,
                            setUpstream: setUpstream,
                            refspec: nil,
                            tagMode: tagMode,
                            skipHooks: skipHooks,
                            rebase: GitUpdateMethodSettings.method(for: self.projectWorkspace.path) == .rebase,
                            viewCommitRanges: viewCommitRanges
                        )
                    } else {
                        let viewCommitsAction = self.multiRootUpdateViewCommitsAction(
                            ranges: viewCommitRanges
                        )
                        let recovery = PersistedPushRecovery(
                            remote: rejectedRemote,
                            branch: rejectedBranch,
                            force: force,
                            forceWithLease: forceWithLease,
                            setUpstream: setUpstream,
                            refspec: refspec,
                            tagModeRaw: tagMode?.rawValue,
                            skipHooks: skipHooks,
                            rebase: false
                        )
                        let mergeRequest = self.singleRootPushRecoveryRequest(
                            rootPath: rootPath,
                            recovery: recovery,
                            viewCommitRanges: viewCommitRanges
                        )
                        let rebaseRequest = self.singleRootPushRecoveryRequest(
                            rootPath: rootPath,
                            recovery: PersistedPushRecovery(
                                remote: recovery.remote,
                                branch: recovery.branch,
                                force: recovery.force,
                                forceWithLease: recovery.forceWithLease,
                                setUpstream: recovery.setUpstream,
                                refspec: recovery.refspec,
                                tagModeRaw: recovery.tagModeRaw,
                                skipHooks: recovery.skipHooks,
                                rebase: true
                            ),
                            viewCommitRanges: viewCommitRanges
                        )
                        let recoveryActions = [
                            FeedbackAction(title: "Update with Merge", semanticAction: mergeRequest) {
                                self.handleVCSActionRequest(mergeRequest)
                            },
                            FeedbackAction(title: "Update with Rebase", semanticAction: rebaseRequest) {
                                self.handleVCSActionRequest(rebaseRequest)
                            }
                        ] + self.directPushRetryActions(
                            rootPath: rootPath,
                            remote: rejectedRemote,
                            branch: rejectedBranch,
                            force: force,
                            forceWithLease: forceWithLease,
                            setUpstream: setUpstream,
                            refspec: refspec,
                            tagMode: tagMode,
                            skipHooks: skipHooks,
                            viewCommitRanges: viewCommitRanges,
                            includeForce: false
                        ) + (viewCommitsAction.map { [$0] } ?? []) + [
                            self.showOperationDetailsAction(notificationID: notificationID)
                        ]
                        self.feedbackCenter.warning(
                            "Push rejected",
                            detail: "\(rootPath): \(rejectedRemote)/\(rejectedBranch): \(message)",
                            nextStep: "Update this Git root, resolve any conflicts, then retry Push.",
                            additionalActions: recoveryActions,
                            notificationID: notificationID,
                            notificationGroup: .important,
                            localized: false
                        )
                    }
                } else {
                    let viewCommitsAction = self.multiRootUpdateViewCommitsAction(
                        ranges: viewCommitRanges
                    )
                    let retryActions: [FeedbackAction]
                    let hasCustomRefspec = !(refspec?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                    if let remote = retryRemote,
                       let branch = retryBranch,
                       !remote.isEmpty,
                       hasCustomRefspec || !branch.isEmpty {
                        retryActions = self.directPushRetryActions(
                            rootPath: rootPath,
                            remote: remote,
                            branch: branch,
                            force: force,
                            forceWithLease: forceWithLease,
                            setUpstream: setUpstream,
                            refspec: refspec,
                            tagMode: tagMode,
                            skipHooks: skipHooks,
                            viewCommitRanges: viewCommitRanges,
                            includeForce: false
                        )
                    } else {
                        retryActions = []
                    }
                    self.feedbackCenter.error(
                        "Push failed",
                        detail: "\(rootPath): \(friendlyRemoteError(error))",
                        nextStep: "Check the selected remote, refspec, credentials, and protected-branch settings.",
                        additionalActions: retryActions
                            + (viewCommitsAction.map { [$0] } ?? [])
                            + [self.showOperationDetailsAction(notificationID: notificationID)],
                        notificationID: notificationID,
                        notificationGroup: .important
                    )
                }
                if self.isAuthenticationFailure(error) {
                    self.hostingWorkspace.showHostingAuthPrompt = true
                }
            }
        }
    }
}

func doPush(
    _ name: String? = nil,
    branch requestedBranch: String? = nil,
    force requestedForce: Bool? = nil,
    forceWithLease requestedForceWithLease: Bool? = nil,
    setUpstream: Bool = false,
    refspec: String? = nil,
    tagMode: PushDialogTagMode? = nil,
    skipHooks: Bool = false,
    viewCommitRanges: [PersistedLogRevisionRange] = [],
    afterCommit: Bool = false
) {
    guard let repo else { return }
    guard let remote = resolveSelectedRemoteName(
        selectedRemote: name,
        availableRemoteNames: remoteWorkspace.remotes.map(\.name)
    ) else {
        feedbackCenter.warning(
            "Choose a remote before pushing",
            detail: remoteWorkspace.remotes.count > 1
                ? "Multiple remotes are configured for this Git root."
                : "No usable remote is configured for this Git root."
        )
        return
    }
    let branch = requestedBranch ?? branchWorkspace.branches.first { $0.isCurrent }?.name ?? "main"
    let force = (requestedForce ?? pushWorkspace.force) || PushDialogRefspec.requestsForce(refspec)
    let useForceWithLease = GitPushSettings.useForceWithLease(force: force, requested: requestedForceWithLease)
    let protectedTarget = PushDialogRefspec.targetBranch(refspec) ?? branch
    if force,
       GitProtectedBranchRules.matches(
           protectedTarget,
           patterns: effectiveProtectedBranchPatterns
       ) {
        feedbackCenter.error(
            "Force push blocked",
            detail: "\(protectedTarget) is protected by Git settings.",
            nextStep: "Edit Protected Branches in Settings or use a non-force push."
        )
        return
    }
    let cancel = GitCancelHandle()
    let notificationID = pushNotificationID(rootPath: repo.workdir() ?? "current")
    let rootPath = repo.workdir()
    beginFeedbackOperation("Push", cancelHandle: cancel, notificationID: notificationID)
    let currentBranchForPush = currentBranchName
    let publish = setUpstream
        || (branch == currentBranchForPush && currentSyncStatus?.trackingExists == false)
    let broker = credentialAuth.broker
    let engineTagMode = tagMode.map { mode in
        switch mode {
        case .all: PushTagMode.all
        case .currentBranch: PushTagMode.follow
        }
    }
    Task.detached(priority: .userInitiated) {
        let initialViewCommitRanges: [PersistedLogRevisionRange] = {
            guard viewCommitRanges.isEmpty,
                  refspec == nil,
                  branch == currentBranchForPush,
                  let rootPath = repo.workdir() else {
                return viewCommitRanges
            }
            return Self.multiRootPushRevisionRanges(for: [rootPath], remote: remote)
        }()
        do {
            if let refspec, !refspec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if engineTagMode != nil || skipHooks {
                    try repo.pushRefspecWithOptionsAndAuthAndCancel(
                        remote: remote,
                        refspec: refspec,
                        force: force,
                        forceWithLease: useForceWithLease,
                        tagMode: engineTagMode,
                        skipHooks: skipHooks,
                        broker: broker,
                        cancel: cancel
                    )
                } else {
                    try repo.pushRefspecWithAuthAndCancel(
                        remote: remote,
                        refspec: refspec,
                        force: force,
                        forceWithLease: useForceWithLease,
                        broker: broker,
                        cancel: cancel
                    )
                }
            } else {
                try repo.pushWithOptionsAndAuthAndCancel(
                    remote: remote,
                    branch: branch,
                    force: force,
                    forceWithLease: useForceWithLease,
                    setUpstream: publish,
                    tagMode: engineTagMode,
                    skipHooks: skipHooks,
                    broker: broker,
                    cancel: cancel
                )
            }
            let lfsCoverageWarning = lfsPushCoverageWarning(repo: repo, skipHooks: skipHooks)
            await MainActor.run {
                self.mergeWorkspace.feedback = "push 完成"
                self.feedbackCenter.success(
                    "Push completed",
                    detail: "\(remote)/\(branch)",
                    additionalActions: self.multiRootUpdateViewCommitsAction(
                        ranges: initialViewCommitRanges
                    ).map { [$0] } ?? [],
                    notificationID: notificationID
                )
                if let lfsCoverageWarning {
                    self.feedbackCenter.warning(
                        "Git LFS objects were not uploaded",
                        detail: lfsCoverageWarning,
                        nextStep: "在 Git LFS 面板安装 hooks，或手动执行 Push LFS objects。"
                    )
                }
                self.autoOpenUpdateInfoIfEnabled(initialViewCommitRanges)
                self.loadRepoData()
            }
        } catch {
            await MainActor.run {
                let detail = friendlyRemoteError(error)
                self.mergeWorkspace.feedback = detail
                if let stale = stalePushRejectionDetails(error) {
                    if let rootPath {
                        let actions = self.directPushRetryActions(
                            rootPath: rootPath,
                            remote: stale.remote,
                            branch: stale.branch,
                            force: force,
                            forceWithLease: useForceWithLease,
                            setUpstream: publish,
                            refspec: refspec,
                            tagMode: tagMode,
                            skipHooks: skipHooks,
                            viewCommitRanges: initialViewCommitRanges,
                            includeForce: true
                        ) + (self.multiRootUpdateViewCommitsAction(
                            ranges: initialViewCommitRanges
                        ).map { [$0] } ?? []) + [
                            self.showOperationDetailsAction(notificationID: notificationID)
                        ]
                        self.feedbackCenter.warning(
                            afterCommit
                                ? "Commit completed; Push rejected by force-with-lease"
                                : "Push rejected by force-with-lease",
                            detail: "\(stale.remote)/\(stale.branch): \(stale.message)",
                            nextStep: "The remote branch changed after the lease was recorded. Verify the remote history before overwriting it.",
                            additionalActions: actions,
                            notificationID: notificationID,
                            notificationGroup: .important,
                            localized: false
                        )
                    } else {
                        self.feedbackCenter.warning(
                            afterCommit
                                ? "Commit completed; Push rejected by force-with-lease"
                                : "Push rejected by force-with-lease",
                            detail: "\(stale.remote)/\(stale.branch): \(stale.message)",
                            nextStep: "The remote branch changed after the lease was recorded. Verify the remote history before overwriting it.",
                            actionTitle: "Force Push Anyway",
                            action: {
                                self.doPush(
                                    stale.remote,
                                    branch: stale.branch,
                                    force: true,
                                    forceWithLease: false,
                                    setUpstream: publish,
                                    refspec: refspec,
                                    tagMode: tagMode,
                                    skipHooks: skipHooks,
                                    viewCommitRanges: initialViewCommitRanges
                                )
                            },
                            notificationID: notificationID,
                            localized: false
                        )
                    }
                } else {
                    let autoUpdate = gitPushAutoUpdateIsEligible(
                        enabled: GitPushAutoUpdateSettings.value(for: self.projectWorkspace.path),
                        force: force,
                        refspec: refspec,
                        currentBranch: currentBranchForPush,
                        rejectedBranch: branch,
                        hasTracking: self.currentSyncStatus?.trackingExists == true
                    )
                    if autoUpdate, let rootPath {
                        self.updateRootForPushRecovery(
                            rootPath: rootPath,
                            remote: remote,
                            branch: branch,
                            force: force,
                            forceWithLease: useForceWithLease,
                            setUpstream: publish,
                            refspec: nil,
                            tagMode: tagMode,
                            skipHooks: skipHooks,
                            rebase: GitUpdateMethodSettings.method(for: self.projectWorkspace.path) == .rebase,
                            viewCommitRanges: initialViewCommitRanges
                        )
                    } else {
                        let retryActions: [FeedbackAction] = rootPath.map { path in
                            self.directPushRetryActions(
                                rootPath: path,
                                remote: remote,
                                branch: branch,
                                force: force,
                                forceWithLease: useForceWithLease,
                                setUpstream: publish,
                                refspec: refspec,
                                tagMode: tagMode,
                                skipHooks: skipHooks,
                                viewCommitRanges: initialViewCommitRanges,
                                includeForce: false
                            )
                        } ?? []
                        let detailAction = self.showOperationDetailsAction(notificationID: notificationID)
                        self.feedbackCenter.error(
                            "Push failed",
                            detail: detail,
                            nextStep: "Check the remote, upstream, and credentials, then retry.",
                            additionalActions: retryActions + [detailAction],
                            notificationID: notificationID,
                            notificationGroup: .important
                        )
                        self.offerPushRecovery(
                            error,
                            remote: remote,
                            branch: branch,
                            force: force,
                            forceWithLease: useForceWithLease,
                            setUpstream: publish,
                            refspec: refspec,
                            tagMode: tagMode,
                            afterCommit: afterCommit,
                            viewCommitRanges: initialViewCommitRanges
                        )
                    }
                }
                if self.isAuthenticationFailure(error) { self.hostingWorkspace.showHostingAuthPrompt = true }
            }
        }
    }
}

}
