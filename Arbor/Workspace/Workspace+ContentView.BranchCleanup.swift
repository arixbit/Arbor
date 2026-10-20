import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {

func nextBranchCleanupGeneration() -> Int {
    branchCleanup.windowGeneration += 1
    return branchCleanup.windowGeneration
}

nonisolated func loadBranchCleanupRoots(scanRoot: String) throws -> [BranchCleanupRoot] {
    let roots = try discoverGitRoots(scanRoot: scanRoot, maxDepth: nil)
    return try roots.map { root in
        let rootRepo = try openRepository(path: root.path)
        let branches = try rootRepo.branchList()
        let syncStatuses = (try? rootRepo.syncStatus()) ?? []
        let trackingByBranch = Dictionary(
            uniqueKeysWithValues: syncStatuses
                .filter { $0.trackingExists }
                .map { ($0.branch, $0.upstream) }
        )
        return BranchCleanupRoot(
            rootPath: root.path,
            displayName: root.displayName,
            relativePath: root.relativePath,
            branches: branches,
            trackingByBranch: trackingByBranch,
            mergedBranches: [],
            calculatedTarget: nil,
            calculatedPrefix: nil,
            calculationError: nil
        )
    }
}

func beginBranchCleanup() {
    guard let projectPath = projectWorkspace.path else { return }
    let generation = nextBranchCleanupGeneration()
    beginFeedbackOperation("Load branch cleanup")
    let scanRoot = projectPath
    Task.detached(priority: .userInitiated) {
        do {
            let roots = try loadBranchCleanupRoots(scanRoot: scanRoot)
            await MainActor.run {
                guard self.branchCleanup.windowGeneration == generation else { return }
                self.branchCleanupWindow.present(roots: roots)
                self.feedbackCenter.success("Branch cleanup loaded", detail: "\(roots.count) repositories")
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Load branch cleanup failed",
                    detail: errorMessage(error),
                    nextStep: "Check the selected Git roots and retry."
                )
            }
        }
    }
}

func refreshBranchCleanup() {
    guard let projectPath = projectWorkspace.path else { return }
    let generation = nextBranchCleanupGeneration()
    beginFeedbackOperation("Refresh branch cleanup")
    let scanRoot = projectPath
    Task.detached(priority: .userInitiated) {
        do {
            let roots = try loadBranchCleanupRoots(scanRoot: scanRoot)
            await MainActor.run {
                guard self.branchCleanup.windowGeneration == generation else { return }
                self.branchCleanupWindow.updateRoots(roots)
                self.feedbackCenter.success("Branch cleanup refreshed", detail: "\(roots.count) repositories")
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Refresh branch cleanup failed", detail: errorMessage(error))
            }
        }
    }
}

func reloadBranchCleanupContext(for generation: Int) {
    guard let projectPath = projectWorkspace.path else { return }
    let scanRoot = projectPath
    Task.detached(priority: .userInitiated) {
        do {
            let roots = try loadBranchCleanupRoots(scanRoot: scanRoot)
            await MainActor.run {
                guard self.branchCleanup.windowGeneration == generation else { return }
                self.branchCleanupWindow.updateRoots(roots)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Refresh branch cleanup failed", detail: errorMessage(error))
            }
        }
    }
}

func calculateBranchCleanup(target: String, prefix: String) {
    let roots = branchCleanupWindow.roots
    let generation = nextBranchCleanupGeneration()
    let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else { return }
    beginFeedbackOperation("Calculate branch merge status")
    Task.detached(priority: .userInitiated) {
        let scanResults = await scanBranchMergeRoots(roots, target: target, prefix: prefix)
        let rootsToApply = scanResults.map(\.root)
        let failuresToReport = scanResults.compactMap { result in
            result.error.map { "\(result.root.displayName): \($0)" }
        }
        await MainActor.run {
            guard self.branchCleanup.windowGeneration == generation else { return }
            self.branchCleanupWindow.updateRoots(rootsToApply)
            if failuresToReport.isEmpty {
                self.feedbackCenter.success("Branch merge status calculated", detail: target)
            } else {
                self.feedbackCenter.warning(
                    "Branch merge status incomplete",
                    detail: failuresToReport.joined(separator: "\n"),
                    nextStep: "Choose a target branch that exists in each affected root."
                )
            }
        }
    }
}

func deleteBranchCleanup(_ selections: [BranchCleanupSelection]) {
    guard !selections.isEmpty else { return }
    let generation = nextBranchCleanupGeneration()
    beginFeedbackOperation("Delete selected branches")
    Task.detached(priority: .userInitiated) {
        var deleted: [String] = []
        var failures: [String] = []
        for selection in selections {
            do {
                let rootRepo = try openRepository(path: selection.rootPath)
                try rootRepo.branchDelete(name: selection.branchName, force: false)
                deleted.append("\(selection.branchName) · \(selection.rootPath)")
            } catch {
                failures.append("\(selection.branchName) · \(selection.rootPath): \(errorMessage(error))")
            }
        }
        let deletedToReport = deleted
        let failuresToReport = failures
        await MainActor.run {
            guard self.branchCleanup.windowGeneration == generation else { return }
            self.loadRepoData()
            if failuresToReport.isEmpty {
                self.feedbackCenter.success("Selected branches deleted", detail: deletedToReport.joined(separator: ", "))
            } else {
                self.feedbackCenter.warning(
                    "Some branches could not be deleted",
                    detail: failuresToReport.joined(separator: "\n"),
                    nextStep: "Review the affected roots and delete the remaining branches individually."
                )
            }
            self.reloadBranchCleanupContext(for: generation)
        }
    }
}
}
