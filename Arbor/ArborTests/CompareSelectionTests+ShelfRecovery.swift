import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {

    func testShelfFeedbackTitlesMatchApplyAndPopActions() {
        XCTAssertEqual(shelfFeedbackTitle(.apply), "Apply Shelf")
        XCTAssertEqual(
            shelfFeedbackTitle(.apply, removeApplied: true),
            "Unshelve and Remove Shelf"
        )
        XCTAssertEqual(shelfFeedbackTitle(.pop), "Pop Shelf")
        XCTAssertEqual(shelfFeedbackTitle(.drop), "Drop Shelf")
    }

    @MainActor
    func testFeedbackOperationItemsPersistShelfBatchOutcomesAcrossReload() {
        let suiteName = "Arbor.FeedbackOperationItemsReloadTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let notificationID = "arbor.shelf.batch.apply./workspace/app"
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Some shelves were not unshelved",
            detail: "1/2 applied",
            notificationID: notificationID,
            localized: false
        )
        feedbackCenter.attachResultRows(
            [
                FeedbackResultRow(
                    rootPath: "/workspace/app",
                    displayName: "App",
                    state: .success,
                    detail: "Shelf batch finished"
                )
            ],
            notificationID: notificationID
        )
        feedbackCenter.attachOperationItems(
            [
                FeedbackOperationItem(
                    scope: "/workspace/app",
                    name: "feature-a",
                    state: .success,
                    detail: "Applied → Review",
                    children: [
                        FeedbackOperationSubitem(
                            scope: "/workspace/app\u{1f}feature-a",
                            path: "Sources/App.swift",
                            state: .success,
                            detail: "Applied"
                        ),
                        FeedbackOperationSubitem(
                            scope: "/workspace/app\u{1f}feature-a",
                            path: "Tests/AppTests.swift",
                            state: .skipped,
                            detail: "Not attempted"
                        )
                    ]
                ),
                FeedbackOperationItem(
                    scope: "/workspace/app",
                    name: "feature-b",
                    state: .failed,
                    detail: "Conflict paused: Sources/App.swift"
                )
            ],
            notificationID: notificationID
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.resultRows.map(\.displayName), ["App"])
        XCTAssertEqual(reloaded.history.first?.resultItems.map(\.name), ["feature-a", "feature-b"])
        XCTAssertEqual(reloaded.history.first?.resultItems.map(\.state), [.success, .failed])
        XCTAssertEqual(
            reloaded.history.first?.resultItems[1].scope,
            "/workspace/app"
        )
        XCTAssertEqual(
            reloaded.history.first?.resultItems[1].detail,
            "Conflict paused: Sources/App.swift"
        )
        XCTAssertEqual(
            reloaded.history.first?.resultItems[0].children.map(\.path),
            ["Sources/App.swift", "Tests/AppTests.swift"]
        )
        XCTAssertEqual(
            reloaded.history.first?.resultItems[0].children.map(\.state),
            [.success, .skipped]
        )
    }

    @MainActor
    func testFeedbackShelfRetryPreservesAndMergesStableItemResults() {
        let suiteName = "Arbor.FeedbackShelfRetryItemsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let notificationID = "arbor.shelf.batch.apply./workspace/app"
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        let completedItem = FeedbackOperationItem(
            scope: "/workspace/app",
            name: "feature-a",
            state: .success,
            detail: "Applied"
        )
        let pendingItem = FeedbackOperationItem(
            scope: "/workspace/app",
            name: "feature-b",
            state: .failed,
            detail: "Conflict paused"
        )

        feedbackCenter.begin("Unshelve shelves", notificationID: notificationID)
        feedbackCenter.attachOperationItems(
            [completedItem, pendingItem],
            notificationID: notificationID
        )
        feedbackCenter.begin(
            "Retry remaining shelves",
            notificationID: notificationID,
            preserveResultItems: true
        )
        XCTAssertEqual(
            feedbackCenter.history.first?.resultItems.map(\.name),
            ["feature-a", "feature-b"]
        )

        let retriedItem = FeedbackOperationItem(
            scope: "/workspace/app",
            name: "feature-b",
            state: .success,
            detail: "Applied"
        )
        feedbackCenter.success(
            "Shelves unshelved",
            notificationID: notificationID,
            localized: false
        )
        feedbackCenter.attachOperationItems(
            [retriedItem],
            notificationID: notificationID,
            mergeWithExisting: true
        )

        XCTAssertEqual(
            feedbackCenter.history.first?.resultItems.map(\.name),
            ["feature-a", "feature-b"]
        )
        XCTAssertEqual(
            feedbackCenter.history.first?.resultItems.map(\.state),
            [.success, .success]
        )
        XCTAssertEqual(
            feedbackCenter.history.first?.resultItems.map(\.detail),
            ["Applied", "Applied"]
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(
            reloaded.history.first?.resultItems.map(\.name),
            ["feature-a", "feature-b"]
        )
        feedbackCenter.begin("Fresh Shelf batch", notificationID: notificationID)
        XCTAssertTrue(feedbackCenter.history.first?.resultItems.isEmpty == true)
    }

    @MainActor
    func testFeedbackShelfMemberRetryPreservesGroupedPathResults() {
        let suiteName = "Arbor.FeedbackShelfMemberRetryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let rootPath = "/workspace/app"
        let notificationID = shelfNotificationID(
            prefix: "shelf-member-batch.drop",
            rootPath: rootPath
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        let completedItem = FeedbackOperationItem(
            scope: rootPath,
            name: "Shelf A",
            state: .success,
            detail: "Moved to Recently Deleted",
            children: [FeedbackOperationSubitem(
                scope: "\(rootPath)\u{1f}Shelf A",
                path: "Sources/A.swift",
                state: .success,
                detail: "Moved to Recently Deleted"
            )]
        )
        let pendingItem = FeedbackOperationItem(
            scope: rootPath,
            name: "Shelf B",
            state: .failed,
            detail: "Permission denied"
        )

        feedbackCenter.begin("Drop Shelf changes", notificationID: notificationID)
        feedbackCenter.attachOperationItems(
            [completedItem, pendingItem],
            notificationID: notificationID
        )
        feedbackCenter.begin(
            "Retry remaining Shelf changes",
            notificationID: notificationID,
            preserveResultItems: true
        )
        let retriedItem = FeedbackOperationItem(
            scope: rootPath,
            name: "Shelf B",
            state: .success,
            detail: "Moved to Recently Deleted",
            children: [FeedbackOperationSubitem(
                scope: "\(rootPath)\u{1f}Shelf B",
                path: "Sources/B.swift",
                state: .success,
                detail: "Moved to Recently Deleted"
            )]
        )
        feedbackCenter.success(
            "Shelf changes dropped",
            notificationID: notificationID,
            localized: false
        )
        feedbackCenter.attachOperationItems(
            [retriedItem],
            notificationID: notificationID,
            mergeWithExisting: true
        )

        XCTAssertEqual(
            feedbackCenter.history.first?.resultItems.map(\.name),
            ["Shelf A", "Shelf B"]
        )
        XCTAssertEqual(
            feedbackCenter.history.first?.resultItems.map(\.state),
            [.success, .success]
        )
        XCTAssertEqual(
            feedbackCenter.history.first?.resultItems[0].children.map(\.path),
            ["Sources/A.swift"]
        )
        XCTAssertEqual(
            FeedbackCenter(defaults: defaults).history.first?.resultItems.map(\.name),
            ["Shelf A", "Shelf B"]
        )

        feedbackCenter.begin("Fresh Shelf member batch", notificationID: notificationID)
        XCTAssertTrue(feedbackCenter.history.first?.resultItems.isEmpty == true)
    }

    func testShelfActionRequestRoundTripsAcrossPersistenceBoundary() throws {
        let request = ArborVCSActionRequest(
            kind: .restoreShelf,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "WIP: review"
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ArborVCSActionRequest.self, from: data)

        XCTAssertEqual(decoded, request)
    }

    func testDeletedShelfMemberDeleteActionKeepsRootAndPaths() throws {
        let request = ArborVCSActionRequest(
            kind: .deleteDeletedShelfPaths,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "WIP: review (deleted)",
            shelfPaths: ["Sources/App.swift", "Tests/AppTests.swift"]
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.rootPath, "/project/app")
        XCTAssertEqual(decoded.shelfPaths, ["Sources/App.swift", "Tests/AppTests.swift"])
    }

    func testShelfDeletionUndoActionRequestPreservesOriginalTimestamp() throws {
        let request = ArborVCSActionRequest(
            kind: .undoShelfDeletion,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "WIP: review",
            shelfRestoreTimestamp: 1_725_000_123
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ArborVCSActionRequest.self, from: data)

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.shelfRestoreTimestamp, 1_725_000_123)
    }

    func testShelfBatchDeletionUndoActionPreservesAllOriginalTimestamps() throws {
        let request = ArborVCSActionRequest(
            kind: .undoShelfDeletions,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "",
            shelfRestoreTimestamps: [
                "WIP: one": 1_725_000_123,
                "WIP: two": 1_725_000_456
            ],
            shelfNames: ["WIP: one", "WIP: two"]
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.shelfRestoreTimestamps?["WIP: two"], 1_725_000_456)
    }

    func testShelfDeletedMemberUndoActionRequestPreservesPaths() throws {
        let request = ArborVCSActionRequest(
            kind: .restoreShelfPaths,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "WIP: review-deleted-members",
            shelfPaths: ["Sources/App.swift", "README.md"],
            shelfRestoreTimestamp: 1_725_000_123
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ArborVCSActionRequest.self, from: data)

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.shelfPaths, ["Sources/App.swift", "README.md"])
    }

    func testSavedChangesActionRequestRoundTripsAndKeepsLegacyPayloadsReadable() throws {
        let request = ArborVCSActionRequest(
            kind: .showSavedChanges,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "",
            savedChangesKind: .stash,
            savedChangesID: "stash@{2}:abc123"
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ArborVCSActionRequest.self, from: data)

        XCTAssertEqual(decoded, request)

        let legacyJSON = #"{"kind":"restoreShelf","projectPath":"/project/app","rootPath":"/project/app","shelfName":"WIP: review"}"#
        let legacyRequest = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertEqual(legacyRequest.kind, .restoreShelf)
        XCTAssertNil(legacyRequest.savedChangesKind)
        XCTAssertNil(legacyRequest.savedChangesID)
    }

    func testShelfBatchRetryActionRequestRoundTripsAndKeepsLegacyPayloadsReadable() throws {
        let request = ArborVCSActionRequest(
            kind: .retryShelfBatch,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "",
            shelfNames: ["WIP: one", "WIP: two"],
            shelfBatchOperation: .pop,
            shelfBatchTargetName: nil,
            shelfBatchRemoveApplied: true
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ArborVCSActionRequest.self, from: data)

        XCTAssertEqual(decoded, request)

        let legacyJSON = #"{"kind":"restoreShelf","projectPath":"/project/app","rootPath":"/project/app","shelfName":"WIP: review"}"#
        let legacyRequest = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertNil(legacyRequest.shelfNames)
        XCTAssertNil(legacyRequest.shelfBatchOperation)
        XCTAssertNil(legacyRequest.shelfBatchRemoveApplied)
    }

    func testShelfBatchDropActionRequestRoundTrips() throws {
        let request = ArborVCSActionRequest(
            kind: .retryShelfBatch,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "",
            shelfNames: ["WIP: one", "WIP: two"],
            shelfBatchOperation: .drop,
            shelfBatchTargetName: nil,
            shelfBatchRemoveApplied: false
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ArborVCSActionRequest.self, from: data)

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.shelfBatchOperation, .drop)
    }

    func testShelfDeletePlanRetryActionRequestRoundTrips() throws {
        let plan = ShelfDeletePlan(
            activeShelfNames: ["active"],
            activePathGroups: [
                ShelfPathDeleteGroup(shelfName: "active-members", paths: ["Sources/A.swift"])
            ],
            deletedShelfNames: ["deleted"],
            deletedPathGroups: [
                ShelfPathDeleteGroup(shelfName: "deleted-members", paths: ["Tests/A.swift"])
            ]
        )
        let request = ArborVCSActionRequest(
            kind: .retryShelfDeletePlan,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "",
            shelfDeletePlan: PersistedShelfDeletePlan(plan)
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.shelfDeletePlan?.shelfDeletePlan, plan)
    }

    func testShelfMemberBatchRetryActionRequestRoundTripsGroupedPaths() throws {
        let request = ArborVCSActionRequest(
            kind: .retryShelfMemberBatch,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "",
            shelfMemberGroups: [
                PersistedShelfPathGroup(
                    shelfName: "WIP: one",
                    paths: ["Sources/App.swift", "Tests/AppTests.swift"]
                ),
                PersistedShelfPathGroup(
                    shelfName: "WIP: two",
                    paths: ["README.md"]
                )
            ],
            shelfMemberBatchOperation: .unshelveDeletedAndRemove,
            shelfMemberBatchTargetName: "Review"
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ArborVCSActionRequest.self, from: data)

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.shelfMemberGroups?.count, 2)
        XCTAssertEqual(decoded.shelfMemberBatchOperation, .unshelveDeletedAndRemove)
        XCTAssertEqual(decoded.shelfMemberBatchTargetName, "Review")

        let legacyJSON = #"{"kind":"retryShelfMemberBatch","projectPath":"/project/app","rootPath":"/project/app","shelfName":"","shelfMemberGroups":[{"shelfName":"WIP: one","paths":["Sources/App.swift"]}],"shelfMemberBatchOperation":"unshelve"}"#
        let legacyRequest = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertNil(legacyRequest.shelfMemberBatchTargetName)
    }

    func testShelfLifecycleBatchRetryActionRequestRoundTrips() throws {
        let request = ArborVCSActionRequest(
            kind: .retryShelfLifecycleBatch,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "",
            shelfNames: ["WIP: one", "WIP: two"],
            shelfLifecycleOperation: .deleteDeleted
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ArborVCSActionRequest.self, from: data)

        XCTAssertEqual(decoded, request)
        XCTAssertNil(decoded.shelfBatchOperation)
        XCTAssertNil(decoded.shelfBatchRemoveApplied)
    }

    @MainActor
    func testFeedbackCleanShelfLifecycleReusesStableNotificationEntry() {
        let suiteName = "Arbor.FeedbackCleanShelfTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let notificationID = shelfNotificationID(
            prefix: "shelf-metadata.clean",
            rootPath: "/workspace/app"
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)

        feedbackCenter.begin("Clear Already Unshelved", notificationID: notificationID)
        feedbackCenter.success(
            "Already unshelved shelves cleared",
            detail: "WIP: first",
            notificationID: notificationID,
            localized: false
        )
        feedbackCenter.begin("Clear Already Unshelved", notificationID: notificationID)
        feedbackCenter.warning(
            "No already unshelved shelves to clear",
            notificationID: notificationID,
            localized: false
        )

        XCTAssertEqual(feedbackCenter.history.count, 1)
        XCTAssertEqual(feedbackCenter.history.first?.notificationID, notificationID)
        XCTAssertEqual(feedbackCenter.history.first?.title, "No already unshelved shelves to clear")
    }

    @MainActor
    func testFeedbackHistoryRestoresSemanticShelfActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterShelfActionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .dropShelf,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "WIP: review"
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.success(
            "Shelf restored",
            additionalActions: [
                FeedbackAction(title: "Drop", semanticAction: request) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        let action = reloaded.history.first?.actions.first
        XCTAssertEqual(action?.title, "Drop")
        XCTAssertEqual(action?.semanticAction, request)
    }

    @MainActor
    func testFeedbackHistoryRestoresShelfBatchRetryActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterShelfBatchActionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .retryShelfBatch,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "",
            shelfNames: ["WIP: remaining"],
            shelfBatchOperation: .apply,
            shelfBatchRemoveApplied: false
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Some shelves were not unshelved",
            additionalActions: [
                FeedbackAction(
                    title: "Retry Remaining Shelves",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        let action = reloaded.history.first?.actions.first
        XCTAssertEqual(action?.title, "Retry Remaining Shelves")
        XCTAssertEqual(action?.semanticAction, request)
    }

    @MainActor
    func testFeedbackHistoryRestoresShelfMemberTargetRetryActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterShelfMemberTargetActionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .retryShelfMemberBatch,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "",
            shelfMemberGroups: [
                PersistedShelfPathGroup(shelfName: "WIP: one", paths: ["Sources/App.swift"]),
                PersistedShelfPathGroup(shelfName: "WIP: two", paths: ["Tests/AppTests.swift"])
            ],
            shelfMemberBatchOperation: .unshelveAndRemove,
            shelfMemberBatchTargetName: "Review"
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Some Shelf changes were not unshelved",
            additionalActions: [
                FeedbackAction(
                    title: "Retry Remaining Shelf Changes",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        let action = reloaded.history.first?.actions.first
        XCTAssertEqual(action?.title, "Retry Remaining Shelf Changes")
        XCTAssertEqual(action?.semanticAction, request)
    }

    @MainActor
    func testFeedbackHistoryRestoresShelfLifecycleBatchRetryActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterShelfLifecycleBatchActionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .retryShelfLifecycleBatch,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "",
            shelfNames: ["WIP: remaining"],
            shelfLifecycleOperation: .restoreDeleted
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Some shelves restored",
            additionalActions: [
                FeedbackAction(
                    title: "Retry Remaining Shelf Actions",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        let action = reloaded.history.first?.actions.first
        XCTAssertEqual(action?.title, "Retry Remaining Shelf Actions")
        XCTAssertEqual(action?.semanticAction, request)
    }

    @MainActor
    func testFeedbackHistoryRestoresSavedChangesPreviewActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterSavedChangesActionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .showSavedChanges,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "",
            savedChangesKind: .stash,
            savedChangesID: "stash@{2}:abc123"
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Local changes were not restored",
            additionalActions: [
                FeedbackAction(title: "View saved changes…", semanticAction: request) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        let action = reloaded.history.first?.actions.first
        XCTAssertEqual(action?.title, "View saved changes…")
        XCTAssertEqual(action?.semanticAction, request)
    }
}
