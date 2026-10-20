import CoreServices
import XCTest
@testable import Arbor

extension RepositoryFileChangeMonitorTests {

    func testExternalVCSActionPathsOnlySelectUntrackedCreatesAndDeletedTrackedFiles() {
        let workdir = "/tmp/ArborRepositoryFileMonitor/worktree"
        XCTAssertNil(
            repositoryRelativeWorktreeEventPath(
                workdir: workdir,
                path: "\(workdir)/.git/index"
            )
        )
        XCTAssertNil(
            repositoryRelativeWorktreeEventPath(
                workdir: workdir,
                path: "\(workdir)/../outside.txt"
            )
        )
        let event = RepositoryChangeEvent(
            repositoryPath: workdir,
            scopes: .worktree,
            dirtyPaths: [
                RepositoryDirtyPath(
                    path: "\(workdir)/new.txt",
                    isDirectory: false,
                    kind: .created
                ),
                RepositoryDirtyPath(
                    path: "\(workdir)/old.txt",
                    isDirectory: false,
                    kind: .removed
                ),
                RepositoryDirtyPath(
                    path: "\(workdir)/ignored.log",
                    isDirectory: false,
                    kind: .created
                ),
                RepositoryDirtyPath(
                    path: "\(workdir)/changed.txt",
                    isDirectory: false,
                    kind: .created
                )
            ]
        )
        let status = [
            FileEntry(path: "new.txt", oldPath: nil, staged: .unchanged, unstaged: .untracked),
            FileEntry(path: "old.txt", oldPath: nil, staged: .unchanged, unstaged: .deleted),
            FileEntry(path: "ignored.log", oldPath: nil, staged: .unchanged, unstaged: .ignored),
            FileEntry(path: "changed.txt", oldPath: nil, staged: .unchanged, unstaged: .modified)
        ]

        XCTAssertEqual(
            repositoryExternalVCSActionPaths(event: event, workdir: workdir, status: status),
            RepositoryExternalVCSActionPaths(
                add: [],
                remove: ["old.txt"],
                stageAdd: ["new.txt"]
            )
        )
    }

    func testExternalVCSActionPathsExpandDirectoryEventsAndIgnoreRenames() {
        let workdir = "/tmp/ArborRepositoryFileMonitor/worktree"
        let event = RepositoryChangeEvent(
            repositoryPath: workdir,
            scopes: .worktree,
            dirtyPaths: [
                RepositoryDirtyPath(
                    path: "\(workdir)/Sources",
                    isDirectory: true,
                    kind: .created
                ),
                RepositoryDirtyPath(
                    path: "\(workdir)/old.swift",
                    isDirectory: false,
                    kind: .renamed
                )
            ]
        )
        let status = [
            FileEntry(path: "Sources/App.swift", oldPath: nil, staged: .unchanged, unstaged: .untracked),
            FileEntry(path: "Sources/Tests/AppTests.swift", oldPath: nil, staged: .unchanged, unstaged: .untracked),
            FileEntry(path: "old.swift", oldPath: nil, staged: .unchanged, unstaged: .deleted)
        ]

        XCTAssertEqual(
            repositoryExternalVCSActionPaths(event: event, workdir: workdir, status: status),
            RepositoryExternalVCSActionPaths(
                add: [],
                remove: [],
                stageAdd: ["Sources/App.swift", "Sources/Tests/AppTests.swift"]
            )
        )
    }

