import XCTest
@testable import Arbor


final class GitUpdateNotificationSummaryTests: XCTestCase {
    func testUpdatedCommitCountParsesSuccessfulAndRestoreMessages() {
        XCTAssertEqual(
            ContentView.updatedCommitCount(from: "updated 3 commits and restored local changes"),
            3
        )
        XCTAssertEqual(ContentView.updatedCommitCount(from: "updated 0 commits"), 0)
        XCTAssertNil(ContentView.updatedCommitCount(from: "detached HEAD"))
    }

    func testSkippedRootsAreGroupedByReasonAndSorted() {
        let results = [
            RootOperationResult(
                rootPath: "/b",
                displayName: "B",
                success: true,
                skipped: true,
                message: "detached HEAD"
            ),
            RootOperationResult(
                rootPath: "/a",
                displayName: "A",
                success: true,
                skipped: true,
                message: "no configured upstream"
            ),
            RootOperationResult(
                rootPath: "/c",
                displayName: "C",
                success: true,
                skipped: true,
                message: "detached HEAD"
            )
        ]

        XCTAssertEqual(
            ContentView.skippedUpdateRootDetails(results),
            ["B, C (detached HEAD)", "A (no configured upstream)"]
        )
    }

    func testSuccessDetailIncludesCommitCountAndSkippedReasons() {
        let results = [
            RootOperationResult(
                rootPath: "/repo",
                displayName: "App",
                success: true,
                skipped: false,
                message: "updated 2 commits"
            ),
            RootOperationResult(
                rootPath: "/docs",
                displayName: "Docs",
                success: true,
                skipped: true,
                message: "detached HEAD"
            )
        ]

        XCTAssertEqual(
            ContentView.multiRootUpdateSuccessDetail(results),
            "1 updated · 2 commits · Skipped: Docs (detached HEAD)"
        )
        XCTAssertEqual(
            ContentView.multiRootUpdateSuccessDetail(results, updatedFilesCount: 3),
            "3 files updated in 2 commits · Skipped: Docs (detached HEAD)"
        )
    }

    func testUpdateProjectRequiresAnEligibleRootWhenAllRootsAreSkipped() {
        let unavailable = [
            RootOperationResult(
                rootPath: "/workspace/app",
                displayName: "App",
                success: true,
                skipped: true,
                message: "no configured upstream"
            ),
            RootOperationResult(
                rootPath: "/workspace/docs",
                displayName: "Docs",
                success: true,
                skipped: true,
                message: "detached HEAD"
            )
        ]
        XCTAssertFalse(ContentView.updateProjectHasEligibleRoot(unavailable))

        let partiallyEligible = unavailable + [
            RootOperationResult(
                rootPath: "/workspace/service",
                displayName: "Service",
                success: true,
                skipped: false,
                message: "updated 0 commits"
            )
        ]
        XCTAssertTrue(ContentView.updateProjectHasEligibleRoot(partiallyEligible))

        let failed = [
            RootOperationResult(
                rootPath: "/workspace/app",
                displayName: "App",
                success: false,
                skipped: false,
                message: "another Git operation is already in progress"
            )
        ]
        XCTAssertFalse(ContentView.updateProjectHasEligibleRoot(failed))
    }

    func testUpdateProjectNotReadyClassifierCoversEngineAndLegacyMessages() {
        let ready = RootOperationResult(
            rootPath: "/workspace/app",
            displayName: "App",
            success: true,
            skipped: false,
            message: "updated 0 commits"
        )
        XCTAssertFalse(ContentView.updateProjectIsNotReady([ready]))
        XCTAssertTrue(ContentView.updateProjectIsNotReady([
            RootOperationResult(
                rootPath: "/workspace/app",
                displayName: "App",
                success: false,
                skipped: false,
                message: "update not ready: unresolved conflicts remain"
            )
        ]))
        XCTAssertTrue(ContentView.updateProjectIsNotReady([
            RootOperationResult(
                rootPath: "/workspace/app",
                displayName: "App",
                success: false,
                skipped: false,
                message: "another Git operation is already in progress"
            )
        ]))
        XCTAssertFalse(ContentView.updateProjectIsNotReady([
            RootOperationResult(
                rootPath: "/workspace/docs",
                displayName: "Docs",
                success: true,
                skipped: true,
                message: "detached HEAD"
            )
        ]))
    }

    func testUnknownCommitCountDoesNotLookLikeNothingToUpdate() {
        let results = [
            RootOperationResult(
                rootPath: "/submodule",
                displayName: "Submodule",
                success: true,
                skipped: false,
                message: "updated detached submodule via parent App"
            )
        ]

        XCTAssertEqual(
            ContentView.multiRootUpdateSuccessDetail(results),
            "1 updated"
        )
    }

