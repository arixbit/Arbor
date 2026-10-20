import XCTest
@testable import Arbor


final class GitProtectedBranchRulesTests: XCTestCase {
    func testDefaultPatternsProtectMainAndMasterOnly() {
        let patterns = GitProtectedBranchRules.patterns(from: GitProtectedBranchRules.defaultPatterns)
        XCTAssertTrue(GitProtectedBranchRules.matches("main", patterns: patterns))
        XCTAssertTrue(GitProtectedBranchRules.matches("refs/heads/master", patterns: patterns))
        XCTAssertFalse(GitProtectedBranchRules.matches("feature/main", patterns: patterns))
    }

    func testConfiguredPatternsUseAnchoredRegularExpressions() {
        let patterns = GitProtectedBranchRules.patterns(from: "release/.*\n^hotfix$")
        XCTAssertTrue(GitProtectedBranchRules.matches("release/2026.08", patterns: patterns))
        XCTAssertTrue(GitProtectedBranchRules.matches("hotfix", patterns: patterns))
        XCTAssertFalse(GitProtectedBranchRules.matches("hotfix/urgent", patterns: patterns))
    }

    func testInvalidPatternsDoNotBlockUnrelatedPushes() {
        let patterns = GitProtectedBranchRules.patterns(from: "[")
        XCTAssertFalse(GitProtectedBranchRules.matches("main", patterns: patterns))
    }

    func testGitHubMasksMatchIntelliJPatternUtilSemantics() {
        XCTAssertEqual(GitProtectedBranchRules.githubMaskToRegex("release/*"), "release\\/.*")
        XCTAssertEqual(GitProtectedBranchRules.githubMaskToRegex("feature?"), "feature.")
        XCTAssertEqual(GitProtectedBranchRules.githubMaskToRegex("release.v1"), "release\\.v1")

        let patterns = [GitProtectedBranchRules.githubMaskToRegex("release/*")]
        XCTAssertTrue(GitProtectedBranchRules.matches("release/2026.08", patterns: patterns))
        XCTAssertFalse(GitProtectedBranchRules.matches("release-candidate", patterns: patterns))
    }

    func testRemotePatternsAreProjectScopedAndCanBeCombinedSafely() {
        let suiteName = "Arbor.GitProtectedBranchRulesTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        let path = "/tmp/arbor-protected-\(UUID().uuidString)"
        GitProtectedBranchRules.saveRemotePatterns(["release/.*", "main"], for: path, defaults: suite)

        XCTAssertEqual(
            GitProtectedBranchRules.loadRemotePatterns(for: path, defaults: suite),
            ["release/.*", "main"]
        )
        XCTAssertEqual(
            GitProtectedBranchRules.combinedPatterns(
                localRawValue: "main\nfeature/.*",
                remotePatterns: ["release/.*", "main"],
                synchronize: true
            ),
            ["main", "feature/.*", "release/.*"]
        )
        XCTAssertEqual(
            GitProtectedBranchRules.combinedPatterns(
                localRawValue: "main",
                remotePatterns: ["release/.*"],
                synchronize: false
            ),
            ["main"]
        )
        XCTAssertEqual(
            GitProtectedBranchRules.synchronizedRemotePatterns(
                cachedPatterns: ["main", "release/.*"],
                fetchedPatterns: ["main", "hotfix"],
                hasProviderFailure: true
            ),
            ["hotfix", "main", "release/.*"]
        )
        XCTAssertEqual(
            GitProtectedBranchRules.synchronizedRemotePatterns(
                cachedPatterns: ["stale"],
                fetchedPatterns: ["main"],
                hasProviderFailure: false
            ),
            ["main"]
        )
    }

    func testMultiRootRemotePatternsDoNotCrossProtectRepositories() {
        let firstRoot = "/tmp/arbor-protected-root-a-\(UUID().uuidString)"
        let secondRoot = "/tmp/arbor-protected-root-b-\(UUID().uuidString)"
        let patternsByRoot = [
            URL(fileURLWithPath: firstRoot).standardizedFileURL.path: ["release/.*"],
            URL(fileURLWithPath: secondRoot).standardizedFileURL.path: ["stable"]
        ]

        XCTAssertEqual(
            GitProtectedBranchRules.remotePatterns(
                forRootPath: firstRoot,
                primaryPatterns: ["main"],
                patternsByRoot: patternsByRoot
            ),
            ["release/.*"]
        )
        XCTAssertEqual(
            GitProtectedBranchRules.remotePatterns(
                forRootPath: secondRoot,
                primaryPatterns: ["main"],
                patternsByRoot: patternsByRoot
            ),
            ["stable"]
        )
        XCTAssertTrue(
            GitProtectedBranchRules.matches(
                "stable",
                patterns: GitProtectedBranchRules.remotePatterns(
                    forRootPath: secondRoot,
                    primaryPatterns: ["main"],
                    patternsByRoot: patternsByRoot
                )
            )
        )
        XCTAssertFalse(
            GitProtectedBranchRules.matches(
                "release/2026.08",
                patterns: GitProtectedBranchRules.remotePatterns(
                    forRootPath: secondRoot,
                    primaryPatterns: ["main"],
                    patternsByRoot: patternsByRoot
                )
            )
        )
    }

    func testProjectProtectedBranchSettingsOverrideAndThenInheritGlobalValues() {
        let suiteName = "Arbor.GitProtectedBranchRulesTests.project.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        suite.set("main\nmaster", forKey: GitProtectedBranchRules.userDefaultsKey)
        suite.set(false, forKey: GitProtectedBranchRules.synchronizeKey)

        let path = "/tmp/arbor-protected-project-\(UUID().uuidString)"
        let otherPath = "/tmp/arbor-protected-other-\(UUID().uuidString)"
        XCTAssertEqual(
            GitProtectedBranchRules.globalRawValue(from: suite),
            "main\nmaster"
        )
        XCTAssertEqual(
            GitProtectedBranchRules.synchronizeRemotePatterns(for: path, defaults: suite),
            false
        )

        GitProtectedBranchRules.saveProjectPatterns("release/.*", for: path, defaults: suite)
        GitProtectedBranchRules.saveProjectSynchronize(true, for: path, defaults: suite)
        XCTAssertEqual(
            GitProtectedBranchRules.projectRawValue(for: path, defaults: suite),
            "release/.*"
        )
        XCTAssertEqual(
            GitProtectedBranchRules.synchronizeRemotePatterns(for: path, defaults: suite),
            true
        )
        XCTAssertNil(GitProtectedBranchRules.projectRawValue(for: otherPath, defaults: suite))
        XCTAssertEqual(
            GitProtectedBranchRules.synchronizeRemotePatterns(for: otherPath, defaults: suite),
            false
        )

        GitProtectedBranchRules.saveProjectPatterns(nil, for: path, defaults: suite)
        GitProtectedBranchRules.saveProjectSynchronize(nil, for: path, defaults: suite)
        XCTAssertNil(GitProtectedBranchRules.projectRawValue(for: path, defaults: suite))
        XCTAssertNil(GitProtectedBranchRules.projectSynchronizeValue(for: path, defaults: suite))
        XCTAssertEqual(
            GitProtectedBranchRules.synchronizeRemotePatterns(for: path, defaults: suite),
            false
        )
    }
}
