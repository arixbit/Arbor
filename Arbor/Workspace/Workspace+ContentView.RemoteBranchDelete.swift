import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

func trackedRemoteProtectionName(_ remoteBranch: String) -> String {
    String(remoteBranch.split(separator: "/", maxSplits: 1).dropFirst().joined(separator: "/"))
}

func deleteTrackedRemoteBranch(_ context: BranchDeleteRecoveryContext) {
    guard let remoteBranch = context.trackedRemoteBranch else { return }
    deleteTrackedRemoteBranch(remoteBranch, contexts: [context])
}

func deleteTrackedRemoteBranch(
    _ remoteBranch: String,
    contexts: [BranchDeleteRecoveryContext]
) {
    let normalizedRemoteBranch = remoteBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedRemoteBranch.isEmpty,
          !contexts.isEmpty,
          contexts.contains(where: { $0.trackedRemoteBranch == normalizedRemoteBranch }) else {
        return
    }
    guard !GitProtectedBranchRules.matches(
        trackedRemoteProtectionName(normalizedRemoteBranch),
        patterns: effectiveProtectedBranchPatterns
    ) else {
        feedbackCenter.warning(
            "Tracked remote branch is protected",
            detail: normalizedRemoteBranch,
            nextStep: "Edit Protected Branches in Settings before deleting it."
        )
        return
    }

    let roots = contexts.filter { $0.trackedRemoteBranch == normalizedRemoteBranch }
    let location = roots.compactMap(\.rootPath).joined(separator: "\n")
    let alert = NSAlert()
    alert.messageText = String(localized: "Delete tracked remote branch?")
    alert.informativeText = "This will delete \(normalizedRemoteBranch) from the remote repository.\(location.isEmpty ? "" : "\n\n\(location)")"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Delete tracked remote branch", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        var succeeded: [BranchDeleteRecoveryContext] = []
        var failures: [String] = []
        var cancelled = false
        for context in roots {
            guard !cancel.isCancelled() else {
                cancelled = true
                break
            }
            do {
                try context.repo.deleteRemoteBranchWithAuthAndCancel(
                    remoteBranch: normalizedRemoteBranch,
                    broker: broker,
                    cancel: cancel
                )
                succeeded.append(context)
            } catch {
                if cancel.isCancelled() {
                    cancelled = true
                    break
                }
                failures.append(
                    "\(context.rootPath ?? String(localized: "Repository")): \(friendlyRemoteError(error))"
                )
            }
        }
        let succeededIDs = Set(succeeded.map(\.id))
        let failuresToReport = failures
        let cancelledToReport = cancelled
        await MainActor.run {
            if let context = self.branchWorkspace.deleteRecovery,
               context.trackedRemoteBranch == normalizedRemoteBranch,
               succeededIDs.contains(context.id) {
                self.branchWorkspace.deleteRecovery = BranchDeleteRecoveryContext(
                    repo: context.repo,
                    preview: context.preview,
                    rootPath: context.rootPath,
                    trackedRemoteBranch: nil
                )
            }
            if let context = self.branchWorkspace.multiRootDeleteRecovery {
                let updatedContexts = context.contexts.map { item in
                    guard item.trackedRemoteBranch == normalizedRemoteBranch,
                          succeededIDs.contains(item.id) else { return item }
                    return BranchDeleteRecoveryContext(
                        repo: item.repo,
                        preview: item.preview,
                        rootPath: item.rootPath,
                        trackedRemoteBranch: nil
                    )
                }
                self.branchWorkspace.multiRootDeleteRecovery = MultiRootBranchDeleteRecoveryContext(
                    branchName: context.branchName,
                    contexts: updatedContexts
                )
            }
            if roots.contains(where: { $0.rootPath != nil }) {
                self.loadMultiRoots()
            }
            if roots.contains(where: { $0.rootPath == nil }) {
                self.loadRepoData()
            }
            if failuresToReport.isEmpty && !cancelledToReport {
                self.feedbackCenter.success(
                    "Tracked remote branch deleted",
                    detail: normalizedRemoteBranch
                )
            } else {
                var details = failuresToReport
                if cancelledToReport {
                    details.insert("Operation cancelled.", at: 0)
                }
                self.feedbackCenter.warning(
                    "Tracked remote branch deletion partially failed",
                    detail: details.joined(separator: "\n"),
                    nextStep: "Retry the remaining remote deletion from the recovery sheet."
                )
            }
        }
    }
}

