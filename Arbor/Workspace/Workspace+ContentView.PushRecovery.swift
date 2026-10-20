import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

func singleRootPushRecoveryRequest(
    rootPath: String,
    recovery: PersistedPushRecovery,
    viewCommitRanges: [PersistedLogRevisionRange] = []
) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: .retryPushRecovery,
        projectPath: projectWorkspace.path,
        rootPath: rootPath,
        shelfName: "",
        pushRecovery: recovery,
        logRevisionRanges: viewCommitRanges.isEmpty ? nil : viewCommitRanges
    )
}

func directPushRetryActions(
    rootPath: String,
    remote: String,
    branch: String,
    force: Bool,
    forceWithLease: Bool,
    setUpstream: Bool,
    refspec: String?,
    tagMode: PushDialogTagMode?,
    skipHooks: Bool,
    viewCommitRanges: [PersistedLogRevisionRange] = [],
    includeForce: Bool
) -> [FeedbackAction] {
    let retryRequest = singleRootPushRequest(
        rootPath: rootPath,
        remote: remote,
        branch: branch,
        force: force,
        forceWithLease: forceWithLease,
        setUpstream: setUpstream,
        refspec: refspec,
        tagMode: tagMode,
        skipHooks: skipHooks,
        viewCommitRanges: viewCommitRanges
    )
    var actions = [FeedbackAction]()
    if includeForce {
        let forceRequest = singleRootPushRequest(
            rootPath: rootPath,
            remote: remote,
            branch: branch,
            force: true,
            forceWithLease: false,
            setUpstream: setUpstream,
            refspec: refspec,
            tagMode: tagMode,
            skipHooks: skipHooks,
            viewCommitRanges: viewCommitRanges
        )
        actions.append(
            FeedbackAction(title: "Force Push Anyway", semanticAction: forceRequest) {
                self.handleVCSActionRequest(forceRequest)
            }
        )
    }
    actions.append(
        FeedbackAction(title: "Retry Push", semanticAction: retryRequest) {
            self.handleVCSActionRequest(retryRequest)
        }
    )
    return actions
}

/// Retry the original Push itself after a rejected or transport failure. The
/// root, remote, branch, refspec and force policy are persisted; only the
/// current Git state is revalidated before starting the command.
func retrySingleRootPush(
    rootPath: String,
    push: PersistedPushRecovery,
    viewCommitRanges: [PersistedLogRevisionRange] = []
) {
    let hasCustomRefspec = !(push.refspec?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    guard !push.remote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          hasCustomRefspec || !push.branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        feedbackCenter.error(
            "Push retry unavailable",
            detail: "The saved Push request is incomplete; no Git operation was started.",
            nextStep: "Open Push again and retry after selecting a remote and branch.",
            notificationID: pushNotificationID(rootPath: rootPath)
        )
        return
    }
    guard let rootRepo = try? openRepository(path: rootPath) else {
        feedbackCenter.warning(
            "Push retry unavailable",
            detail: "Open the Git root that originally rejected the Push before retrying.",
            nextStep: rootPath,
            notificationID: pushNotificationID(rootPath: rootPath),
            notificationGroup: .important
        )
        return
    }

    Task.detached(priority: .userInitiated) {
        let currentBranch = (try? rootRepo.branchList())?.first(where: { $0.isCurrent })?.name
        let branchIsValid = hasCustomRefspec || currentBranch == push.branch
        await MainActor.run {
            guard branchIsValid else {
                self.feedbackCenter.warning(
                    "Push retry is stale",
                    detail: "The checked-out branch changed. No Push was started.",
                    nextStep: "Switch back to \(push.branch), then retry the Push action.",
                    notificationID: self.pushNotificationID(rootPath: rootPath),
                    notificationGroup: .important
                )
                return
            }
            self.pushInRoot(
                rootPath: rootPath,
                remote: push.remote,
                branch: push.branch,
                force: push.force,
                forceWithLease: push.forceWithLease,
                setUpstream: push.setUpstream,
                refspec: push.refspec,
                tagMode: push.tagModeRaw.flatMap(PushDialogTagMode.init(rawValue:)),
                skipHooks: push.skipHooks,
                viewCommitRanges: viewCommitRanges
            )
        }
    }
}

