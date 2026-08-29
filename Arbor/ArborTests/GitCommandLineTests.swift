import XCTest
@testable import Arbor

final class GitCommandLineTests: XCTestCase {
    func testTokenizesQuotedLogArguments() {
        XCTAssertEqual(
            tokenizeGitCommandLine("--author=\"Ada Lovelace\" --grep='release candidate'"),
            ["--author=Ada Lovelace", "--grep=release candidate"]
        )
    }

    func testTokenizesPathspecSeparator() {
        XCTAssertEqual(
            tokenizeGitCommandLine("--oneline -- 'src/with spaces/file.swift'"),
            ["--oneline", "--", "src/with spaces/file.swift"]
        )
    }

    func testCommandLogOnlyStopsPagingForExplicitMaximum() {
        XCTAssertTrue(gitLogCommandHasExplicitLimit(["--max-count=20"]))
        XCTAssertTrue(gitLogCommandHasExplicitLimit(["-n", "20"]))
        XCTAssertTrue(gitLogCommandHasExplicitLimit(["-5"]))
        XCTAssertFalse(gitLogCommandHasExplicitLimit(["--author=Ada", "--grep=release"]))
        XCTAssertEqual(gitLogCommandMaximum(["--max-count=20"]), 20)
        XCTAssertEqual(gitLogCommandMaximum(["-n", "20"]), 20)
        XCTAssertEqual(gitLogCommandMaximum(["-5"]), 5)
        XCTAssertNil(gitLogCommandMaximum(["--", "-5"]))
    }
}
