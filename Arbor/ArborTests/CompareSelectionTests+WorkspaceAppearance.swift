import XCTest
import AppKit
@testable import Arbor

extension CompareSelectionTests {
    func testGraphColorsSeparateReferencedTipsThatReuseOneLane() {
        var commits = [
            logCommit(id: "fix", parentIds: ["main"]),
            logCommit(id: "feature", parentIds: ["main"]),
            logCommit(id: "main", parentIds: ["tagged"]),
            logCommit(id: "tagged", parentIds: [])
        ]
        commits[0].refs = ["bugfix/beta"]
        commits[1].remoteRefs = ["origin/feature"]
        commits[2].isHead = true
        commits[3].tagRefs = ["v1"]
        let colors = logGraphColorIndexes(commits: commits)
        XCTAssertEqual(Set(colors.prefix(3)).count, 3)
        XCTAssertEqual(colors[2], colors[3], "A tag must not start a new branch color")
    }

    func testGraphColorsFollowMergeParentsAndRemainStableWhenPaging() {
        let commits = [
            logCommit(id: "merge", parentIds: ["left", "right"]),
            logCommit(id: "left", parentIds: ["base"]),
            logCommit(id: "right", parentIds: ["base"]),
            logCommit(id: "base", parentIds: [])
        ]
        let colors = logGraphColorIndexes(commits: commits)
        XCTAssertEqual(colors[0], colors[1])
        XCTAssertNotEqual(colors[1], colors[2])
        XCTAssertEqual(colors[1], colors[3])
        XCTAssertEqual(Array(colors.prefix(3)), logGraphColorIndexes(commits: Array(commits.prefix(3))))
        let cache = LinearBekGraphCache()
        let expanded = cache.resolve(commits: commits, collapseAll: false, expandedMergeIDs: [], collapsedMergeIDs: [])
        let collapsed = cache.resolve(commits: commits, collapseAll: true, expandedMergeIDs: [], collapsedMergeIDs: [])
        XCTAssertEqual(expanded.colorIndexes, collapsed.colorIndexes)
    }

    func testGraphColorsKeepEqualObjectIDsInSeparateRepositories() {
        let commits = [
            logCommit(id: "tip", repositoryPath: "/one", parentIds: ["base"]),
            logCommit(id: "tip", repositoryPath: "/two", parentIds: ["base"]),
            logCommit(id: "base", repositoryPath: "/one", parentIds: []),
            logCommit(id: "base", repositoryPath: "/two", parentIds: [])
        ]
        let snapshot = LinearBekGraphCache().resolve(
            commits: commits, collapseAll: false, expandedMergeIDs: [], collapsedMergeIDs: [],
            rootQualifiedIdentity: true
        )
        XCTAssertEqual(snapshot.colorIndexes[0], snapshot.colorIndexes[2])
        XCTAssertEqual(snapshot.colorIndexes[1], snapshot.colorIndexes[3])
        XCTAssertNotEqual(snapshot.colorIndexes[0], snapshot.colorIndexes[1])
    }

    func testWorkspaceFontsAreBundledAndRegistered() throws {
        let bundle = Bundle(for: ArborAppDelegate.self)
        for name in ["Inter-Regular", "Inter-SemiBold"] {
            XCTAssertNotNil(bundle.url(forResource: name, withExtension: "otf"))
            let font = try XCTUnwrap(NSFont(name: name, size: 13))
            XCTAssertEqual(font.fontName, name)
        }
        XCTAssertNotNil(bundle.url(forResource: "OFL", withExtension: "txt"))
    }

    func testCommitDatesFollowInterfaceLanguageAfterSwitching() throws {
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2024, month: 1, day: 5, hour: 17)))
        let timestamp = Int64(date.timeIntervalSince1970)
        let english = Design.Typography.commitDate(timestamp, locale: Locale(identifier: "en_US"))
        let chinese = Design.Typography.commitDate(timestamp, locale: Locale(identifier: "zh-Hans"))
        XCTAssertTrue(english.hasPrefix("05/01/24"))
        XCTAssertTrue(english.contains("PM"))
        XCTAssertTrue(chinese.hasSuffix("下午5:00"))
        XCTAssertEqual(english, Design.Typography.commitDate(timestamp, locale: Locale(identifier: "en_US")))
    }
}
