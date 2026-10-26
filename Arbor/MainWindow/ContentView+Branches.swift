import SwiftUI
import AppKit

extension ContentView {
    var selectedBranchComparisonCommit: CommitInfo? {
        let commits = branchComparison.selectionSide == .first
            ? branchComparison.firstEntries
            : branchComparison.secondEntries
        return commits.first { $0.id == branchComparison.selectionID }
    }

    var currentSyncStatus: SyncStatus? {
        branchWorkspace.syncStatuses.first(where: { $0.branch == currentBranchName })
    }

    var currentBranchHasUnfetchedIncoming: Bool {
        hasUnfetchedIncomingBranch(
            rootPath: repo?.workdir() ?? projectWorkspace.path,
            branch: currentBranchName,
            in: gitSettings.autoFetchIncomingBranches
        )
    }

    var currentBranchName: String {
        branchWorkspace.branches.first(where: { $0.isCurrent })?.name ?? "（无分支）"
    }

    private var hasAnyMultiRootCommitChanges: Bool {
        multiRootWorkspace.changeGroups.contains { !$0.changedEntries.isEmpty }
    }

    private func openCommitWorkspaceFromBranchPopup() {
        branchWorkspace.showPopover = false
        projectWorkspace.toolWindowMode = .commit
        toolWindowExpanded = true
        projectPanelExpanded = false
    }

