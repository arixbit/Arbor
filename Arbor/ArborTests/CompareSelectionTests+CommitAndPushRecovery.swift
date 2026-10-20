import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {

    func testAddCommitsToRemoteBranchRequiresOneRootAndLinearCommits() {
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
        var merge = first
        merge.id = "merge"
        merge.parentIds = ["left", "right"]
        var otherRoot = first
        otherRoot.id = "other"
        otherRoot.repositoryPath = "/workspace/two"

        XCTAssertTrue(isAddCommitsToRemoteBranchAvailable(for: [first]))
        XCTAssertFalse(isAddCommitsToRemoteBranchAvailable(for: [first, merge]))
        XCTAssertFalse(isAddCommitsToRemoteBranchAvailable(for: [first, otherRoot]))
    }

    func testMultiRootForcePushRetryActionRoundTripsLeaseOptions() throws {
        let request = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRetryOperation: .push,
            multiRootRetryRootPaths: ["/project/app"],
            multiRootPushTagMode: .all,
            multiRootPushSkipHooks: true,
            multiRootPushForce: true,
            multiRootPushForceWithLease: true
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.multiRootPushTagMode, .all)
        XCTAssertEqual(decoded.multiRootPushSkipHooks, true)
        XCTAssertEqual(decoded.multiRootPushForce, true)
        XCTAssertEqual(decoded.multiRootPushForceWithLease, true)
    }

    @MainActor
    func testFeedbackHistoryRestoresPushRecoveryRetryActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterPushRecoveryRetryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRetryOperation: .pushRecovery,
            multiRootRetryRootPaths: ["/project/app"],
            multiRootRetryUpdateRootPaths: ["/project/app", "/project/lib"],
            multiRootRetryRebase: true,
            multiRootPushTagMode: .all,
            multiRootPushSkipHooks: true
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.error(
            "Update Push Roots failed",
            additionalActions: [
                FeedbackAction(
                    title: "Retry Push Recovery",
                    semanticAction: request
                ) {}
            ],
            notificationID: "arbor.multi-root-retry.pushRecovery._project",
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.title, "Retry Push Recovery")
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    func testMultiRootCommitRetryRequestRoundTripsFullCommitContext() throws {
        let options = MultiRootCommitOptions(
            skipHooks: true,
            authorName: "Author",
            authorEmail: "author@example.com",
            committerName: "Committer",
            committerEmail: "committer@example.com",
            signOff: true,
            coAuthors: ["Co Author <co@example.com>"],
            amend: true,
            runBeforeCommitChecks: true,
            beforeCommitCommands: [
                MultiRootCommitCheck(command: "swift", args: ["test", "--parallel"])
            ]
        )
        let persisted = PersistedMultiRootCommitRetry(
            message: "release: retry failed roots",
            options: options,
            pushAfterCommit: true,
            pushRootPaths: ["/project/app"],
            selectedPaths: [
                PersistedMultiRootChangePath(
                    rootPath: "/project/app",
                    path: "Sources/App.swift",
                    oldPath: "Sources/LegacyApp.swift"
                ),
                PersistedMultiRootChangePath(
                    rootPath: "/project/lib",
                    path: "README.md"
                )
            ]
        )
        let request = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRetryOperation: .commit,
            multiRootRetryRootPaths: ["/project/app", "/project/lib"],
            multiRootCommitRetry: persisted
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.multiRootRetryOperation, .commit)
        XCTAssertEqual(decoded.multiRootRetryRootPaths, ["/project/app", "/project/lib"])
        XCTAssertEqual(decoded.multiRootCommitRetry?.message, persisted.message)
        XCTAssertEqual(decoded.multiRootCommitRetry?.pushAfterCommit, true)
        XCTAssertEqual(decoded.multiRootCommitRetry?.pushRootPaths, ["/project/app"])
        XCTAssertEqual(
            decoded.multiRootCommitRetry?.selectedPaths,
            persisted.selectedPaths
        )
        XCTAssertEqual(
            decoded.multiRootCommitRetry?.makeLiveOptions().beforeCommitCommands.first?.command,
            "swift"
        )
        XCTAssertEqual(
            decoded.multiRootCommitRetry?.makeLiveOptions().beforeCommitCommands.first?.args,
            ["test", "--parallel"]
        )
        XCTAssertEqual(decoded.multiRootCommitRetry?.makeLiveOptions().authorEmail, options.authorEmail)
        XCTAssertEqual(decoded.multiRootCommitRetry?.makeLiveOptions().amend, options.amend)

        let pushRequest = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRetryOperation: .pushAfterCommit,
            multiRootRetryRootPaths: ["/project/app"]
        )
        let decodedPushRequest = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(pushRequest)
        )
        XCTAssertEqual(decodedPushRequest, pushRequest)
        XCTAssertEqual(decodedPushRequest.multiRootRetryOperation, .pushAfterCommit)
    }

    func testMultiRootCommitAndPushOnlyStartsPushAfterAnAllSuccessfulCommitPhase() {
        XCTAssertTrue(
            shouldAutomaticallyOpenMultiRootCommitPushOptions(
                pushAfterCommit: true,
                pushRootPaths: ["/project/app"],
                failedRootPaths: []
            )
        )
        XCTAssertFalse(
            shouldAutomaticallyOpenMultiRootCommitPushOptions(
                pushAfterCommit: true,
                pushRootPaths: ["/project/app"],
                failedRootPaths: ["/project/lib"]
            )
        )
        XCTAssertFalse(
            shouldAutomaticallyOpenMultiRootCommitPushOptions(
                pushAfterCommit: true,
                pushRootPaths: [],
                failedRootPaths: []
            )
        )
        XCTAssertFalse(
            shouldAutomaticallyOpenMultiRootCommitPushOptions(
                pushAfterCommit: false,
                pushRootPaths: ["/project/app"],
                failedRootPaths: []
            )
        )
    }

    @MainActor
    func testFeedbackHistoryRestoresMultiRootCommitRetryActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterMultiRootCommitRetryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRetryOperation: .commit,
            multiRootRetryRootPaths: ["/project/app"],
            multiRootCommitRetry: PersistedMultiRootCommitRetry(
                message: "retry commit",
                options: MultiRootCommitOptions(
                    skipHooks: false,
                    authorName: nil,
                    authorEmail: nil,
                    committerName: nil,
                    committerEmail: nil,
                    signOff: false,
                    coAuthors: [],
                    amend: false,
                    runBeforeCommitChecks: true,
                    beforeCommitCommands: []
                )
            )
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Multi-root commit partially completed",
            additionalActions: [
                FeedbackAction(
                    title: "Retry Failed Commits",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testFeedbackHistoryRestoresCatastrophicCommitRetryContextAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterCatastrophicCommitRetryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let options = MultiRootCommitOptions(
            skipHooks: true,
            authorName: "Author",
            authorEmail: "author@example.com",
            committerName: nil,
            committerEmail: nil,
            signOff: true,
            coAuthors: [],
            amend: false,
            runBeforeCommitChecks: false,
            beforeCommitCommands: []
        )
        let request = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRetryOperation: .commit,
            multiRootRetryRootPaths: ["/project/app"],
            multiRootCommitRetry: PersistedMultiRootCommitRetry(
                message: "release",
                options: options,
                pushAfterCommit: true,
                pushRootPaths: ["/project/lib"]
            )
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.error(
            "Multi-root commit failed",
            additionalActions: [
                FeedbackAction(
                    title: "Retry Failed Commits",
                    semanticAction: request
                ) {}
            ],
            notificationID: "arbor.multi-root-retry.commit._project",
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.title, "Retry Failed Commits")
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
        XCTAssertEqual(reloaded.history.first?.notificationID, "arbor.multi-root-retry.commit._project")
    }

    @MainActor
    func testFeedbackHistoryRestoresMultiRootCommitPushActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterMultiRootCommitPushTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRetryOperation: .pushAfterCommit,
            multiRootRetryRootPaths: ["/project/app", "/project/lib"]
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.success(
            "Multi-root commit complete",
            additionalActions: [
                FeedbackAction(
                    title: "Push Committed Roots",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.title, "Push Committed Roots")
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testMultiRootCommitPushKeepsFailedCommitRecoveryAlongsidePushNotification() {
        let suiteName = "Arbor.FeedbackCenterMultiRootCommitPushRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let retryRequest = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRetryOperation: .commit,
            multiRootRetryRootPaths: ["/project/lib"]
        )
        let pushRequest = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRetryOperation: .pushAfterCommit,
            multiRootRetryRootPaths: ["/project/app"]
        )
        let commitNotificationID = "arbor.multi-root-retry.commit._project"
        let pushNotificationID = "arbor.multi-root-retry.push._project"
        let feedbackCenter = FeedbackCenter(defaults: defaults)

        feedbackCenter.warning(
            "Multi-root commit partially completed",
            additionalActions: [FeedbackAction(title: "Retry Failed Commits", semanticAction: retryRequest) {}],
            notificationID: commitNotificationID,
            localized: false
        )
        feedbackCenter.success(
            "Multi-root Push completed",
            additionalActions: [FeedbackAction(title: "Push Committed Roots", semanticAction: pushRequest) {}],
            notificationID: pushNotificationID,
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        let commitEntry = reloaded.history.first { $0.notificationID == commitNotificationID }
        let pushEntry = reloaded.history.first { $0.notificationID == pushNotificationID }
        XCTAssertEqual(commitEntry?.actions.first?.title, "Retry Failed Commits")
        XCTAssertEqual(commitEntry?.actions.first?.semanticAction, retryRequest)
        XCTAssertEqual(pushEntry?.actions.first?.title, "Push Committed Roots")
        XCTAssertEqual(pushEntry?.actions.first?.semanticAction, pushRequest)
    }

    @MainActor
    func testCommitRewordActionRoundTripsRootAndHeadAcrossReload() throws {
        let request = ArborVCSActionRequest(
            kind: .rewordCommit,
            projectPath: "/project",
            rootPath: "/project/nested",
            shelfName: "",
            rewordCommitID: "0123456789abcdef"
        )
        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)

        let suiteName = "Arbor.FeedbackCenterCommitRewordTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.success(
            "Commit completed",
            additionalActions: [
                FeedbackAction(
                    title: "Reword Commit",
                    semanticAction: request
                ) {}
            ],
            notificationID: "arbor.commit._project_nested",
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.title, "Reword Commit")
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
        XCTAssertEqual(reloaded.history.first?.notificationID, "arbor.commit._project_nested")
    }

    func testSingleRootPushRecoveryRequestRoundTripsExpectedBranch() throws {
        let recovery = PersistedPushRecovery(
            remote: "origin",
            branch: "feature/login",
            force: false,
            forceWithLease: true,
            setUpstream: true,
            tagModeRaw: PushDialogTagMode.currentBranch.rawValue,
            skipHooks: true,
            rebase: true
        )
        let request = ArborVCSActionRequest(
            kind: .retryPushRecovery,
            projectPath: "/project",
            rootPath: "/project/app",
            shelfName: "",
            pushRecovery: recovery,
            logRevisionRanges: [PersistedLogRevisionRange(
                rootPath: "/project/app",
                oldRevision: "base",
                newRevision: "local-tip"
            )]
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.pushRecovery?.remote, "origin")
        XCTAssertEqual(decoded.pushRecovery?.branch, "feature/login")
        XCTAssertEqual(decoded.pushRecovery?.tagModeRaw, "currentBranch")
        XCTAssertEqual(decoded.pushRecovery?.rebase, true)
        XCTAssertEqual(decoded.logRevisionRanges?.first?.oldRevision, "base")
        XCTAssertEqual(decoded.logRevisionRanges?.first?.newRevision, "local-tip")
    }

    func testSingleRootPushRetryAndShowDetailsRequestsRoundTripAcrossReload() throws {
        let push = PersistedPushRecovery(
            remote: "origin",
            branch: "feature/login",
            force: true,
            forceWithLease: false,
            setUpstream: false,
            refspec: "refs/heads/feature/login:refs/heads/release",
            tagModeRaw: PushDialogTagMode.all.rawValue,
            skipHooks: true,
            rebase: false
        )
        let retry = ArborVCSActionRequest(
            kind: .retryPush,
            projectPath: "/project",
            rootPath: "/project/app",
            shelfName: "",
            pushRecovery: push,
            logRevisionRanges: [PersistedLogRevisionRange(
                rootPath: "/project/app",
                oldRevision: "base",
                newRevision: "local-tip"
            )]
        )
        let details = ArborVCSActionRequest(
            kind: .showOperationDetails,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            operationNotificationID: "arbor.push.v1.project-app"
        )

        let decodedRetry = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(retry)
        )
        let decodedDetails = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(details)
        )

        XCTAssertEqual(decodedRetry, retry)
        XCTAssertEqual(decodedRetry.pushRecovery?.refspec, push.refspec)
        XCTAssertEqual(decodedRetry.pushRecovery?.force, true)
        XCTAssertEqual(decodedDetails, details)
        XCTAssertEqual(decodedDetails.operationNotificationID, "arbor.push.v1.project-app")
    }

    func testDetachedRefspecPushRetryPayloadDoesNotRequireBranch() throws {
        let push = PersistedPushRecovery(
            remote: "origin",
            branch: "",
            force: false,
            forceWithLease: false,
            setUpstream: false,
            refspec: "refs/tags/v1:refs/tags/v1",
            tagModeRaw: nil,
            skipHooks: false,
            rebase: false
        )
        let request = ArborVCSActionRequest(
            kind: .retryPush,
            projectPath: "/project",
            rootPath: "/project/app",
            shelfName: "",
            pushRecovery: push
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.pushRecovery?.branch, "")
        XCTAssertEqual(decoded.pushRecovery?.refspec, push.refspec)
    }

    func testMultiRootPushGroupsRejectionsSeparatelyFromTransportErrors() {
        let rejected = RootOperationResult(
            rootPath: "/project/app",
            displayName: "app",
            success: false,
            skipped: false,
            message: "push rejected for origin/main: non-fast-forward"
        )
        let stale = RootOperationResult(
            rootPath: "/project/lib",
            displayName: "lib",
            success: false,
            skipped: false,
            message: "push rejected: stale info"
        )
        let authentication = RootOperationResult(
            rootPath: "/project/auth",
            displayName: "auth",
            success: false,
            skipped: false,
            message: "push rejected: authentication failed"
        )

        XCTAssertTrue(pushResultIsRejected(rejected))
        XCTAssertTrue(pushResultIsRejected(stale))
        XCTAssertFalse(pushResultIsRejected(authentication))
    }

    @MainActor
    func testPushAllRecoveryActionsStayOnTheOriginalNotification() {
        let suiteName = "Arbor.FeedbackCenterPushAllRecoveryNotificationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notificationID = "arbor.multi-root-retry.push./project"
        let feedbackCenter = FeedbackCenter(defaults: defaults)

        feedbackCenter.begin("Push All", notificationID: notificationID)
        feedbackCenter.warning(
            "Multi-root Push partially completed",
            detail: "root-a: non-fast-forward",
            additionalActions: [FeedbackAction(title: "Update with Merge") {}],
            notificationID: notificationID,
            localized: false
        )

        XCTAssertEqual(feedbackCenter.history.count, 1)
        XCTAssertEqual(feedbackCenter.history.first?.title, "Multi-root Push partially completed")
        XCTAssertEqual(feedbackCenter.history.first?.notificationID, notificationID)
    }

    @MainActor
    func testFeedbackHistoryRestoresPushRecoveryViewCommitsActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterPushRecoveryLogTests.\(UUID().uuidString)"
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
                    oldRevision: "push-before",
                    newRevision: "push-after"
                )
            ]
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.success(
            "Update Push Roots completed",
            detail: "App updated and pushed",
            additionalActions: [
                FeedbackAction(title: "View Commits", semanticAction: request) {}
            ],
            notificationID: "git.multi-root.push.recovery",
            notificationGroup: .standard,
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.notificationID, "git.multi-root.push.recovery")
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testFeedbackHistoryRestoresRootPushRecoveryViewCommitsActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterRootPushRecoveryLogTests.\(UUID().uuidString)"
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
                    oldRevision: "update-before",
                    newRevision: "update-after"
                )
            ]
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.success(
            "Push completed",
            detail: "origin/main · /project/app",
            additionalActions: [
                FeedbackAction(title: "View Commits", semanticAction: request) {}
            ],
            notificationID: "arbor.push.v1.root-app",
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.notificationID, "arbor.push.v1.root-app")
        XCTAssertEqual(reloaded.history.first?.actions.first?.title, "View Commits")
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }
}
