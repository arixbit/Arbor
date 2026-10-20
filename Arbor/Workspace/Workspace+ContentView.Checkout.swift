import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
func checkoutFromLog(_ commit: CommitInfo) {
    guard let repo = logRepository(for: commit) else { return }
    let alert = NSAlert()
    alert.messageText = "Checkout revision?"
    alert.informativeText = "This will detach HEAD at \(commit.shortId). Uncommitted changes must be clean."
    alert.addButton(withTitle: "Checkout")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    beginFeedbackOperation("Checkout revision")
    let id = commit.id
    Task.detached(priority: .userInitiated) {
        do {
            try repo.checkoutDetached(commitId: id)
            await MainActor.run {
                self.commitWorkspace.feedback = "已 checkout \(String(id.prefix(7)))"
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
            }
        } catch {
            let detail = errorMessage(error)
            await MainActor.run {
                self.commitWorkspace.feedback = detail
                self.presentCheckoutRecovery(
                    repo: repo,
                    name: id,
                    detail: detail,
                    onSmart: { self.smartCheckoutDetached(repo: repo, revision: id) },
                    onForce: { self.forceCheckoutDetached(repo: repo, revision: id) }
                )
            }
        }
    }
}

/// BRANCH-001：Checkout 并同步远程（update = merge,rebase = --rebase）。
func checkoutAndUpdate(_ name: String, rebase: Bool) {
    guard let repo else { return }
    if rebase {
        checkoutAndRebaseOntoCurrent(repo: repo, name: name)
        return
    }
    guard let upstream = checkoutAndUpdateUpstream(
        branch: name,
        syncStatuses: branchWorkspace.syncStatuses
    ) else {
        feedbackCenter.warning(
            "Checkout and Update unavailable",
            detail: "The branch no longer has a valid tracking branch.",
            nextStep: "Refresh Git State, then retry Checkout and Update."
        )
        return
    }
    beginFeedbackOperation("Checkout and update")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.switchBranch(name: name)
            await MainActor.run {
                self.finishCheckoutAndUpdate(
                    repo: repo,
                    name: name,
                    upstream: upstream,
                    rebase: rebase
                )
            }
        } catch {
            let detail = errorMessage(error)
            await MainActor.run {
                self.presentCheckoutRecovery(
                    repo: repo,
                    name: name,
                    detail: detail,
                    onSmart: {
                        self.smartCheckoutBranch(repo: repo, name: name) {
                            self.finishCheckoutAndUpdate(
                                repo: repo,
                                name: name,
                                upstream: upstream,
                                rebase: rebase
                            )
                        }
                    },
                    onForce: {
                        self.forceCheckoutBranch(repo: repo, name: name) {
                            self.finishCheckoutAndUpdate(
                                repo: repo,
                                name: name,
                                upstream: upstream,
                                rebase: rebase
                            )
                        }
                    }
                )
            }
        }
    }
}

func finishCheckoutAndUpdate(
    repo: Repository,
    name: String,
    upstream: String?,
    rebase: Bool
) {
    guard let upstream, upstream.contains("/") else {
        feedbackCenter.success("Checked out and updated", detail: name)
        refreshAll(showFeedback: false)
        loadRepoData()
        return
    }

    beginFeedbackOperation("Checkout and Update")
    pullAfterCheckout(
        repo: repo,
        upstream: upstream,
        onComplete: { self.feedbackCenter.success("Checked out and updated", detail: name) }
    )
}

func executeMultiRootCheckout(reference: String, detach: Bool) {
    performMultiRootCheckout(reference: reference, detach: detach, mode: .normal, offerRecovery: true)
}

