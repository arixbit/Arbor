import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {

    func testBranchPopupActionSpeedSearchMatchesOnlyEnabledActionFilter() {
        XCTAssertEqual(
            filteredBranchPopupActions(
                query: "commit",
                filterByAction: true
            ),
            [.commitChanges]
        )
        XCTAssertEqual(
            filteredBranchPopupActions(
                query: "new branch",
                filterByAction: true
            ),
            [.newBranch]
        )
        XCTAssertEqual(
            filteredBranchPopupActions(
                query: "checkout revision",
                filterByAction: true
            ),
            [.checkoutReference]
        )
        XCTAssertTrue(
            filteredBranchPopupActions(
                query: "new branch",
                filterByAction: false
            ).isEmpty
        )
        XCTAssertEqual(
            branchPopupVisibleActions(
                query: "no matching action",
                filterByAction: false
            ),
            BranchPopupActionID.allCases
        )
    }

    func testBranchPopupCommitActionRequiresChangesAndExplainsDisabledState() {
        XCTAssertFalse(
            isBranchPopupActionEnabled(
                .commitChanges,
                hasHeadCommit: true,
                hasCommitChanges: false
            )
        )
        XCTAssertTrue(
            isBranchPopupActionEnabled(
                .commitChanges,
                hasHeadCommit: false,
                hasCommitChanges: true
            )
        )
        XCTAssertFalse(
            isBranchPopupActionEnabled(.newBranch, hasHeadCommit: false)
        )
        XCTAssertTrue(
            isBranchPopupActionEnabled(.newBranch, hasHeadCommit: true)
        )
        XCTAssertTrue(
            isBranchPopupActionEnabled(.checkoutReference, hasHeadCommit: false)
        )
        XCTAssertEqual(
            branchPopupActionDisabledDescription(.newBranch, hasHeadCommit: false),
            "Cannot create new branch in empty repository. Make initial commit first"
        )
        XCTAssertNil(
            branchPopupActionDisabledDescription(.newBranch, hasHeadCommit: true)
        )
        XCTAssertNil(
            branchPopupActionDisabledDescription(.checkoutReference, hasHeadCommit: false)
        )
        XCTAssertEqual(
            branchPopupActionDisabledDescription(
                .commitChanges,
                hasHeadCommit: true,
                hasCommitChanges: false
            ),
            "There are no Git changes to commit"
        )
    }

    func testBranchPopupNewBranchActionIsVisibleButDisabledForUnbornRepositories() {
        XCTAssertFalse(
            isBranchPopupActionEnabled(.newBranch, hasHeadCommit: false)
        )
        XCTAssertTrue(
            isBranchPopupActionEnabled(.newBranch, hasHeadCommit: true)
        )
        XCTAssertTrue(
            isBranchPopupActionEnabled(.checkoutReference, hasHeadCommit: false)
        )
        XCTAssertEqual(
            branchPopupActionDisabledDescription(.newBranch, hasHeadCommit: false),
            "Cannot create new branch in empty repository. Make initial commit first"
        )
        XCTAssertNil(
            branchPopupActionDisabledDescription(.newBranch, hasHeadCommit: true)
        )
        XCTAssertNil(
            branchPopupActionDisabledDescription(.checkoutReference, hasHeadCommit: false)
        )
        XCTAssertFalse(isFindMergedBranchesActionEnabled(localBranchCounts: [1]))
        XCTAssertTrue(isFindMergedBranchesActionEnabled(localBranchCounts: [1, 2]))
    }

    func testMultiRootBranchRepositorySearchMatchesNameAndRelativePath() {
        XCTAssertTrue(
            branchPopupRepositorySearchMatches(
                displayName: "Payments",
                relativePath: "services/payments",
                query: "pay"
            )
        )
        XCTAssertTrue(
            branchPopupRepositorySearchMatches(
                displayName: "Payments",
                relativePath: "services/payments",
                query: "services"
            )
        )
        XCTAssertFalse(
            branchPopupRepositorySearchMatches(
                displayName: "Payments",
                relativePath: "services/payments",
                query: ""
            )
        )
        XCTAssertFalse(
            branchPopupRepositorySearchMatches(
                displayName: "Payments",
                relativePath: "services/payments",
                query: "frontend"
            )
        )
    }

    func testMultiRootRepositoryTargetParticipatesInKeyboardSelection() {
        let repository = BranchTreeTarget(
            id: "multi.repository:/workspace/services/payments",
            value: "Payments services/payments",
            title: "Payments",
            kind: .repository,
            rootPath: "/workspace/services/payments"
        )
        let branch = BranchTreeTarget(
            id: "multi.local:payments",
            value: "payments",
            title: "payments",
            kind: .local
        )

        XCTAssertEqual(
            bestBranchTreeTargetID(
                query: "services",
                targets: [repository, branch]
            ),
            repository.id
        )
    }

    func testBranchPopupRepositoryScopeEscapeReturnsBeforeDismiss() {
        XCTAssertEqual(
            branchPopupExitDestination(repositoryFilter: "/workspace/services/payments"),
            .repositoryList
        )
        XCTAssertEqual(
            branchPopupExitDestination(repositoryFilter: "  "),
            .dismiss
        )
    }

    func testBranchPopupOperationActionsMatchIntelliJGroupsAndConflictVisibility() {
        XCTAssertEqual(
            branchPopupOperationActions(for: .rebase, hasConflicts: false),
            [.abortRebase, .rebaseContinue, .rebaseSkip]
        )
        XCTAssertEqual(
            branchPopupOperationActions(for: .merge, hasConflicts: false),
            [.mergeAbort]
        )
        XCTAssertEqual(
            gitMainMenuOperationActions(for: .merge, hasConflicts: false),
            [.mergeCommit, .mergeAbort]
        )
        XCTAssertEqual(
            gitMainMenuOperationActions(for: .merge, hasConflicts: true),
            [.mergeAbort]
        )
        XCTAssertEqual(
            branchPopupOperationActions(for: .cherryPick, hasConflicts: false),
            [.cherryPickAbort, .cherryPickContinue]
        )
        XCTAssertEqual(
            branchPopupOperationActions(for: .cherryPick, hasConflicts: true),
            [.cherryPickAbort]
        )
        XCTAssertEqual(
            branchPopupOperationActions(for: .revert, hasConflicts: true),
            [.revertAbort]
        )
    }

    func testBranchDashboardActionUpdateDisablesCommitDependentActionsForUnbornRoots() {
        let head = BranchDashboardReference(
            rootPath: "/workspace/unborn",
            name: "HEAD",
            kind: .head,
            remote: nil,
            isCurrent: true,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false,
            hasHeadCommit: false
        )
        let currentBranch = BranchDashboardReference(
            rootPath: "/workspace/unborn",
            name: "main",
            kind: .local,
            remote: nil,
            isCurrent: true,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false,
            hasHeadCommit: false
        )

        let headAvailability = BranchDashboardActionAvailability.resolve(selection: [head])
        let branchAvailability = BranchDashboardActionAvailability.resolve(selection: [currentBranch])

        XCTAssertTrue(headAvailability.contains(.checkoutAsNewBranch))
        XCTAssertFalse(headAvailability.isEnabled(.checkoutAsNewBranch))
        XCTAssertTrue(headAvailability.contains(.createWorktree))
        XCTAssertFalse(headAvailability.isEnabled(.createWorktree))
        XCTAssertFalse(branchAvailability.isEnabled(.checkoutAsNewBranch))
        XCTAssertFalse(branchAvailability.isEnabled(.createWorktree))
    }
}
