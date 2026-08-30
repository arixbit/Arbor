import CoreServices
import XCTest
@testable import Arbor

final class RepositoryFileChangeMonitorTests: XCTestCase {
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

    func testRepositoryMonitorKeepsNestedRootsQualified() {
        let paths = repositoryMonitorRootPaths(
            primary: "/tmp/project",
            additional: ["/tmp/project/sub", "/tmp/project", "/tmp/other"]
        )
        XCTAssertEqual(paths, ["/tmp/project", "/tmp/project/sub", "/tmp/other"])
        XCTAssertEqual(
            nestedRepositoryRootPaths(
                rootPath: "/tmp/project",
                allRootPaths: paths
            ),
            ["/tmp/project/sub"]
        )
        XCTAssertEqual(
            nestedRepositoryRootPaths(
                rootPath: "/tmp/project/sub",
                allRootPaths: paths
            ),
            []
        )
    }

    func testLinkedWorktreeMetadataRootsIncludeTheCommonGitDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborLinkedWorktreeMetadata-\(UUID().uuidString)")
        let commonGitDir = root.appendingPathComponent("main/.git")
        let worktreeGitDir = commonGitDir.appendingPathComponent("worktrees/feature")
        try FileManager.default.createDirectory(
            at: worktreeGitDir,
            withIntermediateDirectories: true
        )
        try Data("  ../..\r\n".utf8).write(
            to: worktreeGitDir.appendingPathComponent("commondir")
        )
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            repositoryMetadataRootPaths(gitDir: worktreeGitDir.path),
            [worktreeGitDir.standardizedFileURL.path, commonGitDir.standardizedFileURL.path]
        )
    }

    func testInvalidLinkedWorktreeCommonDirectoryFallsBackToWorktreeGitDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborInvalidLinkedWorktreeMetadata-\(UUID().uuidString)")
        let worktreeGitDir = root.appendingPathComponent("worktrees/feature")
        try FileManager.default.createDirectory(
            at: worktreeGitDir,
            withIntermediateDirectories: true
        )
        try Data("../../missing-main-git\n".utf8).write(
            to: worktreeGitDir.appendingPathComponent("commondir")
        )
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            repositoryMetadataRootPaths(gitDir: worktreeGitDir.path),
            [worktreeGitDir.standardizedFileURL.path]
        )
        XCTAssertEqual(
            repositoryGitExcludeURL(gitDirectory: worktreeGitDir),
            worktreeGitDir.appendingPathComponent("info/exclude").standardizedFileURL
        )
    }

    func testLinkedWorktreeCommonDirectoryUsesCanonicalPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborCanonicalLinkedWorktreeMetadata-\(UUID().uuidString)")
        let commonGitDir = root.appendingPathComponent("main/.git")
        let commonAlias = root.appendingPathComponent("main/.git-alias")
        let worktreeGitDir = commonGitDir.appendingPathComponent("worktrees/feature")
        try FileManager.default.createDirectory(
            at: worktreeGitDir,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: commonAlias,
            withDestinationURL: commonGitDir
        )
        try Data("../../../.git-alias\n".utf8).write(
            to: worktreeGitDir.appendingPathComponent("commondir")
        )
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            repositoryMetadataRootPaths(gitDir: worktreeGitDir.path),
            [worktreeGitDir.standardizedFileURL.path, commonGitDir.standardizedFileURL.path]
        )
        XCTAssertEqual(
            repositoryGitExcludeURL(gitDirectory: worktreeGitDir).path,
            commonGitDir.appendingPathComponent("info/exclude").standardizedFileURL.path
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

    func testRegularRepositoryMetadataRootsStayScopedToItsGitDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborRegularMetadata-(UUID().uuidString)")
        let gitDir = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            repositoryMetadataRootPaths(gitDir: gitDir.path),
            [gitDir.standardizedFileURL.path]
        )
    }

    func testWorktreeAndGitMetadataChangesAreDeliveredWithSeparateScopes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborRepositoryFileMonitor-\(UUID().uuidString)")
        let workdir = root.appendingPathComponent("worktree")
        let gitDir = root.appendingPathComponent("git")
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let worktreeChange = expectation(description: #function)
        let metadataChange = expectation(description: #function)
        let filePath = workdir.appendingPathComponent("file.txt").standardizedFileURL.path
        let headPath = gitDir.appendingPathComponent("HEAD").standardizedFileURL.path
        var worktreeDelivered = false
        var metadataDelivered = false
        let watcher = RepositoryFileChangeWatcher(
            workdir: workdir.path,
            gitDir: gitDir.path
        ) { event in
            XCTAssertEqual(event.repositoryPath, workdir.standardizedFileURL.path)
            if event.scopes.contains(.worktree), !worktreeDelivered {
                guard event.dirtyPaths.contains(where: {
                    $0.path == filePath && !$0.isDirectory
                }) else { return }
                worktreeDelivered = true
                worktreeChange.fulfill()
            }
            if event.scopes.contains(.gitMetadata), !metadataDelivered {
                guard event.dirtyPaths.contains(where: {
                    $0.path == headPath && !$0.isDirectory
                }) else { return }
                metadataDelivered = true
                metadataChange.fulfill()
            }
        }
        watcher.start()
        defer { watcher.stop() }

        try Data("worktree".utf8).write(to: workdir.appendingPathComponent("file.txt"))
        await fulfillment(of: [worktreeChange], timeout: 5)

        try Data("ref: refs/heads/main\n".utf8).write(to: gitDir.appendingPathComponent("HEAD"))
        await fulfillment(of: [metadataChange], timeout: 5)
    }

    func testLinkedWorktreeCommonMetadataChangesAreDelivered() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborLinkedWorktreeWatcher-\(UUID().uuidString)")
        let workdir = root.appendingPathComponent("worktree")
        let commonGitDir = root.appendingPathComponent("main/.git")
        let worktreeGitDir = commonGitDir.appendingPathComponent("worktrees/feature")
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktreeGitDir, withIntermediateDirectories: true)
        try Data("  ../..\r\n".utf8).write(to: worktreeGitDir.appendingPathComponent("commondir"))
        defer { try? FileManager.default.removeItem(at: root) }

        let metadataChange = expectation(description: #function)
        let refPath = commonGitDir.appendingPathComponent("refs/heads/feature")
        try FileManager.default.createDirectory(
            at: refPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let watcher = RepositoryFileChangeWatcher(
            workdir: workdir.path,
            gitDir: worktreeGitDir.path
        ) { event in
            guard event.scopes.contains(.gitMetadata),
                  event.dirtyPaths.contains(where: { $0.path == refPath.standardizedFileURL.path }) else {
                return
            }
            metadataChange.fulfill()
        }
        watcher.start()
        defer { watcher.stop() }

        try Data("1111111\n".utf8).write(to: refPath)
        await fulfillment(of: [metadataChange], timeout: 5)
    }
}
