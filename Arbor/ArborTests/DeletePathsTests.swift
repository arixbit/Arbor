import XCTest
@testable import Arbor

/// IntelliJ 对照：`Git.Stage.Tree.Menu` 的 `$Delete`（platform Delete 动作）。
/// 删除本身在引擎侧（`delete_worktree_paths`），这里覆盖 Swift 侧的请求整形
/// 与确认文案，以及「非法路径绝不进删除队列」这条边界。
final class DeletePathsTests: XCTestCase {
    func testNormalizedPathsDropDuplicatesAndKeepOrder() {
        let normalized = normalizedDeletePaths(["b.txt", "a.txt", "b.txt"])
        XCTAssertEqual(normalized, ["b.txt", "a.txt"])
    }

    func testNormalizedPathsDropPathsThatEscapeTheRepository() {
        let normalized = normalizedDeletePaths([
            "/etc/hosts",
            "../outside.txt",
            "",
            "   ",
            "folder/../file.txt",
            "ok.txt"
        ])
        XCTAssertEqual(normalized, ["ok.txt"])
    }

    func testNormalizedPathsCollapseRedundantSeparators() {
        // 重复分隔符会被收敛；`.` 开头的路径与 `..` 一样属于越界写法，直接丢弃。
        XCTAssertEqual(normalizedDeletePaths(["folder//b.txt"]), ["folder/b.txt"])
        XCTAssertEqual(normalizedDeletePaths(["./a.txt"]), [])
    }

    func testConfirmationListsEveryPathWhenTheSelectionIsSmall() {
        let message = deleteConfirmationMessage(["a.txt", "b.txt"])
        XCTAssertTrue(message.hasPrefix("a.txt\nb.txt"))
        XCTAssertFalse(message.contains("more"))
        // 未跟踪文件无法从 Git 恢复，确认文案必须说清楚。
        XCTAssertTrue(message.contains("Untracked files cannot be restored."))
    }

    func testConfirmationSummarizesLongSelections() {
        let paths = (1...12).map { "file\($0).txt" }
        let message = deleteConfirmationMessage(paths)
        XCTAssertTrue(message.contains("file10.txt"))
        XCTAssertFalse(message.contains("file11.txt"))
        XCTAssertTrue(message.contains("…and 2 more"))
    }
}
