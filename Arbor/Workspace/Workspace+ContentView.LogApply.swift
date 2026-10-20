import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// Apply or reverse selected Changes Browser records as worktree patches.
/// Unlike Get Version this keeps the index untouched and leaves unrelated
/// files alone. IntelliJ applies every selected commit/parent patch in one
/// action; keep root-qualified batches ordered and stop at the first failure
/// so a conflict never allows later patches to run against an unresolved tree.
func applySelectedChangesFromLog(
    _ records: [LogChangeRecord],
    reverse: Bool
) {
    let groups = logChangePatchGroups(records)
    guard !groups.isEmpty else { return }
    let requests = groups.compactMap { group -> (Repository, CommitInfo, UInt32?, [String])? in
        guard let first = group.first,
              let repo = logRepository(for: first.commit) else {
            return nil
        }
        return (
            repo,
            first.commit,
            first.parentIndex,
            group.map(\.change.path)
        )
    }
    guard requests.count == groups.count else { return }
    let requestRootPaths = Set(requests.compactMap { request in
        request.0.workdir().map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    })
    let refreshMultiRootChanges = requestRootPaths.count > 1

    let action = reverse ? "Revert Selected Changes" : "Apply Selected Changes"
    let question = reverse ? "Revert selected changes?" : "Apply selected changes?"
    let fileCount = records.count
    let commitCount = Set(records.map { record in
        "\(record.commit.repositoryPath ?? "")\u{1f}\(record.commit.id)"
    }).count
    let worktreeScope = requestRootPaths.count > 1
        ? " across \(requestRootPaths.count) Git roots"
        : " in the current worktree"
    let notificationID = logChangesPatchNotificationID(
        rootPaths: Array(requestRootPaths),
        reverse: reverse
    )
    let detail = reverse
        ? "Reverse \(fileCount) file change(s) from \(commitCount) commit(s)\(worktreeScope)."
        : "Apply \(fileCount) file change(s) from \(commitCount) commit(s)\(worktreeScope)."
    let alert = NSAlert()
    alert.messageText = question
    alert.informativeText = detail + " The index and unrelated files will not be changed."
    alert.alertStyle = .warning
    alert.addButton(withTitle: reverse ? "Revert Changes" : "Apply Changes")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    beginFeedbackOperation(action, notificationID: notificationID)
    Task.detached(priority: .userInitiated) {
        var appliedFiles = 0
        for (repo, commit, parentIndex, paths) in requests {
            do {
                try repo.applySelectedCommitChanges(
                    commitId: commit.id,
                    parentIndex: parentIndex,
                    paths: paths,
                    reverse: reverse
                )
                appliedFiles += paths.count
            } catch {
                let completed = appliedFiles
                if case let .ShelveApplyConflict(conflictName, conflictPaths) = error as? EngineError {
                    let restoreInfo = (try? repo.shelveRestoreInfo()) ?? nil
                    let patchText = restoreInfo?.patch
                    await MainActor.run {
                        self.presentShelveConflict(
                            name: conflictName,
                            paths: conflictPaths,
                            isPop: false,
                            isDirectPatch: true,
                            patchText: patchText,
                            repository: repo,
                            notificationID: notificationID
                        )
                        if refreshMultiRootChanges {
                            self.loadMultiRootChanges()
                        }
                    }
                } else {
                    await MainActor.run {
                        self.refreshAll(showFeedback: false)
                        if refreshMultiRootChanges {
                            self.loadMultiRootChanges()
                        }
                        if completed > 0 {
                            self.feedbackCenter.warning(
                                "Some selected changes applied",
                                detail: "Applied \(completed) file(s); the remaining patch failed: \(errorMessage(error))",
                                nextStep: "Review the worktree and retry the failed selection.",
                                notificationID: notificationID
                            )
                        } else {
                            self.feedbackCenter.error(
                                "\(action) failed",
                                detail: errorMessage(error),
                                nextStep: "Review local changes and patch applicability, then retry.",
                                notificationID: notificationID
                            )
                        }
                    }
                }
                return
            }
        }
        let totalAppliedFiles = appliedFiles
        await MainActor.run {
            self.feedbackCenter.success(
                action,
                detail: "\(totalAppliedFiles) file(s) from \(commitCount) commit(s)\(requestRootPaths.count > 1 ? " across \(requestRootPaths.count) Git roots" : "")",
                notificationID: notificationID
            )
            self.refreshAll(showFeedback: false)
            if refreshMultiRootChanges {
                self.loadMultiRootChanges()
            }
        }
    }
}