func performMultiRootCheckout(
    reference: String,
    detach: Bool,
    mode: MultiRootCheckoutMode,
    offerRecovery: Bool
) {
    multiRootWorkspace.updateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryContext = nil
    guard let projectPath = projectWorkspace.path, !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        feedbackCenter.warning("Checkout cancelled", detail: "A branch, tag, or revision is required.")
        return
    }
    multiRootWorkspace.running = true
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
    beginFeedbackOperation(mode == .normal ? "Multi-root checkout" : "Multi-root \(mode == .smart ? "Smart" : "Force") Checkout")
    Task.detached(priority: .userInitiated) {
        do {
            let initialRoots = try Arbor.discoverGitRoots(scanRoot: projectPath, maxDepth: nil)
            let initialSnapshots = try Arbor.listMultiRootBranches(scanRoot: projectPath)
            let savedChangeIDsBefore = mode == .smart
                ? Self.savedChangeIDsByRoot(rootPaths: initialRoots.map(\.path))
                : (stashes: [:], shelves: [:])
            let results = try Arbor.runMultiRootCheckoutWithPolicy(
                scanRoot: projectPath,
                reference: reference,
                detach: detach,
                mode: mode,
                savePolicy: projectSavePolicy
            )
            let newSavedChangeIDs = mode == .smart
                ? Self.newSavedChangeIDsByRoot(
                    rootPaths: results.map(\.rootPath),
                    before: savedChangeIDsBefore,
                    stashMessagePrefix: "Arbor: Smart Checkout to \(reference)",
                    shelfNamePrefix: "Arbor: Smart Checkout to \(reference)"
                )
                : (stashes: [:], shelves: [:])
            await MainActor.run {
                self.multiRootWorkspace.results = results
                self.multiRootWorkspace.running = false
                let failures = results.filter { !$0.success }
                let initialRootsByPath = Dictionary(uniqueKeysWithValues: initialRoots.map { ($0.path, $0) })
                let initialSnapshotsByPath = Dictionary(uniqueKeysWithValues: initialSnapshots.map { ($0.rootPath, $0) })
                let finalRootsByPath: [String: GitRootInfo] = (try? Arbor.discoverGitRoots(
                    scanRoot: projectPath,
                    maxDepth: nil
                ))
                .map { Dictionary(uniqueKeysWithValues: $0.map { ($0.path, $0) }) } ?? [:]
                let successfulTargets: [MultiRootBranchTarget] = mode == .normal
                    ? results
                        .filter { $0.success && !$0.skipped }
                        .compactMap { result in
                            guard let root = initialRootsByPath[result.rootPath],
                                  let finalRoot = finalRootsByPath[result.rootPath],
                                  let expectedHead = finalRoot.headId else { return nil }
                            return MultiRootBranchTarget(
                                rootPath: root.path,
                                checkedOut: true,
                                previousBranch: root.headBranch,
                                previousHead: root.headId,
                                expectedHead: expectedHead,
                                expectedBranch: finalRoot.headBranch,
                                createdBranch: createdCheckoutBranch(
                                    reference: reference,
                                    detach: detach,
                                    snapshot: initialSnapshotsByPath[result.rootPath]
                                )
                            )
                        }
                    : []
                if failures.isEmpty {
                    self.feedbackCenter.success(
                        mode == .normal ? "Multi-root checkout complete" : "Multi-root checkout restored",
                        detail: "\(results.count) roots · \(reference)"
                    )
                    self.loadMultiRoots()
                } else if mode == .normal && offerRecovery,
                          failures.contains(where: isCheckoutOverwriteFailure) {
                    self.presentMultiRootCheckoutRecovery(
                        reference: reference,
                        detach: detach,
                        failures: failures,
                        successfulTargets: successfulTargets
                    )
                } else if mode == .normal && offerRecovery && !successfulTargets.isEmpty {
                    self.presentMultiRootCheckoutPartialResult(
                        reference: reference,
                        failures: failures,
                        successfulTargets: successfulTargets
                    )
                } else {
                    let savedChangesActions = results.compactMap { result -> FeedbackAction? in
                        if let stashID = newSavedChangeIDs.stashes[result.rootPath] {
                            return self.savedChangesFeedbackAction(
                                kind: .stash,
                                identifier: stashID,
                                rootPath: result.rootPath
                            )
                        }
                        if let shelfName = newSavedChangeIDs.shelves[result.rootPath] {
                            return self.savedChangesFeedbackAction(
                                kind: .shelf,
                                identifier: shelfName,
                                rootPath: result.rootPath
                            )
                        }
                        return nil
                    }
                    self.feedbackCenter.error(
                        mode == .normal ? "Multi-root checkout failed" : "Multi-root checkout paused",
                        detail: failures.map { "\($0.displayName): \($0.message)" }.joined(separator: "\n"),
                        nextStep: "Resolve the affected roots, then retry checkout.",
                        additionalActions: savedChangesActions
                    )
                    self.loadMultiRoots()
                    self.presentMultiRootShelfRestoreConflicts(results)
                }
            }
        } catch {
            await MainActor.run {
                self.multiRootWorkspace.running = false
                self.feedbackCenter.error(
                    "Multi-root checkout failed",
                    detail: errorMessage(error),
                    nextStep: "Resolve the affected roots, then retry checkout."
                )
            }
        }
    }
}

