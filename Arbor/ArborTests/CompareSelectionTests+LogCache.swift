import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {

    func testPersistedLogCacheRoundTripsAndRejectsRootOrRefsDrift() throws {
        let commit = logCommit(
            id: "0123456789abcdef",
            repositoryPath: "/workspace/repo"
        )
        let entry = PersistedLogCacheEntry(
            rootPath: "/workspace/repo",
            queryFingerprint: "query-v1",
            refsToken: "refs-v1",
            commits: [commit]
        )

        let decoded = try JSONDecoder().decode(
            PersistedLogCacheEntry.self,
            from: JSONEncoder().encode(entry)
        )

        XCTAssertEqual(
            decoded.restoredCommitsIfValid(
                rootPath: "/workspace/repo",
                queryFingerprint: "query-v1",
                refsToken: "refs-v1"
            ),
            [commit]
        )
        XCTAssertNil(
            decoded.restoredCommitsIfValid(
                rootPath: "/workspace/other",
                queryFingerprint: "query-v1",
                refsToken: "refs-v1"
            )
        )
        XCTAssertNil(
            decoded.restoredCommitsIfValid(
                rootPath: "/workspace/repo",
                queryFingerprint: "query-v1",
                refsToken: "refs-changed"
            )
        )
    }

    func testPersistedLogCacheFingerprintIncludesQueryBoundaries() {
        let base = persistedLogCacheQueryFingerprint(
            rootPath: "/workspace/repo",
            pathFilters: ["Sources"],
            startRevisions: ["main"],
            author: "A",
            message: "fix",
            messageRegex: false,
            messageMatchCase: false,
            since: "2026-01-01",
            until: "",
            noMerges: false,
            follow: false,
            sortMode: "date",
            pageLimit: 80
        )
        let same = persistedLogCacheQueryFingerprint(
            rootPath: "/workspace/repo",
            pathFilters: ["Sources"],
            startRevisions: ["main"],
            author: "A",
            message: "fix",
            messageRegex: false,
            messageMatchCase: false,
            since: "2026-01-01",
            until: "",
            noMerges: false,
            follow: false,
            sortMode: "date",
            pageLimit: 80
        )
        let changedFilter = persistedLogCacheQueryFingerprint(
            rootPath: "/workspace/repo",
            pathFilters: ["Tests"],
            startRevisions: ["main"],
            author: "A",
            message: "fix",
            messageRegex: false,
            messageMatchCase: false,
            since: "2026-01-01",
            until: "",
            noMerges: false,
            follow: false,
            sortMode: "date",
            pageLimit: 80
        )
        let changedPageSize = persistedLogCacheQueryFingerprint(
            rootPath: "/workspace/repo",
            pathFilters: ["Sources"],
            startRevisions: ["main"],
            author: "A",
            message: "fix",
            messageRegex: false,
            messageMatchCase: false,
            since: "2026-01-01",
            until: "",
            noMerges: false,
            follow: false,
            sortMode: "date",
            pageLimit: 200
        )

        XCTAssertEqual(base, same)
        XCTAssertNotEqual(base, changedFilter)
        XCTAssertNotEqual(base, changedPageSize)
    }

    func testPersistedLogGraphRoundTripsContinuationAndRejectsInvalidCompletion() throws {
        let commit = logCommit(
            id: "0123456789abcdef",
            repositoryPath: "/workspace/repo"
        )
        let entry = PersistedLogGraphEntry(
            rootPath: "/workspace/repo",
            queryFingerprint: "graph-v1",
            refsToken: "refs-v1",
            commits: [commit],
            cursor: "0123456789abcdef",
            hasMore: true
        )

        let decoded = try JSONDecoder().decode(
            PersistedLogGraphEntry.self,
            from: JSONEncoder().encode(entry)
        )

        XCTAssertEqual(
            decoded.restoredIfValid(
                rootPath: "/workspace/repo/.",
                queryFingerprint: "graph-v1",
                refsToken: "refs-v1"
            ),
            PersistedLogGraphRestore(
                commits: [commit],
                cursor: "0123456789abcdef",
                hasMore: true
            )
        )
        XCTAssertNil(
            decoded.restoredIfValid(
                rootPath: "/workspace/repo",
                queryFingerprint: "graph-v1",
                refsToken: "refs-changed"
            )
        )

        let incompleteEntry = PersistedLogGraphEntry(
            rootPath: "/workspace/repo",
            queryFingerprint: "graph-v1",
            refsToken: "refs-v1",
            commits: [commit],
            cursor: nil,
            hasMore: true
        )
        XCTAssertNil(
            incompleteEntry.restoredIfValid(
                rootPath: "/workspace/repo",
                queryFingerprint: "graph-v1",
                refsToken: "refs-v1"
            )
        )
    }

    func testPersistedLogGraphFingerprintIgnoresPageBatchSize() {
        let first = persistedLogGraphQueryFingerprint(
            rootPath: "/workspace/repo",
            pathFilters: ["Sources"],
            startRevisions: ["main"],
            author: "A",
            message: "fix",
            messageRegex: false,
            messageMatchCase: false,
            since: "2026-01-01",
            until: "",
            noMerges: false,
            follow: false,
            sortMode: "date"
        )
        let second = persistedLogGraphQueryFingerprint(
            rootPath: "/workspace/repo",
            pathFilters: ["Sources"],
            startRevisions: ["main"],
            author: "A",
            message: "fix",
            messageRegex: false,
            messageMatchCase: false,
            since: "2026-01-01",
            until: "",
            noMerges: false,
            follow: false,
            sortMode: "date"
        )

        XCTAssertEqual(first, second)
    }
}
