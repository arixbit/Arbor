import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// Resolve a selected revision that is outside the current paged graph. This
/// is required for reflog rows and for external "open commit" notifications:
/// the inspector must remain useful even when the graph has only loaded its
/// first page.
func loadCommitDetailsIfNeeded(_ id: String, forReflog: Bool = false) {
    let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let repo = logRepository, !normalized.isEmpty else { return }
    let revision = normalized.split(separator: "\u{1f}", maxSplits: 1).last.map(String.init) ?? normalized
    if !forReflog,
       let visible = (logList.viewMode == .command ? logRuntime.commandEntries : logList.entries).first(where: {
           let identity = logCommitIdentity($0)
           return identity == normalized || identity.hasPrefix(normalized) || normalized.hasPrefix(identity)
       }) {
        logSelectionState.detailLoadTask?.cancel()
        logSelectionState.detailCommit = visible
        return
    }
    if forReflog, reflog.detailCommit?.id == normalized { return }
    logSelectionState.detailLoadTask?.cancel()
    if forReflog {
        reflog.detailCommit = nil
    } else {
        logSelectionState.detailCommit = nil
    }
    let expectedReflogSelection = forReflog ? reflog.selection : nil
    let expectedLogSelection = forReflog ? nil : logSelectionState.selection
    let tabID = currentLogTabID
    let task = Task.detached(priority: .userInitiated) {
        do {
            let candidates = try repo.logFiltered(
                path: nil,
                limit: 1,
                follow: false,
                startRev: revision,
                author: nil,
                since: nil
            )
            guard !Task.isCancelled,
                  let commit = candidates.first(where: {
                      $0.id == normalized || $0.id.hasPrefix(normalized) || normalized.hasPrefix($0.id)
            }) else { return }
            await MainActor.run {
                guard self.externalLogTabIsAlive(tabID),
                      self.isActiveLogRepository(repo) else { return }
                if forReflog {
                    guard self.reflog.selection == expectedReflogSelection,
                          self.selectedReflogEntry?.newId == commit.id else { return }
                    self.reflog.detailCommit = commit
                } else if let selected = expectedLogSelection,
                          selected == normalized
                            || selected.hasPrefix(normalized)
                            || normalized.hasPrefix(selected) {
                    self.logSelectionState.detailCommit = commit
                }
            }
        } catch {
            // The graph/inspector will keep its existing content. A missing
            // reflog object is not a reason to replace a usable log with an
            // error screen.
        }
    }
    logSelectionState.detailLoadTask = task
}

/// Vcs.Log.GoToParent / GoToChild: keep navigation inside the graph table so
/// the details inspector follows the new lead selection immediately. IntelliJ
/// exposes all adjacent graph rows when there is more than one choice; resolve
/// those rows from the repository rather than treating the loaded page as the
/// complete graph.
func selectParentLogCommit() {
    guard let commit = selectedCommit,
          !commit.parentIds.isEmpty,
          let repository = logRepository(for: commit) else { return }

    let parentIDs = commit.parentIds
    let expectedSelection = logCommitIdentity(commit)
    let expectedGeneration = logList.generation
    if parentIDs.count == 1 {
        selectLogRevision(
            logCommitIdentity(repositoryPath: commit.repositoryPath, id: parentIDs[0])
        )
        return
    }

    Task.detached(priority: .userInitiated) {
        let parents = try? parentIDs.map { try repository.commitInfo(commitId: $0) }
        guard !Task.isCancelled else { return }
        await MainActor.run {
            guard self.logList.generation == expectedGeneration,
                  self.logSelectionState.selection == expectedSelection,
                  self.isActiveLogNavigationRepository(repository, rootPath: commit.repositoryPath) else {
                return
            }
            guard let parents, !parents.isEmpty else {
                self.feedbackCenter.warning(
                    "Parent navigation unavailable",
                    detail: "The selected commit's parent records could not be loaded.",
                    nextStep: "Refresh Log and try again."
                )
                return
            }
            self.logSelectionState.pendingNavigationCommits = parents
            self.logSelectionState.navigationChoosesParent = true
            self.logSelectionState.pendingNavigationSelection = expectedSelection
            self.logSelectionState.pendingNavigationGeneration = expectedGeneration
            self.logSelectionState.isNavigationChoicePresented = true
        }
    }
}

