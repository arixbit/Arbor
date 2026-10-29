import XCTest
@testable import Arbor

final class AppUpdateCheckTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppUpdateCheckTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testNewInstallUsesSparkleDefault() {
        XCTAssertNil(appUpdateLegacyAutomaticCheckPreference(in: defaults))
    }

    func testExistingOptOutIsPreserved() {
        defaults.set(false, forKey: "arbor.autoCheckForUpdates")
        XCTAssertEqual(appUpdateLegacyAutomaticCheckPreference(in: defaults), false)
    }

    func testExistingOptInIsPreserved() {
        defaults.set(true, forKey: "arbor.autoCheckForUpdates")
        XCTAssertEqual(appUpdateLegacyAutomaticCheckPreference(in: defaults), true)
    }

    func testSparklePreferenceTakesPrecedenceAfterMigration() {
        defaults.set(false, forKey: "arbor.autoCheckForUpdates")
        defaults.set(true, forKey: "SUEnableAutomaticChecks")
        XCTAssertNil(appUpdateLegacyAutomaticCheckPreference(in: defaults))
    }

    func testUITestLaunchKeepsTheUpdaterIdle() {
        XCTAssertTrue(isUITestLaunch(environment: ["ARBOR_UI_TEST": "1"]))
        XCTAssertFalse(isUITestLaunch(environment: ["ARBOR_UI_TEST": "0"]))
        XCTAssertFalse(isUITestLaunch(environment: [:]))
    }

    @MainActor
    func testPackagedAppContainsUpdaterAndFeedConfiguration() throws {
        let bundle = Bundle(for: ArborAppDelegate.self)
        XCTAssertEqual(
            bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            "https://github.com/arixbit/Arbor/releases/latest/download/appcast.xml"
        )
        let key = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
        XCTAssertEqual(Data(base64Encoded: key)?.count, 32)
        let frameworks = try XCTUnwrap(bundle.privateFrameworksURL)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: frameworks.appendingPathComponent("Sparkle.framework").path
        ))
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "SUAutomaticallyUpdate") as? Bool, false)
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "SUSendProfileInfo") as? Bool, false)
    }
}
