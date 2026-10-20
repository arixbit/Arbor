import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {

    func testMergeDialogRejectsAlreadyMergedLocalBranchesButAllowsRevisions() {
        let merged = Set(["feature/done"])
        XCTAssertTrue(mergeBranchIsAlreadyMerged("feature/done", mergedBranches: merged))
        XCTAssertTrue(mergeBranchIsAlreadyMerged("refs/heads/feature/done", mergedBranches: merged))
        XCTAssertTrue(mergeBranchIsAlreadyMerged("refs/remotes/origin/feature/done", mergedBranches: ["origin/feature/done"]))
        XCTAssertFalse(mergeBranchIsAlreadyMerged("feature/in-progress", mergedBranches: merged))
        XCTAssertFalse(mergeBranchIsAlreadyMerged("a1b2c3d", mergedBranches: merged))
    }

    func testTrackedRemoteDeletionRequiresTheSoleLiveTrackerAndAnUnprotectedRemote() {
        let soleTracker = [
            SyncStatus(
                branch: "feature",
                upstream: "origin/feature",
                ahead: 0,
                behind: 0,
                trackingExists: true
            )
        ]
        XCTAssertEqual(
            deletableTrackedRemoteBranch(
                branchName: "feature",
                upstream: "origin/feature",
                syncStatuses: soleTracker,
                protectedPatterns: []
            ),
            "origin/feature"
        )
        XCTAssertNil(
            deletableTrackedRemoteBranch(
                branchName: "feature",
                upstream: "feature",
                syncStatuses: soleTracker,
                protectedPatterns: []
            )
        )
        XCTAssertNil(
            deletableTrackedRemoteBranch(
                branchName: "feature",
                upstream: "origin/feature",
                syncStatuses: [
                    soleTracker[0],
                    SyncStatus(
                        branch: "feature-copy",
                        upstream: "origin/feature",
                        ahead: 0,
                        behind: 0,
                        trackingExists: true
                    )
                ],
                protectedPatterns: []
            )
        )
        XCTAssertNil(
            deletableTrackedRemoteBranch(
                branchName: "feature",
                upstream: "origin/main",
                syncStatuses: [
                    SyncStatus(
                        branch: "feature",
                        upstream: "origin/main",
                        ahead: 0,
                        behind: 0,
                        trackingExists: true
                    )
                ],
                protectedPatterns: ["main"]
            )
        )
        XCTAssertEqual(
            deletableTrackedRemoteBranches(
                branchName: "feature",
                syncStatusesByRoot: [
                    soleTracker,
                    [
                        SyncStatus(
                            branch: "feature",
                            upstream: "origin/feature",
                            ahead: 0,
                            behind: 0,
                            trackingExists: true
                        ),
                        SyncStatus(
                            branch: "feature-copy",
                            upstream: "origin/feature",
                            ahead: 0,
                            behind: 0,
                            trackingExists: true
                        )
                    ]
                ],
                protectedPatterns: []
            ),
            []
        )
    }

    func testCheckoutAndUpdateRevalidatesTrackingBeforeSwitching() {
        XCTAssertEqual(
            checkoutAndUpdateUpstream(
                branch: "feature",
                syncStatuses: [
                    SyncStatus(
                        branch: "feature",
                        upstream: "origin/feature",
                        ahead: 0,
                        behind: 1,
                        trackingExists: true
                    )
                ]
            ),
            "origin/feature"
        )
        XCTAssertNil(
            checkoutAndUpdateUpstream(
                branch: "feature",
                syncStatuses: [
                    SyncStatus(
                        branch: "feature",
                        upstream: "origin/feature",
                        ahead: 0,
                        behind: 1,
                        trackingExists: false
                    )
                ]
            )
        )
        XCTAssertNil(
            checkoutAndUpdateUpstream(
                branch: "feature",
                syncStatuses: [
                    SyncStatus(
                        branch: "feature",
                        upstream: "origin/",
                        ahead: 0,
                        behind: 0,
                        trackingExists: true
                    )
                ]
            )
        )
    }

    func testBranchNameCleanupMatchesGitRefValidatorTypingAndFinalRules() {
        let suiteName = "Arbor.GitBranchNameCleanupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            GitBranchNameCleanup.cleanUpOnTyping("feature  name\twith~bad:chars", defaults: defaults),
            "feature-name-withbadchars"
        )
        XCTAssertEqual(
            GitBranchNameCleanup.cleanUp("feature.lock", defaults: defaults),
            "feature"
        )
        XCTAssertEqual(
            GitBranchNameCleanup.cleanUp("feature/", defaults: defaults),
            "feature"
        )
        defaults.set("_", forKey: GitBranchNameCleanupSettings.key)
        XCTAssertEqual(
            GitBranchNameCleanup.cleanUpOnTyping("release candidate", defaults: defaults),
            "release_candidate"
        )
    }

    func testCheckoutWithRebaseReusesExistingBranchUnlessResetIsExplicit() {
        XCTAssertFalse(
            branchCreateAndRebaseShouldCreateBranch(
                branchAlreadyExists: true,
                resetExisting: false
            )
        )
        XCTAssertTrue(
            branchCreateAndRebaseShouldCreateBranch(
                branchAlreadyExists: true,
                resetExisting: true
            )
        )
        XCTAssertTrue(
            branchCreateAndRebaseShouldCreateBranch(
                branchAlreadyExists: false,
                resetExisting: false
            )
        )
    }

    func testMultiRootRemoteTagRowsKeepRepositoryIdentityAndSortStably() {
        let rows = [
            MultiRootRemoteTagRow(
                rootPath: "/workspace/z-root",
                displayName: "Z",
                relativePath: "z",
                tag: RemoteTagInfo(
                    remote: "origin",
                    name: "release",
                    objectId: "1111111111111111111111111111111111111111",
                    id: "1111111111111111111111111111111111111111",
                    shortId: "1111111",
                    kind: .lightweight
                )
            ),
            MultiRootRemoteTagRow(
                rootPath: "/workspace/a-root",
                displayName: "A",
                relativePath: "a",
                tag: RemoteTagInfo(
                    remote: "origin",
                    name: "release",
                    objectId: "2222222222222222222222222222222222222222",
                    id: "2222222222222222222222222222222222222222",
                    shortId: "2222222",
                    kind: .lightweight
                )
            )
        ]

        let sorted = stableMultiRootRemoteTagRows(rows)
        XCTAssertEqual(sorted.map(\.relativePath), ["a", "z"])
        XCTAssertNotEqual(sorted[0].id, sorted[1].id)
        XCTAssertEqual(
            filteredMultiRootRemoteTagRows(sorted, query: "z-root").map(\.relativePath),
            ["z"]
        )
    }
}
