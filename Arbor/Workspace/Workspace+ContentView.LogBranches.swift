import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {

var logBranchFilterTitle: String {
    activeLogStartRevisions.isEmpty
        ? "Branch"
        : activeLogStartRevisions.joined(separator: ", ")
}

/// Branch dashboard navigation is root-aware. Selecting a branch in a nested
/// Git root changes only the Log repository context; the primary Commit/Status
/// repository remains unchanged.
func navigateLogToBranch(rootPath: String?, branch: String) {
    logRuntime.aggregateBranchFilters = []
    logRuntime.aggregateRevisionRanges = []
    logRuntime.aggregateRootPaths = []
    logRuntime.aggregateRepositories = [:]
    logRuntime.aggregateLoadedCounts = [:]
    var navigationHeadID: String?
    if let rootPath {
        guard let rootRepo = try? openRepository(path: rootPath) else {
            feedbackCenter.error(
                "Log navigation failed",
                detail: "Unable to open Git root: \(rootPath)",
                nextStep: "Refresh Git roots and retry."
            )
            return
        }
        logList.activeRootPath = rootPath
        logList.activeRepo = rootRepo
        logRuntime.activeBranches = (try? rootRepo.branchList()) ?? []
        logRuntime.activeRemoteBranches = (try? rootRepo.remoteBranchList()) ?? []
        logRuntime.activeRemotes = (try? rootRepo.remoteList()) ?? []
        navigationHeadID = try? rootRepo.revisionCommitId(revision: branch)
    } else {
        logList.activeRootPath = nil
        logList.activeRepo = nil
        logRuntime.activeBranches = []
        logRuntime.activeRemoteBranches = []
        logRuntime.activeRemotes = []
        navigationHeadID = repo.flatMap { try? $0.revisionCommitId(revision: branch) }
    }
    setLogStartRevision(branch)
    logSelectionState.selection = navigationHeadID
    logSelectionState.selectedIDs = navigationHeadID.map { [$0] } ?? []
    logList.viewMode = .graph
    loadLog()
}

/// IntelliJ's "Show My Branches" is based on branch ownership, not merely on
/// the author of the branch tip. The engine computes each reference's commits
/// that are not reachable from another branch and matches those commits to
/// Git's configured identity. Keep the expensive reachability work off the UI
/// actor and discard results after a project/root refresh.
func setLogBranchesShowOnlyMy(_ enabled: Bool) {
    logBranchesPanel.showOnlyMy = enabled
    logBranchesPanel.showMyTask?.cancel()
    logBranchesPanel.showMyTask = nil

    guard enabled else {
        logBranchesPanel.myBranchIDs = []
        logBranchesPanel.isLoadingMy = false
        return
    }

    var rootPaths: [String]
    if multiRootWorkspace.branchSnapshots.count > 1 {
        rootPaths = multiRootWorkspace.branchSnapshots.map(\.rootPath)
    } else if let projectPath = projectWorkspace.path {
        rootPaths = [projectPath]
    } else {
        rootPaths = []
    }
    rootPaths = Array(Set(rootPaths)).sorted()
    guard !rootPaths.isEmpty else {
        logBranchesPanel.myBranchIDs = []
        logBranchesPanel.isLoadingMy = false
        return
    }

    let projectToken = projectWorkspace.path
    logBranchesPanel.isLoadingMy = true
    logBranchesPanel.showMyTask = Task.detached(priority: .utility) { [rootPaths] in
        var branchIDs = Set<String>()
        for rootPath in rootPaths {
            guard !Task.isCancelled,
                  let rootRepo = try? openRepository(path: rootPath),
                  let names = try? rootRepo.myBranchNames() else { continue }
            branchIDs.formUnion(names.local.map {
                BranchDashboardReference.referenceID(
                    rootPath: rootPath,
                    name: $0,
                    kind: .local
                )
            })
            branchIDs.formUnion(names.remote.map {
                BranchDashboardReference.referenceID(
                    rootPath: rootPath,
                    name: $0,
                    kind: .remote
                )
            })
        }
        guard !Task.isCancelled else { return }
        let resolvedBranchIDs = branchIDs
        await MainActor.run {
            guard self.projectWorkspace.path == projectToken,
                  self.logBranchesPanel.showOnlyMy else { return }
            self.logBranchesPanel.myBranchIDs = resolvedBranchIDs
            self.logBranchesPanel.isLoadingMy = false
            self.logBranchesPanel.showMyTask = nil
        }
    }
}

func refreshLogMyBranches() {
    guard logBranchesPanel.showOnlyMy else { return }
    setLogBranchesShowOnlyMy(true)
}
}
