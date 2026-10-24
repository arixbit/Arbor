import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

func chooseUpstreamFeedbackAction(for error: Error) -> FeedbackAction? {
    let branch: String
    switch error as? EngineError {
    case let .NoUpstream(name):
        branch = name
    case let .TrackingMissing(name, _):
        branch = name
    default:
        return nil
    }
    guard !branch.isEmpty else { return nil }
    return FeedbackAction(title: "Choose Upstream Branch") {
        self.branchWorkspace.upstreamLocalBranch = branch
        self.loadRepoData(includeComparisons: false)
        self.branchWorkspace.showUpstreamDialog = true
    }
}

/// 建立或修改本地分支的 configured upstream。
func setBranchUpstream(_ branch: String, upstream: String) {
    guard let repo else { return }
    let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
    let upstream = upstream.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !branch.isEmpty, !upstream.isEmpty else { return }
    beginFeedbackOperation("Set branch upstream")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.branchSetUpstream(branch: branch, upstream: upstream)
            await MainActor.run {
                self.feedbackCenter.success("Upstream configured", detail: "\(branch) → \(upstream)")
                self.loadRepoData()
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Set upstream failed", detail: errorMessage(error), nextStep: "选择一个有效的 remote-tracking branch 后重试。")
            }
        }
    }
}

/// 清除本地分支的 configured upstream，不删除本地或远程分支。
func unsetBranchUpstream(_ branch: String) {
    guard let repo else { return }
    beginFeedbackOperation("Unset branch upstream")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.branchUnsetUpstream(branch: branch)
            await MainActor.run {
                self.feedbackCenter.success("Upstream removed", detail: branch)
                self.loadRepoData()
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Unset upstream failed", detail: errorMessage(error))
            }
        }
    }
}

/// 多 root tracking 配置使用显式输入，避免把当前 root 的 remote branch 列表
/// 错误地复用到另一个 root。
func setBranchUpstreamInRoot(rootPath: String, branch: String) {
    let alert = NSAlert()
    alert.messageText = String(localized: "Set Upstream")
    alert.informativeText = String(localized: "Enter a remote-tracking branch, for example origin/\(branch).")
    let field = NSTextField(string: "origin/\(branch)")
    field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "Set Upstream")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let upstream = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !upstream.isEmpty else { return }
    setBranchUpstreamInRoot(
        rootPath: rootPath,
        branch: branch,
        upstream: upstream,
        requireCurrentBranch: false
    )
}

/// 保存已从目标 root 的 remote-tracking branch 选择器中选出的 upstream。
/// The write remains explicitly root-scoped; it never falls back to `repo`.
func setBranchUpstreamInRoot(
    rootPath: String,
    branch: String,
    upstream: String,
    requireCurrentBranch: Bool
) {
    beginFeedbackOperation("Set branch upstream")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            if requireCurrentBranch {
                let currentBranch = try rootRepo.branchList().first(where: { $0.isCurrent })?.name
                guard currentBranch == branch else {
                    throw NSError(
                        domain: "Arbor.UpstreamRecovery",
                        code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "The target root is no longer on branch '\(branch)'."
                        ]
                    )
                }
            }
            try rootRepo.branchSetUpstream(branch: branch, upstream: upstream)
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.success("Upstream configured", detail: "\(branch) → \(upstream) · \(rootPath)")
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.error("Set upstream failed", detail: "\(branch) · \(rootPath): \(errorMessage(error))")
            }
        }
    }
}

/// Load the upstream choices from the skipped root itself before showing the
/// shared picker. This matches IntelliJ's repository-qualified recovery action
/// and avoids asking users to hand-type a refspec in a multi-root project.
func presentUpstreamDialogInRoot(rootPath: String, displayName: String, branch: String) {
    let normalizedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
    let normalizedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedRoot.isEmpty, !normalizedBranch.isEmpty else { return }
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: normalizedRoot)
            let currentBranch = try rootRepo.branchList().first(where: { $0.isCurrent })?.name
            guard currentBranch == normalizedBranch else {
                await MainActor.run {
                    self.feedbackCenter.warning(
                        "Upstream recovery is stale",
                        detail: "\(displayName) is no longer on branch \(normalizedBranch)."
                    )
                }
                return
            }
            let remoteBranches = try rootRepo.remoteBranchList()
            let currentUpstream = (try? rootRepo.syncStatus())?.first {
                $0.branch == normalizedBranch && $0.trackingExists
            }?.upstream
            await MainActor.run {
                self.branchWorkspace.multiRootUpstreamContext = MultiRootUpstreamContext(
                    rootPath: normalizedRoot,
                    displayName: displayName,
                    localBranch: normalizedBranch,
                    remoteBranches: remoteBranches,
                    currentUpstream: currentUpstream
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Load upstream branches failed",
                    detail: "\(displayName) · \(errorMessage(error))"
                )
            }
        }
    }
}

func unsetBranchUpstreamInRoot(rootPath: String, branch: String) {
    beginFeedbackOperation("Unset branch upstream")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            try rootRepo.branchUnsetUpstream(branch: branch)
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.success("Upstream removed", detail: "\(branch) · \(rootPath)")
            }
        } catch {
            await MainActor.run {
                self.loadMultiRoots()
                self.feedbackCenter.error("Unset upstream failed", detail: "\(branch) · \(rootPath): \(errorMessage(error))")
            }
        }
    }
}

}
