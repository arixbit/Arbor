import CoreServices
import XCTest
@testable import Arbor


final class RepositoryFileChangeMonitorTests: XCTestCase {

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

    func testGitMetadataLockFilesAreIgnored() {
        XCTAssertTrue(
            repositoryShouldIgnoreGitMetadataEvent(
                scope: .gitMetadata,
                path: "/tmp/repository/.git/index.lock"
            )
        )
        XCTAssertTrue(
            repositoryShouldIgnoreGitMetadataEvent(
                scope: .gitMetadata,
                path: "/tmp/repository/.git/refs/heads/main.lock"
            )
        )
        XCTAssertFalse(
            repositoryShouldIgnoreGitMetadataEvent(
                scope: .gitMetadata,
                path: "/tmp/repository/.git/index"
            )
        )
        XCTAssertFalse(
            repositoryShouldIgnoreGitMetadataEvent(
                scope: .gitMetadata,
                path: "/tmp/repository/.git/HEAD"
            )
        )
        XCTAssertFalse(
            repositoryShouldIgnoreGitMetadataEvent(
                scope: .worktree,
                path: "/tmp/repository/notes.lock"
            )
        )
    }

    /// `git status` creates and removes `.git/index.lock` even when it does
    /// not change the repository. The watcher must not report that transient
    /// coordination file, or a refresh would keep triggering itself.
    func testGitLockFileChangesAreNotDeliveredAsMetadataChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborGitLockWatcher-\(UUID().uuidString)")
        let workdir = root.appendingPathComponent("worktree")
        let gitDir = root.appendingPathComponent("git")
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lockEvent = expectation(description: #function)
        lockEvent.isInverted = true
        var metadataPaths: [String] = []
        let watcher = RepositoryFileChangeWatcher(
            workdir: workdir.path,
            gitDir: gitDir.path
        ) { event in
            guard event.scopes.contains(.gitMetadata) else { return }
            let paths = event.dirtyPaths.map(\.path)
            metadataPaths.append(contentsOf: paths)
            if paths.contains(where: { $0.hasSuffix("/index.lock") }) {
                lockEvent.fulfill()
            }
        }
        watcher.start()
        defer { watcher.stop() }

        let lock = gitDir.appendingPathComponent("index.lock")
        try Data().write(to: lock)
        try await Task.sleep(for: .milliseconds(500))
        try FileManager.default.removeItem(at: lock)
        await fulfillment(of: [lockEvent], timeout: 1.5)
        XCTAssertFalse(
            metadataPaths.contains { $0.hasSuffix("/index.lock") },
            "lock path was delivered: \(metadataPaths)"
        )
    }
}
