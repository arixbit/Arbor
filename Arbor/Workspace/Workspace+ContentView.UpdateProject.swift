import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// IntelliJ treats an Update Project run with no tracked, checked-out root as
/// NOT_READY. Detached or untracked roots may be skipped only when another
/// root can actually perform the update.
nonisolated static func updateProjectHasEligibleRoot(
    _ results: [RootOperationResult]
) -> Bool {
    results.contains { result in
        result.success && !result.skipped
    }
}

/// The engine performs IntelliJ's project-level readiness check before any
/// root is fetched or updated. Keep the presentation classifier tolerant of
/// the older single-root error wording as well, so a race that is detected at
/// the root boundary still follows the same unavailable/recovery flow.
nonisolated static func updateProjectIsNotReady(
    _ results: [RootOperationResult]
) -> Bool {
    results.contains { result in
        let message = result.message.lowercased()
        return message.contains("update not ready")
            || message.contains("another git operation is already in progress")
            || message.contains("unresolved conflicts remain")
    }
}

nonisolated static func skippedUpdateRootDetails(_ results: [RootOperationResult]) -> [String] {
    var rootsByReason: [String: [String]] = [:]
    for result in results where result.skipped {
        let reason = result.message.trimmingCharacters(in: .whitespacesAndNewlines)
        rootsByReason[reason.isEmpty ? "not available" : reason, default: []].append(result.displayName)
    }
    return rootsByReason.keys.sorted().compactMap { reason in
        guard let roots = rootsByReason[reason], !roots.isEmpty else { return nil }
        return "\(roots.joined(separator: ", ")) (\(reason))"
    }
}

struct UpdateRootRecoveryTarget: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case chooseUpstream
        case openBranches
    }

    let kind: Kind
    let rootPath: String
    let displayName: String
    let branch: String?
}

struct UpdateRootRecoveryRoot: Equatable, Sendable {
    let path: String
    let displayName: String
    let isSubmodule: Bool
    let headBranch: String?
}

/// Project Update skips detached or untracked roots instead of turning one
/// root's configuration problem into a compound-operation failure. Keep the
/// recovery target root-qualified so the follow-up action cannot accidentally
/// edit the current window's repository when the skipped root is nested.
nonisolated static func updateRootRecoveryTargets(
    results: [RootOperationResult],
    roots: [UpdateRootRecoveryRoot]
) -> [UpdateRootRecoveryTarget] {
    let rootsByPath = Dictionary(
        uniqueKeysWithValues: roots.map {
            (URL(fileURLWithPath: $0.path).standardizedFileURL.path, $0)
        }
    )
    var targets: [UpdateRootRecoveryTarget] = []
    for result in results where result.skipped {
        let path = URL(fileURLWithPath: result.rootPath).standardizedFileURL.path
        guard let root = rootsByPath[path], !root.isSubmodule else { continue }
        let message = result.message.lowercased()
        if message.contains("no configured upstream")
            || message.contains("tracking branch")
        {
            guard let branch = root.headBranch, !branch.isEmpty else { continue }
            targets.append(
                UpdateRootRecoveryTarget(
                    kind: .chooseUpstream,
                    rootPath: path,
                    displayName: root.displayName,
                    branch: branch
                )
            )
        } else if message.contains("detached head") {
            targets.append(
                UpdateRootRecoveryTarget(
                    kind: .openBranches,
                    rootPath: path,
                    displayName: root.displayName,
                    branch: nil
                )
            )
        }
    }
    return targets.sorted {
        if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
        return $0.rootPath < $1.rootPath
    }
}

