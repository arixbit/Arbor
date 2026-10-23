import SwiftUI
import AppKit

extension ContentView {

/// IntelliJ 对照：`Vcs.ShowHistoryForBlock` → `SelectedBlockHistoryAction`。
///
/// 动作作用在**选区**上，所以在原生应用里由代码视图的行选择触发。这里只做
/// 两件事：解析拥有该路径的 Git root（嵌套仓库不能用父仓库的历史），然后
/// 把加载交给 `BlockHistoryRequest`，让 sheet 立刻出现并自己补内容。
func showBlockHistory(path: String, startLine: Int, endLine: Int) {
    guard startLine >= 1, endLine >= startLine else { return }
    guard let primaryRepo = repo,
          let primaryRootPath = primaryRepo.workdir(),
          normalizedRepositoryRelativePath(path) != nil else {
        feedbackCenter.error(
            "Selection history unavailable",
            detail: "The selected path is not a safe repository-relative path.",
            nextStep: "Refresh the project tree, then try again."
        )
        return
    }

    let cachedRoots = multiRootWorkspace.roots
    Task.detached(priority: .userInitiated) {
        let roots = cachedRoots.isEmpty
            ? ((try? discoverGitRoots(scanRoot: primaryRootPath, maxDepth: nil)) ?? [])
            : cachedRoots
        guard let target = fileReferenceComparisonTarget(
            path: path,
            primaryRootPath: primaryRootPath,
            roots: roots
        ) else {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Selection history unavailable",
                    detail: "The selected file is outside the discovered Git roots.",
                    nextStep: "Refresh the project roots, then retry."
                )
            }
            return
        }

        do {
            let targetRepo: Repository
            if canonicalExternalLogPath(primaryRootPath) == target.rootPath {
                targetRepo = primaryRepo
            } else {
                targetRepo = try openRepository(path: target.rootPath)
            }
            await MainActor.run {
                guard let currentRootPath = self.repo?.workdir(),
                      canonicalExternalLogPath(currentRootPath)
                          == canonicalExternalLogPath(primaryRootPath) else {
                    return
                }
                self.fileWorkspace.blockHistoryRequest = BlockHistoryRequest(
                    repo: targetRepo,
                    path: target.relativePath,
                    startLine: startLine,
                    endLine: endLine,
                    formatError: errorMessage
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Unable to read selection history",
                    detail: "\(target.rootPath)\n\(errorMessage(error))",
                    nextStep: "Check the repository state, then retry."
                )
            }
        }
    }
}

}
