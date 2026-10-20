import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {

/// BRANCH-001：Recent 分组检出（recent_branches 数据源）。
func checkoutRecentBranch(_ name: String) {
    // Keep Recent and Local Branches on the same checkout state machine so a
    // dirty-worktree checkout cannot bypass Smart/Force/Cancel recovery.
    switchBranch(name)
}

func switchBranch(_ name: String) {
    guard let repo else { return }
    beginFeedbackOperation("Checkout branch")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.switchBranch(name: name)
            await MainActor.run {
                self.repositoryStatus.loadError = nil
                self.feedbackCenter.success("Branch checked out", detail: name)
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
            }
        } catch {
            let detail = errorMessage(error)
            await MainActor.run {
                self.presentCheckoutRecovery(
                    repo: repo,
                    name: name,
                    detail: detail,
                    onSmart: { self.smartCheckoutBranch(repo: repo, name: name) },
                    onForce: { self.forceCheckoutBranch(repo: repo, name: name) }
                )
            }
        }
    }
}

/// Branches Popup 多 root 行为：在选中 root 内检出，不把同名分支误操作到
/// 当前窗口绑定的另一个 repository。
func checkoutBranchInRoot(rootPath: String, reference: String, isRemote: Bool) {
    beginFeedbackOperation(isRemote ? "Checkout remote branch" : "Checkout branch")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            if isRemote {
                try rootRepo.checkoutRemoteBranch(remoteBranch: reference, localName: nil)
            } else {
                try rootRepo.switchBranch(name: reference)
            }
            await MainActor.run {
                self.feedbackCenter.success(
                    isRemote ? "Remote branch checked out" : "Branch checked out",
                    detail: reference
                )
                self.loadMultiRoots()
                self.refreshAll(showFeedback: false)
            }
        } catch {
            let detail = errorMessage(error)
            do {
                let rootRepo = try openRepository(path: rootPath)
                await MainActor.run {
                    self.presentCheckoutRecovery(
                        repo: rootRepo,
                        name: reference,
                        detail: detail,
                        onSmart: {
                            if isRemote {
                                self.smartCheckoutRemoteBranch(repo: rootRepo, remoteBranch: reference) {
                                    self.loadMultiRoots()
                                }
                            } else {
                                self.smartCheckoutBranch(repo: rootRepo, name: reference) {
                                    self.loadMultiRoots()
                                }
                            }
                        },
                        onForce: {
                            if isRemote {
                                self.forceCheckoutRemoteBranch(repo: rootRepo, remoteBranch: reference) {
                                    self.loadMultiRoots()
                                }
                            } else {
                                self.forceCheckoutBranch(repo: rootRepo, name: reference) {
                                    self.loadMultiRoots()
                                }
                            }
                        }
                    )
                }
            } catch {
                await MainActor.run {
                    self.feedbackCenter.error("Root checkout failed", detail: detail)
                }
            }
        }
    }
}

/// Recent branch checkout is the same local-branch operation, but the root is
/// explicit so a matching branch name in another repository cannot win.
func checkoutRecentBranchInRoot(rootPath: String, name: String) {
    checkoutBranchInRoot(rootPath: rootPath, reference: name, isRemote: false)
}

func smartCheckoutBranch(
    repo: Repository,
    name: String,
    onSuccess: @escaping () -> Void = {}
) {
    let cancel = GitCancelHandle()
    let projectSavePolicy = GitLocalChangesSavePolicySettings.engineValue(for: projectWorkspace.path)
    beginFeedbackOperation("Smart Checkout", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            try repo.smartSwitchBranchWithPolicyAndCancel(
                name: name,
                savePolicy: projectSavePolicy,
                cancel: cancel
            )
            await MainActor.run {
                self.repositoryStatus.loadError = nil
                self.feedbackCenter.success("Smart Checkout completed", detail: name)
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
                onSuccess()
            }
        } catch {
            if case .Cancelled = error as? EngineError {
                await MainActor.run {
                    self.feedbackCenter.warning(
                        "Smart Checkout cancelled",
                        detail: name,
                        nextStep: "The preservation Shelf was kept when restore had started; retry after reviewing the root."
                    )
                }
            } else if case let .StashApplyConflict(paths, stashID) = error as? EngineError {
                await MainActor.run {
                    let viewAction = stashID.flatMap {
                        self.savedChangesFeedbackAction(
                            kind: .stash,
                            identifier: $0,
                            rootPath: repo.workdir()
                        )
                    }
                    self.showStashRestoreConflict(
                        paths,
                        additionalActions: viewAction.map { [$0] } ?? [],
                        stashID: stashID
                    )
                }
            } else if case let .ShelveApplyConflict(name, paths) = error as? EngineError {
                await MainActor.run {
                    let viewAction = self.savedChangesFeedbackAction(
                        kind: .shelf,
                        identifier: name,
                        rootPath: repo.workdir()
                    )
                    self.presentShelveConflict(
                        name: name,
                        paths: paths,
                        isPop: true,
                        additionalActions: viewAction.map { [$0] } ?? []
                    )
                }
            } else {
                await MainActor.run {
                    self.repositoryStatus.loadError = errorMessage(error)
                    self.feedbackCenter.error(
                        "Smart Checkout failed",
                        detail: errorMessage(error),
                        nextStep: "The original local changes were restored when possible."
                    )
                }
            }
        }
    }
}

func forceCheckoutBranch(
    repo: Repository,
    name: String,
    onSuccess: @escaping () -> Void = {}
) {
    beginFeedbackOperation("Force Checkout")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.forceSwitchBranch(name: name)
            await MainActor.run {
                self.repositoryStatus.loadError = nil
                self.feedbackCenter.success("Force Checkout completed", detail: name)
                self.refreshAll(showFeedback: false)
                self.loadRepoData()
                onSuccess()
            }
        } catch {
            await MainActor.run {
                self.repositoryStatus.loadError = errorMessage(error)
                self.feedbackCenter.error("Force Checkout failed", detail: errorMessage(error))
            }
        }
    }
}
}
