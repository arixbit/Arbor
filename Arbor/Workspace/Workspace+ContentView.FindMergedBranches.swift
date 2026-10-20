import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

nonisolated func isUnmergedBranchDeletionError(_ error: Error) -> Bool {
    errorMessage(error).localizedCaseInsensitiveContains("not fully merged")
}

/// IntelliJ Cleanup Branches 的项目级入口：加载所有 Git root 的本地分支，
/// 由 BranchCleanupDialogView 决定目标分支、前缀、合并状态和批量删除集合。
func deleteMergedBranches() {
    beginBranchCleanup()
}

/// Find Merged follows IntelliJ's `reposWithTarget` boundary: a repository
/// without the requested local target is not a failed comparison and must not
/// make an otherwise successful multi-root scan look incomplete.
static func findMergedRootsContainingTarget(
    _ target: String,
    in roots: [BranchCleanupRoot]
) -> [BranchCleanupRoot] {
    roots.filter { root in
        root.branches.contains { $0.name == target }
    }
}

/// IntelliJ FindMergedLocalBranchesAction 的项目级入口：只读加载所有 Git
/// root，再由独立 sheet 按目标分支和名称前缀计算结果。
func beginFindMergedBranches() {
    guard let projectPath = projectWorkspace.path else { return }
    branchCleanup.task?.cancel()
    branchCleanup.task = nil
    let generation = nextFindMergedGeneration()
    let activeBranch = branchWorkspace.branches.first(where: { $0.isCurrent })?.name ?? ""
    branchCleanup.targetBranch = activeBranch
    branchCleanup.prefix = ""
    branchCleanup.roots = []
    branchCleanup.hasCalculated = false
    branchCleanup.summary = nil
    branchCleanup.reportID = nil
    branchCleanup.reportText = ""
    branchCleanup.isRunning = true
    branchCleanup.showFindMergedDialog = true
    beginFeedbackOperation("Load merged branch roots")
    let scanRoot = projectPath
    let task = Task.detached(priority: .userInitiated) {
        do {
            let roots = try loadBranchCleanupRoots(scanRoot: scanRoot)
            guard !Task.isCancelled else { return }
            let allBranches = roots.flatMap { $0.branches }
            let fallbackTarget: String
            if !activeBranch.isEmpty {
                fallbackTarget = activeBranch
            } else if let main = allBranches.first(where: { $0.name == "main" })?.name {
                fallbackTarget = main
            } else if let master = allBranches.first(where: { $0.name == "master" })?.name {
                fallbackTarget = master
            } else {
                fallbackTarget = allBranches.first(where: { $0.isCurrent })?.name ?? ""
            }
            await MainActor.run {
                guard self.branchCleanup.generation == generation else { return }
                self.branchCleanup.task = nil
                self.branchCleanup.roots = roots
                self.branchCleanup.targetBranch = fallbackTarget
                self.branchCleanup.isRunning = false
                self.feedbackCenter.success("Merged branch roots loaded", detail: "\(roots.count) repositories")
            }
        } catch {
            await MainActor.run {
                guard self.branchCleanup.generation == generation else { return }
                self.branchCleanup.task = nil
                self.branchCleanup.isRunning = false
                self.feedbackCenter.error(
                    "Load merged branch roots failed",
                    detail: errorMessage(error),
                    nextStep: "Check the selected Git roots and retry."
                )
            }
        }
    }
    branchCleanup.task = task
}

func nextFindMergedGeneration() -> Int {
    branchCleanup.generation += 1
    return branchCleanup.generation
}

func dismissFindMergedBranches() {
    branchCleanup.task?.cancel()
    branchCleanup.task = nil
    _ = nextFindMergedGeneration()
    branchCleanup.showFindMergedDialog = false
    branchCleanup.isRunning = false
    branchCleanup.hasCalculated = false
    branchCleanup.summary = nil
    branchCleanup.roots = []
}

