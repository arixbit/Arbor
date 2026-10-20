import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

func logApplyRecoveryNotificationID(rootPath: String) -> String {
    let stableRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.log-apply-recovery.\(stableRoot)"
}

func logApplyRecoveryTitle(
    _ operation: PersistedLogApplyRecovery.Operation
) -> String {
    switch operation {
    case .cherryPick: "Cherry-pick"
    case .revert: "Revert"
    }
}

func logApplyRecoveryAction(
    _ recovery: PersistedLogApplyRecovery
) -> FeedbackAction {
    let request = ArborVCSActionRequest(
        kind: .retryLogApply,
        projectPath: projectWorkspace.path,
        rootPath: recovery.rootPath,
        shelfName: "",
        logApplyRecovery: recovery
    )
    return FeedbackAction(
        title: logApplyRecoveryActionTitle(recovery),
        semanticAction: request
    ) {
        self.handleVCSActionRequest(request)
    }
}

func logApplyAffectedFilesAction(
    _ recovery: PersistedLogApplyRecovery
) -> FeedbackAction? {
    guard !recovery.affectedPaths.isEmpty else { return nil }
    let request = ArborVCSActionRequest(
        kind: .showLogApplyAffectedFiles,
        projectPath: projectWorkspace.path,
        rootPath: recovery.rootPath,
        shelfName: "",
        logApplyRecovery: recovery
    )
    return FeedbackAction(title: "Show Files", semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

func logApplyRecoveryActions(
    _ recovery: PersistedLogApplyRecovery
) -> [FeedbackAction] {
    [logApplyAffectedFilesAction(recovery), logApplyRecoveryAction(recovery)]
        .compactMap { $0 }
}

func logApplyRecoveryFingerprint(
    _ recovery: PersistedLogApplyRecovery
) -> String {
    [
        recovery.operation.rawValue,
        recovery.rootPath,
        recovery.sessionID,
        String(recovery.batchIndex),
        String(recovery.batchCount),
        recovery.initialHead,
        recovery.commitIDs.joined(separator: "\u{1f}"),
        recovery.preserveLocalChanges ? "preserve" : "direct",
        recovery.emptyPolicyRaw,
        recovery.appendPublishedSuffix ? "suffix" : "no-suffix",
        recovery.savePolicyRaw,
        recovery.affectedPaths.joined(separator: "\u{1f}")
    ].joined(separator: "\u{1e}")
}

func nextLogApplyRecovery(
    after completed: PersistedLogApplyRecovery
) -> PersistedLogApplyRecovery? {
    pendingLogApplyRecoveries(sessionID: completed.sessionID).first {
        $0.operation == completed.operation
            && $0.batchCount == completed.batchCount
            && $0.batchIndex == completed.batchIndex + 1
    }
}

func retryNextLogApplyRoot(
    after completed: PersistedLogApplyRecovery
) {
    guard let nextRecovery = nextLogApplyRecovery(after: completed) else { return }
    retryLogApplyRecovery(nextRecovery, automatic: true)
}

func publishLogApplyRecoveryNoticeIfNeeded(rootPath: String) -> Bool {
    let normalizedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
    guard let recovery = loadLogApplyRecovery(repositoryPath: normalizedRoot),
          recovery.rootPath == normalizedRoot,
          !recovery.commitIDs.isEmpty,
          !recovery.initialHead.isEmpty else {
        feedbackCenter.expire(notificationID: logApplyRecoveryNotificationID(rootPath: normalizedRoot))
        logSelectionState.applyRecoveryNotificationFingerprints.removeValue(
            forKey: operationRecoveryNotificationRootKey(normalizedRoot)
        )
        return false
    }
    let key = operationRecoveryNotificationRootKey(normalizedRoot)
    let fingerprint = logApplyRecoveryFingerprint(recovery)
    guard logSelectionState.applyRecoveryNotificationFingerprints[key] != fingerprint else { return true }
    let title = logApplyRecoveryTitle(recovery.operation)
    if recovery.preserveLocalChanges, !recovery.affectedPaths.isEmpty {
        feedbackCenter.error(
            "\(title) failed",
            detail: "Local changes would be overwritten: \(recovery.affectedPaths.joined(separator: ", ")).",
            nextStep: "Show the affected files or choose \(logApplyRecoveryActionTitle(recovery)).",
            additionalActions: logApplyRecoveryActions(recovery),
            notificationID: logApplyRecoveryNotificationID(rootPath: normalizedRoot),
            notificationGroup: .important,
            localized: false
        )
    } else {
        feedbackCenter.warning(
            "\(title) recovery available",
            detail: "A previous Log \(title) action was interrupted before its final result was recorded.",
            nextStep: "Retry is allowed only while the repository HEAD remains \(String(recovery.initialHead.prefix(7))).",
            additionalActions: logApplyRecoveryActions(recovery),
            notificationID: logApplyRecoveryNotificationID(rootPath: normalizedRoot),
            notificationGroup: .important,
            localized: false
        )
    }
    logSelectionState.applyRecoveryNotificationFingerprints[key] = fingerprint
    return true
}

func retryLogApplyRecovery(
    _ requestedRecovery: PersistedLogApplyRecovery,
    automatic: Bool = false
) {
    guard let recovery = loadLogApplyRecovery(repositoryPath: requestedRecovery.rootPath),
          recovery == requestedRecovery else {
        feedbackCenter.warning(
            "Retry unavailable",
            detail: "The saved Log operation is no longer pending.",
            nextStep: "Refresh the Log and select the commits again."
        )
        return
    }
    let normalizedRoot = URL(fileURLWithPath: recovery.rootPath).standardizedFileURL.path
    guard recovery.rootPath == normalizedRoot,
          !recovery.commitIDs.isEmpty,
          !recovery.initialHead.isEmpty else {
        feedbackCenter.warning(
            "Retry unavailable",
            detail: "The saved Log operation context is incomplete."
        )
        return
    }
    let pendingRecoveries = pendingLogApplyRecoveries(sessionID: recovery.sessionID)
    if let firstPending = pendingRecoveries.first,
       !logApplyRecoveryCanRun(recovery, pending: pendingRecoveries) {
        feedbackCenter.warning(
            "Retry unavailable",
            detail: "An earlier Git root in this Log operation is still pending.",
            nextStep: "Complete or retry root \(firstPending.batchIndex + 1) before continuing this root."
        )
        return
    }
    guard let targetRepo = try? openRepository(path: normalizedRoot) else {
        feedbackCenter.warning(
            "Retry unavailable",
            detail: "The saved Git root could not be opened.",
            nextStep: "Refresh Git Roots, then retry from the recovery notification."
        )
        return
    }
    do {
        guard try targetRepo.operationState() == nil else {
            feedbackCenter.warning(
                "Retry unavailable",
                detail: "This repository still has an active Git operation.",
                nextStep: "Continue or Abort the active operation first."
            )
            return
        }
    } catch {
        feedbackCenter.warning(
            "Retry unavailable",
            detail: "The current Git operation state could not be read.",
            nextStep: "Refresh Git Roots, then retry when the repository is readable."
        )
        return
    }
    guard targetRepo.headCommitId() == recovery.initialHead else {
        clearLogApplyRecovery(repositoryPath: normalizedRoot)
        feedbackCenter.expire(notificationID: logApplyRecoveryNotificationID(rootPath: normalizedRoot))
        logSelectionState.applyRecoveryNotificationFingerprints.removeValue(
            forKey: operationRecoveryNotificationRootKey(normalizedRoot)
        )
        feedbackCenter.warning(
            "Retry refused",
            detail: "The repository HEAD changed after the interrupted Log operation.",
            nextStep: "Re-select the commits from the current Log instead of replaying the old action."
        )
        return
    }

    let operation: LogApplyOperation = recovery.operation == .cherryPick
        ? .cherryPick
        : .revert
    let emptyPolicy = GitCherryPickEmptyPolicyChoice(rawValue: recovery.emptyPolicyRaw)
        ?? GitCherryPickSettings.defaultEmptyPolicy
    let savePolicy = GitLocalChangesSavePolicyChoice(rawValue: recovery.savePolicyRaw)
        ?? GitLocalChangesSavePolicySettings.defaultPolicy
    beginFeedbackOperation(logApplyRecoveryTitle(recovery.operation))
    Task.detached(priority: .userInitiated) {
        do {
            let resultID = try executeLogApply(
                operation: operation,
                repo: targetRepo,
                commitIDs: recovery.commitIDs,
                emptyPolicy: emptyPolicy.engineValue,
                appendPublishedSuffix: recovery.appendPublishedSuffix,
                preserveLocalChanges: recovery.preserveLocalChanges,
                savePolicy: savePolicy.engineValue
            )
            clearLogApplyRecovery(repositoryPath: normalizedRoot)
            await MainActor.run {
                self.logSelectionState.applyRecoveryNotificationFingerprints.removeValue(
                    forKey: operationRecoveryNotificationRootKey(normalizedRoot)
                )
                self.feedbackCenter.expire(
                    notificationID: self.logApplyRecoveryNotificationID(rootPath: normalizedRoot)
                )
                let nextRecovery = self.nextLogApplyRecovery(after: recovery)
                self.feedbackCenter.success(
                    automatic || nextRecovery != nil
                        ? "\(logApplyRecoveryTitle(recovery.operation)) root completed"
                        : "\(logApplyRecoveryTitle(recovery.operation)) retried",
                    detail: nextRecovery == nil
                        ? "\(normalizedRoot): \(String(resultID.prefix(7)))"
                        : "\(normalizedRoot): \(String(resultID.prefix(7))). Continuing the next Git root."
                )
                self.refreshAll(showFeedback: false)
                if let nextRecovery {
                    self.retryLogApplyRecovery(nextRecovery, automatic: true)
                }
            }
        } catch {
            let latestState = try? targetRepo.operationState()
            await MainActor.run {
                self.refreshAll(showFeedback: false)
                if let latestState, let rootPath = targetRepo.workdir() {
                    self.operationRecovery.operation = latestState
                    self.publishOperationRecoveryNoticeIfNeeded(
                        state: latestState,
                        rootPath: rootPath
                    )
                } else {
                    self.feedbackCenter.error(
                        "\(logApplyRecoveryTitle(recovery.operation)) retry failed",
                        detail: errorMessage(error),
                        nextStep: "Review the current root, then retry the saved Log action.",
                        additionalActions: [self.logApplyRecoveryAction(recovery)],
                        notificationID: self.logApplyRecoveryNotificationID(rootPath: normalizedRoot)
                    )
                }
            }
        }
    }
}

func showLogApplyAffectedFiles(
    _ recovery: PersistedLogApplyRecovery
) {
    guard let persisted = loadLogApplyRecovery(repositoryPath: recovery.rootPath),
          persisted == recovery,
          !recovery.affectedPaths.isEmpty else {
        feedbackCenter.warning(
            "Show Files unavailable",
            detail: "The Log operation is no longer pending.",
            nextStep: "Refresh the Log and select the commits again."
        )
        return
    }

    let rootPath = URL(fileURLWithPath: recovery.rootPath).standardizedFileURL.path
    let preferredPath = recovery.affectedPaths.first
    projectWorkspace.toolWindowMode = .commit
    toolWindowExpanded = true
    let currentRootMatches = repo?.workdir().map {
        URL(fileURLWithPath: $0).standardizedFileURL.path == rootPath
    } == true
    guard currentRootMatches, let activeRepo = repo else {
        openMultiRootConflictResolver(
            preferredRootPath: rootPath,
            preferredPath: preferredPath
        )
        return
    }

    fileWorkspace.selection = preferredPath
    fileWorkspace.fileSelection = nil
    fileWorkspace.selectionModePath = nil
    fileWorkspace.previewPath = nil
    fileWorkspace.previewVisible = false
    Task.detached(priority: .userInitiated) {
        let status = (try? activeRepo.status()) ?? []
        await MainActor.run {
            guard self.repo === activeRepo else { return }
            self.repositoryStatus.entries = status
            self.fileWorkspace.selection = status.first(where: {
                recovery.affectedPaths.contains($0.path)
            })?.path ?? preferredPath
        }
    }
}

}