    func testExternalVCSActionPathsRoutePairedRenamesAndCaseOnlyMoves() {
        let workdir = "/tmp/ArborRepositoryFileMonitor/worktree"
        let event = RepositoryChangeEvent(
            repositoryPath: workdir,
            scopes: .worktree,
            dirtyPaths: [
                RepositoryDirtyPath(
                    path: "\(workdir)/new.txt",
                    isDirectory: false,
                    kind: .renamed,
                    oldPath: "\(workdir)/old.txt"
                ),
                RepositoryDirtyPath(
                    path: "\(workdir)/casename.txt",
                    isDirectory: false,
                    kind: .renamed,
                    oldPath: "\(workdir)/CaseName.txt"
                )
            ]
        )
        let status = [
            FileEntry(path: "old.txt", oldPath: nil, staged: .unchanged, unstaged: .deleted),
            FileEntry(path: "new.txt", oldPath: nil, staged: .unchanged, unstaged: .untracked),
            FileEntry(path: "CaseName.txt", oldPath: nil, staged: .unchanged, unstaged: .deleted),
            FileEntry(path: "casename.txt", oldPath: nil, staged: .unchanged, unstaged: .untracked)
        ]

        XCTAssertEqual(
            repositoryExternalVCSActionPaths(
                event: event,
                workdir: workdir,
                status: status
            ),
            RepositoryExternalVCSActionPaths(
                add: ["new.txt"],
                remove: ["old.txt"],
                forceMove: [
                    RepositoryExternalVCSMove(
                        oldPath: "CaseName.txt",
                        newPath: "casename.txt"
                    )
                ]
            )
        )
    }