func presentMultiRootCheckoutRecovery(
    reference: String,
    detach: Bool,
    failures: [RootOperationResult],
    successfulTargets: [MultiRootBranchTarget] = []
) {
    let alert = NSAlert()
    alert.messageText = "Local changes would be overwritten in multiple Git roots"
    alert.informativeText = failures
        .map { "\($0.displayName): \($0.message)" }
        .joined(separator: "\n")
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Smart Checkout All")
    alert.addButton(withTitle: "Force Checkout All")
    alert.addButton(withTitle: "Cancel")
    switch alert.runModal() {
    case .alertFirstButtonReturn:
        performMultiRootCheckout(
            reference: reference,
            detach: detach,
            mode: .smart,
            offerRecovery: false
        )
    case .alertSecondButtonReturn:
        performMultiRootCheckout(
            reference: reference,
            detach: detach,
            mode: .force,
            offerRecovery: false
        )
    default:
        if successfulTargets.isEmpty {
            feedbackCenter.warning("Checkout cancelled", detail: "Local changes were kept in every root.")
        } else {
            presentMultiRootCheckoutPartialResult(
                reference: reference,
                failures: failures,
                successfulTargets: successfulTargets
            )
        }
    }
}

func presentMultiRootCheckoutPartialResult(
    reference: String,
    failures: [RootOperationResult],
    successfulTargets: [MultiRootBranchTarget]
) {
    operationRecovery.viewMode = .roots
    projectWorkspace.toolWindowMode = .operations
    toolWindowExpanded = true
    let rollbackRequest = ArborVCSActionRequest(
        kind: .rollbackMultiRootCheckout,
        projectPath: projectWorkspace.path,
        rootPath: nil,
        shelfName: "",
        checkoutReference: reference,
        checkoutTargets: successfulTargets.map(PersistedMultiRootCheckoutTarget.init)
    )
    feedbackCenter.warning(
        "Multi-root checkout partially completed",
        detail: failures.map { "\($0.displayName): \($0.message)" }.joined(separator: "\n"),
        nextStep: "Keep the successful roots checked out or rollback them to their previous HEAD.",
        additionalActions: [
            FeedbackAction(
                title: "Rollback Successful Roots",
                semanticAction: rollbackRequest
            ) {
                self.handleVCSActionRequest(rollbackRequest)
            }
        ],
        notificationID: multiRootCheckoutRollbackNotificationID()
    )
    loadMultiRoots()
}

func multiRootCheckoutRollbackNotificationID() -> String? {
    guard let projectPath = projectWorkspace.path, !projectPath.isEmpty else { return nil }
    let stableProject = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.multi-root-checkout.rollback.\(stableProject)"
}

func makeMultiRootCheckoutUpdateRetryRequest(
    reference: String,
    rootPaths: [String],
    detach: Bool,
    rebase: Bool,
    mode: MultiRootCheckoutMode
) -> ArborVCSActionRequest {
    let persistedMode: ArborVCSActionRequest.CheckoutUpdateMode = switch mode {
    case .normal:
        .normal
    case .smart:
        .smart
    case .force:
        .force
    }
    return ArborVCSActionRequest(
        kind: .retryMultiRootOperation,
        projectPath: projectWorkspace.path,
        rootPath: nil,
        shelfName: "",
        checkoutReference: reference,
        multiRootRetryOperation: .checkoutUpdate,
        multiRootRetryRootPaths: rootPaths,
        multiRootRetryRebase: rebase,
        multiRootRetryDetach: detach,
        multiRootRetryCheckoutMode: persistedMode
    )
}

func rollbackMultiRootCheckout(
    _ targets: [MultiRootBranchTarget],
    reference: String
) {
    guard !targets.isEmpty else { return }
    let notificationID = multiRootCheckoutRollbackNotificationID()
    let fullRetryRequest = ArborVCSActionRequest(
        kind: .rollbackMultiRootCheckout,
        projectPath: projectWorkspace.path,
        rootPath: nil,
        shelfName: "",
        checkoutReference: reference,
        checkoutTargets: targets.map(PersistedMultiRootCheckoutTarget.init)
    )
    beginFeedbackOperation(
        "Rollback multi-root checkout",
        notificationID: notificationID
    )
    Task.detached(priority: .userInitiated) {
        do {
            let results = try Arbor.restoreMultiRootCheckout(targets: targets)
            await MainActor.run {
                self.multiRootWorkspace.results = results
                self.loadMultiRoots()
                let failures = results.filter { !$0.success }
                if failures.isEmpty {
                    self.feedbackCenter.success(
                        "Checkout rollback completed",
                        detail: reference,
                        notificationID: notificationID,
                        notificationGroup: .standard
                    )
                } else {
                    let failedRootPaths = Set(failures.map(\.rootPath))
                    let remainingTargets = targets.filter { failedRootPaths.contains($0.rootPath) }
                    let retryRequest = ArborVCSActionRequest(
                        kind: .rollbackMultiRootCheckout,
                        projectPath: projectWorkspace.path,
                        rootPath: nil,
                        shelfName: "",
                        checkoutReference: reference,
                        checkoutTargets: remainingTargets.map(PersistedMultiRootCheckoutTarget.init)
                    )
                    self.feedbackCenter.warning(
                        "Checkout rollback partially failed",
                        detail: failures.map { "\($0.displayName): \($0.message)" }.joined(separator: "\n"),
                        nextStep: "Review the affected roots and retry the remaining rollback targets.",
                        additionalActions: remainingTargets.isEmpty
                            ? []
                            : [FeedbackAction(
                                title: "Retry Checkout Rollback",
                                semanticAction: retryRequest
                            ) {
                                self.handleVCSActionRequest(retryRequest)
                            }],
                        notificationID: notificationID,
                        notificationGroup: .important
                    )
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Checkout rollback failed",
                    detail: errorMessage(error),
                    nextStep: "Review the affected roots and retry the rollback action.",
                    additionalActions: [FeedbackAction(
                        title: "Retry Checkout Rollback",
                        semanticAction: fullRetryRequest
                    ) {
                        self.handleVCSActionRequest(fullRetryRequest)
                    }],
                    notificationID: notificationID,
                    notificationGroup: .important
                )
            }
        }
    }
}

