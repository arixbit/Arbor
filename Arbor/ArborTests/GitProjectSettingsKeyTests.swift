import XCTest
@testable import Arbor

final class GitProjectSettingsKeyTests: XCTestCase {
    func testProjectKeysKeepLegacyPathEncoding() {
        let cases = [
            ("/projects/arbor", "L3Byb2plY3RzL2FyYm9y"),
            ("/projects/nested/../arbor", "L3Byb2plY3RzL2FyYm9y"),
            ("/projects/工程", "L3Byb2plY3RzL+W3peeoiw=="),
            ("/", "Lw==")
        ]
        for (path, encodedPath) in cases {
            XCTAssertEqual(gitProjectSettingsKey("legacy:", for: path), "legacy:" + encodedPath)
        }
    }

    func testExistingProjectValuesRemainReadable() {
        let suiteName = "Arbor.GitProjectSettingsKeyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let projectPath = "/projects/nested/../arbor"
        defaults.set(true, forKey: "arbor.git.signOffCommit.project.v1:L3Byb2plY3RzL2FyYm9y")
        defaults.set(true, forKey: "arbor.git.pushAutoUpdate.project.v1:L3Byb2plY3RzL2FyYm9y")
        defaults.set(false, forKey: "arbor.git.branchesPopup.project.v1:L3Byb2plY3RzL2FyYm9y:showTags")

        XCTAssertTrue(GitSignOffCommitSettings.value(for: projectPath, defaults: defaults))
        XCTAssertTrue(GitPushAutoUpdateSettings.value(for: projectPath, defaults: defaults))
        XCTAssertFalse(GitBranchesPopupSettings.value(
            GitBranchesPopupSettings.showTagsKey,
            for: projectPath,
            defaults: defaults
        ))
        XCTAssertEqual(
            GitIncomingCheckStrategySettings.projectKey(for: projectPath),
            "arbor.git.incomingCheckStrategy.project.v1:L3Byb2plY3RzL2FyYm9y"
        )
        let invalidPaths: [String?] = [nil, ""]
        for invalidPath in invalidPaths {
            XCTAssertNil(GitIncomingCheckStrategySettings.projectKey(for: invalidPath))
            XCTAssertFalse(GitPushAutoUpdateSettings.value(for: invalidPath, defaults: defaults))
        }
    }
}
