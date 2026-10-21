import XCTest
@testable import Arbor

final class AppUpdateCheckTests: XCTestCase {

    // MARK: - Version comparison

    func testPatchBumpComparesAsNewer() {
        XCTAssertEqual(
            appUpdateCompareVersions("1.0.21", "1.0.20"),
            .orderedDescending
        )
        XCTAssertEqual(
            appUpdateCompareVersions("1.0.20", "1.0.21"),
            .orderedAscending
        )
    }

    func testMinorBeatsLongerPatchNumber() {
        // 1.1.0 is newer than 1.0.21 even though 21 > 0 as text.
        XCTAssertEqual(
            appUpdateCompareVersions("1.1.0", "1.0.21"),
            .orderedDescending
        )
    }

    func testEqualVersionsAndVarianceTolerance() {
        XCTAssertEqual(appUpdateCompareVersions("1.0.20", "1.0.20"), .orderedSame)
        XCTAssertEqual(appUpdateCompareVersions("v1.0.20", "1.0.20"), .orderedSame)
        // Unparseable input never claims to be a different release.
        XCTAssertEqual(appUpdateCompareVersions("", "1.0.20"), .orderedSame)
        XCTAssertEqual(appUpdateCompareVersions("nonsense", "1.0.20"), .orderedSame)
    }

    func testMissingSegmentsTreatAsZero() {
        XCTAssertEqual(appUpdateCompareVersions("1.1", "1.1.0"), .orderedSame)
        XCTAssertEqual(appUpdateCompareVersions("1.2", "1.1.9"), .orderedDescending)
    }

    // MARK: - Payload parsing

    func testParseLatestReleaseExtractsTagAndLink() throws {
        let payload = """
        {
          "tag_name": "v1.0.21",
          "html_url": "https://github.com/arixbit/Arbor/releases/tag/v1.0.21",
          "name": "Arbor 1.0.21 (unsigned arm64)"
        }
        """
        let info = try XCTUnwrap(
            appUpdateParseLatestRelease(Data(payload.utf8))
        )
        XCTAssertEqual(info.version, "1.0.21")
        XCTAssertEqual(
            info.releaseURL,
            URL(string: "https://github.com/arixbit/Arbor/releases/tag/v1.0.21")
        )
        // A parsed 1.0.21 must compare newer than the running 1.0.20.
        XCTAssertEqual(
            appUpdateCompareVersions(info.version, "1.0.20"),
            .orderedDescending
        )
    }

    func testParseLatestReleaseFallsBackToReleasesPageWithoutTag() {
        let payload = #"{"message": "Not Found"}"#
        XCTAssertNil(appUpdateParseLatestRelease(Data(payload.utf8)))
    }

    // MARK: - Automatic check scheduling

    func testAutoCheckRunsOncePerInterval() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(appUpdateShouldAutoCheck(lastCheck: nil, now: now))
        XCTAssertFalse(
            appUpdateShouldAutoCheck(
                lastCheck: now.addingTimeInterval(-3600),
                now: now
            )
        )
        XCTAssertTrue(
            appUpdateShouldAutoCheck(
                lastCheck: now.addingTimeInterval(-24 * 60 * 60 - 1),
                now: now
            )
        )
        // Exactly at the interval boundary the check is due again.
        XCTAssertTrue(
            appUpdateShouldAutoCheck(
                lastCheck: now.addingTimeInterval(-24 * 60 * 60),
                now: now
            )
        )
    }
}
