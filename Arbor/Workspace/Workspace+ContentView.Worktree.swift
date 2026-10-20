import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
/// IntelliJ's `Show Diff with Working Tree`: compare the selected branch
/// revision with the tracked state currently present in its owning worktree.
/// This is deliberately separate from `compareLogBranch`, which compares two
/// committed revisions and opens the history-style comparison view.
func showBranchDiffWithWorkingTree(rootPath: String?, branch: String) {
    let comparisonRepo: Repository?
    if let rootPath {
        guard let rootRepo = try? openRepository(path: rootPath) else {
            feedbackCenter.error(
                "Show Diff unavailable",
                detail: "Unable to open Git root: \(rootPath)"
            )
            return
        }
        comparisonRepo = rootRepo
    } else {
        comparisonRepo = repo
    }
    guard let comparisonRepo,
          let owningRoot = rootPath ?? comparisonRepo.workdir() else { return }
    openTreeComparisonTab(
        rootPath: owningRoot,
        first: branch,
        second: "Working Tree",
        comparesWithWorkingTree: true
    )
}

/// IntelliJ's Create New Working Tree action is repository-scoped. The
/// multi-root Branches Popup therefore carries the selected root into the
/// same dialog instead of pretending that one worktree operation spans roots.
func presentNewWorktreeFromReference(
    _ reference: String,
    isTag: Bool,
    rootPath: String? = nil
) {
    let selectedRootPath = rootPath ?? repo?.workdir()
    guard let selectedRootPath, !selectedRootPath.isEmpty else { return }
    if rootPath != nil, (try? openRepository(path: selectedRootPath)) == nil {
        feedbackCenter.warning(
            "New Working Tree unavailable",
            detail: "The selected Git root could not be opened.",
            nextStep: "Refresh Git Roots, then retry from the branch or tag."
        )
        return
    }
    let trimmedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedReference.isEmpty else { return }
    newWorktreeRootPath = selectedRootPath
    newWorktreeReference = trimmedReference
    newWorktreeIsTag = isTag
    newWorktreePath = ""
    newWorktreeBranch = ""
    showNewWorktreeDialog = true
}

func dismissNewWorktreeDialog() {
    showNewWorktreeDialog = false
    newWorktreeRootPath = nil
    newWorktreeReference = ""
    newWorktreeIsTag = false
    newWorktreePath = ""
    newWorktreeBranch = ""
}

func loadWorktrees() {
    guard let repo else { return }
    Task.detached(priority: .userInitiated) {
        let items = (try? repo.worktreeList()) ?? []
        await MainActor.run { self.worktrees = items }
    }
}

func createWorktree(
    path: String,
    branch: String,
    revision: String,
    rootPath: String? = nil
) {
    let targetRepo: Repository
    let targetRootPath: String
    if let rootPath {
        guard let openedRepo = try? openRepository(path: rootPath) else {
            feedbackCenter.error("Create worktree failed", detail: "The selected Git root could not be opened.")
            return
        }
        targetRepo = openedRepo
        targetRootPath = rootPath
    } else {
        guard let repo, let workdir = repo.workdir(), !workdir.isEmpty else { return }
        targetRepo = repo
        targetRootPath = workdir
    }
    let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
    let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
    let revision = revision.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { return }
    beginFeedbackOperation("Create worktree")
    Task.detached(priority: .userInitiated) {
        do {
            try targetRepo.worktreeAdd(
                path: path,
                newBranch: branch.isEmpty ? nil : branch,
                revision: revision.isEmpty ? nil : revision
            )
            let items = try targetRepo.worktreeList()
            await MainActor.run {
                if self.repo?.workdir() == targetRootPath {
                    self.worktrees = items
                }
                self.loadMultiRoots()
                self.worktreeFeedback = "已创建 worktree：\(path)"
                self.feedbackCenter.success("Worktree created", detail: path)
            }
        } catch {
            await MainActor.run {
                self.worktreeFeedback = errorMessage(error)
                self.feedbackCenter.error("Create worktree failed", detail: errorMessage(error))
            }
        }
    }
}

func removeWorktree(path: String, force: Bool) {
    guard let repo else { return }
    let alert = NSAlert()
    alert.messageText = force ? "Force remove worktree?" : "Remove worktree?"
    alert.informativeText = "\(path) 中未提交的修改可能会丢失。"
    alert.alertStyle = .warning
    alert.addButton(withTitle: force ? "Force Remove" : "Remove")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    beginFeedbackOperation("Remove worktree")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.worktreeRemove(path: path, force: force)
            let items = try repo.worktreeList()
            await MainActor.run {
                self.worktrees = items
                self.worktreeFeedback = "已移除 worktree：\(path)"
                self.feedbackCenter.success("Worktree removed", detail: path)
            }
        } catch {
            await MainActor.run {
                self.worktreeFeedback = errorMessage(error)
                self.feedbackCenter.error("Remove worktree failed", detail: errorMessage(error))
            }
        }
    }
}

func lockWorktree(_ path: String) {
    updateWorktreeLock(path: path, lock: true)
}

func unlockWorktree(_ path: String) {
    updateWorktreeLock(path: path, lock: false)
}

func updateWorktreeLock(path: String, lock: Bool) {
    guard let repo else { return }
    beginFeedbackOperation(lock ? "Lock worktree" : "Unlock worktree")
    Task.detached(priority: .userInitiated) {
        do {
            if lock { try repo.worktreeLock(path: path) }
            else { try repo.worktreeUnlock(path: path) }
            let items = try repo.worktreeList()
            await MainActor.run {
                self.worktrees = items
                self.feedbackCenter.success(lock ? "Worktree locked" : "Worktree unlocked", detail: path)
            }
        } catch {
            await MainActor.run {
                self.worktreeFeedback = errorMessage(error)
                self.feedbackCenter.error(lock ? "Lock worktree failed" : "Unlock worktree failed", detail: errorMessage(error))
            }
        }
    }
}

func pruneWorktrees() {
    guard let repo else { return }
    beginFeedbackOperation("Prune worktrees")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.worktreePrune()
            let items = try repo.worktreeList()
            await MainActor.run {
                self.worktrees = items
                self.feedbackCenter.success("Worktrees pruned")
            }
        } catch {
            await MainActor.run { self.feedbackCenter.error("Prune worktrees failed", detail: errorMessage(error)) }
        }
    }
}

}
