import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {

    func testStashDeleteSelectionResolvesByStableIDAfterStackIndexShifts() {
        let initial = [
            StashInfo(id: "stash-new", shortId: "new", message: "new"),
            StashInfo(id: "stash-old", shortId: "old", message: "old"),
            StashInfo(id: "stash-older", shortId: "older", message: "older")
        ]
        XCTAssertEqual(stashIndex(forID: "stash-old", in: initial), 1)

        let afterDroppingNewest = Array(initial.dropFirst())
        XCTAssertEqual(stashIndex(forID: "stash-old", in: afterDroppingNewest), 0)
        XCTAssertNil(stashIndex(forID: "stash-missing", in: afterDroppingNewest))
    }

    func testPullStashSelectionRequiresTheExactPersistedMessage() {
        let stashes = [
            StashInfo(id: "user-stash", shortId: "user", message: "WIP"),
            StashInfo(id: "pull-stash", shortId: "pull", message: "Arbor: pull 123")
        ]

        XCTAssertEqual(pullStashIndex(message: "Arbor: pull 123", in: stashes), 1)
        XCTAssertNil(pullStashIndex(message: nil, in: stashes))
        XCTAssertNil(pullStashIndex(message: "Arbor: pull", in: stashes))

        let duplicateMessage = stashes + [
            StashInfo(id: "duplicate", shortId: "dupe", message: "Arbor: pull 123")
        ]
        XCTAssertNil(pullStashIndex(message: "Arbor: pull 123", in: duplicateMessage))
    }

    func testStashSplitPreviewSettingDefaultsOnAndPersists() {
        let suiteName = "Arbor.StashSplitPreviewSettingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(GitStashViewSettings.splitPreview(from: defaults))

        GitStashViewSettings.saveSplitPreview(false, defaults: defaults)
        XCTAssertFalse(GitStashViewSettings.splitPreview(from: defaults))

        GitStashViewSettings.saveSplitPreview(true, defaults: defaults)
        XCTAssertTrue(GitStashViewSettings.splitPreview(from: defaults))
    }

    func testPullLocalChangesPreservationCodableKeepsExactShelfOrStashIdentity() throws {
        let shelf = PullLocalChangesPreservation(
            shelfName: "Arbor: pull 123",
            stashMessage: nil
        )
        let stash = PullLocalChangesPreservation(
            shelfName: nil,
            stashMessage: "Arbor: pull 456",
            stashID: "abcdef1234567890"
        )

        XCTAssertEqual(
            try JSONDecoder().decode(
                PullLocalChangesPreservation.self,
                from: JSONEncoder().encode(shelf)
            ),
            shelf
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                PullLocalChangesPreservation.self,
                from: JSONEncoder().encode(stash)
            ),
            stash
        )

        // Markers written before stash IDs were persisted remain decodable and
        // continue through the message-based compatibility fallback.
        let legacy = try JSONSerialization.data(
            withJSONObject: ["shelfName": NSNull(), "stashMessage": "Arbor: pull legacy"]
        )
        let decodedLegacy = try JSONDecoder().decode(
            PullLocalChangesPreservation.self,
            from: legacy
        )
        XCTAssertEqual(decodedLegacy.stashMessage, "Arbor: pull legacy")
        XCTAssertNil(decodedLegacy.stashID)
    }

    func testStashBranchRetryRequestRoundTripsIdentityAndExpectedState() throws {
        let retry = PersistedStashBranchRetry(
            stashID: "stash-object-id",
            branch: "wip/branch",
            expectedCurrentBranch: "main",
            expectedCurrentHead: "head-before-retry"
        )
        let request = ArborVCSActionRequest(
            kind: .retryStashBranch,
            projectPath: "/project",
            rootPath: "/project/nested",
            shelfName: "",
            stashBranchRetry: retry
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertTrue(
            stashBranchRetryStateIsSafe(
                retry,
                currentBranch: "main",
                currentHead: "head-before-retry",
                stashIDs: ["other", "stash-object-id"],
                localBranches: ["main"]
            )
        )
        XCTAssertFalse(
            stashBranchRetryStateIsSafe(
                retry,
                currentBranch: "wip/branch",
                currentHead: "head-before-retry",
                stashIDs: ["stash-object-id"],
                localBranches: ["main", "wip/branch"]
            )
        )
    }
}