/// 多 root Branches Popup 的远程分支删除；保留二次确认，避免把远程
/// tracking ref 的删除误认为仅本地清理。
func deleteRemoteBranchInRoot(rootPath: String, branch: String) {
    let branchName = branch.split(separator: "/", maxSplits: 1)
        .dropFirst()
        .joined(separator: "/")
    let protectedName = branchName.isEmpty ? branch : branchName
    guard !GitProtectedBranchRules.matches(
        protectedName,
        patterns: effectiveProtectedBranchPatterns
    ) else {
        feedbackCenter.warning(
            "Delete remote branch unavailable",
            detail: "Protected branch: \(branch)",
            nextStep: "Remove the protection rule only if deleting this remote branch is intentional."
        )
        return
    }
    let alert = NSAlert()
    alert.messageText = String(localized: "Delete remote branch?")
    alert.informativeText = String(localized: "This will delete \(branch) from its remote repository.")
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Delete remote branch", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            try rootRepo.deleteRemoteBranchWithAuthAndCancel(
                remoteBranch: branch,
                broker: broker,
                cancel: cancel
            )
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.success("Remote branch deleted", detail: "\(branch) · \(rootPath)")
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                if cancel.isCancelled() {
                    self.feedbackCenter.warning(
                        "Remote branch deletion cancelled",
                        detail: "\(branch) · \(rootPath)",
                        nextStep: "The remote branch was not confirmed as deleted; refresh before retrying."
                    )
                } else {
                    self.feedbackCenter.error(
                        "Delete remote branch failed",
                        detail: "\(branch) · \(rootPath): \(friendlyRemoteError(error))",
                        nextStep: "Check permissions and the remote name, then retry."
                    )
                }
            }
        }
    }
}

func presentMultiRootRemoteDeleteDialog(branch: String) {
    let eligible = multiRootWorkspace.branchSnapshots.filter { snapshot in
        snapshot.remoteBranches.contains { $0.name == branch }
    }
    guard !eligible.isEmpty else {
        feedbackCenter.warning(
            "Delete remote branch unavailable",
            detail: "No Git root contains " + branch + "."
        )
        return
    }
    branchWorkspace.multiRootRemoteDeleteName = branch
    branchWorkspace.multiRootRemoteDeleteSelectedRootPaths = Set(eligible.map(\.rootPath))
    branchWorkspace.multiRootRemoteDeleteTracking = false
    branchWorkspace.showMultiRootRemoteDeleteDialog = true
}

func dismissMultiRootRemoteDeleteDialog() {
    branchWorkspace.showMultiRootRemoteDeleteDialog = false
    branchWorkspace.multiRootRemoteDeleteName = ""
    branchWorkspace.multiRootRemoteDeleteSelectedRootPaths = []
    branchWorkspace.multiRootRemoteDeleteTracking = false
}