    func testExternalVCSActionPathsReconcileUnpairedRenamesWithoutGuessing() {
        let workdir = "/tmp/ArborRepositoryFileMonitor/worktree"
        let event = RepositoryChangeEvent(
            repositoryPath: workdir,
            scopes: .worktree,
            dirtyPaths: [
                RepositoryDirtyPath(
                    path: "\(workdir)/new.txt",
                    isDirectory: false,
                    kind: .renamed
                )
            ]
        )

        XCTAssertEqual(
            repositoryExternalVCSActionPaths(
                event: event,
                workdir: workdir,
                status: [
                    FileEntry(
                        path: "new.txt",
                        oldPath: nil,
                        staged: .unchanged,
                        unstaged: .untracked
                    ),
                    FileEntry(
                        path: "old.txt",
                        oldPath: nil,
                        staged: .unchanged,
                        unstaged: .deleted
                    )
                ]
            ),
            RepositoryExternalVCSActionPaths(
                add: [],
                remove: [],
                stageAdd: ["new.txt"]
            )
        )

        XCTAssertEqual(
            repositoryExternalVCSActionPaths(
                event: RepositoryChangeEvent(
                    repositoryPath: workdir,
                    scopes: .worktree,
                    dirtyPaths: [
                        RepositoryDirtyPath(
                            path: "\(workdir)/new/new.txt",
                            isDirectory: false,
                            kind: .renamed
                        )
                    ]
                ),
                workdir: workdir,
                status: [
                    FileEntry(
                        path: "new/new.txt",
                        oldPath: nil,
                        staged: .unchanged,
                        unstaged: .untracked
                    ),
                    FileEntry(
                        path: "old/new.txt",
                        oldPath: nil,
                        staged: .unchanged,
                        unstaged: .deleted
                    )
                ]
            ),
            RepositoryExternalVCSActionPaths(
                add: [],
                remove: [],
                reviewMoves: [
                    RepositoryExternalVCSMove(
                        oldPath: "old/new.txt",
                        newPath: "new/new.txt"
                    )
                ]
            )
        )

        XCTAssertEqual(
            repositoryExternalVCSActionPaths(
                event: event,
                workdir: workdir,
                status: [
                    FileEntry(
                        path: "new.txt",
                        oldPath: nil,
                        staged: .unchanged,
                        unstaged: .untracked
                    )
                ]
            ),
            RepositoryExternalVCSActionPaths(
                add: [],
                remove: [],
                stageAdd: ["new.txt"]
            )
        )

        XCTAssertEqual(
            repositoryExternalVCSActionPaths(
                event: event,
                workdir: workdir,
                status: [
                    FileEntry(
                        path: "new.txt",
                        oldPath: "New.txt",
                        staged: .unchanged,
                        unstaged: .renamed
                    )
                ]
            ),
            RepositoryExternalVCSActionPaths(
                add: [],
                remove: [],
                forceMove: [
                    RepositoryExternalVCSMove(
                        oldPath: "New.txt",
                        newPath: "new.txt"
                    )
                ]
            )
        )

        XCTAssertEqual(
            repositoryExternalVCSActionPaths(
                event: event,
                workdir: workdir,
                status: [
                    FileEntry(
                        path: "new.txt",
                        oldPath: nil,
                        staged: .unchanged,
                        unstaged: .untracked
                    ),
                    FileEntry(
                        path: "old.txt",
                        oldPath: nil,
                        staged: .unchanged,
                        unstaged: .deleted
                    )
                ]
            ),
            RepositoryExternalVCSActionPaths(
                add: [],
                remove: [],
                stageAdd: ["new.txt"]
            )
        )

        XCTAssertEqual(
            repositoryExternalVCSActionPaths(
                event: event,
                workdir: workdir,
                status: [
                    FileEntry(
                        path: "new.txt",
                        oldPath: nil,
                        staged: .unchanged,
                        unstaged: .untracked
                    ),
                    FileEntry(
                        path: "old.txt",
                        oldPath: nil,
                        staged: .unchanged,
                        unstaged: .deleted
                    ),
                    FileEntry(
                        path: "other-old.txt",
                        oldPath: nil,
                        staged: .unchanged,
                        unstaged: .deleted
                    )
                ]
            ),
            RepositoryExternalVCSActionPaths(
                add: [],
                remove: [],
                stageAdd: ["new.txt"]
            )
        )

        let ambiguousFilePaths = repositoryExternalVCSActionPaths(
            event: event,
            workdir: workdir,
            status: [
                FileEntry(
                    path: "new.txt",
                    oldPath: nil,
                    staged: .unchanged,
                    unstaged: .untracked
                ),
                FileEntry(
                    path: "old-a/new.txt",
                    oldPath: nil,
                    staged: .unchanged,
                    unstaged: .deleted
                ),
                FileEntry(
                    path: "old-b/new.txt",
                    oldPath: nil,
                    staged: .unchanged,
                    unstaged: .deleted
                ),
                FileEntry(
                    path: "unrelated.txt",
                    oldPath: nil,
                    staged: .unchanged,
                    unstaged: .deleted
                )
            ]
        )
        XCTAssertEqual(ambiguousFilePaths.add, [])
        XCTAssertEqual(ambiguousFilePaths.remove, [])
        XCTAssertEqual(ambiguousFilePaths.stageAdd, [])
        XCTAssertEqual(
            ambiguousFilePaths.reviewMoves,
            [
                RepositoryExternalVCSMove(
                    oldPath: "old-a/new.txt",
                    newPath: "new.txt"
                ),
                RepositoryExternalVCSMove(
                    oldPath: "old-b/new.txt",
                    newPath: "new.txt"
                )
            ]
        )

        XCTAssertEqual(
            repositoryExternalVCSActionPaths(
                event: RepositoryChangeEvent(
                    repositoryPath: workdir,
                    scopes: .worktree,
                    dirtyPaths: [
                        RepositoryDirtyPath(
                            path: "\(workdir)/folder",
                            isDirectory: true,
                            kind: .renamed
                        )
                    ]
                ),
                workdir: workdir,
                status: [
                    FileEntry(
                        path: "folder/new.txt",
                        oldPath: nil,
                        staged: .unchanged,
                        unstaged: .untracked
                    ),
                    FileEntry(
                        path: "old.txt",
                        oldPath: nil,
                        staged: .unchanged,
                        unstaged: .deleted
                    )
                ]
            ),
            RepositoryExternalVCSActionPaths(
                add: [],
                remove: [],
                stageAdd: ["folder/new.txt"]
            )
        )
    }

    func testUnpairedRenameUsesUniqueGitBlobIdentityForArbitraryBasenames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborContentRenameIdentity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func runGit(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
        }

        try runGit(["init", "--quiet", root.path])
        try runGit(["-C", root.path, "config", "user.name", "Arbor Test"])
        try runGit(["-C", root.path, "config", "user.email", "test@arbor.local"])
        let oldURL = root.appendingPathComponent("old-name.txt")
        try Data("same content\n".utf8).write(to: oldURL)
        try runGit(["-C", root.path, "add", "old-name.txt"])
        try runGit(["-C", root.path, "commit", "--quiet", "-m", "init"])

