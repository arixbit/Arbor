import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {
    func testAppLanguageDefaultsToEnglishAndPreservesExplicitSelection() {
        XCTAssertEqual(AppLanguage.defaultLanguage, .english)
        XCTAssertEqual(AppLanguage.resolve(nil), .english)
        XCTAssertEqual(AppLanguage.resolve("invalid"), .english)
        XCTAssertEqual(AppLanguage.resolve("system"), .system)
        XCTAssertEqual(AppLanguage.resolve("zh-Hans"), .simplifiedChinese)
    }

    func testSearchEverywhereReferencesPreserveKindsAndRootIdentity() {
        let rootA = SearchEverywhereGitRoot(
            rootPath: "/tmp/project/app",
            displayName: "app",
            relativePath: "app",
            branches: [
                BranchInfo(name: "main", isCurrent: true, shortId: "1111111", lastCommitTime: 0),
            ],
            remoteBranches: [
                RemoteBranchInfo(name: "origin/main", remote: "origin", shortId: "2222222"),
            ],
            tags: [
                TagInfo(
                    name: "v1.0",
                    id: "3333333333333333",
                    objectId: "3333333333333333",
                    shortId: "3333333",
                    kind: .lightweight,
                    message: "",
                    isCurrent: false
                ),
            ]
        )
        let rootB = SearchEverywhereGitRoot(
            rootPath: "/tmp/project/web",
            displayName: "web",
            relativePath: "web",
            branches: [
                BranchInfo(name: "main", isCurrent: false, shortId: "4444444", lastCommitTime: 0),
            ],
            remoteBranches: [],
            tags: []
        )

        let items = searchEverywhereReferenceItems(roots: [rootA, rootB], query: "main")

        XCTAssertEqual(items.map(\.kind), [.localBranch, .remoteBranch, .localBranch])
        XCTAssertEqual(items.map(\.rootPath), [
            "/tmp/project/app",
            "/tmp/project/app",
            "/tmp/project/web",
        ])
        XCTAssertEqual(items[0].subtitle, "app · app · current")
        XCTAssertEqual(items[1].revision, "origin/main")
    }

    func testSearchEverywhereCommitQueryThresholdsMatchGitContributor() {
        XCTAssertFalse(searchEverywhereCanSearchCommitByHash("abcdef"))
        XCTAssertTrue(searchEverywhereCanSearchCommitByHash("abcdef1"))
        XCTAssertTrue(searchEverywhereCanSearchCommitByHash("ABCDEF1234567890"))
        XCTAssertFalse(searchEverywhereCanSearchCommitByHash("abcdefg"))
        XCTAssertFalse(searchEverywhereCanSearchCommitByMessage("ab"))
        XCTAssertTrue(searchEverywhereCanSearchCommitByMessage("fix"))
        XCTAssertTrue(searchEverywhereCanSearchCommitByMessage("  fix  "))
    }

    func testConfiguredUpstreamResolvesTheLongestRemotePrefix() {
        let remotes = [
            RemoteInfo(name: "corp", url: "https://example.com/corp.git", pushUrl: nil, fetchRefspec: nil, pushRefspec: nil),
            RemoteInfo(name: "corp/release", url: "https://example.com/release.git", pushUrl: nil, fetchRefspec: nil, pushRefspec: nil),
            RemoteInfo(name: "origin", url: "https://example.com/origin.git", pushUrl: nil, fetchRefspec: nil, pushRefspec: nil),
        ]

        XCTAssertEqual(
            remoteBranchTargetForConfiguredUpstream(" corp/release/2026 ", remotes: remotes)?.remote,
            "corp/release"
        )
        XCTAssertEqual(
            remoteBranchTargetForConfiguredUpstream("corp/release/2026", remotes: remotes)?.branch,
            "2026"
        )
        XCTAssertNil(remoteBranchTargetForConfiguredUpstream("upstream/main", remotes: remotes))
        XCTAssertNil(remoteBranchTargetForConfiguredUpstream("origin/", remotes: remotes))
    }

    func testGitInitializationDetectsExistingRepositoryAndNestedPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arbor-git-init-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try initializeRepository(path: root.path)

        XCTAssertEqual(
            gitInitializationExistingRepositoryRoot(path: root.path),
            root.standardizedFileURL.path
        )
        XCTAssertEqual(
            gitInitializationExistingRepositoryRoot(path: nested.path),
            root.standardizedFileURL.path
        )
    }
}
