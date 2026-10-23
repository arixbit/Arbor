import XCTest
@testable import Arbor

/// IntelliJ 对照：`Vcs.ShowHistoryForBlock` → `SelectedBlockHistoryAction`。
///
/// 动作作用在选区上，所以原生应用的对应物是「行选择 + 选区历史面板」。
/// 这里覆盖选择逻辑本身：单击、Shift 扩展、右键落在选区外时的降级。
final class BlockHistoryTests: XCTestCase {
    func testClickSelectsASingleLine() {
        let selection = fileContentLineSelection(anchor: nil, line: 7, extending: false)
        XCTAssertEqual(selection.anchor, 7)
        XCTAssertEqual(selection.range, 7...7)
    }

    func testClickReplacesAnExistingAnchor() {
        let selection = fileContentLineSelection(anchor: 3, line: 9, extending: false)
        XCTAssertEqual(selection.anchor, 9)
        XCTAssertEqual(selection.range, 9...9)
    }

    func testShiftClickExtendsForwardFromTheAnchor() {
        let selection = fileContentLineSelection(anchor: 3, line: 8, extending: true)
        XCTAssertEqual(selection.anchor, 3)
        XCTAssertEqual(selection.range, 3...8)
    }

    func testShiftClickExtendsBackwardFromTheAnchor() {
        let selection = fileContentLineSelection(anchor: 8, line: 2, extending: true)
        // 锚点不动，区间按行号排序。
        XCTAssertEqual(selection.anchor, 8)
        XCTAssertEqual(selection.range, 2...8)
    }

    func testShiftClickWithoutAnAnchorFallsBackToASingleLine() {
        let selection = fileContentLineSelection(anchor: nil, line: 4, extending: true)
        XCTAssertEqual(selection.anchor, 4)
        XCTAssertEqual(selection.range, 4...4)
    }

    func testContextMenuUsesTheSelectionWhenTheRowIsInsideIt() {
        let range = fileContentSelectionRange(selected: 4...9, containing: 6)
        XCTAssertEqual(range, 4...9)
    }

    func testContextMenuFallsBackToOneRowOutsideTheSelection() {
        // 右键到选区之外的行不应该沿用旧选区，否则会把一段不相干的
        // 行区间送进历史查询。
        let range = fileContentSelectionRange(selected: 4...9, containing: 12)
        XCTAssertEqual(range, 12...12)
    }

    func testContextMenuWithoutASelectionUsesTheRow() {
        let range = fileContentSelectionRange(selected: nil, containing: 5)
        XCTAssertEqual(range, 5...5)
    }

    func testLineRangeLabelDistinguishesOneLineFromMany() {
        XCTAssertEqual(blockHistoryLineRangeLabel(startLine: 5, endLine: 5), "Line 5")
        XCTAssertEqual(blockHistoryLineRangeLabel(startLine: 5, endLine: 8), "Lines 5–8")
    }
}
