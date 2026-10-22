import XCTest
@testable import Arbor

/// The project tree resolves a row's status from a per-snapshot index instead
/// of scanning every changed entry for every row. These tests pin the
/// aggregation rules (conflict wins, otherwise the first notable kind) that
/// the scanned implementation used to produce.
final class ProjectFileTreeStatusIndexTests: XCTestCase {
    private func entry(
        _ path: String,
        staged: ChangeKind = .unchanged,
        unstaged: ChangeKind = .unchanged
    ) -> FileEntry {
        FileEntry(path: path, oldPath: nil, staged: staged, unstaged: unstaged)
    }

    func testFileStatusComesFromItsOwnEntryOnly() {
        let index = ProjectFileTreeStatusIndex(entries: [
            entry("Sources/App.swift", unstaged: .modified),
            entry("Sources/AppTests.swift", unstaged: .added),
        ])

        XCTAssertEqual(index.kind(path: "Sources/App.swift", isDirectory: false), .modified)
        XCTAssertEqual(index.kind(path: "Sources/AppTests.swift", isDirectory: false), .added)
        XCTAssertNil(index.kind(path: "Sources/Untracked.swift", isDirectory: false))
    }

    func testFileStatusDoesNotMatchALongerSiblingPath() {
        let index = ProjectFileTreeStatusIndex(entries: [
            entry("Sources/App.swift", unstaged: .modified),
        ])

        XCTAssertNil(index.kind(path: "Sources/App", isDirectory: false))
    }

    func testDirectoryAggregatesDescendants() {
        let index = ProjectFileTreeStatusIndex(entries: [
            entry("Sources/Model/User.swift", unstaged: .untracked),
            entry("Sources/View/Root.swift", unstaged: .modified),
        ])

        XCTAssertEqual(index.kind(path: "Sources/Model", isDirectory: true), .untracked)
        XCTAssertEqual(index.kind(path: "Sources", isDirectory: true), .untracked)
        XCTAssertNil(index.kind(path: "Docs", isDirectory: true))
    }

    func testIgnoredAndUnchangedEntriesDoNotColourARow() {
        let index = ProjectFileTreeStatusIndex(entries: [
            entry("build", staged: .ignored, unstaged: .ignored),
            entry("README.md", unstaged: .unchanged),
        ])

        XCTAssertNil(index.kind(path: "build", isDirectory: true))
        XCTAssertNil(index.kind(path: "README.md", isDirectory: false))
    }

    func testConflictWinsOverOtherKindsInADirectory() {
        let index = ProjectFileTreeStatusIndex(entries: [
            entry("Sources/A.swift", unstaged: .modified),
            entry("Sources/B.swift", staged: .conflicted, unstaged: .conflicted),
        ])

        XCTAssertEqual(index.kind(path: "Sources", isDirectory: true), .conflicted)
        XCTAssertEqual(index.kind(path: "Sources/B.swift", isDirectory: false), .conflicted)
    }
}
