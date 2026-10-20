import XCTest
import Foundation
@testable import Arbor

final class CompareSelectionTests: XCTestCase {

    let changes = [
        TreeChange(path: "Sources/App.swift", oldPath: nil, isPureMove: false, kind: .modified, oldMode: 0o100644, newMode: 0o100644),
        TreeChange(path: "README.md", oldPath: nil, isPureMove: false, kind: .added, oldMode: 0, newMode: 0o100644),
        TreeChange(path: "Tests/AppTests.swift", oldPath: nil, isPureMove: false, kind: .deleted, oldMode: 0o100644, newMode: 0)
    ]

    func shelf(
        _ name: String,
        id: String,
        paths: [String],
        deleted: Bool = false
    ) -> ShelveInfo {
        ShelveInfo(
            name: name,
            id: id,
            shortId: String(name.prefix(7)),
            paths: paths,
            description: name,
            timestamp: 0,
            isDeleted: deleted,
            isRecycled: false,
            isPendingDelete: false
        )
    }

    func logCommit(
        id: String = "commit",
        repositoryPath: String = "/workspace/repo",
        parentIds: [String] = ["parent"]
    ) -> CommitInfo {
        CommitInfo(
            id: id,
            repositoryPath: repositoryPath,
            shortId: String(id.prefix(7)),
            summary: id,
            authorName: "A",
            authorEmail: "a@example.com",
            committerName: "A",
            committerEmail: "a@example.com",
            messageBody: "",
            hasSignature: false,
            time: 0,
            parentIds: parentIds,
            refs: [],
            tagRefs: [],
            remoteRefs: [],
            isHead: false,
            lane: 0,
            parentLanes: []
        )
    }

    func testSelectionFollowsTreeDiffOrder() {
        let selected = orderedCompareSelection(
            changes: changes,
            selectedPaths: ["Tests/AppTests.swift", "Sources/App.swift"]
        )

        XCTAssertEqual(selected.map(\.path), ["Sources/App.swift", "Tests/AppTests.swift"])
    }

    func testSelectionDropsPathsThatAreNoLongerInComparison() {
        let selected = orderedCompareSelection(
            changes: changes,
            selectedPaths: ["README.md", "stale.txt"]
        )

        XCTAssertEqual(selected.map(\.path), ["README.md"])
    }

    func testEmptySelectionHasNoChanges() {
        XCTAssertTrue(orderedCompareSelection(changes: changes, selectedPaths: []).isEmpty)
    }

    func testAdjacentChangeNavigationStopsAtBothBoundaries() {
        XCTAssertEqual(adjacentChangeIndex(count: 3, current: 1, offset: -1), 0)
        XCTAssertEqual(adjacentChangeIndex(count: 3, current: 1, offset: 1), 2)
        XCTAssertNil(adjacentChangeIndex(count: 3, current: 0, offset: -1))
        XCTAssertNil(adjacentChangeIndex(count: 3, current: 2, offset: 1))
    }

    func testAdjacentChangeNavigationRejectsInvalidRows() {
        XCTAssertNil(adjacentChangeIndex(count: 0, current: 0, offset: 1))
        XCTAssertNil(adjacentChangeIndex(count: 2, current: -1, offset: 1))
        XCTAssertNil(adjacentChangeIndex(count: 2, current: 2, offset: -1))
    }

    func testKeyboardChangeIndexStartsAtVisibleBoundaryWithoutSelection() {
        XCTAssertEqual(keyboardChangeIndex(count: 3, current: nil, offset: 1), 0)
        XCTAssertEqual(keyboardChangeIndex(count: 3, current: nil, offset: -1), 2)
        XCTAssertNil(keyboardChangeIndex(count: 0, current: nil, offset: 1))
        XCTAssertNil(keyboardChangeIndex(count: 3, current: nil, offset: 0))
    }

    func testKeyboardChangeIndexUsesAdjacentSelectionOnceFocused() {
        XCTAssertEqual(keyboardChangeIndex(count: 3, current: 1, offset: -1), 0)
        XCTAssertEqual(keyboardChangeIndex(count: 3, current: 1, offset: 1), 2)
        XCTAssertNil(keyboardChangeIndex(count: 3, current: 0, offset: -1))
        XCTAssertNil(keyboardChangeIndex(count: 3, current: 2, offset: 1))
    }
}
