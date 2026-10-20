import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {

    func testMultiRootCheckoutRollbackRequestRoundTripsExactTargets() throws {
        let target = PersistedMultiRootCheckoutTarget(
            MultiRootBranchTarget(
                rootPath: "/project/app",
                checkedOut: true,
                previousBranch: "main",
                previousHead: "1111111",
                expectedHead: "2222222",
                expectedBranch: "feature",
                createdBranch: "feature"
            )
        )
        let request = ArborVCSActionRequest(
            kind: .rollbackMultiRootCheckout,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            checkoutReference: "feature",
            checkoutTargets: [target]
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.checkoutTargets?.map(\.rootPath), ["/project/app"])
        XCTAssertEqual(decoded.checkoutTargets?.first?.makeLiveTarget().previousHead, "1111111")
    }

    func testMultiRootBranchCreateRollbackRequestRoundTripsExactTipState() throws {
        let target = PersistedMultiRootBranchCreateTarget(
            MultiRootBranchCreateTarget(
                rootPath: "/project/app",
                checkedOut: true,
                previousBranch: "main",
                previousHead: "1111111",
                expectedHead: "3333333",
                expectedBranch: "topic",
                previousBranchTip: "2222222",
                expectedBranchTip: "3333333"
            )
        )
        let request = ArborVCSActionRequest(
            kind: .rollbackMultiRootBranchCreate,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootBranchName: "topic",
            multiRootBranchCreateRollbackTargets: [target]
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(
            decoded.multiRootBranchCreateRollbackTargets?.first?.previousBranchTip,
            "2222222"
        )
        XCTAssertEqual(
            decoded.multiRootBranchCreateRollbackTargets?.first?.makeLiveTarget().expectedBranchTip,
            "3333333"
        )
    }

    @MainActor
    func testFeedbackHistoryRestoresMultiRootBranchCreateRollbackActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterMultiRootBranchCreateRollbackTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .rollbackMultiRootBranchCreate,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootBranchName: "topic",
            multiRootBranchCreateRollbackTargets: [
                PersistedMultiRootBranchCreateTarget(
                    MultiRootBranchCreateTarget(
                        rootPath: "/project/app",
                        checkedOut: false,
                        previousBranch: "main",
                        previousHead: "1111111",
                        expectedHead: nil,
                        expectedBranch: nil,
                        previousBranchTip: "2222222",
                        expectedBranchTip: "3333333"
                    )
                )
            ]
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Multi-root branch creation partially completed",
            additionalActions: [
                FeedbackAction(
                    title: "Rollback Successful Roots",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testFeedbackHistoryRestoresMultiRootCheckoutRollbackActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterMultiRootRollbackTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .rollbackMultiRootCheckout,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            checkoutReference: "feature",
            checkoutTargets: [
                PersistedMultiRootCheckoutTarget(
                    MultiRootBranchTarget(
                        rootPath: "/project/app",
                        checkedOut: true,
                        previousBranch: "main",
                        previousHead: "1111111",
                        expectedHead: "2222222",
                        expectedBranch: "feature",
                        createdBranch: nil
                    )
                )
            ]
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Checkout partially completed",
            additionalActions: [
                FeedbackAction(
                    title: "Rollback Successful Roots",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testMultiRootBranchRenameRollbackActionRoundTripsAndSurvivesReload() throws {
        let target = PersistedMultiRootBranchRenameRollbackTarget(
            rootPath: "/project/app",
            displayName: "app",
            oldName: "feature",
            newName: "feature-renamed",
            expectedNewTip: "2222222",
            expectedCurrentBranch: "main",
            expectedUpstream: nil,
            upstream: "origin/feature"
        )
        let request = ArborVCSActionRequest(
            kind: .rollbackMultiRootBranchRename,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootBranchRenameOldName: "feature",
            multiRootBranchRenameNewName: "feature-renamed",
            multiRootBranchRenameRollbackTargets: [target]
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(
            decoded.multiRootBranchRenameRollbackTargets?.first?.expectedNewTip,
            "2222222"
        )
        XCTAssertEqual(
            decoded.multiRootBranchRenameRollbackTargets?.first?.expectedCurrentBranch,
            "main"
        )

        let suiteName = "Arbor.FeedbackCenterMultiRootBranchRenameRollbackTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Multi-root branch rename partially completed",
            additionalActions: [
                FeedbackAction(
                    title: "Rollback Successful Roots",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testBranchDeleteRestoreActionRoundTripsAndSurvivesReload() throws {
        let commit = PersistedBranchDeleteCommit(
            id: "2222222",
            shortID: "2222222",
            summary: "unmerged work",
            time: 1_700_000_000
        )
        let target = PersistedBranchDeleteRecoveryTarget(
            rootPath: "/project/app",
            branchName: "feature",
            tipID: "1111111",
            upstream: "origin/feature",
            baseBranches: ["main"],
            unmergedCommits: [commit]
        )
        let request = ArborVCSActionRequest(
            kind: .restoreDeletedBranches,
            projectPath: "/project",
            rootPath: "/project/app",
            shelfName: "",
            branchDeleteRecoveryTargets: [target]
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.branchDeleteRecoveryTargets?.first?.tipID, "1111111")
        XCTAssertEqual(decoded.branchDeleteRecoveryTargets?.first?.upstream, "origin/feature")
        XCTAssertEqual(decoded.branchDeleteRecoveryTargets?.first?.baseBranches, ["main"])
        XCTAssertEqual(decoded.branchDeleteRecoveryTargets?.first?.unmergedCommits, [commit])

        let suiteName = "Arbor.FeedbackCenterBranchDeleteRestoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.success(
            "Branch deleted",
            additionalActions: [
                FeedbackAction(
                    title: "Restore",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testBranchDeleteViewCommitsActionRoundTripsAndSurvivesReload() throws {
        let target = PersistedBranchDeleteRecoveryTarget(
            rootPath: "/project/app",
            branchName: "feature",
            tipID: "1111111",
            upstream: nil,
            baseBranches: ["main"],
            unmergedCommits: [
                PersistedBranchDeleteCommit(
                    id: "2222222",
                    shortID: "2222222",
                    summary: "unmerged work",
                    time: 1_700_000_000
                )
            ]
        )
        let request = ArborVCSActionRequest(
            kind: .viewDeletedBranchCommits,
            projectPath: "/project",
            rootPath: "/project/app",
            shelfName: "",
            branchDeleteRecoveryTargets: [target]
        )
        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)

        let suiteName = "Arbor.FeedbackCenterBranchDeleteViewCommitsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.success(
            "Branch deleted",
            additionalActions: [
                FeedbackAction(
                    title: "View Commits",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    func testMultiRootCheckoutUpdateRetryActionRoundTripsCheckoutContext() throws {
        let request = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            checkoutReference: "origin/feature",
            multiRootRetryOperation: .checkoutUpdate,
            multiRootRetryRootPaths: ["/project/app"],
            multiRootRetryRebase: true,
            multiRootRetryDetach: false,
            multiRootRetryCheckoutMode: .smart
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.checkoutReference, "origin/feature")
        XCTAssertEqual(decoded.multiRootRetryOperation, .checkoutUpdate)
        XCTAssertEqual(decoded.multiRootRetryRootPaths, ["/project/app"])
        XCTAssertEqual(decoded.multiRootRetryRebase, true)
        XCTAssertEqual(decoded.multiRootRetryDetach, false)
        XCTAssertEqual(decoded.multiRootRetryCheckoutMode, .smart)
    }
}
