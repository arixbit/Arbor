import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {

    func testImportedPatchContextMatcherScoresSplitHunksWithFivePartCap() {
        let patch = (1...6).map { number in
            """
            @@ -\(number * 3 - 2),3 +\(number * 3 - 2),3 @@
             context-\(number)
            -old-\(number)
            +new-\(number)
             tail-\(number)
            """
        }.joined(separator: "\n")
        let text = (1...6).map { number in
            "context-\(number)\nold-\(number)\ntail-\(number)"
        }.joined(separator: "\n")

        XCTAssertEqual(RebasedPatchContextMatcher.score(patch: patch, text: text), 5)
    }

    func testApplyPatchConflictModePreservesPatchSemantics() {
        let mode = MergeRevisionsDialogView.Mode.applyPatch

        XCTAssertTrue(mode.isApplyPatch)
        XCTAssertEqual(mode.title, "Apply Patch — Resolve Conflicts")
        XCTAssertEqual(mode.primaryTitle, "Complete Apply Patch")
        XCTAssertEqual(mode.abortTitle, "Rollback Apply Patch")
    }

    func testUnifiedPatchParserBuildsDifferentiatedFilesWithoutGitHeaders() {
        let patch = """
        --- a/Sources/One.swift
        +++ b/Sources/One.swift
        @@ -1,2 +1,2 @@
         let one = 1
        -let value = 1
        +let value = 2
        --- a/Sources/Two.swift
        +++ b/Sources/Two.swift
        @@ -4,1 +4,1 @@
        -old()
        +new()
        """

        let files = RebasedUnshelveDialog.parsePatchFiles(
            patch,
            allowedPaths: ["Sources/One.swift", "Sources/Two.swift"]
        )

        XCTAssertEqual(files.map(\.path), ["Sources/One.swift", "Sources/Two.swift"])
        XCTAssertEqual(files.map { $0.hunks.count }, [1, 1])
        XCTAssertTrue(files.allSatisfy { $0.status == .modified })
    }

    func testUnifiedPatchDiffParserBuildsStructuredSideBySideContent() {
        let patch = """
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -3,3 +3,3 @@
         let before = true
        -let value = 1
        +let value = 2
         let after = true
        """

        let diff = RebasedPatchDiffParser.parse(
            patch: patch,
            path: "Sources/App.swift"
        )

        XCTAssertEqual(diff?.path, "Sources/App.swift")
        XCTAssertEqual(diff?.hunks.count, 1)
        XCTAssertEqual(diff?.hunks.first?.oldStart, 3)
        XCTAssertEqual(diff?.hunks.first?.newStart, 3)
        XCTAssertEqual(
            diff?.hunks.first?.oldLines.map(\.text),
            ["let before = true", "let value = 1", "let after = true"]
        )
        XCTAssertEqual(
            diff?.hunks.first?.newLines.map(\.text),
            ["let before = true", "let value = 2", "let after = true"]
        )
        XCTAssertEqual(diff?.hunks.first?.oldLines[1].kind, .deletion)
        XCTAssertEqual(diff?.hunks.first?.newLines[1].kind, .addition)
    }

    func testUnifiedPatchParserKeepsGitExtendedHeadersAsOneFile() {
        let patch = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 1111111..2222222 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1,1 +1,1 @@
        -old()
        +new()
        """

        let files = RebasedUnshelveDialog.parsePatchFiles(
            patch,
            allowedPaths: ["Sources/App.swift"]
        )

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.path, "Sources/App.swift")
        XCTAssertEqual(files.first?.hunks.count, 1)
    }

    func testUnifiedDeletedPatchUsesTheOldPathForMapping() {
        let patch = """
        --- a/Sources/Removed.swift
        +++ /dev/null
        @@ -1,1 +0,0 @@
        -removed()
        """

        let files = RebasedUnshelveDialog.parsePatchFiles(
            patch,
            allowedPaths: ["Sources/Removed.swift"]
        )

        XCTAssertEqual(files.first?.path, "Sources/Removed.swift")
        XCTAssertEqual(files.first?.status, .deleted)
    }

    func testPatchPathMapperHonorsZeroStripAndRejectsOverStrip() {
        XCTAssertEqual(
            RebasedPatchPathMapper.strippedPath(rawPath: "a/Sources/App.swift", pathStrip: 0),
            "a/Sources/App.swift"
        )
        XCTAssertEqual(
            RebasedPatchPathMapper.strippedPath(rawPath: "a/Sources/App.swift", pathStrip: 1),
            "Sources/App.swift"
        )
        XCTAssertNil(
            RebasedPatchPathMapper.strippedPath(rawPath: "App.swift", pathStrip: 1)
        )
    }

    func testImportedPatchBaseSearchIncludesUntrackedPackageDescendants() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborPatchBaseSearch-\(UUID().uuidString)")
        let resource = root
            .appendingPathComponent("Demo.app/Contents/Resources/Info.txt")
        try FileManager.default.createDirectory(
            at: resource.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old\n".utf8).write(to: resource)
        defer { try? FileManager.default.removeItem(at: root) }

        let patch = """
        --- a/Contents/Resources/Info.txt
        +++ b/Contents/Resources/Info.txt
        @@ -1,1 +1,1 @@
        -old
        +new
        """
        let file = RebasedShelfPatchFile(
            path: "Contents/Resources/Info.txt",
            hunks: [],
            isBinary: false,
            status: .modified,
            rawPatch: patch
        )

        let candidates = RebasedUnshelveDialog.discoverBaseMappings(
            patchFiles: [file],
            rootPath: root.path,
            indexedPaths: []
        )

        XCTAssertEqual(candidates.first?.basePath, "Demo.app")
        XCTAssertEqual(candidates.first?.pathStrip, 0)
    }

    func testImportedPatchBaseSearchHonorsExplicitExcludedScope() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborPatchScope-\(UUID().uuidString)")
        let included = root.appendingPathComponent("Included/Info.txt")
        let excludedRoot = root.appendingPathComponent("Excluded")
        let excluded = excludedRoot.appendingPathComponent("Info.txt")
        try FileManager.default.createDirectory(
            at: included.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: excludedRoot,
            withIntermediateDirectories: true
        )
        try Data("included\n".utf8).write(to: included)
        try Data("excluded\n".utf8).write(to: excluded)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = RebasedShelfPatchFile(
            path: "Info.txt",
            hunks: [],
            isBinary: false,
            status: .added,
            rawPatch: """
            --- Info.txt
            +++ Info.txt
            @@ -0,0 +1,1 @@
            +new
            """
        )
        let candidates = RebasedUnshelveDialog.discoverBaseMappings(
            patchFiles: [file],
            rootPath: root.path,
            indexedPaths: [],
            scope: RebasedPatchCandidateScope(
                rootPath: root.path,
                excludedPaths: [excludedRoot.path]
            )
        )

        XCTAssertTrue(candidates.contains { $0.basePath == "Included" })
        XCTAssertFalse(candidates.contains { $0.basePath == "Excluded" })
    }

    func testImportedPatchUsesProjectFilenameIndexForVirtualPathsAndExcludesResources() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborPatchFilenameIndex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let excludedRoot = root.appendingPathComponent("ShelfResources")
        let scope = RebasedPatchCandidateScope(
            rootPath: root.path,
            excludedPaths: [excludedRoot.path]
        )
        let filenameIndex = RebasedPatchFilenameIndex(
            rootPath: root.path,
            filePaths: [
                "Sources/Info.txt",
                "ShelfResources/Info.txt",
                "Virtual/OnlyOnIndex.swift"
            ],
            scope: scope
        )
        let file = RebasedShelfPatchFile(
            path: "module/Sources/Info.txt",
            hunks: [],
            isBinary: false,
            status: .modified,
            rawPatch: """
            --- x/Sources/Info.txt
            +++ x/Sources/Info.txt
            @@ -1,1 +1,1 @@
            -old
            +new
            """
        )

        let candidates = RebasedUnshelveDialog.discoverBaseMappings(
            patchFiles: [file],
            rootPath: root.path,
            indexedPaths: [],
            scope: scope,
            filenameIndex: filenameIndex
        )

        XCTAssertTrue(candidates.contains { $0.basePath == "Sources" && $0.pathStrip == 2 })
        XCTAssertFalse(candidates.contains { $0.basePath == "ShelfResources" })
        XCTAssertTrue(filenameIndex.relativeFiles.contains("Virtual/OnlyOnIndex.swift"))
    }

    func testPatchFilenameIndexStorePersistsAndInvalidatesPerRepositoryRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborPatchFilenameIndexStore-\(UUID().uuidString)")
        let sources = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try Data("app\n".utf8).write(to: sources.appendingPathComponent("App.swift"))
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "ArborPatchFilenameIndexStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = RebasedPatchFilenameIndexStore.loadOrBuild(
            rootPath: root.path,
            indexedPaths: [],
            defaults: defaults
        )
        XCTAssertTrue(first.relativeFiles.contains("Sources/App.swift"))

        let persisted = RebasedPatchFilenameIndexStore.loadOrBuild(
            rootPath: root.path,
            indexedPaths: [],
            defaults: defaults
        )
        XCTAssertEqual(persisted, first)

        try Data("new\n".utf8).write(to: sources.appendingPathComponent("New.swift"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 5)],
            ofItemAtPath: sources.path
        )
        XCTAssertFalse(first.isFilesystemCurrent())
        let automaticallyRefreshed = RebasedPatchFilenameIndexStore.loadOrBuild(
            rootPath: root.path,
            indexedPaths: [],
            defaults: defaults
        )
        XCTAssertTrue(automaticallyRefreshed.relativeFiles.contains("Sources/New.swift"))

        try Data("explicit\n".utf8).write(
            to: sources.appendingPathComponent("Explicit.swift")
        )
        RebasedPatchFilenameIndexStore.invalidate(
            rootPath: root.path,
            defaults: defaults
        )
        let refreshed = RebasedPatchFilenameIndexStore.loadOrBuild(
            rootPath: root.path,
            indexedPaths: [],
            defaults: defaults
        )
        XCTAssertTrue(refreshed.relativeFiles.contains("Sources/Explicit.swift"))
        XCTAssertNotEqual(refreshed, first)
    }

    func testPatchFilenameIndexSupportsMultipleContentRootsAndExclusions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborPatchContentRoots-\(UUID().uuidString)")
        let firstRoot = root.appendingPathComponent("ModuleA")
        let secondRoot = root.appendingPathComponent("ModuleB")
        let excludedRoot = secondRoot.appendingPathComponent("ShelfResources")
        try FileManager.default.createDirectory(
            at: firstRoot.appendingPathComponent("Sources"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: excludedRoot,
            withIntermediateDirectories: true
        )
        try Data("a\n".utf8).write(
            to: firstRoot.appendingPathComponent("Sources/App.swift")
        )
        try Data("excluded\n".utf8).write(
            to: excludedRoot.appendingPathComponent("App.swift")
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let scope = RebasedPatchCandidateScope(
            rootPath: root.path,
            contentRootPaths: [firstRoot.path, secondRoot.path],
            excludedPaths: [excludedRoot.path]
        )
        let index = RebasedPatchFilenameIndex.build(
            rootPath: root.path,
            indexedPaths: ["ModuleB/Virtual/OnlyOnIndex.swift"],
            scope: scope
        )

        XCTAssertTrue(index.relativeFiles.contains("ModuleA/Sources/App.swift"))
        XCTAssertTrue(index.relativeFiles.contains("ModuleB/Virtual/OnlyOnIndex.swift"))
        XCTAssertFalse(index.relativeFiles.contains("ModuleB/ShelfResources/App.swift"))
        XCTAssertFalse(index.relativeFiles.contains("Outside/NotInContentRoots.swift"))
        XCTAssertTrue(scope.contains(firstRoot.appendingPathComponent("Sources/App.swift").path))
        XCTAssertFalse(scope.contains(root.appendingPathComponent("Outside").path))
    }

    func testImportedNewPatchInfersBaseWhenTrailingDirectoriesDoNotExist() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborPatchNewPathBaseSearch-\(UUID().uuidString)")
        let existingDirectory = root
            .appendingPathComponent("platform-tests/testSrc/com/intellij/openapi/editor")
        try FileManager.default.createDirectory(
            at: existingDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let patch = """
        --- community/platform/platform-tests/testSrc/com/intellij/openapi/editor/colors/New.java
        +++ community/platform/platform-tests/testSrc/com/intellij/openapi/editor/colors/New.java
        @@ -0,0 +1,1 @@
        +new file
        """
        let file = RebasedShelfPatchFile(
            path: "community/platform/platform-tests/testSrc/com/intellij/openapi/editor/colors/New.java",
            hunks: [],
            isBinary: false,
            status: .added,
            rawPatch: patch
        )

        let candidates = RebasedUnshelveDialog.discoverBaseMappings(
            patchFiles: [file],
            rootPath: root.path,
            indexedPaths: []
        )

        XCTAssertTrue(
            candidates.contains {
                $0.basePath.isEmpty && $0.pathStrip == 2
            }
        )
        XCTAssertEqual(
            RebasedUnshelveDialog.automaticallySelectedBaseMapping(
                patchFiles: [file],
                candidates: candidates
            ),
            RebasedPatchBaseCandidate(basePath: "", pathStrip: 2, contextScore: 0)
        )
    }

    func testImportedNewPatchFallsBackToProjectRootForAmbiguousCandidates() {
        let file = RebasedShelfPatchFile(
            path: "Sources/New.swift",
            hunks: [],
            isBinary: false,
            status: .added,
            rawPatch: ""
        )
        let candidates = [
            RebasedPatchBaseCandidate(basePath: "AppA", pathStrip: 0, contextScore: 0),
            RebasedPatchBaseCandidate(basePath: "AppB", pathStrip: 0, contextScore: 0)
        ]

        XCTAssertNil(
            RebasedUnshelveDialog.automaticallySelectedBaseMapping(
                patchFiles: [file],
                candidates: candidates
            )
        )
    }

    func testImportedPatchContextMatcherSkipsPureInsertionsBeforePartLimit() {
        let patch = """
        @@ -0,0 +1,1 @@
        +inserted
        """ + (1...5).map { number in
            """
            @@ -\(number * 3 - 2),3 +\(number * 3 - 2),3 @@
             context-\(number)
            -old-\(number)
            +new-\(number)
             tail-\(number)
            """
        }.joined(separator: "\n")
        let text = (1...5).map { number in
            "context-\(number)\nold-\(number)\ntail-\(number)"
        }.joined(separator: "\n")

        XCTAssertEqual(RebasedPatchContextMatcher.score(patch: patch, text: text), 5)
    }

    func testImportedPatchContextMatcherUsesExpectedLineWindow() {
        let patch = """
        @@ -2,3 +2,3 @@
         context
        -old
        +new
         tail
        """
        let nearText = ((0..<50).map { "noise-\($0)" } + ["context", "old", "tail"]).joined(separator: "\n")
        let farText = ((0..<102).map { "noise-\($0)" } + ["context", "old", "tail"]).joined(separator: "\n")

        XCTAssertEqual(RebasedPatchContextMatcher.score(patch: patch, text: nearText), 1)
        XCTAssertEqual(RebasedPatchContextMatcher.score(patch: patch, text: farText), 0)
    }
}