nonisolated static func multiRootUpdateFailureDetails(
    _ results: [RootOperationResult],
    submoduleRootPaths: Set<String>
) -> [String] {
    func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    func isDescendant(_ path: String, of ancestor: String) -> Bool {
        path.hasPrefix(ancestor + "/")
    }

    let normalizedSubmodulePaths = Set(submoduleRootPaths.map(normalizedPath))
    let resultPaths = Dictionary(uniqueKeysWithValues: results.map {
        (normalizedPath($0.rootPath), $0)
    })
    let failedPaths = Set(results.filter { !$0.success }.map { normalizedPath($0.rootPath) })

    func nearestFailedAncestor(for path: String) -> String? {
        failedPaths
            .filter { $0 != path && isDescendant(path, of: $0) }
            .max { $0.count < $1.count }
    }

    var grouped: [String: [RootOperationResult]] = [:]
    for result in results where !result.success {
        let path = normalizedPath(result.rootPath)
        let groupPath = nearestFailedAncestor(for: path) ?? path
        grouped[groupPath, default: []].append(result)
    }
    for result in results where result.skipped {
        let path = normalizedPath(result.rootPath)
        guard normalizedSubmodulePaths.contains(path),
              let groupPath = nearestFailedAncestor(for: path) else { continue }
        grouped[groupPath, default: []].append(result)
    }

    var groupedResultPaths = Set<String>()
    var details: [String] = []
    for groupPath in grouped.keys.sorted() {
        guard let groupRoot = resultPaths[groupPath],
              let members = grouped[groupPath] else { continue }
        groupedResultPaths.formUnion(members.map { normalizedPath($0.rootPath) })
        details.append("\(groupRoot.displayName): \(groupRoot.message)")
        for member in members
            .filter({ normalizedPath($0.rootPath) != groupPath })
            .sorted(by: { $0.rootPath < $1.rootPath }) {
            details.append("  \(member.displayName): \(member.message)")
        }
    }

    var skippedByReason: [String: [String]] = [:]
    for result in results where result.skipped {
        let path = normalizedPath(result.rootPath)
        guard !groupedResultPaths.contains(path) else { continue }
        let reason = result.message.trimmingCharacters(in: .whitespacesAndNewlines)
        skippedByReason[reason.isEmpty ? "not available" : reason, default: []].append(result.displayName)
    }
    for reason in skippedByReason.keys.sorted() {
        guard let roots = skippedByReason[reason], !roots.isEmpty else { continue }
        details.append("\(roots.joined(separator: ", ")) (\(reason))")
    }
    return details
}

nonisolated static func multiRootUpdateSuccessDetail(
    _ results: [RootOperationResult],
    updatedFilesCount: Int? = nil
) -> String {
    let updatedResults = results.filter { $0.success && !$0.skipped }
    let parsedCommitCounts = updatedResults.compactMap { updatedCommitCount(from: $0.message) }
    let updatedCommits = parsedCommitCounts.reduce(0, +)
    var details: [String] = []
    if updatedResults.isEmpty {
        details.append("Nothing to update")
    } else if parsedCommitCounts.count == updatedResults.count && updatedCommits == 0 {
        details.append("Nothing to update")
    } else if parsedCommitCounts.isEmpty {
        details.append("\(updatedResults.count) updated")
    } else {
        details.append("\(updatedResults.count) updated · \(updatedCommits) commits")
    }
    if let updatedFilesCount,
       !updatedResults.isEmpty,
       !(parsedCommitCounts.count == updatedResults.count && updatedCommits == 0) {
        if parsedCommitCounts.count == updatedResults.count {
            details[0] = "\(updatedFilesCount) files updated in \(updatedCommits) commits"
        } else {
            details[0] = "\(updatedFilesCount) files updated"
        }
    }
    let skipped = skippedUpdateRootDetails(results)
    if !skipped.isEmpty {
        details.append("Skipped: \(skipped.joined(separator: "; "))")
    }
    return details.joined(separator: " · ")
}

/// Vcs.UpdateProject first presents the platform options dialog unless the
/// project opted out. The selected method is applied only after confirmation;
/// Reset remains a dialog-side action and never persists a new update method.
func requestUpdateProject() {
    guard !isArborBackgroundVCSOperationInProgress(
        feedbackIsRunning: feedbackCenter.isRunning,
        multiRootIsRunning: multiRootWorkspace.running || multiRootWorkspace.updateDiscoveryRunning
    ) else { return }
    guard repo != nil else { return }
    guard let projectPath = projectWorkspace.path, !projectPath.isEmpty else {
        executeMultiRootUpdate(rebase: gitSettings.projectUpdateMethod == .rebase)
        return
    }
    if GitUpdateOptionsDialogSettings.shouldShow(for: projectPath) {
        gitSettings.showUpdateProjectOptions = true
    } else {
        executeMultiRootUpdate(rebase: gitSettings.projectUpdateMethod == .rebase)
    }
}

