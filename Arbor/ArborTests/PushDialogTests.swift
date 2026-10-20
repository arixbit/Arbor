import XCTest
@testable import Arbor


final class PushDialogTests: XCTestCase {
    func testLeadingPlusRefspecIsForceAndExposesItsBranchTarget() {
        XCTAssertTrue(PushDialogRefspec.requestsForce(" +HEAD:refs/heads/main "))
        XCTAssertFalse(PushDialogRefspec.requestsForce("HEAD:refs/heads/main"))
        XCTAssertEqual(
            PushDialogRefspec.sourceRevision(" +feature/local:refs/heads/release/1.0 "),
            "feature/local"
        )
        XCTAssertEqual(
            PushDialogRefspec.targetBranch("+HEAD:refs/heads/release/1.0"),
            "release/1.0"
        )
        XCTAssertNil(PushDialogRefspec.sourceRevision(":refs/heads/main"))
        XCTAssertNil(PushDialogRefspec.targetBranch("refs/tags/v1:refs/tags/v1"))
    }

    func testOnlyCommitAndPushKeepsNoRemoteCommitFallback() {
        XCTAssertTrue(PushDialogMode.commitAndPush.allowsCommitOnlyFallbackWithoutRemote)
        XCTAssertFalse(PushDialogMode.push.allowsCommitOnlyFallbackWithoutRemote)
        XCTAssertFalse(PushDialogMode.pushUpToCommit.allowsCommitOnlyFallbackWithoutRemote)
        XCTAssertFalse(PushDialogMode.addCommitsToRemoteBranch.allowsCommitOnlyFallbackWithoutRemote)
    }

    func testAddCommitsToRemoteBranchUsesDedicatedPushMode() {
        XCTAssertEqual(
            PushDialogMode.addCommitsToRemoteBranch.title,
            "Add Commits to Remote Branch"
        )
        XCTAssertEqual(
            PushDialogMode.addCommitsToRemoteBranch.actionTitle,
            "Push"
        )
    }

    func testPushTagModesMatchIntelliJOptions() {
        XCTAssertEqual(PushDialogTagMode.all.title, "All tags")
        XCTAssertEqual(
            PushDialogTagMode.currentBranch.title,
            "Tags reachable from current branch"
        )
        XCTAssertEqual(PushDialogTagMode.allCases, [.all, .currentBranch])
    }

    func testPushUpToCommitBuildsDetachedSourceRefspec() {
        XCTAssertEqual(
            PushDialogRefspec.pushUpToCommit(
                sourceRevision: "abc123",
                targetBranch: "release/1.0"
            ),
            "abc123:refs/heads/release/1.0"
        )
    }

    func testPushUpToCommitAcceptsFullTargetRef() {
        XCTAssertEqual(
            PushDialogRefspec.pushUpToCommit(
                sourceRevision: "HEAD~2",
                targetBranch: "refs/heads/release"
            ),
            "HEAD~2:refs/heads/release"
        )
    }

    func testPushUpToCommitRequiresBothSourceAndTarget() {
        XCTAssertNil(
            PushDialogRefspec.pushUpToCommit(sourceRevision: "", targetBranch: "main")
        )
        XCTAssertNil(
            PushDialogRefspec.pushUpToCommit(sourceRevision: "abc123", targetBranch: " ")
        )
    }
}
