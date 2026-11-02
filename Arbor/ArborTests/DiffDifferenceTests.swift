import XCTest
@testable import Arbor

/// IntelliJ's diff viewer counts and navigates contiguous changed runs rather
/// than Git hunks, and shows the complete file. These tests pin the shared
/// difference numbering, the whole-file row synthesis and the anchor rows that
/// the toolbar uses for navigation.
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
        // The hunk header and the context rows are not differences; the paired
        // change in the middle is difference 0.
        XCTAssertEqual(
            sideBySideDifferenceOrdinals(sideBySideDisplayItems(fileDiff: diff([hunk]), fullFile: nil)),
            [nil, nil, 0, nil]
        )
        // The unified layout renders deletion and addition on separate rows,
        // but they remain one difference.
        XCTAssertEqual(
            unifiedDifferenceOrdinals(unifiedDisplayItems(fileDiff: diff([hunk]), fullFile: nil)),
            [nil, nil, 0, 0, nil]
        )
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

        XCTAssertEqual(sideBySideDifferenceCount(in: [hunk]), 2)
        XCTAssertEqual(unifiedDifferenceCount(in: [hunk]), 2)
        XCTAssertEqual(
            sideBySideDifferenceOrdinals(sideBySideDisplayItems(fileDiff: diff([hunk]), fullFile: nil)),
            [nil, nil, 0, nil, 1, nil]
        )
        XCTAssertEqual(
            unifiedDifferenceOrdinals(unifiedDisplayItems(fileDiff: diff([hunk]), fullFile: nil)),
            [nil, nil, 0, 0, nil, 1, 1, nil]
        )
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

        XCTAssertEqual(sideBySideDifferenceCount(in: [hunk]), 1)
        XCTAssertEqual(unifiedDifferenceCount(in: [hunk]), 1)
        XCTAssertEqual(
            sideBySideDifferenceOrdinals(sideBySideDisplayItems(fileDiff: diff([hunk]), fullFile: nil)),
            [nil, nil, 0, 0, nil]
        )
        XCTAssertEqual(
            unifiedDifferenceOrdinals(unifiedDisplayItems(fileDiff: diff([hunk]), fullFile: nil)),
            [nil, nil, 0, 0, nil]
        )
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

        XCTAssertEqual(sideBySideDifferenceCount(in: [first, second]), 2)
        XCTAssertEqual(unifiedDifferenceCount(in: [first, second]), 2)
        XCTAssertEqual(
            sideBySideDifferenceOrdinals(sideBySideDisplayItems(fileDiff: diff([first, second]), fullFile: nil)),
            [nil, 0, nil, 1]
        )
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
        let ordinals = sideBySideDifferenceOrdinals(
            sideBySideDisplayItems(fileDiff: diff([hunk]), fullFile: nil)
        )

        // Items: header, context, change, context, change. The anchors use the
        // display-item index, not the row index inside the hunk.
        XCTAssertEqual(differenceAnchorID(ordinal: 0, ordinals: ordinals), diffRowAnchorID(2))
        XCTAssertEqual(differenceAnchorID(ordinal: 1, ordinals: ordinals), diffRowAnchorID(4))
        XCTAssertNil(differenceAnchorID(ordinal: 2, ordinals: ordinals))
    }

    func testWholeFileRowsKeepUnchangedLinesBetweenHunks() {
        let oldLines = (1...20).map { "line \($0)" }
        var newLines = oldLines
        newLines[4] = "line 5 changed"
        newLines[14] = "line 15 changed"
        let fileDiff = diff([
            makeHunk(
                oldStart: 2,
                newStart: 2,
                old: [
                    contextLine(old: 2, new: 2, oldLines),
                    contextLine(old: 3, new: 3, oldLines),
                    contextLine(old: 4, new: 4, oldLines),
                    line(.deletion, old: 5, new: 0, text: oldLines[4]),
                    contextLine(old: 6, new: 6, oldLines),
                    contextLine(old: 7, new: 7, oldLines),
                ],
                new: [
                    contextLine(old: 2, new: 2, newLines),
                    contextLine(old: 3, new: 3, newLines),
                    contextLine(old: 4, new: 4, newLines),
                    line(.addition, old: 0, new: 5, text: newLines[4]),
                    contextLine(old: 6, new: 6, newLines),
                    contextLine(old: 7, new: 7, newLines),
                ]
            ),
            makeHunk(
                oldStart: 13,
                newStart: 13,
                old: [
                    contextLine(old: 13, new: 13, oldLines),
                    contextLine(old: 14, new: 14, oldLines),
                    line(.deletion, old: 15, new: 0, text: oldLines[14]),
                    contextLine(old: 16, new: 16, oldLines),
                    contextLine(old: 17, new: 17, oldLines),
                ],
                new: [
                    contextLine(old: 13, new: 13, newLines),
                    contextLine(old: 14, new: 14, newLines),
                    line(.addition, old: 0, new: 15, text: newLines[14]),
                    contextLine(old: 16, new: 16, newLines),
                    contextLine(old: 17, new: 17, newLines),
                ]
            ),
        ])

        let fullFile = FullFileDiff(oldLines: oldLines, newLines: newLines)
        let items = sideBySideDisplayItems(fileDiff: fileDiff, fullFile: fullFile)
        XCTAssertFalse(items.contains { if case .hunkHeader = $0 { return true }; return false },
                       "the whole-file presentation must not insert hunk headers")

        guard let rows = fullFileSideBySideRows(fileDiff: fileDiff, fullFile: fullFile) else {
            return XCTFail("whole-file rows were not built")
        }
        XCTAssertEqual(rows.count, 20, "every old line must appear exactly once")
        XCTAssertEqual(rows.first?.row.old?.oldLine, 1)
        XCTAssertEqual(rows.first?.row.new?.newLine, 1)
        XCTAssertEqual(rows.last?.row.old?.oldLine, 20)
        XCTAssertEqual(rows.last?.row.new?.newLine, 20)
        XCTAssertEqual(rows[4].row.old?.kind, .deletion)
        XCTAssertEqual(rows[4].row.new?.kind, .addition)

        let ordinals = sideBySideDifferenceOrdinals(items)
        XCTAssertEqual(ordinals.filter { $0 != nil }.compactMap { $0 }, [0, 1])
        XCTAssertEqual(differenceAnchorID(ordinal: 0, ordinals: ordinals), diffRowAnchorID(4))
    }

    func testWholeFileUnifiedRowsAddOneRowPerChangedLine() {
        let oldLines = ["a", "b", "c"]
        let newLines = ["a", "B", "c"]
        let hunk = makeHunk(
            old: [
                contextLine(old: 1, new: 1, oldLines),
                line(.deletion, old: 2, new: 0, text: "b"),
                contextLine(old: 3, new: 3, oldLines),
            ],
            new: [
                contextLine(old: 1, new: 1, newLines),
                line(.addition, old: 0, new: 2, text: "B"),
                contextLine(old: 3, new: 3, newLines),
            ]
        )
        let fileDiff = diff([hunk])
        let fullFile = FullFileDiff(oldLines: oldLines, newLines: newLines)
        let rows = fullFileUnifiedRows(fileDiff: fileDiff, fullFile: fullFile)

        XCTAssertEqual(rows?.count, 4)
        XCTAssertEqual(rows?.first?.oldLine, 1)
        XCTAssertEqual(rows?.last?.newLine, 3)
        XCTAssertEqual(rows?.filter { $0.prefix == "-" }.count, 1)
        XCTAssertEqual(rows?.filter { $0.prefix == "+" }.count, 1)
        XCTAssertEqual(unifiedDifferenceCount(in: fileDiff.hunks), 1)
    }

    // MARK: - Helpers

    private func diff(_ hunks: [DiffHunk]) -> FileDiff {
        FileDiff(path: "file.txt", binary: false, hunks: hunks)
    }

    private func makeHunk(
        oldStart: UInt32 = 1,
        newStart: UInt32 = 1,
        old: [DiffLine],
        new: [DiffLine]
    ) -> DiffHunk {
        DiffHunk(oldStart: oldStart, newStart: newStart, oldLines: old, newLines: new)
    }

    private func contextLine(old: Int, new: Int, _ lines: [String]) -> DiffLine {
        line(.context, old: UInt32(old), new: UInt32(new), text: lines[old - 1])
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