enum LogApplyOperation: Equatable {
    case cherryPick
    case revert

    var title: String {
        switch self {
        case .cherryPick: "Cherry-pick"
        case .revert: "Revert"
        }
    }

    var smartTitle: String {
        switch self {
        case .cherryPick: "Smart Cherry-pick"
        case .revert: "Smart Revert"
        }
    }

    var pausedMessage: String {
        switch self {
        case .cherryPick: "Cherry-pick paused: resolve conflicts, then Continue or Abort"
        case .revert: "Revert paused: resolve conflicts, then Continue or Abort"
        }
    }
}

nonisolated func executeLogApply(
    operation: LogApplyOperation,
    repo: Repository,
    commitIDs: [String],
    emptyPolicy: CherryPickEmptyPolicy,
    appendPublishedSuffix: Bool,
    preserveLocalChanges: Bool,
    savePolicy: LocalChangesSavePolicy
) throws -> String {
    switch operation {
    case .cherryPick:
        if preserveLocalChanges {
            return try repo.cherryPickManyWithOptionsAndPolicy(
                commitIds: commitIDs,
                emptyPolicy: emptyPolicy,
                appendSuffix: appendPublishedSuffix,
                savePolicy: savePolicy
            )
        }
        return try repo.cherryPickManyWithOptions(
            commitIds: commitIDs,
            emptyPolicy: emptyPolicy,
            appendSuffix: appendPublishedSuffix
        )
    case .revert:
        if preserveLocalChanges {
            return try repo.revertManyWithPolicy(
                commitIds: commitIDs,
                mainline: nil,
                savePolicy: savePolicy
            )
        }
        return try repo.revertMany(commitIds: commitIDs, mainline: nil)
    }
}

