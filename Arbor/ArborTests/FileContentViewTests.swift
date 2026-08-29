import XCTest
import Foundation
@testable import Arbor

final class FileContentViewTests: XCTestCase {
    func testOlderFileContentReadCannotReplaceNewerRefreshGeneration() {
        XCTAssertFalse(
            isCurrentFileContentRequest(
                path: "file.txt",
                version: .local,
                generation: 3,
                currentPath: "file.txt",
                currentVersion: .local,
                currentGeneration: 4
            )
        )
        XCTAssertTrue(
            isCurrentFileContentRequest(
                path: "file.txt",
                version: .staged,
                generation: 4,
                currentPath: "file.txt",
                currentVersion: .staged,
                currentGeneration: 4
            )
        )
    }

    func testFileContentVersionOptionsFollowPresence() {
        XCTAssertEqual(
            fileContentVersions(for: [.local, .staged, .local], current: .staged),
            [.local, .staged]
        )
        XCTAssertEqual(
            fileContentVersions(for: [.staged], current: .local),
            [.staged]
        )
        XCTAssertEqual(
            fileContentVersions(for: [], current: .local),
            [.local]
        )
    }

    func testFileContentVersionResolvesToTheFirstAvailableVersion() {
        XCTAssertEqual(
            resolvedFileContentVersion(current: .staged, available: [.local]),
            .local
        )
        XCTAssertEqual(
            resolvedFileContentVersion(current: .staged, available: [.local, .staged]),
            .staged
        )
        XCTAssertNil(resolvedFileContentVersion(current: .local, available: []))
    }

    func testCodeLineChangesMarksAddedLines() {
        let diff = FileDiff(
            path: "file.txt",
            binary: false,
            hunks: [DiffHunk(
                oldStart: 1,
                newStart: 1,
                oldLines: [diffLine(.context, old: 1, new: 1)],
                newLines: [
                    diffLine(.context, old: 1, new: 1),
                    diffLine(.addition, old: 0, new: 2),
                ]
            )]
        )

        XCTAssertEqual(codeLineChanges(for: diff, lineCount: 2), [2: .added])
    }

    func testCodeLineChangesMarksReplacementAsModified() {
        let diff = FileDiff(
            path: "file.txt",
            binary: false,
            hunks: [DiffHunk(
                oldStart: 2,
                newStart: 2,
                oldLines: [diffLine(.deletion, old: 2, new: 0)],
                newLines: [diffLine(.addition, old: 0, new: 2)]
            )]
        )

        XCTAssertEqual(codeLineChanges(for: diff, lineCount: 3), [2: .modified])
    }

    func testCodeLineChangesAnchorsPureDeletionToSurvivingLine() {
        let diff = FileDiff(
            path: "file.txt",
            binary: false,
            hunks: [DiffHunk(
                oldStart: 2,
                newStart: 2,
                oldLines: [diffLine(.deletion, old: 2, new: 0)],
                newLines: []
            )]
        )

        XCTAssertEqual(codeLineChanges(for: diff, lineCount: 3), [2: .deleted])
    }

    func testCodeLineChangesIgnoreBinaryDiffs() {
        let diff = FileDiff(path: "image.png", binary: true, hunks: [])
        XCTAssertTrue(codeLineChanges(for: diff, lineCount: 1).isEmpty)
    }

    func testDiffPatchCommandPreservesRenameEndpointsAndSeparatesPathspecs() {
        let entry = FileEntry(
            path: "new name.txt",
            oldPath: "old name.txt",
            staged: .renamed,
            unstaged: .unchanged
        )

        XCTAssertEqual(
            diffPatchGitCommand(for: entry, mode: .indexToHead),
            DiffPatchGitCommand(
                command: "diff",
                args: [
                    "--no-color", "--binary", "--no-ext-diff", "--cached", "--",
                    "old name.txt", "new name.txt"
                ],
                acceptsExitCodeOne: false
            )
        )
    }

