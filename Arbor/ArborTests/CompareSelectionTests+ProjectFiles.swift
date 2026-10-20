import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {

    func testProjectFileTreeRepositoryIdentityUsesCanonicalWorktreePath() throws {
        XCTAssertNil(projectFileTreeRepositoryIdentity(workdir: nil))
        XCTAssertNil(projectFileTreeRepositoryIdentity(workdir: "   "))
        XCTAssertEqual(
            projectFileTreeRepositoryIdentity(workdir: "/tmp/Projects/../repo/"),
            "/tmp/repo"
        )
        XCTAssertNotEqual(
            projectFileTreeRepositoryIdentity(workdir: "/tmp/first/repo"),
            projectFileTreeRepositoryIdentity(workdir: "/tmp/second/repo")
        )

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborFileTreeIdentity-\(UUID().uuidString)")
        let realRoot = temporaryRoot.appendingPathComponent("real")
        let linkRoot = temporaryRoot.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkRoot, withDestinationURL: realRoot)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        XCTAssertEqual(
            projectFileTreeRepositoryIdentity(workdir: linkRoot.path),
            projectFileTreeRepositoryIdentity(workdir: realRoot.path)
        )
    }

    func testRepositoryRelativeClipboardPathRejectsUnsafeEndpoints() {
        XCTAssertEqual(
            normalizedRepositoryRelativePath("  Sources//Arbor/App.swift  "),
            "Sources/Arbor/App.swift"
        )
        XCTAssertNil(normalizedRepositoryRelativePath("/tmp/outside.swift"))
        XCTAssertNil(normalizedRepositoryRelativePath("Sources/../Secrets.txt"))
        XCTAssertNil(normalizedRepositoryRelativePath("."))
    }

    func testProjectFileTreeHistoryIsFileScopedAndNormalizesPath() {
        XCTAssertEqual(
            projectFileTreeHistoryPath(" Sources//Arbor/App.swift ", isDirectory: false),
            "Sources/Arbor/App.swift"
        )
        XCTAssertNil(projectFileTreeHistoryPath("Sources", isDirectory: true))
        XCTAssertNil(projectFileTreeHistoryPath("/tmp/outside.swift", isDirectory: false))
        XCTAssertNil(projectFileTreeHistoryPath("Sources/../Secrets.txt", isDirectory: false))
    }

    func testProjectFileTreeAnnotateKeepsGitUnsupportedFilesDisabled() {
        XCTAssertEqual(
            projectFileTreeHistoryPath(" Sources//Arbor/App.swift ", isDirectory: false),
            "Sources/Arbor/App.swift"
        )
        XCTAssertTrue(
            projectFileTreeCanAnnotate(
                path: "Sources/Arbor/App.swift",
                entries: []
            )
        )

        let modified = FileEntry(
            path: "Sources/Arbor/App.swift",
            oldPath: nil,
            staged: .unchanged,
            unstaged: .modified
        )
        XCTAssertTrue(projectFileTreeCanAnnotate(path: modified.path, entries: [modified]))

        for kind in [ChangeKind.untracked, .deleted, .ignored, .conflicted] {
            let entry = FileEntry(
                path: "Sources/Arbor/App.swift",
                oldPath: nil,
                staged: .unchanged,
                unstaged: kind
            )
            XCTAssertFalse(projectFileTreeCanAnnotate(path: entry.path, entries: [entry]))
        }
    }

    func testProjectFileTreeSameVersionComparisonKeepsHeadBoundary() {
        XCTAssertTrue(
            projectFileTreeCanCompareWithSameVersion(
                path: "Sources/Arbor/App.swift",
                entries: []
            )
        )

        let modified = FileEntry(
            path: "Sources/Arbor/App.swift",
            oldPath: nil,
            staged: .unchanged,
            unstaged: .modified
        )
        XCTAssertTrue(
            projectFileTreeCanCompareWithSameVersion(
                path: modified.path,
                entries: [modified]
            )
        )

        for kind in [ChangeKind.untracked, .ignored, .conflicted] {
            let entry = FileEntry(
                path: "Sources/Arbor/App.swift",
                oldPath: nil,
                staged: .unchanged,
                unstaged: kind
            )
            XCTAssertFalse(
                projectFileTreeCanCompareWithSameVersion(
                    path: entry.path,
                    entries: [entry]
                )
            )
        }
    }

    func testProjectFileTreeSelectedRevisionComparisonRejectsUnsupportedStatus() {
        XCTAssertTrue(
            projectFileTreeCanCompareWithSelectedRevision(
                path: "Sources/App.swift",
                isDirectory: false,
                entries: []
            )
        )

        let deleted = FileEntry(
            path: "Sources/App.swift",
            oldPath: nil,
            staged: .deleted,
            unstaged: .unchanged
        )
        XCTAssertTrue(
            projectFileTreeCanCompareWithSelectedRevision(
                path: deleted.path,
                isDirectory: false,
                entries: [deleted]
            )
        )

        for kind in [ChangeKind.untracked, .ignored, .conflicted] {
            let entry = FileEntry(
                path: "Sources/App.swift",
                oldPath: nil,
                staged: .unchanged,
                unstaged: kind
            )
            XCTAssertFalse(
                projectFileTreeCanCompareWithSelectedRevision(
                    path: entry.path,
                    isDirectory: false,
                    entries: [entry]
                )
            )
        }

        let directoryEntries = [
            FileEntry(
                path: "Sources/App.swift",
                oldPath: nil,
                staged: .unchanged,
                unstaged: .modified
            ),
            FileEntry(
                path: "Sources/Generated.swift",
                oldPath: nil,
                staged: .unchanged,
                unstaged: .untracked
            )
        ]
        XCTAssertFalse(
            projectFileTreeCanCompareWithSelectedRevision(
                path: "Sources",
                isDirectory: true,
                entries: directoryEntries
            )
        )
        XCTAssertTrue(
            projectFileTreeCanCompareWithSelectedRevision(
                path: "Docs",
                isDirectory: true,
                entries: directoryEntries
            )
        )
    }

    func testProjectFileTreeContextMutationsFollowGitFileStatus() {
        let modified = FileEntry(
            path: "Sources/App.swift",
            oldPath: nil,
            staged: .unchanged,
            unstaged: .modified
        )
        XCTAssertTrue(projectFileTreeCanCheckin(
            path: modified.path,
            isDirectory: false,
            entries: [modified]
        ))
        XCTAssertTrue(projectFileTreeCanRevert(
            path: modified.path,
            isDirectory: false,
            entries: [modified]
        ))
        XCTAssertFalse(projectFileTreeCanAdd(
            path: modified.path,
            isDirectory: false,
            entries: [modified]
        ))

        let untracked = FileEntry(
            path: "Sources/New.swift",
            oldPath: nil,
            staged: .unchanged,
            unstaged: .untracked
        )
        XCTAssertTrue(projectFileTreeCanCheckin(
            path: untracked.path,
            isDirectory: false,
            entries: [untracked]
        ))
        XCTAssertTrue(projectFileTreeCanAdd(
            path: untracked.path,
            isDirectory: false,
            entries: [untracked]
        ))
        XCTAssertFalse(projectFileTreeCanRevert(
            path: untracked.path,
            isDirectory: false,
            entries: [untracked]
        ))

        let conflicted = FileEntry(
            path: "Sources/Conflict.swift",
            oldPath: nil,
            staged: .conflicted,
            unstaged: .conflicted
        )
        XCTAssertFalse(projectFileTreeCanCheckin(
            path: conflicted.path,
            isDirectory: false,
            entries: [conflicted]
        ))
        XCTAssertFalse(projectFileTreeCanAdd(
            path: conflicted.path,
            isDirectory: false,
            entries: [conflicted]
        ))
        XCTAssertFalse(projectFileTreeCanRevert(
            path: conflicted.path,
            isDirectory: false,
            entries: [conflicted]
        ))
        XCTAssertEqual(
            projectFileTreeFirstConflictedPath(
                path: conflicted.path,
                isDirectory: false,
                entries: [conflicted]
            ),
            conflicted.path
        )
        XCTAssertNil(projectFileTreeFirstConflictedPath(
            path: "Sources",
            isDirectory: true,
            entries: [conflicted]
        ))

        XCTAssertFalse(projectFileTreeCanCheckin(
            path: "Sources",
            isDirectory: true,
            entries: [modified]
        ))
        XCTAssertFalse(projectFileTreeCanAdd(
            path: "Sources",
            isDirectory: true,
            entries: [untracked]
        ))

    }

    func testProjectFileTreeShowCurrentRevisionFollowsGitFileStatus() {
        let modified = FileEntry(
            path: "Sources/App.swift",
            oldPath: nil,
            staged: .unchanged,
            unstaged: .modified
        )
        XCTAssertTrue(projectFileTreeCanShowCurrentRevision(
            path: modified.path,
            entries: [modified]
        ))
        XCTAssertTrue(projectFileTreeCanShowCurrentRevision(
            path: "Sources/Clean.swift",
            entries: []
        ))

        let untracked = FileEntry(
            path: "Sources/New.swift",
            oldPath: nil,
            staged: .unchanged,
            unstaged: .untracked
        )
        XCTAssertFalse(projectFileTreeCanShowCurrentRevision(
            path: untracked.path,
            entries: [untracked]
        ))

        let ignored = FileEntry(
            path: "Sources/Ignored.swift",
            oldPath: nil,
            staged: .unchanged,
            unstaged: .ignored
        )
        XCTAssertFalse(projectFileTreeCanShowCurrentRevision(
            path: ignored.path,
            entries: [ignored]
        ))

        let conflicted = FileEntry(
            path: "Sources/Conflict.swift",
            oldPath: nil,
            staged: .conflicted,
            unstaged: .conflicted
        )
        XCTAssertFalse(projectFileTreeCanShowCurrentRevision(
            path: conflicted.path,
            entries: [conflicted]
        ))
    }

    func testProjectFileTreeRevertResolvedIsExactFileScoped() {
        XCTAssertTrue(projectFileTreeCanRevertResolved(
            path: "Sources/Conflict.swift",
            isDirectory: false,
            resolvedConflictPaths: ["Sources/Conflict.swift"]
        ))
        XCTAssertFalse(projectFileTreeCanRevertResolved(
            path: "Sources",
            isDirectory: true,
            resolvedConflictPaths: ["Sources/Conflict.swift"]
        ))
        XCTAssertFalse(projectFileTreeCanRevertResolved(
            path: "Sources/Other.swift",
            isDirectory: false,
            resolvedConflictPaths: ["Sources/Conflict.swift"]
        ))
    }

    func testProjectFileHistoryPrefersTheOwningTreeRootOverLogSelection() {
        XCTAssertEqual(
            resolvedFileHistoryRootPath(
                preferredRootPath: "/project/nested",
                selectedCommitRootPath: "/project/other",
                activeLogRootPath: "/project/log",
                repositoryRootPath: "/project"
            ),
            "/project/nested"
        )
        XCTAssertEqual(
            resolvedFileHistoryRootPath(
                preferredRootPath: nil,
                selectedCommitRootPath: "/project/other",
                activeLogRootPath: "/project/log",
                repositoryRootPath: "/project"
            ),
            "/project/other"
        )
    }

    func testFileReferenceChoicesKeepBranchRemoteAndTagIdentity() {
        let choices = fileReferenceChoices(
            localBranches: [
                BranchInfo(name: "feature/z", isCurrent: false, shortId: "z", lastCommitTime: 0),
                BranchInfo(name: "main", isCurrent: true, shortId: "m", lastCommitTime: 0)
            ],
            remoteBranches: [
                RemoteBranchInfo(name: "origin/main", remote: "origin", shortId: "r")
            ],
            tags: [
                TagInfo(
                    name: "main",
                    id: "tag-id",
                    objectId: "tag-object",
                    shortId: "t",
                    kind: .lightweight,
                    message: "",
                    isCurrent: false
                )
            ]
        )

        XCTAssertEqual(
            choices.map { $0.id },
            ["localBranch:feature/z", "localBranch:main", "remoteBranch:origin/main", "tag:main"]
        )
        XCTAssertEqual(choices.filter { $0.name == "main" }.count, 2)
        XCTAssertEqual(choices.last?.revision, "main")
    }

    func testSelectedRevisionChoiceUsesFullObjectIdentityForDiff() {
        let fullID = String(repeating: "a", count: 40)
        let choice = FileReferenceChoice(
            kind: .history,
            name: String(fullID.prefix(7)),
            revisionID: fullID,
            summary: "Change file",
            author: "Author",
            timestamp: 1,
            message: "Change file"
        )

        XCTAssertEqual(choice.revision, fullID)
        XCTAssertEqual(choice.id, "history:\(fullID)")
    }

    func testFileReferenceComparisonUsesDeepestNestedGitRoot() {
        let roots = [
            GitRootInfo(
                path: "/workspace/project",
                displayName: "project",
                relativePath: ".",
                isSubmodule: false,
                headBranch: "main",
                headId: "parent-head",
                dirty: false,
                operation: nil
            ),
            GitRootInfo(
                path: "/workspace/project/vendor/lib",
                displayName: "lib",
                relativePath: "vendor/lib",
                isSubmodule: true,
                headBranch: "main",
                headId: "child-head",
                dirty: false,
                operation: nil
            )
        ]

        XCTAssertEqual(
            fileReferenceComparisonTarget(
                path: "vendor/lib/Sources/README.md",
                primaryRootPath: "/workspace/project",
                roots: roots
            ),
            FileReferenceComparisonTarget(
                rootPath: "/workspace/project/vendor/lib",
                relativePath: "Sources/README.md"
            )
        )
        XCTAssertNil(
            fileReferenceComparisonTarget(
                path: "../outside.txt",
                primaryRootPath: "/workspace/project",
                roots: roots
            )
        )
    }

    func testFileReferenceDirectoryChangesKeepRenameEndpointsUnderDirectory() {
        let changes = [
            TreeChange(
                path: "Sources/New.swift",
                oldPath: "README.md",
                isPureMove: false,
                kind: .renamed,
                oldMode: 0o100644,
                newMode: 0o100644
            ),
            TreeChange(
                path: "Docs/README.md",
                oldPath: nil,
                isPureMove: false,
                kind: .modified,
                oldMode: 0o100644,
                newMode: 0o100644
            ),
            TreeChange(
                path: "README.md",
                oldPath: "Sources/Old.swift",
                isPureMove: false,
                kind: .renamed,
                oldMode: 0o100644,
                newMode: 0o100644
            ),
            TreeChange(
                path: "Sources2/NotIncluded.swift",
                oldPath: nil,
                isPureMove: false,
                kind: .modified,
                oldMode: 0o100644,
                newMode: 0o100644
            )
        ]

        XCTAssertEqual(
            fileReferenceDirectoryChanges(changes, under: "Sources"),
            [changes[0], changes[2]]
        )
        XCTAssertEqual(
            fileReferenceDirectoryChanges(changes, under: "Docs"),
            [changes[1]]
        )
        XCTAssertTrue(fileReferenceDirectoryChanges(changes, under: "").isEmpty)
    }
}
