import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {

    func testBranchComparisonSeparatesHistoryFromWorkingTreeDiff() {
        XCTAssertEqual(
            branchComparisonLogViewMode(workingTreeDiff: false),
            .compareBranches
        )
        XCTAssertEqual(
            branchComparisonLogViewMode(workingTreeDiff: true),
            .compare
        )
    }

    func testBranchComparisonFilterValidatesDatesPerPane() {
        XCTAssertNil(
            branchComparisonFilterDateError(
                BranchComparisonFilter(since: "2026-08-01", until: "2026-08-24"),
                side: .first
            )
        )

        XCTAssertEqual(
            branchComparisonFilterDateError(
                BranchComparisonFilter(since: "not-a-date"),
                side: .first
            ),
            "左侧 Since 必须是 YYYY-MM-DD、YYYY-MM-DD HH:mm 或 Unix seconds"
        )
        XCTAssertEqual(
            branchComparisonFilterDateError(
                BranchComparisonFilter(until: "2026-99-99"),
                side: .second
            ),
            "右侧 Until 必须是 YYYY-MM-DD、YYYY-MM-DD HH:mm 或 Unix seconds"
        )
    }

    func testBranchComparisonGraphSelectionPreservesSamePaneMultiSelection() {
        XCTAssertEqual(
            branchComparisonGraphSelection(
                current: ["a", "b"],
                selectedID: "b",
                validIDs: ["a", "b", "c"]
            ),
            ["a", "b"]
        )
        XCTAssertEqual(
            branchComparisonGraphSelection(
                current: ["a"],
                selectedID: "c",
                validIDs: ["a", "b", "c"]
            ),
            ["c"]
        )
        XCTAssertNil(
            branchComparisonGraphSelection(
                current: ["a"],
                selectedID: "missing",
                validIDs: ["a", "b"]
            )
        )
    }

    func testBranchComparisonPaginationProjectsOnlyNewUniqueEntries() {
        let commits = [
            CommitInfo(
                id: "a", repositoryPath: "/repo", shortId: "a", summary: "a",
                authorName: "A", authorEmail: "a@example.com", committerName: "A",
                committerEmail: "a@example.com", messageBody: "", hasSignature: false,
                time: 0, parentIds: [], refs: [], tagRefs: [], remoteRefs: [],
                isHead: false, lane: 0, parentLanes: []
            ),
            CommitInfo(
                id: "b", repositoryPath: "/repo", shortId: "b", summary: "b",
                authorName: "A", authorEmail: "a@example.com", committerName: "A",
                committerEmail: "a@example.com", messageBody: "", hasSignature: false,
                time: 0, parentIds: [], refs: [], tagRefs: [], remoteRefs: [],
                isHead: false, lane: 0, parentLanes: []
            ),
            CommitInfo(
                id: "c", repositoryPath: "/repo", shortId: "c", summary: "c",
                authorName: "A", authorEmail: "a@example.com", committerName: "A",
                committerEmail: "a@example.com", messageBody: "", hasSignature: false,
                time: 0, parentIds: [], refs: [], tagRefs: [], remoteRefs: [],
                isHead: false, lane: 0, parentLanes: []
            )
        ]
        XCTAssertEqual(
            branchComparisonNewEntries(
                returned: commits + [commits[1]],
                existingIDs: ["a"]
            ).map(\.id),
            ["b", "c"]
        )
        XCTAssertTrue(
            branchComparisonHasMore(
                returnedCount: 80,
                requestedLimit: 80,
                isHashQuery: false
            )
        )
        XCTAssertFalse(
            branchComparisonHasMore(
                returnedCount: 80,
                requestedLimit: 80,
                isHashQuery: true
            )
        )
    }

    func testBranchComparisonRefreshKeepsSelectionFromOtherPane() {
        XCTAssertEqual(
            branchComparisonSelectionAfterRefresh(
                selectedID: "second-commit",
                firstIDs: ["first-commit"],
                secondIDs: ["second-commit"]
            ).id,
            "second-commit"
        )
        XCTAssertEqual(
            branchComparisonSelectionAfterRefresh(
                selectedID: "removed-first-commit",
                firstIDs: [],
                secondIDs: ["second-commit"]
            ).side,
            .second
        )
        XCTAssertNil(
            branchComparisonSelectionAfterRefresh(
                selectedID: "removed",
                firstIDs: [],
                secondIDs: []
            ).id
        )
    }

    func testBranchComparisonLogTabIsRootQualifiedAndPreservesRange() throws {
        let tab = makeBranchComparisonLogTab(
            first: " feature ",
            second: "main",
            rootPath: "/workspace/project/./nested"
        )

        XCTAssertEqual(tab.title, "Compare: feature ↔ main")
        XCTAssertEqual(tab.viewMode, .compareBranches)
        XCTAssertEqual(tab.rootPath, "/workspace/project/nested")
        XCTAssertEqual(tab.compareRepositoryPath, "/workspace/project/nested")
        XCTAssertEqual(tab.compareRevision1, "feature")
        XCTAssertEqual(tab.compareRevision2, "main")
        XCTAssertFalse(tab.compareWithWorkingTree)

        var filteredTab = tab
        filteredTab.compareFirstFilter = BranchComparisonFilter(
            message: "fix",
            author: "alice",
            since: "2026-08-01",
            until: "2026-08-26",
            messageRegex: true,
            messageMatchCase: true,
            noMerges: true
        )
        filteredTab.compareSecondFilter = BranchComparisonFilter(author: "bob")

        let decoded = try JSONDecoder().decode(
            LogTabDescriptor.self,
            from: JSONEncoder().encode(filteredTab)
        )
        XCTAssertEqual(decoded, filteredTab)
    }

    func testTreeComparisonLogTabsSeparateCommittedAndWorkingTreeDiffs() {
        let committed = makeTreeComparisonLogTab(
            first: "feature",
            second: "main",
            rootPath: "/workspace/project/./nested",
            comparesWithWorkingTree: false
        )
        XCTAssertEqual(committed.title, "Diff: feature ↔ main")
        XCTAssertEqual(committed.viewMode, .compare)
        XCTAssertEqual(committed.rootPath, "/workspace/project/nested")
        XCTAssertFalse(committed.compareWithWorkingTree)

        let workingTree = makeTreeComparisonLogTab(
            first: "feature",
            second: "ignored",
            rootPath: "/workspace/project/nested",
            comparesWithWorkingTree: true
        )
        XCTAssertEqual(workingTree.title, "Diff: feature ↔ Working Tree")
        XCTAssertTrue(workingTree.compareWithWorkingTree)
        XCTAssertNotEqual(
            committed.compareWithWorkingTree,
            workingTree.compareWithWorkingTree
        )
    }

    func testCompareBranchesSwapSidesSettingIsProjectScoped() {
        let suiteName = "Arbor.GitCompareBranchesSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstProject = "/workspace/compare-one"
        let secondProject = "/workspace/compare-two"
        XCTAssertFalse(
            GitCompareBranchesSettings.swapSides(for: firstProject, defaults: defaults)
        )

        GitCompareBranchesSettings.saveSwapSides(
            true,
            for: firstProject,
            defaults: defaults
        )

        XCTAssertTrue(
            GitCompareBranchesSettings.swapSides(for: firstProject, defaults: defaults)
        )
        XCTAssertFalse(
            GitCompareBranchesSettings.swapSides(for: secondProject, defaults: defaults)
        )
    }
}
