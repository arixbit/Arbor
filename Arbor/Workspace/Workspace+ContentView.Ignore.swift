import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// IDX-001「Add to Git / Ignore」入口：追加规则到工作区或选定的 .gitignore。
/// Multiple selected unversioned files share one ignore-file choice and are
/// validated by Rust before any rule is written.
struct IgnoreFileCreationRequest: Equatable {
    let paths: [String]
    let workdir: String
}

func ignorePaths(_ paths: [String], ignoreFilePath: String? = nil) {
    guard let repo else { return }
    let paths = Array(Set(paths)).sorted()
    guard !paths.isEmpty else { return }
    if let workdir = repo.workdir(),
       gitIgnoreNeedsRootCreationConfirmation(
           ignoreFilePath: ignoreFilePath,
           workdir: workdir
       ) {
        fileWorkspace.pendingIgnoreFileCreation = IgnoreFileCreationRequest(
            paths: paths,
            workdir: URL(fileURLWithPath: workdir).standardizedFileURL.path
        )
        return
    }
    performIgnorePaths(paths, ignoreFilePath: ignoreFilePath)
}

func confirmPendingIgnoreFileCreation() {
    guard let request = fileWorkspace.pendingIgnoreFileCreation else { return }
    fileWorkspace.pendingIgnoreFileCreation = nil
    guard let repo,
          let workdir = repo.workdir(),
          URL(fileURLWithPath: workdir).standardizedFileURL.path == request.workdir
    else {
        feedbackCenter.error(
            "Ignore failed",
            detail: "The repository changed while confirming .gitignore creation.",
            nextStep: "Select the files again and retry."
        )
        return
    }
    performIgnorePaths(request.paths, ignoreFilePath: nil)
}

func performIgnorePaths(_ paths: [String], ignoreFilePath: String?) {
    guard let repo else { return }
    let targetPaths: [String]
    if let ignoreFilePath, let workdir = repo.workdir() {
        targetPaths = gitIgnoreTargetPaths(
            for: paths,
            ignoreFile: ignoreFilePath,
            workdir: workdir
        )
    } else {
        targetPaths = paths
    }
    guard !targetPaths.isEmpty else { return }
    beginFeedbackOperation("Ignore file")
    Task.detached(priority: .userInitiated) {
        do {
            let rules: [String]
            if let ignoreFilePath, let workdir = repo.workdir() {
                let relativeRules = targetPaths.map { path in
                    gitIgnoreRule(
                        for: path,
                        ignoreFile: ignoreFilePath,
                        workdir: workdir
                    )
                }
                rules = try repo.addToGitignoreAtPaths(
                    rules: relativeRules,
                    ignoreFile: ignoreFilePath,
                    targetPaths: targetPaths
                )
            } else {
                rules = try repo.addToGitignoreRules(rules: targetPaths)
            }
            await MainActor.run {
                let destination = ignoreFilePath ?? ".gitignore"
                self.feedbackCenter.success(
                    "Ignored",
                    detail: "\(rules.joined(separator: ", ")) -> \(destination)"
                )
                self.operationRecovery.feedback = nil
                self.refreshAll(showFeedback: false)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Ignore failed", detail: errorMessage(error), nextStep: "规则必须是非空单行。")
            }
        }
    }
}

/// Phase 5：在文件编辑器中打开 .gitignore（不存在则创建）。
func editGitignore() {
    guard let repo, let workdir = repo.workdir() else { return }
    let path = URL(fileURLWithPath: workdir).appendingPathComponent(".gitignore").path
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
}

}
