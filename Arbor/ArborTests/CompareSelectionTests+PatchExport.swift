import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {

    func testComparePatchArgumentsKeepRevisionsAndPathsAsSeparateArguments() {
        XCTAssertEqual(
            comparePatchGitArguments(
                rev1: "feature/with spaces",
                rev2: "release;echo unsafe",
                comparesWithWorkingTree: false,
                paths: ["Sources/A B.swift", "README.md"]
            ),
            [
                "--binary",
                "--no-ext-diff",
                "feature/with spaces",
                "release;echo unsafe",
                "--",
                "Sources/A B.swift",
                "README.md"
            ]
        )
        XCTAssertEqual(
            comparePatchGitArguments(
                rev1: "HEAD",
                rev2: "ignored",
                comparesWithWorkingTree: true,
                paths: ["file.txt"]
            ),
            ["--binary", "--no-ext-diff", "HEAD", "--", "file.txt"]
        )
    }

    func testLogPatchCommandsKeepParentAndPathspecBoundaries() {
        let merge = logCommit(id: "merge", parentIds: ["left", "right"])
        XCTAssertEqual(
            logPatchGitCommand(
                commit: merge,
                parentIndex: 1,
                paths: ["Sources/App.swift"]
            ),
            LogPatchGitCommand(
                command: "diff",
                args: ["--binary", "--no-ext-diff", "right", "merge", "--", "Sources/App.swift"]
            )
        )
        XCTAssertEqual(
            logPatchGitCommand(
                commit: logCommit(id: "root", parentIds: []),
                parentIndex: nil,
                paths: ["README.md"]
            ),
            LogPatchGitCommand(
                command: "show",
                args: ["--format=", "--binary", "--no-ext-diff", "--root", "root", "--", "README.md"]
            )
        )
        XCTAssertNil(
            logPatchGitCommand(
                commit: merge,
                parentIndex: 2,
                paths: ["Sources/App.swift"]
            )
        )
        XCTAssertNil(
            logPatchGitCommand(
                commit: merge,
                parentIndex: 0,
                paths: []
            )
        )
    }

    func testPatchExportBaseDirectoryRejectsPathsOutsideSelectedBase() {
        let root = "/tmp/arbor-patch-export-root"
        XCTAssertEqual(
            patchExportBaseDirectoryRelativePath(
                repositoryRootPath: root,
                baseDirectory: root + "/Sources",
                paths: ["Sources/App.swift", "Sources/Model.swift"]
            ),
            "Sources"
        )
        XCTAssertTrue(
            patchExportBaseDirectoryIsValid(
                repositoryRootPath: root,
                baseDirectory: root,
                paths: ["Sources/App.swift", "Docs/README.md"]
            )
        )
        XCTAssertFalse(
            patchExportBaseDirectoryIsValid(
                repositoryRootPath: root,
                baseDirectory: root + "/Sources",
                paths: ["Sources/App.swift", "Docs/README.md"]
            )
        )
        XCTAssertNil(
            patchExportBaseDirectoryRelativePath(
                repositoryRootPath: root,
                baseDirectory: "/tmp/arbor-patch-export-root-sibling",
                paths: ["Sources/App.swift"]
            )
        )
    }

    func testPatchExportArgumentsPreserveAndToggleExistingReverseFlag() {
        let baseArguments = ["--binary", "--no-ext-diff", "HEAD", "--", "Sources/App.swift"]
        XCTAssertEqual(
            patchExportGitArguments(
                baseArguments: baseArguments,
                repositoryRootPath: "/tmp/arbor-patch-export-root",
                paths: ["Sources/App.swift"],
                options: PatchExportOptions(
                    baseDirectory: "/tmp/arbor-patch-export-root/Sources",
                    reverse: true,
                    copyToClipboard: false,
                    encoding: .utf8
                )
            ),
            ["--binary", "--no-ext-diff", "HEAD", "--reverse", "--relative=Sources", "--", "Sources/App.swift"]
        )

        XCTAssertEqual(
            patchExportGitArguments(
                baseArguments: ["--binary", "--reverse", "--", "Sources/App.swift"],
                repositoryRootPath: "/tmp/arbor-patch-export-root",
                paths: ["Sources/App.swift"],
                options: PatchExportOptions(
                    baseDirectory: nil,
                    reverse: false,
                    copyToClipboard: false,
                    encoding: .utf8
                )
            ),
            ["--binary", "--reverse", "--", "Sources/App.swift"]
        )
        XCTAssertEqual(
            patchExportGitArguments(
                baseArguments: ["--binary", "--reverse", "--", "Sources/App.swift"],
                repositoryRootPath: "/tmp/arbor-patch-export-root",
                paths: ["Sources/App.swift"],
                options: PatchExportOptions(
                    baseDirectory: nil,
                    reverse: true,
                    copyToClipboard: false,
                    encoding: .utf8
                )
            ),
            ["--binary", "--", "Sources/App.swift"]
        )
    }

    func testPatchExportTextKeepsCommitHeaderAndStableMultiPartBoundary() {
        XCTAssertEqual(
            patchTextWithCommitMessage("diff --git a/a.txt b/a.txt\n", commitMessage: "Add feature\n\nDetails"),
            "Subject: [PATCH] Add feature\n\nDetails\n---\ndiff --git a/a.txt b/a.txt\n"
        )
        XCTAssertEqual(
            joinedGitPatchParts(["first\n", "second", "", "third\n\n"]),
            "first\nsecond\nthird\n"
        )
        XCTAssertEqual(joinedGitPatchParts([]), "")
    }

    func testPatchExportEncodingUsesExplicitBytesAndRejectsLossyConversion() throws {
        XCTAssertEqual(
            try patchExportData("café", encoding: .isoLatin1),
            Data([0x63, 0x61, 0x66, 0xE9])
        )
        XCTAssertThrowsError(try patchExportData("😀", encoding: .isoLatin1))
        XCTAssertEqual(
            try patchExportData("😀", encoding: .utf8),
            Data("😀".utf8)
        )
    }

    func testPatchExportDataPreservesNonUtf8BytesOnlyForExplicitUtf8Output() throws {
        let rawPatch = Data([0x64, 0xE9, 0x0A])
        XCTAssertEqual(
            try patchExportData(rawPatch, encoding: .utf8),
            rawPatch
        )
        XCTAssertThrowsError(try patchExportData(rawPatch, encoding: .utf16))
        XCTAssertThrowsError(try patchExportData(rawPatch, encoding: .isoLatin1))
        XCTAssertThrowsError(try patchExportData(rawPatch, encoding: .windows1252))
    }

    func testJoinedGitPatchDataPreservesPayloadAndNormalizesSeparators() throws {
        XCTAssertEqual(
            joinedGitPatchData([
                Data([0x64, 0xE9, 0x0A]),
                Data([0x73, 0x65, 0x63, 0x6F, 0x6E, 0x64])
            ]),
            Data([0x64, 0xE9, 0x0A, 0x73, 0x65, 0x63, 0x6F, 0x6E, 0x64, 0x0A])
        )
    }

    func testPatchExportCommitHeaderDoesNotCorruptRawBody() throws {
        let rawPatch = Data([0x64, 0xE9, 0x0A])
        XCTAssertEqual(
            try patchExportData(
                rawPatch,
                commitMessage: "subject",
                encoding: .utf8
            ),
            Data("Subject: [PATCH] subject\n---\n".utf8) + rawPatch
        )
    }

    func testPatchExportSettingsAreProjectScopedAndRememberDestination() throws {
        let suiteName = "ArborTests.PatchExport.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstRoot = "/tmp/arbor-patch-settings-one"
        let secondRoot = "/tmp/arbor-patch-settings-two"
        XCTAssertEqual(PatchExportSettings.encoding(for: firstRoot, defaults: defaults), .utf8)
        XCTAssertFalse(PatchExportSettings.copyToClipboard(for: firstRoot, defaults: defaults))

        let options = PatchExportOptions(
            baseDirectory: nil,
            reverse: false,
            copyToClipboard: true,
            encoding: .windows1252
        )
        PatchExportSettings.save(options, for: firstRoot, defaults: defaults)
        XCTAssertEqual(
            PatchExportSettings.encoding(for: firstRoot, defaults: defaults),
            .windows1252
        )
        XCTAssertTrue(PatchExportSettings.copyToClipboard(for: firstRoot, defaults: defaults))
        XCTAssertEqual(PatchExportSettings.encoding(for: secondRoot, defaults: defaults), .utf8)
        XCTAssertFalse(PatchExportSettings.copyToClipboard(for: secondRoot, defaults: defaults))

        let destination = URL(fileURLWithPath: "/tmp/patch.patch")
        PatchExportSettings.saveDestination(destination, for: firstRoot, defaults: defaults)
        XCTAssertEqual(
            PatchExportSettings.lastDirectory(for: firstRoot, defaults: defaults)?.path,
            "/tmp"
        )
    }
}