func runLogApplyOperation(
    _ operation: LogApplyOperation,
    commits: [CommitInfo],
    confirm: Bool,
    preserveLocalChanges: Bool
) {
    guard !commits.isEmpty else { return }
    let batches = logCommitRootBatches(commits)
    guard !batches.isEmpty,
          batches.flatMap(\.commits).count == commits.count else {
        feedbackCenter.warning(
            "\(operation.title) unavailable",
            detail: "Every selected commit must belong to an available Git root.",
            nextStep: "Refresh Git Roots, then retry from the Log."
        )
        return
    }

    if operation == .revert,
       !commits.allSatisfy({ $0.parentIds.count == 1 }) {
        feedbackCenter.warning(
            "Revert unavailable",
            detail: "Root and merge commits cannot be reverted from this selection."
        )
        return
    }

    if confirm {
        let alert = NSAlert()
        if commits.count == 1, let commit = commits.first {
            alert.messageText = operation == .revert ? "Revert this commit?" : "Cherry-pick this commit?"
            alert.informativeText = operation == .revert
                ? "A new inverse commit will be created for \(commit.shortId) \(commit.summary)."
                : "A new commit will be created from \(commit.shortId) \(commit.summary)."
        } else {
            alert.messageText = operation == .revert ? "Revert selected commits?" : "Cherry-pick selected commits?"
            alert.informativeText = operation == .revert
                ? "A new inverse commit will be created for each selected commit across its Git root."
                : "A new commit will be created for each selected commit in its Git root."
        }
        alert.addButton(withTitle: operation == .revert ? "Revert" : "Cherry-pick")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
    }

    beginFeedbackOperation(operation.title)
    let emptyPolicyChoice = configuredCherryPickEmptyPolicyChoice()
    let emptyPolicy = emptyPolicyChoice.engineValue
    let protectedPatterns = effectiveProtectedBranchPatterns
    let savePolicyChoice = GitLocalChangesSavePolicySettings.choice(for: projectWorkspace.path)
    let operationProjectPath = projectWorkspace.path
    let logApplySessionID = UUID().uuidString
    let logApplyBatchCount = batches.count
    Task.detached(priority: .userInitiated) {
        // Save every root before the first engine mutation. A process exit
        // between two roots must not erase the remaining Log selection.
        var preparedRecoveries: [String: PersistedLogApplyRecovery] = [:]
        for (batchIndex, batch) in batches.enumerated() {
            let orderedCommits = operation == .cherryPick && batch.commits.count > 1
                ? Array(batch.commits.reversed())
                : batch.commits
            guard let batchRepo = try? openRepository(path: batch.rootPath),
                  let initialHead = batchRepo.headCommitId(),
                  let rootPath = batchRepo.workdir() else { continue }
            let remoteBranches = (try? batchRepo.remoteBranchList()) ?? []
            let appendSuffix = operation == .cherryPick && shouldAppendCherryPickSuffix(
                projectPath: operationProjectPath,
                commits: orderedCommits,
                repo: batchRepo,
                remoteBranches: remoteBranches,
                protectedPatterns: protectedPatterns
            )
            let recovery = PersistedLogApplyRecovery(
                operation: operation == .cherryPick ? .cherryPick : .revert,
                rootPath: rootPath,
                commitIDs: orderedCommits.map(\.id),
                sessionID: logApplySessionID,
                batchIndex: batchIndex,
                batchCount: logApplyBatchCount,
                initialHead: initialHead,
                preserveLocalChanges: preserveLocalChanges,
                emptyPolicyRaw: emptyPolicyChoice.rawValue,
                appendPublishedSuffix: appendSuffix,
                savePolicyRaw: savePolicyChoice.rawValue
            )
            saveLogApplyRecovery(recovery)
            preparedRecoveries[rootPath] = recovery
        }

        var completedCommits: [CommitInfo] = []
        var resultIDs: [(String, String)] = []
        for (batchIndex, batch) in batches.enumerated() {
            do {
                let repo = try openRepository(path: batch.rootPath)
                // The Log is newest-first; Cherry-pick replays each root's
                // selected sequence oldest-first. Revert keeps IntelliJ's
                // existing UI order and Git's sequencer semantics.
                let orderedCommits = operation == .cherryPick && batch.commits.count > 1
                    ? Array(batch.commits.reversed())
                    : batch.commits
                let ids = orderedCommits.map(\.id)
                let resultID: String
                switch operation {
                case .cherryPick:
                    let recovery = preparedRecoveries[batch.rootPath]
                    let appendSuffix = recovery?.appendPublishedSuffix ?? {
                        let remoteBranches = (try? repo.remoteBranchList()) ?? []
                        return shouldAppendCherryPickSuffix(
                            projectPath: operationProjectPath,
                            commits: orderedCommits,
                            repo: repo,
                            remoteBranches: remoteBranches,
                            protectedPatterns: protectedPatterns
                        )
                    }()
                    if let initialHead = repo.headCommitId(),
                       let rootPath = repo.workdir(),
                       recovery == nil {
                        saveLogApplyRecovery(
                            PersistedLogApplyRecovery(
                                operation: operation == .cherryPick ? .cherryPick : .revert,
                                rootPath: rootPath,
                                commitIDs: ids,
                                sessionID: logApplySessionID,
                                batchIndex: batchIndex,
                                batchCount: logApplyBatchCount,
                                initialHead: initialHead,
                                preserveLocalChanges: preserveLocalChanges,
                                emptyPolicyRaw: emptyPolicyChoice.rawValue,
                                appendPublishedSuffix: appendSuffix,
                                savePolicyRaw: savePolicyChoice.rawValue
                            )
                        )
                    }
                    resultID = try executeLogApply(
                        operation: operation,
                        repo: repo,
                        commitIDs: ids,
                        emptyPolicy: emptyPolicy,
                        appendPublishedSuffix: appendSuffix,
                        preserveLocalChanges: preserveLocalChanges,
                        savePolicy: savePolicyChoice.engineValue
                    )
                case .revert:
                    let recovery = preparedRecoveries[batch.rootPath]
                    if let initialHead = repo.headCommitId(),
                       let rootPath = repo.workdir(),
                       recovery == nil {
                        saveLogApplyRecovery(
                            PersistedLogApplyRecovery(
                                operation: .revert,
                                rootPath: rootPath,
                                commitIDs: ids,
                                sessionID: logApplySessionID,
                                batchIndex: batchIndex,
                                batchCount: logApplyBatchCount,
                                initialHead: initialHead,
                                preserveLocalChanges: preserveLocalChanges,
                                emptyPolicyRaw: emptyPolicyChoice.rawValue,
                                appendPublishedSuffix: false,
                                savePolicyRaw: savePolicyChoice.rawValue
                            )
                        )
                    }
                    resultID = try executeLogApply(
                        operation: operation,
                        repo: repo,
                        commitIDs: ids,
                        emptyPolicy: emptyPolicy,
                        appendPublishedSuffix: false,
                        preserveLocalChanges: preserveLocalChanges,
                        savePolicy: savePolicyChoice.engineValue
                    )
                }
                if let rootPath = repo.workdir() {
                    clearLogApplyRecovery(repositoryPath: rootPath)
                }
                completedCommits.append(contentsOf: orderedCommits)
                resultIDs.append((batch.rootPath, resultID))
            } catch {
                let repo = try? openRepository(path: batch.rootPath)
                let pendingCommits = batches[batchIndex...].flatMap(\.commits)
                let status = repo.flatMap { try? $0.status() } ?? []
                let state = repo.flatMap { try? $0.operationState() }
                let firstConflict = status.first {
                    $0.staged == .conflicted || $0.unstaged == .conflicted
                }?.path
                let completedCommitsSnapshot = completedCommits
                await MainActor.run {
                    self.handleLogApplyFailure(
                        operation: operation,
                        error: error,
                        repo: repo,
                        status: status,
                        state: state,
                        firstConflict: firstConflict,
                        pendingCommits: pendingCommits,
                        completedCommits: completedCommitsSnapshot
                    )
                }
                return
            }
        }
        let resultIDsSnapshot = resultIDs
        await MainActor.run {
            let details = resultIDsSnapshot.map { rootPath, id in
                "\(rootPath): \(String(id.prefix(7)))"
            }.joined(separator: "\n")
            self.commitWorkspace.feedback = operation.title
            self.feedbackCenter.success(operation.title, detail: details)
            self.logSelectionState.selection = nil
            self.logSelectionState.selectedIDs = []
            self.refreshAll(showFeedback: false)
        }
    }
}

