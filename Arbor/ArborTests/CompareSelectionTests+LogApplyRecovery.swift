import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {

    func testLogApplyRecoveryActionRequestRoundTripsRootAndHeadGuard() throws {
        let recovery = PersistedLogApplyRecovery(
            operation: .cherryPick,
            rootPath: "/project/app",
            commitIDs: ["older", "newer"],
            sessionID: "log-session",
            batchIndex: 0,
            batchCount: 1,
            initialHead: "head-before-retry",
            preserveLocalChanges: true,
            emptyPolicyRaw: "createEmpty",
            appendPublishedSuffix: true,
            savePolicyRaw: "shelve"
        )
        let request = ArborVCSActionRequest(
            kind: .retryLogApply,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "",
            logApplyRecovery: recovery
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ArborVCSActionRequest.self, from: data)

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.logApplyRecovery?.commitIDs, ["older", "newer"])
        XCTAssertEqual(decoded.logApplyRecovery?.initialHead, "head-before-retry")
        XCTAssertEqual(decoded.logApplyRecovery?.operation, .cherryPick)
        XCTAssertEqual(decoded.logApplyRecovery?.affectedPaths, [])
    }

    func testLogApplyRecoverySaveAndRetryContextPreservesGuardsAndAffectedPaths() {
        let direct = PersistedLogApplyRecovery(
            operation: .revert,
            rootPath: "/project/app",
            commitIDs: ["commit"],
            sessionID: "session",
            batchIndex: 0,
            batchCount: 1,
            initialHead: "head-before-retry",
            preserveLocalChanges: false,
            emptyPolicyRaw: "skip",
            appendPublishedSuffix: false,
            savePolicyRaw: "shelve"
        )

        let saveAndRetry = direct.updating(
            preserveLocalChanges: true,
            affectedPaths: ["Sources/App.swift", "Resources/Info.plist"]
        )

        XCTAssertEqual(saveAndRetry.operation, direct.operation)
        XCTAssertEqual(saveAndRetry.rootPath, direct.rootPath)
        XCTAssertEqual(saveAndRetry.commitIDs, direct.commitIDs)
        XCTAssertEqual(saveAndRetry.sessionID, direct.sessionID)
        XCTAssertEqual(saveAndRetry.batchIndex, direct.batchIndex)
        XCTAssertEqual(saveAndRetry.batchCount, direct.batchCount)
        XCTAssertEqual(saveAndRetry.initialHead, direct.initialHead)
        XCTAssertEqual(saveAndRetry.emptyPolicyRaw, direct.emptyPolicyRaw)
        XCTAssertEqual(saveAndRetry.appendPublishedSuffix, direct.appendPublishedSuffix)
        XCTAssertEqual(saveAndRetry.savePolicyRaw, direct.savePolicyRaw)
        XCTAssertTrue(saveAndRetry.preserveLocalChanges)
        XCTAssertEqual(saveAndRetry.affectedPaths, ["Sources/App.swift", "Resources/Info.plist"])
        XCTAssertEqual(logApplyRecoveryActionTitle(direct), "Retry Revert")
        XCTAssertEqual(logApplyRecoveryActionTitle(saveAndRetry), "Save and Retry Revert (Shelf)")
    }

    func testLogApplyShowFilesActionRequestRoundTripsAffectedPaths() throws {
        let recovery = PersistedLogApplyRecovery(
            operation: .cherryPick,
            rootPath: "/project/app",
            commitIDs: ["commit"],
            sessionID: "session",
            batchIndex: 0,
            batchCount: 1,
            initialHead: "head-before-retry",
            preserveLocalChanges: true,
            emptyPolicyRaw: "skip",
            appendPublishedSuffix: false,
            savePolicyRaw: "stash",
            affectedPaths: ["Sources/App.swift"]
        )
        let request = ArborVCSActionRequest(
            kind: .showLogApplyAffectedFiles,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "",
            logApplyRecovery: recovery
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.kind, .showLogApplyAffectedFiles)
        XCTAssertEqual(decoded.logApplyRecovery?.affectedPaths, ["Sources/App.swift"])
    }

    func testLegacyLogApplyRecoveryPayloadDefaultsToSingleRootSession() throws {
        let legacyPayload = #"""
        {
            "operation": "revert",
            "rootPath": "/project/app",
            "commitIDs": ["commit"],
            "initialHead": "head-before-retry",
            "preserveLocalChanges": false,
            "emptyPolicyRaw": "skip",
            "appendPublishedSuffix": false,
            "savePolicyRaw": "stash"
        }
        """#.data(using: .utf8)!

        let recovery = try JSONDecoder().decode(
            PersistedLogApplyRecovery.self,
            from: legacyPayload
        )

        XCTAssertEqual(recovery.sessionID, "legacy:/project/app")
        XCTAssertEqual(recovery.batchIndex, 0)
        XCTAssertEqual(recovery.batchCount, 1)
        XCTAssertEqual(recovery.commitIDs, ["commit"])
    }

    func testLogApplyRecoveryOnlyRunsTheEarliestPendingRoot() {
        let first = PersistedLogApplyRecovery(
            operation: .revert,
            rootPath: "/project/one",
            commitIDs: ["one"],
            sessionID: "ordered-session",
            batchIndex: 0,
            batchCount: 2,
            initialHead: "head-one",
            preserveLocalChanges: false,
            emptyPolicyRaw: "skip",
            appendPublishedSuffix: false,
            savePolicyRaw: "stash"
        )
        let second = PersistedLogApplyRecovery(
            operation: .revert,
            rootPath: "/project/two",
            commitIDs: ["two"],
            sessionID: "ordered-session",
            batchIndex: 1,
            batchCount: 2,
            initialHead: "head-two",
            preserveLocalChanges: false,
            emptyPolicyRaw: "skip",
            appendPublishedSuffix: false,
            savePolicyRaw: "stash"
        )

        XCTAssertTrue(logApplyRecoveryCanRun(first, pending: [second, first]))
        XCTAssertFalse(logApplyRecoveryCanRun(second, pending: [first, second]))
    }

    func testAbortingLogApplyCancelsEveryPendingRootInTheSession() {
        let first = PersistedLogApplyRecovery(
            operation: .cherryPick,
            rootPath: "/project/one",
            commitIDs: ["one"],
            sessionID: "cancelled-session",
            batchIndex: 0,
            batchCount: 2,
            initialHead: "head-one",
            preserveLocalChanges: false,
            emptyPolicyRaw: "skip",
            appendPublishedSuffix: false,
            savePolicyRaw: "stash"
        )
        let second = PersistedLogApplyRecovery(
            operation: .cherryPick,
            rootPath: "/project/two",
            commitIDs: ["two"],
            sessionID: "cancelled-session",
            batchIndex: 1,
            batchCount: 2,
            initialHead: "head-two",
            preserveLocalChanges: false,
            emptyPolicyRaw: "skip",
            appendPublishedSuffix: false,
            savePolicyRaw: "stash"
        )
        let unrelated = PersistedLogApplyRecovery(
            operation: .cherryPick,
            rootPath: "/project/other",
            commitIDs: ["other"],
            sessionID: "other-session",
            batchIndex: 0,
            batchCount: 1,
            initialHead: "other-head",
            preserveLocalChanges: false,
            emptyPolicyRaw: "skip",
            appendPublishedSuffix: false,
            savePolicyRaw: "stash"
        )

        let targets = logApplyRecoveryCancellationTargets(
            current: first,
            pending: [unrelated, second, first]
        )

        XCTAssertEqual(targets.map(\.rootPath), ["/project/one", "/project/two"])
        XCTAssertEqual(targets.map(\.batchIndex), [0, 1])
    }
}