/// BRANCH-001：在选中的 Git root 集合上执行 Checkout and Update / Checkout
/// with Rebase。Branches Popup 传入单 root，项目级入口可以传入全部 roots。
func executeMultiRootCheckoutAndUpdate(
    reference: String,
    rootPath: String? = nil,
    detach: Bool,
    rebase: Bool
) {
    performMultiRootCheckoutAndUpdate(
        reference: reference,
        selectedRootPaths: rootPath.map { [$0] },
        detach: detach,
        rebase: rebase,
        mode: .normal,
        offerRecovery: true
    )
}

func performMultiRootCheckoutAndUpdate(
    reference: String,
    selectedRootPaths: [String]?,
    detach: Bool,
    rebase: Bool,
    mode: MultiRootCheckoutMode,
    offerRecovery: Bool,
    mergeResults: Bool = false
) {
    multiRootWorkspace.updateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryContext = nil
    guard let projectPath = projectWorkspace.path, !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        feedbackCenter.warning("Checkout cancelled", detail: "A branch, tag, or revision is required.")
        return
    }
    let broker = credentialAuth.broker
    let cancel = GitCancelHandle()
    multiRootWorkspace.running = true
    let modeLabel = mode == .smart ? "Smart" : "Force"
    beginFeedbackOperation(
        mode == .normal
            ? (rebase ? "Checkout with Rebase" : "Checkout and Update")
            : "Multi-root \(modeLabel) Checkout and Update",
        cancelHandle: cancel,
        notificationID: multiRootRetryNotificationID(.checkoutUpdate)
    )
    let fetchTagMode = fetchTagsMode
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectPath)
    Task.detached(priority: .userInitiated) {
        do {
            let initialRoots = try Arbor.discoverGitRoots(scanRoot: projectPath, maxDepth: nil)
            let initialSnapshots = try Arbor.listMultiRootBranches(scanRoot: projectPath)
            let savedChangeIDsBefore: (stashes: [String: Set<String>], shelves: [String: Set<String>])
            if mode == .smart {
                savedChangeIDsBefore = Self.savedChangeIDsByRoot(rootPaths: initialRoots.map(\.path))
            } else {
                savedChangeIDsBefore = (stashes: [:], shelves: [:])
            }
            let results = try Arbor.runMultiRootCheckoutAndUpdateWithPolicyAndOptions(
                scanRoot: projectPath,
                selectedRootPaths: selectedRootPaths,
                reference: reference,
                detach: detach,
                rebase: rebase,
                mode: mode,
                tagMode: fetchTagMode,
                broker: broker,
                cancel: cancel,
                savePolicy: projectSavePolicy
            )
            let finalRoots = (try? Arbor.discoverGitRoots(scanRoot: projectPath, maxDepth: nil)) ?? []
            let newSavedChangeIDs = mode == .smart
                ? Self.newSavedChangeIDsByRoot(
                    rootPaths: results.map(\.rootPath),
                    before: savedChangeIDsBefore,
                    stashMessagePrefix: "Arbor: Checkout and Update to \(reference)",
                    shelfNamePrefix: "Arbor: Checkout and Update to \(reference)"
                )
                : (stashes: [:], shelves: [:])
            await MainActor.run {
                if mergeResults {
                    let retryByRoot = Dictionary(uniqueKeysWithValues: results.map { ($0.rootPath, $0) })
                    self.multiRootWorkspace.results = self.multiRootWorkspace.results.map { retryByRoot[$0.rootPath] ?? $0 }
                } else {
                    self.multiRootWorkspace.results = results
                }
                self.multiRootWorkspace.running = false
                let failures = results.filter { !$0.success }
                let successfulRollbackTargets: [MultiRootBranchTarget] = (!mergeResults && mode != .force)
                    ? results
                        .filter { $0.success && !$0.skipped }
                        .compactMap { result in
                            guard let initialRoot = initialRoots.first(where: { $0.path == result.rootPath }),
                                  let finalRoot = finalRoots.first(where: { $0.path == result.rootPath }),
                                  let expectedHead = finalRoot.headId else { return nil }
                            let initialSnapshot = initialSnapshots.first(where: { $0.rootPath == result.rootPath })
                            return MultiRootBranchTarget(
                                rootPath: result.rootPath,
                                checkedOut: true,
                                previousBranch: initialRoot.headBranch,
                                previousHead: initialRoot.headId,
                                expectedHead: expectedHead,
                                expectedBranch: finalRoot.headBranch,
                                createdBranch: createdCheckoutBranch(
                                    reference: reference,
                                    detach: detach,
                                    snapshot: initialSnapshot
                                )
                            )
                        }
                    : []
                if failures.isEmpty {
                    self.multiRootWorkspace.checkoutUpdateRetryAvailable = false
                    self.multiRootWorkspace.checkoutUpdateRetryContext = nil
                } else {
                    self.multiRootWorkspace.checkoutUpdateRetryAvailable = true
                    self.multiRootWorkspace.checkoutUpdateRetryContext = MultiRootCheckoutUpdateRetryContext(
                        reference: reference,
                        selectedRootPaths: failures.map(\.rootPath),
                        detach: detach,
                        rebase: rebase,
                        mode: mode
                    )
                }
                let dirtyFailure = failures.contains(where: isCheckoutOverwriteFailure)
                if failures.isEmpty {
                    let skipped = results.filter(\.skipped).count
                    self.feedbackCenter.success(
                        rebase ? "Checkout with Rebase completed" : "Checkout and Update completed",
                        detail: "\(results.count - skipped) updated · \(skipped) skipped · \(reference)"
                    )
                    self.loadMultiRoots()
                } else if mode == .normal && offerRecovery && dirtyFailure {
                    self.presentMultiRootCheckoutAndUpdateRecovery(
                        reference: reference,
                        selectedRootPaths: selectedRootPaths,
                        detach: detach,
                        rebase: rebase,
                        failures: failures
                    )
                } else {
                    self.operationRecovery.viewMode = .roots
                    self.projectWorkspace.toolWindowMode = .operations
                    self.toolWindowExpanded = true
                    let retryRequest = self.makeMultiRootCheckoutUpdateRetryRequest(
                        reference: reference,
                        rootPaths: failures.map(\.rootPath),
                        detach: detach,
                        rebase: rebase,
                        mode: mode
                    )
                    let rollbackRequest = successfulRollbackTargets.isEmpty
                        ? nil
                        : ArborVCSActionRequest(
                            kind: .rollbackMultiRootCheckout,
                            projectPath: projectPath,
                            rootPath: nil,
                            shelfName: "",
                            checkoutReference: reference,
                            checkoutTargets: successfulRollbackTargets.map(PersistedMultiRootCheckoutTarget.init)
                        )
                    var recoveryActions: [FeedbackAction] = [
                        FeedbackAction(
                            title: "Retry Failed Checkout Roots",
                            semanticAction: retryRequest
                        ) {
                            self.handleVCSActionRequest(retryRequest)
                        }
                    ]
                    if let rollbackRequest {
                        recoveryActions.append(
                            FeedbackAction(
                                title: "Rollback Successful Roots",
                                semanticAction: rollbackRequest
                            ) {
                                self.handleVCSActionRequest(rollbackRequest)
                            }
                        )
                    }
                    self.feedbackCenter.warning(
                        rebase ? "Checkout with Rebase partially completed" : "Checkout and Update partially completed",
                        detail: failures.map { "\($0.displayName): \($0.message)" }.joined(separator: "\n"),
                        nextStep: successfulRollbackTargets.isEmpty
                            ? "Resolve conflicted roots, then continue or abort their Git operation."
                            : "Retry the failed roots or rollback the roots that already changed.",
                        additionalActions: recoveryActions + results.compactMap { result -> FeedbackAction? in
                            if let stashID = newSavedChangeIDs.stashes[result.rootPath] {
                                return self.savedChangesFeedbackAction(
                                    kind: .stash,
                                    identifier: stashID,
                                    rootPath: result.rootPath
                                )
                            }
                            if let shelfName = newSavedChangeIDs.shelves[result.rootPath] {
                                return self.savedChangesFeedbackAction(
                                    kind: .shelf,
                                    identifier: shelfName,
                                    rootPath: result.rootPath
                                )
                            }
                            return nil
                        },
                        notificationID: self.multiRootRetryNotificationID(.checkoutUpdate)
                    )
                    self.loadMultiRoots()
                    self.presentMultiRootShelfRestoreConflicts(results)
                }
            }
        } catch {
            await MainActor.run {
                self.multiRootWorkspace.running = false
                self.feedbackCenter.error(
                    rebase ? "Checkout with Rebase failed" : "Checkout and Update failed",
                    detail: errorMessage(error),
                    nextStep: "Resolve the affected roots, then retry the operation."
                )
            }
        }
    }
}