/// Resume the rejected-push follow-up only when the original Git root and
/// checked-out branch are still active. IntelliJ's notification action is
/// bound to the Push operation; silently applying it to a different branch
/// after relaunch would be materially unsafe.
func retrySingleRootPushRecovery(
    rootPath: String,
    recovery: PersistedPushRecovery,
    viewCommitRanges: [PersistedLogRevisionRange] = []
) {
    guard !recovery.remote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !recovery.branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        feedbackCenter.error(
            "Push recovery unavailable",
            detail: "The saved Push recovery request is incomplete; no Git operation was started.",
            nextStep: "Open Push again and retry after selecting a remote and branch.",
            notificationID: pushNotificationID(rootPath: rootPath)
        )
        return
    }
    guard let activeRepo = repo,
          let activePath = activeRepo.workdir(),
          URL(fileURLWithPath: activePath).standardizedFileURL.path
              == URL(fileURLWithPath: rootPath).standardizedFileURL.path else {
        feedbackCenter.warning(
            "Push recovery unavailable",
            detail: "Open the Git root that originally rejected the Push before retrying.",
            nextStep: rootPath,
            notificationID: pushNotificationID(rootPath: rootPath),
            notificationGroup: .important
        )
        return
    }

    let expectedBranch = recovery.branch
    Task.detached(priority: .userInitiated) {
        let currentBranch = (try? activeRepo.branchList())?.first(where: { $0.isCurrent })?.name
        let trackingExists = (try? activeRepo.syncStatus())?
            .first(where: { $0.branch == expectedBranch })?
            .trackingExists == true
        await MainActor.run {
            guard currentBranch == expectedBranch, trackingExists else {
                self.feedbackCenter.warning(
                    "Push recovery is stale",
                    detail: "The repository branch or its configured upstream changed. No update or push was started.",
                    nextStep: "Switch back to \(expectedBranch) and restore its upstream, then retry the Push recovery action.",
                    notificationID: self.pushNotificationID(rootPath: rootPath),
                    notificationGroup: .important
                )
                return
            }
            // Keep the recovery as one root-scoped compound operation. The
            // generic doPull/doPush path owns separate global operation
            // lifecycles and would lose the original Push notification and
            // root context when update pauses for conflicts.
            self.updateRootForPushRecovery(
                rootPath: rootPath,
                remote: recovery.remote,
                branch: recovery.branch,
                force: recovery.force,
                forceWithLease: recovery.forceWithLease,
                setUpstream: recovery.setUpstream,
                refspec: nil,
                tagMode: recovery.tagModeRaw.flatMap(PushDialogTagMode.init(rawValue:)),
                skipHooks: recovery.skipHooks,
                rebase: recovery.rebase,
                viewCommitRanges: viewCommitRanges
            )
        }
    }
}

