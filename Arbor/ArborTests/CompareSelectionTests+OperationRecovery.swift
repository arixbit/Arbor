import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {

    func testMultiRootRetryActionRequestRoundTripsOperationAndRootScopes() throws {
        let request = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRetryOperation: .pushRecovery,
            multiRootRetryRootPaths: ["/project/app"],
            multiRootRetryUpdateRootPaths: ["/project/app", "/project/docs"],
            multiRootRetryRebase: true,
            multiRootRetryRebaseRootPaths: ["/project/app"],
            multiRootRetryLogRevisionRanges: [
                PersistedLogRevisionRange(
                    rootPath: "/project/app",
                    oldRevision: "old-app",
                    newRevision: "new-app"
                )
            ],
            multiRootRetryResultRows: [
                FeedbackResultRow(
                    rootPath: "/project/app",
                    displayName: "App",
                    state: .success,
                    detail: "pushed App"
                ),
                FeedbackResultRow(
                    rootPath: "/project/docs",
                    displayName: "Docs",
                    state: .failed,
                    detail: "push rejected"
                )
            ]
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.multiRootRetryOperation, .pushRecovery)
        XCTAssertEqual(decoded.multiRootRetryRootPaths, ["/project/app"])
        XCTAssertEqual(decoded.multiRootRetryUpdateRootPaths, ["/project/app", "/project/docs"])
        XCTAssertEqual(decoded.multiRootRetryRebase, true)
        XCTAssertEqual(decoded.multiRootRetryRebaseRootPaths, ["/project/app"])
        XCTAssertEqual(
            decoded.multiRootRetryLogRevisionRanges,
            [
                PersistedLogRevisionRange(
                    rootPath: "/project/app",
                    oldRevision: "old-app",
                    newRevision: "new-app"
                )
            ]
        )
        XCTAssertEqual(
            decoded.multiRootRetryResultRows,
            [
                FeedbackResultRow(
                    rootPath: "/project/app",
                    displayName: "App",
                    state: .success,
                    detail: "pushed App"
                ),
                FeedbackResultRow(
                    rootPath: "/project/docs",
                    displayName: "Docs",
                    state: .failed,
                    detail: "push rejected"
                )
            ]
        )
    }

    func testMultiRootGenericRetryOperationsRoundTrip() throws {
        for operation in [
            ArborVCSActionRequest.MultiRootRetryOperation.fetch,
            .pullMerge,
            .pullRebase
        ] {
            let request = ArborVCSActionRequest(
                kind: .retryMultiRootOperation,
                projectPath: "/project",
                rootPath: nil,
                shelfName: "",
                multiRootRetryOperation: operation,
                multiRootRetryRootPaths: ["/project/app"]
            )
            let decoded = try JSONDecoder().decode(
                ArborVCSActionRequest.self,
                from: JSONEncoder().encode(request)
            )
            XCTAssertEqual(decoded, request)
            XCTAssertEqual(decoded.multiRootRetryOperation, operation)
            XCTAssertEqual(decoded.multiRootRetryRootPaths, ["/project/app"])
        }
    }

    @MainActor
    func testFeedbackHistoryRestoresMultiRootRetryActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterMultiRootRetryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRetryOperation: .update,
            multiRootRetryRootPaths: ["/project/app"],
            multiRootRetryRebase: false
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Update partially completed",
            additionalActions: [
                FeedbackAction(
                    title: "Retry Failed Update Roots",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testFeedbackHistoryRestoresAggregatePullRetryWithPriorRanges() {
        let suiteName = "Arbor.FeedbackCenterAggregatePullRetryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRetryOperation: .pullMerge,
            multiRootRetryRootPaths: ["/project/app", "/project/lib"],
            multiRootRetryLogRevisionRanges: [
                PersistedLogRevisionRange(
                    rootPath: "/project/app",
                    oldRevision: "old-app",
                    newRevision: "new-app"
                )
            ]
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.error(
            "Multi-root Pull failed",
            additionalActions: [FeedbackAction(title: "Retry Pull Roots (Merge)", semanticAction: request) {}],
            notificationID: "arbor.multi-root-retry.pullMerge._project",
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.title, "Retry Pull Roots (Merge)")
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    func testMultiRootChangesMutationRetryRequestsRoundTripRootAndPath() throws {
        let cases: [(ArborVCSActionRequest.MultiRootRetryOperation, String?)] = [
            (.stage, "Sources/App.swift"),
            (.unstage, "Sources/App.swift"),
            (.stageAll, nil),
            (.unstageAll, nil)
        ]

        for (operation, path) in cases {
            let request = ArborVCSActionRequest(
                kind: .retryMultiRootOperation,
                projectPath: "/project",
                rootPath: nil,
                shelfName: "",
                multiRootRetryOperation: operation,
                multiRootRetryRootPaths: ["/project/app"],
                multiRootRetryPath: path
            )
            let decoded = try JSONDecoder().decode(
                ArborVCSActionRequest.self,
                from: JSONEncoder().encode(request)
            )

            XCTAssertEqual(decoded, request)
            XCTAssertEqual(decoded.multiRootRetryOperation, operation)
            XCTAssertEqual(decoded.multiRootRetryRootPaths, ["/project/app"])
            XCTAssertEqual(decoded.multiRootRetryPath, path)
        }
    }

    func testMultiRootChangesBatchRetryPreservesRootQualifiedPaths() throws {
        let first = PersistedMultiRootChangePath(
            rootPath: "/project/app",
            path: "README.md"
        )
        let second = PersistedMultiRootChangePath(
            rootPath: "/project/lib",
            path: "README.md"
        )
        let request = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRetryOperation: .stage,
            multiRootRetryRootPaths: ["/project/app", "/project/lib"],
            multiRootRetryChangePaths: [first, second]
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.multiRootRetryChangePaths, [first, second])
        XCTAssertNotEqual(
            first.makeLiveSelection(),
            second.makeLiveSelection()
        )
    }

    @MainActor
    func testFeedbackHistoryRestoresMultiRootChangesMutationRetryActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterMultiRootChangesMutationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notificationID = "arbor.multi-root-changes.stage.project.app.Sources_App.swift"

        let request = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRetryOperation: .stage,
            multiRootRetryRootPaths: ["/project/app"],
            multiRootRetryPath: "Sources/App.swift"
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.error(
            "Stage failed",
            detail: "/project/app: Sources/App.swift",
            additionalActions: [
                FeedbackAction(
                    title: "Retry Stage",
                    semanticAction: request
                ) {}
            ],
            notificationID: notificationID,
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.title, "Retry Stage")
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)

        reloaded.success(
            "Changes staged",
            detail: "/project/app: Sources/App.swift",
            notificationID: notificationID,
            localized: false
        )
        XCTAssertEqual(reloaded.history.count, 1)
        XCTAssertEqual(reloaded.history.first?.title, "Changes staged")
        XCTAssertTrue(reloaded.history.first?.actions.isEmpty == true)
        XCTAssertEqual(reloaded.history.first?.notificationID, notificationID)
    }

    func testOperationRecoveryActionRequestRoundTripsAllOperationModes() throws {
        for action in [
            ArborVCSActionRequest.OperationRecoveryAction.continueOperation,
            .skip,
            .abort,
            .openRecovery
        ] {
            let request = ArborVCSActionRequest(
                kind: .operationRecovery,
                projectPath: "/project",
                rootPath: "/project/app",
                shelfName: "",
                operationRecoveryAction: action
            )

            let decoded = try JSONDecoder().decode(
                ArborVCSActionRequest.self,
                from: JSONEncoder().encode(request)
            )

            XCTAssertEqual(decoded, request)
            XCTAssertEqual(decoded.operationRecoveryAction, action)
            XCTAssertEqual(decoded.rootPath, "/project/app")
        }
    }

    func testUncommitUndoActionRequestRoundTripsBranchAndHeadScope() throws {
        let request = ArborVCSActionRequest(
            kind: .undoUncommit,
            projectPath: "/project",
            rootPath: "/project/app",
            shelfName: "",
            uncommitCommitID: "0123456789abcdef",
            uncommitExpectedHead: "fedcba9876543210",
            uncommitExpectedBranch: "main"
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.kind, .undoUncommit)
        XCTAssertEqual(decoded.uncommitExpectedBranch, "main")
    }

    @MainActor
    func testFeedbackHistoryRestoresUncommitUndoActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterUncommitUndoTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .undoUncommit,
            projectPath: "/project",
            rootPath: "/project/app",
            shelfName: "",
            uncommitCommitID: "0123456789abcdef",
            uncommitExpectedHead: "fedcba9876543210",
            uncommitExpectedBranch: "main"
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.success(
            "Latest commit undone",
            additionalActions: [
                FeedbackAction(
                    title: "Undo Uncommit",
                    semanticAction: request
                ) {}
            ],
            notificationID: "arbor.uncommit-undo._project_app"
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testFeedbackHistoryRestoresOperationRecoveryActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterOperationRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .operationRecovery,
            projectPath: "/project",
            rootPath: "/project/app",
            shelfName: "",
            operationRecoveryAction: .abort
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Rebase recovery available",
            additionalActions: [
                FeedbackAction(
                    title: "Abort",
                    semanticAction: request
                ) {}
            ],
            notificationID: "arbor.operation-recovery._project_app",
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }
}
