import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {
/// Log ref actions must retain the selected commit's Git root. Resolving a
/// missing path through `repo` would make an aggregate Log mutate the window's
/// primary repository, so this action path fails closed instead.
func performLogReferenceAction(
    _ commit: CommitInfo,
    target: LogReferenceActionTarget,
    action: LogReferenceAction
) {
    guard let rootPath = logReferenceRootPath(for: commit) else {
        feedbackCenter.warning(
            "Reference action unavailable",
            detail: "The selected commit has no Git root.",
            nextStep: "Refresh Git Roots, then retry from the commit history."
        )
        return
    }

    switch action {
    case .checkout:
        checkoutBranchInRoot(
            rootPath: rootPath,
            reference: target.name,
            isRemote: target.kind == .remote
        )
    case .checkoutAndUpdate:
        executeMultiRootCheckoutAndUpdate(
            reference: target.name,
            rootPath: rootPath,
            detach: false,
            rebase: false
        )
    case .checkoutWithRebase:
        executeMultiRootCheckoutAndUpdate(
            reference: target.name,
            rootPath: rootPath,
            detach: false,
            rebase: true
        )
    case .compare:
        compareBranchInRoot(rootPath: rootPath, branch: target.name)
    case .showDiff:
        showBranchDiffWithWorkingTree(rootPath: rootPath, branch: target.name)
    case .rebase:
        rebaseCurrentInRoot(rootPath: rootPath, onto: target.name)
    case .merge:
        mergeBranchInRoot(rootPath: rootPath, branch: target.name)
    case .update:
        updateBranchInRoot(rootPath: rootPath, branch: target.name)
    case .push:
        beginMultiRootPushDialog(rootPath: rootPath, branch: target.name)
    case .pullMerge:
        pullBranchInRoot(rootPath: rootPath, branch: target.name, rebase: false)
    case .pullRebase:
        pullBranchInRoot(rootPath: rootPath, branch: target.name, rebase: true)
    case .rename:
        renameBranchInRoot(rootPath: rootPath, oldName: target.name)
    case .delete:
        switch target.kind {
        case .local:
            deleteBranchInRoot(rootPath: rootPath, name: target.name)
        case .remote:
            deleteRemoteBranchInRoot(rootPath: rootPath, branch: target.name)
        case .tag:
            deleteTagInRoot(rootPath: rootPath, name: target.name)
        }
    }
}

/// LOG-004：在本地只读仓库浏览器中打开提交对应的树。
func browseRevisionFromLog(_ commit: CommitInfo) {
    guard logRepository(for: commit) != nil else {
        feedbackCenter.error(
            "Browse revision unavailable",
            detail: "No repository is open.",
            nextStep: "Open a Git repository, then retry."
        )
        return
    }
    fileWorkspace.revisionBrowserPath = nil
    fileWorkspace.revisionBrowserCommit = commit
    fileWorkspace.showRevisionBrowser = true
}

/// Open the selected file directly in the read-only revision browser.
func browseFileRevisionFromLog(_ commit: CommitInfo, path: String) {
    guard logRepository(for: commit) != nil else {
        feedbackCenter.error(
            "Browse revision unavailable",
            detail: "No repository is open.",
            nextStep: "Open a Git repository, then retry."
        )
        return
    }
    fileWorkspace.revisionBrowserPath = path
    fileWorkspace.revisionBrowserCommit = commit
    fileWorkspace.showRevisionBrowser = true
}

/// Map IntelliJ's `Vcs.EditSource` to the macOS default application for the
/// current worktree file. Arbor is not an IDE, so this deliberately delegates
/// editing to the user's system file association rather than embedding one.
func editSourceFromLog(_ path: String) {
    guard let repo = logRepository, let workdir = repo.workdir() else {
        feedbackCenter.error(
            "Edit source unavailable",
            detail: "No repository is open.",
            nextStep: "Open a Git repository, then retry."
        )
        return
    }

    let root = URL(fileURLWithPath: workdir).standardizedFileURL
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    guard !components.isEmpty, !components.contains("..") else {
        feedbackCenter.error(
            "Edit source unavailable",
            detail: "The selected path is not a repository-relative file.",
            nextStep: "Refresh the Changes browser and retry."
        )
        return
    }
    let fileURL = root
        .appendingPathComponent(components.joined(separator: "/"))
        .standardizedFileURL
    guard fileURL.path == root.path || fileURL.path.hasPrefix(root.path + "/") else {
        feedbackCenter.error(
            "Edit source unavailable",
            detail: "The selected path is outside the repository.",
            nextStep: "Refresh the Changes browser and retry."
        )
        return
    }

    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL.deletingLastPathComponent()])
        feedbackCenter.warning(
            "Source file unavailable",
            detail: "\(path) is not present in the current worktree.",
            nextStep: "Use Show File at Revision to inspect the historical copy."
        )
        return
    }

    guard NSWorkspace.shared.open(fileURL) else {
        feedbackCenter.error(
            "Open source failed",
            detail: "macOS could not open \(path) with its default application.",
            nextStep: "Choose an application for this file type in Finder."
        )
        return
    }
}

