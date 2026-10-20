import XCTest
@testable import Arbor


final class GitDeleteOnMergeOptionTests: XCTestCase {
    func testDefaultIsToProposeDeletion() {
        let suiteName = "Arbor.GitDeleteOnMergeOptionTests.default.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            GitDeleteOnMergeOption.choice(from: suite),
            .propose
        )
    }

    func testConfiguredOptionIsLoadedAndInvalidValuesUseDefault() {
        let suiteName = "Arbor.GitDeleteOnMergeOptionTests.configured.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        suite.set(GitDeleteOnMergeOption.delete.rawValue, forKey: GitDeleteOnMergeOption.key)
        XCTAssertEqual(GitDeleteOnMergeOption.choice(from: suite), .delete)

        suite.set("invalid", forKey: GitDeleteOnMergeOption.key)
        XCTAssertEqual(GitDeleteOnMergeOption.choice(from: suite), .propose)
    }

    func testOnlyEligibleLocalBranchesUseConfiguredAction() {
        XCTAssertEqual(
            GitDeleteOnMergeOption.effectiveOption(.delete, canDeleteBranch: true),
            .delete
        )
        XCTAssertEqual(
            GitDeleteOnMergeOption.effectiveOption(.propose, canDeleteBranch: true),
            .propose
        )
        XCTAssertEqual(
            GitDeleteOnMergeOption.effectiveOption(.nothing, canDeleteBranch: true),
            .nothing
        )
        XCTAssertEqual(
            GitDeleteOnMergeOption.effectiveOption(.delete, canDeleteBranch: false),
            .nothing
        )
    }

    func testMultiRootMergeDeleteTargetsAreRootQualifiedAndDeduplicated() {
        let candidates = [
            MultiRootMergeDeleteCandidate(rootPath: "/project/app", displayName: "App"),
            MultiRootMergeDeleteCandidate(rootPath: "/project/docs", displayName: "Docs"),
            MultiRootMergeDeleteCandidate(rootPath: "/project/app", displayName: "Duplicate App")
        ]

        XCTAssertEqual(
            multiRootMergeDeleteTargets(
                selectedRootPaths: ["/project/docs/", "/project/app"],
                candidates: candidates
            ),
            [
                MultiRootMergeDeleteCandidate(rootPath: "/project/app", displayName: "App"),
                MultiRootMergeDeleteCandidate(rootPath: "/project/docs", displayName: "Docs")
            ]
        )
    }
}
