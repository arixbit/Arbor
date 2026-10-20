import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {

    func testExternalLogRootSelectionStartsAllAndRetainsAValidNonEmptyScope() {
        let available = ["/workspace/repo-b", "/workspace/repo-a", "/workspace/repo-a"]

        XCTAssertEqual(
            reconciledExternalLogRootSelection(
                availableRoots: available,
                selectedRoots: [],
                initialized: false
            ),
            ["/workspace/repo-a", "/workspace/repo-b"]
        )
        XCTAssertEqual(
            reconciledExternalLogRootSelection(
                availableRoots: available,
                selectedRoots: ["/workspace/repo-b", "/workspace/missing"],
                initialized: true
            ),
            ["/workspace/repo-b"]
        )
        XCTAssertEqual(
            reconciledExternalLogRootSelection(
                availableRoots: available,
                selectedRoots: ["/workspace/missing"],
                initialized: true
            ),
            ["/workspace/repo-a"]
        )
        XCTAssertTrue(
            reconciledExternalLogRootSelection(
                availableRoots: [],
                selectedRoots: ["/workspace/repo-a"],
                initialized: true
            ).isEmpty
        )
    }

    func testExternalLogWindowRequestNormalizesRootsAndRoundTrips() throws {
        let request = ExternalLogWindowRequest(
            projectPath: "/workspace/project/.",
            rootPaths: [
                "/workspace/project/nested/..",
                "/workspace/project/child",
                "/workspace/project/child"
            ]
        )

        XCTAssertEqual(request.projectPath, "/workspace/project")
        XCTAssertEqual(
            request.rootPaths,
            ["/workspace/project", "/workspace/project/child"]
        )

        let encoded = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(ExternalLogWindowRequest.self, from: encoded), request)
    }

    func testExternalLogWindowGeometryRoundTripsAndRejectsUnsafeFrames() throws {
        let geometry = ExternalLogWindowGeometry(
            x: 120,
            y: 80,
            width: 1642,
            height: 1015
        )
        let encoded = try JSONEncoder().encode(geometry)
        XCTAssertEqual(
            try JSONDecoder().decode(ExternalLogWindowGeometry.self, from: encoded),
            geometry
        )
        XCTAssertTrue(
            externalLogWindowGeometryIsUsable(
                geometry,
                visibleFrames: [CGRect(x: 0, y: 0, width: 1728, height: 1117)]
            )
        )
        XCTAssertFalse(
            externalLogWindowGeometryIsUsable(
                ExternalLogWindowGeometry(x: 0, y: 0, width: 899, height: 600),
                visibleFrames: [CGRect(x: 0, y: 0, width: 1728, height: 1117)]
            )
        )
        XCTAssertFalse(
            externalLogWindowGeometryIsUsable(
                ExternalLogWindowGeometry(x: 3000, y: 3000, width: 1200, height: 800),
                visibleFrames: [CGRect(x: 0, y: 0, width: 1728, height: 1117)]
            )
        )
    }

    func testExternalLogTabsStateRoundTripsAndKeysByRootScope() throws {
        var tab = LogTabDescriptor()
        tab.title = "Feature history"
        tab.viewMode = .reflog
        tab.pathFilter = "Sources"
        tab.selectedIDs = ["root\u{1f}commit"]
        let state = ExternalLogTabsState(tabs: [tab], activeTabID: tab.id)

        let encoded = try JSONEncoder().encode(state)
        XCTAssertEqual(
            try JSONDecoder().decode(ExternalLogTabsState.self, from: encoded),
            state
        )
        let scopedKey = ExternalLogTabsStore.key(
            projectPath: "/tmp/arbor-external-tabs-\(UUID().uuidString)",
            rootPaths: ["/tmp/arbor-external-tabs-root"]
        )
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: scopedKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: scopedKey)
            } else {
                defaults.removeObject(forKey: scopedKey)
            }
        }
        ExternalLogTabsStore.save(state, key: scopedKey)
        XCTAssertEqual(ExternalLogTabsStore.load(key: scopedKey), state)
        XCTAssertEqual(
            ExternalLogTabsStore.key(
                projectPath: "/workspace/project/.",
                rootPaths: ["/workspace/project/child", "/workspace/project"]
            ),
            ExternalLogTabsStore.key(
                projectPath: "/workspace/project",
                rootPaths: ["/workspace/project", "/workspace/project/child"]
            )
        )
        XCTAssertNotEqual(
            ExternalLogTabsStore.key(
                projectPath: "/workspace/project",
                rootPaths: ["/workspace/project"]
            ),
            ExternalLogTabsStore.key(
                projectPath: "/workspace/project",
                rootPaths: ["/workspace/project/child"]
            )
        )

        var newerTab = tab
        newerTab.rootPath = "/workspace/project/nested"
        newerTab.historyPath = "Sources/App.swift"
        let newerObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(newerTab)
            ) as? [String: Any]
        )
        var legacyObject = newerObject
        legacyObject.removeValue(forKey: "rootPath")
        legacyObject.removeValue(forKey: "historyPath")
        let legacyTab = try JSONDecoder().decode(
            LogTabDescriptor.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        XCTAssertNil(legacyTab.rootPath)
        XCTAssertNil(legacyTab.historyPath)
    }

    func testFileHistoryLogTabIsRootQualifiedAndStartsAtRequestedRevision() {
        let tab = makeFileHistoryLogTab(
            path: "Sources/App.swift",
            startRevision: "abc123",
            rootPath: "/workspace/project/./nested"
        )

        XCTAssertEqual(tab.title, "History: App.swift")
        XCTAssertEqual(tab.historyPath, "Sources/App.swift")
        XCTAssertEqual(tab.rootPath, "/workspace/project/nested")
        XCTAssertEqual(tab.startRevision, "abc123")
        XCTAssertEqual(tab.startRevisions, ["abc123"])
        XCTAssertEqual(
            tab.pathSelections,
            [
                LogPathFilterSelection(
                    rootPath: "/workspace/project/nested",
                    path: "Sources/App.swift"
                )
            ]
        )
        XCTAssertTrue(tab.follow)
    }

    func testUpdateInfoLogTabIsDedicatedAndRetainsRootQualifiedRanges() throws {
        let ranges = [
            PersistedLogRevisionRange(
                rootPath: "/workspace/project/docs",
                oldRevision: "docs-before",
                newRevision: "docs-after"
            ),
            PersistedLogRevisionRange(
                rootPath: "/workspace/project/app",
                oldRevision: "app-before",
                newRevision: "app-after"
            )
        ]

        var tab = makeUpdateInfoLogTab(ranges: ranges, title: "Update Info · now")
        XCTAssertEqual(tab.title, "Update Info · now")
        XCTAssertNil(tab.rootPath)
        XCTAssertEqual(tab.updateInfoRanges, ranges)
        XCTAssertEqual(tab.aggregateRevisionRanges, ranges)
        XCTAssertNil(tab.aggregateBranchFilters)

        tab.aggregateRootPaths = ["/workspace/project/app", "/workspace/project/docs"]
        XCTAssertEqual(
            try JSONDecoder().decode(
                LogTabDescriptor.self,
                from: JSONEncoder().encode(tab)
            ),
            tab
        )
    }

    func testExternalLogTabsStateSanitizesDuplicateUIIDs() {
        let first = LogTabDescriptor()
        var duplicate = first
        duplicate.title = "Duplicate"
        let second = LogTabDescriptor()
        let sanitized = ExternalLogTabsState(
            tabs: [first, duplicate, second],
            activeTabID: duplicate.id
        ).sanitized()

        XCTAssertEqual(sanitized.tabs.map(\.id), [first.id, second.id])
        XCTAssertEqual(sanitized.activeTabID, first.id)
    }

    func testExternalLogProviderSessionOwnsAndDisposesSelectedRootRepositories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborExternalLogProvider-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.deletingLastPathComponent()
            .appendingPathComponent("ArborExternalLogProviderAlias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: alias) }

        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "--quiet", root.path]
        try git.run()
        git.waitUntilExit()
        XCTAssertEqual(git.terminationStatus, 0)

        let request = ExternalLogWindowRequest(
            projectPath: root.path,
            rootPaths: [root.path]
        )
        let manager = try ExternalLogManager.initialize(
            request: request,
            executable: "/usr/bin/git"
        )
        let session = manager.providerSession
        let canonicalRootPath = canonicalExternalLogPath(root.path)
        XCTAssertEqual(
            normalizedLogRootPaths([root.path, alias.path]),
            [canonicalRootPath]
        )
        XCTAssertEqual(
            reconciledExternalLogRootSelection(
                availableRoots: [root.path],
                selectedRoots: [alias.path],
                initialized: true
            ),
            [canonicalRootPath]
        )
        XCTAssertEqual(session.providerName, "Git")
        XCTAssertEqual(manager.name, "Vcs Log for Git")
        XCTAssertEqual(
            session.providers[canonicalRootPath],
            ExternalLogProviderDescriptor(name: "Git", rootPath: canonicalRootPath)
        )
        XCTAssertEqual(session.rootPaths, [canonicalRootPath])
        XCTAssertEqual(session.roots.map(\.path), [canonicalRootPath])
        XCTAssertNotNil(session.repository(for: root.path))

        let tabID = UUID()
        XCTAssertTrue(manager.registerUI(tabID))
        XCTAssertFalse(manager.registerUI(tabID))
        XCTAssertTrue(manager.isUIAlive(tabID))
        manager.disposeUI(tabID)
        XCTAssertFalse(manager.isUIAlive(tabID))

        manager.dispose()
        XCTAssertNil(session.repository(for: root.path))
        XCTAssertTrue(session.repositories(for: [root.path]).isEmpty)
    }
}
