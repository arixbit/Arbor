import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

func handleMultiRootRebaseRecovery(
    rootPath: String,
    action: MultiRootRecoveryAction,
    operationStillActive: Bool,
    sessionID: UUID
) {
    guard var session = rebaseWorkspace.multiRootSession, session.id == sessionID,
          let index = session.roots.firstIndex(where: { $0.rootPath == rootPath }) else { return }
    var root = session.roots[index]
    if operationStillActive {
        root.state = .paused
        root.message = "rebase remains paused"
        session.roots[index] = root
        rebaseWorkspace.multiRootSession = session
        saveMultiRootRebaseSession(session)
        return
    }

    switch action {
    case .continueOperation, .skip:
        root.state = .completed
        root.message = action == .skip ? "rebase step skipped and root completed" : "rebase completed"
        session.roots[index] = root
        rebaseWorkspace.multiRootSession = session
        saveMultiRootRebaseSession(session)
        if session.roots.contains(where: { $0.state == .pending }) {
            feedbackCenter.success("Rebase root completed", detail: "Starting the next repository.")
            runPendingMultiRootRebase(session)
        } else {
            clearMultiRootRebaseSession(session)
            rebaseWorkspace.multiRootSession = nil
            feedbackCenter.success("Multi-root rebase completed", detail: session.projectPath)
        }
    case .abort:
        root.state = .aborted
        root.message = "rebase aborted"
        session.roots[index] = root
        rebaseWorkspace.multiRootSession = session
        saveMultiRootRebaseSession(session)
        let targets = multiRootRebaseRollbackTargets(for: session)
        let failures = session.roots
            .filter { $0.state == .failed || $0.state == .aborted || $0.state == .pending }
            .map { "\($0.displayName): \($0.message)" }
        if targets.isEmpty {
            clearMultiRootRebaseSession(session)
            rebaseWorkspace.multiRootSession = nil
            feedbackCenter.warning("Multi-root rebase aborted", detail: failures.joined(separator: "\n"))
        } else {
            rebaseWorkspace.multiRootRollbackContext = MultiRootRebaseRollbackContext(
                sessionID: session.id,
                branch: root.branch,
                targets: targets,
                failures: failures
            )
            feedbackCenter.warning(
                "Multi-root rebase partially completed",
                detail: failures.joined(separator: "\n"),
                nextStep: "Choose whether to rollback the successful repositories or keep the partial state.",
                additionalActions: [
                    multiRootRebaseRecoveryFeedbackAction(
                        .rollback,
                        sessionID: session.id
                    ),
                    multiRootRebaseRecoveryFeedbackAction(
                        .keepPartial,
                        sessionID: session.id
                    )
                ],
                notificationID: multiRootRebaseNotificationID()
            )
        }
    }
}

func rollbackPersistedMultiRootRebase() {
    guard let session = rebaseWorkspace.multiRootSession else { return }
    let targets = multiRootRebaseRollbackTargets(for: session)
    guard !targets.isEmpty else {
        clearMultiRootRebaseSession(session)
        rebaseWorkspace.multiRootSession = nil
        feedbackCenter.warning(
            "Multi-root rebase rollback unavailable",
            detail: "No completed root has an expected HEAD to restore.",
            notificationID: multiRootRebaseNotificationID()
        )
        return
    }
    rebaseWorkspace.multiRootRollbackContext = MultiRootRebaseRollbackContext(
        sessionID: session.id,
        branch: session.roots.first?.branch ?? rebaseWorkspace.branch,
        targets: targets,
        failures: session.roots
            .filter { $0.state == .failed || $0.state == .aborted || $0.state == .pending }
            .map { "\($0.displayName): \($0.message)" }
    )
    rollbackMultiRootRebase(targets)
}

func keepPersistedMultiRootRebasePartial() {
    guard let session = rebaseWorkspace.multiRootSession else { return }
    let context = MultiRootRebaseRollbackContext(
        sessionID: session.id,
        branch: session.roots.first?.branch ?? rebaseWorkspace.branch,
        targets: multiRootRebaseRollbackTargets(for: session),
        failures: session.roots
            .filter { $0.state == .failed || $0.state == .aborted || $0.state == .pending }
            .map { "\($0.displayName): \($0.message)" }
    )
    keepMultiRootRebasePartial(context)
}

