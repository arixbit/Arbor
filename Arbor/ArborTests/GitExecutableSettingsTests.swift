import XCTest
@testable import Arbor


final class GitExecutableSettingsTests: XCTestCase {
    func testProjectOverridePersistsIndependentlyAndCanInheritAgain() {
        let suiteName = "Arbor.GitExecutableSettingsTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        let projectPath = "/tmp/arbor-git-executable-\(UUID().uuidString)"
        let otherProjectPath = "/tmp/arbor-git-executable-other-\(UUID().uuidString)"

        XCTAssertNil(GitExecutableSettings.projectOverride(for: projectPath, defaults: suite))
        GitExecutableSettings.saveProjectOverride(" /usr/local/bin/git ", for: projectPath, defaults: suite)

        XCTAssertEqual(
            GitExecutableSettings.projectOverride(for: projectPath, defaults: suite),
            "/usr/local/bin/git"
        )
        XCTAssertNil(GitExecutableSettings.projectOverride(for: otherProjectPath, defaults: suite))

        GitExecutableSettings.saveProjectOverride(nil, for: projectPath, defaults: suite)
        XCTAssertNil(GitExecutableSettings.projectOverride(for: projectPath, defaults: suite))
    }

    func testRegisteredRootsNormalizeAndDeduplicateProjectRoots() {
        let projectPath = "/tmp/arbor-git-executable/project/.."
        let roots = GitExecutableSettings.registeredRoots(
            projectPath: projectPath,
            repositoryRoot: "/tmp/arbor-git-executable/repository/..",
            discoveredRoots: [
                "/tmp/arbor-git-executable/repository",
                "/tmp/arbor-git-executable/other/../repository"
            ]
        )

        XCTAssertEqual(
            roots,
            [
                "/tmp/arbor-git-executable",
                "/tmp/arbor-git-executable/repository"
            ]
        )
    }
}
