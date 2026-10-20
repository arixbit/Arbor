import CoreServices
import XCTest
@testable import Arbor

extension RepositoryFileChangeMonitorTests {
    func testGitIgnoreActionOnlyTargetsUnversionedUnstagedFiles() {
        XCTAssertTrue(
            gitIgnoreActionAvailable(
                for: FileEntry(
                    path: "build.log",
                    oldPath: nil,
                    staged: .unchanged,
                    unstaged: .untracked
                )
            )
        )
        XCTAssertFalse(
            gitIgnoreActionAvailable(
                for: FileEntry(
                    path: "tracked.txt",
                    oldPath: nil,
                    staged: .unchanged,
                    unstaged: .modified
                )
            )
        )
        XCTAssertFalse(
            gitIgnoreActionAvailable(
                for: FileEntry(
                    path: "staged.log",
                    oldPath: nil,
                    staged: .added,
                    unstaged: .unchanged
                )
            )
        )
        XCTAssertFalse(
            gitIgnoreActionAvailable(
                for: FileEntry(
                    path: "already-ignored.log",
                    oldPath: nil,
                    staged: .unchanged,
                    unstaged: .ignored
                )
            )
        )
    }

    func testGitIgnoreCandidatesFollowTargetAncestryAndProduceRelativeRules() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ArborGitIgnoreCandidates-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources/Feature"),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: root.appendingPathComponent(".gitignore").path,
            contents: Data()
        )
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("Sources/.gitignore").path,
            contents: Data()
        )
        let target = root.appendingPathComponent("Sources/Feature/new.txt")
        FileManager.default.createFile(atPath: target.path, contents: Data())

        let candidates = gitIgnoreFileCandidates(
            for: target.path,
            workdir: root.path
        )
        XCTAssertEqual(
            candidates,
            [
                root.appendingPathComponent("Sources/.gitignore").path,
                root.appendingPathComponent(".gitignore").path
            ]
        )
        XCTAssertEqual(
            gitIgnoreFileDisplayName(candidates[0], workdir: root.path),
            "Sources/.gitignore"
        )
        XCTAssertEqual(
            gitIgnoreRule(
                for: target.path,
                ignoreFile: candidates[0],
                workdir: root.path
            ),
            "Feature/new.txt"
        )
        XCTAssertEqual(
            gitIgnoreFileCandidates(
                for: "/tmp/outside/new.txt",
                workdir: root.path
            ),
            []
        )
    }

    func testGitIgnoreCandidatesIntersectAcrossSelectedPaths() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ArborGitIgnoreCommonCandidates-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources/Feature"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources/Other"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("NoIgnore"),
            withIntermediateDirectories: true
        )
        for path in [
            "Sources/.gitignore",
            "Sources/Feature/.gitignore"
        ] {
            FileManager.default.createFile(
                atPath: root.appendingPathComponent(path).path,
                contents: Data()
            )
        }
        let featureTarget = root.appendingPathComponent("Sources/Feature/new.txt")
        let otherTarget = root.appendingPathComponent("Sources/Other/other.txt")
        let noIgnoreTarget = root.appendingPathComponent("NoIgnore/other.txt")
        FileManager.default.createFile(atPath: featureTarget.path, contents: Data())
        FileManager.default.createFile(atPath: otherTarget.path, contents: Data())
        FileManager.default.createFile(atPath: noIgnoreTarget.path, contents: Data())

        XCTAssertEqual(
            gitIgnoreFileCandidates(
                for: [featureTarget.path, otherTarget.path, noIgnoreTarget.path],
                workdir: root.path
            ),
            [
                root.appendingPathComponent("Sources/.gitignore").path
            ]
        )
        XCTAssertEqual(
            gitIgnoreTargetPaths(
                for: [featureTarget.path, otherTarget.path, noIgnoreTarget.path],
                ignoreFile: root.appendingPathComponent("Sources/.gitignore").path,
                workdir: root.path
            ),
            [featureTarget.path, otherTarget.path]
        )
    }

    func testGitIgnoreRootCreationConfirmationOnlyAppliesToMissingRootFile() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ArborGitIgnoreConfirmation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        XCTAssertTrue(
            gitIgnoreNeedsRootCreationConfirmation(
                ignoreFilePath: nil,
                workdir: root.path
            )
        )
        XCTAssertFalse(
            gitIgnoreNeedsRootCreationConfirmation(
                ignoreFilePath: root.appendingPathComponent("nested/.gitignore").path,
                workdir: root.path
            )
        )

        FileManager.default.createFile(
            atPath: root.appendingPathComponent(".gitignore").path,
            contents: Data()
        )
        XCTAssertFalse(
            gitIgnoreNeedsRootCreationConfirmation(
                ignoreFilePath: nil,
                workdir: root.path
            )
        )
    }

    func testGitExcludeURLUsesCommonDirectoryForLinkedWorktree() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborLinkedWorktreeExclude-\(UUID().uuidString)")
        let commonGitDir = root.appendingPathComponent("main/.git")
        let worktreeGitDir = commonGitDir.appendingPathComponent("worktrees/feature")
        try FileManager.default.createDirectory(
            at: worktreeGitDir,
            withIntermediateDirectories: true
        )
        try Data("../..\r\n".utf8).write(
            to: worktreeGitDir.appendingPathComponent("commondir")
        )
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            repositoryGitExcludeURL(gitDirectory: worktreeGitDir).path,
            commonGitDir.appendingPathComponent("info/exclude").standardizedFileURL.path
        )
    }

    func testGitExcludeURLFallsBackToAdministrativeDirectoryWithoutCommonDirectory() throws {
        let gitDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborRegularExclude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: gitDirectory) }

        XCTAssertEqual(
            repositoryGitExcludeURL(gitDirectory: gitDirectory).path,
            gitDirectory.appendingPathComponent("info/exclude").standardizedFileURL.path
        )
    }
}
