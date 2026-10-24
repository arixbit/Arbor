import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {

func presentNewBranchDialog(
    baseRevision: String? = nil,
    suggestedName: String? = nil,
    title: String? = nil,
    afterCreateRebase: Bool = false,
    repositoryOverride: Repository? = nil
) {
    branchWorkspace.newName = suggestedName ?? ""
    branchWorkspace.newBase = baseRevision ?? ""
    branchWorkspace.newDialogTitle = title ?? String(localized: "New Branch")
    branchWorkspace.newCheckout = true
    branchWorkspace.newResetExisting = false
    branchWorkspace.newAfterCreateRebase = afterCreateRebase
    branchWorkspace.newRepositoryOverride = repositoryOverride
    if let targetRepo = repositoryOverride ?? repo {
        branchWorkspace.newDialogBranches = (try? targetRepo.branchList()) ?? branchWorkspace.branches
    } else {
        branchWorkspace.newDialogBranches = branchWorkspace.branches
    }
    branchWorkspace.showNewDialog = true
}

func dismissNewBranchDialog() {
    branchWorkspace.showNewDialog = false
    branchWorkspace.newDialogTitle = String(localized: "New Branch")
    branchWorkspace.newName = ""
    branchWorkspace.newBase = ""
    branchWorkspace.newCheckout = true
    branchWorkspace.newResetExisting = false
    branchWorkspace.newAfterCreateRebase = false
    branchWorkspace.newRepositoryOverride = nil
    branchWorkspace.newDialogBranches = []
}

/// Shared Branch Dashboard semantics for a single Git root. IntelliJ's
/// Checkout as New Branch keeps the selected ref as the start point; the
/// remote Checkout with Rebase variant creates the local branch first and
/// then rebases it onto the current branch.
func presentNewBranchFromReference(
    _ reference: String,
    isRemote: Bool,
    afterCreateRebase: Bool = false,
    rootPath: String? = nil
) {
    let trimmedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedReference.isEmpty else { return }
    let suggestedName: String
    if isRemote,
       let separator = trimmedReference.firstIndex(of: "/") {
        let suffixStart = trimmedReference.index(after: separator)
        suggestedName = suffixStart < trimmedReference.endIndex
            ? String(trimmedReference[suffixStart...])
            : trimmedReference
    } else {
        suggestedName = trimmedReference
    }
    let repositoryOverride: Repository?
    if let rootPath {
        guard let selectedRepository = try? openRepository(path: rootPath) else {
            feedbackCenter.warning(
                "Checkout with Rebase unavailable",
                detail: "The selected Git root could not be opened.",
                nextStep: "Refresh Git Roots, then retry from the branch or tag."
            )
            return
        }
        repositoryOverride = selectedRepository
    } else {
        repositoryOverride = nil
    }
    presentNewBranchDialog(
        baseRevision: trimmedReference,
        suggestedName: afterCreateRebase ? suggestedName : suggestedName + "-copy",
        title: afterCreateRebase ? "Checkout with Rebase" : "Checkout as New Branch",
        afterCreateRebase: afterCreateRebase,
        repositoryOverride: repositoryOverride
    )
}

func presentMultiRootNewBranchDialog() {
    guard !multiRootWorkspace.branchSnapshots.isEmpty else {
        loadMultiRoots()
        feedbackCenter.warning("New branch unavailable", detail: "No Git roots were discovered.")
        return
    }
    branchWorkspace.multiRootNewName = ""
    branchWorkspace.multiRootNewBase = ""
    branchWorkspace.multiRootNewCheckout = true
    branchWorkspace.multiRootNewResetExisting = false
    branchWorkspace.multiRootExistingNames = Dictionary(
        uniqueKeysWithValues: multiRootWorkspace.branchSnapshots.map { snapshot in
            (snapshot.rootPath, Set(snapshot.branches.map(\.name)))
        }
    )
    branchWorkspace.multiRootNewSelectedRootPaths = Set(multiRootWorkspace.branchSnapshots.map(\.rootPath))
    branchWorkspace.showMultiRootNewDialog = true
}

/// IntelliJ's Checkout as New Branch action keeps the selected reference as
/// the base revision and restricts the dialog to the owning Git root.  Do not
/// reuse the project-wide New Branch defaults here: a same-named ref in a
/// nested root must never become the base of the new branch.
func presentMultiRootNewBranchFromReference(
    rootPath: String,
    reference: String,
    isRemote: Bool
) {
    guard multiRootWorkspace.branchSnapshots.contains(where: { $0.rootPath == rootPath }) else {
        feedbackCenter.warning(
            "Checkout as New Branch unavailable",
            detail: "The selected Git root is no longer available: \(rootPath)"
        )
        loadMultiRoots()
        return
    }

    let trimmedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedReference.isEmpty else {
        feedbackCenter.warning(
            "Checkout as New Branch unavailable",
            detail: "The selected reference is empty."
        )
        return
    }

    let suggestedName: String
    if isRemote,
       let separator = trimmedReference.firstIndex(of: "/") {
        let suffixStart = trimmedReference.index(after: separator)
        suggestedName = suffixStart < trimmedReference.endIndex
            ? String(trimmedReference[suffixStart...])
            : trimmedReference
    } else {
        suggestedName = trimmedReference
    }

    branchWorkspace.multiRootNewName = suggestedName + "-copy"
    branchWorkspace.multiRootNewBase = trimmedReference
    branchWorkspace.multiRootNewCheckout = true
    branchWorkspace.multiRootNewResetExisting = false
    branchWorkspace.multiRootExistingNames = Dictionary(
        uniqueKeysWithValues: multiRootWorkspace.branchSnapshots.map { snapshot in
            (snapshot.rootPath, Set(snapshot.branches.map(\.name)))
        }
    )
    branchWorkspace.multiRootNewSelectedRootPaths = [rootPath]
    branchWorkspace.showMultiRootNewDialog = true
}

func dismissMultiRootNewBranchDialog() {
    branchWorkspace.showMultiRootNewDialog = false
    branchWorkspace.multiRootNewName = ""
    branchWorkspace.multiRootNewBase = ""
    branchWorkspace.multiRootNewCheckout = true
    branchWorkspace.multiRootNewResetExisting = false
    branchWorkspace.multiRootExistingNames = [:]
    branchWorkspace.multiRootNewSelectedRootPaths = []
}

/// BRANCH-001：对选中的 Git roots 创建同名分支。Rust 返回旧 HEAD 与逐 root
/// 状态，Swift 只负责呈现 IntelliJ 风格的部分成功和显式 rollback 决策。
func createMultiRootBranch(
    name: String,
    baseRevision: String,
    checkout: Bool,
    reset: Bool,
    selectedRootPaths: Set<String>
) {
    multiRootWorkspace.updateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryAvailable = false
    multiRootWorkspace.checkoutUpdateRetryContext = nil
    guard let projectPath = projectWorkspace.path else { return }
    let branchName = GitBranchNameCleanup.cleanUp(name)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !branchName.isEmpty else { return }
    let startPoint = baseRevision.trimmingCharacters(in: .whitespacesAndNewlines)
    let selected = selectedRootPaths.isEmpty ? nil : Array(selectedRootPaths)
    multiRootWorkspace.running = true
    beginFeedbackOperation("Multi-root branch creation")
    Task.detached(priority: .userInitiated) {
        do {
            let results = try Arbor.runMultiRootBranchCreateWithOptions(
                scanRoot: projectPath,
                selectedRootPaths: selected,
                name: branchName,
                startPoint: startPoint.isEmpty ? nil : startPoint,
                checkout: checkout,
                reset: reset
            )
            await MainActor.run {
                self.multiRootWorkspace.results = results.map {
                    RootOperationResult(
                        rootPath: $0.rootPath,
                        displayName: $0.displayName,
                        success: $0.success,
                        skipped: $0.skipped,
                        message: $0.message
                    )
                }
                self.multiRootWorkspace.running = false
                self.loadMultiRoots()
                let created = results.filter { $0.success && !$0.skipped && $0.branchCreated }.count
                let overwritten = results.filter {
                    $0.success && !$0.skipped && $0.previousBranchTip != nil
                }.count
                let failures = results.filter { !$0.success }
                if failures.isEmpty {
                    self.feedbackCenter.success(
                        "Multi-root branch creation completed",
                        detail: "\(created) created · \(overwritten) overwritten · \(branchName)"
                    )
                } else {
                    self.operationRecovery.viewMode = .roots
                    self.projectWorkspace.toolWindowMode = .operations
                    self.toolWindowExpanded = true
                    self.presentMultiRootBranchRollback(name: branchName, results: results)
                }
            }
        } catch {
            await MainActor.run {
                self.multiRootWorkspace.running = false
                self.feedbackCenter.error(
                    "Multi-root branch creation failed",
                    detail: errorMessage(error),
                    nextStep: "Check the selected Git roots and retry."
                )
            }
        }
    }
}

func presentMultiRootBranchRollback(
    name: String,
    results: [MultiRootBranchResult]
) {
    let targets = results
        .filter {
            $0.success && !$0.skipped
                && ($0.branchCreated || $0.previousBranchTip != nil)
        }
        .map {
            MultiRootBranchCreateTarget(
                rootPath: $0.rootPath,
                checkedOut: $0.checkedOut,
                previousBranch: $0.previousBranch,
                previousHead: $0.previousHead,
                expectedHead: $0.checkedOut ? $0.expectedBranchTip : nil,
                expectedBranch: $0.checkedOut ? name : nil,
                previousBranchTip: $0.previousBranchTip,
                expectedBranchTip: $0.expectedBranchTip
            )
        }
    let failureDetail = results
        .filter { !$0.success || $0.skipped }
        .map { "\($0.displayName): \($0.message)" }
        .joined(separator: "\n")
    guard !targets.isEmpty else {
        feedbackCenter.warning(
            "Multi-root branch creation failed",
            detail: failureDetail,
            nextStep: "Check the selected Git roots and retry.",
            notificationID: multiRootBranchCreateRollbackNotificationID(),
            notificationGroup: .standard
        )
        return
    }

    let rollbackRequest = multiRootBranchCreateRollbackRequest(
        branchName: name,
        targets: targets
    )
    let keepRequest = ArborVCSActionRequest(
        kind: .keepMultiRootBranchCreatePartial,
        projectPath: projectWorkspace.path,
        rootPath: nil,
        shelfName: "",
        multiRootBranchName: name
    )
    feedbackCenter.warning(
        "Multi-root branch creation partially completed",
        detail: failureDetail,
        nextStep: "Rollback the successful roots or keep the partial branch state.",
        additionalActions: [
            FeedbackAction(
                title: "Rollback Successful Roots",
                semanticAction: rollbackRequest
            ) {
                self.handleVCSActionRequest(rollbackRequest)
            },
            FeedbackAction(
                title: "Keep Partial Branches",
                semanticAction: keepRequest
            ) {
                self.handleVCSActionRequest(keepRequest)
            }
        ],
        notificationID: multiRootBranchCreateRollbackNotificationID(),
        notificationGroup: .standard
    )
}

func multiRootBranchCreateRollbackRequest(
    branchName: String,
    targets: [MultiRootBranchCreateTarget]
) -> ArborVCSActionRequest {
    ArborVCSActionRequest(
        kind: .rollbackMultiRootBranchCreate,
        projectPath: projectWorkspace.path,
        rootPath: nil,
        shelfName: "",
        multiRootBranchName: branchName,
        multiRootBranchCreateRollbackTargets: targets.map(PersistedMultiRootBranchCreateTarget.init)
    )
}

func multiRootBranchCreateRollbackNotificationID() -> String? {
    guard let projectPath = projectWorkspace.path, !projectPath.isEmpty else { return nil }
    let stableProject = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.multi-root-branch-create.rollback.\(stableProject)"
}

func rollbackMultiRootBranchCreate(
    _ targets: [MultiRootBranchCreateTarget],
    branchName: String
) {
    guard !targets.isEmpty else { return }
    beginFeedbackOperation("Rollback multi-root branch")
    Task.detached(priority: .userInitiated) {
        do {
            let rollback = try Arbor.rollbackMultiRootBranchCreateWithState(
                name: branchName,
                targets: targets
            )
            await MainActor.run {
                self.finishMultiRootBranchCreateRollback(
                    branchName: branchName,
                    targets: targets,
                    results: rollback
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.warning(
                    "Branch rollback failed",
                    detail: errorMessage(error),
                    nextStep: "Retry after confirming the selected roots still contain the expected branch state.",
                    additionalActions: [
                        FeedbackAction(
                            title: "Retry Branch Rollback",
                            semanticAction: self.multiRootBranchCreateRollbackRequest(
                                branchName: branchName,
                                targets: targets
                            )
                        ) {
                            self.rollbackMultiRootBranchCreate(targets, branchName: branchName)
                        }
                    ],
                    notificationID: self.multiRootBranchCreateRollbackNotificationID(),
                    notificationGroup: .standard
                )
            }
        }
    }
}

func finishMultiRootBranchCreateRollback(
    branchName: String,
    targets: [MultiRootBranchCreateTarget],
    results: [RootOperationResult]
) {
    multiRootWorkspace.results = results
    loadMultiRoots()
    let failedRootPaths = Set(results.filter { !$0.success }.map(\.rootPath))
    let remainingTargets = targets.filter { failedRootPaths.contains($0.rootPath) }
    guard !remainingTargets.isEmpty else {
        feedbackCenter.success(
            "Branch rollback completed",
            detail: branchName,
            notificationID: multiRootBranchCreateRollbackNotificationID(),
            notificationGroup: .standard
        )
        return
    }

    let retryRequest = multiRootBranchCreateRollbackRequest(
        branchName: branchName,
        targets: remainingTargets
    )
    let failures = results
        .filter { !$0.success }
        .map { "\($0.displayName): \($0.message)" }
        .joined(separator: "\n")
    feedbackCenter.warning(
        "Branch rollback partially failed",
        detail: failures,
        nextStep: "Review the remaining roots and retry only when their expected branch state is still present.",
        additionalActions: [
            FeedbackAction(
                title: "Retry Remaining Rollback",
                semanticAction: retryRequest
            ) {
                self.rollbackMultiRootBranchCreate(
                    remainingTargets,
                    branchName: branchName
                )
            }
        ],
        notificationID: multiRootBranchCreateRollbackNotificationID(),
        notificationGroup: .standard
    )
}

func createdCheckoutBranch(
    reference: String,
    detach: Bool,
    snapshot: GitRootBranchSnapshot?
) -> String? {
    guard !detach,
          let snapshot,
          snapshot.branches.allSatisfy({ $0.name != reference }),
          snapshot.remoteBranches.contains(where: { $0.name == reference }),
          let separator = reference.firstIndex(of: "/") else {
        return nil
    }
    return String(reference[reference.index(after: separator)...])
}

/// IntelliJ asks for a second confirmation only when resetting an existing
/// branch would actually drop commits that are not reachable from the chosen
/// start point. The checkbox itself is still the explicit opt-in for reset;
/// this guard protects the more destructive local-commit case.
func confirmBranchResetIfNeeded(
    repo: Repository,
    name: String,
    startPoint: String?
) -> Bool {
    guard let branches = try? repo.branchList(),
          branches.contains(where: { $0.name == name }) else {
        return true
    }
    let base: String
    if let trimmed = startPoint?.trimmingCharacters(in: .whitespacesAndNewlines),
       !trimmed.isEmpty {
        base = trimmed
    } else {
        base = "HEAD"
    }
    guard let comparison = try? repo.branchCompare(a: name, b: base),
          comparison.ahead > 0 else {
        return true
    }

    let alert = NSAlert()
    alert.messageText = String(localized: "Reset existing branch?")
    alert.informativeText = String(localized: "\(name) has \(comparison.ahead) local commit(s) not contained in \(base). Resetting it will discard those commits from the branch ref.")
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Drop Local Commits")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    return alert.runModal() == .alertFirstButtonReturn
}

func branchCreate(
    at baseRevision: String? = nil,
    checkout: Bool = false,
    reset: Bool = false,
    repository repositoryOverride: Repository? = nil
) {
    guard let targetRepo = repositoryOverride ?? branchWorkspace.newRepositoryOverride ?? repo else { return }
    let name = GitBranchNameCleanup.cleanUp(branchWorkspace.newName)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    let base = baseRevision?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reset || confirmBranchResetIfNeeded(
        repo: targetRepo,
        name: name,
        startPoint: base
    ) else { return }
    beginFeedbackOperation("Create branch")
    let targetRootPath = targetRepo.workdir() ?? "selected repository"
    Task.detached(priority: .userInitiated) {
        do {
            let startPoint = base?.isEmpty == true ? nil : base
            try targetRepo.branchCreateOrReset(
                name: name,
                at: startPoint,
                checkout: checkout,
                reset: reset
            )
            let bs = try targetRepo.branchList()
            await MainActor.run {
                if self.repo?.workdir() == targetRootPath {
                    self.branchWorkspace.branches = bs
                    self.loadRepoData()
                } else {
                    self.loadMultiRoots()
                }
                self.branchWorkspace.newName = ""
                self.branchWorkspace.newBase = ""
                self.feedbackCenter.success(
                    "Branch created",
                    detail: checkout
                        ? "\(name) (checked out) · \(targetRootPath)"
                        : "\(name) · \(targetRootPath)"
                )
                if self.showsLogWorkspace { self.loadLog() }
            }
        } catch { await MainActor.run { self.repositoryStatus.loadError = errorMessage(error) } }
    }
}
}
