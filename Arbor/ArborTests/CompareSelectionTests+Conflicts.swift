import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {

    func testConflictSelectionKeepsOnlyConflictedPathsInStableOrder() {
        XCTAssertEqual(
            conflictPathsForSelection(
                ["z.swift", "stale.swift", "a.swift"],
                paths: ["z.swift", "a.swift", "b.swift"]
            ),
            ["a.swift", "z.swift"]
        )
    }

    func testConflictSelectionCanBeEmpty() {
        XCTAssertTrue(conflictPathsForSelection([], paths: ["a.swift"]).isEmpty)
    }

    func testMultiRootConflictTargetsAreRootQualifiedAndStable() {
        let groups = [
            MultiRootConflictGroup(
                rootPath: "/workspace/z-root",
                displayName: "Z",
                relativePath: "z",
                operation: nil,
                paths: ["z.swift", "a.swift"]
            ),
            MultiRootConflictGroup(
                rootPath: "/workspace/a-root",
                displayName: "A",
                relativePath: "a",
                operation: nil,
                paths: ["same.swift"]
            )
        ]

        let targets = multiRootConflictTargets(from: groups)

        XCTAssertEqual(
            targets.map { "\($0.rootPath):\($0.path)" },
            ["/workspace/a-root:same.swift", "/workspace/z-root:a.swift", "/workspace/z-root:z.swift"]
        )
        XCTAssertNotEqual(
            MultiRootConflictTarget(rootPath: "/workspace/a-root", path: "same.swift").id,
            MultiRootConflictTarget(rootPath: "/workspace/z-root", path: "same.swift").id
        )
    }

    func testMultiRootConflictResolverQueueIsStableAndRebaseSupportsSkip() {
        let roots = stableMultiRootConflictResolverRoots([
            MultiRootConflictResolverRoot(
                rootPath: "/workspace/z-root",
                displayName: "Z",
                relativePath: "z",
                paths: ["z.swift"],
                kind: .operation(.merge)
            ),
            MultiRootConflictResolverRoot(
                rootPath: "/workspace/a-root",
                displayName: "A",
                relativePath: "a",
                paths: ["a.swift"],
                kind: .operation(.rebase)
            )
        ])

        XCTAssertEqual(roots.map(\.rootPath), ["/workspace/a-root", "/workspace/z-root"])
        XCTAssertTrue(roots[0].canSkip)
        XCTAssertFalse(roots[1].canSkip)
    }
}
