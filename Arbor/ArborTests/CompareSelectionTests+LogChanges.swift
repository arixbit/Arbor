import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {

    func testMultiRootChangeSelectionSeparatesSamePathAcrossRoots() {
        let firstRoot = MultiRootChangeSelection(
            rootPath: "/workspace/one",
            path: "README.md"
        )
        let secondRoot = MultiRootChangeSelection(
            rootPath: "/workspace/two",
            path: "README.md"
        )

        XCTAssertNotEqual(firstRoot, secondRoot)
        XCTAssertNotEqual(firstRoot.id, secondRoot.id)
    }

    func testLogChangeContextMenuPreservesSelectedPatchScope() {
        let commit = logCommit()
        let first = LogChangeRecord(
            commit: commit,
            parentIndex: 0,
            change: changes[0]
        )
        let second = LogChangeRecord(
            commit: commit,
            parentIndex: 0,
            change: changes[1]
        )

        let selected = contextualLogChangeSelection(
            context: first,
            selected: [first, second]
        )
        XCTAssertEqual(selected.map(\.id), [first.id, second.id])
    }

    func testLogChangeContextMenuFallsBackToOneRowForMixedSelection() {
        let commit = logCommit()
        let first = LogChangeRecord(
            commit: commit,
            parentIndex: 0,
            change: changes[0]
        )
        let second = LogChangeRecord(
            commit: commit,
            parentIndex: 1,
            change: changes[1]
        )

        XCTAssertEqual(
            contextualLogChangeSelection(
                context: first,
                selected: [first, second]
            ).map(\.id),
            [first.id]
        )
        XCTAssertEqual(
            contextualLogChangeSelection(
                context: first,
                selected: [first, second]
            ).map(\.id),
            [first.id]
        )
    }

    func testHistoryChangeRewriteAllowsRenamesAndGitlinksButRejectsFullSelection() {
        XCTAssertTrue(
            canRewriteSelectedHistoryChanges(
                commitCount: 1,
                selectedCount: 1,
                totalChangeCount: 2
            )
        )
        XCTAssertFalse(
            canRewriteSelectedHistoryChanges(
                commitCount: 1,
                selectedCount: 2,
                totalChangeCount: 2
            )
        )
    }

    func testHistoryChangeRewriteUsesUnfilteredChangeCount() {
        XCTAssertTrue(
            canRewriteSelectedHistoryChanges(
                commitCount: 1,
                selectedCount: 1,
                totalChangeCount: 3
            )
        )
    }

    func testLogChangeDirectorySelectionReplacesAndTogglesTheWholeGroup() {
        let group = Set(["one", "two"])

        XCTAssertEqual(
            logChangeSelectionAfterGroupClick(
                currentSelection: ["other"],
                groupIDs: group,
                visibleIDs: ["other", "one", "two"],
                anchorID: nil,
                command: false,
                shift: false
            ),
            group
        )
        XCTAssertEqual(
            logChangeSelectionAfterGroupClick(
                currentSelection: ["one"],
                groupIDs: group,
                visibleIDs: ["one", "two", "other"],
                anchorID: "one",
                command: true,
                shift: false
            ),
            Set(["one", "two"])
        )
        XCTAssertEqual(
            logChangeSelectionAfterGroupClick(
                currentSelection: ["one", "two", "other"],
                groupIDs: group,
                visibleIDs: ["one", "two", "other"],
                anchorID: "one",
                command: true,
                shift: false
            ),
            Set(["other"])
        )
        XCTAssertEqual(
            logChangeSelectionAfterGroupClick(
                currentSelection: ["one"],
                groupIDs: Set(["three", "four"]),
                visibleIDs: ["one", "two", "three", "four", "five"],
                anchorID: "one",
                command: false,
                shift: true
            ),
            Set(["one", "two", "three", "four"])
        )
    }

    func testHistoryChangeRewriteOnlyAllowsFirstParentMergeSelection() {
        let merge = logCommit(id: "merge", parentIds: ["first", "second"])
        let firstParent = LogChangeRecord(
            commit: merge,
            parentIndex: 0,
            change: changes[0]
        )
        let secondParent = LogChangeRecord(
            commit: merge,
            parentIndex: 1,
            change: changes[1]
        )

        XCTAssertTrue(logChangeSelectionUsesFirstParent([firstParent]))
        XCTAssertFalse(logChangeSelectionUsesFirstParent([secondParent]))
        XCTAssertFalse(logChangeSelectionUsesFirstParent([firstParent, secondParent]))
    }

    func testLogChangePatchGroupsSupportMultipleCommitsInOneRoot() {
        let first = LogChangeRecord(
            commit: logCommit(id: "one"),
            parentIndex: 0,
            change: changes[0]
        )
        let second = LogChangeRecord(
            commit: logCommit(id: "two"),
            parentIndex: 0,
            change: changes[1]
        )

        let groups = logChangePatchGroups([first, second])
        XCTAssertEqual(groups.map { $0.map(\.id) }, [[first.id], [second.id]])
        XCTAssertTrue(canApplyLogChangeSelection([first, second]))
    }

    func testLogChangePatchGroupsSupportCrossRootSelectionsAndRejectMixedParents() {
        let first = LogChangeRecord(
            commit: logCommit(id: "one"),
            parentIndex: 0,
            change: changes[0]
        )
        let otherRoot = LogChangeRecord(
            commit: logCommit(id: "two", repositoryPath: "/workspace/other"),
            parentIndex: 0,
            change: changes[1]
        )
        let mixedParent = LogChangeRecord(
            commit: first.commit,
            parentIndex: 1,
            change: changes[1]
        )

        let crossRootGroups = logChangePatchGroups([first, otherRoot])
        XCTAssertEqual(crossRootGroups.map { $0.map(\.id) }, [[first.id], [otherRoot.id]])
        XCTAssertTrue(canApplyLogChangeSelection([first, otherRoot]))
        XCTAssertTrue(logChangePatchGroups([first, mixedParent]).isEmpty)
        XCTAssertFalse(canApplyLogChangeSelection([first, mixedParent]))
    }

    func testLogChangePatchGroupsKeepEqualCommitIDsSeparateAcrossRoots() {
        let first = LogChangeRecord(
            commit: logCommit(id: "same", repositoryPath: "/workspace/one"),
            parentIndex: 0,
            change: changes[0]
        )
        let second = LogChangeRecord(
            commit: logCommit(id: "same", repositoryPath: "/workspace/two"),
            parentIndex: 0,
            change: changes[0]
        )

        let groups = logChangePatchGroups([first, second])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.flatMap { $0.map(\.id) }, [first.id, second.id])
        XCTAssertTrue(canApplyLogChangeSelection([first, second]))
    }

    func testLogChangesBrowserGroupsEqualCommitIDsByGitRoot() {
        let first = LogChangeRecord(
            commit: logCommit(id: "same", repositoryPath: "/workspace/one"),
            parentIndex: 0,
            change: changes[0]
        )
        let second = LogChangeRecord(
            commit: logCommit(id: "same", repositoryPath: "/workspace/two"),
            parentIndex: 0,
            change: changes[1]
        )

        XCTAssertEqual(
            logChangesCommitRecords([first, second], for: first.commit),
            [first]
        )
        XCTAssertEqual(
            logChangesCommitRecords([first, second], for: second.commit),
            [second]
        )
        XCTAssertNotEqual(
            logChangesCommitIdentity(first.commit),
            logChangesCommitIdentity(second.commit)
        )
        XCTAssertEqual(
            logChangesCommitGroupName(
                first.commit,
                among: [first.commit, second.commit]
            ),
            "one · same  " + first.commit.summary
        )
        let sameNameRoot = logCommit(
            id: "other",
            repositoryPath: "/other/one"
        )
        XCTAssertEqual(
            logChangesCommitGroupName(
                first.commit,
                among: [first.commit, sameNameRoot]
            ),
            "/workspace/one · same  " + first.commit.summary
        )
    }

    func testLogChangesPatchNotificationIDIsRootQualifiedAndOrderIndependent() {
        let roots = ["/workspace/other", "/workspace/one"]
        let notificationID = logChangesPatchNotificationID(
            rootPaths: roots,
            reverse: false
        )
        XCTAssertEqual(
            notificationID,
            logChangesPatchNotificationID(
                rootPaths: roots.reversed(),
                reverse: false
            )
        )
        XCTAssertNotEqual(
            notificationID,
            logChangesPatchNotificationID(rootPaths: roots, reverse: true)
        )
        XCTAssertTrue(notificationID.contains("_workspace_one"))
        XCTAssertTrue(notificationID.contains("_workspace_other"))
    }

    func testHostedFileRevisionTargetUsesParentForDeletedPaths() {
        let deleted = LogChangeRecord(
            commit: logCommit(id: "merge", parentIds: ["first-parent", "second-parent"]),
            parentIndex: 1,
            change: changes[2]
        )
        let deletedTarget = hostedFileRevisionTarget(for: deleted)
        XCTAssertEqual(deletedTarget.commitID, "second-parent")
        XCTAssertEqual(deletedTarget.path, "Tests/AppTests.swift")

        let modified = LogChangeRecord(
            commit: logCommit(id: "modified"),
            parentIndex: 0,
            change: changes[0]
        )
        let modifiedTarget = hostedFileRevisionTarget(for: modified)
        XCTAssertEqual(modifiedTarget.commitID, "modified")
        XCTAssertEqual(modifiedTarget.path, "Sources/App.swift")
    }

    func testCreatePatchSelectionRejectsDuplicatePathsAndPreservesRenameEndpoints() {
        let first = LogChangeRecord(
            commit: logCommit(id: "one"),
            parentIndex: 0,
            change: changes[0]
        )
        let second = LogChangeRecord(
            commit: logCommit(id: "two"),
            parentIndex: 0,
            change: changes[1]
        )
        XCTAssertTrue(canCreateLogPatchSelection([first, second]))
        XCTAssertFalse(
            canCreateLogPatchSelection([
                first,
                LogChangeRecord(
                    commit: second.commit,
                    parentIndex: 0,
                    change: changes[0]
                )
            ])
        )

        let renamed = LogChangeRecord(
            commit: logCommit(id: "rename"),
            parentIndex: 0,
            change: TreeChange(
                path: "Sources/New.swift",
                oldPath: "Sources/Old.swift",
                isPureMove: false,
                kind: .renamed,
                oldMode: 0o100644,
                newMode: 0o100644
            )
        )
        XCTAssertTrue(canCreateLogPatchSelection([renamed]))
    }

    func testLogChangeGetVersionContextPreservesCrossRootSelection() {
        let first = LogChangeRecord(
            commit: logCommit(id: "one"),
            parentIndex: 0,
            change: changes[0]
        )
        let second = LogChangeRecord(
            commit: logCommit(id: "two", repositoryPath: "/workspace/other"),
            parentIndex: 0,
            change: changes[1]
        )

        XCTAssertEqual(
            contextualLogChangeRestoreSelection(
                context: first,
                selected: [first, second]
            ).map(\.id),
            [first.id, second.id]
        )
        XCTAssertEqual(
            contextualLogChangeRestoreSelection(
                context: first,
                selected: [second]
            ).map(\.id),
            [first.id]
        )
    }

    func testLogChangesFromParentsOnlyExpandsOneMergeCommit() {
        let merge = logCommit(id: "merge", parentIds: ["parent-a", "parent-b"])

        XCTAssertEqual(
            logChangeParentIndices(
                commit: merge,
                selectedCommitCount: 1,
                selectedParentIndex: 0,
                showsChangesFromParents: true
            ),
            [0, 1]
        )
        XCTAssertEqual(
            logChangeParentIndices(
                commit: merge,
                selectedCommitCount: 2,
                selectedParentIndex: 0,
                showsChangesFromParents: true
            ),
            [0]
        )
    }

    func testLogChangeAffectedPathMatchesDirectoriesAndRenameEndpoints() {
        let renamed = TreeChange(
            path: "Sources/New/App.swift",
            oldPath: "Legacy/App.swift",
            isPureMove: false,
            kind: .renamed,
            oldMode: 0o100644,
            newMode: 0o100644
        )

        XCTAssertTrue(logChangeAffectsPath(renamed, affectedPath: "Sources"))
        XCTAssertTrue(logChangeAffectsPath(renamed, affectedPath: "Legacy/App.swift"))
        XCTAssertTrue(logChangeAffectsPath(renamed, affectedPath: "./Sources/New/App.swift/"))
        XCTAssertFalse(logChangeAffectsPath(renamed, affectedPath: "Other"))
        XCTAssertFalse(logChangeAffectsPath(renamed, affectedPath: ""))
    }

    func testRelativeLogPathFilterUsesDeepestGitRootAndDirectoryMarker() {
        XCTAssertEqual(
            relativeLogPathFilter(
                for: URL(fileURLWithPath: "/workspace/repo/Package/Sources/App.swift"),
                roots: ["/workspace/repo", "/workspace/repo/Package"]
            ),
            "Sources/App.swift"
        )
        XCTAssertEqual(
            relativeLogPathFilter(
                for: URL(fileURLWithPath: "/workspace/repo/Sources", isDirectory: true),
                roots: ["/workspace/repo"]
            ),
            "Sources/"
        )
        XCTAssertEqual(
            relativeLogPathFilter(
                for: URL(fileURLWithPath: "/workspace/other/File.swift"),
                roots: ["/workspace/repo"]
            ),
            nil
        )
    }

    func testLogPathFiltersNormalizeMultipleLinesAndPreserveOrder() {
        let paths = normalizedLogPathFilters(" Sources/App.swift\n./Tests/\nSources/App.swift\n")

        XCTAssertEqual(paths, ["Sources/App.swift", "Tests"])
        XCTAssertEqual(logPathFilterText(paths), "Sources/App.swift\nTests")
        XCTAssertEqual(logPathFilterSummary(paths), "Sources/App.swift + 1")
    }

    func testRootQualifiedLogPathSelectionsPreserveEqualPathsAcrossRoots() {
        let selections = normalizedLogPathFilterSelections([
            LogPathFilterSelection(rootPath: "/workspace/one", path: "Sources/App.swift"),
            LogPathFilterSelection(rootPath: "/workspace/two", path: "Sources/App.swift"),
            LogPathFilterSelection(rootPath: "/workspace/one", path: "./Sources/App.swift")
        ])
        XCTAssertEqual(selections.count, 2)
        XCTAssertEqual(
            logPathFilterPathsForRoot(selections, rootPath: "/workspace/one"),
            ["Sources/App.swift"]
        )
        XCTAssertEqual(
            logPathFilterPathsForRoot(
                [LogPathFilterSelection(rootPath: "/workspace/one", path: "Sources/App.swift")],
                rootPath: "/workspace/two"
            ),
            []
        )

        let editorText = logPathFilterEditorText(selections)
        XCTAssertTrue(editorText.contains("/workspace/one/Sources/App.swift"))
        XCTAssertTrue(editorText.contains("/workspace/two/Sources/App.swift"))
        XCTAssertEqual(
            parseLogPathFilterEditorText(
                editorText,
                roots: ["/workspace/one", "/workspace/two"]
            ),
            selections
        )

        let change = TreeChange(
            path: "Sources/App.swift",
            oldPath: nil,
            isPureMove: false,
            kind: .modified,
            oldMode: 0o100644,
            newMode: 0o100644
        )
        XCTAssertTrue(logChangeAffectsAnyPath(change, rootPath: "/workspace/one", selections: selections))
        XCTAssertTrue(logChangeAffectsAnyPath(change, rootPath: "/workspace/two", selections: selections))
        XCTAssertFalse(logChangeAffectsAnyPath(change, rootPath: "/workspace/three", selections: selections))
    }

    func testRootQualifiedPathParsingUsesTheDeepestNestedRoot() {
        let roots = ["/workspace/repo", "/workspace/repo/packages/app"]
        let selections = parseLogPathFilterEditorText(
            "/workspace/repo/packages/app/Sources/App.swift",
            roots: roots
        )

        XCTAssertEqual(
            selections,
            [LogPathFilterSelection(
                rootPath: "/workspace/repo/packages/app",
                path: "Sources/App.swift"
            )]
        )
        XCTAssertEqual(
            logRootPathsDeepestFirst(roots),
            ["/workspace/repo/packages/app", "/workspace/repo"]
        )
        XCTAssertTrue(
            parseLogPathFilterEditorText(
                "/workspace/outside/Sources/App.swift",
                roots: roots
            ).isEmpty
        )
    }

    func testLogPathTreeSelectionCollapsesDescendantsButKeepsRootsSeparate() {
        let parent = LogPathFilterSelection(rootPath: "/workspace/one", path: "Sources")
        let child = LogPathFilterSelection(rootPath: "/workspace/one", path: "Sources/App.swift")
        let otherRoot = LogPathFilterSelection(rootPath: "/workspace/two", path: "Sources/App.swift")

        let collapsed = normalizedLogTreeSelections([child, parent, otherRoot])
        XCTAssertEqual(collapsed, [parent, otherRoot])
        XCTAssertEqual(logPathTreeSelectionState(child, in: collapsed), .selectedAbove)
        XCTAssertEqual(logPathTreeSelectionState(parent, in: collapsed), .selected)
        XCTAssertEqual(logPathTreeSelectionState(otherRoot, in: collapsed), .selected)

        let expanded = logPathTreeSelectionsAfterToggle(parent, in: collapsed)
        XCTAssertEqual(expanded, [otherRoot])
    }

    func testLogPathTreeSelectionLimitRejectsIndependentNodeButAllowsParentCollapse() {
        let root = "/workspace/one"
        let selected = Set((0..<logPathTreeSelectionLimit).map { index in
            LogPathFilterSelection(rootPath: root, path: "Sources/File\(index).swift")
        })
        let extra = LogPathFilterSelection(rootPath: root, path: "Sources/Extra.swift")
        XCTAssertEqual(
            logPathTreeSelectionsAfterToggle(extra, in: selected),
            selected
        )

        let descendant = LogPathFilterSelection(rootPath: root, path: "Sources/Folder/File.swift")
        var withDescendant = selected
        withDescendant.remove(LogPathFilterSelection(rootPath: root, path: "Sources/File0.swift"))
        withDescendant.insert(descendant)
        let folder = LogPathFilterSelection(rootPath: root, path: "Sources/Folder")
        let collapsed = logPathTreeSelectionsAfterToggle(folder, in: withDescendant)
        XCTAssertTrue(collapsed.contains(folder))
        XCTAssertFalse(collapsed.contains(descendant))
        XCTAssertEqual(collapsed.count, logPathTreeSelectionLimit)
    }

    func testLogRootVisibilityReconcilesStaleRootsAndSerializesPartialSelection() {
        let roots = ["/workspace/one", "/workspace/two"]
        let visible = reconciledLogVisibleRootPaths(
            allRoots: roots,
            raw: "/workspace/two\n/workspace/missing"
        )

        XCTAssertEqual(visible, ["/workspace/two"])
        XCTAssertEqual(
            serializedLogVisibleRootPaths(selected: visible, allRoots: roots),
            "/workspace/two"
        )
        XCTAssertEqual(
            reconciledLogVisibleRootPaths(allRoots: roots, raw: ""),
            Set(roots)
        )
    }

    func testUncommitChangedPathsIncludesRenameEndpointsOnce() {
        let changes = [
            TreeChange(
                path: "Sources/New.swift",
                oldPath: "Sources/Old.swift",
                isPureMove: true,
                kind: .renamed,
                oldMode: 0o100644,
                newMode: 0o100644
            ),
            TreeChange(
                path: "Sources/New.swift",
                oldPath: nil,
                isPureMove: false,
                kind: .modified,
                oldMode: 0o100644,
                newMode: 0o100644
            )
        ]

        XCTAssertEqual(
            uncommitChangedPaths(changes),
            ["Sources/New.swift", "Sources/Old.swift"]
        )
    }
}