/// Delete one remote branch across selected roots. IntelliJ first asks once
/// for the remote deletion and whether common local tracking branches should
/// follow; remote failures are reported per root, but tracking cleanup starts
/// only after every selected remote deletion succeeds. Local force deletions
/// retain exact previews for Restore All.
func deleteMultiRootRemoteBranch(
    remoteBranch: String,
    deleteTracking: Bool,
    selectedRootPaths: Set<String>
) {
    multiRootWorkspace.updateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryContext = nil
    let branchName = remoteBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !branchName.isEmpty else { return }
    let roots = multiRootWorkspace.branchSnapshots.filter { snapshot in
        selectedRootPaths.contains(snapshot.rootPath)
            && snapshot.remoteBranches.contains { $0.name == branchName }
    }
    guard !roots.isEmpty else { return }
    let commonTrackingBranches = multiRootCommonTrackingBranches(
        remoteBranch: branchName,
        snapshots: multiRootWorkspace.branchSnapshots,
        selectedRootPaths: selectedRootPaths
    )
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    multiRootWorkspace.running = true
    beginFeedbackOperation("Multi-root remote branch deletion", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        var results: [RootOperationResult] = []
        var recoveryContexts: [BranchDeleteRecoveryContext] = []
        var remoteFailures: [String] = []
        var trackingWarnings: [String] = []
        var cancelled = false
        var repositoriesByRoot: [String: Repository] = [:]
        for snapshot in roots {
            guard !cancel.isCancelled() else {
                cancelled = true
                results.append(
                    RootOperationResult(
                        rootPath: snapshot.rootPath,
                        displayName: snapshot.displayName,
                        success: false,
                        skipped: true,
                        message: "Cancelled"
                    )
                )
                continue
            }
            do {
                let rootRepo = try openRepository(path: snapshot.rootPath)
                try rootRepo.deleteRemoteBranchWithAuthAndCancel(
                    remoteBranch: branchName,
                    broker: broker,
                    cancel: cancel
                )
                repositoriesByRoot[snapshot.rootPath] = rootRepo
                results.append(
                    RootOperationResult(
                        rootPath: snapshot.rootPath,
                        displayName: snapshot.displayName,
                        success: true,
                        skipped: false,
                        message: "Deleted \(branchName)"
                    )
                )
            } catch {
                if cancel.isCancelled() {
                    cancelled = true
                    results.append(
                        RootOperationResult(
                            rootPath: snapshot.rootPath,
                            displayName: snapshot.displayName,
                            success: false,
                            skipped: true,
                            message: "Cancelled"
                        )
                    )
                    continue
                }
                let detail = "\(snapshot.displayName): \(errorMessage(error))"
                remoteFailures.append(detail)
                results.append(
                    RootOperationResult(
                        rootPath: snapshot.rootPath,
                        displayName: snapshot.displayName,
                        success: false,
                        skipped: false,
                        message: errorMessage(error)
                    )
                )
            }
        }

        // IntelliJ only removes the common local tracking branches after the
        // remote deletion succeeds for every selected repository. A failed
        // remote operation therefore never causes an extra local deletion.
        var trackingDeletedByRoot: [String: Int] = [:]
        if remoteFailures.isEmpty && !cancelled && deleteTracking {
            for localBranch in commonTrackingBranches {
                for snapshot in roots {
                    guard snapshot.branches.contains(where: { $0.name == localBranch && !$0.isCurrent }),
                          let rootRepo = repositoriesByRoot[snapshot.rootPath] else {
                        continue
                    }
                    do {
                        let preview = try rootRepo.branchDeletePreview(name: localBranch)
                        do {
                            try rootRepo.branchDelete(name: localBranch, force: false)
                        } catch {
                            guard isUnmergedBranchDeletionError(error) else { throw error }
                            try rootRepo.branchDelete(name: localBranch, force: true)
                        }
                        recoveryContexts.append(
                            BranchDeleteRecoveryContext(
                                repo: rootRepo,
                                preview: preview,
                                rootPath: snapshot.rootPath
                            )
                        )
                        trackingDeletedByRoot[snapshot.rootPath, default: 0] += 1
                    } catch {
                        let warning = "\(snapshot.displayName): \(localBranch): \(errorMessage(error))"
                        trackingWarnings.append(warning)
                    }
                }
            }
        }
        if remoteFailures.isEmpty, !cancelled, deleteTracking, !commonTrackingBranches.isEmpty {
            for index in results.indices where results[index].success {
                let deletedCount = trackingDeletedByRoot[results[index].rootPath, default: 0]
                results[index].message = deletedCount == commonTrackingBranches.count
                    ? "Deleted \(branchName) and common local tracking branches"
                    : "Deleted \(branchName); local branches kept"
            }
        }
        let resultsToApply = results
        let recoveryContextsToOffer = recoveryContexts
        let remoteFailuresToReport = remoteFailures
        let trackingWarningsToReport = trackingWarnings
        let cancelledToReport = cancelled
        let restoredBranchNames = Array(
            Set(recoveryContextsToOffer.map(\.preview.branchName))
        ).sorted()
        await MainActor.run {
            self.multiRootWorkspace.running = false
            self.branchWorkspace.showMultiRootRemoteDeleteDialog = false
            self.multiRootWorkspace.results = resultsToApply
            self.loadMultiRoots()
            if !recoveryContextsToOffer.isEmpty {
                self.branchWorkspace.multiRootDeleteRecovery = MultiRootBranchDeleteRecoveryContext(
                    branchName: restoredBranchNames.joined(separator: ", "),
                    contexts: recoveryContextsToOffer
                )
            }
            var details = remoteFailuresToReport + trackingWarningsToReport
            if cancelledToReport {
                details.insert("Operation cancelled.", at: 0)
            }
            if details.isEmpty {
                self.feedbackCenter.success(
                    "Multi-root remote branch deletion completed",
                    detail: "\(resultsToApply.filter(\.success).count) repositories · \(branchName)",
                    additionalActions: self.branchDeleteRecoveryActions(
                        contexts: recoveryContextsToOffer
                    ),
                    notificationID: recoveryContextsToOffer.isEmpty
                        ? nil
                        : self.branchDeleteNotificationID(),
                    notificationGroup: recoveryContextsToOffer.isEmpty ? .toolWindow : .standard
                )
            } else {
                self.projectWorkspace.toolWindowMode = .operations
                self.toolWindowExpanded = true
                self.feedbackCenter.warning(
                    cancelledToReport
                        ? "Multi-root remote branch deletion cancelled"
                        : remoteFailuresToReport.isEmpty
                        ? "Remote branch deleted; some local branches kept"
                        : "Multi-root remote branch deletion partially completed",
                    detail: details.joined(separator: "\n"),
                    nextStep: recoveryContextsToOffer.isEmpty
                        ? "Review the affected roots and retry the failed operation."
                        : "Use Restore All if you need to recover the deleted local tracking branches.",
                    additionalActions: self.branchDeleteRecoveryActions(
                        contexts: recoveryContextsToOffer
                    ),
                    notificationID: recoveryContextsToOffer.isEmpty
                        ? nil
                        : self.branchDeleteNotificationID(),
                    notificationGroup: recoveryContextsToOffer.isEmpty ? .toolWindow : .standard
                )
            }
        }
    }
}

