import CoreServices
import XCTest
@testable import Arbor

extension RepositoryFileChangeMonitorTests {

    func testRenameEventsFallBackUntilOldAndNewPathsCanBePaired() {
        XCTAssertNil(
            repositoryWorktreeStatusPaths(
                workdir: "/tmp/repository",
                gitDir: "/tmp/repository/.git",
                dirtyPaths: [
                    RepositoryDirtyPath(
                        path: "/tmp/repository/new-name.swift",
                        isDirectory: false,
                        kind: .renamed
                    )
                ]
            )
        )
    }

    func testPairedRenameStatusPathsIncludeBothEndpoints() {
        let workdir = "/tmp/ArborRepositoryFileMonitor/worktree"
        let oldPath = "\(workdir)/old-name.swift"
        let newPath = "\(workdir)/new-name.swift"

        XCTAssertEqual(
            repositoryWorktreeStatusPaths(
                workdir: workdir,
                gitDir: "\(workdir)/.git",
                dirtyPaths: [
                    RepositoryDirtyPath(
                        path: newPath,
                        isDirectory: false,
                        kind: .renamed,
                        oldPath: oldPath
                    )
                ]
            ),
            ["new-name.swift", "old-name.swift"]
        )
    }

    func testRenamePairingUsesFilesystemIdentityAndRejectsAmbiguousIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborRenamePairing-\(UUID().uuidString)")
        let oldURL = root.appendingPathComponent("old.txt")
        let newURL = root.appendingPathComponent("new.txt")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("rename me\n".utf8).write(to: oldURL)
        let previous = repositoryFileSnapshots(rootPath: root.path)
        try FileManager.default.moveItem(at: oldURL, to: newURL)
        let current = repositoryFileSnapshots(rootPath: root.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let raw = [
            RepositoryDirtyPath(
                path: newURL.standardizedFileURL.path,
                isDirectory: false,
                kind: .renamed
            )
        ]
        XCTAssertEqual(
            repositoryPairRenameEvents(
                dirtyPaths: raw,
                previous: previous,
                current: current
            ),
            [
                RepositoryDirtyPath(
                    path: newURL.standardizedFileURL.path,
                    isDirectory: false,
                    kind: .renamed,
                    oldPath: oldURL.standardizedFileURL.path
                )
            ]
        )

        let ambiguousPrevious = [
            "/tmp/ArborRenamePairing/a.txt": RepositoryFileSnapshot(
                identity: "same",
                isDirectory: false
            ),
            "/tmp/ArborRenamePairing/b.txt": RepositoryFileSnapshot(
                identity: "same",
                isDirectory: false
            )
        ]
        let ambiguousCurrent = [
            "/tmp/ArborRenamePairing/new.txt": RepositoryFileSnapshot(
                identity: "same",
                isDirectory: false
            )
        ]
        let ambiguousRaw = [
            RepositoryDirtyPath(
                path: "/tmp/ArborRenamePairing/new.txt",
                isDirectory: false,
                kind: .renamed
            )
        ]
        XCTAssertEqual(
            repositoryPairRenameEvents(
                dirtyPaths: ambiguousRaw,
                previous: ambiguousPrevious,
                current: ambiguousCurrent
            ),
            ambiguousRaw
        )

        let directoryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborDirectoryRenamePairing-\(UUID().uuidString)")
        let oldDirectory = directoryRoot.appendingPathComponent("old")
        let newDirectory = directoryRoot.appendingPathComponent("new")
        let oldChild = oldDirectory.appendingPathComponent("child.txt")
        let newChild = newDirectory.appendingPathComponent("child.txt")
        try FileManager.default.createDirectory(
            at: oldDirectory,
            withIntermediateDirectories: true
        )
        try Data("directory rename\n".utf8).write(to: oldChild)
        let directoryPrevious = repositoryFileSnapshots(rootPath: directoryRoot.path)
        try FileManager.default.moveItem(at: oldDirectory, to: newDirectory)
        let directoryCurrent = repositoryFileSnapshots(rootPath: directoryRoot.path)
        defer { try? FileManager.default.removeItem(at: directoryRoot) }

        let directoryEvents = repositoryPairRenameEvents(
            dirtyPaths: [
                RepositoryDirtyPath(
                    path: newDirectory.standardizedFileURL.path,
                    isDirectory: true,
                    kind: .renamed
                )
            ],
            previous: directoryPrevious,
            current: directoryCurrent
        )
        XCTAssertTrue(
            directoryEvents.contains {
                $0.path == newDirectory.standardizedFileURL.path
                    && $0.oldPath == oldDirectory.standardizedFileURL.path
                    && $0.isDirectory
            }
        )

        let directoryActionPaths = repositoryExternalVCSActionPaths(
            event: RepositoryChangeEvent(
                repositoryPath: directoryRoot.path,
                scopes: .worktree,
                dirtyPaths: directoryEvents
            ),
            workdir: directoryRoot.path,
            status: [
                FileEntry(
                    path: "new/child.txt",
                    oldPath: nil,
                    staged: .unchanged,
                    unstaged: .untracked
                ),
                FileEntry(
                    path: "old/child.txt",
                    oldPath: nil,
                    staged: .unchanged,
                    unstaged: .deleted
                )
            ]
        )
        XCTAssertEqual(
            directoryActionPaths,
            RepositoryExternalVCSActionPaths(
                add: ["new/child.txt"],
                remove: ["old/child.txt"]
            )
        )

        XCTAssertTrue(
            directoryEvents.contains {
                $0.path == newChild.standardizedFileURL.path
                    && $0.oldPath == oldChild.standardizedFileURL.path
            }
        )

        XCTAssertEqual(
            repositoryExternalVCSActionPaths(
                event: RepositoryChangeEvent(
                    repositoryPath: directoryRoot.path,
                    scopes: .worktree,
                    dirtyPaths: [
                        RepositoryDirtyPath(
                            path: "\(directoryRoot.path)/old",
                            isDirectory: true,
                            kind: .renamed,
                            oldPath: "\(directoryRoot.path)/Old"
                        ),
                        RepositoryDirtyPath(
                            path: "\(directoryRoot.path)/old/child.txt",
                            isDirectory: false,
                            kind: .renamed,
                            oldPath: "\(directoryRoot.path)/Old/child.txt"
                        )
                    ]
                ),
                workdir: directoryRoot.path,
                status: [
                    FileEntry(
                        path: "old/child.txt",
                        oldPath: nil,
                        staged: .unchanged,
                        unstaged: .untracked
                    ),
                    FileEntry(
                        path: "Old/child.txt",
                        oldPath: nil,
                        staged: .unchanged,
                        unstaged: .deleted
                    )
                ]
            ),
            RepositoryExternalVCSActionPaths(
                add: [],
                remove: [],
                forceMove: [
                    RepositoryExternalVCSMove(
                        oldPath: "Old/child.txt",
                        newPath: "old/child.txt"
                    )
                ]
            )
        )
    }

