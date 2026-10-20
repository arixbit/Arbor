import XCTest
@testable import Arbor


final class GitPushSettingsTests: XCTestCase {
    func testForceWithLeaseDefaultsToEnabled() {
        let suite = UserDefaults(suiteName: "Arbor.GitPushSettingsTests.default")!
        suite.removePersistentDomain(forName: "Arbor.GitPushSettingsTests.default")

        XCTAssertTrue(GitPushSettings.forceWithLeaseDefault(from: suite))
    }

    func testForceWithLeaseDefaultCanBeDisabled() {
        let suite = UserDefaults(suiteName: "Arbor.GitPushSettingsTests.disabled")!
        suite.removePersistentDomain(forName: "Arbor.GitPushSettingsTests.disabled")
        suite.set(false, forKey: GitPushSettings.forceWithLeaseDefaultKey)

        XCTAssertFalse(GitPushSettings.forceWithLeaseDefault(from: suite))
    }

    func testForceWithLeaseDecisionPreservesPushSafetyBoundaries() {
        let suite = UserDefaults(suiteName: "Arbor.GitPushSettingsTests.decision")!
        suite.removePersistentDomain(forName: "Arbor.GitPushSettingsTests.decision")

        XCTAssertFalse(GitPushSettings.useForceWithLease(force: false, requested: nil, defaults: suite))
        XCTAssertTrue(GitPushSettings.useForceWithLease(force: true, requested: nil, defaults: suite))
        XCTAssertFalse(GitPushSettings.useForceWithLease(force: true, requested: false, defaults: suite))
    }
}
