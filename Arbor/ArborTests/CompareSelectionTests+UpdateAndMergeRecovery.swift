import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {

    func testMultiRootMergeChecksMergedBranchesPerRepository() {
        let mergedByRoot = [
            "/workspace/app": Set(["feature/done"]),
            "/workspace/tools": Set(["release/old"])
        ]

        XCTAssertTrue(
            mergeBranchIsAlreadyMerged(
                "feature/done",
                mergedBranches: mergedByRoot["/workspace/app"]!
            )
        )
        XCTAssertFalse(
            mergeBranchIsAlreadyMerged(
                "feature/done",
                mergedBranches: mergedByRoot["/workspace/tools"]!
            )
        )
    }

    func testResetSelectionAllowsOneRevisionPerRootOnly() {
        let first = CommitInfo(
            id: "a",
            repositoryPath: "/workspace/one",
            shortId: "a",
            summary: "one",
            authorName: "A",
            authorEmail: "a@example.com",
            committerName: "A",
            committerEmail: "a@example.com",
            messageBody: "",
            hasSignature: false,
            time: 0,
            parentIds: [],
            refs: [],
            tagRefs: [],
            remoteRefs: [],
            isHead: false,
            lane: 0,
            parentLanes: []
        )
        var sameRoot = first
        sameRoot.id = "b"
        var otherRoot = first
        otherRoot.id = "c"
        otherRoot.repositoryPath = "/workspace/two"

        XCTAssertTrue(isResetSelectionAvailable(for: [first]))
        XCTAssertFalse(isResetSelectionAvailable(for: [first, sameRoot]))
        XCTAssertTrue(isResetSelectionAvailable(for: [first, otherRoot]))
    }

    func testMultiRootResetRetryReplacesOnlyRetriedRootResults() {
        let initial = [
            RootOperationResult(
                rootPath: "/workspace/app",
                displayName: "app",
                success: true,
                skipped: false,
                message: "reset to aaaaaaa"
            ),
            RootOperationResult(
                rootPath: "/workspace/docs",
                displayName: "docs",
                success: false,
                skipped: false,
                message: "local changes would be overwritten"
            ),
            RootOperationResult(
                rootPath: "/workspace/tools",
                displayName: "tools",
                success: false,
                skipped: false,
                message: "repository unavailable"
            )
        ]
        let retry = [
            RootOperationResult(
                rootPath: "/workspace/docs",
                displayName: "docs",
                success: true,
                skipped: false,
                message: "reset to aaaaaaa"
            )
        ]

        let merged = mergeRootOperationResults(
            preserved: initial.filter { $0.rootPath != "/workspace/docs" },
            retry: retry,
            rootOrder: ["/workspace/app", "/workspace/docs", "/workspace/tools"]
        )

        XCTAssertEqual(merged.map(\.rootPath), [
            "/workspace/app", "/workspace/docs", "/workspace/tools"
        ])
        XCTAssertTrue(merged[1].success)
        XCTAssertEqual(merged[2].message, "repository unavailable")
    }

    func testMultiRootMergeSmartRetryKeepsNonBlockedResultsAndRollbackMetadata() {
        func result(
            rootPath: String,
            displayName: String,
            success: Bool,
            skipped: Bool = false,
            message: String,
            initialHead: String?,
            finalHead: String?,
            requiresFinish: Bool = false,
            conflicts: [String] = [],
            overwritePaths: [String] = []
        ) -> MultiRootMergeResult {
            MultiRootMergeResult(
                rootPath: rootPath,
                displayName: displayName,
                success: success,
                skipped: skipped,
                message: message,
                initialHead: initialHead,
                finalHead: finalHead,
                completed: success && !requiresFinish,
                requiresFinish: requiresFinish,
                conflicts: conflicts,
                localChangesOverwritePaths: overwritePaths
            )
        }

        let initial = [
            result(
                rootPath: "/workspace/app",
                displayName: "app",
                success: true,
                message: "merge completed",
                initialHead: "a",
                finalHead: "b"
            ),
            result(
                rootPath: "/workspace/docs",
                displayName: "docs",
                success: false,
                message: "local changes would be overwritten",
                initialHead: "c",
                finalHead: "c",
                overwritePaths: ["README.md"]
            ),
            result(
                rootPath: "/workspace/tools",
                displayName: "tools",
                success: true,
                message: "merge paused with 1 conflict(s)",
                initialHead: "d",
                finalHead: "d",
                requiresFinish: true,
                conflicts: ["tool.swift"]
            )
        ]
        let retry = [
            result(
                rootPath: "/workspace/docs",
                displayName: "docs",
                success: true,
                message: "merge completed",
                initialHead: "c",
                finalHead: "e"
            )
        ]

        let merged = mergeMultiRootMergeResults(
            preserved: initial.filter { $0.rootPath != "/workspace/docs" },
            retry: retry,
            rootOrder: ["/workspace/app", "/workspace/docs", "/workspace/tools"]
        )

        XCTAssertEqual(merged.map(\.rootPath), [
            "/workspace/app", "/workspace/docs", "/workspace/tools"
        ])
        XCTAssertEqual(merged[0].initialHead, "a")
        XCTAssertEqual(merged[0].finalHead, "b")
        XCTAssertTrue(merged[1].success)
        XCTAssertEqual(merged[1].finalHead, "e")
        XCTAssertTrue(merged[2].requiresFinish)
        XCTAssertEqual(merged[2].conflicts, ["tool.swift"])
    }

    func testCompletedMergeRevisionRangesExcludePendingFailedSkippedAndUnchangedRoots() {
        let results = [
            MultiRootMergeResult(
                rootPath: "/workspace/app",
                displayName: "app",
                success: true,
                skipped: false,
                message: "merge completed",
                initialHead: "1111111",
                finalHead: "2222222",
                completed: true,
                requiresFinish: false,
                conflicts: [],
                localChangesOverwritePaths: []
            ),
            MultiRootMergeResult(
                rootPath: "/workspace/docs",
                displayName: "docs",
                success: true,
                skipped: false,
                message: "already up to date",
                initialHead: "3333333",
                finalHead: "3333333",
                completed: true,
                requiresFinish: false,
                conflicts: [],
                localChangesOverwritePaths: []
            ),
            MultiRootMergeResult(
                rootPath: "/workspace/tools",
                displayName: "tools",
                success: true,
                skipped: false,
                message: "merge applied; explicit finish required",
                initialHead: "4444444",
                finalHead: "5555555",
                completed: false,
                requiresFinish: true,
                conflicts: [],
                localChangesOverwritePaths: []
            ),
            MultiRootMergeResult(
                rootPath: "/workspace/web",
                displayName: "web",
                success: false,
                skipped: false,
                message: "merge failed",
                initialHead: "6666666",
                finalHead: "7777777",
                completed: false,
                requiresFinish: false,
                conflicts: [],
                localChangesOverwritePaths: []
            ),
            MultiRootMergeResult(
                rootPath: "/workspace/worker",
                displayName: "worker",
                success: true,
                skipped: true,
                message: "not attempted",
                initialHead: "8888888",
                finalHead: "9999999",
                completed: false,
                requiresFinish: false,
                conflicts: [],
                localChangesOverwritePaths: []
            )
        ]

        let ranges = ContentView.completedMergeRevisionRanges(results)

        XCTAssertEqual(ranges, [
            PersistedLogRevisionRange(
                rootPath: "/workspace/app",
                oldRevision: "1111111",
                newRevision: "2222222"
            )
        ])
    }

    @MainActor
    func testMultiRootUpdateRollbackActionRoundTripsAndSurvivesReload() throws {
        let request = ArborVCSActionRequest(
            kind: .rollbackMultiRootUpdate,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootUpdateRollbackTargets: [
                PersistedMultiRootUpdateRollbackTarget(
                    rootPath: "/project/vendor/lib",
                    displayName: "lib",
                    initialHead: "1111111",
                    expectedHead: "2222222"
                )
            ]
        )
        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.multiRootUpdateRollbackTargets?.first?.expectedHead, "2222222")

        let suiteName = "Arbor.FeedbackCenterMultiRootUpdateRollbackTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Update Project partially completed",
            additionalActions: [
                FeedbackAction(
                    title: "Rollback Updated Roots",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testMultiRootSoftResetRollbackActionRoundTripsAndSurvivesReload() throws {
        let target = PersistedMultiRootResetRollbackTarget(
            rootPath: "/project/app",
            displayName: "app",
            initialHead: "1111111",
            expectedHead: "2222222",
            expectedHeadBranch: "main"
        )
        let request = ArborVCSActionRequest(
            kind: .rollbackMultiRootReset,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootResetRollbackTargets: [target]
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(
            decoded.multiRootResetRollbackTargets?.first?.makeLiveTarget().expectedHead,
            "2222222"
        )
        XCTAssertEqual(
            decoded.multiRootResetRollbackTargets?.first?.expectedHeadBranch,
            "main"
        )

        let suiteName = "Arbor.FeedbackCenterMultiRootSoftResetRollbackTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.success(
            "Multi-root soft reset completed",
            additionalActions: [
                FeedbackAction(
                    title: "Rollback Soft Reset",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testResetRecoveryUndoAndKeepActionsRoundTripAndSurviveReload() throws {
        let target = PersistedResetRecoveryTarget(
            rootPath: "/project/app",
            displayName: "app",
            initialHead: "1111111",
            expectedHead: "2222222",
            expectedHeadBranch: "main",
            mode: .hard,
            rollbackID: "reset-undo-1"
        )
        let undoRequest = ArborVCSActionRequest(
            kind: .rollbackResetRecovery,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            resetRecoveryTargets: [target]
        )
        let keepRequest = ArborVCSActionRequest(
            kind: .keepResetRecovery,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            resetRecoveryTargets: [target]
        )

        let decodedUndo = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(undoRequest)
        )
        let decodedKeep = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(keepRequest)
        )
        XCTAssertEqual(decodedUndo, undoRequest)
        XCTAssertEqual(decodedKeep, keepRequest)
        XCTAssertEqual(decodedUndo.resetRecoveryTargets?.first?.makeLiveTarget().mode, .hard)
        XCTAssertEqual(decodedUndo.resetRecoveryTargets?.first?.rollbackID, "reset-undo-1")

        let suiteName = "Arbor.FeedbackCenterResetRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Reset completed",
            additionalActions: [
                FeedbackAction(title: "Undo Reset", semanticAction: undoRequest) {},
                FeedbackAction(title: "Keep Reset Result", semanticAction: keepRequest) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.map(\.semanticAction), [undoRequest, keepRequest])
    }

    @MainActor
    func testMultiRootMergeRollbackActionRoundTripsAndSurvivesReload() throws {
        let target = PersistedMultiRootMergeRollbackTarget(
            MultiRootMergeRollbackTarget(
                rootPath: "/project/app",
                displayName: "app",
                initialHead: "1111111",
                expectedHead: "2222222",
                operationPending: true
            )
        )
        let request = ArborVCSActionRequest(
            kind: .rollbackMultiRootMerge,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootMergeBranchName: "feature",
            multiRootMergeRollbackTargets: [target],
            multiRootMergeRollbackResultRows: [
                FeedbackResultRow(
                    rootPath: "/project/docs",
                    displayName: "docs",
                    state: .success,
                    detail: "Restored the original HEAD"
                )
            ]
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.multiRootMergeBranchName, "feature")
        XCTAssertEqual(decoded.multiRootMergeRollbackTargets?.first?.makeLiveTarget().expectedHead, "2222222")
        XCTAssertTrue(decoded.multiRootMergeRollbackTargets?.first?.operationPending == true)
        XCTAssertEqual(decoded.multiRootMergeRollbackResultRows?.first?.rootPath, "/project/docs")

        let suiteName = "Arbor.FeedbackCenterMultiRootMergeRollbackTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Multi-root merge partially completed",
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
    func testMultiRootMergeDeleteActionRoundTripsAndSurvivesReload() throws {
        let request = ArborVCSActionRequest(
            kind: .deleteMultiRootMergeBranch,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootMergeDeleteBranchName: "feature",
            multiRootMergeDeleteRootPaths: ["/project/docs", "/project/app"]
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.multiRootMergeDeleteBranchName, "feature")
        XCTAssertEqual(decoded.multiRootMergeDeleteRootPaths, ["/project/docs", "/project/app"])

        let suiteName = "Arbor.FeedbackCenterMultiRootMergeDeleteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.success(
            "Multi-root merge completed",
            additionalActions: [
                FeedbackAction(
                    title: "Delete branch",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testMultiRootMergeDeleteNotificationExpiresAfterAction() {
        let request = ArborVCSActionRequest(
            kind: .deleteMultiRootMergeBranch,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootMergeDeleteBranchName: "feature",
            multiRootMergeDeleteRootPaths: ["/project/app"]
        )
        let suiteName = "Arbor.FeedbackCenterMultiRootMergeDeleteExpiryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.success(
            "Multi-root merge completed",
            additionalActions: [
                FeedbackAction(title: "Delete branch", semanticAction: request) {}
            ],
            notificationID: "arbor.multi-root-merge.delete._project",
            localized: false
        )
        XCTAssertEqual(feedbackCenter.history.first?.actions.count, 1)

        feedbackCenter.expire(notificationID: "arbor.multi-root-merge.delete._project")

        XCTAssertTrue(feedbackCenter.history.first?.actions.isEmpty == true)
        XCTAssertNil(feedbackCenter.history.first?.notificationID)
    }

    @MainActor
    func testMultiRootMergeRollbackResultRowsPersistAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterMultiRootMergeRollbackRowsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let feedbackCenter = FeedbackCenter(defaults: defaults)
        let notificationID = "arbor.multi-root-merge.rollback._project"
        feedbackCenter.warning(
            "Multi-root merge rollback partially failed",
            detail: "Docs: HEAD changed after the merge",
            notificationID: notificationID,
            localized: false
        )
        let rows = [
            FeedbackResultRow(
                rootPath: "/project/app",
                displayName: "App",
                state: .success,
                detail: "Restored the original HEAD"
            ),
            FeedbackResultRow(
                rootPath: "/project/docs",
                displayName: "Docs",
                state: .failed,
                detail: "HEAD changed after the merge; rollback was skipped."
            )
        ]
        let retriedRows = [
            FeedbackResultRow(
                rootPath: "/project/docs",
                displayName: "Docs",
                state: .success,
                detail: "Restored the original HEAD"
            )
        ]
        let cumulativeRows = mergeFeedbackResultRows(
            preserved: rows,
            retry: retriedRows
        )
        XCTAssertEqual(cumulativeRows, [rows[0], retriedRows[0]])
        feedbackCenter.attachResultRows(cumulativeRows, notificationID: notificationID)

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.resultRows, cumulativeRows)
    }

    func testGitRootsPullAllUsesPreservingUpdateRoute() {
        XCTAssertEqual(multiRootPullRebaseMode(.pullMerge), false)
        XCTAssertEqual(multiRootPullRebaseMode(.pullRebase), true)
        XCTAssertNil(multiRootPullRebaseMode(.fetch))
        XCTAssertNil(multiRootPullRebaseMode(.push))
        XCTAssertNil(multiRootPullRebaseMode(.commit))
    }

    func testMultiRootUpdateCancellationRemainsVisibleInPartialDetails() {
        let results = [
            RootOperationResult(
                rootPath: "/workspace/project",
                displayName: "project",
                success: true,
                skipped: true,
                message: "cancelled before update"
            )
        ]

        XCTAssertEqual(
            ContentView.multiRootUpdateFailureDetails(
                results,
                submoduleRootPaths: []
            ),
            ["project (cancelled before update)"]
        )
    }

    func testMultiRootUpdateRollbackTargetsIncludeOnlyAdvancedSuccessfulRoots() {
        let results = [
            RootOperationResult(
                rootPath: "/workspace/project",
                displayName: "project",
                success: true,
                skipped: false,
                message: "updated"
            ),
            RootOperationResult(
                rootPath: "/workspace/project/vendor/lib",
                displayName: "lib",
                success: true,
                skipped: false,
                message: "updated detached submodule"
            ),
            RootOperationResult(
                rootPath: "/workspace/failed",
                displayName: "failed",
                success: false,
                skipped: false,
                message: "remote unavailable"
            ),
            RootOperationResult(
                rootPath: "/workspace/skipped",
                displayName: "skipped",
                success: true,
                skipped: true,
                message: "no upstream"
            )
        ]
        let targets = ContentView.updateSessionRollbackTargets(
            previousHeads: [
                "/workspace/project": "p-old",
                "/workspace/project/vendor/lib": "c-old",
                "/workspace/failed": "f-old",
                "/workspace/skipped": "s-old"
            ],
            currentHeads: [
                "/workspace/project": "p-new",
                "/workspace/project/vendor/lib": "c-new",
                "/workspace/failed": "f-new",
                "/workspace/skipped": "s-new"
            ],
            results: results,
            submoduleRootPaths: ["/workspace/project/vendor/lib"],
            previousHeadBranches: [
                "/workspace/project": "main",
                "/workspace/project/vendor/lib": ""
            ]
        )

        XCTAssertEqual(
            targets.map(\.rootPath),
            ["/workspace/project/vendor/lib", "/workspace/project"]
        )
        XCTAssertEqual(targets.map(\.initialHead), ["c-old", "p-old"])
        XCTAssertEqual(targets.map(\.expectedHead), ["c-new", "p-new"])
        XCTAssertEqual(targets.map { $0.expectedHeadBranch ?? "<missing>" }, ["", "main"])
        XCTAssertEqual(targets.map(\.ignoredPaths), [[], ["vendor/lib"]])
    }

    func testUpdateSessionLogRangeActionRoundTripsRootQualifiedRanges() throws {
        let request = ArborVCSActionRequest(
            kind: .showLogRanges,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            logRevisionRanges: [
                PersistedLogRevisionRange(
                    rootPath: "/project/app",
                    oldRevision: "1111111",
                    newRevision: "2222222"
                ),
                PersistedLogRevisionRange(
                    rootPath: "/project/docs",
                    oldRevision: "3333333",
                    newRevision: "4444444"
                )
            ]
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.logRevisionRanges?.map(\.rootPath), ["/project/app", "/project/docs"])
        XCTAssertEqual(decoded.logRevisionRanges?.last?.oldRevision, "3333333")
    }

    @MainActor
    func testFeedbackHistoryRestoresUpdateSessionLogRangeActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterUpdateSessionLogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .showLogRanges,
            projectPath: "/project",
            rootPath: nil,
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
        feedbackCenter.success(
            "Update completed",
            additionalActions: [
                FeedbackAction(title: "View Commits", semanticAction: request) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(
            reloaded.history.first?.actions.first?.semanticAction,
            request
        )
    }
}
