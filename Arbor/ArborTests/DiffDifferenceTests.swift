import XCTest
@testable import Arbor

/// IntelliJ's diff viewer counts and navigates contiguous changed runs rather
/// than Git hunks. These tests pin the row ordinals that the toolbar uses to
/// mark and scroll to the same difference in both presentations.
final class DiffDifferenceTests: XCTestCase {
    func testSingleModificationIsOneDifferenceInBothPresentations() {
        let hunk = makeHunk(
            old: [
                line(.context, old: 1, new: 1),
                line(.deletion, old: 2, new: 0),
                line(.context, old: 3, new: 3),
            ],
            new: [
                line(.context, old: 1, new: 1),
                line(.addition, old: 0, new: 2),
                line(.context, old: 3, new: 3),
            ]
        )

        XCTAssertEqual(sideBySideDifferenceCount(in: [hunk]), 1)
        XCTAssertEqual(unifiedDifferenceCount(in: [hunk]), 1)
        // Context, paired change, context: only the middle row belongs to
        // difference 0.
        XCTAssertEqual(sideBySideDifferenceOrdinals(in: [hunk]), [[nil, 0, nil]])
        // The unified layout renders deletion and addition on separate rows,
        // but they remain one difference.
        XCTAssertEqual(unifiedDifferenceOrdinals(in: [hunk]), [[nil, 0, 0, nil]])
    }

    func testSeparateChangedRunsInOneHunkCountSeparately() {
        let hunk = makeHunk(
            old: [
                line(.context, old: 1, new: 1),
                line(.deletion, old: 2, new: 0),
                line(.context, old: 3, new: 3),
                line(.deletion, old: 4, new: 0),
                line(.context, old: 5, new: 5),
            ],
            new: [
                line(.context, old: 1, new: 1),
                line(.addition, old: 0, new: 2),
                line(.context, old: 3, new: 3),
                line(.addition, old: 0, new: 4),
                line(.context, old: 5, new: 5),
            ]
        )

        XCTAssertEqual(sideBySideDifferenceOrdinals(in: [hunk]), [[nil, 0, nil, 1, nil]])
        XCTAssertEqual(unifiedDifferenceOrdinals(in: [hunk]), [[nil, 0, 0, nil, 1, 1, nil]])
        XCTAssertEqual(sideBySideDifferenceCount(in: [hunk]), 2)
        XCTAssertEqual(unifiedDifferenceCount(in: [hunk]), 2)
    }

    func testPureInsertionKeepsEveryAddedRowInTheSameDifference() {
        let hunk = makeHunk(
            old: [
                line(.context, old: 1, new: 1),
                line(.context, old: 2, new: 2),
            ],
            new: [
                line(.context, old: 1, new: 1),
                line(.addition, old: 0, new: 2),
                line(.addition, old: 0, new: 3),
                line(.context, old: 2, new: 4),
            ]
        )

        XCTAssertEqual(sideBySideDifferenceOrdinals(in: [hunk]), [[nil, 0, 0, nil]])
        XCTAssertEqual(unifiedDifferenceOrdinals(in: [hunk]), [[nil, 0, 0, nil]])
        XCTAssertEqual(sideBySideDifferenceCount(in: [hunk]), 1)
        XCTAssertEqual(unifiedDifferenceCount(in: [hunk]), 1)
    }

    func testDifferencesStayNumberedAcrossHunks() {
        let first = makeHunk(
            old: [line(.deletion, old: 1, new: 0)],
            new: [line(.addition, old: 0, new: 1)]
        )
        let second = makeHunk(
            old: [line(.deletion, old: 9, new: 0)],
            new: [line(.addition, old: 0, new: 9)]
        )

        XCTAssertEqual(sideBySideDifferenceOrdinals(in: [first, second]), [[0], [1]])
        XCTAssertEqual(unifiedDifferenceOrdinals(in: [first, second]), [[0, 0], [1, 1]])
        XCTAssertEqual(sideBySideDifferenceCount(in: [first, second]), 2)
        XCTAssertEqual(unifiedDifferenceCount(in: [first, second]), 2)
    }

    func testEmptyDiffHasNoDifferences() {
        XCTAssertEqual(sideBySideDifferenceCount(in: []), 0)
        XCTAssertEqual(unifiedDifferenceCount(in: []), 0)
    }

    func testAnchorPointsAtTheFirstRowOfTheRequestedDifference() {
        let hunk = makeHunk(
            old: [
                line(.context, old: 1, new: 1),
                line(.deletion, old: 2, new: 0),
                line(.context, old: 3, new: 3),
                line(.deletion, old: 4, new: 0),
            ],
            new: [
                line(.context, old: 1, new: 1),
                line(.addition, old: 0, new: 2),
                line(.context, old: 3, new: 3),
                line(.addition, old: 0, new: 4),
            ]
        )
        let ordinals = sideBySideDifferenceOrdinals(in: [hunk])

        XCTAssertEqual(
            differenceAnchorID(ordinal: 0, ordinals: ordinals),
            diffRowAnchorID(hunk: 0, row: 1)
        )
        XCTAssertEqual(
            differenceAnchorID(ordinal: 1, ordinals: ordinals),
            diffRowAnchorID(hunk: 0, row: 3)
        )
        XCTAssertNil(differenceAnchorID(ordinal: 2, ordinals: ordinals))
    }

    // MARK: - Helpers

    private func makeHunk(old: [DiffLine], new: [DiffLine]) -> DiffHunk {
        DiffHunk(oldStart: 1, newStart: 1, oldLines: old, newLines: new)
    }

    private func line(
        _ kind: DiffLineKind,
        old: UInt32,
        new: UInt32,
        text: String = "line"
    ) -> DiffLine {
        DiffLine(
            kind: kind,
            oldLine: old,
            newLine: new,
            text: text,
            spans: [],
            highlights: []
        )
    }
}