        let repo = try openRepository(path: root.path)
        let newURL = root.appendingPathComponent("renamed-without-shared-basename.md")
        try FileManager.default.moveItem(at: oldURL, to: newURL)
        let status = try repo.status()
        let event = RepositoryChangeEvent(
            repositoryPath: root.path,
            scopes: .worktree,
            dirtyPaths: [
                RepositoryDirtyPath(
                    path: newURL.path,
                    isDirectory: false,
                    kind: .renamed
                )
            ]
        )

        let matches = repositoryUniqueContentRenameMatches(
            repo: repo,
            event: event,
            workdir: root.path,
            status: status
        )
        XCTAssertEqual(
            matches,
            [
                RepositoryExternalVCSMove(
                    oldPath: "old-name.txt",
                    newPath: "renamed-without-shared-basename.md"
                )
            ]
        )
        XCTAssertEqual(
            repositoryExternalVCSActionPaths(
                event: event,
                workdir: root.path,
                status: status,
                contentRenameMatches: matches
            ),
            RepositoryExternalVCSActionPaths(
                add: ["renamed-without-shared-basename.md"],
                remove: ["old-name.txt"]
            )
        )
    }

    func testUnpairedRenameDoesNotAutoPairDuplicateGitBlobIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborDuplicateContentRename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func runGit(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
        }

        try runGit(["init", "--quiet", root.path])
        try runGit(["-C", root.path, "config", "user.name", "Arbor Test"])
        try runGit(["-C", root.path, "config", "user.email", "test@arbor.local"])
        try Data("same content\n".utf8).write(to: root.appendingPathComponent("first.txt"))
        try Data("same content\n".utf8).write(to: root.appendingPathComponent("second.txt"))
        try runGit(["-C", root.path, "add", "first.txt", "second.txt"])
        try runGit(["-C", root.path, "commit", "--quiet", "-m", "init"])

        let repo = try openRepository(path: root.path)
        try FileManager.default.removeItem(at: root.appendingPathComponent("first.txt"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("second.txt"))
        try Data("same content\n".utf8).write(
            to: root.appendingPathComponent("new-name.md")
        )
        let event = RepositoryChangeEvent(
            repositoryPath: root.path,
            scopes: .worktree,
            dirtyPaths: [
                RepositoryDirtyPath(
                    path: root.appendingPathComponent("new-name.md").path,
                    isDirectory: false,
                    kind: .renamed
                )
            ]
        )
        XCTAssertTrue(
            repositoryUniqueContentRenameMatches(
                repo: repo,
                event: event,
                workdir: root.path,
                status: try repo.status()
            ).isEmpty
        )
    }

    func testUnpairedRenameWithSimilarModifiedContentUsesUniqueSimilarity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborModifiedContentRename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func runGit(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
        }

        try runGit(["init", "--quiet", root.path])
        try runGit(["-C", root.path, "config", "user.name", "Arbor Test"])
        try runGit(["-C", root.path, "config", "user.email", "test@arbor.local"])
        let oldURL = root.appendingPathComponent("old-name.txt")
        try Data("first\nsecond\nthird\n".utf8).write(to: oldURL)
        try runGit(["-C", root.path, "add", "old-name.txt"])
        try runGit(["-C", root.path, "commit", "--quiet", "-m", "init"])

        let repo = try openRepository(path: root.path)
        let newURL = root.appendingPathComponent("renamed-without-shared-basename.md")
        try FileManager.default.moveItem(at: oldURL, to: newURL)
        try Data("first\nchanged\nthird\n".utf8).write(to: newURL)
        let event = RepositoryChangeEvent(
            repositoryPath: root.path,
            scopes: .worktree,
            dirtyPaths: [
                RepositoryDirtyPath(
                    path: newURL.path,
                    isDirectory: false,
                    kind: .renamed
                )
            ]
        )
        let status = try repo.status()
        let matches = repositoryModifiedContentRenameMatches(
            repo: repo,
            event: event,
            workdir: root.path,
            status: status
        )
        XCTAssertEqual(
            matches,
            [
                RepositoryExternalVCSMove(
                    oldPath: "old-name.txt",
                    newPath: "renamed-without-shared-basename.md"
                )
            ]
        )
        XCTAssertEqual(
            repositoryExternalVCSActionPaths(
                event: event,
                workdir: root.path,
                status: status,
                contentRenameMatches: matches
            ),
            RepositoryExternalVCSActionPaths(
                add: ["renamed-without-shared-basename.md"],
                remove: ["old-name.txt"]
            )
        )
    }

    func testRenameSimilarityScoreRequiresSubstantialContentOverlap() {
        XCTAssertEqual(repositoryRenameSimilarityScore("same\n", "same\n"), 1)
        XCTAssertGreaterThan(
            repositoryRenameSimilarityScore(
                "one\ntwo\nthree\n",
                "one\nchanged\nthree\n"
            ),
            0.60
        )
        XCTAssertLessThan(
            repositoryRenameSimilarityScore("original\n", "changed\n"),
            0.60
        )
    }

    func testAmbiguousDirectoryRenameOffersPerFileReviewCandidates() {
        let workdir = "/tmp/ArborRepositoryFileMonitor/worktree"
        let paths = repositoryExternalVCSActionPaths(
            event: RepositoryChangeEvent(
                repositoryPath: workdir,
                scopes: .worktree,
                dirtyPaths: [
                    RepositoryDirtyPath(
                        path: "\(workdir)/new",
                        isDirectory: true,
                        kind: .renamed
                    )
                ]
            ),
            workdir: workdir,
            status: [
                FileEntry(
                    path: "new/child.txt",
                    oldPath: nil,
                    staged: .unchanged,
                    unstaged: .untracked
                ),
                FileEntry(
                    path: "old-a/child.txt",
                    oldPath: nil,
                    staged: .unchanged,
                    unstaged: .deleted
                ),
                FileEntry(
                    path: "old-b/child.txt",
                    oldPath: nil,
                    staged: .unchanged,
                    unstaged: .deleted
                ),
                FileEntry(
                    path: "unrelated.txt",
                    oldPath: nil,
                    staged: .unchanged,
                    unstaged: .deleted
                )
            ]
        )

        XCTAssertEqual(paths.add, [])
        XCTAssertEqual(paths.remove, [])
        XCTAssertEqual(paths.stageAdd, [])
        XCTAssertEqual(
            paths.reviewMoves,
            [
                RepositoryExternalVCSMove(
                    oldPath: "old-a/child.txt",
                    newPath: "new/child.txt"
                ),
                RepositoryExternalVCSMove(
                    oldPath: "old-b/child.txt",
                    newPath: "new/child.txt"
                )
            ]
        )
    }

    func testAmbiguousRenameSelectionRemainsOneToOne() {
        let selected = repositoryNonConflictingExternalVCSMoves([
            RepositoryExternalVCSMove(oldPath: "old-a/child.txt", newPath: "new/child.txt"),
            RepositoryExternalVCSMove(oldPath: "old-b/child.txt", newPath: "new/child.txt"),
            RepositoryExternalVCSMove(oldPath: "old-a/child.txt", newPath: "other/child.txt"),
            RepositoryExternalVCSMove(oldPath: "old-c/third.txt", newPath: "third/child.txt")
        ])

        XCTAssertEqual(
            selected,
            [
                RepositoryExternalVCSMove(oldPath: "old-a/child.txt", newPath: "new/child.txt"),
                RepositoryExternalVCSMove(oldPath: "old-c/third.txt", newPath: "third/child.txt")
            ]
        )
        XCTAssertEqual(Set(selected.map(\.oldPath)).count, selected.count)
        XCTAssertEqual(Set(selected.map(\.newPath)).count, selected.count)
    }

    func testExternalVCSRetryPayloadRoundTripsAndRejectsUnsafePaths() throws {
        let action = RepositoryExternalVCSAction(
            addPaths: ["new/file.txt"],
            stageAddPaths: ["new/empty.txt"],
            removePaths: ["old/file.txt"],
            forceMoves: [
                RepositoryExternalVCSMove(
                    oldPath: "old/case.txt",
                    newPath: "old/Case.txt"
                )
            ]
        )

        XCTAssertTrue(repositoryExternalVCSActionIsSafe(action))
        let data = try JSONEncoder().encode(action)
        XCTAssertEqual(try JSONDecoder().decode(RepositoryExternalVCSAction.self, from: data), action)

        XCTAssertFalse(
            repositoryExternalVCSActionIsSafe(
                RepositoryExternalVCSAction(
                    addPaths: ["../outside.txt"],
                    stageAddPaths: [],
                    removePaths: [],
                    forceMoves: []
                )
            )
        )
        XCTAssertFalse(
            repositoryExternalVCSActionIsSafe(
                RepositoryExternalVCSAction(
                    addPaths: ["/tmp/outside.txt"],
                    stageAddPaths: [],
                    removePaths: [],
                    forceMoves: []
                )
            )
        )

        let request = ArborVCSActionRequest(
            kind: .retryExternalVCSAction,
            projectPath: "/tmp/project",
            rootPath: "/tmp/project",
            shelfName: "",
            externalVCSAction: action
        )
        let requestData = try JSONEncoder().encode(request)
        XCTAssertEqual(
            try JSONDecoder().decode(ArborVCSActionRequest.self, from: requestData),
            request
        )
    }

    func testExternalVCSRetrySnapshotsRejectChangedAndRecreatedPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborExternalVCSRetry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let newFile = root.appendingPathComponent("new.txt")
        try Data("first".utf8).write(to: newFile)

        let addAction = repositoryExternalVCSActionCapturingSnapshots(
            RepositoryExternalVCSAction(
                addPaths: ["new.txt"],
                stageAddPaths: [],
                removePaths: [],
                forceMoves: []
            ),
            rootPath: root.path
        )
        XCTAssertTrue(repositoryExternalVCSActionMatchesSnapshots(addAction, rootPath: root.path))
        try Data("second".utf8).write(to: newFile)
        XCTAssertFalse(repositoryExternalVCSActionMatchesSnapshots(addAction, rootPath: root.path))

        let removeAction = repositoryExternalVCSActionCapturingSnapshots(
            RepositoryExternalVCSAction(
                addPaths: [],
                stageAddPaths: [],
                removePaths: ["deleted.txt"],
                forceMoves: []
            ),
            rootPath: root.path
        )
        XCTAssertTrue(repositoryExternalVCSActionMatchesSnapshots(removeAction, rootPath: root.path))
        try Data("restored".utf8).write(to: root.appendingPathComponent("deleted.txt"))
        XCTAssertFalse(repositoryExternalVCSActionMatchesSnapshots(removeAction, rootPath: root.path))

        let encoded = try JSONEncoder().encode(addAction)
        XCTAssertEqual(
            try JSONDecoder().decode(RepositoryExternalVCSAction.self, from: encoded),
            addAction
        )
    }

    func testGitVFSListenerSettingsDefaultToAskAndPersistIndependently() {
        let suiteName = "ArborGitVFSListenerSettings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(GitVFSListenerSettings.addAction(defaults: defaults), .ask)
        XCTAssertEqual(GitVFSListenerSettings.removeAction(defaults: defaults), .ask)

        GitVFSListenerSettings.setAddAction(.perform, defaults: defaults)
        GitVFSListenerSettings.setRemoveAction(.ignore, defaults: defaults)

        XCTAssertEqual(GitVFSListenerSettings.addAction(defaults: defaults), .perform)
        XCTAssertEqual(GitVFSListenerSettings.removeAction(defaults: defaults), .ignore)
    }

    func testExternalVCSActionSelectionPreservesOrderAndDeduplicates() {
        XCTAssertEqual(
            repositorySelectedExternalVCSPaths(
                paths: ["b.txt", "a.txt", "b.txt", "ignored.txt"],
                selected: ["b.txt", "ignored.txt"]
            ),
            ["b.txt", "ignored.txt"]
        )
        XCTAssertEqual(
            repositorySelectedExternalVCSPaths(
                paths: ["b.txt", "a.txt"],
                selected: []
            ),
            []
        )
    }
}