func cancelFindMergedBranches() {
    guard branchCleanup.isRunning else { return }
    // Root discovery is cancellable and dismisses the sheet; an active scan
    // keeps its partial roots and reports cancellation at the next boundary.
    if branchCleanup.roots.isEmpty && branchCleanup.summary == nil {
        dismissFindMergedBranches()
    } else {
        branchCleanup.task?.cancel()
    }
}

func calculateFindMergedBranches() {
    let target = branchCleanup.targetBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = branchCleanup.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else {
        feedbackCenter.warning("Target branch is required")
        return
    }
    let discoveredRoots = branchCleanup.roots
    let roots = Self.findMergedRootsContainingTarget(target, in: discoveredRoots)
    let generation = nextFindMergedGeneration()
    let startedAt = DispatchTime.now().uptimeNanoseconds
    branchCleanup.isRunning = true
    branchCleanup.hasCalculated = false
    branchCleanup.summary = nil
    branchCleanup.task?.cancel()
    beginFeedbackOperation("Find merged branches")
    let task = Task.detached(priority: .userInitiated) {
        let scanResults = await scanBranchMergeRoots(roots, target: target, prefix: prefix)
        let calculatedRoots = scanResults.map(\.root)
        let failures = scanResults.compactMap { result in
            result.error.map { "\(result.root.displayName): \($0)" }
        }
        let repositoriesScanned = scanResults.filter(\.repositoryScanned).count
        let candidateBranchesChecked = scanResults.reduce(0) {
            $0 + $1.candidateBranchesChecked
        }
        let mergedBranchesFound = scanResults.reduce(0) {
            $0 + $1.mergedBranchesFound
        }
        let wasCancelled = Task.isCancelled
        let rootsToApply = calculatedRoots
        let completedRepositoryCount = calculatedRoots.count
        let failuresToReport = failures
        let elapsedMilliseconds = Int64(
            (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        )
        let summary = FindMergedScanSummary(
            targetBranch: target,
            prefix: prefix,
            repositoriesDiscovered: discoveredRoots.count,
            repositoriesScanned: repositoriesScanned,
            candidateBranchesChecked: candidateBranchesChecked,
            mergedBranchesFound: mergedBranchesFound,
            errors: failuresToReport,
            elapsedMilliseconds: elapsedMilliseconds,
            isCancelled: wasCancelled
        )
        await MainActor.run {
            guard self.branchCleanup.generation == generation else { return }
            self.branchCleanup.task = nil
            self.branchCleanup.roots = rootsToApply
            self.branchCleanup.isRunning = false
            self.branchCleanup.hasCalculated = true
            self.branchCleanup.summary = summary
            let reportID = UUID().uuidString
            let report = findMergedBranchesReportText(
                summary: summary,
                roots: rootsToApply,
                projectName: self.projectWorkspace.path.map {
                    URL(fileURLWithPath: $0).lastPathComponent
                } ?? ""
            )
            FindMergedReportStore.save(
                PersistedFindMergedReport(
                    id: reportID,
                    projectPath: self.projectWorkspace.path ?? "",
                    targetBranch: summary.targetBranch,
                    prefix: summary.prefix,
                    report: report,
                    createdAt: Date()
                )
            )
            self.branchCleanup.reportID = reportID
            let reportAction = self.findMergedReportAction(reportID: reportID)
            let notificationID = self.findMergedNotificationID(
                targetBranch: summary.targetBranch,
                prefix: summary.prefix
            )
            if summary.isCancelled {
                self.feedbackCenter.warning(
                    "Find merged branches cancelled",
                    detail: "\(completedRepositoryCount) of \(roots.count) repositories completed",
                    additionalActions: [reportAction],
                    notificationID: notificationID,
                    notificationGroup: .standard
                )
            } else if failuresToReport.isEmpty {
                self.feedbackCenter.success(
                    "Merged branches found",
                    detail: target,
                    additionalActions: [reportAction],
                    notificationID: notificationID,
                    notificationGroup: .standard
                )
            } else {
                self.feedbackCenter.warning(
                    "Find merged branches incomplete",
                    detail: failuresToReport.joined(separator: "\n"),
                    nextStep: "Choose a target branch that exists in the affected roots.",
                    additionalActions: [reportAction],
                    notificationID: notificationID,
                    notificationGroup: .standard
                )
            }
        }
    }
    branchCleanup.task = task
}

func findMergedReportAction(reportID: String) -> FeedbackAction {
    let request = ArborVCSActionRequest(
        kind: .showFindMergedReport,
        projectPath: projectWorkspace.path,
        rootPath: nil,
        shelfName: "",
        findMergedReportID: reportID
    )
    return FeedbackAction(
        id: "open-find-merged-report",
        title: "Open Report",
        semanticAction: request
    ) {
        NotificationCenter.default.post(name: .arborVCSAction, object: request)
    }
}

func findMergedNotificationID(targetBranch: String, prefix: String) -> String {
    let source = [projectWorkspace.path ?? "", targetBranch, prefix].joined(separator: "\u{1f}")
    let encoded = Data(source.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "git.find-merged.\(encoded)"
}

func presentFindMergedReport() {
    if branchCleanup.showFindMergedDialog {
        // The report editor is attached to the project view rather than the
        // scan sheet. Dismiss the scan sheet first so SwiftUI does not reject
        // a second presentation while the first sheet is still mounted.
        branchCleanup.showFindMergedDialog = false
        Task { @MainActor in
            await Task.yield()
            self.branchCleanup.showReport = true
        }
    } else {
        branchCleanup.showReport = true
    }
}

func openFindMergedReport() {
    let target = branchCleanup.targetBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = branchCleanup.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let summary = branchCleanup.summary,
          summary.targetBranch == target,
          summary.prefix == prefix else {
        feedbackCenter.warning("Run Find to calculate merged branches")
        return
    }
    let report = findMergedBranchesReportText(
        summary: summary,
        roots: branchCleanup.roots,
        projectName: projectWorkspace.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
    )
    let reportID = branchCleanup.reportID ?? UUID().uuidString
    if let projectPath = projectWorkspace.path {
        FindMergedReportStore.save(
            PersistedFindMergedReport(
                id: reportID,
                projectPath: projectPath,
                targetBranch: summary.targetBranch,
                prefix: summary.prefix,
                report: report,
                createdAt: Date()
            )
        )
    }
    branchCleanup.reportID = reportID
    branchCleanup.reportText = report
    presentFindMergedReport()
}

func openFindMergedReport(reportID: String) {
    guard let saved = FindMergedReportStore.load(id: reportID) else {
        feedbackCenter.warning(
            "Merged branches report unavailable",
            detail: "The saved report is no longer available.",
            nextStep: "Run Find Merged Local Branches again."
        )
        return
    }
    if let projectPath = projectWorkspace.path,
       URL(fileURLWithPath: projectPath).standardizedFileURL.path
            != URL(fileURLWithPath: saved.projectPath).standardizedFileURL.path
    {
        return
    }
    branchCleanup.reportID = saved.id
    branchCleanup.targetBranch = saved.targetBranch
    branchCleanup.prefix = saved.prefix
    branchCleanup.reportText = saved.report
    presentFindMergedReport()
}

func copyFindMergedBranches() {
    let target = branchCleanup.targetBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = branchCleanup.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let summary = branchCleanup.summary,
          summary.targetBranch == target,
          summary.prefix == prefix else {
        feedbackCenter.warning("Run Find to calculate merged branches")
        return
    }
    let report = findMergedBranchesReportText(
        summary: summary,
        roots: branchCleanup.roots,
        projectName: projectWorkspace.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
    )
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(report, forType: .string)
    feedbackCenter.success("Merged branches copied", detail: "\(summary.mergedBranchesFound) branches")
}

}
