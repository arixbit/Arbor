import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {

    @MainActor
    func testSubmoduleUpdateUndoActionKeepsItsDedicatedRecoveryKind() throws {
        let request = ArborVCSActionRequest(
            kind: .rollbackSubmoduleUpdate,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootUpdateRollbackTargets: [
                PersistedMultiRootUpdateRollbackTarget(
                    rootPath: "/project/vendor/lib",
                    displayName: "lib",
                    initialHead: "child-old",
                    expectedHead: "child-new",
                    expectedHeadBranch: ""
                )
            ]
        )
        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.kind, .rollbackSubmoduleUpdate)
        XCTAssertEqual(decoded.multiRootUpdateRollbackTargets?.count, 1)
    }

    func testSubmoduleRetryActionRequestRoundTripsCompleteOperationContext() throws {
        let retry = PersistedSubmoduleRetry(
            operation: .update,
            url: "https://example.com/lib.git",
            path: "vendor/lib",
            branch: "main",
            force: true,
            initFlag: true,
            recursive: true,
            remote: true
        )
        let request = ArborVCSActionRequest(
            kind: .retrySubmoduleOperation,
            projectPath: "/project",
            rootPath: "/project",
            shelfName: "",
            submoduleRetry: retry
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.submoduleRetry, retry)
        XCTAssertEqual(decoded.submoduleRetry?.operation, .update)
        XCTAssertEqual(decoded.submoduleRetry?.path, "vendor/lib")
        XCTAssertEqual(decoded.submoduleRetry?.recursive, true)
    }

    func testSubmoduleSyncRetryRequestRetainsTheSyncOperation() throws {
        let retry = PersistedSubmoduleRetry(operation: .sync)
        let request = ArborVCSActionRequest(
            kind: .retrySubmoduleOperation,
            projectPath: "/project",
            rootPath: "/project",
            shelfName: "",
            submoduleRetry: retry
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded.submoduleRetry?.operation, .sync)
        XCTAssertNil(decoded.submoduleRetry?.path)
    }

    func testSubmoduleDeinitUndoRequiresExpectedCleanStateAndRoundTrips() throws {
        let before = [
            SubmoduleInfo(
                path: "vendor/lib",
                headId: "child-head",
                state: .clean,
                branch: nil,
                dirty: false
            )
        ]
        let context = try XCTUnwrap(
            ContentView.submoduleDeinitUndoContext(
                path: "./vendor/lib",
                before: before,
                gitmodulesPresent: true,
                gitmodulesContents: "[submodule \"vendor/lib\"]\n"
            )
        )
        XCTAssertEqual(context.path, "vendor/lib")
        XCTAssertEqual(context.expectedHeadID, "child-head")

        let afterDeinit = [
            SubmoduleInfo(
                path: "vendor/lib",
                headId: "child-head",
                state: .uninitialized,
                branch: nil,
                dirty: false
            )
        ]
        XCTAssertNotNil(
            ContentView.submoduleDeinitUndoTargetAfterDeinit(
                context,
                modules: afterDeinit,
                gitmodulesPresent: true,
                gitmodulesContents: "[submodule \"vendor/lib\"]\n"
            )
        )
        XCTAssertNil(
            ContentView.submoduleDeinitUndoTargetAfterDeinit(
                context,
                modules: afterDeinit,
                gitmodulesPresent: true,
                gitmodulesContents: "changed"
            )
        )

        let restored = [
            SubmoduleInfo(
                path: "vendor/lib",
                headId: "child-head",
                state: .clean,
                branch: nil,
                dirty: false
            )
        ]
        XCTAssertTrue(
            ContentView.submoduleDeinitUndoTargetAfterRestore(
                context,
                modules: restored,
                gitmodulesPresent: true,
                gitmodulesContents: "[submodule \"vendor/lib\"]\n"
            )
        )

        let request = ArborVCSActionRequest(
            kind: .undoSubmoduleOperation,
            projectPath: "/project",
            rootPath: "/project",
            shelfName: "",
            submoduleUndo: context
        )
        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.submoduleUndo, context)
    }

    func testSubmoduleDeinitUndoIsNotProposedForDirtyBeforeState() {
        let dirty = [
            SubmoduleInfo(
                path: "vendor/lib",
                headId: "child-head",
                state: .clean,
                branch: nil,
                dirty: true
            )
        ]
        XCTAssertNil(
            ContentView.submoduleDeinitUndoContext(
                path: "vendor/lib",
                before: dirty,
                gitmodulesPresent: true,
                gitmodulesContents: "same"
            )
        )
    }

    func testSubmoduleAddUndoPersistsExpectedStateAndRejectsOccupiedPath() throws {
        let seed = try XCTUnwrap(
            ContentView.submoduleAddUndoSeed(
                path: "./vendor/lib",
                before: [],
                parentHeadID: "parent-head",
                gitmodulesPresent: false,
                gitmodulesContents: nil,
                pathExists: false
            )
        )
        let added = SubmoduleInfo(
            path: "vendor/lib",
            headId: "child-head",
            state: .clean,
            branch: nil,
            dirty: false
        )
        let context = try XCTUnwrap(
            ContentView.submoduleAddUndoContext(
                seed,
                module: added,
                gitmodulesPresent: true,
                gitmodulesContents: "[submodule \"vendor/lib\"]\n"
            )
        )
        XCTAssertEqual(context.operation, .add)
        XCTAssertEqual(context.expectedParentHeadID, "parent-head")
        XCTAssertEqual(context.restoreGitmodulesPresent, false)

        let request = ArborVCSActionRequest(
            kind: .undoSubmoduleOperation,
            projectPath: "/project",
            rootPath: "/project",
            shelfName: "",
            submoduleUndo: context
        )
        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)
        XCTAssertNil(
            ContentView.submoduleAddUndoSeed(
                path: "vendor/lib",
                before: [],
                parentHeadID: "parent-head",
                gitmodulesPresent: false,
                gitmodulesContents: nil,
                pathExists: true
            )
        )
        XCTAssertNil(
            ContentView.submoduleAddUndoContext(
                seed,
                module: SubmoduleInfo(
                    path: "vendor/lib",
                    headId: "child-head",
                    state: .clean,
                    branch: nil,
                    dirty: true
                ),
                gitmodulesPresent: true,
                gitmodulesContents: "[submodule \"vendor/lib\"]\n"
            )
        )
    }

    func testSubmoduleRemoveUndoPersistsCompareAndSwapStateAndLegacyDeinitPayloads() throws {
        let seed = ContentView.SubmoduleRemoveUndoSeed(
            path: "vendor/lib",
            parentHeadID: "parent-head",
            gitlinkID: "child-head",
            gitmodulesPresent: true,
            gitmodulesContents: "[submodule \"vendor/lib\"]\npath = vendor/lib\n"
        )
        let context = try XCTUnwrap(
            ContentView.submoduleRemoveUndoContextAfterRemove(
                seed,
                gitmodulesPresent: true,
                gitmodulesContents: ""
            )
        )
        XCTAssertEqual(context.operation, .remove)
        XCTAssertEqual(context.path, "vendor/lib")
        XCTAssertEqual(context.expectedHeadID, "child-head")
        XCTAssertEqual(context.expectedParentHeadID, "parent-head")
        XCTAssertEqual(context.expectedGitmodulesContents, "")
        XCTAssertEqual(context.restoreGitmodulesContents, seed.gitmodulesContents)

        let request = ArborVCSActionRequest(
            kind: .undoSubmoduleOperation,
            projectPath: "/project",
            rootPath: "/project",
            shelfName: "",
            submoduleUndo: context
        )
        let decodedRequest = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decodedRequest, request)

        let legacy = PersistedSubmoduleUndo(
            operation: .deinitialize,
            path: "vendor/lib",
            expectedHeadID: "child-head",
            expectedGitmodulesPresent: true,
            expectedGitmodulesContents: seed.gitmodulesContents
        )
        let decodedLegacy = try JSONDecoder().decode(
            PersistedSubmoduleUndo.self,
            from: JSONEncoder().encode(legacy)
        )
        XCTAssertEqual(decodedLegacy, legacy)
        XCTAssertNil(decodedLegacy.expectedParentHeadID)
        XCTAssertNil(decodedLegacy.restoreGitmodulesPresent)
        XCTAssertNil(decodedLegacy.restoreGitmodulesContents)
    }

    func testUpdateRootRecoveryTargetsStayRootQualifiedAndSkipSubmodules() {
        let results = [
            RootOperationResult(
                rootPath: "/workspace/app",
                displayName: "app",
                success: true,
                skipped: true,
                message: "no configured upstream"
            ),
            RootOperationResult(
                rootPath: "/workspace/vendor/lib",
                displayName: "lib",
                success: true,
                skipped: true,
                message: "detached HEAD"
            ),
            RootOperationResult(
                rootPath: "/workspace/docs",
                displayName: "docs",
                success: true,
                skipped: true,
                message: "detached HEAD"
            )
        ]
        let roots = [
            ContentView.UpdateRootRecoveryRoot(
                path: "/workspace/app",
                displayName: "app",
                isSubmodule: false,
                headBranch: "main"
            ),
            ContentView.UpdateRootRecoveryRoot(
                path: "/workspace/vendor/lib",
                displayName: "lib",
                isSubmodule: true,
                headBranch: nil
            ),
            ContentView.UpdateRootRecoveryRoot(
                path: "/workspace/docs",
                displayName: "docs",
                isSubmodule: false,
                headBranch: nil
            )
        ]

        let targets = ContentView.updateRootRecoveryTargets(results: results, roots: roots)

        XCTAssertEqual(targets, [
            ContentView.UpdateRootRecoveryTarget(
                kind: .chooseUpstream,
                rootPath: "/workspace/app",
                displayName: "app",
                branch: "main"
            ),
            ContentView.UpdateRootRecoveryTarget(
                kind: .openBranches,
                rootPath: "/workspace/docs",
                displayName: "docs",
                branch: nil
            )
        ])
    }

    func testCloneRecursiveSubmodulesSettingDefaultsOnAndPersists() {
        let suiteName = "Arbor.CloneSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(GitCloneSettings.recurseSubmodules(from: defaults))
        GitCloneSettings.saveRecurseSubmodules(false, defaults: defaults)
        XCTAssertFalse(GitCloneSettings.recurseSubmodules(from: defaults))
        GitCloneSettings.saveRecurseSubmodules(true, defaults: defaults)
        XCTAssertTrue(GitCloneSettings.recurseSubmodules(from: defaults))
    }

    func testMultiRootUpdateGroupsSubmoduleFailureAndDependentSkip() {
        let results = [
            RootOperationResult(
                rootPath: "/workspace/project",
                displayName: "project",
                success: false,
                skipped: false,
                message: "parent update failed"
            ),
            RootOperationResult(
                rootPath: "/workspace/project/vendor/lib",
                displayName: "lib",
                success: true,
                skipped: true,
                message: "detached submodule parent update did not complete"
            ),
            RootOperationResult(
                rootPath: "/workspace/independent",
                displayName: "independent",
                success: false,
                skipped: false,
                message: "remote unavailable"
            )
        ]

        XCTAssertEqual(
            ContentView.multiRootUpdateFailureDetails(
                results,
                submoduleRootPaths: ["/workspace/project/vendor/lib"]
            ),
            [
                "independent: remote unavailable",
                "project: parent update failed",
                "  lib: detached submodule parent update did not complete"
            ]
        )
    }

    func testStandaloneSubmoduleUpdateBuildsOnlyMovedChildUndoTargets() {
        let before = [
            GitRootInfo(
                path: "/workspace/project",
                displayName: "project",
                relativePath: ".",
                isSubmodule: false,
                headBranch: "main",
                headId: "parent",
                dirty: false,
                operation: nil
            ),
            GitRootInfo(
                path: "/workspace/project/vendor/lib",
                displayName: "lib",
                relativePath: "vendor/lib",
                isSubmodule: true,
                headBranch: nil,
                headId: "child-old",
                dirty: false,
                operation: nil
            )
        ]
        let after = [
            before[0],
            GitRootInfo(
                path: "/workspace/project/vendor/lib",
                displayName: "lib",
                relativePath: "vendor/lib",
                isSubmodule: true,
                headBranch: nil,
                headId: "child-new",
                dirty: false,
                operation: nil
            )
        ]

        let targets = ContentView.submoduleUpdateRollbackTargets(before: before, after: after)

        XCTAssertEqual(targets.map(\.rootPath), ["/workspace/project/vendor/lib"])
        XCTAssertEqual(targets.map(\.initialHead), ["child-old"])
        XCTAssertEqual(targets.map(\.expectedHead), ["child-new"])
        XCTAssertEqual(targets.map { $0.expectedHeadBranch ?? "<missing>" }, [""])
        XCTAssertEqual(targets.map(\.ignoredPaths), [[]])
    }
}