/// Retry only roots that failed in the last Checkout and Update / Checkout
/// with Rebase run. Successful roots remain untouched, while the engine still
/// includes any required parent Git roots for a selected nested repository.
func retryMultiRootCheckoutAndUpdateFailedRoots(
    reference: String? = nil,
    selectedRootPaths: [String]? = nil,
    detach: Bool? = nil,
    rebase: Bool? = nil,
    checkoutMode: ArborVCSActionRequest.CheckoutUpdateMode? = nil
) {
    guard !multiRootWorkspace.running else { return }
    let context = multiRootWorkspace.checkoutUpdateRetryContext
    guard let reference = reference ?? context?.reference,
          let requestedRootPaths = selectedRootPaths ?? context?.selectedRootPaths,
          let detach = detach ?? context?.detach,
          let rebase = rebase ?? context?.rebase,
          let mode = checkoutMode.map(engineCheckoutMode)
              ?? context.map(\.mode) else {
        feedbackCenter.warning(
            "Retry unavailable",
            detail: "There is no failed Checkout and Update root to retry."
        )
        return
    }
    let retryableRootPaths: Set<String>
    if selectedRootPaths == nil {
        retryableRootPaths = Set(multiRootWorkspace.results.compactMap { result -> String? in
            guard !result.success,
                  requestedRootPaths.contains(result.rootPath),
                  !stashRecovery.multiRootUpdateStashedRoots.contains(result.rootPath),
                  multiRootWorkspace.roots.first(where: { $0.path == result.rootPath })?.operation == nil else {
                return nil
            }
            return result.rootPath
        })
    } else {
        retryableRootPaths = Set(requestedRootPaths.filter { rootPath in
            !stashRecovery.multiRootUpdateStashedRoots.contains(rootPath)
                && multiRootWorkspace.roots.first(where: { $0.path == rootPath })?.operation == nil
        })
    }
    let selectedRootPaths = requestedRootPaths.filter(retryableRootPaths.contains)
    guard !selectedRootPaths.isEmpty else {
        feedbackCenter.warning(
            "Retry unavailable",
            detail: "There are no failed Checkout and Update roots to retry."
        )
        return
    }
    performMultiRootCheckoutAndUpdate(
        reference: reference,
        selectedRootPaths: selectedRootPaths,
        detach: detach,
        rebase: rebase,
        mode: mode,
        offerRecovery: false,
        mergeResults: true
    )
}

