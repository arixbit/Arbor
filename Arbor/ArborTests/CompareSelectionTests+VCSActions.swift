import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {

    func testVCSQuickActionItemsMatchGitQuickListOrderAndEnablement() {
        let items = vcsQuickActionItems(
            isShallowRepository: false,
            hasCurrentBranch: false,
            hasConflicts: false,
            hasUnstagedTrackedChanges: false,
            hasUnstagedChanges: false
        )

        XCTAssertEqual(
            items.map(\.action),
            [
                .commit,
                .stageTracked,
                .branches,
                .push,
                .stash,
                .unstash,
                .worktrees,
                .stageAll,
                .copyCurrentBranchName,
                .resolveConflicts
            ]
        )
        XCTAssertFalse(items.first { $0.action == .copyCurrentBranchName }!.isEnabled)
        XCTAssertFalse(items.first { $0.action == .resolveConflicts }!.isEnabled)
        XCTAssertFalse(items.first { $0.action == .commit }!.isEnabled)
        XCTAssertFalse(items.first { $0.action == .stageTracked }!.isEnabled)
        XCTAssertFalse(items.first { $0.action == .stageAll }!.isEnabled)
        XCTAssertTrue(items.first { $0.action == .push }!.isEnabled)

        let stagedOnlyItems = vcsQuickActionItems(
            isShallowRepository: false,
            hasCurrentBranch: true,
            hasConflicts: false,
            hasUnstagedTrackedChanges: false,
            hasUnstagedChanges: false,
            hasCommitChanges: true
        )
        XCTAssertTrue(stagedOnlyItems.first { $0.action == .commit }!.isEnabled)

        let shallowItems = vcsQuickActionItems(
            isShallowRepository: true,
            hasCurrentBranch: true,
            hasConflicts: true,
            hasUnstagedTrackedChanges: true,
            hasUnstagedChanges: true
        )
        XCTAssertEqual(shallowItems.last?.action, .fetchUnshallow)
        XCTAssertTrue(shallowItems.first { $0.action == .copyCurrentBranchName }!.isEnabled)
        XCTAssertTrue(shallowItems.first { $0.action == .resolveConflicts }!.isEnabled)

        let shallowFetchBusyItems = vcsQuickActionItems(
            isShallowRepository: true,
            hasCurrentBranch: true,
            hasConflicts: true,
            hasUnstagedTrackedChanges: true,
            hasUnstagedChanges: true,
            hasFetchInProgress: true
        )
        XCTAssertFalse(shallowFetchBusyItems.first { $0.action == .fetchUnshallow }!.isEnabled)

        let noRepositoryItems = vcsQuickActionItems(
            isShallowRepository: false,
            hasCurrentBranch: true,
            hasConflicts: true,
            hasUnstagedTrackedChanges: true,
            hasUnstagedChanges: true,
            hasRepository: false
        )
        XCTAssertTrue(noRepositoryItems.allSatisfy { !$0.isEnabled })

        let untrackedOnlyItems = vcsQuickActionItems(
            isShallowRepository: false,
            hasCurrentBranch: true,
            hasConflicts: false,
            hasUnstagedTrackedChanges: false,
            hasUnstagedChanges: true
        )
        XCTAssertFalse(untrackedOnlyItems.first { $0.action == .stageTracked }!.isEnabled)
        XCTAssertTrue(untrackedOnlyItems.first { $0.action == .stageAll }!.isEnabled)

        let conflictOnlyItems = vcsQuickActionItems(
            isShallowRepository: false,
            hasCurrentBranch: true,
            hasConflicts: true,
            hasUnstagedTrackedChanges: false,
            hasUnstagedChanges: false
        )
        XCTAssertFalse(conflictOnlyItems.first { $0.action == .stageTracked }!.isEnabled)
        XCTAssertFalse(conflictOnlyItems.first { $0.action == .stageAll }!.isEnabled)
    }

    func testVCSActionContextMatchesGitMenuEnablement() {
        let unavailable = ArborVCSActionContext(
            hasRepository: false,
            hasCurrentBranch: false,
            hasLocalChanges: false,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: false
        )
        XCTAssertFalse(isArborVCSActionEnabled(.showLog, in: unavailable))
        XCTAssertFalse(isArborVCSActionEnabled(.showShelf, in: unavailable))
        XCTAssertFalse(isArborVCSActionEnabled(.showStash, in: unavailable))
        XCTAssertFalse(isArborVCSActionEnabled(.showStagingArea, in: unavailable))
        XCTAssertFalse(isArborVCSActionEnabled(.revertSelectedChanges, in: unavailable))
        XCTAssertFalse(isArborVCSActionEnabled(.configureRemotes, in: unavailable))
        XCTAssertFalse(isArborVCSActionEnabled(.showExternalLog, in: unavailable))
        XCTAssertFalse(isArborVCSActionEnabled(.quickActions, in: unavailable))
        XCTAssertFalse(isArborVCSActionEnabled(.searchEverywhere, in: unavailable))
        XCTAssertFalse(isArborVCSActionEnabled(.applyPatchFromClipboard, in: unavailable))
        XCTAssertFalse(isArborVCSActionEnabled(.commit, in: unavailable))
        XCTAssertFalse(isArborVCSActionVisible(.merge, in: unavailable))
        XCTAssertFalse(isArborVCSActionVisible(.rebase, in: unavailable))

        let clean = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: false,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: false
        )
        XCTAssertTrue(isArborVCSActionEnabled(.branches, in: clean))
        XCTAssertTrue(isArborVCSActionEnabled(.showShelf, in: clean))
        XCTAssertTrue(isArborVCSActionEnabled(.showStash, in: clean))
        XCTAssertTrue(isArborVCSActionEnabled(.showStagingArea, in: clean))
        XCTAssertFalse(isArborVCSActionEnabled(.revertSelectedChanges, in: clean))
        XCTAssertTrue(isArborVCSActionEnabled(.configureRemotes, in: clean))
        XCTAssertTrue(isArborVCSActionEnabled(.update, in: clean))
        XCTAssertTrue(isArborVCSActionEnabled(.reset, in: clean))
        XCTAssertFalse(isArborVCSActionEnabled(.showExternalLog, in: clean))
        XCTAssertTrue(isArborVCSActionEnabled(.newBranch, in: clean))
        XCTAssertTrue(isArborVCSActionEnabled(.merge, in: clean))
        XCTAssertTrue(isArborVCSActionEnabled(.rebase, in: clean))
        XCTAssertTrue(isArborVCSActionVisible(.merge, in: clean))
        XCTAssertTrue(isArborVCSActionEnabled(.push, in: clean))
        XCTAssertTrue(isArborVCSActionEnabled(.pull, in: clean))
        XCTAssertTrue(isArborVCSActionEnabled(.pullMerge, in: clean))
        XCTAssertTrue(pullDialogDefaultRebase(explicit: nil, savedOptions: [.rebase]))
        XCTAssertFalse(pullDialogDefaultRebase(explicit: nil, savedOptions: []))
        XCTAssertFalse(pullDialogDefaultRebase(explicit: false, savedOptions: [.rebase]))
        XCTAssertTrue(isArborVCSActionEnabled(.applyPatchFromClipboard, in: clean))
        XCTAssertFalse(isArborVCSActionEnabled(.commit, in: clean))
        XCTAssertFalse(isArborVCSActionEnabled(.fetch, in: clean))
        XCTAssertFalse(isArborVCSActionEnabled(.revertResolved, in: clean))
        XCTAssertFalse(isArborVCSActionEnabled(.resetToRemoteBranch, in: clean))

        let unbornRepository = ArborVCSActionContext(
            hasRepository: true,
            allRepositoriesHaveHeadCommit: false,
            hasCurrentBranch: false,
            hasLocalChanges: false,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: false
        )
        XCTAssertFalse(isArborVCSActionEnabled(.newBranch, in: unbornRepository))

        let selectedFile = ArborSelectedGitFileContext(
            path: "Sources/App.swift",
            rootRelativePath: "Sources/App.swift",
            isDirectory: false,
            owningRootPath: "/workspace/project",
            isPrimaryRoot: true,
            canCheckin: true,
            canAdd: false,
            canAnnotate: true,
            canCompareWithHead: true,
            canCompareWithSelectedRevision: true
        )
        let fileActions = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: true,
            hasUnstagedTrackedChanges: true,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: false,
            selectedFileAction: selectedFile
        )
        XCTAssertTrue(isArborVCSActionEnabled(.fileCheckin, in: fileActions))
        XCTAssertFalse(isArborVCSActionEnabled(.fileAdd, in: fileActions))
        XCTAssertTrue(isArborVCSActionEnabled(.fileAnnotate, in: fileActions))
        XCTAssertTrue(isArborVCSActionEnabled(.fileCompareSameVersion, in: fileActions))
        XCTAssertTrue(isArborVCSActionEnabled(.fileCompareSelectedRevision, in: fileActions))
        XCTAssertTrue(isArborVCSActionEnabled(.fileCompareWithBranch, in: fileActions))
        XCTAssertTrue(isArborVCSActionEnabled(.fileHistory, in: fileActions))

        let untrackedFile = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: true,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: false,
            selectedFileAction: ArborSelectedGitFileContext(
                path: "new.txt",
                rootRelativePath: "new.txt",
                isDirectory: false,
                owningRootPath: "/workspace/project",
                isPrimaryRoot: true,
                canCheckin: true,
                canAdd: true,
                canAnnotate: true,
                canCompareWithHead: false,
                canCompareWithSelectedRevision: false
            )
        )
        XCTAssertTrue(isArborVCSActionEnabled(.fileAdd, in: untrackedFile))

        let nestedFile = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: true,
            hasUnstagedTrackedChanges: true,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: false,
            selectedFileAction: ArborSelectedGitFileContext(
                path: "vendor/lib/Sources/App.swift",
                rootRelativePath: "Sources/App.swift",
                isDirectory: false,
                owningRootPath: "/workspace/project/vendor/lib",
                isPrimaryRoot: false,
                canCheckin: false,
                canAdd: false,
                canAnnotate: false,
                canCompareWithHead: true,
                canCompareWithSelectedRevision: true
            )
        )
        XCTAssertFalse(isArborVCSActionEnabled(.fileCheckin, in: nestedFile))
        XCTAssertFalse(isArborVCSActionEnabled(.fileAnnotate, in: nestedFile))
        XCTAssertTrue(isArborVCSActionEnabled(.fileCompareSameVersion, in: nestedFile))

        let fileActionBusy = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: true,
            hasUnstagedTrackedChanges: true,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: false,
            hasBackgroundVCSOperation: true,
            selectedFileAction: selectedFile
        )
        XCTAssertFalse(isArborVCSActionEnabled(.fileCheckin, in: fileActionBusy))
        XCTAssertFalse(isArborVCSActionEnabled(.fileAnnotate, in: fileActionBusy))

        let directoryActions = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: false,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: false,
            selectedFileAction: ArborSelectedGitFileContext(
                path: "Sources",
                rootRelativePath: "Sources",
                isDirectory: true,
                owningRootPath: "/workspace/project",
                isPrimaryRoot: true,
                canCheckin: false,
                canAdd: false,
                canAnnotate: false,
                canCompareWithHead: false,
                canCompareWithSelectedRevision: false
            )
        )
        XCTAssertTrue(isArborVCSActionEnabled(.fileCompareWithBranch, in: directoryActions))
        XCTAssertFalse(isArborVCSActionEnabled(.fileHistory, in: directoryActions))

        let resolvedSelection = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: false,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: false,
            selectedLocalChangePath: "conflicted.txt",
            selectedResolvedConflictPath: "conflicted.txt"
        )
        XCTAssertTrue(isArborVCSActionEnabled(.revertResolved, in: resolvedSelection))

        XCTAssertTrue(isArborFetchInProgress(isRunning: true, operationName: "Fetch"))
        XCTAssertTrue(isArborFetchInProgress(isRunning: true, operationName: "Fetch all remotes"))
        XCTAssertTrue(isArborFetchInProgress(isRunning: true, operationName: "Fetch remote branch"))
        XCTAssertTrue(isArborFetchInProgress(isRunning: true, operationName: "Prune remote branches"))
        XCTAssertFalse(isArborFetchInProgress(isRunning: true, operationName: "Pull"))
        XCTAssertFalse(isArborFetchInProgress(isRunning: false, operationName: "Fetch"))
        XCTAssertTrue(isArborBackgroundVCSOperationInProgress(
            feedbackIsRunning: false,
            multiRootIsRunning: false
        ) == false)
        XCTAssertTrue(isArborBackgroundVCSOperationInProgress(
            feedbackIsRunning: true,
            multiRootIsRunning: false
        ))
        XCTAssertTrue(isArborBackgroundVCSOperationInProgress(
            feedbackIsRunning: false,
            multiRootIsRunning: true
        ))

        let trackedRemote = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: false,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: true,
            hasTrackedUpstream: true,
            hasSingleGitRoot: true
        )
        XCTAssertTrue(isArborVCSActionEnabled(.resetToRemoteBranch, in: trackedRemote))

        let dirty = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: true,
            hasUnstagedTrackedChanges: true,
            hasStagedChanges: true,
            hasConflicts: true,
            isShallowRepository: true,
            hasRemotes: true,
            selectedLocalChangePath: "tracked.txt"
        )
        XCTAssertTrue(isArborVCSActionEnabled(.commitAndPush, in: dirty))
        XCTAssertTrue(isArborVCSActionEnabled(.stageTracked, in: dirty))
        XCTAssertTrue(isArborVCSActionEnabled(.stash, in: dirty))
        XCTAssertTrue(isArborVCSActionEnabled(.unstash, in: dirty))
        XCTAssertTrue(isArborVCSActionEnabled(.fetchUnshallow, in: dirty))
        XCTAssertTrue(isArborVCSActionEnabled(.resolveConflicts, in: dirty))
        XCTAssertTrue(isArborVCSActionEnabled(.fetchAll, in: dirty))
        XCTAssertTrue(isArborVCSActionEnabled(.revertSelectedChanges, in: dirty))

        let fetchBusy = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: false,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: true,
            hasRemotes: true,
            hasFetchInProgress: true
        )
        XCTAssertFalse(isArborVCSActionEnabled(.fetch, in: fetchBusy))
        XCTAssertFalse(isArborVCSActionEnabled(.fetchAll, in: fetchBusy))

        let updateBusy = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: false,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: true,
            hasBackgroundVCSOperation: true
        )
        XCTAssertFalse(isArborVCSActionEnabled(.update, in: updateBusy))
        XCTAssertFalse(isArborVCSActionEnabled(.reset, in: updateBusy))
        XCTAssertFalse(isArborVCSActionEnabled(.pullMerge, in: updateBusy))
        XCTAssertFalse(isArborVCSActionEnabled(.pullRebase, in: updateBusy))
        XCTAssertFalse(isArborVCSActionEnabled(.fetchPrune, in: fetchBusy))
        XCTAssertFalse(isArborVCSActionEnabled(.fetchUnshallow, in: fetchBusy))

        let operationBusy = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: false,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: true,
            hasRepositoryOperationInProgress: true,
            selectedLocalChangePath: "tracked.txt"
        )
        XCTAssertFalse(isArborVCSActionEnabled(.pullMerge, in: operationBusy))
        XCTAssertFalse(isArborVCSActionEnabled(.pullRebase, in: operationBusy))
        XCTAssertFalse(isArborVCSActionEnabled(.reset, in: operationBusy))
        XCTAssertFalse(isArborVCSActionEnabled(.revertResolved, in: operationBusy))
        XCTAssertFalse(isArborVCSActionEnabled(.revertSelectedChanges, in: operationBusy))

        let externalLog = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: false,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: false,
            projectPath: "/tmp/project"
        )
        XCTAssertTrue(isArborVCSActionEnabled(.showExternalLog, in: externalLog))

        let stagedOnly = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: true,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: true,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: true
        )
        XCTAssertFalse(isArborVCSActionEnabled(.stageTracked, in: stagedOnly))
        XCTAssertTrue(isArborVCSActionEnabled(.commit, in: stagedOnly))

        let multiRootCommit = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: false,
            hasLocalChanges: false,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: true,
            hasMultipleGitRoots: true,
            hasProjectCommitChanges: true,
            hasTrackedUpstream: true
        )
        XCTAssertTrue(isArborVCSActionEnabled(.commitAndPush, in: multiRootCommit))
        XCTAssertFalse(isArborVCSActionEnabled(.resetToRemoteBranch, in: multiRootCommit))

        let rebasePaused = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: true,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: true,
            hasConflicts: true,
            isShallowRepository: false,
            hasRemotes: true,
            hasRebaseInProgress: true
        )
        XCTAssertFalse(isArborVCSActionEnabled(.rebase, in: rebasePaused))
        XCTAssertFalse(isArborVCSActionVisible(.rebase, in: rebasePaused))
        XCTAssertTrue(isArborVCSActionVisible(.rebase, in: clean))

        let mergePaused = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: true,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: true,
            hasConflicts: true,
            isShallowRepository: false,
            hasRemotes: true,
            hasMergeInProgress: true
        )
        XCTAssertFalse(isArborVCSActionEnabled(.merge, in: mergePaused))
        XCTAssertFalse(isArborVCSActionVisible(.merge, in: mergePaused))

        let allRepositoriesBusy = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: true,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: true,
            hasConflicts: true,
            isShallowRepository: false,
            hasRemotes: true,
            hasNormalOrDetachedRepository: false
        )
        XCTAssertFalse(isArborVCSActionEnabled(.rebase, in: allRepositoriesBusy))
        XCTAssertTrue(isArborVCSActionVisible(.rebase, in: allRepositoriesBusy))
        XCTAssertFalse(isArborVCSActionEnabled(.merge, in: allRepositoriesBusy))
        XCTAssertTrue(isArborVCSActionVisible(.merge, in: allRepositoriesBusy))

        let secondaryRootMergeOperation = GitRootInfo(
            path: "/workspace/project/vendor/lib",
            displayName: "lib",
            relativePath: "vendor/lib",
            isSubmodule: true,
            headBranch: "feature",
            headId: "abc123",
            dirty: true,
            operation: .merge
        )
        XCTAssertTrue(
            isArborMergeInProgress(
                currentOperation: nil,
                roots: [secondaryRootMergeOperation]
            )
        )
        var secondaryRootCherryPicking = secondaryRootMergeOperation
        secondaryRootCherryPicking.operation = .cherryPick
        XCTAssertFalse(
            isArborMergeInProgress(
                currentOperation: nil,
                roots: [secondaryRootCherryPicking]
            )
        )

        let secondaryRootRebasing = GitRootInfo(
            path: "/workspace/project/vendor/lib",
            displayName: "lib",
            relativePath: "vendor/lib",
            isSubmodule: true,
            headBranch: "feature",
            headId: "abc123",
            dirty: true,
            operation: .rebase
        )
        XCTAssertTrue(
            isArborRebaseInProgress(
                currentOperation: nil,
                roots: [secondaryRootRebasing],
                hasMultiRootSession: false
            )
        )
        var secondaryRootMerging = secondaryRootRebasing
        secondaryRootMerging.operation = .merge
        XCTAssertFalse(
            isArborRebaseInProgress(
                currentOperation: nil,
                roots: [secondaryRootMerging],
                hasMultiRootSession: false
            )
        )

        let cleanRoot = GitRootInfo(
            path: "/workspace/project",
            displayName: "project",
            relativePath: ".",
            isSubmodule: false,
            headBranch: "main",
            headId: "def456",
            dirty: false,
            operation: nil
        )
        XCTAssertFalse(
            isArborRebaseInProgress(
                currentOperation: nil,
                roots: [cleanRoot],
                hasMultiRootSession: false
            )
        )
        XCTAssertFalse(
            hasArborNormalOrDetachedRepository(
                currentOperation: .merge,
                currentRootPath: cleanRoot.path,
                roots: [cleanRoot]
            )
        )
        var secondaryRootNormal = secondaryRootMerging
        secondaryRootNormal.operation = nil
        XCTAssertTrue(
            hasArborNormalOrDetachedRepository(
                currentOperation: .merge,
                currentRootPath: cleanRoot.path,
                roots: [cleanRoot, secondaryRootNormal]
            )
        )
    }

    func testVCSQuickActionFilterRequiresAllQueryTokensCaseInsensitively() {
        let items = vcsQuickActionItems(
            isShallowRepository: true,
            hasCurrentBranch: true,
            hasConflicts: true,
            hasUnstagedTrackedChanges: true,
            hasUnstagedChanges: true
        )

        XCTAssertEqual(
            filteredVCSQuickActionItems(items, query: "FULL history").map(\.action),
            [.fetchUnshallow]
        )
        XCTAssertEqual(
            filteredVCSQuickActionItems(items, query: "branch copy").map(\.action),
            [.copyCurrentBranchName]
        )
        XCTAssertTrue(filteredVCSQuickActionItems(items, query: "does-not-exist").isEmpty)
    }

    func testGitMergeRebaseWidgetItemsPreferLiveCurrentRootState() {
        let currentRoot = GitRootInfo(
            path: "/workspace/project",
            displayName: "project",
            relativePath: ".",
            isSubmodule: false,
            headBranch: "main",
            headId: "head",
            dirty: true,
            operation: .merge
        )
        let secondaryRoot = GitRootInfo(
            path: "/workspace/project/vendor/lib",
            displayName: "lib",
            relativePath: "vendor/lib",
            isSubmodule: true,
            headBranch: "feature",
            headId: "head-2",
            dirty: true,
            operation: .rebase
        )

        let items = gitMergeRebaseWidgetItems(
            currentRootPath: "/workspace/project/.",
            currentOperation: .rebase,
            roots: [currentRoot, secondaryRoot]
        )

        XCTAssertEqual(items.map(\.rootPath), ["/workspace/project", "/workspace/project/vendor/lib"])
        XCTAssertEqual(items.map(\.operation), [.rebase, .rebase])
        XCTAssertTrue(items.first?.isCurrent == true)
    }

    func testGitMergeRebaseWidgetItemsRemoveStaleCurrentSnapshotState() {
        let currentRoot = GitRootInfo(
            path: "/workspace/project",
            displayName: "project",
            relativePath: ".",
            isSubmodule: false,
            headBranch: "main",
            headId: "head",
            dirty: false,
            operation: .merge
        )
        let secondaryRoot = GitRootInfo(
            path: "/workspace/project/vendor/lib",
            displayName: "lib",
            relativePath: "vendor/lib",
            isSubmodule: true,
            headBranch: "feature",
            headId: "head-2",
            dirty: true,
            operation: .cherryPick
        )

        let items = gitMergeRebaseWidgetItems(
            currentRootPath: "/workspace/project",
            currentOperation: nil,
            roots: [currentRoot, secondaryRoot]
        )

        XCTAssertEqual(items.map(\.rootPath), ["/workspace/project/vendor/lib"])
        XCTAssertEqual(items.first?.operation, .cherryPick)
    }

    func testSelectedRevertPathIsTrackedAndSelectionScoped() {
        let tracked = FileEntry(
            path: "tracked.txt",
            oldPath: nil,
            staged: .modified,
            unstaged: .unchanged
        )
        let untracked = FileEntry(
            path: "new.txt",
            oldPath: nil,
            staged: .unchanged,
            unstaged: .untracked
        )
        let conflicted = FileEntry(
            path: "conflict.txt",
            oldPath: nil,
            staged: .conflicted,
            unstaged: .conflicted
        )
        let ignored = FileEntry(
            path: "ignored.log",
            oldPath: nil,
            staged: .unchanged,
            unstaged: .ignored
        )

        XCTAssertEqual(
            arborSelectedRevertPath(
                entries: [tracked, untracked, conflicted, ignored],
                candidates: ["new.txt", "tracked.txt"]
            ),
            "tracked.txt"
        )
        XCTAssertNil(
            arborSelectedRevertPath(
                entries: [tracked],
                candidates: ["tracked.txt"],
                headPresentByPath: ["tracked.txt": false]
            )
        )
        XCTAssertNil(
            arborSelectedRevertPath(
                entries: [tracked, untracked, conflicted, ignored],
                candidates: ["missing.txt", "new.txt", "conflict.txt", "ignored.log"]
            )
        )
    }

    @MainActor
    func testVCSQuickActionsPanelCoordinatorUsesReusableNonModalPanel() {
        let coordinator = VCSQuickActionsPanelCoordinator()
        let items = vcsQuickActionItems(
            isShallowRepository: false,
            hasCurrentBranch: true,
            hasConflicts: false,
            hasUnstagedTrackedChanges: false,
            hasUnstagedChanges: false
        )

        coordinator.present(items: items) { _ in }
        XCTAssertTrue(coordinator.isPresented)
        XCTAssertEqual(coordinator.panelWindow?.title, "Quick Git Actions")
        XCTAssertTrue(coordinator.panelWindow?.styleMask.contains(.utilityWindow) == true)
        let firstPanel = coordinator.panelWindow

        coordinator.present(items: Array(items.dropFirst()), onAction: { _ in })
        XCTAssertTrue(coordinator.isPresented)
        XCTAssertTrue(coordinator.panelWindow === firstPanel)

        coordinator.close()
        XCTAssertFalse(coordinator.isPresented)
        XCTAssertNil(coordinator.panelWindow)
    }
}
