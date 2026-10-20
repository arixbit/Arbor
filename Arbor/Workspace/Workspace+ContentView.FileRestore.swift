import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// Restore selected historical file versions into both the index and worktree.
/// This is the Changes Browser's `Vcs.GetVersion` action. IntelliJ accepts the
/// complete selected-change set, so a single confirmation covers multi-file,
/// multi-commit, and multi-root selections.
func restoreSelectedFilesFromRevisions(_ records: [LogChangeRecord]) {
    guard !records.isEmpty else { return }
    let requests = records.compactMap { record -> (Repository, String, String, String)? in
        guard let repo = logRepository(for: record.commit) else { return nil }
        return (
            repo,
            record.change.path,
            record.commit.id,
            "\(record.commit.repositoryPath ?? "Git root") · \(record.commit.shortId) · \(record.change.path)"
        )
    }
    guard !requests.isEmpty else { return }

    let alert = NSAlert()
    alert.messageText = records.count == 1 ? "Get file version?" : "Get file versions?"
    let rootCount = max(
        1,
        Set(records.compactMap(\.commit.repositoryPath).filter { !$0.isEmpty }).count
    )
    alert.informativeText = "Replace the index and working tree copies of \(requests.count) file(s) from \(rootCount) Git root(s)?"
    alert.alertStyle = .warning
    alert.addButton(withTitle: records.count == 1 ? "Get Version" : "Get Versions")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    beginFeedbackOperation(records.count == 1 ? "Get file version" : "Get file versions")
    Task.detached(priority: .userInitiated) {
        var restoredCount = 0
        var failures: [String] = []
        for (repo, path, revision, label) in requests {
            do {
                try repo.restoreFile(path: path, revision: revision)
                restoredCount += 1
            } catch {
                failures.append("\(label): \(errorMessage(error))")
            }
        }

        let restored = restoredCount
        let failed = failures
        await MainActor.run {
            self.refreshAll(showFeedback: false)
            if failed.isEmpty {
                self.feedbackCenter.success(
                    restored == 1 ? "File restored" : "Files restored",
                    detail: "\(restored) file(s)"
                )
            } else if restored > 0 {
                self.feedbackCenter.warning(
                    "Some files could not be restored",
                    detail: "Restored \(restored); failed \(failed.count). \(failed.joined(separator: " | "))",
                    nextStep: "Check the selected revisions and retry the failed files."
                )
            } else {
                self.feedbackCenter.error(
                    "Get file versions failed",
                    detail: failed.joined(separator: " | "),
                    nextStep: "Check the selected revisions and retry."
                )
            }
        }
    }
}

/// A Drop/Extract rewrite can finish its history edit and still fail while
/// replaying the user's saved local scene. The engine leaves a stable
/// history-rewrite marker and the exact stash; open the same root-scoped
/// resolver used by the other preserving operations instead of leaving only
/// a generic error and a stash hint.
func presentLogSelectedChangesRestoreConflict(rootPath: String) {
    guard !rootPath.isEmpty else { return }
    Task.detached(priority: .utility) {
        guard let rootRepo = try? openRepository(path: rootPath),
              let info = (try? rootRepo.applyLocalChangesRestoreInfo()) ?? nil,
              info.operation == "history-rewrite" else { return }
        let paths = ((try? rootRepo.status()) ?? [])
            .filter { $0.staged == .conflicted || $0.unstaged == .conflicted }
            .map(\.path)
        await MainActor.run {
            self.openMultiRootConflictResolver(
                preferredRootPath: rootPath,
                preferredPath: paths.first
            )
        }
    }
}

func restoreSelectedFile() {
    // The Commit workspace keeps its selected row in `commitPreviewPath` so the
    // main Log selection can remain independent.  Fall back to the older
    // selection channels for Project/Conflict workspaces.
    guard let path = fileWorkspace.previewPath ?? fileWorkspace.selection ?? fileWorkspace.fileSelection else { return }
    restoreFileFromHead(path)
}

/// Restore is a tree action in GitStagePanel, not a global toolbar action.
/// Keep the selected-file wrapper for keyboard/legacy callers, but let the
/// tree context menu pass its path directly so a context-menu click cannot
/// race the asynchronous row-selection state update.
func restoreFileFromHead(
    _ path: String,
    prompt: String = "Restore file from HEAD?",
    confirmTitle: String = "Restore",
    feedbackTitle: String = "File restored"
) {
    guard let repo else { return }
    let alert = NSAlert()
    alert.messageText = prompt
    alert.informativeText = "This restores \(path) in both the index and working tree."
    alert.alertStyle = .warning
    alert.addButton(withTitle: confirmTitle)
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    beginFeedbackOperation("Restore file")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.restoreFile(path: path, revision: nil)
            await MainActor.run {
                self.feedbackCenter.success(feedbackTitle, detail: path)
                self.fileWorkspace.selection = nil
                self.fileWorkspace.previewPath = nil
                self.refreshAll(showFeedback: false)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Restore file failed", detail: errorMessage(error), nextStep: "Check the selected path and retry.")
            }
        }
    }
}

/// Project-tree Revert is the same tracked-file operation as ChangesView's
/// Revert, but resolves nested Git roots before touching the index/worktree.
func restoreProjectTreePath(_ path: String) {
    guard let normalizedPath = normalizedRepositoryRelativePath(path),
          let primaryRepo = repo,
          let primaryRootPath = primaryRepo.workdir(),
          !primaryRootPath.isEmpty else { return }
    let alert = NSAlert()
    alert.messageText = "Revert file?"
    alert.informativeText = "This restores \(normalizedPath) in both the index and working tree."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Revert")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let cachedRoots = multiRootWorkspace.roots
    beginFeedbackOperation("Revert file")
    Task.detached(priority: .userInitiated) {
        do {
            let roots = cachedRoots.isEmpty
                ? ((try? discoverGitRoots(scanRoot: primaryRootPath, maxDepth: nil)) ?? [])
                : cachedRoots
            guard let target = fileReferenceComparisonTarget(
                path: normalizedPath,
                primaryRootPath: primaryRootPath,
                roots: roots
            ) else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The selected path is outside the discovered Git roots."]
                )
            }
            let targetRepo = canonicalExternalLogPath(primaryRootPath) == target.rootPath
                ? primaryRepo
                : try openRepository(path: target.rootPath)
            let currentStatus = try targetRepo.statusPaths(paths: [target.relativePath])
            guard projectFileTreeCanRevert(
                path: target.relativePath,
                isDirectory: false,
                entries: currentStatus
            ) else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "The file is no longer a tracked, non-conflicted change."]
                )
            }
            try targetRepo.restoreFile(path: target.relativePath, revision: nil)
            await MainActor.run {
                self.refreshAll(showFeedback: false)
                self.loadMultiRootChanges()
                self.feedbackCenter.success("File reverted", detail: normalizedPath)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Revert failed",
                    detail: errorMessage(error),
                    nextStep: "Check that the file is a tracked, non-conflicted change, then retry."
                )
            }
        }
    }
}

}
