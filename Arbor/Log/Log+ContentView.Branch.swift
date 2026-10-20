import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {

var cherryPickTargetBranchLabel: String {
    if isLogAggregate {
        return "each repository's current branch"
    }
    return Arbor.cherryPickTargetBranch(
        mode: logList.viewMode,
        sourceBranch: logCherryPickCompareBranch,
        firstBranch: comparisonWorkspace.revision1,
        secondBranch: comparisonWorkspace.revision2,
        currentBranch: branchWorkspace.branches.first(where: \.isCurrent)?.name
    )
}


@ViewBuilder
var logBranchesPanelView: some View {
    if multiRootWorkspace.branchSnapshots.count > 1 {
        MultiRootLogBranchesPanel(
            projectPath: projectWorkspace.path,
            snapshots: multiRootWorkspace.branchSnapshots,
            groupByDirectory: $logBranchesPanel.groupByDirectory,
            groupByRepository: $logBranchesPanel.groupByRepository,
            selectionActionRaw: $logBranchesPanel.selectionActionRaw,
            showOnlyMy: $logBranchesPanel.showOnlyMy,
            myBranchIDs: logBranchesPanel.myBranchIDs,
            isLoadingMyBranches: logBranchesPanel.isLoadingMy,
            onShowOnlyMyChanged: setLogBranchesShowOnlyMy,
            onNavigate: navigateLogToBranch,
            onCompare: compareLogBranch,
            onFilter: applyLogBranchFilters,
            onNewBranch: presentMultiRootNewBranchDialog,
            onCleanup: deleteMergedBranches,
            onFindMerged: beginFindMergedBranches,
            onHide: { logBranchesVisible = false },
            onDelete: { rootPath, name in
                deleteBranchInRoot(rootPath: rootPath, name: name)
            },
            onCheckout: { rootPath, name, isRemote in
                checkoutBranchInRoot(rootPath: rootPath, reference: name, isRemote: isRemote)
            },
            onCheckoutAsNewBranch: { rootPath, name, isRemote in
                presentMultiRootNewBranchFromReference(
                    rootPath: rootPath,
                    reference: name,
                    isRemote: isRemote
                )
            },
            onOpenWorktree: { path in
                openWindow(value: path)
            },
            onCreateWorktreeFromReference: { rootPath, reference, isTag in
                presentNewWorktreeFromReference(
                    reference,
                    isTag: isTag,
                    rootPath: rootPath
                )
            },
            onCheckoutTag: { rootPath, name in
                checkoutTagInRoot(rootPath: rootPath, name: name)
            },
            onCheckoutAndUpdate: { rootPath, name, _ in
                executeMultiRootCheckoutAndUpdate(
                    reference: name,
                    rootPath: rootPath,
                    detach: false,
                    rebase: false
                )
            },
            onCheckoutWithRebase: { rootPath, name, isRemote in
                if isRemote {
                    presentNewBranchFromReference(
                        name,
                        isRemote: true,
                        afterCreateRebase: true,
                        rootPath: rootPath
                    )
                } else {
                    executeMultiRootCheckoutWithRebase(rootPath: rootPath, branch: name)
                }
            },
            onPullBranch: { rootPath, branch, rebase in
                pullBranchInRoot(rootPath: rootPath, branch: branch, rebase: rebase)
            },
            onUpdate: { rootPath, name in
                updateBranchInRoot(rootPath: rootPath, branch: name)
            },
            onMerge: { rootPath, name in
                mergeBranchInRoot(rootPath: rootPath, branch: name)
            },
            onRebase: { rootPath, name in
                rebaseCurrentInRoot(rootPath: rootPath, onto: name)
            },
            onShowDiffWithWorkingTree: { rootPath, branch in
                showBranchDiffWithWorkingTree(rootPath: rootPath, branch: branch)
            },
            onDeleteTag: { rootPath, name in
                deleteTagInRoot(rootPath: rootPath, name: name)
            },
            onPushTag: { rootPath, name in
                pushTagInRoot(rootPath: rootPath, name: name)
            },
            onPushTagToRemote: { rootPath, name, remote in
                pushTagInRoot(rootPath: rootPath, name: name, remote: remote)
            },
            onCompareSelected: { rootPath, first, second in
                compareBranchesCommitWiseInRoot(rootPath: rootPath, first: first, second: second)
            },
            onCompareSelectedFiles: { rootPath, first, second in
                compareBranchesInRoot(rootPath: rootPath, first: first, second: second)
            },
            onUpdateSelected: { targets in
                updateSelectedBranchesInRoots(targets)
            },
            onDeleteSelected: { targets in
                deleteSelectedBranchesInRoots(targets)
            },
            onEditRemote: { rootPath, name in
                beginMultiRootRemoteConfig(rootPath: rootPath, selectedRemote: name)
            },
            onRemoveRemote: { rootPath, name in
                removeRemoteInRoot(rootPath: rootPath, name: name)
            },
            onRemoveRemoteSelected: { groups in
                removeSelectedRemotesInRoots(groups)
            },
            onConfigureRemotes: beginConfigureRemotes,
            onPush: { rootPath, name in
                beginMultiRootPushDialog(rootPath: rootPath, branch: name)
            },
            onFetch: { rootPath, name in
                fetchRemoteBranchInRoot(rootPath: rootPath, branch: name)
            },
            onFetchAll: { doFetchAll() },
            onSetUpstream: { rootPath, name in
                setBranchUpstreamInRoot(rootPath: rootPath, branch: name)
            },
            onUnsetUpstream: { rootPath, name in
                unsetBranchUpstreamInRoot(rootPath: rootPath, branch: name)
            },
            onRename: { rootPath, name in
                renameBranchInRoot(rootPath: rootPath, oldName: name)
            },
            onDeleteRemote: { rootPath, name in
                deleteRemoteBranchInRoot(rootPath: rootPath, branch: name)
            },
            protectedBranchPatterns: effectiveProtectedBranchPatterns
        )
    } else {
        LogBranchesPanel(
            projectPath: projectWorkspace.path,
            branches: branchWorkspace.branches,
            remoteBranches: branchWorkspace.remoteBranches,
            remotes: remoteWorkspace.remotes,
            tags: tagWorkspace.tags,
            hasHeadCommit: repositoryStatus.headId != nil,
            syncStatuses: branchWorkspace.syncStatuses,
            protectedBranchPatterns: effectiveProtectedBranchPatterns,
            groupByDirectory: $logBranchesPanel.groupByDirectory,
            selectionActionRaw: $logBranchesPanel.selectionActionRaw,
            showOnlyMy: $logBranchesPanel.showOnlyMy,
            myBranchIDs: logBranchesPanel.myBranchIDs,
            isLoadingMyBranches: logBranchesPanel.isLoadingMy,
            onShowOnlyMyChanged: setLogBranchesShowOnlyMy,
            onNavigate: { branch in
                navigateLogToBranch(rootPath: nil, branch: branch)
            },
            onFilter: { filters in
                applyLogBranchFilters(filters)
            },
            onCompare: { branch in
                compareLogBranch(rootPath: nil, branch: branch)
            },
            onNewBranch: { presentNewBranchDialog() },
            onCleanup: deleteMergedBranches,
            onFindMerged: beginFindMergedBranches,
            onHide: { logBranchesVisible = false },
            onDelete: branchDelete,
            onCheckout: { reference, isRemote in
                if isRemote {
                    guard let branch = branchWorkspace.remoteBranches.first(where: { $0.name == reference }) else { return }
                    checkoutRemoteBranch(branch)
                } else {
                    switchBranch(reference)
                }
            },
            onCheckoutAsNewBranch: { reference, isRemote in
                presentNewBranchFromReference(reference, isRemote: isRemote)
            },
            worktrees: worktreeWorkspace.worktrees,
            onOpenWorktree: { path in
                openWindow(value: path)
            },
            onCreateWorktreeFromReference: { reference, isTag in
                presentNewWorktreeFromReference(reference, isTag: isTag)
            },
            onCheckoutTag: checkoutTag,
            onCheckoutAndUpdate: { reference, rebase in
                checkoutAndUpdate(reference, rebase: rebase)
            },
            onCheckoutWithRebase: { reference, isRemote in
                if isRemote {
                    presentNewBranchFromReference(reference, isRemote: true, afterCreateRebase: true)
                } else {
                    checkoutAndUpdate(reference, rebase: true)
                }
            },
            onPullBranch: { branch, rebase in
                pullSelectedBranch(branch, rebase: rebase)
            },
            onUpdate: updateSelectedBranch,
            onMerge: { branch in
                openMergeDialog(branch)
            },
            onRebase: { branch in
                openRebaseDialog(branch)
            },
            onShowDiffWithWorkingTree: { branch in
                showBranchDiffWithWorkingTree(rootPath: nil, branch: branch)
            },
            onDeleteTag: { tag in tagDelete(tag.name) },
            onPushTag: { tag in tagPushToRemote(tag) },
            onPushTagToRemote: { name, remote in
                tagPushToRemote(name, remote: remote)
            },
            onCompareSelected: { selection in
                guard let pair = branchDashboardComparisonPair(selection: selection),
                      let rootPath = projectWorkspace.path,
                      pair.rootPath == rootPath else { return }
                compareBranchesCommitWiseInRoot(
                    rootPath: rootPath,
                    first: pair.first,
                    second: pair.second
                )
            },
            onCompareSelectedFiles: { selection in
                guard let pair = branchDashboardComparisonPair(selection: selection),
                      let rootPath = projectWorkspace.path,
                      pair.rootPath == rootPath else { return }
                compareBranchesInRoot(
                    rootPath: rootPath,
                    first: pair.first,
                    second: pair.second
                )
            },
            onUpdateSelected: updateSelectedBranchesInRoots,
            onDeleteSelected: deleteSelectedBranchesInRoots,
            onPush: { branch in
                beginPushDialog(branch: branch)
            },
            onFetch: { reference in
                guard let branch = branchWorkspace.remoteBranches.first(where: { $0.name == reference }) else { return }
                fetchRemoteBranch(branch)
            },
            onFetchAll: { doFetchAll() },
            onSetUpstream: { branch in
                branchWorkspace.upstreamLocalBranch = branch
                branchWorkspace.showUpstreamDialog = true
            },
            onUnsetUpstream: unsetBranchUpstream,
            onRename: renameBranchFromPopup,
            onDeleteRemote: deleteRemoteBranch
        )
    }
}
}
