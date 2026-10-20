import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {

    @MainActor
    func testFeedbackBeginReusesStableNotificationHistoryEntryForRetry() {
        let suiteName = "Arbor.FeedbackCenterStableRetryHistoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notificationID = "arbor.multi-root-retry.fetch./project"

        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Fetch All partially completed",
            notificationID: notificationID,
            localized: false
        )
        feedbackCenter.begin("Retry Fetch All", notificationID: notificationID)
        feedbackCenter.success(
            "Fetch All completed",
            detail: "1 ok",
            notificationID: notificationID,
            localized: false
        )

        XCTAssertEqual(feedbackCenter.history.count, 1)
        XCTAssertEqual(feedbackCenter.history.first?.title, "Fetch All completed")
        XCTAssertEqual(feedbackCenter.history.first?.notificationID, notificationID)
    }

    @MainActor
    func testCompoundRetryNotificationIDsAvoidWorkingHistoryRows() {
        let suiteName = "Arbor.FeedbackCenterCompoundRetryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let updatePartialID = "git.project.partially.updated._project"
        let updateCompletedID = "git.project.updated._project"
        let checkoutID = "arbor.multi-root-retry.checkoutUpdate._project"
        let feedbackCenter = FeedbackCenter(defaults: defaults)

        feedbackCenter.warning(
            "Update Project partially completed",
            notificationID: updatePartialID,
            localized: false
        )
        feedbackCenter.begin("Retry Update Project", notificationID: updateCompletedID)
        feedbackCenter.success(
            "Update Project completed",
            notificationID: updateCompletedID,
            localized: false
        )
        XCTAssertEqual(feedbackCenter.history.first?.title, "Update Project completed")
        XCTAssertFalse(feedbackCenter.history.contains { $0.title == "Working…" })

        feedbackCenter.warning(
            "Checkout and Update partially completed",
            notificationID: checkoutID,
            localized: false
        )
        feedbackCenter.begin("Retry Checkout and Update", notificationID: checkoutID)
        feedbackCenter.success(
            "Checkout and Update completed",
            notificationID: checkoutID,
            localized: false
        )
        XCTAssertEqual(feedbackCenter.history.first?.title, "Checkout and Update completed")
        XCTAssertFalse(feedbackCenter.history.contains { $0.title == "Working…" })

        let rollbackID = "arbor.multi-root-checkout.rollback._project"
        feedbackCenter.warning(
            "Checkout rollback partially failed",
            additionalActions: [FeedbackAction(title: "Retry Checkout Rollback") {}],
            notificationID: rollbackID,
            localized: false
        )
        feedbackCenter.begin("Rollback multi-root checkout", notificationID: rollbackID)
        feedbackCenter.success(
            "Checkout rollback completed",
            notificationID: rollbackID,
            localized: false
        )
        XCTAssertEqual(feedbackCenter.history.first?.title, "Checkout rollback completed")
        XCTAssertEqual(feedbackCenter.history.first?.notificationID, rollbackID)
        XCTAssertFalse(feedbackCenter.history.contains { $0.title == "Working…" })
    }

    @MainActor
    func testFeedbackWarningPreservesAndInvokesNotificationAction() {
        let feedbackCenter = FeedbackCenter()
        var invoked = false

        feedbackCenter.warning(
            "Update Project partially completed",
            actionTitle: "Resolve Conflicts",
            action: { invoked = true }
        )

        XCTAssertEqual(feedbackCenter.current?.actionTitle, "Resolve Conflicts")
        feedbackCenter.current?.action?()
        XCTAssertTrue(invoked)
    }

    @MainActor
    func testFeedbackWarningSupportsMultipleNotificationActions() {
        let feedbackCenter = FeedbackCenter()
        var selectedAction = ""

        feedbackCenter.warning(
            "Push rejected",
            actionTitle: "Update with Merge",
            action: { selectedAction = "merge" },
            additionalActions: [
                FeedbackAction(title: "Update with Rebase") { selectedAction = "rebase" },
                FeedbackAction(title: "Retry Push") { selectedAction = "retry" }
            ],
            localized: false
        )

        XCTAssertEqual(feedbackCenter.current?.actions.map(\.title), [
            "Update with Merge",
            "Update with Rebase",
            "Retry Push"
        ])
        feedbackCenter.current?.actions[2].action()
        XCTAssertEqual(selectedAction, "retry")
    }

    func testStalePushRejectionKeepsStructuredLeaseGuidance() {
        let stale = EngineError.PushRejected(
            kind: .staleInfo,
            remote: "origin",
            branch: "main",
            message: "remote rejected: stale info"
        )
        let nonFastForward = EngineError.PushRejected(
            kind: .nonFastForward,
            remote: "origin",
            branch: "main",
            message: "remote rejected: non-fast-forward"
        )

        XCTAssertEqual(stalePushRejectionDetails(stale)?.remote, "origin")
        XCTAssertEqual(stalePushRejectionDetails(stale)?.branch, "main")
        XCTAssertEqual(stalePushRejectionDetails(stale)?.message, "remote rejected: stale info")
        XCTAssertNil(stalePushRejectionDetails(nonFastForward))
    }

    @MainActor
    func testFeedbackNotificationIDUpdatesOneGroupedHistoryEntry() {
        let suiteName = "Arbor.FeedbackGroupingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feedbackCenter = FeedbackCenter(defaults: defaults)

        feedbackCenter.warning(
            "Incoming changes available",
            detail: "root-a · origin/main",
            notificationID: "git.fetch.project.incoming",
            localized: false
        )
        feedbackCenter.warning(
            "Incoming changes available",
            detail: "root-a · origin/main\nroot-b · upstream/dev",
            notificationID: "git.fetch.project.incoming",
            localized: false
        )

        XCTAssertEqual(feedbackCenter.history.count, 1)
        XCTAssertEqual(
            feedbackCenter.history.first?.detail,
            "root-a · origin/main\nroot-b · upstream/dev"
        )
    }

    func testFeedbackResultRowsPreserveExecutionOrderAndState() {
        let rows = feedbackResultRows(from: [
            RootOperationResult(
                rootPath: "/workspace/app",
                displayName: "App",
                success: true,
                skipped: false,
                message: "updated 2 commits"
            ),
            RootOperationResult(
                rootPath: "/workspace/docs",
                displayName: "Docs",
                success: true,
                skipped: true,
                message: "detached HEAD"
            ),
            RootOperationResult(
                rootPath: "/workspace/tools",
                displayName: "Tools",
                success: false,
                skipped: false,
                message: "authentication failed"
            )
        ])

        XCTAssertEqual(rows.map(\.rootPath), [
            "/workspace/app", "/workspace/docs", "/workspace/tools"
        ])
        XCTAssertEqual(rows.map(\.state), [.success, .skipped, .failed])
        XCTAssertEqual(rows.map(\.detail), [
            "updated 2 commits", "detached HEAD", "authentication failed"
        ])
    }

    func testFeedbackResultRowsMarkPausedRootsAsPartialUsingCanonicalPaths() {
        let rows = feedbackResultRows(
            from: [
                RootOperationResult(
                    rootPath: "/workspace/app/../app",
                    displayName: "App",
                    success: true,
                    skipped: false,
                    message: "conflicts need resolution"
                ),
                RootOperationResult(
                    rootPath: "/workspace/docs",
                    displayName: "Docs",
                    success: true,
                    skipped: false,
                    message: "rebase completed"
                )
            ],
            partialRootPaths: ["/workspace/app"]
        )

        XCTAssertEqual(rows.map(\.state), [.partial, .success])
    }

    @MainActor
    func testFeedbackResultRowsPersistAcrossOperationLogReload() {
        let suiteName = "Arbor.FeedbackResultRowsReloadTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let notificationID = "git.fetch.project"
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Fetch All partially completed",
            detail: "1 ok · 1 failed",
            notificationID: notificationID,
            localized: false
        )
        feedbackCenter.attachResultRows(
            [
                FeedbackResultRow(
                    rootPath: "/workspace/app",
                    displayName: "App",
                    state: .success,
                    detail: "updated refs"
                ),
                FeedbackResultRow(
                    rootPath: "/workspace/docs",
                    displayName: "Docs",
                    state: .failed,
                    detail: "remote unavailable"
                )
            ],
            notificationID: notificationID
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.resultRows.map(\.displayName), ["App", "Docs"])
        XCTAssertEqual(reloaded.history.first?.resultRows.map(\.state), [.success, .failed])
        XCTAssertEqual(reloaded.history.first?.resultRows[1].rootPath, "/workspace/docs")
    }

    @MainActor
    func testFeedbackNotificationIDRebuildsDisplayIndexAfterReload() {
        let suiteName = "Arbor.FeedbackGroupingReloadTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let notificationID = "arbor.update.project"
        let first = FeedbackCenter(defaults: defaults)
        first.warning(
            "Update Project partially completed",
            detail: "root-a failed",
            notificationID: notificationID,
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        reloaded.warning(
            "Update Project completed",
            detail: "root-a and root-b updated",
            notificationID: notificationID,
            localized: false
        )

        XCTAssertEqual(reloaded.history.count, 1)
        XCTAssertEqual(reloaded.history.first?.title, "Update Project completed")
        XCTAssertEqual(reloaded.history.first?.detail, "root-a and root-b updated")
        XCTAssertEqual(reloaded.history.first?.notificationID, notificationID)
    }

    @MainActor
    func testFeedbackExpirationRemovesDisplayIndexButKeepsHistory() {
        let suiteName = "Arbor.FeedbackExpirationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let notificationID = "arbor.branch.recovery"
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Branch restored",
            additionalActions: [FeedbackAction(title: "Retry") {}],
            notificationID: notificationID,
            localized: false
        )
        feedbackCenter.expire(notificationID: notificationID)

        XCTAssertEqual(feedbackCenter.history.count, 1)
        XCTAssertNil(feedbackCenter.history.first?.notificationID)
        XCTAssertTrue(feedbackCenter.history.first?.actions.isEmpty == true)
        XCTAssertTrue(feedbackCenter.history.first?.actionTitles.isEmpty == true)

        let reloadedExpired = FeedbackCenter(defaults: defaults)
        XCTAssertTrue(reloadedExpired.history.first?.actions.isEmpty == true)
        XCTAssertTrue(reloadedExpired.history.first?.actionTitles.isEmpty == true)

        let reloaded = FeedbackCenter(defaults: defaults)
        reloaded.warning(
            "Another branch restored",
            notificationID: notificationID,
            localized: false
        )

        XCTAssertEqual(reloaded.history.count, 2)
        XCTAssertEqual(reloaded.history.first?.title, "Another branch restored")
    }

    @MainActor
    func testFeedbackHistoryRetainsNotificationActions() {
        let feedbackCenter = FeedbackCenter()
        var invoked = false

        feedbackCenter.warning(
            "Push rejected",
            actionTitle: "Retry Push",
            action: { invoked = true },
            localized: false
        )

        XCTAssertEqual(feedbackCenter.history.first?.actions.map(\.title), ["Retry Push"])
        feedbackCenter.history.first?.actions.first?.action()
        XCTAssertTrue(invoked)
    }

    @MainActor
    func testFeedbackCenterTracksBatchProgressUntilOperationFinishes() {
        let feedbackCenter = FeedbackCenter()
        feedbackCenter.begin("Unshelve shelves silently")
        XCTAssertTrue(feedbackCenter.history.first?.isRunning == true)
        feedbackCenter.updateBatchProgress(
            completed: 1,
            total: 4,
            phase: "Unshelve Shelf",
            detail: "WIP: one"
        )

        XCTAssertEqual(feedbackCenter.batchProgress?.completed, 1)
        XCTAssertEqual(feedbackCenter.batchProgress?.total, 4)
        XCTAssertEqual(feedbackCenter.batchProgress?.percentage, 25)
        XCTAssertEqual(feedbackCenter.batchProgress?.detail, "WIP: one")

        feedbackCenter.success("Shelves unshelved silently", localized: false)
        XCTAssertNil(feedbackCenter.batchProgress)
        XCTAssertFalse(feedbackCenter.history.first?.isRunning == true)
    }

    @MainActor
    func testFeedbackHistoryPersistsSafeSummaryAcrossCenterReload() {
        let suiteName = "Arbor.FeedbackCenterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Push rejected",
            detail: "origin/main rejected the update",
            actionTitle: "Retry Push",
            action: {},
            additionalActions: [FeedbackAction(title: "Open Git Roots") {}],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.count, 1)
        XCTAssertEqual(reloaded.history.first?.title, "Push rejected")
        XCTAssertEqual(reloaded.history.first?.detail, "origin/main rejected the update")
        XCTAssertEqual(reloaded.history.first?.actionTitles, ["Retry Push", "Open Git Roots"])
        XCTAssertTrue(reloaded.history.first?.actions.isEmpty == true)
        XCTAssertNil(reloaded.history.first?.command)
        XCTAssertNil(reloaded.history.first?.stdout)
        XCTAssertNil(reloaded.history.first?.stderr)
    }

    @MainActor
    func testFeedbackHistoryRestoresSemanticSubsetFromMixedActions() {
        let suiteName = "Arbor.FeedbackCenterMixedActionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .showLogRanges,
            projectPath: "/project",
            rootPath: "/project/app",
            shelfName: "",
            logRevisionRanges: [
                PersistedLogRevisionRange(
                    rootPath: "/project/app",
                    oldRevision: "1111111",
                    newRevision: "2222222"
                )
            ]
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Update partially completed",
            actionTitle: "Resolve Conflicts",
            action: {},
            additionalActions: [
                FeedbackAction(title: "View Commits", semanticAction: request) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actionTitles, ["Resolve Conflicts", "View Commits"])
        XCTAssertEqual(reloaded.history.first?.actions.map(\.title), ["View Commits"])
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }
}