/// Root-scoped recovery for a rejected push. The selected nested repository is
/// updated directly; it never falls back to the superproject's current repo.
/// A clean update proceeds straight to the original push, while an update
/// conflict stays in the existing project-level resolver with a Resolve action.
func updateRootForPushRecovery(
    rootPath: String,
    remote: String,
    branch: String,
    force: Bool,
    forceWithLease: Bool,
    setUpstream: Bool,
    refspec: String?,
    tagMode: PushDialogTagMode?,
    skipHooks: Bool,
    rebase: Bool,
    viewCommitRanges: [PersistedLogRevisionRange] = []
) {
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    let notificationID = pushNotificationID(rootPath: rootPath)
    beginFeedbackOperation(
        rebase ? "Update root with rebase" : "Update root with merge",
        cancelHandle: cancel,
        notificationID: notificationID
    )
    let fetchTagMode = fetchTagsMode
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    Task.detached(priority: .userInitiated) {
        let previousHeads = Self.headCommitIDs(for: [rootPath])
        do {
            let result = try runRootUpdateForPushRecoveryWithOptions(
                rootPath: rootPath,
                remote: remote,
                branch: branch,
                rebase: rebase,
                tagMode: fetchTagMode,
                broker: broker,
                cancel: cancel,
                savePolicy: projectSavePolicy
            )
            let currentHeads = Self.headCommitIDs(for: [rootPath])
            let latestViewCommitRanges = result.success && !result.skipped
                ? Self.updateSessionRevisionRanges(
                    previousHeads: previousHeads,
                    currentHeads: currentHeads,
                    results: [result]
                )
                : []
            let combinedViewCommitRanges = Self.joinedRevisionRanges(
                existing: viewCommitRanges,
                latest: latestViewCommitRanges
            )
            await MainActor.run {
                self.loadMultiRoots()
                let existingViewCommitsAction = self.multiRootUpdateViewCommitsAction(
                    ranges: viewCommitRanges
                )
                if result.success && !result.skipped {
                    self.feedbackCenter.success(
                        "Root updated; retrying Push",
                        detail: "\(rootPath): \(remote)/\(branch)",
                        notificationID: notificationID
                    )
                    self.pushInRoot(
                        rootPath: rootPath,
                        remote: remote,
                        branch: branch,
                        force: force,
                        forceWithLease: forceWithLease,
                        setUpstream: setUpstream,
                        refspec: refspec,
                        tagMode: tagMode,
                        skipHooks: skipHooks,
                        viewCommitRanges: combinedViewCommitRanges
                    )
                } else if result.skipped {
                    self.feedbackCenter.warning(
                        "Push update cancelled",
                        detail: "\(rootPath): \(result.message)",
                        nextStep: "Retry the root-scoped update when the worktree is ready.",
                        actionTitle: "Retry Update",
                        action: {
                            self.updateRootForPushRecovery(
                                rootPath: rootPath,
                                remote: remote,
                                branch: branch,
                                force: force,
                                forceWithLease: forceWithLease,
                                setUpstream: setUpstream,
                                refspec: refspec,
                                tagMode: tagMode,
                                skipHooks: skipHooks,
                                rebase: rebase,
                                viewCommitRanges: viewCommitRanges
                            )
                        },
                        additionalActions: existingViewCommitsAction.map { [$0] } ?? [],
                        notificationID: notificationID,
                        localized: false
                    )
                } else if result.message.localizedCaseInsensitiveContains("conflict")
                            || result.message.localizedCaseInsensitiveContains("operation is already in progress") {
                    self.feedbackCenter.warning(
                        "Push update paused for conflicts",
                        detail: "\(rootPath): \(result.message)",
                        nextStep: "Resolve the files in this Git root, then continue the operation.",
                        actionTitle: "Resolve Conflicts",
                        action: {
                            self.openMultiRootConflictResolver(preferredRootPath: rootPath)
                        },
                        additionalActions: existingViewCommitsAction.map { [$0] } ?? [],
                        notificationID: notificationID,
                        localized: false
                    )
                } else {
                    self.feedbackCenter.error(
                        "Push update failed",
                        detail: "\(rootPath): \(result.message)",
                        nextStep: "Resolve the update error, then retry the root-scoped update.",
                        actionTitle: "Retry Update",
                        action: {
                            self.updateRootForPushRecovery(
                                rootPath: rootPath,
                                remote: remote,
                                branch: branch,
                                force: force,
                                forceWithLease: forceWithLease,
                                setUpstream: setUpstream,
                                refspec: refspec,
                                tagMode: tagMode,
                                skipHooks: skipHooks,
                                rebase: rebase,
                                viewCommitRanges: viewCommitRanges
                            )
                        },
                        additionalActions: existingViewCommitsAction.map { [$0] } ?? [],
                        notificationID: notificationID,
                        localized: false
                    )
                }
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                let existingViewCommitsAction = self.multiRootUpdateViewCommitsAction(
                    ranges: viewCommitRanges
                )
                self.feedbackCenter.error(
                    "Push update failed",
                    detail: "\(rootPath): \(friendlyRemoteError(error))",
                    nextStep: "Resolve the update error, then retry the root-scoped update.",
                    actionTitle: "Retry Update",
                    action: {
                        self.updateRootForPushRecovery(
                            rootPath: rootPath,
                            remote: remote,
                            branch: branch,
                            force: force,
                            forceWithLease: forceWithLease,
                            setUpstream: setUpstream,
                            refspec: refspec,
                            tagMode: tagMode,
                            skipHooks: skipHooks,
                            rebase: rebase,
                            viewCommitRanges: viewCommitRanges
                        )
                    },
                    additionalActions: existingViewCommitsAction.map { [$0] } ?? [],
                    notificationID: notificationID
                )
            }
        }
    }
}