    @ViewBuilder
    var branchPopup: some View {
        Button {
            loadRepoData()
            if multiRootWorkspace.roots.count > 1 {
                // The Branches Popup action group needs a current project-wide
                // status snapshot to update Commit Changes enablement. Do not
                // leave a stale empty multi-root snapshot looking clean.
                loadMultiRootChanges()
            }
            branchWorkspace.showPopover = true
        } label: {
            HStack(spacing: 7) {
                Label(currentBranchName, systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
                if incomingOutgoingInfoEnabled,
                   let sync = currentSyncStatus, sync.trackingExists,
                   sync.ahead > 0 || sync.behind > 0 {
                    HStack(spacing: 3) {
                        if sync.ahead > 0 {
                            Image(systemName: "arrow.up")
                            Text("\(sync.ahead)")
                        }
                        if sync.behind > 0 {
                            Image(systemName: "arrow.down")
                            Text("\(sync.behind)")
                        }
                        if currentBranchHasUnfetchedIncoming {
                            Image(systemName: "arrow.down")
                            Text("?")
                        }
                    }
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(sync.behind > 0 ? .blue : .green)
                } else if incomingOutgoingInfoEnabled, currentBranchHasUnfetchedIncoming {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down")
                        Text("?")
                    }
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.blue)
                    .help("Remote has incoming commits not fetched locally")
                }
            }
        }
        .buttonStyle(.borderless)
        .disabled(repo == nil)
        .help("Branches: checkout / pull / push / fetch / merge / rebase / stash")
        .popover(isPresented: $branchWorkspace.showPopover, arrowEdge: .bottom) {
            if multiRootWorkspace.roots.count > 1 && !multiRootWorkspace.branchSnapshots.isEmpty {
                MultiRootBranchesPopover(
                    projectPath: projectWorkspace.path,
                    protectedBranchPatterns: effectiveProtectedBranchPatterns,
                    snapshots: multiRootWorkspace.branchSnapshots,
                    incomingBranches: gitSettings.autoFetchIncomingBranches,
                    operationContexts: multiRootWorkspace.roots.compactMap { root in
                        guard let kind = root.operation else { return nil }
                        return BranchPopupOperationContext(
                            rootPath: root.path,
                            displayName: root.displayName,
                            relativePath: root.relativePath,
                            kind: kind,
                            hasConflicts: operationRecovery.multiRootConflictGroups.contains {
                                $0.rootPath == root.path && !$0.paths.isEmpty
                            }
                        )
                    },
                    onOperationAction: { rootPath, action in
                        handleVCSActionRequest(
                            ArborVCSActionRequest(
                                kind: .operationRecovery,
                                projectPath: projectWorkspace.path,
                                rootPath: rootPath,
                                shelfName: "",
                                operationRecoveryAction: action.recoveryAction
                            )
                        )
                    },
                    onCommitChanges: {
                        branchWorkspace.showPopover = false
                        openMultiRootCommitDialog()
                    },
                    hasCommitChanges: hasAnyMultiRootCommitChanges,
                    onNewBranch: {
                        presentMultiRootNewBranchDialog()
                        branchWorkspace.showPopover = false
                    },
                    onFindMerged: {
                        beginFindMergedBranches()
                        branchWorkspace.showPopover = false
                    },
                    onRemoteTags: {
                        branchWorkspace.showPopover = false
                        tagWorkspace.showMultiRootRemoteTagsDialog = true
                    },
                    onCheckout: { rootPath, reference, isRemote in
                        checkoutBranchInRoot(
                            rootPath: rootPath,
                            reference: reference,
                            isRemote: isRemote
                        )
                        branchWorkspace.showPopover = false
                    },
                    onCheckoutAsNewBranch: { rootPath, reference, isRemote in
                        presentMultiRootNewBranchFromReference(
                            rootPath: rootPath,
                            reference: reference,
                            isRemote: isRemote
                        )
                    },
                    onCheckoutAndUpdate: { rootPath, reference, _, rebase in
                        executeMultiRootCheckoutAndUpdate(
                            reference: reference,
                            rootPath: rootPath,
                            detach: false,
                            rebase: rebase
                        )
                        branchWorkspace.showPopover = false
                    },
                    onCheckoutWithRebase: { rootPath, reference, isRemote in
                        if isRemote {
                            presentNewBranchFromReference(
                                reference,
                                isRemote: true,
                                afterCreateRebase: true,
                                rootPath: rootPath
                            )
                        } else {
                            executeMultiRootCheckoutWithRebase(
                                rootPath: rootPath,
                                branch: reference
                            )
                        }
                        branchWorkspace.showPopover = false
                    },
                    onCheckoutRecent: { rootPath, name in
                        checkoutRecentBranchInRoot(rootPath: rootPath, name: name)
                        branchWorkspace.showPopover = false
                    },
                    onCheckoutTag: { rootPath, name in
                        checkoutTagInRoot(rootPath: rootPath, name: name)
                        branchWorkspace.showPopover = false
                    },
                    onDeleteTag: { rootPath, name in
                        deleteTagInRoot(rootPath: rootPath, name: name)
                    },
                    onDeleteTagAcrossRoots: { name in
                        presentMultiRootDeleteTagDialog(name: name)
                        branchWorkspace.showPopover = false
                    },
                    onRenameTag: { rootPath, name in
                        renameTagInRoot(rootPath: rootPath, name: name)
                    },
                    onPushTag: { rootPath, name in
                        pushTagInRoot(rootPath: rootPath, name: name)
                    },
                    onPushTagToRemote: { rootPath, name, remote in
                        pushTagInRoot(rootPath: rootPath, name: name, remote: remote)
                    },
                    onShowDiffWithWorkingTree: { rootPath, name in
                        showBranchDiffWithWorkingTree(rootPath: rootPath, branch: name)
                    },
                    onPushAllTags: { rootPath, remote in
                        pushAllTagsInRoot(rootPath: rootPath, remote: remote)
                    },
                    onApplyStash: { rootPath, stashID, restoreIndex in
                        applyStashInRoot(rootPath: rootPath, stashID: stashID, restoreIndex: restoreIndex)
                    },
                    onPopStash: { rootPath, stashID, restoreIndex in
                        popStashInRoot(rootPath: rootPath, stashID: stashID, restoreIndex: restoreIndex)
                    },
                    onDropStash: { rootPath, stashID in
                        dropStashInRoot(rootPath: rootPath, stashID: stashID)
                    },
                    onStashBranch: { rootPath, stashID in
                        stashBranchInRoot(rootPath: rootPath, stashID: stashID)
                    },
                    onStashDiff: { rootPath, stashID in
                        showStashDiffInRoot(rootPath: rootPath, stashID: stashID)
                    },
                    onStashClear: { rootPath in
                        clearStashesInRoot(rootPath: rootPath)
                    },
                    onUpdateBranch: { rootPath, branch in
                        updateBranchInRoot(rootPath: rootPath, branch: branch)
                        branchWorkspace.showPopover = false
                    },
                    onForcePushedUpdate: { rootPath, branch in
                        updateForcePushedBranchInRoot(rootPath: rootPath, branch: branch)
                        branchWorkspace.showPopover = false
                    },
                    onForcePushedUpdateAcrossRoots: { branch in
                        updateForcePushedBranchAcrossRoots(branch)
                        branchWorkspace.showPopover = false
                    },
                    onPullBranch: { rootPath, branch, rebase in
                        pullBranchInRoot(rootPath: rootPath, branch: branch, rebase: rebase)
                        branchWorkspace.showPopover = false
                    },
                    onPullRemoteBranch: { rootPath, branch, rebase in
                        pullRemoteBranchInRoot(
                            rootPath: rootPath,
                            remoteBranch: branch,
                            rebase: rebase
                        )
                        branchWorkspace.showPopover = false
                    },
                    onDeleteRemote: { rootPath, branch in
                        deleteRemoteBranchInRoot(rootPath: rootPath, branch: branch)
                        branchWorkspace.showPopover = false
                    },
                    onDeleteRemoteAcrossRoots: { branch in
                        presentMultiRootRemoteDeleteDialog(branch: branch)
                        branchWorkspace.showPopover = false
                    },
                    onMerge: { rootPath, branch in
                        mergeBranchInRoot(rootPath: rootPath, branch: branch)
                        branchWorkspace.showPopover = false
                    },
                    onMergeAcrossRoots: presentMultiRootMergeFromPopup,
                    onRebase: { rootPath, branch in
                        rebaseCurrentInRoot(rootPath: rootPath, onto: branch)
                        branchWorkspace.showPopover = false
                    },
                    onCompare: { rootPath, branch in
                        compareBranchInRoot(rootPath: rootPath, branch: branch)
                        branchWorkspace.showPopover = false
                    },
                    onCompareSelected: { selection in
                        guard selection.count == 2,
                              let first = selection.first,
                              selection.allSatisfy({ $0.rootPath == first.rootPath }) else { return }
                        compareBranchesCommitWiseInRoot(
                            rootPath: first.rootPath,
                            first: first.name,
                            second: selection[1].name
                        )
                        branchWorkspace.showPopover = false
                    },
                    onCompareSelectedFiles: { selection in
                        guard selection.count == 2,
                              let first = selection.first,
                              selection.allSatisfy({ $0.rootPath == first.rootPath }) else { return }
                        compareBranchesInRoot(
                            rootPath: first.rootPath,
                            first: first.name,
                            second: selection[1].name
                        )
                        branchWorkspace.showPopover = false
                    },
                    onUpdateSelected: { selection in
                        updateSelectedBranchesInRoots(selection)
                        branchWorkspace.showPopover = false
                    },
                    onDeleteSelected: { selection in
                        deleteSelectedBranchesInRoots(selection)
                        branchWorkspace.showPopover = false
                    },
                    onPushDialog: { rootPath, branch in
                        beginMultiRootPushDialog(rootPath: rootPath, branch: branch)
                        branchWorkspace.showPopover = false
                    },
                    onEditRemote: { rootPath, name in
                        beginMultiRootRemoteConfig(rootPath: rootPath, selectedRemote: name)
                        branchWorkspace.showPopover = false
                    },
                    onRemoveRemote: { rootPath, name in
                        removeRemoteInRoot(rootPath: rootPath, name: name)
                    },
                    onRemoveRemoteSelected: { groups in
                        removeSelectedRemotesInRoots(groups)
                    },
                    onConfigureRemotes: {
                        beginConfigureRemotes()
                    },
                    onSetUpstream: { rootPath, branch in
                        setBranchUpstreamInRoot(rootPath: rootPath, branch: branch)
                        branchWorkspace.showPopover = false
                    },
                    onUnsetUpstream: { rootPath, branch in
                        unsetBranchUpstreamInRoot(rootPath: rootPath, branch: branch)
                        branchWorkspace.showPopover = false
                    },
                    onRenameBranch: { rootPath, branch in
                        renameBranchInRoot(rootPath: rootPath, oldName: branch)
                        branchWorkspace.showPopover = false
                    },
                    onRenameBranchAcrossRoots: { name in
                        presentMultiRootRenameBranchDialog(name: name)
                        branchWorkspace.showPopover = false
                    },
                    onDeleteBranchAcrossRoots: { name in
                        presentMultiRootDeleteBranchDialog(name: name)
                        branchWorkspace.showPopover = false
                    },
                    onDeleteBranch: { rootPath, branch in
                        deleteBranchInRoot(rootPath: rootPath, name: branch)
                        branchWorkspace.showPopover = false
                    },
                    onCheckoutReference: { rootPath in
                        checkoutReferenceFromInput(rootPath: rootPath)
                    },
                    onOpenWorktree: { path in
                        branchWorkspace.showPopover = false
                        openWindow(value: path)
                    },
                    onCreateWorktreeFromReference: { rootPath, reference, isTag in
                        branchWorkspace.showPopover = false
                        presentNewWorktreeFromReference(
                            reference,
                            isTag: isTag,
                            rootPath: rootPath
                        )
                    },
                    onProjectGitSettings: {
                        branchWorkspace.showPopover = false
                        gitSettings.showProjectGitSettings = true
                    },
                    onCancel: { branchWorkspace.showPopover = false }
                )
                .environment(\.locale, appLocale)
            } else {
                RebasedBranchesPopover(
                projectPath: projectWorkspace.path,
                branches: branchWorkspace.branches,
                remoteBranches: branchWorkspace.remoteBranches,
                recentBranches: branchWorkspace.recentBranches,
                tags: tagWorkspace.tags,
                comparisons: branchWorkspace.comparisons,
                syncStatuses: branchWorkspace.syncStatuses,
                incomingBranches: gitSettings.autoFetchIncomingBranches,
                stashes: stashUI.stashes,
                worktrees: worktreeWorkspace.worktrees,
                hasRemote: !remoteWorkspace.remotes.isEmpty,
                protectedBranchPatterns: effectiveProtectedBranchPatterns,
                isShallow: repositoryStatus.isShallowRepository,
                hasHeadCommit: repositoryStatus.headId != nil,
                hasCommitChanges: vcsActionContext.hasLocalChanges,
                onCheckout: switchBranch,
                onRenameBranch: renameBranchFromPopup,
                onDeleteBranch: deleteBranchFromPopup,
                onCheckoutRecent: checkoutRecentBranch,
                onCheckoutTag: checkoutTag,
                onCheckoutAsNewBranch: { reference, isRemote in
                    presentNewBranchFromReference(reference, isRemote: isRemote)
                },
                onDeleteTag: tagDelete,
                onRenameTag: { old in
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Rename Tag")
                    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
                    field.stringValue = old
                    alert.accessoryView = field
                    alert.addButton(withTitle: "Rename")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        tagRename(old, field.stringValue)
                    }
                },
                onPushTag: { tag in tagPushToRemote(tag) },
                tagPushRemotes: remoteWorkspace.remotes.map(\.name),
                onPushTagToRemote: { tag, remote in
                    tagPushToRemote(tag, remote: remote)
                },
                onShowDiffWithWorkingTree: { branch in
                    showBranchDiffWithWorkingTree(rootPath: nil, branch: branch)
                },
                onPushAllTags: { remote in
                    pushAllTagsToRemote(remote: remote)
                },
                onRemoteTags: {
                    branchWorkspace.showPopover = false
                    tagWorkspace.showRemoteTagsDialog = true
                },
                onCheckoutAndUpdate: { branch, rebase in checkoutAndUpdate(branch, rebase: rebase) },
                onUpdateBranch: updateSelectedBranch,
                onPushBranch: { branch in beginPushDialog(branch: branch) },
                onForcePushedUpdate: updateForcePushedBranch,
                onPullRemoteBranch: { branch, rebase in pullRemoteBranch(branch, rebase: rebase) },
                onCheckoutRemote: checkoutRemoteBranch,
                onCheckoutRemoteWithRebase: { branch in
                    presentNewBranchFromReference(
                        branch.name,
                        isRemote: true,
                        afterCreateRebase: true
                    )
                },
                onDeleteRemote: deleteRemoteBranch,
                onNewBranch: { presentNewBranchDialog() },
                onCommitChanges: openCommitWorkspaceFromBranchPopup,
                onFindMerged: {
                    beginFindMergedBranches()
                    branchWorkspace.showPopover = false
                },
                onCheckoutReference: checkoutReferenceFromInput,
                onOpenWorktree: { path in
                    branchWorkspace.showPopover = false
                    openWindow(value: path)
                },
                onCreateWorktreeFromReference: { reference, isTag in
                    branchWorkspace.showPopover = false
                    presentNewWorktreeFromReference(reference, isTag: isTag)
                },
                onCompare: compareBranchFromPopup,
                onMerge: openMergeDialog,
                onRebase: openRebaseDialog,
                onStash: presentStashDialog,
                onApplyStash: { stashID, restoreIndex in stashApply(stashID: stashID, restoreIndex: restoreIndex) },
                onPopStash: { stashID, restoreIndex in stashPop(stashID: stashID, restoreIndex: restoreIndex) },
                onDropStash: stashDrop(stashID:),
                onStashBranch: stashBranch(stashID:),
                onStashDiff: showStashDiffFor(stashID:),
                onStashClear: stashClearAll,
                onNewTag: beginNewTagDialog,
                onShelve: { shelfWorkspace.showCreateDialog = true },
                onUpdate: { doPull(nil, rebase: $0) },
                onPush: { beginPushDialog() },
                onFetch: { doFetch(nil) },
                onRefresh: { loadRepoData() },
                onConfigureRemotes: beginConfigureRemotes,
                onProjectGitSettings: {
                    branchWorkspace.showPopover = false
                    gitSettings.showProjectGitSettings = true
                },
                onFetchAll: { doFetchAll() },
                onFetchPrune: doFetchPrune,
                onFetchUnshallow: doFetchUnshallow,
                onSetUpstream: { branch in
                    branchWorkspace.upstreamLocalBranch = branch
                    branchWorkspace.showUpstreamDialog = true
                },
                onUnsetUpstream: unsetBranchUpstream,
                operationState: operationRecovery.operation,
                onOperationContinue: {
                    doOperationContinue()
                    branchWorkspace.showPopover = false
                },
                onOperationSkip: {
                    doOperationSkip()
                    branchWorkspace.showPopover = false
                },
                onOperationAbort: {
                    doOperationAbort()
                    branchWorkspace.showPopover = false
                }
                )
                .environment(\.locale, appLocale)
            }
        }
    }

    private func compareBranchFromPopup(_ branch: String) {
        projectWorkspace.toolWindowMode = .log
        toolWindowExpanded = true
        projectPanelExpanded = false
        compareLogBranch(rootPath: nil, branch: branch)
        branchWorkspace.showPopover = false
    }

    func renameBranchFromPopup(_ oldName: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename Branch")
        let field = NSTextField(string: oldName)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != oldName else { return }
        branchWorkspace.renameOld = oldName
        branchWorkspace.renameNew = newName
        branchRename()
    }

    private func deleteBranchFromPopup(_ name: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete branch \(name)?")
        alert.informativeText = String(localized: "This removes the local branch reference. Unmerged commits are not deleted from the object database immediately.")
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        branchDelete(name)
    }

    func handleBranchCleanupAction(_ action: BranchCleanupWindowAction?) {
        guard let action else { return }
        branchCleanupWindow.action = nil
        switch action {
        case let .calculate(target, prefix):
            calculateBranchCleanup(target: target, prefix: prefix)
        case let .delete(selections):
            deleteBranchCleanup(selections)
        case .refresh:
            refreshBranchCleanup()
        }
    }
}