    func testDiffPatchCommandUsesNoIndexForUntrackedFilesAndAcceptsGitDiffExitOne() {
        let entry = FileEntry(
            path: "new.txt",
            oldPath: nil,
            staged: .unchanged,
            unstaged: .untracked
        )

        XCTAssertEqual(
            diffPatchGitCommand(for: entry, mode: .worktreeToIndex),
            DiffPatchGitCommand(
                command: "diff",
                args: [
                    "--no-color", "--binary", "--no-ext-diff", "--no-index", "--",
                    "/dev/null", "new.txt"
                ],
                acceptsExitCodeOne: true
            )
        )
        XCTAssertEqual(
            diffPatchGitCommand(for: entry, mode: .indexToWorktree)?.args.suffix(2),
            ["new.txt", "/dev/null"]
        )
    }

    func testRevisionPatchCommandRejectsOptionLikeRevisionAndKeepsPathAfterSeparator() {
        XCTAssertNil(
            diffPatchGitCommand(revision1: "--cached", revision2: "HEAD", path: "file.txt")
        )
        XCTAssertEqual(
            diffPatchGitCommand(revision1: "HEAD~1", revision2: "HEAD", path: "file name.txt")?.args,
            ["--no-color", "--binary", "--no-ext-diff", "HEAD~1", "HEAD", "--", "file name.txt"]
        )
    }

    func testExternalDiffCommandKeepsRevisionAndRenamePathsSeparate() {
        let entry = FileEntry(
            path: "new name.txt",
            oldPath: "old name.txt",
            staged: .renamed,
            unstaged: .unchanged
        )

        XCTAssertEqual(
            externalDiffGitCommand(for: entry, mode: .indexToHead),
            DiffExternalGitCommand(
                command: "difftool",
                args: ["--no-prompt", "--cached", "--", "old name.txt", "new name.txt"]
            )
        )
        XCTAssertEqual(
            externalDiffGitCommand(for: entry, mode: .indexToWorktree)?.args,
            ["--no-prompt", "--reverse", "--", "old name.txt", "new name.txt"]
        )
    }

    func testExternalDiffCommandUsesNoIndexForUntrackedFiles() {
        let entry = FileEntry(
            path: "new.txt",
            oldPath: nil,
            staged: .unchanged,
            unstaged: .untracked
        )

        XCTAssertEqual(
            externalDiffGitCommand(for: entry, mode: .worktreeToIndex),
            DiffExternalGitCommand(
                command: "difftool",
                args: ["--no-prompt", "--no-index", "--", "/dev/null", "new.txt"]
            )
        )
        XCTAssertNil(
            externalDiffGitCommand(
                for: FileEntry(
                    path: "",
                    oldPath: nil,
                    staged: .unchanged,
                    unstaged: .unchanged
                ),
                mode: .worktreeToIndex
            )
        )
    }

    func testExternalDiffToolSelectionFailsClosedWithoutConfiguredSelector() {
        let missing = GitCommandResult(
            command: "git config --get diff.tool",
            stdout: "",
            stdoutBytes: Data(),
            stderr: "",
            exitCode: 1,
            durationMs: 0
        )
        let configured = GitCommandResult(
            command: "git config --get diff.guitool",
            stdout: "  meld  \n",
            stdoutBytes: Data("  meld  \n".utf8),
            stderr: "",
            exitCode: 0,
            durationMs: 0
        )

        XCTAssertNil(configuredExternalDiffToolName(diffTool: missing, guiTool: missing))
        XCTAssertEqual(
            configuredExternalDiffToolName(diffTool: missing, guiTool: configured),
            "meld"
        )
        let primary = GitCommandResult(
            command: "git config --get diff.tool",
            stdout: "opendiff\n",
            stdoutBytes: Data("opendiff\n".utf8),
            stderr: "",
            exitCode: 0,
            durationMs: 0
        )
        XCTAssertEqual(
            configuredExternalDiffToolName(diffTool: primary, guiTool: configured),
            "opendiff"
        )
    }

    private func diffLine(_ kind: DiffLineKind, old: UInt32, new: UInt32) -> DiffLine {
        DiffLine(
            kind: kind,
            oldLine: old,
            newLine: new,
            text: "line",
            spans: [],
            highlights: []
        )
    }
}