/// Vcs.UpdateProject / ⌘T：多 root 项目必须一次更新所有 configured upstream，
/// 而不是只更新当前窗口绑定的 root。
func executeMultiRootUpdate(rebase: Bool) {
    guard !isArborBackgroundVCSOperationInProgress(
        feedbackIsRunning: feedbackCenter.isRunning,
        multiRootIsRunning: multiRootWorkspace.running || multiRootWorkspace.updateDiscoveryRunning
    ) else { return }
    multiRootWorkspace.updateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryContext = nil
    multiRootWorkspace.updateRebaseRootPaths = nil
    guard let projectPath = projectWorkspace.path else { return }
    multiRootWorkspace.updateDiscoveryRunning = true
    multiRootWorkspace.updateRebase = rebase
    let broker = credentialAuth.broker
    let tagMode = fetchTagsMode
    let cancel = GitCancelHandle()
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
    Task.detached(priority: .userInitiated) {
        do {
            let roots = try discoverGitRoots(scanRoot: projectPath, maxDepth: nil)
            guard roots.count > 1 else {
                if rebase, let root = roots.first {
                    let preflight = try prepareMultiRootUpdate(
                        scanRoot: projectPath,
                        selectedRootPaths: [root.path],
                        tagMode: tagMode,
                        broker: broker,
                        cancel: cancel
                    )
                    if preflight.problematicRootPaths.contains(root.path) {
                        let decision = await MainActor.run {
                            presentUpdateRebaseOverMergeDialog(problematicRoots: [root])
                        }
                        guard decision != .cancel else {
                            await MainActor.run {
                                self.multiRootWorkspace.updateDiscoveryRunning = false
                                self.feedbackCenter.warning(
                                    "Update Project cancelled",
                                    detail: "No working tree changes were applied."
                                )
                            }
                            return
                        }
                        await MainActor.run {
                            self.multiRootWorkspace.updateDiscoveryRunning = false
                            self.doPull(
                                nil,
                                rebase: decision == .rebaseAnyway,
                                autoOpenUpdateInfo: true
                            )
                        }
                        return
                    }
                }
                await MainActor.run {
                    self.multiRootWorkspace.updateDiscoveryRunning = false
                    self.doPull(nil, rebase: rebase, autoOpenUpdateInfo: true)
                }
                return
            }
            let submoduleRootPaths = Set(roots.filter(\.isSubmodule).map(\.path))
            let rootPaths = roots.map(\.path)
            await MainActor.run {
                self.multiRootWorkspace.updateDiscoveryRunning = false
                self.multiRootWorkspace.running = true
                self.multiRootWorkspace.updateRetryAvailable = true
                self.beginFeedbackOperation(
                    rebase ? "Update Project (rebase)" : "Update Project",
                    cancelHandle: cancel
                )
            }
            let preflight: UpdateProjectPreflight? = rebase
                ? try prepareMultiRootUpdate(
                    scanRoot: projectPath,
                    selectedRootPaths: nil,
                    tagMode: tagMode,
                    broker: broker,
                    cancel: cancel
                )
                : nil
            let decision: UpdateRebaseOverMergeDecision
            if rebase, let preflight, !preflight.problematicRootPaths.isEmpty {
                let problematicRoots = roots.filter {
                    preflight.problematicRootPaths.contains($0.path)
                }
                decision = await MainActor.run {
                    presentUpdateRebaseOverMergeDialog(problematicRoots: problematicRoots)
                }
            } else {
                decision = .rebaseAnyway
            }
            guard decision != .cancel else {
                await MainActor.run {
                    self.multiRootWorkspace.running = false
                    self.multiRootWorkspace.updateRetryAvailable = false
                    self.feedbackCenter.warning(
                        "Update Project cancelled",
                        detail: "No working tree changes were applied."
                    )
                }
                return
            }
            let rebaseRootPaths: [String]? = decision == .mergeInstead
                ? rootPaths.filter { !(preflight?.problematicRootPaths.contains($0) ?? false) }
                : nil
            await MainActor.run {
                self.multiRootWorkspace.updateRebaseRootPaths = rebaseRootPaths.map(Set.init)
            }
            let previousHeads = Self.headCommitIDs(for: rootPaths)
            let previousHeadBranches = Self.headBranchNames(for: rootPaths)
            let results = try runMultiRootUpdateSelectedWithMethodsAndOptions(
                scanRoot: projectPath,
                selectedRootPaths: nil,
                rebase: rebase,
                rebaseRootPaths: rebaseRootPaths,
                prefetchedRootPaths: preflight?.fetchedRootPaths,
                broker: broker,
                cancel: cancel,
                tagMode: tagMode,
                savePolicy: projectSavePolicy
            )
            let currentHeads = Self.headCommitIDs(for: rootPaths)
            let revisionRanges = Self.updateSessionRevisionRanges(
                previousHeads: previousHeads,
                currentHeads: currentHeads,
                results: results
            )
            let updatedFilesCount = Self.updateSessionUpdatedFilesCount(revisionRanges)
            let rollbackTargets = Self.updateSessionRollbackTargets(
                previousHeads: previousHeads,
                currentHeads: currentHeads,
                results: results,
                submoduleRootPaths: Array(submoduleRootPaths),
                previousHeadBranches: previousHeadBranches
            )
            let recoveryTargets = Self.updateRootRecoveryTargets(
                results: results,
                roots: roots.map {
                    UpdateRootRecoveryRoot(
                        path: $0.path,
                        displayName: $0.displayName,
                        isSubmodule: $0.isSubmodule,
                        headBranch: $0.headBranch
                    )
                }
            )
            await MainActor.run {
                self.multiRootWorkspace.results = results
                self.multiRootWorkspace.updateDiscoveryRunning = false
                self.multiRootWorkspace.running = false
                for result in results {
                    if result.success || result.skipped {
                        self.stashRecovery.multiRootUpdateStashedRoots.remove(result.rootPath)
                    } else if result.message.localizedCaseInsensitiveContains("local changes remain in stash")
                                || result.message.localizedCaseInsensitiveContains("local changes remain in shelf")
                                || result.message.localizedCaseInsensitiveContains("local restore conflicted") {
                        self.stashRecovery.multiRootUpdateStashedRoots.insert(result.rootPath)
                    }
                }
                self.loadMultiRoots()
                let failed = results.filter { !$0.success }.count
                let cancelled = results.contains {
                    $0.message.localizedCaseInsensitiveContains("cancelled")
                }
                let hasEligibleRoot = Self.updateProjectHasEligibleRoot(results)
                let updateNotReady = Self.updateProjectIsNotReady(results)
                if !cancelled && updateNotReady {
                    if let notificationID = self.multiRootUpdateNotificationID(partial: false) {
                        self.feedbackCenter.expire(notificationID: notificationID)
                    }
                    if let notificationID = self.multiRootUpdateNotificationID(partial: true) {
                        self.feedbackCenter.expire(notificationID: notificationID)
                    }
                    self.operationRecovery.viewMode = .roots
                    self.projectWorkspace.toolWindowMode = .operations
                    self.toolWindowExpanded = true
                    let details = Self.multiRootUpdateFailureDetails(
                        results,
                        submoduleRootPaths: submoduleRootPaths
                    )
                    var recoveryActions = self.updateRootRecoveryActions(recoveryTargets)
                    recoveryActions.insert(
                        FeedbackAction(title: "Open Conflict Workbench") {
                            self.openMultiRootConflictResolver()
                        },
                        at: 0
                    )
                    self.feedbackCenter.error(
                        "Update Project unavailable",
                        detail: details.isEmpty
                            ? "Update Project cannot start because a Git root is not ready."
                            : "Update Project cannot start.\n" + details.joined(separator: "\n"),
                        nextStep: "Resolve the ongoing Git operation or unresolved conflicts, then retry Update Project.",
                        additionalActions: recoveryActions,
                        notificationID: self.multiRootUpdateErrorNotificationID(),
                        notificationGroup: .important
                    )
                    self.feedbackCenter.attachResultRows(
                        feedbackResultRows(from: results),
                        notificationID: self.multiRootUpdateErrorNotificationID()
                    )
                } else if failed == 0 && !cancelled && !hasEligibleRoot {
                    if let notificationID = self.multiRootUpdateNotificationID(partial: false) {
                        self.feedbackCenter.expire(notificationID: notificationID)
                    }
                    if let notificationID = self.multiRootUpdateNotificationID(partial: true) {
                        self.feedbackCenter.expire(notificationID: notificationID)
                    }
                    self.operationRecovery.viewMode = .roots
                    self.projectWorkspace.toolWindowMode = .operations
                    self.toolWindowExpanded = true
                    let skippedDetails = Self.skippedUpdateRootDetails(results)
                    let detail = skippedDetails.isEmpty
                        ? "No Git root has a checked-out branch with a configured upstream."
                        : "No Git root can be updated.\n" + skippedDetails.joined(separator: "\n")
                    let recoveryActions = self.updateRootRecoveryActions(recoveryTargets)
                    self.feedbackCenter.error(
                        "Update Project unavailable",
                        detail: detail,
                        nextStep: recoveryActions.isEmpty
                            ? "Check out a branch and configure its upstream, then retry Update Project."
                            : "Configure an upstream or check out a branch, then retry Update Project.",
                        additionalActions: recoveryActions,
                        notificationID: self.multiRootUpdateErrorNotificationID(),
                        notificationGroup: .important
                    )
                    self.feedbackCenter.attachResultRows(
                        feedbackResultRows(from: results),
                        notificationID: self.multiRootUpdateErrorNotificationID()
                    )
                } else if failed == 0 && !cancelled {
                    if let notificationID = self.multiRootUpdateErrorNotificationID() {
                        self.feedbackCenter.expire(notificationID: notificationID)
                    }
                    if let notificationID = self.multiRootUpdateNotificationID(partial: true) {
                        self.feedbackCenter.expire(notificationID: notificationID)
                    }
                    let viewCommitsAction = self.multiRootUpdateViewCommitsAction(
                        ranges: revisionRanges
                    )
                    let recoveryActions = self.updateRootRecoveryActions(recoveryTargets)
                    self.feedbackCenter.success(
                        rebase ? "Update Project completed (rebase)" : "Update Project completed",
                        detail: Self.multiRootUpdateSuccessDetail(
                            results,
                            updatedFilesCount: revisionRanges.isEmpty ? nil : updatedFilesCount
                        ),
                        additionalActions: (viewCommitsAction.map { [$0] } ?? []) + recoveryActions,
                        notificationID: self.multiRootUpdateNotificationID(partial: false),
                        notificationGroup: .standard
                    )
                    self.autoOpenUpdateInfoIfEnabled(revisionRanges)
                } else {
                    if let notificationID = self.multiRootUpdateErrorNotificationID() {
                        self.feedbackCenter.expire(notificationID: notificationID)
                    }
                    if let notificationID = self.multiRootUpdateNotificationID(partial: false) {
                        self.feedbackCenter.expire(notificationID: notificationID)
                    }
                    self.operationRecovery.viewMode = .roots
                    self.projectWorkspace.toolWindowMode = .operations
                    self.toolWindowExpanded = true
                    var details = Self.multiRootUpdateFailureDetails(
                        results,
                        submoduleRootPaths: submoduleRootPaths
                    )
                    if !revisionRanges.isEmpty {
                        details.insert(
                            Self.multiRootUpdateSuccessDetail(
                                results,
                                updatedFilesCount: updatedFilesCount
                            ),
                            at: 0
                        )
                    }
                    let retryPaths = results.filter { !$0.success }.map(\.rootPath)
                    var additionalActions = [FeedbackAction]()
                    if !retryPaths.isEmpty {
                        let retryRequest = makeMultiRootRetryRequest(
                            operation: .update,
                            rootPaths: retryPaths,
                            rebase: rebase,
                            rebaseRootPaths: self.multiRootWorkspace.updateRebaseRootPaths.map(Array.init)
                        )
                        additionalActions.append(
                            FeedbackAction(
                                title: "Retry Failed Update Roots",
                                semanticAction: retryRequest
                            ) {
                                self.handleVCSActionRequest(retryRequest)
                            }
                        )
                    }
                    if let viewCommitsAction = self.multiRootUpdateViewCommitsAction(
                        ranges: revisionRanges
                    ) {
                        additionalActions.insert(viewCommitsAction, at: 0)
                    }
                    additionalActions.append(contentsOf: self.updateRootRecoveryActions(recoveryTargets))
                    if let rollbackAction = self.multiRootUpdateRollbackAction(
                        targets: rollbackTargets
                    ) {
                        additionalActions.append(rollbackAction)
                    }
                    self.feedbackCenter.warning(
                        rebase ? "Update Project partially completed (rebase)" : "Update Project partially completed",
                        detail: details.joined(separator: "\n"),
                        nextStep: "Resolve conflicted roots, then continue or abort their Git operation.",
                        actionTitle: "Resolve Conflicts",
                        action: {
                            NotificationCenter.default.post(
                                name: .arborOpenMultiRootConflictResolver,
                                object: nil
                            )
                        },
                        additionalActions: additionalActions,
                        notificationID: self.multiRootUpdateNotificationID(partial: true),
                        notificationGroup: .standard
                    )
                    self.autoOpenUpdateInfoIfEnabled(revisionRanges)
                    self.presentMultiRootUpdateRestoreConflicts(results)
                    self.recoverMultiRootUpdateStashesAfterFailure(results)
                }
            }
        } catch {
            await MainActor.run {
                self.multiRootWorkspace.updateDiscoveryRunning = false
                self.multiRootWorkspace.running = false
                if let notificationID = self.multiRootUpdateNotificationID(partial: false) {
                    self.feedbackCenter.expire(notificationID: notificationID)
                }
                if let notificationID = self.multiRootUpdateNotificationID(partial: true) {
                    self.feedbackCenter.expire(notificationID: notificationID)
                }
                self.feedbackCenter.error(
                    "Update Project failed",
                    detail: errorMessage(error),
                    nextStep: "检查各 Git root 的 upstream 和认证配置后重试。",
                    notificationID: self.multiRootUpdateErrorNotificationID()
                )
                if self.isAuthenticationFailure(error) {
                    self.hostingWorkspace.showHostingAuthPrompt = true
                }
            }
        }
    }
}

}