/// Rebased 的 rejected push 引导：只对 non-fast-forward 提供 Merge/Rebase，
/// 不把 force push 当成修复建议；Publish Branch 则由 Push 对话框的 upstream 开关完成。
func offerPushRecovery(
    _ error: Error,
    remote: String?,
    branch: String?,
    force: Bool,
    forceWithLease: Bool = false,
    setUpstream: Bool,
    refspec: String? = nil,
    tagMode: PushDialogTagMode? = nil,
    skipHooks: Bool = false,
    afterCommit: Bool = false,
    viewCommitRanges: [PersistedLogRevisionRange] = []
) {
    // A detached/custom source cannot be repaired by pulling the checked-out
    // branch and retrying it. The caller must rebuild that source against the
    // newly fetched remote tip instead of silently pushing the wrong ref.
    guard refspec == nil else { return }
    guard case let .PushRejected(kind, remote, branch, _) = error as? EngineError,
          kind == .nonFastForward else { return }
    // Match GitPushOperation.pushingToNotTrackedBranch and
    // pushingNotCurrentBranch: updating the checked-out branch is only a
    // valid repair when the rejected push came from that branch's tracked
    // upstream. A custom/non-current push must remain a plain rejection.
    guard currentBranchName == branch,
          currentSyncStatus?.trackingExists == true else { return }
    guard let rootPath = repo?.workdir() else { return }
    let recovery = PersistedPushRecovery(
        remote: remote,
        branch: branch,
        force: force,
        forceWithLease: forceWithLease,
        setUpstream: setUpstream,
        tagModeRaw: tagMode?.rawValue,
        skipHooks: skipHooks,
        rebase: false
    )
    let mergeRequest = singleRootPushRecoveryRequest(
        rootPath: rootPath,
        recovery: recovery,
        viewCommitRanges: viewCommitRanges
    )
    let rebaseRequest = singleRootPushRecoveryRequest(
        rootPath: rootPath,
        recovery: PersistedPushRecovery(
            remote: recovery.remote,
            branch: recovery.branch,
            force: recovery.force,
            forceWithLease: recovery.forceWithLease,
            setUpstream: recovery.setUpstream,
            tagModeRaw: recovery.tagModeRaw,
            skipHooks: recovery.skipHooks,
            rebase: true
        ),
        viewCommitRanges: viewCommitRanges
    )
    let notificationID = pushNotificationID(rootPath: rootPath)
    let recoveryActions = [
        FeedbackAction(title: "Update with Merge", semanticAction: mergeRequest) {
            self.handleVCSActionRequest(mergeRequest)
        },
        FeedbackAction(title: "Update with Rebase", semanticAction: rebaseRequest) {
            self.handleVCSActionRequest(rebaseRequest)
        }
    ] + self.directPushRetryActions(
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
    ) + (self.multiRootUpdateViewCommitsAction(ranges: viewCommitRanges).map { [$0] } ?? [])
        + [self.showOperationDetailsAction(notificationID: notificationID)]
    feedbackCenter.warning(
        afterCommit ? "Commit completed; Push rejected" : "Push rejected",
        detail: "Remote branch \(remote)/\(branch) has commits that are not local.",
        nextStep: "Update the checked-out branch, then retry Push.",
        additionalActions: recoveryActions,
        notificationID: notificationID,
        notificationGroup: .important
    )
}

}