func engineCheckoutMode(
    _ mode: ArborVCSActionRequest.CheckoutUpdateMode
) -> MultiRootCheckoutMode {
    switch mode {
    case .normal:
        return .normal
    case .smart:
        return .smart
    case .force:
        return .force
    }
}

func isCheckoutOverwriteFailure(_ result: RootOperationResult) -> Bool {
    result.message.localizedCaseInsensitiveContains("overwrit")
}

func presentMultiRootCheckoutAndUpdateRecovery(
    reference: String,
    selectedRootPaths: [String]?,
    detach: Bool,
    rebase: Bool,
    failures: [RootOperationResult]
) {
    let alert = NSAlert()
    alert.messageText = "Local changes would be overwritten during checkout"
    alert.informativeText = failures.map { "\($0.displayName): \($0.message)" }.joined(separator: "\n")
    alert.alertStyle = .warning
    alert.addButton(withTitle: rebase ? "Smart Checkout with Rebase" : "Smart Checkout and Update")
    alert.addButton(withTitle: rebase ? "Force Checkout with Rebase" : "Force Checkout and Update")
    alert.addButton(withTitle: "Cancel")
    switch alert.runModal() {
    case .alertFirstButtonReturn:
        performMultiRootCheckoutAndUpdate(
            reference: reference,
            selectedRootPaths: selectedRootPaths,
            detach: detach,
            rebase: rebase,
            mode: .smart,
            offerRecovery: false
        )
    case .alertSecondButtonReturn:
        performMultiRootCheckoutAndUpdate(
            reference: reference,
            selectedRootPaths: selectedRootPaths,
            detach: detach,
            rebase: rebase,
            mode: .force,
            offerRecovery: false
        )
    default:
        feedbackCenter.warning("Checkout cancelled", detail: "Local changes were kept.")
    }
}