    func testUpdateSessionRevisionRangesOnlyIncludeChangedSuccessfulRoots() {
        let results = [
            RootOperationResult(
                rootPath: "/workspace/docs",
                displayName: "Docs",
                success: true,
                skipped: true,
                message: "detached HEAD"
            ),
            RootOperationResult(
                rootPath: "/workspace/app/.",
                displayName: "App",
                success: true,
                skipped: false,
                message: "updated 2 commits"
            ),
            RootOperationResult(
                rootPath: "/workspace/failed",
                displayName: "Failed",
                success: false,
                skipped: false,
                message: "conflict"
            ),
            RootOperationResult(
                rootPath: "/workspace/unchanged",
                displayName: "Unchanged",
                success: true,
                skipped: false,
                message: "updated 0 commits"
            )
        ]

        let ranges = ContentView.updateSessionRevisionRanges(
            previousHeads: [
                "/workspace/app": "app-old",
                "/workspace/docs": "docs-old",
                "/workspace/failed": "failed-old",
                "/workspace/unchanged": "same"
            ],
            currentHeads: [
                "/workspace/app": "app-new",
                "/workspace/docs": "docs-new",
                "/workspace/failed": "failed-new",
                "/workspace/unchanged": "same"
            ],
            results: results
        )

        XCTAssertEqual(ranges, [
            PersistedLogRevisionRange(
                rootPath: "/workspace/app",
                oldRevision: "app-old",
                newRevision: "app-new"
            )
        ])
    }

    func testJoinedRevisionRangesKeepOriginalBoundaryAcrossRepeatedPushRecovery() {
        let joined = ContentView.joinedRevisionRanges(
            existing: [
                PersistedLogRevisionRange(
                    rootPath: "/workspace/app/.",
                    oldRevision: "before-first-update",
                    newRevision: "after-first-update"
                ),
                PersistedLogRevisionRange(
                    rootPath: "/workspace/docs",
                    oldRevision: "docs-before",
                    newRevision: "docs-after"
                )
            ],
            latest: [
                PersistedLogRevisionRange(
                    rootPath: "/workspace/app",
                    oldRevision: "before-second-update",
                    newRevision: "after-second-update"
                )
            ]
        )

        XCTAssertEqual(joined, [
            PersistedLogRevisionRange(
                rootPath: "/workspace/app",
                oldRevision: "before-first-update",
                newRevision: "after-second-update"
            ),
            PersistedLogRevisionRange(
                rootPath: "/workspace/docs",
                oldRevision: "docs-before",
                newRevision: "docs-after"
            )
        ])
    }

    func testMultiRootPushRetryRangesRetainCompletedRootsAndAppendLaterSuccesses() {
        let initialResults = [
            RootOperationResult(
                rootPath: "/workspace/app",
                displayName: "App",
                success: true,
                skipped: false,
                message: "pushed App"
            ),
            RootOperationResult(
                rootPath: "/workspace/docs",
                displayName: "Docs",
                success: false,
                skipped: false,
                message: "push rejected"
            )
        ]
        let completedInitially = ContentView.successfulPushRevisionRanges(
            pendingRanges: [
                PersistedLogRevisionRange(
                    rootPath: "/workspace/app",
                    oldRevision: "app-base",
                    newRevision: "app-tip"
                ),
                PersistedLogRevisionRange(
                    rootPath: "/workspace/docs",
                    oldRevision: "docs-base",
                    newRevision: "docs-tip"
                )
            ],
            results: initialResults
        )

        let joined = ContentView.joinedRevisionRanges(
            existing: completedInitially,
            latest: [
                PersistedLogRevisionRange(
                    rootPath: "/workspace/docs/.",
                    oldRevision: "docs-base-after-update",
                    newRevision: "docs-tip-after-update"
                )
            ]
        )

        XCTAssertEqual(joined, [
            PersistedLogRevisionRange(
                rootPath: "/workspace/app",
                oldRevision: "app-base",
                newRevision: "app-tip"
            ),
            PersistedLogRevisionRange(
                rootPath: "/workspace/docs",
                oldRevision: "docs-base-after-update",
                newRevision: "docs-tip-after-update"
            )
        ])
    }

