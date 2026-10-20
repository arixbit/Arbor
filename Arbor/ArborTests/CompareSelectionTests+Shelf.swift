import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {

    func testShelfActionRootGuardFailsClosedForInactiveRoots() {
        XCTAssertTrue(
            shelfActionRootMatchesCurrentRoot(
                requestedRootPath: nil,
                currentRootPath: nil
            )
        )
        XCTAssertTrue(
            shelfActionRootMatchesCurrentRoot(
                requestedRootPath: "/workspace/repo/.",
                currentRootPath: "/workspace/repo"
            )
        )
        XCTAssertFalse(
            shelfActionRootMatchesCurrentRoot(
                requestedRootPath: "/workspace/other",
                currentRootPath: "/workspace/repo"
            )
        )
        XCTAssertFalse(
            shelfActionRootMatchesCurrentRoot(
                requestedRootPath: "/workspace/repo",
                currentRootPath: nil
            )
        )
    }

    func testShelfRootSelectionKeepsPrimaryAndSecondaryBoundaries() {
        XCTAssertTrue(
            shelfRootSelectionIsPrimary(
                selectedRootPath: nil,
                primaryRootPath: "/workspace/repo"
            )
        )
        XCTAssertTrue(
            shelfRootSelectionIsPrimary(
                selectedRootPath: "/workspace/repo/.",
                primaryRootPath: "/workspace/repo"
            )
        )
        XCTAssertFalse(
            shelfRootSelectionIsPrimary(
                selectedRootPath: "/workspace/other",
                primaryRootPath: "/workspace/repo"
            )
        )
        XCTAssertFalse(
            shelfRootSelectionIsPrimary(
                selectedRootPath: "/workspace/other",
                primaryRootPath: nil
            )
        )
    }

    func testShelfRootSnapshotCarriesItsOwnChangeLists() {
        let lists = [
            ChangeListInfo(
                name: "Secondary Work",
                paths: ["Sources/Secondary.swift"],
                isDefault: false,
                isActive: true
            )
        ]
        let snapshot = ShelfRootSnapshot(
            rootPath: "/workspace/secondary",
            shelves: [],
            deletedShelves: [],
            changeLists: lists
        )

        XCTAssertEqual(snapshot.rootPath, "/workspace/secondary")
        XCTAssertEqual(snapshot.changeLists.map(\.name), ["Secondary Work"])
        XCTAssertEqual(snapshot.changeLists.first?.paths, ["Sources/Secondary.swift"])
    }

    func testSecondaryShelfSnapshotRefreshRequiresItsOwnGitMetadataEvent() {
        XCTAssertTrue(
            shouldRefreshSecondaryShelfSnapshot(
                eventRootPath: "/workspace/secondary/.",
                activeRootPath: "/workspace/secondary",
                primaryRootPath: "/workspace/repo",
                scopes: .gitMetadata
            )
        )
        XCTAssertFalse(
            shouldRefreshSecondaryShelfSnapshot(
                eventRootPath: "/workspace/secondary",
                activeRootPath: "/workspace/secondary",
                primaryRootPath: "/workspace/repo",
                scopes: .worktree
            )
        )
        XCTAssertFalse(
            shouldRefreshSecondaryShelfSnapshot(
                eventRootPath: "/workspace/repo",
                activeRootPath: "/workspace/secondary",
                primaryRootPath: "/workspace/repo",
                scopes: .gitMetadata
            )
        )
        XCTAssertFalse(
            shouldRefreshSecondaryShelfSnapshot(
                eventRootPath: "/workspace/repo",
                activeRootPath: nil,
                primaryRootPath: "/workspace/repo",
                scopes: .gitMetadata
            )
        )
    }

    func testShelfNotificationIDsRemainRootScoped() {
        let primary = shelfNotificationID(
            prefix: "shelf-lifecycle.restoreDeleted",
            rootPath: "/workspace/repo"
        )
        let secondary = shelfNotificationID(
            prefix: "shelf-lifecycle.restoreDeleted",
            rootPath: "/workspace/other"
        )

        XCTAssertNotEqual(primary, secondary)
        XCTAssertEqual(
            primary,
            "arbor.shelf-lifecycle.restoreDeleted._workspace_repo"
        )
        XCTAssertEqual(
            secondary,
            "arbor.shelf-lifecycle.restoreDeleted._workspace_other"
        )
    }

    func testShelfMetadataNotificationIDsRemainDistinctPerOperationAndRoot() {
        let operations = ["import", "export", "clean"]
        let ids = operations.map {
            shelfNotificationID(
                prefix: "shelf-metadata.\($0)",
                rootPath: "/workspace/secondary"
            )
        }

        XCTAssertEqual(Set(ids).count, operations.count)
        XCTAssertTrue(ids.allSatisfy { $0.contains("_workspace_secondary") })
    }

    func testShelfViewSettingsAreProjectScoped() {
        let suiteName = "Arbor.ShelfViewSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstProject = "/workspace/one"
        let secondProject = "/workspace/two"

        XCTAssertFalse(ShelfViewSettings.showRecycled(for: firstProject, defaults: defaults))
        XCTAssertFalse(ShelfViewSettings.showRecycled(for: secondProject, defaults: defaults))

        ShelfViewSettings.saveShowRecycled(true, for: firstProject, defaults: defaults)

        XCTAssertTrue(ShelfViewSettings.showRecycled(for: firstProject, defaults: defaults))
        XCTAssertFalse(ShelfViewSettings.showRecycled(for: secondProject, defaults: defaults))

        ShelfViewSettings.saveShowRecycled(false, for: firstProject, defaults: defaults)
        XCTAssertFalse(ShelfViewSettings.showRecycled(for: firstProject, defaults: defaults))
    }

    func testShelfTreeSettingsAreProjectScoped() {
        let suiteName = "Arbor.ShelfTreeSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstProject = "/workspace/one"
        let secondProject = "/workspace/two"

        XCTAssertTrue(ShelfViewSettings.shelvesExpanded(for: firstProject, defaults: defaults))
        XCTAssertTrue(ShelfViewSettings.groupByDirectory(for: firstProject, defaults: defaults))
        XCTAssertTrue(ShelfViewSettings.deletedShelvesExpanded(for: firstProject, defaults: defaults))

        ShelfViewSettings.saveShelvesExpanded(false, for: firstProject, defaults: defaults)
        ShelfViewSettings.saveGroupByDirectory(false, for: firstProject, defaults: defaults)
        ShelfViewSettings.saveDeletedShelvesExpanded(false, for: firstProject, defaults: defaults)

        XCTAssertFalse(ShelfViewSettings.shelvesExpanded(for: firstProject, defaults: defaults))
        XCTAssertFalse(ShelfViewSettings.groupByDirectory(for: firstProject, defaults: defaults))
        XCTAssertFalse(ShelfViewSettings.deletedShelvesExpanded(for: firstProject, defaults: defaults))
        XCTAssertTrue(ShelfViewSettings.shelvesExpanded(for: secondProject, defaults: defaults))
        XCTAssertTrue(ShelfViewSettings.groupByDirectory(for: secondProject, defaults: defaults))
        XCTAssertTrue(ShelfViewSettings.deletedShelvesExpanded(for: secondProject, defaults: defaults))
    }

    func testShelfRemoveAppliedSettingIsProjectScoped() {
        let suiteName = "Arbor.ShelfRemoveAppliedSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstProject = "/workspace/one"
        let secondProject = "/workspace/two"
        defaults.set(true, forKey: "arbor.commit.shelves.removeApplied.v1")

        XCTAssertFalse(
            ShelfViewSettings.removeAppliedFilesFromShelf(
                for: firstProject,
                defaults: defaults
            )
        )
        XCTAssertFalse(
            ShelfViewSettings.removeAppliedFilesFromShelf(
                for: secondProject,
                defaults: defaults
            )
        )

        ShelfViewSettings.saveRemoveAppliedFilesFromShelf(
            true,
            for: firstProject,
            defaults: defaults
        )

        XCTAssertTrue(
            ShelfViewSettings.removeAppliedFilesFromShelf(
                for: firstProject,
                defaults: defaults
            )
        )
        XCTAssertFalse(
            ShelfViewSettings.removeAppliedFilesFromShelf(
                for: secondProject,
                defaults: defaults
            )
        )

        ShelfViewSettings.saveRemoveAppliedFilesFromShelf(
            false,
            for: firstProject,
            defaults: defaults
        )
        XCTAssertFalse(
            ShelfViewSettings.removeAppliedFilesFromShelf(
                for: firstProject,
                defaults: defaults
            )
        )
    }

    func testSecondaryShelfRootActionAllowlistFailsClosedForWorktreeWrites() {
        XCTAssertTrue(isSecondaryShelfRootScopedAction(.restoreShelf))
        XCTAssertTrue(isSecondaryShelfRootScopedAction(.restoreShelfPaths))
        XCTAssertTrue(isSecondaryShelfRootScopedAction(.deleteDeletedShelfPaths))
        XCTAssertTrue(isSecondaryShelfRootScopedAction(.undoShelfDeletion))
        XCTAssertTrue(isSecondaryShelfRootScopedAction(.undoShelfDeletions))
        XCTAssertTrue(isSecondaryShelfRootScopedAction(.dropShelf))
        XCTAssertTrue(isSecondaryShelfRootScopedAction(.retryShelfBatch))
        XCTAssertTrue(isSecondaryShelfRootScopedAction(.retryShelfMemberBatch))
        XCTAssertTrue(isSecondaryShelfRootScopedAction(.retryShelfLifecycleBatch))
        XCTAssertTrue(isSecondaryShelfRootScopedAction(.retryPush))
        XCTAssertTrue(isSecondaryShelfRootScopedAction(.retryPushRecovery))
        XCTAssertTrue(isSecondaryShelfRootScopedAction(.retryStashBranch))
        XCTAssertTrue(isSecondaryShelfRootScopedAction(.retryLogApply))
        XCTAssertTrue(isSecondaryShelfRootScopedAction(.showLogApplyAffectedFiles))
    }

    func testShelfPreviewRootGuardRejectsStaleRootAndName() {
        XCTAssertTrue(
            shelfPreviewRequestMatches(
                requestedRootPath: "/workspace/repo/.",
                currentRootPath: "/workspace/repo",
                requestedName: "Work",
                currentName: "Work",
                requestedIsDeleted: false,
                currentIsDeleted: false
            )
        )
        XCTAssertFalse(
            shelfPreviewRequestMatches(
                requestedRootPath: "/workspace/other",
                currentRootPath: "/workspace/repo",
                requestedName: "Work",
                currentName: "Work",
                requestedIsDeleted: false,
                currentIsDeleted: false
            )
        )
        XCTAssertFalse(
            shelfPreviewRequestMatches(
                requestedRootPath: "/workspace/repo",
                currentRootPath: "/workspace/repo",
                requestedName: "Work",
                currentName: "Other",
                requestedIsDeleted: false,
                currentIsDeleted: false
            )
        )
        XCTAssertFalse(
            shelfPreviewRequestMatches(
                requestedRootPath: "/workspace/repo",
                currentRootPath: "/workspace/repo",
                requestedName: "Work",
                currentName: "Work",
                requestedIsDeleted: true,
                currentIsDeleted: false
            )
        )
    }

    func testShelfPreviewRootGuardFailsClosedWhenCurrentRootIsUnavailable() {
        XCTAssertFalse(
            shelfPreviewRequestMatches(
                requestedRootPath: "/workspace/repo",
                currentRootPath: nil,
                requestedName: "Work",
                currentName: "Work",
                requestedIsDeleted: false,
                currentIsDeleted: false
            )
        )
    }

    func testShelfTreeGroupsDirectoriesAndKeepsFilesStable() {
        let rows = shelfTreeRows(
            paths: ["Sources/Z.swift", "README.md", "Sources/App.swift", "Tests/AppTests.swift"],
            groupByDirectory: true
        )

        XCTAssertEqual(rows.map(\.path), ["README.md", "Sources", "Sources/App.swift", "Sources/Z.swift", "Tests", "Tests/AppTests.swift"])
        XCTAssertEqual(rows.filter(\.isFolder).map(\.path), ["Sources", "Tests"])
        XCTAssertEqual(rows.first(where: { $0.path == "Sources/App.swift" })?.depth, 1)
    }

    func testShelfTreeFlatModeDoesNotInventFolders() {
        let rows = shelfTreeRows(
            paths: ["b/file.swift", "a/file.swift"],
            groupByDirectory: false
        )

        XCTAssertEqual(rows.map(\.path), ["a/file.swift", "b/file.swift"])
        XCTAssertTrue(rows.allSatisfy { !$0.isFolder && $0.depth == 0 })
    }

    func testShelfTreeFlatModeMatchesIntelliJFilenameFirstOrdering() {
        let rows = shelfTreeRows(
            paths: ["z/README.md", "a/App.swift", "b/README.md", "a/Z.swift"],
            groupByDirectory: false
        )

        XCTAssertEqual(
            rows.map(\.path),
            ["a/App.swift", "b/README.md", "z/README.md", "a/Z.swift"]
        )
    }

    func testShelfMemberSelectionIDIncludesShelfIdentity() {
        XCTAssertNotEqual(
            shelfMemberSelectionID(shelfID: "shelf-a", path: "same.swift"),
            shelfMemberSelectionID(shelfID: "shelf-b", path: "same.swift")
        )
    }

    func testShelfDropPayloadParsesWholeShelf() {
        XCTAssertEqual(parseShelfDropPayload("arbor-shelf:Review fixes"), .shelf("Review fixes"))
    }

    func testShelfDropPayloadParsesSelectedMember() {
        XCTAssertEqual(
            parseShelfDropPayload("arbor-shelf-member:Review fixes\u{1F}Sources/App.swift"),
            .member(shelf: "Review fixes", path: "Sources/App.swift")
        )
    }

    func testShelfDropPayloadRejectsMalformedValues() {
        XCTAssertNil(parseShelfDropPayload(""))
        XCTAssertNil(parseShelfDropPayload("arbor-shelf:"))
        XCTAssertNil(parseShelfDropPayload("arbor-shelf-member:Review fixes"))
        XCTAssertNil(parseShelfDropPayload("arbor-shelf-member:\u{1F}Sources/App.swift"))
    }

    func testShelfLifecycleRunsImmediatelyThenDaily() {
        XCTAssertNil(shelfLifecycleDelaySeconds(firstRun: true))
        XCTAssertEqual(shelfLifecycleDelaySeconds(firstRun: false), 24 * 60 * 60)
    }

    func testShelfDeletePlanMatchesIntellijDeleteProviderSelectionScope() {
        let active = shelf("active", id: "active-id", paths: ["Sources/A.swift", "Sources/B.swift"])
        let activeMemberOnly = shelf("active-member", id: "active-member-id", paths: ["Sources/C.swift"])
        let deleted = shelf("deleted", id: "deleted-id", paths: ["Tests/A.swift", "Tests/B.swift"], deleted: true)

        let plan = shelfDeletePlan(
            visibleShelves: [active, activeMemberOnly],
            deletedShelves: [deleted],
            selectedShelfIDs: [active.id],
            selectedShelfMemberIDs: [
                shelfMemberSelectionID(shelfID: active.id, path: "Sources/B.swift"),
                shelfMemberSelectionID(shelfID: activeMemberOnly.id, path: "Sources/C.swift")
            ],
            selectedDeletedShelfIDs: [],
            selectedDeletedShelfMemberIDs: [
                shelfMemberSelectionID(shelfID: deleted.id, path: "Tests/A.swift")
            ]
        )

        XCTAssertEqual(plan.activeShelfNames, ["active"])
        XCTAssertEqual(
            plan.activePathGroups,
            [ShelfPathDeleteGroup(shelfName: "active-member", paths: ["Sources/C.swift"])]
        )
        XCTAssertEqual(plan.deletedShelfNames, [])
        XCTAssertEqual(
            plan.deletedPathGroups,
            [ShelfPathDeleteGroup(shelfName: "deleted", paths: ["Tests/A.swift"])]
        )
    }

    func testShelfDeletePlanExpandsMixedScopesInStableOrder() {
        let plan = ShelfDeletePlan(
            activeShelfNames: ["active-whole"],
            activePathGroups: [
                ShelfPathDeleteGroup(shelfName: "active-members", paths: ["Sources/A.swift"])
            ],
            deletedShelfNames: ["deleted-whole"],
            deletedPathGroups: [
                ShelfPathDeleteGroup(shelfName: "deleted-members", paths: ["Tests/A.swift"])
            ]
        )

        XCTAssertEqual(
            shelfDeleteOperations(plan),
            [
                ShelfDeleteOperation(kind: .activeShelf, shelfName: "active-whole", paths: []),
                ShelfDeleteOperation(
                    kind: .activePaths,
                    shelfName: "active-members",
                    paths: ["Sources/A.swift"]
                ),
                ShelfDeleteOperation(kind: .deletedShelf, shelfName: "deleted-whole", paths: []),
                ShelfDeleteOperation(
                    kind: .deletedPaths,
                    shelfName: "deleted-members",
                    paths: ["Tests/A.swift"]
                )
            ]
        )
        XCTAssertEqual(
            Set(shelfDeleteOperations(plan).map(\.key)).count,
            4
        )
        XCTAssertEqual(
            shelfDeleteOperations(plan).map(\.displayName),
            [
                "active-whole",
                "active-members",
                "deleted-whole (Recently Deleted)",
                "deleted-members (Recently Deleted)"
            ]
        )
    }
}
