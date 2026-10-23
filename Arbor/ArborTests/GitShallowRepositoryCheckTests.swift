import XCTest
@testable import Arbor

/// IntelliJ 对照：`GitShallowRepositoryCheck`（ProjectActivity + RunOnceUtil）
/// 与 `ShallowRepositoryNotification`。每个用例对应 fork 的一个条件分支。
final class GitShallowRepositoryCheckTests: XCTestCase {
    // MARK: - 决策函数

    func testDecisionSuggestsUnshallowOnlyForSingleShallowRootWithDefaultRemote() {
        let outcome = gitShallowRepositoryCheckDecision(
            rootPath: "/repo",
            rootCount: 1,
            isShallow: true,
            defaultFetchRemote: "origin"
        )
        XCTAssertEqual(outcome, .suggestUnshallow(rootPath: "/repo", remote: "origin"))
    }

    func testDecisionStaysSilentForMultiRootProjects() {
        // fork 在 repositories.singleOrNull() 处短路：多 root 项目不检查。
        XCTAssertEqual(
            gitShallowRepositoryCheckDecision(
                rootPath: "/repo",
                rootCount: 2,
                isShallow: true,
                defaultFetchRemote: "origin"
            ),
            .silent
        )
        XCTAssertEqual(
            gitShallowRepositoryCheckDecision(
                rootPath: "/repo",
                rootCount: 0,
                isShallow: true,
                defaultFetchRemote: "origin"
            ),
            .silent
        )
    }

    func testDecisionStaysSilentForFullRepository() {
        XCTAssertEqual(
            gitShallowRepositoryCheckDecision(
                rootPath: "/repo",
                rootCount: 1,
                isShallow: false,
                defaultFetchRemote: "origin"
            ),
            .silent
        )
    }

    func testDecisionStaysSilentWithoutDefaultFetchRemote() {
        // fork: getDefaultRemoteToFetch == null 时只写 debug 日志。
        XCTAssertEqual(
            gitShallowRepositoryCheckDecision(
                rootPath: "/repo",
                rootCount: 1,
                isShallow: true,
                defaultFetchRemote: nil
            ),
            .silent
        )
    }

    // MARK: - RunOnce 标记

    func testRunOnceMarkerPersistsPerProjectPath() {
        let suiteName = "GitShallowRepositoryCheckTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(
            GitShallowRepositoryRunOnce.hasRun(defaults: defaults, projectPath: "/work/alpha")
        )
        GitShallowRepositoryRunOnce.markRun(defaults: defaults, projectPath: "/work/alpha")
        XCTAssertTrue(
            GitShallowRepositoryRunOnce.hasRun(defaults: defaults, projectPath: "/work/alpha")
        )
        // 其它项目不受影响：RunOnceUtil 是逐项目标记。
        XCTAssertFalse(
            GitShallowRepositoryRunOnce.hasRun(defaults: defaults, projectPath: "/work/beta")
        )
    }

    // MARK: - 真实 shallow fixture

    private func runGit(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
    }

    func testShallowLocalCloneSuggestsUnshallow() throws {
        let origin = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborShallowOrigin-\(UUID().uuidString)")
        let clone = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborShallowClone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: origin)
            try? FileManager.default.removeItem(at: clone)
        }

        try runGit(["init", "--quiet", origin.path])
        try runGit(["-C", origin.path, "config", "user.name", "Arbor Test"])
        try runGit(["-C", origin.path, "config", "user.email", "test@arbor.local"])
        try Data("one\n".utf8).write(to: origin.appendingPathComponent("file.txt"))
        try runGit(["-C", origin.path, "add", "file.txt"])
        try runGit(["-C", origin.path, "commit", "--quiet", "-m", "one"])
        try Data("two\n".utf8).write(to: origin.appendingPathComponent("file.txt"))
        try runGit(["-C", origin.path, "add", "file.txt"])
        try runGit(["-C", origin.path, "commit", "--quiet", "-m", "two"])

        // 本地浅克隆需要 file:// 传输（本地路径会忽略 --depth），与 fork
        // 检测目标一致：shallow 文件存在且远端可解析。
        try runGit([
            "clone", "--quiet", "--depth", "1",
            "file://" + origin.path, clone.path
        ])

        let repo = try openRepository(path: clone.path)
        XCTAssertTrue(repo.isShallow(), "本地 --depth 1 克隆应被引擎识别为 shallow")

        let remotes = try repo.remoteList()
        let remote = defaultFetchRemoteName(
            preferredRemote: nil,
            availableRemoteNames: remotes.map(\.name)
        )
        XCTAssertEqual(remote, "origin")

        let outcome = gitShallowRepositoryCheckDecision(
            rootPath: clone.path,
            rootCount: 1,
            isShallow: repo.isShallow(),
            defaultFetchRemote: remote
        )
        XCTAssertEqual(outcome, .suggestUnshallow(rootPath: clone.path, remote: "origin"))
    }

    func testFullCloneStaysSilent() throws {
        let origin = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborShallowOrigin-\(UUID().uuidString)")
        let clone = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborFullClone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: origin)
            try? FileManager.default.removeItem(at: clone)
        }

        try runGit(["init", "--quiet", origin.path])
        try runGit(["-C", origin.path, "config", "user.name", "Arbor Test"])
        try runGit(["-C", origin.path, "config", "user.email", "test@arbor.local"])
        try Data("one\n".utf8).write(to: origin.appendingPathComponent("file.txt"))
        try runGit(["-C", origin.path, "add", "file.txt"])
        try runGit(["-C", origin.path, "commit", "--quiet", "-m", "one"])

        try runGit(["clone", "--quiet", origin.path, clone.path])

        let repo = try openRepository(path: clone.path)
        XCTAssertFalse(repo.isShallow())
        XCTAssertEqual(
            gitShallowRepositoryCheckDecision(
                rootPath: clone.path,
                rootCount: 1,
                isShallow: repo.isShallow(),
                defaultFetchRemote: "origin"
            ),
            .silent
        )
    }
}