    func testRepositoryFileSnapshotsRespectEntryLimit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborSnapshotLimit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<4 {
            try Data("\(index)\n".utf8).write(
                to: root.appendingPathComponent("file-\(index).txt")
            )
        }

        let snapshots = repositoryFileSnapshots(rootPath: root.path, maxEntries: 2)
        XCTAssertEqual(snapshots.count, 2)
    }

    func testGeneratedWorktreeDirectoriesAreExcludedFromMonitoring() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborGeneratedDirectory-\(UUID().uuidString)")
        let buildFile = root.appendingPathComponent(".build/DerivedData/file.txt")
        let sourceFile = root.appendingPathComponent("Sources/file.txt")
        try FileManager.default.createDirectory(
            at: buildFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sourceFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("build\n".utf8).write(to: buildFile)
        try Data("source\n".utf8).write(to: sourceFile)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(
            repositoryIsGeneratedWorktreePath(
                buildFile.path,
                rootPath: root.path
            )
        )
        XCTAssertFalse(
            repositoryIsGeneratedWorktreePath(
                sourceFile.path,
                rootPath: root.path
            )
        )
        XCTAssertFalse(
            repositoryIsGeneratedWorktreePath(
                root.appendingPathComponent("Sources/build/file.txt").path,
                rootPath: root.path
            )
        )
        XCTAssertTrue(
            repositoryIsGeneratedWorktreePath(
                root.appendingPathComponent("arbor-engine/target/debug/file").path,
                rootPath: root.path
            )
        )
        let snapshots = repositoryFileSnapshots(rootPath: root.path)
        XCTAssertNil(snapshots[buildFile.standardizedFileURL.path])
        XCTAssertNotNil(snapshots[sourceFile.standardizedFileURL.path])
    }

    func testGeneratedDirectoryNamesDoNotFilterGitMetadataEvents() {
        let gitDir = "/tmp/ArborRepository/target/.git"
        let branchRef = "\(gitDir)/refs/heads/target"

        XCTAssertTrue(
            repositoryShouldIgnoreGeneratedWorktreeEvent(
                scope: .worktree,
                path: branchRef,
                rootPath: gitDir
            )
        )
        XCTAssertFalse(
            repositoryShouldIgnoreGeneratedWorktreeEvent(
                scope: .gitMetadata,
                path: branchRef,
                rootPath: gitDir
            )
        )
    }

    func testRenamesCrossingGeneratedDirectoriesRemainVisible() {
        let root = "/tmp/ArborRepository"
        let generated = "\(root)/.build/output.txt"
        let source = "\(root)/Sources/output.txt"

        XCTAssertFalse(
            repositoryShouldIgnoreGeneratedWorktreeEvent(
                scope: .worktree,
                path: generated,
                rootPath: root,
                kind: .renamed,
                oldPath: source
            )
        )
        XCTAssertFalse(
            repositoryShouldIgnoreGeneratedWorktreeEvent(
                scope: .worktree,
                path: source,
                rootPath: root,
                kind: .renamed,
                oldPath: generated
            )
        )
        XCTAssertFalse(
            repositoryShouldIgnoreGeneratedWorktreeEvent(
                scope: .worktree,
                path: generated,
                rootPath: root,
                kind: .renamed
            )
        )
        XCTAssertTrue(
            repositoryShouldIgnoreGeneratedWorktreeEvent(
                scope: .worktree,
                path: generated,
                rootPath: root,
                kind: .renamed,
                oldPath: "\(root)/.build/input.txt"
            )
        )
    }

    func testIgnoreFileChangesInvalidateTheWholeWorktreeStatusScope() {
        let workdir = "/tmp/ArborRepositoryFileMonitor/worktree"
        let gitDir = "\(workdir)/.git"

        XCTAssertNil(
            repositoryWorktreeStatusPaths(
                workdir: workdir,
                gitDir: gitDir,
                dirtyPaths: [
                    RepositoryDirtyPath(
                        path: "\(workdir)/.gitignore",
                        isDirectory: false,
                        kind: .modified
                    )
                ]
            )
        )
        XCTAssertNil(
            repositoryWorktreeStatusPaths(
                workdir: workdir,
                gitDir: gitDir,
                dirtyPaths: [
                    RepositoryDirtyPath(
                        path: "\(workdir)/Sources/.gitignore",
                        isDirectory: false,
                        kind: .modified
                    )
                ]
            )
        )
    }
}
