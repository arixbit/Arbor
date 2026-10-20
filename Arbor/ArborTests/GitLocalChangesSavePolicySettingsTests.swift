import XCTest
@testable import Arbor


final class GitLocalChangesSavePolicySettingsTests: XCTestCase {
    func testIntelliJDefaultIsShelf() {
        let suiteName = "Arbor.GitLocalChangesSavePolicyTests.default"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)

        XCTAssertEqual(
            GitLocalChangesSavePolicySettings.choice(from: suite),
            .shelve
        )
        XCTAssertEqual(
            GitLocalChangesSavePolicySettings.engineValue(from: suite),
            .shelve
        )
    }

    func testConfiguredStashPolicyMapsToEngine() {
        let suiteName = "Arbor.GitLocalChangesSavePolicyTests.stash"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        suite.set(GitLocalChangesSavePolicyChoice.stash.rawValue, forKey: GitLocalChangesSavePolicySettings.key)

        XCTAssertEqual(
            GitLocalChangesSavePolicySettings.engineValue(from: suite),
            .stash
        )
    }

    func testInvalidStoredPolicyUsesShelfDefault() {
        let suiteName = "Arbor.GitLocalChangesSavePolicyTests.invalid"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        suite.set("invalid", forKey: GitLocalChangesSavePolicySettings.key)

        XCTAssertEqual(
            GitLocalChangesSavePolicySettings.choice(from: suite),
            .shelve
        )
    }
}