func handleLogApplyFailure(
    operation: LogApplyOperation,
    error: Error,
    repo: Repository?,
    status: [FileEntry],
    state: OperationState?,
    firstConflict: String?,
    pendingCommits: [CommitInfo],
    completedCommits: [CommitInfo]
) {
    if case let .LocalChangesWouldBeOverwritten(paths) = error as? EngineError {
        let expectedRecoveryOperation: PersistedLogApplyRecovery.Operation = operation == .revert
            ? .revert
            : .cherryPick
        if let recovery = repo?.workdir().flatMap({ loadLogApplyRecovery(repositoryPath: $0) }),
           recovery.operation == expectedRecoveryOperation {
            let savedRecovery = recovery.updating(
                preserveLocalChanges: true,
                affectedPaths: paths
            )
            saveLogApplyRecovery(savedRecovery)
            _ = publishLogApplyRecoveryNoticeIfNeeded(rootPath: savedRecovery.rootPath)
            return
        }

        feedbackCenter.warning(
            "\(operation.title) needs a decision",
            detail: paths.joined(separator: ", "),
            nextStep: "Choose \(operation.smartTitle) to preserve local changes, or cancel and keep the current worktree."
        )
        presentSmartOperationDecision(
            operationTitle: operation.title,
            paths: paths,
            detail: errorMessage(error),
            smartButtonTitle: operation.smartTitle,
            onSmart: {
                self.runLogApplyOperation(
                    operation,
                    commits: pendingCommits,
                    confirm: false,
                    preserveLocalChanges: true
                )
            }
        )
        return
    }

    if state != nil || firstConflict != nil {
        repositoryStatus.entries = status
        operationRecovery.operation = state
        mergeWorkspace.inProgress = true
        operationRecovery.initialPath = firstConflict
        operationRecovery.showConflictResolver = true
        let completedDetail = completedCommits.isEmpty
            ? ""
            : " (\(completedCommits.count) commit(s) completed before this root)"
        commitWorkspace.feedback = operation.pausedMessage + completedDetail
    } else {
        let expectedRecoveryOperation: PersistedLogApplyRecovery.Operation = operation == .revert
            ? .revert
            : .cherryPick
        let recovery = repo?.workdir().flatMap {
            loadLogApplyRecovery(repositoryPath: $0)
        }.flatMap { $0.operation == expectedRecoveryOperation ? $0 : nil }
        let recoveryRootPath = recovery?.rootPath
        feedbackCenter.error(
            "\(operation.title) failed",
            detail: errorMessage(error),
            nextStep: repo == nil
                ? "Refresh Git Roots, then retry."
                : "Review the selected root's status, then retry.",
            additionalActions: recovery.map {
                logApplyRecoveryActions($0)
            } ?? [],
            notificationID: recoveryRootPath.map {
                logApplyRecoveryNotificationID(rootPath: $0)
            }
        )
    }
}

}