/// LOG-005：复制与 Log 提交对应的远程仓库链接。
func copyRevisionLinkFromLog(_ commit: CommitInfo, remote: RemoteInfo) {
    guard let repo = logRepository(for: commit) else {
        feedbackCenter.error(
            "Copy repository link unavailable",
            detail: "The commit's Git root is no longer available.",
            nextStep: "Refresh the project and retry."
        )
        return
    }
    Task.detached(priority: .userInitiated) {
        let link = repo.permalink(remoteUrl: remote.url, commitId: commit.id)
        await MainActor.run {
            guard let link else {
                self.feedbackCenter.error(
                    "Copy repository link unavailable",
                    detail: "The remote does not expose a repository permalink.",
                    nextStep: "Use Copy Commit ID instead."
                )
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
            self.feedbackCenter.success("Repository link copied", detail: link)
        }
    }
}

/// LOG-005：在所选 hosted remote 打开提交 permalink。
func browseHostedRevisionFromLog(_ commit: CommitInfo, remote: RemoteInfo) {
    guard let repo = logRepository(for: commit) else {
        feedbackCenter.error(
            "Browse commit in browser unavailable",
            detail: "The commit's Git root is no longer available.",
            nextStep: "Refresh the project and retry."
        )
        return
    }
    Task.detached(priority: .userInitiated) {
        let link = repo.permalink(remoteUrl: remote.url, commitId: commit.id)
        await MainActor.run {
            guard let link, let url = URL(string: link) else {
                self.feedbackCenter.error(
                    "Browse commit in browser unavailable",
                    detail: "The selected remote does not expose a commit permalink.",
                    nextStep: "Choose another hosted remote or use Copy Commit ID."
                )
                return
            }
            guard NSWorkspace.shared.open(url) else {
                self.feedbackCenter.error(
                    "Browse commit in browser failed",
                    detail: link,
                    nextStep: "Copy the repository link and open it manually."
                )
                return
            }
        }
    }
}

/// LOG-006：Changes Browser / File History 的文件级托管链接。
/// IntelliJ 的 Git.Hosting actions 在文件 revision 上同样可用；这里使用
/// commit.repositoryPath 解析出的 root，避免多仓库项目把文件链接发到错误 remote。
func browseHostedFileRevisionFromLog(_ record: LogChangeRecord, remote: RemoteInfo) {
    guard let repo = logRepository(for: record.commit) else {
        feedbackCenter.error(
            "Browse file in browser unavailable",
            detail: "The commit's Git root is no longer available.",
            nextStep: "Refresh the project and retry."
        )
        return
    }
    let target = hostedFileRevisionTarget(for: record)
    Task.detached(priority: .userInitiated) {
        let link = hostedFileRevisionLink(
            repository: repo,
            remoteURL: remote.url,
            commitID: target.commitID,
            path: target.path
        )
        await MainActor.run {
            guard let link, let url = URL(string: link) else {
                self.feedbackCenter.error(
                    "Browse file in browser unavailable",
                    detail: "The selected root has no supported hosting remote.",
                    nextStep: "Configure a GitHub, GitLab, or Bitbucket remote."
                )
                return
            }
            guard NSWorkspace.shared.open(url) else {
                self.feedbackCenter.error(
                    "Browse file in browser failed",
                    detail: link,
                    nextStep: "Open the copied link manually."
                )
                return
            }
        }
    }
}

/// LOG-007：复制 Changes Browser / File History 的文件级托管链接。
func copyHostedFileRevisionFromLog(_ record: LogChangeRecord, remote: RemoteInfo) {
    guard let repo = logRepository(for: record.commit) else {
        feedbackCenter.error(
            "Copy file link unavailable",
            detail: "The commit's Git root is no longer available.",
            nextStep: "Refresh the project and retry."
        )
        return
    }
    let target = hostedFileRevisionTarget(for: record)
    Task.detached(priority: .userInitiated) {
        let link = hostedFileRevisionLink(
            repository: repo,
            remoteURL: remote.url,
            commitID: target.commitID,
            path: target.path
        )
        await MainActor.run {
            guard let link else {
                self.feedbackCenter.error(
                    "Copy file link unavailable",
                    detail: "The selected root has no supported hosting remote.",
                    nextStep: "Configure a GitHub, GitLab, or Bitbucket remote."
                )
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
            self.feedbackCenter.success("File link copied", detail: link)
        }
    }
}

func openFileHistoryTab(path: String, startRevision: String, rootPath: String?) {
    let tab = makeFileHistoryLogTab(
        path: path,
        startRevision: startRevision,
        rootPath: rootPath
    )
    saveCurrentLogTab()
    if let existing = logSelectionState.tabs.first(where: {
        $0.historyPath == tab.historyPath
            && $0.rootPath == tab.rootPath
            && $0.startRevision == tab.startRevision
            && $0.startRevisions == tab.startRevisions
            && $0.pathFilter == tab.pathFilter
            && $0.pathSelections == tab.pathSelections
            && $0.follow
    }) {
        if existing.id == currentLogTabID {
            applyLogTab(existing)
            loadLog()
        } else {
            switchLogTab(existing.id)
        }
        return
    }
    appendLogTabAndLoad(tab)
}

/// HISTORY-001：File History 入口——打开独立 Log tab 并按路径过滤（follow renames）。
func showFileHistory(_ path: String, rootPath: String? = nil) {
    let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedPath.isEmpty else { return }
    let historyRootPath = resolvedFileHistoryRootPath(
        preferredRootPath: rootPath,
        selectedCommitRootPath: selectedCommit?.repositoryPath,
        activeLogRootPath: logList.activeRootPath,
        repositoryRootPath: repo?.workdir()
    )
    logRuntime.aggregateBranchFilters = []
    logRuntime.aggregateRevisionRanges = []
    logRuntime.aggregateRootPaths = []
    logRuntime.aggregateRepositories = [:]
    logRuntime.aggregateLoadedCounts = [:]
    projectWorkspace.toolWindowMode = .log
    toolWindowExpanded = true
    // File History is a Log editor hand-off. The left workspace must return
    // to Commit/Stash immediately instead of leaving the Project tool window
    // expanded over the staging surface.
    projectPanelExpanded = false
    fileWorkspace.selection = nil
    fileWorkspace.fileSelection = nil
    fileWorkspace.selectionModePath = nil
    fileWorkspace.previewPath = nil
    fileWorkspace.previewVisible = false
    openFileHistoryTab(path: normalizedPath, startRevision: "HEAD", rootPath: historyRootPath)
}

/// Vcs.ShowHistoryForRevision: open the file history rooted at the selected
/// revision instead of silently starting from the current branch tip.
func showFileHistoryForRevision(_ commit: CommitInfo, _ path: String) {
    let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedPath.isEmpty else { return }
    let historyRootPath = commit.repositoryPath
        ?? logList.activeRootPath
        ?? repo?.workdir()
    logRuntime.aggregateBranchFilters = []
    logRuntime.aggregateRevisionRanges = []
    logRuntime.aggregateRootPaths = []
    logRuntime.aggregateRepositories = [:]
    logRuntime.aggregateLoadedCounts = [:]
    projectWorkspace.toolWindowMode = .log
    toolWindowExpanded = true
    projectPanelExpanded = false
    fileWorkspace.selection = nil
    fileWorkspace.fileSelection = nil
    fileWorkspace.selectionModePath = nil
    fileWorkspace.previewPath = nil
    fileWorkspace.previewVisible = false
    openFileHistoryTab(
        path: normalizedPath,
        startRevision: commit.id,
        rootPath: historyRootPath
    )
}

}
