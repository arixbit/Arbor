import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {

    func testRebaseUndoTargetAfterContinueKeepsExpectedHeadSafetyBoundary() {
        let seed = RebaseUndoSeed(
            repositoryPath: "/project/app",
            branch: "feature",
            initialHead: "1111111",
            updateRefs: false,
            protectionCommitID: "first-changed"
        )

        let target = rebaseUndoTargetAfterCompletion(
            seed: seed,
            currentBranch: "feature",
            finalHead: "2222222"
        )
        XCTAssertEqual(target?.initialHead, "1111111")
        XCTAssertEqual(target?.expectedHead, "2222222")
        XCTAssertEqual(target?.protectionCommitID, "first-changed")
        XCTAssertNil(rebaseUndoTargetAfterCompletion(seed: seed, currentBranch: "other", finalHead: "2222222"))
        XCTAssertNil(rebaseUndoTargetAfterCompletion(seed: seed, currentBranch: "feature", finalHead: "1111111"))
        XCTAssertNil(rebaseUndoTargetAfterCompletion(
            seed: RebaseUndoSeed(
                repositoryPath: "/project/app",
                branch: "feature",
                initialHead: "1111111",
                updateRefs: true
            ),
            currentBranch: "feature",
            finalHead: "2222222"
        ))
    }

    func testRebaseUndoTargetSupportsDetachedHeadIdentity() {
        let seed = RebaseUndoSeed(
            repositoryPath: "/project/app",
            branch: "",
            initialHead: "1111111",
            updateRefs: false
        )

        let target = rebaseUndoTargetAfterCompletion(
            seed: seed,
            currentBranch: nil,
            finalHead: "2222222"
        )

        XCTAssertEqual(target?.branch, "")
        XCTAssertEqual(target?.initialHead, "1111111")
        XCTAssertEqual(target?.expectedHead, "2222222")
    }

    func testRebaseUndoSeedCodableRoundTripsRecoveryBoundary() throws {
        let seed = RebaseUndoSeed(
            repositoryPath: "/project/app",
            branch: "feature",
            initialHead: "1111111",
            updateRefs: false,
            protectionCommitID: "first-changed"
        )

        let decoded = try JSONDecoder().decode(
            RebaseUndoSeed.self,
            from: JSONEncoder().encode(seed)
        )

        XCTAssertEqual(decoded, seed)

        let legacy = Data(
            #"{"repositoryPath":"/project/app","branch":"feature","initialHead":"1111111","updateRefs":false}"#.utf8
        )
        XCTAssertNil(try JSONDecoder().decode(RebaseUndoSeed.self, from: legacy).protectionCommitID)
    }

    func testRebaseUndoBlocksPublishedProtectedRemoteHistory() {
        let remoteBranches = [
            RemoteBranchInfo(name: "origin/main", remote: "origin", shortId: "1111111"),
            RemoteBranchInfo(name: "origin/feature", remote: "origin", shortId: "2222222")
        ]

        XCTAssertEqual(
            ContentView.protectedRemoteBranchNameContainingCommit(
                commitID: "1111111",
                remoteBranches: remoteBranches,
                protectedPatterns: ["main"],
                isReachable: { commitID, branchName in
                    commitID == "1111111" && branchName == "origin/main"
                }
            ),
            "origin/main"
        )
        XCTAssertNil(
            ContentView.protectedRemoteBranchNameContainingCommit(
                commitID: "1111111",
                remoteBranches: remoteBranches,
                protectedPatterns: ["main"],
                isReachable: { _, _ in false }
            )
        )
        XCTAssertNil(
            ContentView.protectedRemoteBranchNameContainingCommit(
                commitID: "1111111",
                remoteBranches: remoteBranches,
                protectedPatterns: ["release"],
                isReachable: { _, _ in true }
            )
        )
    }

    func testDropUndoTargetAndSemanticActionRoundTripAcrossPersistence() throws {
        let target = RebaseUndoTarget(
            repositoryPath: "/project/app",
            branch: "feature",
            initialHead: "1111111",
            expectedHead: "2222222",
            protectionCommitID: "first-changed"
        )
        let request = ArborVCSActionRequest(
            kind: .undoRebase,
            projectPath: "/project",
            rootPath: target.repositoryPath,
            shelfName: "",
            rebaseUndoInitialHead: target.initialHead,
            rebaseUndoExpectedHead: target.expectedHead,
            rebaseUndoBranch: target.branch,
            rebaseUndoProtectionCommit: target.protectionCommitID
        )

        XCTAssertEqual(
            try JSONDecoder().decode(RebaseUndoTarget.self, from: JSONEncoder().encode(target)),
            target
        )
        XCTAssertEqual(
            try JSONDecoder().decode(ArborVCSActionRequest.self, from: JSONEncoder().encode(request)),
            request
        )
    }

    func testSelectedChangesUndoTargetAndSemanticActionRoundTripAcrossPersistence() throws {
        let target = LogSelectedChangesUndoTarget(
            repositoryPath: "/project/app",
            branch: "feature",
            initialHead: "1111111",
            expectedHead: "2222222"
        )
        let request = ArborVCSActionRequest(
            kind: .undoLogSelectedChanges,
            projectPath: "/project",
            rootPath: target.repositoryPath,
            shelfName: "",
            logSelectedChangesUndoInitialHead: target.initialHead,
            logSelectedChangesUndoExpectedHead: target.expectedHead,
            logSelectedChangesUndoBranch: target.branch
        )

        XCTAssertEqual(
            try JSONDecoder().decode(
                LogSelectedChangesUndoTarget.self,
                from: JSONEncoder().encode(target)
            ),
            target
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                ArborVCSActionRequest.self,
                from: JSONEncoder().encode(request)
            ),
            request
        )
    }

    func testRebaseUndoSemanticActionRemainsRootScopedAcrossReload() throws {
        func request(rootPath: String) -> ArborVCSActionRequest {
            ArborVCSActionRequest(
                kind: .undoRebase,
                projectPath: "/project",
                rootPath: rootPath,
                shelfName: "",
                rebaseUndoInitialHead: "1111111",
                rebaseUndoExpectedHead: "2222222",
                rebaseUndoBranch: "feature",
                rebaseUndoProtectionCommit: "first-changed"
            )
        }

        let first = request(rootPath: "/project/app")
        let sameRootAfterReload = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(first)
        )
        let otherRoot = request(rootPath: "/project/lib")

        XCTAssertEqual(sameRootAfterReload, first)
        XCTAssertNotEqual(first, otherRoot)
    }

    func testRewordUndoPersistsExpectedHeadAndDetachedBranchState() throws {
        let attached = PersistedRewordUndo(
            initialHeadID: "old-head",
            expectedHeadID: "reworded-head",
            expectedBranch: "main"
        )
        let request = ArborVCSActionRequest(
            kind: .undoRewordCommit,
            projectPath: "/project",
            rootPath: "/project",
            shelfName: "",
            rewordUndo: attached
        )
        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.rewordUndo, attached)

        let detached = PersistedRewordUndo(
            initialHeadID: "old-head",
            expectedHeadID: "reworded-head",
            expectedBranch: ""
        )
        XCTAssertNotEqual(attached, detached)
        XCTAssertEqual(detached.expectedBranch, "")
    }

    func testMultiRootRebaseRecoveryActionRequestsRoundTripAllRecoveryModes() throws {
        let rollbackTarget = PersistedMultiRootRebaseRollbackTarget(
            MultiRootRebaseRollbackTarget(
                rootPath: "/project/app",
                displayName: "app",
                initialHead: "1111111",
                expectedHead: "2222222",
                branch: "feature",
                protectionCommitID: "first-changed"
            )
        )
        let sessionID = UUID().uuidString
        for action in [
            ArborVCSActionRequest.MultiRootRebaseRecoveryAction.resume,
            .retry,
            .stageAndRetry,
            .openRecovery,
            .rollback,
            .keepPartial,
            .undo
        ] {
            let request = ArborVCSActionRequest(
                kind: .multiRootRebaseRecovery,
                projectPath: "/project",
                rootPath: action == .openRecovery || action == .stageAndRetry ? "/project/app" : nil,
                shelfName: "",
                multiRootRebaseRecoveryAction: action,
                multiRootRebaseSessionID: action == .undo ? nil : sessionID,
                multiRootRebaseRollbackTargets: action == .undo ? [rollbackTarget] : nil
            )

            let decoded = try JSONDecoder().decode(
                ArborVCSActionRequest.self,
                from: JSONEncoder().encode(request)
            )

            XCTAssertEqual(decoded, request)
            XCTAssertEqual(decoded.multiRootRebaseRecoveryAction, action)
            XCTAssertEqual(decoded.multiRootRebaseSessionID, request.multiRootRebaseSessionID)
            XCTAssertEqual(decoded.multiRootRebaseRollbackTargets, request.multiRootRebaseRollbackTargets)
        }
    }

    @MainActor
    func testFeedbackHistoryRestoresMultiRootRebaseRecoveryActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterMultiRootRebaseTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .multiRootRebaseRecovery,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRebaseRecoveryAction: .undo,
            multiRootRebaseRollbackTargets: [
                PersistedMultiRootRebaseRollbackTarget(
                    MultiRootRebaseRollbackTarget(
                        rootPath: "/project/app",
                        displayName: "app",
                        initialHead: "1111111",
                        expectedHead: "2222222",
                        branch: "feature"
                    )
                )
            ]
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Multi-root rebase recovery available",
            additionalActions: [
                FeedbackAction(
                    title: "Undo Rebase",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testFeedbackHistoryRestoresMultiRootRebaseStageAndRetryActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterMultiRootRebaseStageRetryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .multiRootRebaseRecovery,
            projectPath: "/project",
            rootPath: "/project/app",
            shelfName: "",
            multiRootRebaseRecoveryAction: .stageAndRetry,
            multiRootRebaseSessionID: UUID().uuidString
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.error(
            "Multi-root recovery failed",
            additionalActions: [
                FeedbackAction(
                    title: "Stage-and-Retry",
                    semanticAction: request
                ) {}
            ],
            notificationID: "arbor.multi-root-rebase.stage-retry",
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    func testRebaseRecoveryActionRequestRoundTripsBranchContext() throws {
        let request = ArborVCSActionRequest(
            kind: .resumeRebase,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "",
            rebaseBranch: "feature"
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.rebaseBranch, "feature")
    }
}
