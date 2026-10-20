import CoreServices
import XCTest
@testable import Arbor

extension RepositoryFileChangeMonitorTests {

    func testDirtyChangeMergingPreservesCreateAndDeleteSemantics() {
        XCTAssertEqual(
            RepositoryDirtyChangeKind.merging(.created, .modified),
            .created
        )
        XCTAssertEqual(
            RepositoryDirtyChangeKind.merging(.removed, .modified),
            .removed
        )
        XCTAssertEqual(
            RepositoryDirtyChangeKind.merging(.created, .removed),
            .renamed
        )
    }

    func testRepositoryChangeBatchMergesScopesAndKeepsRenameOrigins() {
        let root = "/tmp/ArborRepositoryChangeBatch"
        var batch = RepositoryChangeBatch()
        batch.insert(
            RepositoryChangeEvent(
                repositoryPath: root,
                scopes: .worktree,
                dirtyPaths: [
                    RepositoryDirtyPath(
                        path: "\(root)/new.swift",
                        isDirectory: false,
                        kind: .renamed,
                        oldPath: "\(root)/old.swift"
                    )
                ]
            )
        )
        batch.insert(
            RepositoryChangeEvent(
                repositoryPath: "\(root)/.",
                scopes: .gitMetadata,
                dirtyPaths: [
                    RepositoryDirtyPath(
                        path: "\(root)/new.swift",
                        isDirectory: false,
                        kind: .modified
                    )
                ]
            )
        )

        let events = batch.drain()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].scopes, [.worktree, .gitMetadata])
        XCTAssertEqual(events[0].dirtyPaths.count, 1)
        XCTAssertEqual(events[0].dirtyPaths[0].kind, .renamed)
        XCTAssertEqual(events[0].dirtyPaths[0].oldPath, "\(root)/old.swift")
        XCTAssertTrue(batch.isEmpty)
    }

    func testRepositoryChangeBatchKeepsDifferentRootsIndependent() {
        var batch = RepositoryChangeBatch()
        for root in ["/tmp/ArborRootA", "/tmp/ArborRootB"] {
            batch.insert(
                RepositoryChangeEvent(
                    repositoryPath: root,
                    scopes: .worktree,
                    dirtyPaths: [
                        RepositoryDirtyPath(
                            path: "\(root)/file.swift",
                            isDirectory: false
                        )
                    ]
                )
            )
        }
        XCTAssertEqual(batch.drain().count, 2)
    }

    func testExternalVCSActionManagerCoalescesPendingEventsAndSerializesRoots() throws {
        let root = "/tmp/ArborExternalVCSActionManager"
        var manager = RepositoryExternalVCSActionManager()
        manager.enqueue(
            RepositoryChangeEvent(
                repositoryPath: root,
                scopes: .worktree,
                dirtyPaths: [
                    RepositoryDirtyPath(
                        path: "\(root)/first.txt",
                        isDirectory: false,
                        kind: .created
                    )
                ]
            )
        )

        let first = try XCTUnwrap(manager.begin(repositoryPath: root))
        XCTAssertTrue(manager.hasInProgressActions)

        manager.enqueue(
            RepositoryChangeEvent(
                repositoryPath: root,
                scopes: .worktree,
                dirtyPaths: [
                    RepositoryDirtyPath(
                        path: "\(root)/second.txt",
                        isDirectory: false,
                        kind: .removed
                    )
                ]
            )
        )
        manager.enqueue(
            RepositoryChangeEvent(
                repositoryPath: "\(root)/.",
                scopes: .gitMetadata,
                dirtyPaths: [
                    RepositoryDirtyPath(
                        path: "\(root)/third.txt",
                        isDirectory: false,
                        kind: .modified
                    )
                ]
            )
        )

        XCTAssertNil(manager.begin(repositoryPath: root))
        XCTAssertTrue(manager.finish(first))

        let second = try XCTUnwrap(manager.begin(repositoryPath: root))
        XCTAssertEqual(second.event.scopes, [.worktree, .gitMetadata])
        XCTAssertEqual(
            second.event.dirtyPaths.map(\.path),
            ["\(root)/second.txt", "\(root)/third.txt"]
        )
        XCTAssertTrue(manager.finish(second))
        XCTAssertFalse(manager.hasPendingActions)
        XCTAssertFalse(manager.hasInProgressActions)
    }

    func testRepositoryChangeBatchDropsConflictingRenameOriginConservatively() {
        let root = "/tmp/ArborRepositoryChangeBatchConflict"
        var batch = RepositoryChangeBatch()
        batch.insert(
            RepositoryChangeEvent(
                repositoryPath: root,
                scopes: .worktree,
                dirtyPaths: [
                    RepositoryDirtyPath(
                        path: "\(root)/new.swift",
                        isDirectory: false,
                        kind: .renamed,
                        oldPath: "\(root)/old-a.swift"
                    )
                ]
            )
        )
        batch.insert(
            RepositoryChangeEvent(
                repositoryPath: root,
                scopes: .worktree,
                dirtyPaths: [
                    RepositoryDirtyPath(
                        path: "\(root)/./new.swift",
                        isDirectory: false,
                        kind: .modified,
                        oldPath: "\(root)/old-b.swift"
                    )
                ]
            )
        )

        let event = try! XCTUnwrap(batch.drain().first)
        XCTAssertEqual(event.dirtyPaths.count, 1)
        XCTAssertEqual(event.dirtyPaths[0].kind, .renamed)
        XCTAssertNil(event.dirtyPaths[0].oldPath)
    }

    func testRefreshGateInvalidatesStaleResultsAndWidensOverlappingIncrementalRefresh() {
        var gate = RepositoryRefreshGate()

        let first = gate.begin(usesIncrementalStatus: true)
        XCTAssertTrue(first.usesIncrementalStatus)

        let second = gate.begin(usesIncrementalStatus: true)
        XCTAssertFalse(second.usesIncrementalStatus)
        XCTAssertFalse(gate.isCurrent(first))
        XCTAssertTrue(gate.isCurrent(second))
        XCTAssertFalse(gate.finish(first))
        XCTAssertTrue(gate.hasInFlightRefresh)
        XCTAssertTrue(gate.finish(second))
        XCTAssertFalse(gate.hasInFlightRefresh)

        let third = gate.begin(usesIncrementalStatus: true)
        XCTAssertTrue(third.usesIncrementalStatus)
    }

    func testClassifierNormalizesRelativePathsAndCoalescesDirectoryFlags() {
        let root = "/tmp/ArborRepositoryFileMonitor"
        let paths = RepositoryFileChangeClassifier.classify(
            rootPath: root,
            paths: ["./Sources/../Sources/App.swift", "Sources", "Sources"],
            flags: [
                UInt32(kFSEventStreamEventFlagItemCreated),
                0,
                UInt32(kFSEventStreamEventFlagItemIsDir)
            ]
        )

        XCTAssertEqual(
            paths,
            [
                RepositoryDirtyPath(
                    path: "/tmp/ArborRepositoryFileMonitor/Sources",
                    isDirectory: true
                ),
                RepositoryDirtyPath(
                    path: "/tmp/ArborRepositoryFileMonitor/Sources/App.swift",
                    isDirectory: false,
                    kind: .created
                )
            ]
        )

        let renamed = RepositoryFileChangeClassifier.classify(
            rootPath: root,
            paths: ["moved.swift", "moved.swift"],
            flags: [
                UInt32(kFSEventStreamEventFlagItemCreated),
                UInt32(kFSEventStreamEventFlagItemRemoved)
            ]
        )
        XCTAssertEqual(renamed.first?.kind, .renamed)
    }

    func testWorktreeEventsBecomeSafeGitPathspecs() {
        let workdir = "/tmp/ArborRepositoryFileMonitor/worktree"
        let gitDir = "\(workdir)/.git"
        let paths = repositoryWorktreeStatusPaths(
            workdir: workdir,
            gitDir: gitDir,
            dirtyPaths: [
                RepositoryDirtyPath(
                    path: "\(workdir)/Sources/App.swift",
                    isDirectory: false,
                    kind: .modified
                ),
                RepositoryDirtyPath(
                    path: "\(workdir)/Sources",
                    isDirectory: true,
                    kind: .modified
                ),
                RepositoryDirtyPath(
                    path: "\(gitDir)/index",
                    isDirectory: false,
                    kind: .modified
                )
            ]
        )

        XCTAssertEqual(paths, ["Sources"])
        XCTAssertEqual(
            repositoryWorktreeStatusPaths(
                workdir: workdir,
                gitDir: gitDir,
                dirtyPaths: [RepositoryDirtyPath(path: workdir, isDirectory: true)]
            ),
            nil
        )
    }

    func testDirtyScopePreservesExactRecursiveAndRenameParentSemantics() {
        let workdir = "/tmp/ArborRepositoryFileMonitor/worktree"
        let gitDir = "\(workdir)/.git"
        let scope = repositoryDirtyScope(
            workdir: workdir,
            gitDir: gitDir,
            dirtyPaths: [
                RepositoryDirtyPath(
                    path: "\(workdir)/Sources/App.swift",
                    isDirectory: false,
                    kind: .modified
                ),
                RepositoryDirtyPath(
                    path: "\(workdir)/Generated",
                    isDirectory: true,
                    kind: .created
                ),
                RepositoryDirtyPath(
                    path: "\(workdir)/Sources/New.swift",
                    isDirectory: false,
                    kind: .renamed,
                    oldPath: "\(workdir)/Sources/Old.swift"
                ),
                RepositoryDirtyPath(
                    path: "\(workdir)/Modules/NewModule",
                    isDirectory: true,
                    kind: .renamed,
                    oldPath: "\(workdir)/Modules/OldModule"
                )
            ]
        )

        XCTAssertEqual(
            scope.files,
            [
                "\(workdir)/Sources/App.swift",
                "\(workdir)/Sources/New.swift",
                "\(workdir)/Sources/Old.swift"
            ]
        )
        XCTAssertEqual(
            scope.directories,
            [
                "\(workdir)/Generated",
                "\(workdir)/Modules/NewModule",
                "\(workdir)/Modules/OldModule"
            ]
        )
        XCTAssertEqual(
            scope.nonRecursiveDirectories,
            ["\(workdir)/Modules", "\(workdir)/Sources"]
        )
        XCTAssertFalse(scope.everything)
    }

    func testShelfMutationDirtyPathsNormalizeRelativeAndAbsolutePathsSafely() {
        let workdir = "/tmp/ArborShelfMutation/worktree"
        let paths = repositoryShelfMutationDirtyPaths(
            workdir: workdir,
            paths: [
                "Sources/App.swift",
                "\(workdir)/Sources/App.swift",
                "Sources/../README.md",
                "../outside.txt",
                "",
                workdir
            ]
        )

        XCTAssertEqual(
            paths.map(\.path),
            [
                "\(workdir)/README.md",
                "\(workdir)/Sources/App.swift"
            ]
        )
        XCTAssertTrue(paths.allSatisfy { $0.kind == .modified && !$0.isDirectory })
    }

    func testNonRecursiveRenameParentDoesNotClaimDescendantFiles() {
        let root = "/tmp/ArborNonRecursiveDirtyScope"
        let scope = RepositoryDirtyScope(
            files: [],
            directories: [],
            nonRecursiveDirectories: ["\(root)/Sources"],
            everything: false
        )

        XCTAssertTrue(scope.contains(path: "\(root)/Sources", workdir: root))
        XCTAssertFalse(
            scope.contains(path: "\(root)/Sources/App.swift", workdir: root)
        )
    }

    func testDirtyScopeWidensIgnoreAndUnpairedRenameEvents() {
        let workdir = "/tmp/ArborRepositoryFileMonitor/worktree"
        let gitDir = "\(workdir)/.git"

        XCTAssertTrue(
            repositoryDirtyScope(
                workdir: workdir,
                gitDir: gitDir,
                dirtyPaths: [
                    RepositoryDirtyPath(
                        path: "\(workdir)/Sources/.gitignore",
                        isDirectory: false,
                        kind: .modified
                    )
                ]
            ).everything
        )
        XCTAssertTrue(
            repositoryDirtyScope(
                workdir: workdir,
                gitDir: gitDir,
                dirtyPaths: [
                    RepositoryDirtyPath(
                        path: "\(workdir)/new.swift",
                        isDirectory: false,
                        kind: .renamed
                    )
                ]
            ).everything
        )
    }

    func testDirtyScopeManagerPacksMergesAndConsumesRootScopes() {
        let root = "/tmp/ArborDirtyScopeManager"
        var manager = RepositoryDirtyScopeManager()
        manager.mark(
            repositoryPath: root,
            scope: RepositoryDirtyScope(
                files: ["\(root)/Sources/App.swift"],
                directories: [],
                nonRecursiveDirectories: [],
                everything: false
            )
        )
        manager.mark(
            repositoryPath: "\(root)/.",
            scope: RepositoryDirtyScope(
                files: [],
                directories: ["\(root)/Sources"],
                nonRecursiveDirectories: [],
                everything: false
            )
        )

        XCTAssertTrue(manager.hasDirtyScopes)
        XCTAssertFalse(manager.belongsTo(repositoryPath: root, path: root))
        XCTAssertTrue(
            manager.belongsTo(
                repositoryPath: root,
                path: "\(root)/Sources/Generated.swift"
            )
        )

        let packed = manager.retrieveScopes()
        XCTAssertEqual(packed.count, 1)
        XCTAssertFalse(manager.hasDirtyScopes)
        XCTAssertTrue(manager.hasInProgressScopes)
        XCTAssertEqual(packed[0].scope.files, [])
        XCTAssertEqual(packed[0].scope.directories, ["\(root)/Sources"])

        manager.mark(
            repositoryPath: root,
            scope: RepositoryDirtyScope(
                files: ["\(root)/README.md"],
                directories: [],
                nonRecursiveDirectories: [],
                everything: false
            )
        )
        XCTAssertTrue(manager.belongsTo(repositoryPath: root, path: "\(root)/README.md"))
        XCTAssertTrue(manager.pack().contains {
            $0.scope.files.contains("\(root)/README.md")
        })
        XCTAssertTrue(manager.retrieveScopes().isEmpty)

        manager.changesProcessed(repositoryPath: root)
        let next = manager.retrieveScopes()
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next[0].scope.files, ["\(root)/README.md"])
        manager.changesProcessed()
        XCTAssertFalse(manager.hasInProgressScopes)
    }

    func testDirtyScopeManagerEverythingIncludesRootButNotOutsidePaths() {
        let root = "/tmp/ArborDirtyScopeEverything"
        var manager = RepositoryDirtyScopeManager()
        manager.markEverything(repositoryPath: root)
        XCTAssertEqual(manager.retrieveScopes().count, 1)
        XCTAssertTrue(manager.belongsTo(repositoryPath: root, path: root))
        XCTAssertTrue(
            manager.belongsTo(
                repositoryPath: root,
                path: "\(root)/nested/file.swift"
            )
        )
        XCTAssertFalse(
            manager.belongsTo(
                repositoryPath: root,
                path: "/tmp/other/file.swift"
            )
        )
        manager.changesProcessed()
    }

    func testDirtyScopeManagerKeepsEventMetadataWithPackedScope() {
        let root = "/tmp/ArborDirtyScopeMetadata"
        let oldPath = "\(root)/old.swift"
        let newPath = "\(root)/new.swift"
        var manager = RepositoryDirtyScopeManager()

        manager.mark(
            repositoryPath: root,
            scope: RepositoryDirtyScope(
                files: [newPath],
                directories: [],
                nonRecursiveDirectories: ["\(root)/Sources"],
                everything: false
            ),
            changeScope: [.worktree],
            dirtyPaths: [
                RepositoryDirtyPath(
                    path: newPath,
                    isDirectory: false,
                    kind: .renamed,
                    oldPath: oldPath
                )
            ]
        )

        let first = try! XCTUnwrap(manager.retrieveScopes().first)
        XCTAssertEqual(first.event.scopes, [.worktree])
        XCTAssertEqual(first.event.dirtyPaths.first?.oldPath, oldPath)

        // A metadata event arriving while the first scope is being consumed
        // must remain pending and be merged only into the next batch.
        manager.mark(
            repositoryPath: root,
            scope: RepositoryDirtyScope(
                files: [],
                directories: [],
                nonRecursiveDirectories: [],
                everything: false
            ),
            changeScope: [.gitMetadata],
            dirtyPaths: [
                RepositoryDirtyPath(
                    path: "\(root)/.git/index",
                    isDirectory: false,
                    kind: .modified
                )
            ]
        )

        XCTAssertTrue(manager.retrieveScopes().isEmpty)
        manager.changesProcessed(repositoryPath: root)
        let next = try! XCTUnwrap(manager.retrieveScopes().first)
        XCTAssertEqual(next.event.scopes, [.gitMetadata])
        XCTAssertEqual(
            Set(next.event.dirtyPaths.map(\.path)),
            Set(["\(root)/.git/index"])
        )
        manager.changesProcessed(repositoryPath: root)
    }

    func testDirtyScopeManagerTicketsDoNotCrossARefreshGeneration() {
        let root = "/tmp/ArborDirtyScopeTickets"
        var manager = RepositoryDirtyScopeManager()
        manager.mark(
            repositoryPath: root,
            scope: RepositoryDirtyScope(
                files: ["\(root)/old.swift"],
                directories: [],
                nonRecursiveDirectories: [],
                everything: false
            )
        )
        let first = try! XCTUnwrap(manager.beginProcessing(repositoryPath: root))

        manager.mark(
            repositoryPath: root,
            scope: RepositoryDirtyScope(
                files: ["\(root)/new.swift"],
                directories: [],
                nonRecursiveDirectories: [],
                everything: false
            )
        )
        XCTAssertNil(manager.beginProcessing(repositoryPath: root))
        XCTAssertTrue(manager.belongsTo(repositoryPath: root, path: "\(root)/old.swift"))
        manager.changesProcessed(first)
        let second = try! XCTUnwrap(manager.beginProcessing(repositoryPath: root))
        XCTAssertTrue(manager.belongsTo(repositoryPath: root, path: "\(root)/new.swift"))
        manager.changesProcessed(second)
        XCTAssertFalse(manager.belongsTo(repositoryPath: root, path: "\(root)/new.swift"))
        XCTAssertFalse(manager.hasInProgressScopes)
    }

    func testDirtyScopeCompactsAncestorsAndPromotesLargeFolders() {
        let root = "/tmp/ArborDirtyScopeCompaction"
        let scope = RepositoryDirtyScope(
            files: [
                "\(root)/Sources/App.swift",
                "\(root)/Sources/Generated.swift"
            ],
            directories: ["\(root)/Sources"],
            nonRecursiveDirectories: [],
            everything: false
        ).compacted(workdir: root)

        XCTAssertEqual(scope.files, [])
        XCTAssertEqual(scope.directories, ["\(root)/Sources"])

        let manyFiles = (0..<30).map { "\(root)/Generated/File\($0).swift" }
        let promoted = RepositoryDirtyScope(
            files: manyFiles,
            directories: [],
            nonRecursiveDirectories: [],
            everything: false
        ).compacted(workdir: root)

        XCTAssertEqual(promoted.files, [])
        XCTAssertEqual(promoted.directories, ["\(root)/Generated"])
        XCTAssertFalse(promoted.everything)

    }

    func testDirtyScopeManagerPropagatesRecursiveParentEventsToNestedRoots() {
        let parent = "/tmp/ArborNestedDirtyScope"
        let nested = "\(parent)/Packages/NestedRepo"
        var manager = RepositoryDirtyScopeManager()
        manager.register(repositoryPaths: [parent, nested])

        let affected = manager.mark(
            repositoryPath: parent,
            scope: RepositoryDirtyScope(
                files: [],
                directories: ["\(parent)/Packages"],
                nonRecursiveDirectories: [],
                everything: false
            )
        )

        XCTAssertEqual(affected, [parent, nested])
        XCTAssertTrue(manager.belongsTo(repositoryPath: nested, path: nested))
        XCTAssertEqual(manager.pack().count, 2)

        let records = manager.retrieveScopes()
        XCTAssertEqual(records.map(\.repositoryPath), [parent, nested].sorted())
        manager.changesProcessed(repositoryPath: parent)
        manager.changesProcessed(repositoryPath: nested)
        XCTAssertFalse(manager.hasInProgressScopes)
    }

    func testDirtyScopeManagerDoesNotPropagateExactFileEventsToNestedRoots() {
        let parent = "/tmp/ArborNestedDirtyScopeFile"
        let nested = "\(parent)/Packages/NestedRepo"
        var manager = RepositoryDirtyScopeManager()
        manager.register(repositoryPaths: [parent, nested])

        let affected = manager.mark(
            repositoryPath: parent,
            scope: RepositoryDirtyScope(
                files: ["\(nested)/README.md"],
                directories: [],
                nonRecursiveDirectories: [],
                everything: false
            )
        )

        XCTAssertEqual(affected, [parent])
        manager.changesProcessed(
            try! XCTUnwrap(manager.beginProcessing(repositoryPath: parent))
        )
    }

    func testDirtyFileManagerPreservesRenameEndpointsAcrossLifecycle() {
        let root = "/tmp/ArborDirtyFileManager"
        let oldPath = "\(root)/old.swift"
        let newPath = "\(root)/new.swift"
        var manager = RepositoryDirtyFileManager()

        manager.mark(
            repositoryPath: root,
            dirtyPaths: [
                RepositoryDirtyPath(
                    path: newPath,
                    isDirectory: false,
                    kind: .renamed,
                    oldPath: oldPath
                )
            ]
        )
        let first = try! XCTUnwrap(manager.beginProcessing(repositoryPath: root))
        XCTAssertEqual(first.records.count, 1)
        XCTAssertEqual(first.records[0].oldPath, oldPath)
        XCTAssertEqual(first.records[0].endpoints, [newPath, oldPath])
        XCTAssertTrue(manager.hasInProgressFiles)

        manager.mark(
            repositoryPath: root,
            dirtyPaths: [
                RepositoryDirtyPath(
                    path: newPath,
                    isDirectory: false,
                    kind: .modified
                )
            ]
        )
        XCTAssertTrue(
            manager.pack().contains {
                $0.path == newPath && $0.oldPath == oldPath
            }
        )
        let second = try! XCTUnwrap(manager.beginProcessing(repositoryPath: root))
        manager.changesProcessed(first)
        XCTAssertTrue(manager.hasInProgressFiles)
        manager.changesProcessed(second)
        XCTAssertFalse(manager.hasInProgressFiles)
    }
}