struct MultiRootRemoteBranchDeleteGroup: Equatable, Sendable {
    let remoteBranch: String
    let rootPaths: [String]
}

nonisolated static func multiRootRemoteBranchDeleteGroups(
    _ targets: [BranchDashboardReference]
) -> [MultiRootRemoteBranchDeleteGroup] {
    let groupedTargets = Dictionary(grouping: targets, by: \.name)
    return groupedTargets
        .keys
        .sorted()
        .compactMap { remoteBranch in
            guard let branchTargets = groupedTargets[remoteBranch] else {
                return nil
            }
            return MultiRootRemoteBranchDeleteGroup(
                remoteBranch: remoteBranch,
                rootPaths: Array(Set(branchTargets.map(\.rootPath))).sorted()
            )
        }
}

/// IntelliJ's multi-ref DeleteBranchAction also accepts remote branch refs.
/// Keep each remote ref tied to its owning root, ask once whether common local
/// tracking branches should follow, and only perform that local cleanup after
/// every selected root for the same remote branch succeeded.
func deleteSelectedRemoteBranchesInRoots(_ targets: [BranchDashboardReference]) {
    let selected = targets
        .filter { $0.kind == .remote }
        .sorted {
            if $0.rootPath == $1.rootPath { return $0.name < $1.name }
            return $0.rootPath < $1.rootPath
        }
    guard !selected.isEmpty, !multiRootWorkspace.running else { return }
    guard selected.allSatisfy({ !$0.isProtected }) else {
        feedbackCenter.warning(
            "Delete remote branches unavailable",
            detail: "One or more selected remote branches are protected.",
            nextStep: "Remove the protection rule only if deleting these branches is intentional."
        )
        return
    }

    let groups = Self.multiRootRemoteBranchDeleteGroups(selected)
    let commonTrackingBranchesByRemoteBranch = Dictionary(
        uniqueKeysWithValues: groups.map { group in
            (
                group.remoteBranch,
                multiRootCommonTrackingBranches(
                    remoteBranch: group.remoteBranch,
                    snapshots: multiRootWorkspace.branchSnapshots,
                    selectedRootPaths: Set(group.rootPaths)
                )
            )
        }
    )
    let trackingSummary = groups.flatMap { group in
        (commonTrackingBranchesByRemoteBranch[group.remoteBranch] ?? []).map {
            "\(group.remoteBranch) → \($0)"
        }
    }

    let alert = NSAlert()
    alert.messageText = String(localized: "Delete selected remote branches?")
    alert.informativeText = selected
        .map { "\($0.name) · \($0.rootPath)" }
        .joined(separator: "\n")
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    var deleteTrackingCheckbox: NSButton?
    if !trackingSummary.isEmpty {
        let checkbox = NSButton(
            checkboxWithTitle: "Also delete common local tracking branches: \(trackingSummary.joined(separator: ", "))",
            target: nil,
            action: nil
        )
        checkbox.state = .off
        alert.accessoryView = checkbox
        deleteTrackingCheckbox = checkbox
    }
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let deleteTracking = deleteTrackingCheckbox?.state == .on

    let displayNames = Dictionary(
        uniqueKeysWithValues: multiRootWorkspace.branchSnapshots.map { ($0.rootPath, $0.displayName) }
    )
    let localBranchesByRoot = Dictionary(
        uniqueKeysWithValues: multiRootWorkspace.branchSnapshots.map { snapshot in
            (
                snapshot.rootPath,
                Set(snapshot.branches.filter { !$0.isCurrent }.map(\.name))
            )
        }
    )
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    multiRootWorkspace.running = true
    beginFeedbackOperation("Delete selected remote branches", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        var results: [RootOperationResult] = []
        var failures: [String] = []
        var trackingWarnings: [String] = []
        var recoveryContexts: [BranchDeleteRecoveryContext] = []
        var repositoriesByRoot: [String: Repository] = [:]
        var cancelled = false

        for group in groups {
            let groupTargets = selected.filter {
                $0.name == group.remoteBranch && group.rootPaths.contains($0.rootPath)
            }
            var groupSucceeded = true

            for target in groupTargets {
                guard !cancel.isCancelled() else {
                    cancelled = true
                    groupSucceeded = false
                    results.append(
                        RootOperationResult(
                            rootPath: target.rootPath,
                            displayName: displayNames[target.rootPath] ?? target.rootPath,
                            success: false,
                            skipped: true,
                            message: "Cancelled"
                        )
                    )
                    continue
                }
                do {
                    let rootRepo = try openRepository(path: target.rootPath)
                    try rootRepo.deleteRemoteBranchWithAuthAndCancel(
                        remoteBranch: target.name,
                        broker: broker,
                        cancel: cancel
                    )
                    repositoriesByRoot[target.rootPath] = rootRepo
                    results.append(
                        RootOperationResult(
                            rootPath: target.rootPath,
                            displayName: displayNames[target.rootPath] ?? target.rootPath,
                            success: true,
                            skipped: false,
                            message: "Deleted \(target.name)"
                        )
                    )
                } catch {
                    groupSucceeded = false
                    if cancel.isCancelled() {
                        cancelled = true
                        results.append(
                            RootOperationResult(
                                rootPath: target.rootPath,
                                displayName: displayNames[target.rootPath] ?? target.rootPath,
                                success: false,
                                skipped: true,
                                message: "Cancelled"
                            )
                        )
                    } else {
                        let detail = "\(target.name) · \(target.rootPath): \(friendlyRemoteError(error))"
                        failures.append(detail)
                        results.append(
                            RootOperationResult(
                                rootPath: target.rootPath,
                                displayName: displayNames[target.rootPath] ?? target.rootPath,
                                success: false,
                                skipped: false,
                                message: "\(target.name): \(friendlyRemoteError(error))"
                            )
                        )
                    }
                }
            }

            let commonTrackingBranches = commonTrackingBranchesByRemoteBranch[group.remoteBranch] ?? []
            guard deleteTracking,
                  groupSucceeded,
                  !cancelled,
                  !cancel.isCancelled(),
                  !commonTrackingBranches.isEmpty else {
                continue
            }

            var trackingDeletedByRoot: [String: Int] = [:]
            for localBranch in commonTrackingBranches {
                for rootPath in group.rootPaths {
                    guard !cancel.isCancelled() else {
                        cancelled = true
                        break
                    }
                    guard localBranchesByRoot[rootPath]?.contains(localBranch) == true,
                          let rootRepo = repositoriesByRoot[rootPath] else {
                        continue
                    }
                    do {
                        let preview = try rootRepo.branchDeletePreview(name: localBranch)
                        do {
                            try rootRepo.branchDelete(name: localBranch, force: false)
                        } catch {
                            guard isUnmergedBranchDeletionError(error) else { throw error }
                            try rootRepo.branchDelete(name: localBranch, force: true)
                        }
                        recoveryContexts.append(
                            BranchDeleteRecoveryContext(
                                repo: rootRepo,
                                preview: preview,
                                rootPath: rootPath
                            )
                        )
                        trackingDeletedByRoot[rootPath, default: 0] += 1
                    } catch {
                        let warning = "\(displayNames[rootPath] ?? rootPath): \(localBranch): \(errorMessage(error))"
                        trackingWarnings.append(warning)
                    }
                }
            }

            for index in results.indices where group.rootPaths.contains(results[index].rootPath)
                && results[index].success
                && !results[index].skipped
                && results[index].message == "Deleted \(group.remoteBranch)" {
                let deletedCount = trackingDeletedByRoot[results[index].rootPath, default: 0]
                results[index].message = deletedCount == commonTrackingBranches.count
                    ? "Deleted \(group.remoteBranch) and common local tracking branches"
                    : "Deleted \(group.remoteBranch); local branches kept"
            }
        }

        let completedResults = results
        let completedFailures = failures + trackingWarnings + (cancelled ? ["Operation cancelled."] : [])
        let completedRecoveryContexts = recoveryContexts
        let cancelledToReport = cancelled
        await MainActor.run {
            self.multiRootWorkspace.running = false
            self.multiRootWorkspace.results = completedResults
            self.loadMultiRoots()
            if !completedRecoveryContexts.isEmpty {
                self.branchWorkspace.multiRootDeleteRecovery = MultiRootBranchDeleteRecoveryContext(
                    branchName: groups.map(\.remoteBranch).joined(separator: ", "),
                    contexts: completedRecoveryContexts
                )
            }
            if completedFailures.isEmpty && !cancelledToReport {
                self.feedbackCenter.success(
                    "Selected remote branch deletion completed",
                    detail: "\(completedResults.filter(\.success).count) branches",
                    additionalActions: self.branchDeleteRecoveryActions(
                        contexts: completedRecoveryContexts
                    ),
                    notificationID: completedRecoveryContexts.isEmpty
                        ? nil
                        : self.branchDeleteNotificationID(),
                    notificationGroup: completedRecoveryContexts.isEmpty ? .toolWindow : .standard
                )
            } else {
                self.projectWorkspace.toolWindowMode = .operations
                self.toolWindowExpanded = true
                self.feedbackCenter.warning(
                    cancelledToReport
                        ? "Selected remote branch deletion cancelled"
                        : "Selected remote branch deletion partially completed",
                    detail: completedFailures.joined(separator: "\n"),
                    nextStep: completedRecoveryContexts.isEmpty
                        ? "Review the failed remote deletions and retry them individually."
                        : "Use Restore All if you need to recover the deleted local tracking branches.",
                    additionalActions: self.branchDeleteRecoveryActions(
                        contexts: completedRecoveryContexts
                    ),
                    notificationID: completedRecoveryContexts.isEmpty
                        ? nil
                        : self.branchDeleteNotificationID(),
                    notificationGroup: completedRecoveryContexts.isEmpty ? .toolWindow : .standard
                )
            }
        }
    }
}