    func testMultiRootPushRetryRowsRetainSuccessfulRootsAndReplaceRetriedRoots() {
        let initial = [
            RootOperationResult(
                rootPath: "/workspace/app",
                displayName: "App",
                success: true,
                skipped: false,
                message: "pushed App"
            ),
            RootOperationResult(
                rootPath: "/workspace/docs",
                displayName: "Docs",
                success: false,
                skipped: false,
                message: "push rejected"
            )
        ]
        let retry = [
            RootOperationResult(
                rootPath: "/workspace/docs",
                displayName: "Docs",
                success: true,
                skipped: false,
                message: "pushed Docs"
            )
        ]

        let merged = mergeFeedbackResultRows(
            preserved: feedbackResultRows(from: initial),
            retry: feedbackResultRows(from: retry)
        )

        XCTAssertEqual(merged.map(\.rootPath), [
            "/workspace/app",
            "/workspace/docs"
        ])
        XCTAssertEqual(merged.map(\.state), [.success, .success])
        XCTAssertEqual(merged.map(\.detail), ["pushed App", "pushed Docs"])
    }

    func testTargetedForcePushDoesNotPropagateToNonStaleRetryRoots() {
        let stale = RootOperationResult(
            rootPath: "/workspace/stale",
            displayName: "Stale",
            success: false,
            skipped: false,
            message: "push rejected: stale info"
        )
        let rejected = RootOperationResult(
            rootPath: "/workspace/rejected",
            displayName: "Rejected",
            success: false,
            skipped: false,
            message: "push rejected for origin/main: non-fast-forward"
        )

        let staleOnly = multiRootPushRetryForceOptions(
            requestedForce: true,
            requestedForceWithLease: false,
            hasPriorResultRows: true,
            retryResults: [stale]
        )
        let mixed = multiRootPushRetryForceOptions(
            requestedForce: true,
            requestedForceWithLease: false,
            hasPriorResultRows: true,
            retryResults: [stale, rejected]
        )

        XCTAssertTrue(staleOnly.force)
        XCTAssertFalse(mixed.force)
        XCTAssertFalse(mixed.forceWithLease)
    }

    func testPushRecoveryRevisionRangesIncludeOnlyRootsThatUpdatedAndRepublished() {
        let results = [
            RootOperationResult(
                rootPath: "/workspace/app",
                displayName: "App",
                success: true,
                skipped: false,
                message: "updated and pushed origin/main"
            ),
            RootOperationResult(
                rootPath: "/workspace/docs",
                displayName: "Docs",
                success: true,
                skipped: true,
                message: "detached HEAD; Push recovery update skipped"
            ),
            RootOperationResult(
                rootPath: "/workspace/failed",
                displayName: "Failed",
                success: false,
                skipped: false,
                message: "push rejected"
            )
        ]

        let ranges = ContentView.updateSessionRevisionRanges(
            previousHeads: [
                "/workspace/app": "app-before",
                "/workspace/docs": "docs-before",
                "/workspace/failed": "failed-before"
            ],
            currentHeads: [
                "/workspace/app": "app-after",
                "/workspace/docs": "docs-after",
                "/workspace/failed": "failed-after"
            ],
            results: results
        )

        XCTAssertEqual(ranges, [
            PersistedLogRevisionRange(
                rootPath: "/workspace/app",
                oldRevision: "app-before",
                newRevision: "app-after"
            )
        ])
    }

    func testSuccessfulPushRevisionRangesOnlyIncludeCompletedRoots() {
        let pendingRanges = [
            PersistedLogRevisionRange(
                rootPath: "/workspace/docs/.",
                oldRevision: "docs-before",
                newRevision: "docs-after"
            ),
            PersistedLogRevisionRange(
                rootPath: "/workspace/app",
                oldRevision: "app-before",
                newRevision: "app-after"
            ),
            PersistedLogRevisionRange(
                rootPath: "/workspace/skipped",
                oldRevision: "skipped-before",
                newRevision: "skipped-after"
            )
        ]
        let results = [
            RootOperationResult(
                rootPath: "/workspace/app/.",
                displayName: "App",
                success: true,
                skipped: false,
                message: "pushed App"
            ),
            RootOperationResult(
                rootPath: "/workspace/docs",
                displayName: "Docs",
                success: false,
                skipped: false,
                message: "rejected"
            ),
            RootOperationResult(
                rootPath: "/workspace/skipped",
                displayName: "Skipped",
                success: true,
                skipped: true,
                message: "detached HEAD"
            )
        ]

        XCTAssertEqual(
            ContentView.successfulPushRevisionRanges(
                pendingRanges: pendingRanges,
                results: results
            ),
            [
                PersistedLogRevisionRange(
                    rootPath: "/workspace/app",
                    oldRevision: "app-before",
                    newRevision: "app-after"
                )
            ]
        )
    }
}