func selectChildLogCommit() {
    guard let commit = selectedCommit,
          let repository = logRepository(for: commit) else { return }

    let expectedSelection = logCommitIdentity(commit)
    let expectedGeneration = logList.generation
    Task.detached(priority: .userInitiated) {
        let children = try? repository.commitChildren(commitId: commit.id)
        guard !Task.isCancelled else { return }
        await MainActor.run {
            guard self.logList.generation == expectedGeneration,
                  self.logSelectionState.selection == expectedSelection,
                  self.isActiveLogNavigationRepository(repository, rootPath: commit.repositoryPath) else {
                return
            }
            guard let children else {
                self.feedbackCenter.warning(
                    "Child navigation unavailable",
                    detail: "The selected commit's child records could not be loaded.",
                    nextStep: "Refresh Log and try again."
                )
                return
            }
            guard !children.isEmpty else {
                self.feedbackCenter.warning(
                    "No child commits",
                    detail: "The selected commit has no reachable direct child in this Git root.",
                    nextStep: "Select another commit in Log."
                )
                return
            }
            if children.count == 1 {
                self.selectLogRevision(self.logCommitIdentity(children[0]))
            } else {
                self.logSelectionState.pendingNavigationCommits = children
                self.logSelectionState.navigationChoosesParent = false
                self.logSelectionState.pendingNavigationSelection = expectedSelection
                self.logSelectionState.pendingNavigationGeneration = expectedGeneration
                self.logSelectionState.isNavigationChoicePresented = true
            }
        }
    }
}

func choosePendingLogNavigationCommit(_ commit: CommitInfo) {
    guard logSelectionState.isNavigationChoicePresented,
          logSelectionState.pendingNavigationSelection == logSelectionState.selection,
          logSelectionState.pendingNavigationGeneration == logList.generation else {
        logSelectionState.isNavigationChoicePresented = false
        logSelectionState.pendingNavigationCommits = []
        logSelectionState.pendingNavigationSelection = nil
        logSelectionState.pendingNavigationGeneration = nil
        return
    }
    let identity = logCommitIdentity(commit)
    logSelectionState.isNavigationChoicePresented = false
    logSelectionState.pendingNavigationCommits = []
    logSelectionState.pendingNavigationSelection = nil
    logSelectionState.pendingNavigationGeneration = nil
    selectLogRevision(identity)
}

func isCommitHashQuery(_ value: String) -> Bool {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (4...40).contains(normalized.count) else { return false }
    return normalized.unicodeScalars.allSatisfy { scalar in
        switch scalar.value {
        case 48...57, 65...70, 97...102: return true
        default: return false
        }
    }
}

func createBranchFromCommit(_ commit: CommitInfo) {
    guard let targetRepo = logRepository(for: commit) else {
        feedbackCenter.warning(
            "Create Branch unavailable",
            detail: "The selected commit's Git root could not be opened.",
            nextStep: "Refresh Git Roots, then retry from the commit history."
        )
        return
    }
    presentNewBranchDialog(
        baseRevision: commit.id,
        suggestedName: "branch-\(commit.shortId)",
        title: String(localized: "New Branch from %@")
            .replacingOccurrences(of: "%@", with: commit.shortId),
        repositoryOverride: targetRepo
    )
}

/// Return the complete message shown by IntelliJ's Squash dialog.
nonisolated func completeCommitMessage(_ commit: CommitInfo) -> String {
    commit.messageBody.isEmpty
        ? commit.summary
        : "\(commit.summary)\n\n\(commit.messageBody)"
}

func cherryPickCommitsFromLog(_ commits: [CommitInfo]) {
    runLogApplyOperation(
        .cherryPick,
        commits: commits,
        confirm: false,
        preserveLocalChanges: false
    )
}

func revertCommitsFromLog(_ commits: [CommitInfo]) {
    runLogApplyOperation(
        .revert,
        commits: commits,
        confirm: true,
        preserveLocalChanges: false
    )
}

}