func keepMultiRootRebasePartial(_ context: MultiRootRebaseRollbackContext) {
    rebaseWorkspace.multiRootRollbackContext = nil
    if let session = rebaseWorkspace.multiRootSession, session.id == context.sessionID {
        clearMultiRootRebaseSession(session)
        rebaseWorkspace.multiRootSession = nil
    }
    feedbackCenter.warning(
        "Partial rebase kept",
        detail: context.branch,
        nextStep: "Review the affected repositories in Git Roots."
    )
}

func rollbackMultiRootRebase(
    _ targets: [MultiRootRebaseRollbackTarget],
    completionTitle: String = "Multi-root rebase rollback completed"
) {
    guard !targets.isEmpty else { return }
    let context = rebaseWorkspace.multiRootRollbackContext
    rebaseWorkspace.multiRootRollbackContext = nil
    let protectedPatterns = effectiveProtectedBranchPatterns
    let notificationID = multiRootRebaseNotificationID()
    beginFeedbackOperation(
        "Rollback multi-root rebase",
        notificationID: notificationID
    )
    Task.detached(priority: .userInitiated) {
        var failures: [String] = []
        var remaining: [MultiRootRebaseRollbackTarget] = []
        for target in targets {
            do {
                let rootRepo = try openRepository(path: target.rootPath)
                guard try rootRepo.operationState() == nil else {
                    throw NSError(
                        domain: "Arbor.MultiRootRebaseRollback",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "A Git operation is still in progress."]
                    )
                }
                let remoteBranches = try rootRepo.remoteBranchList()
                let protectedCommitID = rebaseUndoProtectionCommit(
                    repo: rootRepo,
                    initialHead: target.initialHead,
                    expectedHead: target.expectedHead,
                    recordedCommitID: target.protectionCommitID
                )
                if let protectedBranch = protectedRemoteBranchContainingCommit(
                    repo: rootRepo,
                    commitID: protectedCommitID,
                    remoteBranches: remoteBranches,
                    protectedPatterns: protectedPatterns
                ) {
                    throw NSError(
                        domain: "Arbor.MultiRootRebaseRollback",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Rollback is blocked: \(protectedBranch) contains published pre-rebase history."
                        ]
                    )
                }
                try rootRepo.restoreBranchIfExpected(
                    branch: target.branch,
                    initialCommitId: target.initialHead,
                    expectedCommitId: target.expectedHead
                )
            } catch {
                failures.append("\(target.displayName): \(errorMessage(error))")
                remaining.append(target)
            }
        }
        let rollbackFailures = failures
        let rollbackRemaining = remaining
        await MainActor.run {
            self.loadMultiRoots()
            if rollbackFailures.isEmpty {
                if let session = self.rebaseWorkspace.multiRootSession {
                    clearMultiRootRebaseSession(session)
                }
                self.rebaseWorkspace.multiRootSession = nil
                if let notificationID {
                    self.feedbackCenter.expire(notificationID: notificationID)
                }
                self.feedbackCenter.success(completionTitle)
            } else {
                self.feedbackCenter.warning(
                    "Multi-root rebase rollback partially failed",
                    detail: rollbackFailures.joined(separator: "\n"),
                    nextStep: "Review the affected repositories and retry the remaining rollback targets.",
                    additionalActions: rollbackRemaining.isEmpty
                        ? []
                        : [
                            self.multiRootRebaseRecoveryFeedbackAction(
                                .undo,
                                rollbackTargets: rollbackRemaining
                            )
                        ],
                    notificationID: notificationID
                )
                if let context {
                    self.rebaseWorkspace.multiRootRollbackContext = MultiRootRebaseRollbackContext(
                        sessionID: context.sessionID,
                        branch: context.branch,
                        targets: rollbackRemaining,
                        failures: rollbackFailures
                    )
                }
            }
        }
    }
}

}
