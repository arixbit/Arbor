import XCTest
@testable import Arbor

@MainActor
final class CommitWorkspaceInclusionTests: XCTestCase {
    func testCommitInclusionIsSeparateForEachCanonicalRootAndPrunesCleanPaths() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("arbor-inclusion-\(UUID().uuidString)")
        let first = parent.appendingPathComponent("first")
        let alias = parent.appendingPathComponent("first-alias")
        let second = parent.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
        defer { try? FileManager.default.removeItem(at: parent) }

        let selection = CommitWorkspaceState()
        XCTAssertTrue(selection.includedPaths(for: first.path).isEmpty)
        selection.setIncluded(true, path: "src/App.swift", in: first.path)
        selection.setIncluded(true, path: "README.md", in: second.path)
        XCTAssertEqual(selection.includedPaths(for: alias.path), ["src/App.swift"])
        XCTAssertEqual(selection.includedPaths(for: second.path), ["README.md"])

        selection.retainChangedPaths([], in: alias.path)
        XCTAssertTrue(selection.includedPaths(for: first.path).isEmpty)
        XCTAssertEqual(selection.includedPaths(for: second.path), ["README.md"])
    }
}