func promptForCheckoutReference() -> String? {
    let alert = NSAlert()
    alert.messageText = "Checkout Tag or Revision"
    alert.informativeText = "Enter reference (branch, tag) name or commit hash:"
    let field = NSTextField(string: "")
    field.placeholderString = "branch, tag, or commit"
    field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "Checkout")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let reference = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reference.isEmpty else {
        feedbackCenter.warning(
            "Checkout cancelled",
            detail: "A branch, tag, or revision is required.",
            nextStep: "Run Checkout Tag or Revision again and enter a reference."
        )
        return nil
    }
    return reference
}

func checkoutReferenceFromInput() {
    guard let repo, let reference = promptForCheckoutReference() else { return }
    beginFeedbackOperation("Checkout reference")
    Task.detached(priority: .userInitiated) {
        let target = resolveCheckoutReferenceTarget(repo: repo, reference: reference)
        do {
            try performCheckoutReference(repo: repo, target: target)
            await MainActor.run {
                self.feedbackCenter.success("Reference checked out", detail: reference)
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
            }
        } catch {
            let detail = errorMessage(error)
            await MainActor.run {
                self.presentCheckoutRecovery(
                    repo: repo,
                    name: reference,
                    detail: detail,
                    onSmart: {
                        self.smartCheckoutReference(repo: repo, target: target)
                    },
                    onForce: {
                        self.forceCheckoutReference(repo: repo, target: target)
                    }
                )
            }
        }
    }
}

/// Multi-root input checkout follows IntelliJ's repository selection: a
/// selected repository is targeted alone; otherwise the reference is tried in
/// every discovered Git root and each root reports its own recovery state.
func checkoutReferenceFromInput(rootPath: String?) {
    guard let reference = promptForCheckoutReference() else { return }
    if let rootPath {
        checkoutReferenceInRoot(rootPath: rootPath, reference: reference)
    } else {
        // The engine resolves local/remote/detached references independently
        // in every root and provides the aggregate Smart/Force/Cancel flow.
        executeMultiRootCheckout(reference: reference, detach: false)
    }
}

func smartCheckoutReference(
    repo: Repository,
    target: CheckoutReferenceTarget,
    onSuccess: @escaping () -> Void = {}
) {
    switch target {
    case let .localBranch(name):
        smartCheckoutBranch(repo: repo, name: name, onSuccess: onSuccess)
    case let .remoteBranch(name):
        smartCheckoutRemoteBranch(repo: repo, remoteBranch: name, onSuccess: onSuccess)
    case let .detached(reference):
        smartCheckoutDetached(repo: repo, revision: reference, onSuccess: onSuccess)
    }
}

func forceCheckoutReference(
    repo: Repository,
    target: CheckoutReferenceTarget,
    onSuccess: @escaping () -> Void = {}
) {
    switch target {
    case let .localBranch(name):
        forceCheckoutBranch(repo: repo, name: name, onSuccess: onSuccess)
    case let .remoteBranch(name):
        forceCheckoutRemoteBranch(repo: repo, remoteBranch: name, onSuccess: onSuccess)
    case let .detached(reference):
        forceCheckoutDetached(repo: repo, revision: reference, onSuccess: onSuccess)
    }
}

func checkoutReferenceInRoot(rootPath: String, reference: String) {
    beginFeedbackOperation("Checkout reference")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let target = resolveCheckoutReferenceTarget(repo: rootRepo, reference: reference)
            do {
                try performCheckoutReference(repo: rootRepo, target: target)
                await MainActor.run {
                    self.feedbackCenter.success(
                        "Reference checked out",
                        detail: "\(reference) · \(rootPath)"
                    )
                    self.loadMultiRoots()
                }
            } catch {
                let detail = errorMessage(error)
                await MainActor.run {
                    self.presentCheckoutRecovery(
                        repo: rootRepo,
                        name: reference,
                        detail: detail,
                        onSmart: {
                            self.smartCheckoutReference(
                                repo: rootRepo,
                                target: target,
                                onSuccess: { self.loadMultiRoots() }
                            )
                        },
                        onForce: {
                            self.forceCheckoutReference(
                                repo: rootRepo,
                                target: target,
                                onSuccess: { self.loadMultiRoots() }
                            )
                        }
                    )
                }
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Checkout reference failed",
                    detail: "\(reference) · \(rootPath): \(errorMessage(error))",
                    nextStep: "Check the repository and reference, then retry."
                )
            }
        }
    }
}

