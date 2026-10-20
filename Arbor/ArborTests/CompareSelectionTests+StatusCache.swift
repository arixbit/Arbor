import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {

    func testPersistedStatusCacheRoundTripsFilesAndChangeListsByRoot() throws {
        let files = [
            FileEntry(
                path: "Sources/New.swift",
                oldPath: "Sources/Old.swift",
                staged: .renamed,
                unstaged: .modified
            ),
            FileEntry(
                path: "README.md",
                oldPath: nil,
                staged: .unchanged,
                unstaged: .untracked
            )
        ]
        let lists = [
            ChangeListInfo(
                name: "Default",
                paths: ["README.md"],
                isDefault: true,
                isActive: true
            )
        ]
        let cache = PersistedStatusCacheEntry(
            rootPath: "/workspace/repo/.",
            files: files,
            changeLists: lists,
            savedAt: Date(timeIntervalSince1970: 123)
        )

        let encoded = try JSONEncoder().encode(cache)
        let decoded = try JSONDecoder().decode(
            PersistedStatusCacheEntry.self,
            from: encoded
        )
        let snapshot = try XCTUnwrap(
            decoded.restoredSnapshot(rootPath: "/workspace/repo")
        )

        XCTAssertEqual(snapshot.files, files)
        XCTAssertEqual(snapshot.changeLists, lists)
        XCTAssertNil(decoded.restoredSnapshot(rootPath: "/workspace/other"))
    }

    func testLegacyStatusCacheMigrationRemovesOnlyStatusCacheKeys() {
        let suiteName = "ArborStatusCacheMigration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Data([1, 2, 3]), forKey: "arbor.vcs-status-cache.v1.repository")
        defaults.set("keep", forKey: "arbor.status-cache-migration.other")

        migrateLegacyPersistedStatusCaches(defaults: defaults)

        XCTAssertNil(defaults.data(forKey: "arbor.vcs-status-cache.v1.repository"))
        XCTAssertEqual(
            defaults.string(forKey: "arbor.status-cache-migration.other"),
            "keep"
        )
    }
}
