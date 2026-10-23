import SwiftUI
import AppKit

extension ContentView {

/// IntelliJ 对照：`Git.Stage.Tree.Menu` 里的 `$Delete`（platform `Delete`）。
///
/// fork 侧是 VFS 删除：先弹确认，再从磁盘移除，不跑 `git rm`；被跟踪的文件
/// 随后以 deleted 出现在 Changes 里。Arbor 拆成两段，删除本身在确认之后才
/// 发生，并且逐路径解析 owning Git root——嵌套仓库的路径不能交给父仓库删。
func requestDeletePaths(_ paths: [String]) {
    let normalized = normalizedDeletePaths(paths)
    guard !normalized.isEmpty else {
        feedbackCenter.warning("No paths selected for deletion")
        return
    }
    projectWorkspace.pendingDeletePaths = normalized
}

func cancelDeletePaths() {
    projectWorkspace.pendingDeletePaths = []
}

func confirmDeletePaths() {
    let requested = projectWorkspace.pendingDeletePaths
    projectWorkspace.pendingDeletePaths = []
    guard !requested.isEmpty else { return }
    guard let primaryRepo = repo, let primaryRootPath = primaryRepo.workdir() else {
        feedbackCenter.error(
            "Delete unavailable",
            detail: "No Git repository is open.",
            nextStep: "Open a repository, then try again."
        )
        return
    }

    let cachedRoots = multiRootWorkspace.roots
    let notificationID = "arbor.delete-paths"
    beginFeedbackOperation("Delete paths", notificationID: notificationID)

    Task.detached(priority: .userInitiated) {
        let roots = cachedRoots.isEmpty
            ? ((try? discoverGitRoots(scanRoot: primaryRootPath, maxDepth: nil)) ?? [])
            : cachedRoots
        var targetsByRoot: [String: [String]] = [:]
        var unresolved: [String] = []
        for path in requested {
            guard let target = fileReferenceComparisonTarget(
                path: path,
                primaryRootPath: primaryRootPath,
                roots: roots
            ) else {
                unresolved.append(path)
                continue
            }
            targetsByRoot[target.rootPath, default: []].append(target.relativePath)
        }

        var deleted: [String] = []
        var failures: [String] = []
        for (rootPath, relativePaths) in targetsByRoot.sorted(by: { $0.key < $1.key }) {
            do {
                let rootRepo = canonicalExternalLogPath(primaryRootPath) == rootPath
                    ? primaryRepo
                    : try openRepository(path: rootPath)
                deleted += try rootRepo.deleteWorktreePaths(paths: relativePaths)
            } catch {
                failures.append("\(rootPath)\n\(errorMessage(error))")
            }
        }

        await MainActor.run {
            let deletedSet = Set(deleted)
            self.clearDeletedPathSelection(deletedSet)
            if !deleted.isEmpty {
                self.feedbackCenter.success(
                    deleted.count == 1 ? "Deleted 1 path" : "Deleted \(deleted.count) paths",
                    detail: deleted.sorted().joined(separator: "\n"),
                    notificationID: notificationID
                )
            }
            if !unresolved.isEmpty || !failures.isEmpty {
                var detail = failures.joined(separator: "\n\n")
                if !unresolved.isEmpty {
                    if !detail.isEmpty { detail += "\n\n" }
                    detail += "Not inside a discovered Git root:\n" + unresolved.joined(separator: "\n")
                }
                self.feedbackCenter.error(
                    "Some paths were not deleted",
                    detail: detail,
                    nextStep: "Refresh the project roots, then retry the remaining paths.",
                    notificationID: notificationID
                )
            }
            self.refreshAll(showFeedback: false)
        }
    }
}

/// 已删除的路径不能继续当选中项或预览目标，否则刷新后仍会去读它。
private func clearDeletedPathSelection(_ deleted: Set<String>) {
    guard !deleted.isEmpty else { return }
    if let selection = fileWorkspace.fileSelection,
       deleted.contains(selectionPathKey(selection)) {
        fileWorkspace.fileSelection = nil
    }
    if let preview = fileWorkspace.previewPath,
       deleted.contains(selectionPathKey(preview)) {
        fileWorkspace.previewPath = nil
        fileWorkspace.previewVisible = false
    }
    if let selection = fileWorkspace.selection,
       deleted.contains(selectionPathKey(selection)) {
        fileWorkspace.selection = nil
    }
}

/// 删除路径比较只看规范化后的仓库相对路径。
private func selectionPathKey(_ path: String) -> String {
    normalizedRepositoryRelativePath(path) ?? path
}

}

/// 去重并丢弃非法（绝对、越界、空）路径，保持用户选择顺序。
func normalizedDeletePaths(_ paths: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for path in paths {
        guard let normalized = normalizedRepositoryRelativePath(path) else { continue }
        if seen.insert(normalized).inserted {
            result.append(normalized)
        }
    }
    return result
}

/// 确认对话框正文：列出前几条路径，并说清楚「被跟踪的能恢复、未跟踪的不能」。
func deleteConfirmationMessage(_ paths: [String]) -> String {
    let visible = paths.prefix(10)
    var lines = visible.joined(separator: "\n")
    if paths.count > visible.count {
        lines += "\n…and \(paths.count - visible.count) more"
    }
    return lines
        + "\n\nTracked files stay in Git and show as deleted. "
        + "Untracked files cannot be restored."
}