/// IntelliJ GitCheckoutOperation 的单仓库交互：先展示会被覆盖的本地
/// 变更，再让用户选择 Smart Checkout、Force Checkout 或取消。
func presentCheckoutRecovery(
    repo: Repository,
    name: String,
    detail: String,
    onSmart: @escaping () -> Void,
    onForce: @escaping () -> Void
) {
    if (try? repo.operationState()) != nil {
        repositoryStatus.loadError = detail
        feedbackCenter.error(
            "Checkout unavailable",
            detail: detail,
            nextStep: "Continue or abort the operation in progress, then retry checkout."
        )
        return
    }
    let paths = (try? repo.status())?.filter {
        $0.staged != .unchanged
            || ($0.unstaged != .unchanged && $0.unstaged != .ignored)
    }.map(\.path) ?? []
    guard !paths.isEmpty else {
        repositoryStatus.loadError = detail
        feedbackCenter.error("Checkout failed", detail: detail, nextStep: "Check the branch name and repository state.")
        return
    }

    feedbackCenter.warning(
        "Checkout needs a decision",
        detail: paths.joined(separator: ", "),
        nextStep: "Choose Smart Checkout to preserve local changes, or cancel and keep the current worktree."
    )
    presentSmartOperationDecision(
        operationTitle: "Checkout",
        paths: paths,
        detail: detail,
        smartButtonTitle: "Smart Checkout",
        forceButtonTitle: "Force Checkout",
        onSmart: onSmart,
        onForce: onForce
    )
}

func smartCheckoutDetached(
    repo: Repository,
    revision: String,
    onSuccess: @escaping () -> Void = {}
) {
    let cancel = GitCancelHandle()
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    beginFeedbackOperation("Smart Checkout", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            try repo.smartCheckoutDetachedWithPolicyAndCancel(
                commitId: revision,
                savePolicy: projectSavePolicy,
                cancel: cancel
            )
            await MainActor.run {
                self.repositoryStatus.loadError = nil
                self.feedbackCenter.success("Smart Checkout completed", detail: revision)
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
                onSuccess()
            }
        } catch {
            if case .Cancelled = error as? EngineError {
                await MainActor.run {
                    self.feedbackCenter.warning(
                        "Smart Checkout cancelled",
                        detail: revision,
                        nextStep: "The preservation Shelf was kept when restore had started; retry after reviewing the root."
                    )
                }
            } else if case let .StashApplyConflict(paths, stashID) = error as? EngineError {
                await MainActor.run {
                    let viewAction = stashID.flatMap {
                        self.savedChangesFeedbackAction(
                            kind: .stash,
                            identifier: $0,
                            rootPath: repo.workdir()
                        )
                    }
                    self.showStashRestoreConflict(
                        paths,
                        additionalActions: viewAction.map { [$0] } ?? [],
                        stashID: stashID
                    )
                }
            } else if case let .ShelveApplyConflict(name, paths) = error as? EngineError {
                await MainActor.run {
                    let viewAction = self.savedChangesFeedbackAction(
                        kind: .shelf,
                        identifier: name,
                        rootPath: repo.workdir()
                    )
                    self.presentShelveConflict(
                        name: name,
                        paths: paths,
                        isPop: true,
                        additionalActions: viewAction.map { [$0] } ?? []
                    )
                }
            } else {
                await MainActor.run {
                    self.repositoryStatus.loadError = errorMessage(error)
                    self.feedbackCenter.error(
                        "Smart Checkout failed",
                        detail: errorMessage(error),
                        nextStep: "The original local changes were restored when possible."
                    )
                }
            }
        }
    }
}

func forceCheckoutDetached(
    repo: Repository,
    revision: String,
    onSuccess: @escaping () -> Void = {}
) {
    beginFeedbackOperation("Force Checkout")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.forceCheckoutDetached(commitId: revision)
            await MainActor.run {
                self.repositoryStatus.loadError = nil
                self.feedbackCenter.success("Force Checkout completed", detail: revision)
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
                onSuccess()
            }
        } catch {
            await MainActor.run {
                self.repositoryStatus.loadError = errorMessage(error)
                self.feedbackCenter.error("Force Checkout failed", detail: errorMessage(error))
            }
        }
    }
}

}
