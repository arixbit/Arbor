import SwiftUI
import AppKit

extension ContentView {

    func presentVCSQuickActionsPanel() {
        let hasUnstagedChanges = repositoryStatus.entries.contains {
            $0.unstaged != .unchanged
                && $0.unstaged != .ignored
                && $0.unstaged != .conflicted
        }
        vcsQuickActionsPanel.present(
            items: vcsQuickActionItems(
                isShallowRepository: repositoryStatus.isShallowRepository,
                hasCurrentBranch: hasCurrentBranch,
                hasConflicts: hasConflicts,
                hasUnstagedTrackedChanges: vcsActionContext.hasUnstagedTrackedChanges,
                hasUnstagedChanges: hasUnstagedChanges,
                hasRepository: repo != nil,
                hasCommitChanges: vcsActionContext.hasLocalChanges,
                hasFetchInProgress: vcsActionContext.hasFetchInProgress
            ),
            onAction: { action in
                NotificationCenter.default.post(
                    name: .arborVCSAction,
                    object: action.rawValue
                )
            }
        )
    }

    private var hasCurrentBranch: Bool {
        branchWorkspace.branches.contains { $0.isCurrent }
    }

    private var hasConflicts: Bool {
        repositoryStatus.entries.contains {
            $0.staged == .conflicted || $0.unstaged == .conflicted
        }
    }

    var vcsActionContext: ArborVCSActionContext {
        let hasLocalChanges = repositoryStatus.entries.contains {
            ($0.staged != .unchanged && $0.staged != .ignored)
                || ($0.unstaged != .unchanged && $0.unstaged != .ignored)
        }
        let hasUnstagedTrackedChanges = repositoryStatus.entries.contains {
            $0.unstaged != .unchanged
                && $0.unstaged != .untracked
                && $0.unstaged != .ignored
                && $0.unstaged != .conflicted
        }
        let hasStagedChanges = repositoryStatus.entries.contains {
            $0.staged != .unchanged && $0.staged != .ignored
        }
        let hasProjectCommitChanges = multiRootWorkspace.changeGroups.contains { group in
            group.entries.contains {
                $0.staged != .unchanged
                    && $0.staged != .ignored
                    && $0.staged != .conflicted
            }
        }
        let allRepositoriesHaveHeadCommit: Bool
        if multiRootWorkspace.roots.isEmpty {
            allRepositoriesHaveHeadCommit = repositoryStatus.headId != nil
        } else {
            allRepositoriesHaveHeadCommit = multiRootWorkspace.roots.allSatisfy { $0.headId != nil }
        }
        return ArborVCSActionContext(
            hasRepository: repo != nil,
            allRepositoriesHaveHeadCommit: allRepositoriesHaveHeadCommit,
            hasCurrentBranch: hasCurrentBranch,
            hasLocalChanges: hasLocalChanges,
            hasUnstagedTrackedChanges: hasUnstagedTrackedChanges,
            hasStagedChanges: hasStagedChanges,
            hasConflicts: hasConflicts,
            isShallowRepository: repositoryStatus.isShallowRepository,
            hasRemotes: !remoteWorkspace.remotes.isEmpty,
            hasFetchInProgress: isArborFetchInProgress(
                isRunning: feedbackCenter.isRunning,
                operationName: feedbackCenter.operationName
            ),
            hasBackgroundVCSOperation: isArborBackgroundVCSOperationInProgress(
                feedbackIsRunning: feedbackCenter.isRunning,
                multiRootIsRunning: multiRootWorkspace.running || multiRootWorkspace.updateDiscoveryRunning
            ),
            projectPath: projectWorkspace.path,
            hasMultipleGitRoots: multiRootWorkspace.roots.count > 1,
            hasProjectCommitChanges: hasProjectCommitChanges || hasStagedChanges,
            hasTrackedUpstream: currentSyncStatus.map {
                $0.trackingExists && !$0.upstream.isEmpty
            } ?? false,
            hasSingleGitRoot: multiRootWorkspace.roots.count == 1,
            hasRepositoryOperationInProgress: operationRecovery.operation != nil
                || multiRootWorkspace.roots.contains { $0.operation != nil },
            hasMergeInProgress: isArborMergeInProgress(
                currentOperation: operationRecovery.operation?.kind,
                roots: multiRootWorkspace.roots
            ),
            hasRebaseInProgress: isArborRebaseInProgress(
                currentOperation: operationRecovery.operation?.kind,
                roots: multiRootWorkspace.roots,
                hasMultiRootSession: rebaseWorkspace.multiRootSession != nil
            ),
            hasNormalOrDetachedRepository: hasArborNormalOrDetachedRepository(
                currentOperation: operationRecovery.operation?.kind,
                currentRootPath: repo?.workdir(),
                roots: multiRootWorkspace.roots
            ),
            selectedLocalChangePath: selectedLocalChangePath,
            selectedResolvedConflictPath: selectedWorkspacePath.flatMap {
                operationRecovery.resolvedConflictPaths.contains($0) ? $0 : nil
            },
            selectedFileAction: selectedFileActionContext
        )
    }
}
