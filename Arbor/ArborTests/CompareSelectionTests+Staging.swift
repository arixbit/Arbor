import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {

    func testStagingComparisonActionsRequireTheExpectedStatusDimensions() {
        let stagedOnly = FileEntry(
            path: "staged.txt",
            oldPath: nil,
            staged: .modified,
            unstaged: .unchanged
        )
        XCTAssertEqual(
            stagingComparisonActions(for: stagedOnly),
            [.stagedWithHead]
        )

        let partiallyStaged = FileEntry(
            path: "partial.txt",
            oldPath: nil,
            staged: .modified,
            unstaged: .modified
        )
        XCTAssertEqual(
            stagingComparisonActions(for: partiallyStaged),
            [.localWithStaged, .stagedWithLocal, .threeVersions, .stagedWithHead]
        )

        let untracked = FileEntry(
            path: "new.txt",
            oldPath: nil,
            staged: .unchanged,
            unstaged: .untracked
        )
        XCTAssertTrue(stagingComparisonActions(for: untracked).isEmpty)

        let stagedAdded = FileEntry(
            path: "new-staged.txt",
            oldPath: nil,
            staged: .added,
            unstaged: .modified
        )
        XCTAssertEqual(
            stagingComparisonActions(for: stagedAdded),
            [.localWithStaged, .stagedWithLocal]
        )

        let conflicted = FileEntry(
            path: "conflict.txt",
            oldPath: nil,
            staged: .conflicted,
            unstaged: .conflicted
        )
        XCTAssertTrue(stagingComparisonActions(for: conflicted).isEmpty)
    }

    func testStagingPreviewKeepsRequestedDimensionWhenAvailable() {
        XCTAssertEqual(
            resolvedStagingPreviewMode(preferred: .staged, available: [.unstaged, .staged]),
            .staged
        )
        XCTAssertEqual(
            resolvedStagingPreviewMode(preferred: .staged, available: [.unstaged]),
            .unstaged
        )
        XCTAssertNil(resolvedStagingPreviewMode(preferred: .unstaged, available: []))
    }

    func testDiffReadRejectsOlderPathGeneration() {
        XCTAssertFalse(
            isCurrentDiffRequest(
                path: "file.txt",
                generation: 2,
                currentPath: "file.txt",
                currentGeneration: 3
            )
        )
        XCTAssertFalse(
            isCurrentDiffRequest(
                path: "old.txt",
                generation: 3,
                currentPath: "new.txt",
                currentGeneration: 3
            )
        )
        XCTAssertTrue(
            isCurrentDiffRequest(
                path: "file.txt",
                generation: 3,
                currentPath: "file.txt",
                currentGeneration: 3
            )
        )
    }

    func testStagingPreviewLineModeUsesTheActiveDiffDimension() {
        XCTAssertEqual(stagingPreviewDiffMode(for: .unstaged), .worktreeToIndex)
        XCTAssertEqual(stagingPreviewDiffMode(for: .staged), .indexToHead)
    }

    func testStagingComparisonActionsUseTheReferenceStagingCoordinateSystem() {
        XCTAssertEqual(
            stagingComparisonDiffMode(for: .localWithStaged),
            .worktreeToIndex
        )
        XCTAssertEqual(
            stagingComparisonDiffMode(for: .stagedWithLocal),
            .worktreeToIndex
        )
        XCTAssertEqual(
            stagingComparisonDiffMode(for: .stagedWithHead),
            .indexToHead
        )
        XCTAssertNil(stagingComparisonDiffMode(for: .threeVersions))
    }

    func testStagingActionsUseExactVersionPresenceWhenAvailable() {
        let unstagedOnly = FileEntry(
            path: "unstaged.txt",
            oldPath: nil,
            staged: .unchanged,
            unstaged: .modified
        )
        XCTAssertEqual(
            stagingComparisonActions(
                for: unstagedOnly,
                presence: StagingVersionPresence(head: true, staged: true, local: true)
            ),
            [.localWithStaged, .stagedWithLocal, .threeVersions, .stagedWithHead]
        )

        let stagedAdded = FileEntry(
            path: "added.txt",
            oldPath: nil,
            staged: .added,
            unstaged: .modified
        )
        XCTAssertEqual(
            stagingComparisonActions(
                for: stagedAdded,
                presence: StagingVersionPresence(head: false, staged: true, local: true)
            ),
            [.localWithStaged, .stagedWithLocal]
        )

        let stagedDeletion = FileEntry(
            path: "deleted.txt",
            oldPath: nil,
            staged: .deleted,
            unstaged: .unchanged
        )
        XCTAssertTrue(
            stagingVersionActions(
                for: stagedDeletion,
                presence: StagingVersionPresence(head: true, staged: false, local: false)
            ).isEmpty
        )
    }

    func testStagingPreviewFileActionsRespectIndexAndWorktreeBoundaries() {
        let partiallyStaged = FileEntry(
            path: "partial.txt",
            oldPath: nil,
            staged: .modified,
            unstaged: .modified
        )
        XCTAssertEqual(
            stagingPreviewFileActions(for: partiallyStaged, mode: .unstaged),
            [.stage, .revertUnstaged]
        )
        XCTAssertEqual(
            stagingPreviewFileActions(for: partiallyStaged, mode: .staged),
            [.unstage]
        )

        let untracked = FileEntry(
            path: "new.txt",
            oldPath: nil,
            staged: .unchanged,
            unstaged: .untracked
        )
        XCTAssertEqual(
            stagingPreviewFileActions(for: untracked, mode: .unstaged),
            [.stage]
        )

        let conflicted = FileEntry(
            path: "conflict.txt",
            oldPath: nil,
            staged: .conflicted,
            unstaged: .conflicted
        )
        XCTAssertTrue(stagingPreviewFileActions(for: conflicted, mode: .unstaged).isEmpty)
        XCTAssertTrue(stagingPreviewFileActions(for: nil, mode: .staged).isEmpty)
    }

    func testStagingHunkActionsExposeStageUnstageAndRollbackPerDimension() {
        let diff = FileDiff(
            path: "partial.txt",
            binary: false,
            hunks: [DiffHunk(oldStart: 1, newStart: 1, oldLines: [], newLines: [])]
        )
        let partiallyStaged = FileEntry(
            path: "partial.txt",
            oldPath: nil,
            staged: .modified,
            unstaged: .modified
        )
        XCTAssertEqual(
            stagingHunkActions(for: partiallyStaged, mode: .unstaged, diff: diff),
            [.stage, .rollback]
        )
        XCTAssertEqual(
            stagingHunkActions(for: partiallyStaged, mode: .staged, diff: diff),
            [.unstage]
        )

        let untracked = FileEntry(
            path: "new.txt",
            oldPath: nil,
            staged: .unchanged,
            unstaged: .untracked
        )
        XCTAssertEqual(
            stagingHunkActions(for: untracked, mode: .unstaged, diff: diff),
            [.stage]
        )
        XCTAssertTrue(
            stagingHunkActions(for: partiallyStaged, mode: .unstaged,
                               diff: FileDiff(path: "partial.txt", binary: true, hunks: []))
                .isEmpty
        )
    }

    func testThreeVersionComparisonModesRouteHunksToTheCorrectStagingDimension() {
        XCTAssertNil(ThreeVersionComparisonMode.overview.diffMode)
        XCTAssertNil(ThreeVersionComparisonMode.overview.stagingMode)
        XCTAssertEqual(ThreeVersionComparisonMode.headToStaged.diffMode, .indexToHead)
        XCTAssertEqual(ThreeVersionComparisonMode.headToStaged.stagingMode, .staged)
        XCTAssertEqual(ThreeVersionComparisonMode.stagedToLocal.diffMode, .worktreeToIndex)
        XCTAssertEqual(ThreeVersionComparisonMode.stagedToLocal.stagingMode, .unstaged)
    }

    func testLineSelectionMapsDeletionAndPureInsertionToTheirOwnSides() {
        let selections = makeLineSelections(from: [
            SelectedDiffLine(hunkIndex: 1, oldLine: 7),
            SelectedDiffLine(hunkIndex: 1, oldLine: 0, newLine: 8)
        ])

        XCTAssertEqual(selections.count, 1)
        XCTAssertEqual(selections[0].hunkIndex, 1)
        XCTAssertEqual(selections[0].oldLines, [7])
        XCTAssertEqual(selections[0].newLines, [8])
    }

    func testStagingVersionActionsOnlyExposePresentVersions() {
        let partiallyStaged = FileEntry(
            path: "partial.txt",
            oldPath: nil,
            staged: .modified,
            unstaged: .modified
        )
        XCTAssertEqual(
            stagingVersionActions(for: partiallyStaged),
            [.local, .staged]
        )

        let deletedLocally = FileEntry(
            path: "deleted.txt",
            oldPath: nil,
            staged: .modified,
            unstaged: .deleted
        )
        XCTAssertEqual(
            stagingVersionActions(for: deletedLocally),
            [.staged]
        )

        let stagedDeletion = FileEntry(
            path: "removed.txt",
            oldPath: nil,
            staged: .deleted,
            unstaged: .unchanged
        )
        XCTAssertTrue(stagingVersionActions(for: stagedDeletion).isEmpty)
    }

    func testReversedFileDiffForPresentationSwapsSidesAndLineKinds() {
        let diff = FileDiff(
            path: "file.txt",
            binary: false,
            hunks: [
                DiffHunk(
                    oldStart: 2,
                    newStart: 3,
                    oldLines: [
                        DiffLine(
                            kind: .context,
                            oldLine: 2,
                            newLine: 3,
                            text: "same",
                            spans: [],
                            highlights: []
                        ),
                        DiffLine(
                            kind: .deletion,
                            oldLine: 3,
                            newLine: 0,
                            text: "branch",
                            spans: [],
                            highlights: []
                        )
                    ],
                    newLines: [
                        DiffLine(
                            kind: .context,
                            oldLine: 2,
                            newLine: 3,
                            text: "same",
                            spans: [],
                            highlights: []
                        ),
                        DiffLine(
                            kind: .addition,
                            oldLine: 0,
                            newLine: 4,
                            text: "working",
                            spans: [],
                            highlights: []
                        )
                    ]
                )
            ]
        )

        let reversed = reversedFileDiffForPresentation(diff)
        XCTAssertEqual(reversed.hunks.first?.oldStart, 3)
        XCTAssertEqual(reversed.hunks.first?.newStart, 2)
        XCTAssertEqual(reversed.hunks.first?.oldLines.map(\.kind), [.context, .deletion])
        XCTAssertEqual(reversed.hunks.first?.newLines.map(\.kind), [.context, .addition])
        XCTAssertEqual(reversed.hunks.first?.oldLines.last?.text, "working")
        XCTAssertEqual(reversed.hunks.first?.newLines.last?.text, "branch")
    }
}
