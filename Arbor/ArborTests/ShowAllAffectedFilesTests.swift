import XCTest
@testable import Arbor

/// IntelliJ 对照：`VcsHistory.ShowAllAffected`（File History 的
/// Show All Affected Files 动作，由 `GitHistoryProvider.getAdditionalActions`
/// 挂载，数据来自 `GitCommittedChangeListProvider.getOneList`）。
final class ShowAllAffectedFilesTests: XCTestCase {
    private func record(
        id: String,
        path: String,
        oldPath: String? = nil,
        kind: TreeChangeKind = .modified,
        repositoryPath: String = "/workspace/repo"
    ) -> LogChangeRecord {
        LogChangeRecord(
            commit: makeCommit(id: id, repositoryPath: repositoryPath),
            parentIndex: 0,
            change: TreeChange(
                path: path,
                oldPath: oldPath,
                isPureMove: kind == .renamed,
                kind: kind,
                oldMode: kind == .added ? 0 : 0o100644,
                newMode: kind == .deleted ? 0 : 0o100644
            )
        )
    }

    private func makeCommit(
        id: String,
        repositoryPath: String
    ) -> CommitInfo {
        CommitInfo(
            id: id,
            repositoryPath: repositoryPath,
            shortId: String(id.prefix(7)),
            summary: id,
            authorName: "A",
            authorEmail: "a@example.com",
            committerName: "A",
            committerEmail: "a@example.com",
            messageBody: "",
            hasSignature: false,
            time: 0,
            parentIds: ["parent"],
            refs: [],
            tagRefs: [],
            remoteRefs: [],
            isHead: false,
            lane: 0,
            parentLanes: []
        )
    }

    // MARK: - 记录匹配（fork getOneList 的 exact-match 语义）

    func testAffectedHistoryRecordMatchesCurrentPath() {
        let records = [
            record(id: "c1", path: "Sources/App.swift"),
            record(id: "c2", path: "README.md", kind: .added)
        ]
        XCTAssertEqual(
            logAffectedHistoryRecordID(records: records, historyPath: "README.md"),
            record(id: "c2", path: "README.md", kind: .added).id
        )
    }

    func testAffectedHistoryRecordMatchesOldPathForInCommitRename() {
        // getOneList 同时检查 change 的 after-path；本提交内改名的旧路径
        // 由 oldPath 候选覆盖（logChangeAffectsPath）。
        let records = [
            record(id: "c1", path: "Sources/App.swift"),
            record(id: "c2", path: "new-name.txt", oldPath: "old-name.txt", kind: .renamed)
        ]
        XCTAssertEqual(
            logAffectedHistoryRecordID(records: records, historyPath: "old-name.txt"),
            record(id: "c2", path: "new-name.txt", oldPath: "old-name.txt", kind: .renamed).id
        )
    }

    func testAffectedHistoryRecordMatchesDirectoryPrefix() {
        let records = [
            record(id: "c1", path: "Sources/App/Detail.swift")
        ]
        XCTAssertEqual(
            logAffectedHistoryRecordID(records: records, historyPath: "Sources/App"),
            record(id: "c1", path: "Sources/App/Detail.swift").id
        )
    }

    func testAffectedHistoryRecordReturnsNilWithoutMatchOrEmptyPath() {
        let records = [record(id: "c1", path: "Sources/App.swift")]
        XCTAssertNil(
            logAffectedHistoryRecordID(records: records, historyPath: "Docs/guide.md")
        )
        XCTAssertNil(logAffectedHistoryRecordID(records: records, historyPath: "  "))
        XCTAssertNil(logAffectedHistoryRecordID(records: [], historyPath: "README.md"))
    }

    // MARK: - 动作可用性（fork update() 的数据上下文检查）

    func testShowAllAffectedFilesAvailabilityMirrorsForkDataContext() {
        // File History tab + 单个选中 revision：可用。
        XCTAssertTrue(isShowAllAffectedFilesAvailable(affectedHistoryPath: "README.md", commitCount: 1))
        // 普通 Log tab：动作不注册。
        XCTAssertFalse(isShowAllAffectedFilesAvailable(affectedHistoryPath: nil, commitCount: 1))
        // 多选 revision：fork 要求单个 VCS_FILE_REVISION。
        XCTAssertFalse(isShowAllAffectedFilesAvailable(affectedHistoryPath: "README.md", commitCount: 2))
        // 空 History 路径：等同无上下文。
        XCTAssertFalse(isShowAllAffectedFilesAvailable(affectedHistoryPath: "", commitCount: 1))
    }
}