func deleteRemoteBranch(_ branch: RemoteBranchInfo) {
    guard let repo else { return }
    let alert = NSAlert()
    alert.messageText = String(localized: "Delete remote branch?")
    alert.informativeText = String(localized: "This will delete \(branch.name) from the remote repository.")
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    let currentLocalBranches = Set(branchWorkspace.branches.filter(\.isCurrent).map(\.name))
    let trackingLocalBranches = branchWorkspace.syncStatuses
        .filter {
            $0.upstream == branch.name
                && $0.trackingExists
                && !currentLocalBranches.contains($0.branch)
        }
        .map(\.branch)
        .sorted()
    var deleteTrackingCheckbox: NSButton?
    if !trackingLocalBranches.isEmpty {
        let localBranchesTitle = trackingLocalBranches.count == 1
            ? "Also delete local branch \(trackingLocalBranches[0])"
            : "Also delete local branches: \(trackingLocalBranches.joined(separator: ", "))"
        let checkbox = NSButton(
            checkboxWithTitle: localBranchesTitle,
            target: nil,
            action: nil
        )
        checkbox.state = .off
        alert.accessoryView = checkbox
        deleteTrackingCheckbox = checkbox
    }
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let deleteTracking = deleteTrackingCheckbox?.state == .on
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Delete remote branch", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            try repo.deleteRemoteBranchWithAuthAndCancel(
                remoteBranch: branch.name,
                broker: broker,
                cancel: cancel
            )
            if cancel.isCancelled() {
                await MainActor.run {
                    self.refreshAll(showFeedback: false)
                    self.loadRepoData()
                    self.feedbackCenter.warning(
                        "Remote branch deletion cancelled",
                        detail: branch.name
                    )
                }
                return
            }
            let localDeletionMessages: [String]
            if deleteTracking {
                localDeletionMessages = trackingLocalBranches.compactMap { localBranchName in
                    do {
                        try repo.branchDelete(name: localBranchName, force: false)
                        return nil
                    } catch {
                        return "\(localBranchName): \(errorMessage(error))"
                    }
                }
            } else {
                localDeletionMessages = []
            }
            await MainActor.run {
                if !localDeletionMessages.isEmpty {
                    self.feedbackCenter.warning(
                        "Remote branch deleted; local branches kept",
                        detail: localDeletionMessages.joined(separator: "\n"),
                        nextStep: "Resolve local changes or delete the local branch separately."
                    )
                } else {
                    self.feedbackCenter.success("Remote branch deleted", detail: branch.name)
                }
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
            }
        } catch {
            await MainActor.run {
                self.repositoryStatus.loadError = errorMessage(error)
                if cancel.isCancelled() {
                    self.feedbackCenter.warning(
                        "Remote branch deletion cancelled",
                        detail: branch.name
                    )
                } else {
                    self.feedbackCenter.error("Delete remote branch failed", detail: friendlyRemoteError(error), nextStep: "Check permissions and the remote name, then retry.")
                }
            }
        }
    }
}

}
