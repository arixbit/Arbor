import XCTest
import Foundation
import CryptoKit
import UserNotifications
@testable import Arbor

final class CompareSelectionTests: XCTestCase {
    func testSearchEverywhereReferencesPreserveKindsAndRootIdentity() {
        let rootA = SearchEverywhereGitRoot(
            rootPath: "/tmp/project/app",
            displayName: "app",
            relativePath: "app",
            branches: [
                BranchInfo(name: "main", isCurrent: true, shortId: "1111111", lastCommitTime: 0),
            ],
            remoteBranches: [
                RemoteBranchInfo(name: "origin/main", remote: "origin", shortId: "2222222"),
            ],
            tags: [
                TagInfo(
                    name: "v1.0",
                    id: "3333333333333333",
                    objectId: "3333333333333333",
                    shortId: "3333333",
                    kind: .lightweight,
                    message: "",
                    isCurrent: false
                ),
            ]
        )
        let rootB = SearchEverywhereGitRoot(
            rootPath: "/tmp/project/web",
            displayName: "web",
            relativePath: "web",
            branches: [
                BranchInfo(name: "main", isCurrent: false, shortId: "4444444", lastCommitTime: 0),
            ],
            remoteBranches: [],
            tags: []
        )

        let items = searchEverywhereReferenceItems(roots: [rootA, rootB], query: "main")

        XCTAssertEqual(items.map(\.kind), [.localBranch, .remoteBranch, .localBranch])
        XCTAssertEqual(items.map(\.rootPath), [
            "/tmp/project/app",
            "/tmp/project/app",
            "/tmp/project/web",
        ])
        XCTAssertEqual(items[0].subtitle, "app · app · current")
        XCTAssertEqual(items[1].revision, "origin/main")
    }

    func testSearchEverywhereCommitQueryThresholdsMatchGitContributor() {
        XCTAssertFalse(searchEverywhereCanSearchCommitByHash("abcdef"))
        XCTAssertTrue(searchEverywhereCanSearchCommitByHash("abcdef1"))
        XCTAssertTrue(searchEverywhereCanSearchCommitByHash("ABCDEF1234567890"))
        XCTAssertFalse(searchEverywhereCanSearchCommitByHash("abcdefg"))
        XCTAssertFalse(searchEverywhereCanSearchCommitByMessage("ab"))
        XCTAssertTrue(searchEverywhereCanSearchCommitByMessage("fix"))
        XCTAssertTrue(searchEverywhereCanSearchCommitByMessage("  fix  "))
    }

    func testConfiguredUpstreamResolvesTheLongestRemotePrefix() {
        let remotes = [
            RemoteInfo(name: "corp", url: "https://example.com/corp.git", pushUrl: nil, fetchRefspec: nil, pushRefspec: nil),
            RemoteInfo(name: "corp/release", url: "https://example.com/release.git", pushUrl: nil, fetchRefspec: nil, pushRefspec: nil),
            RemoteInfo(name: "origin", url: "https://example.com/origin.git", pushUrl: nil, fetchRefspec: nil, pushRefspec: nil),
        ]

        XCTAssertEqual(
            remoteBranchTargetForConfiguredUpstream(" corp/release/2026 ", remotes: remotes)?.remote,
            "corp/release"
        )
        XCTAssertEqual(
            remoteBranchTargetForConfiguredUpstream("corp/release/2026", remotes: remotes)?.branch,
            "2026"
        )
        XCTAssertNil(remoteBranchTargetForConfiguredUpstream("upstream/main", remotes: remotes))
        XCTAssertNil(remoteBranchTargetForConfiguredUpstream("origin/", remotes: remotes))
    }

    func testGitInitializationDetectsExistingRepositoryAndNestedPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("arbor-git-init-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try initializeRepository(path: root.path)

        XCTAssertEqual(
            gitInitializationExistingRepositoryRoot(path: root.path),
            root.standardizedFileURL.path
        )
        XCTAssertEqual(
            gitInitializationExistingRepositoryRoot(path: nested.path),
            root.standardizedFileURL.path
        )
    }

    func testBranchComparisonSeparatesHistoryFromWorkingTreeDiff() {
        XCTAssertEqual(
            branchComparisonLogViewMode(workingTreeDiff: false),
            .compareBranches
        )
        XCTAssertEqual(
            branchComparisonLogViewMode(workingTreeDiff: true),
            .compare
        )
    }

    func testLogNavigationChoiceTitleCarriesRevisionContext() {
        let commit = CommitInfo(
            id: "abcdef1234567890",
            repositoryPath: "/tmp/repo",
            shortId: "abcdef1",
            summary: "Merge feature",
            authorName: "Ada",
            authorEmail: "ada@example.com",
            committerName: "Ada",
            committerEmail: "ada@example.com",
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

        let title = logNavigationChoiceTitle(commit)
        XCTAssertTrue(title.contains("abcdef1"))
        XCTAssertTrue(title.contains("Merge feature"))
        XCTAssertTrue(title.contains("Ada"))
    }

    func testProjectFileTreeRepositoryIdentityUsesCanonicalWorktreePath() throws {
        XCTAssertNil(projectFileTreeRepositoryIdentity(workdir: nil))
        XCTAssertNil(projectFileTreeRepositoryIdentity(workdir: "   "))
        XCTAssertEqual(
            projectFileTreeRepositoryIdentity(workdir: "/tmp/Projects/../repo/"),
            "/tmp/repo"
        )
        XCTAssertNotEqual(
            projectFileTreeRepositoryIdentity(workdir: "/tmp/first/repo"),
            projectFileTreeRepositoryIdentity(workdir: "/tmp/second/repo")
        )

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborFileTreeIdentity-\(UUID().uuidString)")
        let realRoot = temporaryRoot.appendingPathComponent("real")
        let linkRoot = temporaryRoot.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkRoot, withDestinationURL: realRoot)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        XCTAssertEqual(
            projectFileTreeRepositoryIdentity(workdir: linkRoot.path),
            projectFileTreeRepositoryIdentity(workdir: realRoot.path)
        )
    }

    func testRepositoryRelativeClipboardPathRejectsUnsafeEndpoints() {
        XCTAssertEqual(
            normalizedRepositoryRelativePath("  Sources//Arbor/App.swift  "),
            "Sources/Arbor/App.swift"
        )
        XCTAssertNil(normalizedRepositoryRelativePath("/tmp/outside.swift"))
        XCTAssertNil(normalizedRepositoryRelativePath("Sources/../Secrets.txt"))
        XCTAssertNil(normalizedRepositoryRelativePath("."))
    }

    func testProjectFileTreeHistoryIsFileScopedAndNormalizesPath() {
        XCTAssertEqual(
            projectFileTreeHistoryPath(" Sources//Arbor/App.swift ", isDirectory: false),
            "Sources/Arbor/App.swift"
        )
        XCTAssertNil(projectFileTreeHistoryPath("Sources", isDirectory: true))
        XCTAssertNil(projectFileTreeHistoryPath("/tmp/outside.swift", isDirectory: false))
        XCTAssertNil(projectFileTreeHistoryPath("Sources/../Secrets.txt", isDirectory: false))
    }

    func testProjectFileTreeAnnotateKeepsGitUnsupportedFilesDisabled() {
        XCTAssertEqual(
            projectFileTreeHistoryPath(" Sources//Arbor/App.swift ", isDirectory: false),
            "Sources/Arbor/App.swift"
        )
        XCTAssertTrue(
            projectFileTreeCanAnnotate(
                path: "Sources/Arbor/App.swift",
                entries: []
            )
        )

        let modified = FileEntry(
            path: "Sources/Arbor/App.swift",
            oldPath: nil,
            staged: .unchanged,
            unstaged: .modified
        )
        XCTAssertTrue(projectFileTreeCanAnnotate(path: modified.path, entries: [modified]))

        for kind in [ChangeKind.untracked, .deleted, .ignored, .conflicted] {
            let entry = FileEntry(
                path: "Sources/Arbor/App.swift",
                oldPath: nil,
                staged: .unchanged,
                unstaged: kind
            )
            XCTAssertFalse(projectFileTreeCanAnnotate(path: entry.path, entries: [entry]))
        }
    }

    func testProjectFileTreeSameVersionComparisonKeepsHeadBoundary() {
        XCTAssertTrue(
            projectFileTreeCanCompareWithSameVersion(
                path: "Sources/Arbor/App.swift",
                entries: []
            )
        )

        let modified = FileEntry(
            path: "Sources/Arbor/App.swift",
            oldPath: nil,
            staged: .unchanged,
            unstaged: .modified
        )
        XCTAssertTrue(
            projectFileTreeCanCompareWithSameVersion(
                path: modified.path,
                entries: [modified]
            )
        )

        for kind in [ChangeKind.untracked, .ignored, .conflicted] {
            let entry = FileEntry(
                path: "Sources/Arbor/App.swift",
                oldPath: nil,
                staged: .unchanged,
                unstaged: kind
            )
            XCTAssertFalse(
                projectFileTreeCanCompareWithSameVersion(
                    path: entry.path,
                    entries: [entry]
                )
            )
        }
    }

    func testProjectFileTreeSelectedRevisionComparisonRejectsUnsupportedStatus() {
        XCTAssertTrue(
            projectFileTreeCanCompareWithSelectedRevision(
                path: "Sources/App.swift",
                isDirectory: false,
                entries: []
            )
        )

        let deleted = FileEntry(
            path: "Sources/App.swift",
            oldPath: nil,
            staged: .deleted,
            unstaged: .unchanged
        )
        XCTAssertTrue(
            projectFileTreeCanCompareWithSelectedRevision(
                path: deleted.path,
                isDirectory: false,
                entries: [deleted]
            )
        )

        for kind in [ChangeKind.untracked, .ignored, .conflicted] {
            let entry = FileEntry(
                path: "Sources/App.swift",
                oldPath: nil,
                staged: .unchanged,
                unstaged: kind
            )
            XCTAssertFalse(
                projectFileTreeCanCompareWithSelectedRevision(
                    path: entry.path,
                    isDirectory: false,
                    entries: [entry]
                )
            )
        }

        let directoryEntries = [
            FileEntry(
                path: "Sources/App.swift",
                oldPath: nil,
                staged: .unchanged,
                unstaged: .modified
            ),
            FileEntry(
                path: "Sources/Generated.swift",
                oldPath: nil,
                staged: .unchanged,
                unstaged: .untracked
            )
        ]
        XCTAssertFalse(
            projectFileTreeCanCompareWithSelectedRevision(
                path: "Sources",
                isDirectory: true,
                entries: directoryEntries
            )
        )
        XCTAssertTrue(
            projectFileTreeCanCompareWithSelectedRevision(
                path: "Docs",
                isDirectory: true,
                entries: directoryEntries
            )
        )
    }

    func testProjectFileTreeContextMutationsFollowGitFileStatus() {
        let modified = FileEntry(
            path: "Sources/App.swift",
            oldPath: nil,
            staged: .unchanged,
            unstaged: .modified
        )
        XCTAssertTrue(projectFileTreeCanCheckin(
            path: modified.path,
            isDirectory: false,
            entries: [modified]
        ))
        XCTAssertTrue(projectFileTreeCanRevert(
            path: modified.path,
            isDirectory: false,
            entries: [modified]
        ))
        XCTAssertFalse(projectFileTreeCanAdd(
            path: modified.path,
            isDirectory: false,
            entries: [modified]
        ))

        let untracked = FileEntry(
            path: "Sources/New.swift",
            oldPath: nil,
            staged: .unchanged,
            unstaged: .untracked
        )
        XCTAssertTrue(projectFileTreeCanCheckin(
            path: untracked.path,
            isDirectory: false,
            entries: [untracked]
        ))
        XCTAssertTrue(projectFileTreeCanAdd(
            path: untracked.path,
            isDirectory: false,
            entries: [untracked]
        ))
        XCTAssertFalse(projectFileTreeCanRevert(
            path: untracked.path,
            isDirectory: false,
            entries: [untracked]
        ))

        let conflicted = FileEntry(
            path: "Sources/Conflict.swift",
            oldPath: nil,
            staged: .conflicted,
            unstaged: .conflicted
        )
        XCTAssertFalse(projectFileTreeCanCheckin(
            path: conflicted.path,
            isDirectory: false,
            entries: [conflicted]
        ))
        XCTAssertFalse(projectFileTreeCanAdd(
            path: conflicted.path,
            isDirectory: false,
            entries: [conflicted]
        ))
        XCTAssertFalse(projectFileTreeCanRevert(
            path: conflicted.path,
            isDirectory: false,
            entries: [conflicted]
        ))
        XCTAssertEqual(
            projectFileTreeFirstConflictedPath(
                path: conflicted.path,
                isDirectory: false,
                entries: [conflicted]
            ),
            conflicted.path
        )
        XCTAssertNil(projectFileTreeFirstConflictedPath(
            path: "Sources",
            isDirectory: true,
            entries: [conflicted]
        ))

        XCTAssertFalse(projectFileTreeCanCheckin(
            path: "Sources",
            isDirectory: true,
            entries: [modified]
        ))
        XCTAssertFalse(projectFileTreeCanAdd(
            path: "Sources",
            isDirectory: true,
            entries: [untracked]
        ))

    }

    func testProjectFileTreeShowCurrentRevisionFollowsGitFileStatus() {
        let modified = FileEntry(
            path: "Sources/App.swift",
            oldPath: nil,
            staged: .unchanged,
            unstaged: .modified
        )
        XCTAssertTrue(projectFileTreeCanShowCurrentRevision(
            path: modified.path,
            entries: [modified]
        ))
        XCTAssertTrue(projectFileTreeCanShowCurrentRevision(
            path: "Sources/Clean.swift",
            entries: []
        ))

        let untracked = FileEntry(
            path: "Sources/New.swift",
            oldPath: nil,
            staged: .unchanged,
            unstaged: .untracked
        )
        XCTAssertFalse(projectFileTreeCanShowCurrentRevision(
            path: untracked.path,
            entries: [untracked]
        ))

        let ignored = FileEntry(
            path: "Sources/Ignored.swift",
            oldPath: nil,
            staged: .unchanged,
            unstaged: .ignored
        )
        XCTAssertFalse(projectFileTreeCanShowCurrentRevision(
            path: ignored.path,
            entries: [ignored]
        ))

        let conflicted = FileEntry(
            path: "Sources/Conflict.swift",
            oldPath: nil,
            staged: .conflicted,
            unstaged: .conflicted
        )
        XCTAssertFalse(projectFileTreeCanShowCurrentRevision(
            path: conflicted.path,
            entries: [conflicted]
        ))
    }

    func testProjectFileTreeRevertResolvedIsExactFileScoped() {
        XCTAssertTrue(projectFileTreeCanRevertResolved(
            path: "Sources/Conflict.swift",
            isDirectory: false,
            resolvedConflictPaths: ["Sources/Conflict.swift"]
        ))
        XCTAssertFalse(projectFileTreeCanRevertResolved(
            path: "Sources",
            isDirectory: true,
            resolvedConflictPaths: ["Sources/Conflict.swift"]
        ))
        XCTAssertFalse(projectFileTreeCanRevertResolved(
            path: "Sources/Other.swift",
            isDirectory: false,
            resolvedConflictPaths: ["Sources/Conflict.swift"]
        ))
    }

    func testProjectFileHistoryPrefersTheOwningTreeRootOverLogSelection() {
        XCTAssertEqual(
            resolvedFileHistoryRootPath(
                preferredRootPath: "/project/nested",
                selectedCommitRootPath: "/project/other",
                activeLogRootPath: "/project/log",
                repositoryRootPath: "/project"
            ),
            "/project/nested"
        )
        XCTAssertEqual(
            resolvedFileHistoryRootPath(
                preferredRootPath: nil,
                selectedCommitRootPath: "/project/other",
                activeLogRootPath: "/project/log",
                repositoryRootPath: "/project"
            ),
            "/project/other"
        )
    }

    func testFileReferenceChoicesKeepBranchRemoteAndTagIdentity() {
        let choices = fileReferenceChoices(
            localBranches: [
                BranchInfo(name: "feature/z", isCurrent: false, shortId: "z", lastCommitTime: 0),
                BranchInfo(name: "main", isCurrent: true, shortId: "m", lastCommitTime: 0)
            ],
            remoteBranches: [
                RemoteBranchInfo(name: "origin/main", remote: "origin", shortId: "r")
            ],
            tags: [
                TagInfo(
                    name: "main",
                    id: "tag-id",
                    objectId: "tag-object",
                    shortId: "t",
                    kind: .lightweight,
                    message: "",
                    isCurrent: false
                )
            ]
        )

        XCTAssertEqual(
            choices.map { $0.id },
            ["localBranch:feature/z", "localBranch:main", "remoteBranch:origin/main", "tag:main"]
        )
        XCTAssertEqual(choices.filter { $0.name == "main" }.count, 2)
        XCTAssertEqual(choices.last?.revision, "main")
    }

    func testSelectedRevisionChoiceUsesFullObjectIdentityForDiff() {
        let fullID = String(repeating: "a", count: 40)
        let choice = FileReferenceChoice(
            kind: .history,
            name: String(fullID.prefix(7)),
            revisionID: fullID,
            summary: "Change file",
            author: "Author",
            timestamp: 1,
            message: "Change file"
        )

        XCTAssertEqual(choice.revision, fullID)
        XCTAssertEqual(choice.id, "history:\(fullID)")
    }

    func testFileReferenceComparisonUsesDeepestNestedGitRoot() {
        let roots = [
            GitRootInfo(
                path: "/workspace/project",
                displayName: "project",
                relativePath: ".",
                isSubmodule: false,
                headBranch: "main",
                headId: "parent-head",
                dirty: false,
                operation: nil
            ),
            GitRootInfo(
                path: "/workspace/project/vendor/lib",
                displayName: "lib",
                relativePath: "vendor/lib",
                isSubmodule: true,
                headBranch: "main",
                headId: "child-head",
                dirty: false,
                operation: nil
            )
        ]

        XCTAssertEqual(
            fileReferenceComparisonTarget(
                path: "vendor/lib/Sources/README.md",
                primaryRootPath: "/workspace/project",
                roots: roots
            ),
            FileReferenceComparisonTarget(
                rootPath: "/workspace/project/vendor/lib",
                relativePath: "Sources/README.md"
            )
        )
        XCTAssertNil(
            fileReferenceComparisonTarget(
                path: "../outside.txt",
                primaryRootPath: "/workspace/project",
                roots: roots
            )
        )
    }

    func testFileReferenceDirectoryChangesKeepRenameEndpointsUnderDirectory() {
        let changes = [
            TreeChange(
                path: "Sources/New.swift",
                oldPath: "README.md",
                isPureMove: false,
                kind: .renamed,
                oldMode: 0o100644,
                newMode: 0o100644
            ),
            TreeChange(
                path: "Docs/README.md",
                oldPath: nil,
                isPureMove: false,
                kind: .modified,
                oldMode: 0o100644,
                newMode: 0o100644
            ),
            TreeChange(
                path: "README.md",
                oldPath: "Sources/Old.swift",
                isPureMove: false,
                kind: .renamed,
                oldMode: 0o100644,
                newMode: 0o100644
            ),
            TreeChange(
                path: "Sources2/NotIncluded.swift",
                oldPath: nil,
                isPureMove: false,
                kind: .modified,
                oldMode: 0o100644,
                newMode: 0o100644
            )
        ]

        XCTAssertEqual(
            fileReferenceDirectoryChanges(changes, under: "Sources"),
            [changes[0], changes[2]]
        )
        XCTAssertEqual(
            fileReferenceDirectoryChanges(changes, under: "Docs"),
            [changes[1]]
        )
        XCTAssertTrue(fileReferenceDirectoryChanges(changes, under: "").isEmpty)
    }

    func testPersistedRebaseActionKeepsStructuredSquashMessage() {
        let action = RebaseAction.squashWithMessage(message: "combined\n\nreviewed")
        let persisted = PersistedRebaseAction(action: action)

        XCTAssertEqual(persisted.kind, .squash)
        XCTAssertEqual(persisted.message, "combined\n\nreviewed")
        XCTAssertEqual(persisted.makeAction(), action)
    }

    func testBranchComparisonFilterValidatesDatesPerPane() {
        XCTAssertNil(
            branchComparisonFilterDateError(
                BranchComparisonFilter(since: "2026-08-01", until: "2026-08-24"),
                side: .first
            )
        )

        XCTAssertEqual(
            branchComparisonFilterDateError(
                BranchComparisonFilter(since: "not-a-date"),
                side: .first
            ),
            "左侧 Since 必须是 YYYY-MM-DD、YYYY-MM-DD HH:mm 或 Unix seconds"
        )
        XCTAssertEqual(
            branchComparisonFilterDateError(
                BranchComparisonFilter(until: "2026-99-99"),
                side: .second
            ),
            "右侧 Until 必须是 YYYY-MM-DD、YYYY-MM-DD HH:mm 或 Unix seconds"
        )
    }

    func testBranchComparisonGraphSelectionPreservesSamePaneMultiSelection() {
        XCTAssertEqual(
            branchComparisonGraphSelection(
                current: ["a", "b"],
                selectedID: "b",
                validIDs: ["a", "b", "c"]
            ),
            ["a", "b"]
        )
        XCTAssertEqual(
            branchComparisonGraphSelection(
                current: ["a"],
                selectedID: "c",
                validIDs: ["a", "b", "c"]
            ),
            ["c"]
        )
        XCTAssertNil(
            branchComparisonGraphSelection(
                current: ["a"],
                selectedID: "missing",
                validIDs: ["a", "b"]
            )
        )
    }

    func testBranchComparisonPaginationProjectsOnlyNewUniqueEntries() {
        let commits = [
            CommitInfo(
                id: "a", repositoryPath: "/repo", shortId: "a", summary: "a",
                authorName: "A", authorEmail: "a@example.com", committerName: "A",
                committerEmail: "a@example.com", messageBody: "", hasSignature: false,
                time: 0, parentIds: [], refs: [], tagRefs: [], remoteRefs: [],
                isHead: false, lane: 0, parentLanes: []
            ),
            CommitInfo(
                id: "b", repositoryPath: "/repo", shortId: "b", summary: "b",
                authorName: "A", authorEmail: "a@example.com", committerName: "A",
                committerEmail: "a@example.com", messageBody: "", hasSignature: false,
                time: 0, parentIds: [], refs: [], tagRefs: [], remoteRefs: [],
                isHead: false, lane: 0, parentLanes: []
            ),
            CommitInfo(
                id: "c", repositoryPath: "/repo", shortId: "c", summary: "c",
                authorName: "A", authorEmail: "a@example.com", committerName: "A",
                committerEmail: "a@example.com", messageBody: "", hasSignature: false,
                time: 0, parentIds: [], refs: [], tagRefs: [], remoteRefs: [],
                isHead: false, lane: 0, parentLanes: []
            )
        ]
        XCTAssertEqual(
            branchComparisonNewEntries(
                returned: commits + [commits[1]],
                existingIDs: ["a"]
            ).map(\.id),
            ["b", "c"]
        )
        XCTAssertTrue(
            branchComparisonHasMore(
                returnedCount: 80,
                requestedLimit: 80,
                isHashQuery: false
            )
        )
        XCTAssertFalse(
            branchComparisonHasMore(
                returnedCount: 80,
                requestedLimit: 80,
                isHashQuery: true
            )
        )
    }

    func testBranchComparisonRefreshKeepsSelectionFromOtherPane() {
        XCTAssertEqual(
            branchComparisonSelectionAfterRefresh(
                selectedID: "second-commit",
                firstIDs: ["first-commit"],
                secondIDs: ["second-commit"]
            ).id,
            "second-commit"
        )
        XCTAssertEqual(
            branchComparisonSelectionAfterRefresh(
                selectedID: "removed-first-commit",
                firstIDs: [],
                secondIDs: ["second-commit"]
            ).side,
            .second
        )
        XCTAssertNil(
            branchComparisonSelectionAfterRefresh(
                selectedID: "removed",
                firstIDs: [],
                secondIDs: []
            ).id
        )
    }

    func testComparePatchArgumentsKeepRevisionsAndPathsAsSeparateArguments() {
        XCTAssertEqual(
            comparePatchGitArguments(
                rev1: "feature/with spaces",
                rev2: "release;echo unsafe",
                comparesWithWorkingTree: false,
                paths: ["Sources/A B.swift", "README.md"]
            ),
            [
                "--binary",
                "--no-ext-diff",
                "feature/with spaces",
                "release;echo unsafe",
                "--",
                "Sources/A B.swift",
                "README.md"
            ]
        )
        XCTAssertEqual(
            comparePatchGitArguments(
                rev1: "HEAD",
                rev2: "ignored",
                comparesWithWorkingTree: true,
                paths: ["file.txt"]
            ),
            ["--binary", "--no-ext-diff", "HEAD", "--", "file.txt"]
        )
    }

    func testVcsNotificationGroupsMapToNativePresentationAndSharedThreads() {
        XCTAssertEqual(
            arborNativeNotificationThreadIdentifier(for: .standard),
            "arbor.git.standard"
        )
        XCTAssertEqual(
            arborNativeNotificationThreadIdentifier(for: .important),
            "arbor.git.important"
        )
        XCTAssertEqual(
            arborNativeNotificationCategoryIdentifier(for: "git.fetch.project"),
            "arbor.notification.category.git.fetch.project"
        )
        XCTAssertTrue(
            arborNativeNotificationPresentationOptions(for: .standard).contains(.banner)
        )
        XCTAssertFalse(
            arborNativeNotificationPresentationOptions(for: .standard).contains(.sound)
        )
        XCTAssertTrue(
            arborNativeNotificationPresentationOptions(for: .important).contains(.sound)
        )
        XCTAssertEqual(
            arborNativeNotificationPresentationOptions(for: .toolWindow),
            []
        )
        XCTAssertEqual(
            arborNativeNotificationPresentationOptions(for: .silent),
            []
        )
    }

    func testNativeNotificationAuthorizationTreatsDisabledAlertsAsUnavailable() {
        XCTAssertEqual(
            arborNativeNotificationAuthorizationAllowed(
                authorizationStatus: .authorized,
                alertSetting: .enabled
            ),
            true
        )
        XCTAssertEqual(
            arborNativeNotificationAuthorizationAllowed(
                authorizationStatus: .authorized,
                alertSetting: .disabled
            ),
            false
        )
        XCTAssertEqual(
            arborNativeNotificationAuthorizationAllowed(
                authorizationStatus: .denied,
                alertSetting: .enabled
            ),
            false
        )
        XCTAssertNil(
            arborNativeNotificationAuthorizationAllowed(
                authorizationStatus: .notDetermined,
                alertSetting: .notSupported
            )
        )
    }

    @MainActor
    func testNativeNotificationPermissionWarningProvidesRecoveryAction() {
        let suiteName = "Arbor.NativeNotificationPermissionWarningTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.applyNativeNotificationAuthorizationStatus(false)

        XCTAssertEqual(
            feedbackCenter.nativeNotificationPermissionWarning?.title,
            "macOS notifications are disabled"
        )
        XCTAssertEqual(
            feedbackCenter.nativeNotificationPermissionWarning?.actionTitle,
            "Open Notification Settings"
        )
        XCTAssertNotNil(feedbackCenter.nativeNotificationPermissionWarning?.action)
        XCTAssertTrue(feedbackCenter.history.isEmpty)

        feedbackCenter.applyNativeNotificationAuthorizationStatus(true)
        XCTAssertNil(feedbackCenter.nativeNotificationPermissionWarning)
    }

    func testStashDeleteSelectionResolvesByStableIDAfterStackIndexShifts() {
        let initial = [
            StashInfo(id: "stash-new", shortId: "new", message: "new"),
            StashInfo(id: "stash-old", shortId: "old", message: "old"),
            StashInfo(id: "stash-older", shortId: "older", message: "older")
        ]
        XCTAssertEqual(stashIndex(forID: "stash-old", in: initial), 1)

        let afterDroppingNewest = Array(initial.dropFirst())
        XCTAssertEqual(stashIndex(forID: "stash-old", in: afterDroppingNewest), 0)
        XCTAssertNil(stashIndex(forID: "stash-missing", in: afterDroppingNewest))
    }

    func testPullStashSelectionRequiresTheExactPersistedMessage() {
        let stashes = [
            StashInfo(id: "user-stash", shortId: "user", message: "WIP"),
            StashInfo(id: "pull-stash", shortId: "pull", message: "Arbor: pull 123")
        ]

        XCTAssertEqual(pullStashIndex(message: "Arbor: pull 123", in: stashes), 1)
        XCTAssertNil(pullStashIndex(message: nil, in: stashes))
        XCTAssertNil(pullStashIndex(message: "Arbor: pull", in: stashes))

        let duplicateMessage = stashes + [
            StashInfo(id: "duplicate", shortId: "dupe", message: "Arbor: pull 123")
        ]
        XCTAssertNil(pullStashIndex(message: "Arbor: pull 123", in: duplicateMessage))
    }

    func testStashSplitPreviewSettingDefaultsOnAndPersists() {
        let suiteName = "Arbor.StashSplitPreviewSettingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(GitStashViewSettings.splitPreview(from: defaults))

        GitStashViewSettings.saveSplitPreview(false, defaults: defaults)
        XCTAssertFalse(GitStashViewSettings.splitPreview(from: defaults))

        GitStashViewSettings.saveSplitPreview(true, defaults: defaults)
        XCTAssertTrue(GitStashViewSettings.splitPreview(from: defaults))
    }

    func testEmbeddedPinentryProtocolEscapesAndUnescapesGpgData() {
        let original = "line one\n百分号 %\r"
        let encoded = ArborPinentryProtocol.escape(original)

        XCTAssertEqual(encoded, "line one%0A%E7%99%BE%E5%88%86%E5%8F%B7 %25%0D")
        XCTAssertEqual(ArborPinentryProtocol.unescape(encoded), original)
    }

    func testPinentryEndpointAndEncryptedPassphraseRoundTrip() throws {
        let serviceKey = Curve25519.KeyAgreement.PrivateKey()
        let clientKey = Curve25519.KeyAgreement.PrivateKey()
        let endpoint = ArborPinentryEndpoint(
            publicKey: serviceKey.publicKey.rawRepresentation,
            host: "127.0.0.1",
            port: 41_237
        )

        XCTAssertEqual(ArborPinentryEndpoint.parse(endpoint.token), endpoint)
        XCTAssertNil(ArborPinentryEndpoint.parse("AR_PINENTRY=not-a-key:127.0.0.1:41237"))

        let encrypted = try ArborPinentryCrypto.encrypt(
            passphrase: "päss phrase % with spaces",
            clientPublicKey: clientKey.publicKey.rawRepresentation,
            servicePrivateKey: serviceKey
        )
        XCTAssertEqual(
            try ArborPinentryCrypto.decrypt(
                payload: encrypted,
                servicePublicKey: serviceKey.publicKey.rawRepresentation,
                clientPrivateKey: clientKey
            ),
            "päss phrase % with spaces"
        )
    }

    func testEmbeddedPinentryLauncherShellQuotesExecutablePaths() {
        XCTAssertEqual(
            ArborEmbeddedPinentry.shellQuote("/Users/me/O'Reilly/Arbor.app"),
            "'/Users/me/O'\\''Reilly/Arbor.app'"
        )

        let script = ArborEmbeddedPinentry.launcherScript(
            executable: "/Applications/Arbor.app/Contents/MacOS/Arbor",
            fallbackPath: "/opt/homebrew/bin/pinentry"
        )
        XCTAssertTrue(script.contains("--arbor-pinentry"))
        XCTAssertTrue(script.contains("exec '/opt/homebrew/bin/pinentry' \"$@\""))
        XCTAssertTrue(script.contains("case \"${PINENTRY_USER_DATA-}\" in"))
        XCTAssertTrue(script.contains("AR_PINENTRY=*)"))
        XCTAssertTrue(script.contains("IJ_PINENTRY_ENTRYPOINT=*)"))
        XCTAssertTrue(script.contains("entrypoint=\"${entrypoint%%:*}\""))
        XCTAssertFalse(script.contains("status=$?"))
    }

    func testEmbeddedPinentryLauncherRoutesOnlyArborSessionsToHelper() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Arbor Pinentry Launcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let helper = root.appendingPathComponent("helper")
        let fallback = root.appendingPathComponent("fallback")
        let launcher = root.appendingPathComponent("launcher")
        let helperOutput = root.appendingPathComponent("helper-output")
        let fallbackOutput = root.appendingPathComponent("fallback-output")

        try writeExecutableScript(
            at: helper,
            body: "touch \(ArborEmbeddedPinentry.shellQuote(helperOutput.path))\nprintf 'helper:%s\\n' \"$*\" > \(ArborEmbeddedPinentry.shellQuote(helperOutput.path))\nexit 7\n"
        )
        try writeExecutableScript(
            at: fallback,
            body: "printf 'fallback:%s\\n' \"$*\" > \(ArborEmbeddedPinentry.shellQuote(fallbackOutput.path))\n"
        )
        let script = ArborEmbeddedPinentry.launcherScript(
            executable: helper.path,
            fallbackPath: fallback.path
        )
        try Data(script.utf8).write(to: launcher)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: launcher.path
        )

        let noSession = try runLauncher(launcher, environment: [:])
        XCTAssertEqual(noSession.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: helperOutput.path))
        XCTAssertEqual(
            try String(contentsOf: fallbackOutput, encoding: .utf8),
            "fallback:launcher-test-argument\n"
        )

        try FileManager.default.removeItem(at: fallbackOutput)
        let arborSession = try runLauncher(
            launcher,
            environment: ["PINENTRY_USER_DATA": "AR_PINENTRY=test-token"]
        )
        XCTAssertEqual(arborSession.terminationStatus, 7)
        XCTAssertEqual(
            try String(contentsOf: helperOutput, encoding: .utf8),
            "helper:--arbor-pinentry launcher-test-argument\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallbackOutput.path))
    }

    func testEmbeddedPinentryLauncherForwardsRemoteEntrypointBeforeFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Arbor Remote Pinentry Launcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let remote = root.appendingPathComponent("remote entrypoint")
        let fallback = root.appendingPathComponent("fallback")
        let launcher = root.appendingPathComponent("launcher")
        let remoteOutput = root.appendingPathComponent("remote-output")
        let fallbackOutput = root.appendingPathComponent("fallback-output")

        try writeExecutableScript(
            at: remote,
            body: "printf 'remote:%s\\n' \"$*\" > \(ArborEmbeddedPinentry.shellQuote(remoteOutput.path))\nexit 9\n"
        )
        try writeExecutableScript(
            at: fallback,
            body: "printf 'fallback:%s\\n' \"$*\" > \(ArborEmbeddedPinentry.shellQuote(fallbackOutput.path))\n"
        )
        let script = ArborEmbeddedPinentry.launcherScript(
            executable: root.appendingPathComponent("Arbor.app").path,
            fallbackPath: fallback.path
        )
        try Data(script.utf8).write(to: launcher)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: launcher.path
        )

        let result = try runLauncher(
            launcher,
            environment: [
                "PINENTRY_USER_DATA": "\(ArborEmbeddedPinentry.remoteEntrypointPrefix)\(remote.path):public-key:127.0.0.1:1234"
            ]
        )
        XCTAssertEqual(result.terminationStatus, 9)
        XCTAssertEqual(
            try String(contentsOf: remoteOutput, encoding: .utf8),
            "remote:launcher-test-argument\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fallbackOutput.path))

        let emptyEntrypoint = try runLauncher(
            launcher,
            environment: [
                "PINENTRY_USER_DATA": "\(ArborEmbeddedPinentry.remoteEntrypointPrefix):public-key:127.0.0.1:1234"
            ]
        )
        XCTAssertEqual(emptyEntrypoint.terminationStatus, 0)
        XCTAssertEqual(
            try String(contentsOf: fallbackOutput, encoding: .utf8),
            "fallback:launcher-test-argument\n"
        )
    }

    private func writeExecutableScript(at url: URL, body: String) throws {
        try Data("#!/bin/sh\nset -u\n\(body)".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
    }

    private func runLauncher(
        _ launcher: URL,
        environment: [String: String]
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [launcher.path, "launcher-test-argument"]
        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment.removeValue(forKey: "PINENTRY_USER_DATA")
        process.environment = processEnvironment.merging(environment) { _, new in new }
        try process.run()
        process.waitUntilExit()
        return process
    }

    func testGpgSigningFailureClassifierOffersConfigurationOnlyForGpgFailures() {
        XCTAssertTrue(
            gitCommitSigningFailureNeedsGPGConfiguration(
                "error: gpg failed to sign the data"
            )
        )
        XCTAssertTrue(
            gitCommitSigningFailureNeedsGPGConfiguration(
                "gpg: signing failed: No secret key"
            )
        )
        XCTAssertFalse(
            gitCommitSigningFailureNeedsGPGConfiguration(
                "ssh-keygen signing failed for the configured key"
            )
        )
        XCTAssertTrue(
            gnuPGAvailabilityFailure("cannot start gpgconf: No such file or directory")
        )
        XCTAssertTrue(
            gnuPGAvailabilityFailure("cannot resolve GnuPG home directory")
        )
        XCTAssertFalse(gnuPGAvailabilityFailure("gpgconf status command failed"))
    }

    func testOpenGpgAgentSettingsActionRequestRoundTrips() throws {
        let request = ArborVCSActionRequest(
            kind: .openGpgAgentSettings,
            projectPath: "/project",
            rootPath: nil,
            shelfName: ""
        )
        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(
            GnuPGInstallationGuide.downloadURL.absoluteString,
            "https://gnupg.org/download/"
        )
    }

    func testBranchPopupActionSpeedSearchMatchesOnlyEnabledActionFilter() {
        XCTAssertEqual(
            filteredBranchPopupActions(
                query: "commit",
                filterByAction: true
            ),
            [.commitChanges]
        )
        XCTAssertEqual(
            filteredBranchPopupActions(
                query: "new branch",
                filterByAction: true
            ),
            [.newBranch]
        )
        XCTAssertEqual(
            filteredBranchPopupActions(
                query: "checkout revision",
                filterByAction: true
            ),
            [.checkoutReference]
        )
        XCTAssertTrue(
            filteredBranchPopupActions(
                query: "new branch",
                filterByAction: false
            ).isEmpty
        )
        XCTAssertEqual(
            branchPopupVisibleActions(
                query: "no matching action",
                filterByAction: false
            ),
            BranchPopupActionID.allCases
        )
    }

    func testBranchPopupCommitActionRequiresChangesAndExplainsDisabledState() {
        XCTAssertFalse(
            isBranchPopupActionEnabled(
                .commitChanges,
                hasHeadCommit: true,
                hasCommitChanges: false
            )
        )
        XCTAssertTrue(
            isBranchPopupActionEnabled(
                .commitChanges,
                hasHeadCommit: false,
                hasCommitChanges: true
            )
        )
        XCTAssertFalse(
            isBranchPopupActionEnabled(.newBranch, hasHeadCommit: false)
        )
        XCTAssertTrue(
            isBranchPopupActionEnabled(.newBranch, hasHeadCommit: true)
        )
        XCTAssertTrue(
            isBranchPopupActionEnabled(.checkoutReference, hasHeadCommit: false)
        )
        XCTAssertEqual(
            branchPopupActionDisabledDescription(.newBranch, hasHeadCommit: false),
            "Cannot create new branch in empty repository. Make initial commit first"
        )
        XCTAssertNil(
            branchPopupActionDisabledDescription(.newBranch, hasHeadCommit: true)
        )
        XCTAssertNil(
            branchPopupActionDisabledDescription(.checkoutReference, hasHeadCommit: false)
        )
        XCTAssertEqual(
            branchPopupActionDisabledDescription(
                .commitChanges,
                hasHeadCommit: true,
                hasCommitChanges: false
            ),
            "There are no Git changes to commit"
        )
    }

    func testBranchPopupNewBranchActionIsVisibleButDisabledForUnbornRepositories() {
        XCTAssertFalse(
            isBranchPopupActionEnabled(.newBranch, hasHeadCommit: false)
        )
        XCTAssertTrue(
            isBranchPopupActionEnabled(.newBranch, hasHeadCommit: true)
        )
        XCTAssertTrue(
            isBranchPopupActionEnabled(.checkoutReference, hasHeadCommit: false)
        )
        XCTAssertEqual(
            branchPopupActionDisabledDescription(.newBranch, hasHeadCommit: false),
            "Cannot create new branch in empty repository. Make initial commit first"
        )
        XCTAssertNil(
            branchPopupActionDisabledDescription(.newBranch, hasHeadCommit: true)
        )
        XCTAssertNil(
            branchPopupActionDisabledDescription(.checkoutReference, hasHeadCommit: false)
        )
        XCTAssertFalse(isFindMergedBranchesActionEnabled(localBranchCounts: [1]))
        XCTAssertTrue(isFindMergedBranchesActionEnabled(localBranchCounts: [1, 2]))
    }

    func testMultiRootBranchRepositorySearchMatchesNameAndRelativePath() {
        XCTAssertTrue(
            branchPopupRepositorySearchMatches(
                displayName: "Payments",
                relativePath: "services/payments",
                query: "pay"
            )
        )
        XCTAssertTrue(
            branchPopupRepositorySearchMatches(
                displayName: "Payments",
                relativePath: "services/payments",
                query: "services"
            )
        )
        XCTAssertFalse(
            branchPopupRepositorySearchMatches(
                displayName: "Payments",
                relativePath: "services/payments",
                query: ""
            )
        )
        XCTAssertFalse(
            branchPopupRepositorySearchMatches(
                displayName: "Payments",
                relativePath: "services/payments",
                query: "frontend"
            )
        )
    }

    func testMultiRootRepositoryTargetParticipatesInKeyboardSelection() {
        let repository = BranchTreeTarget(
            id: "multi.repository:/workspace/services/payments",
            value: "Payments services/payments",
            title: "Payments",
            kind: .repository,
            rootPath: "/workspace/services/payments"
        )
        let branch = BranchTreeTarget(
            id: "multi.local:payments",
            value: "payments",
            title: "payments",
            kind: .local
        )

        XCTAssertEqual(
            bestBranchTreeTargetID(
                query: "services",
                targets: [repository, branch]
            ),
            repository.id
        )
    }

    func testBranchPopupRepositoryScopeEscapeReturnsBeforeDismiss() {
        XCTAssertEqual(
            branchPopupExitDestination(repositoryFilter: "/workspace/services/payments"),
            .repositoryList
        )
        XCTAssertEqual(
            branchPopupExitDestination(repositoryFilter: "  "),
            .dismiss
        )
    }

    func testBranchPopupOperationActionsMatchIntelliJGroupsAndConflictVisibility() {
        XCTAssertEqual(
            branchPopupOperationActions(for: .rebase, hasConflicts: false),
            [.abortRebase, .rebaseContinue, .rebaseSkip]
        )
        XCTAssertEqual(
            branchPopupOperationActions(for: .merge, hasConflicts: false),
            [.mergeAbort]
        )
        XCTAssertEqual(
            gitMainMenuOperationActions(for: .merge, hasConflicts: false),
            [.mergeCommit, .mergeAbort]
        )
        XCTAssertEqual(
            gitMainMenuOperationActions(for: .merge, hasConflicts: true),
            [.mergeAbort]
        )
        XCTAssertEqual(
            branchPopupOperationActions(for: .cherryPick, hasConflicts: false),
            [.cherryPickAbort, .cherryPickContinue]
        )
        XCTAssertEqual(
            branchPopupOperationActions(for: .cherryPick, hasConflicts: true),
            [.cherryPickAbort]
        )
        XCTAssertEqual(
            branchPopupOperationActions(for: .revert, hasConflicts: true),
            [.revertAbort]
        )
    }

    func testBranchDashboardActionUpdateDisablesCommitDependentActionsForUnbornRoots() {
        let head = BranchDashboardReference(
            rootPath: "/workspace/unborn",
            name: "HEAD",
            kind: .head,
            remote: nil,
            isCurrent: true,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false,
            hasHeadCommit: false
        )
        let currentBranch = BranchDashboardReference(
            rootPath: "/workspace/unborn",
            name: "main",
            kind: .local,
            remote: nil,
            isCurrent: true,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false,
            hasHeadCommit: false
        )

        let headAvailability = BranchDashboardActionAvailability.resolve(selection: [head])
        let branchAvailability = BranchDashboardActionAvailability.resolve(selection: [currentBranch])

        XCTAssertTrue(headAvailability.contains(.checkoutAsNewBranch))
        XCTAssertFalse(headAvailability.isEnabled(.checkoutAsNewBranch))
        XCTAssertTrue(headAvailability.contains(.createWorktree))
        XCTAssertFalse(headAvailability.isEnabled(.createWorktree))
        XCTAssertFalse(branchAvailability.isEnabled(.checkoutAsNewBranch))
        XCTAssertFalse(branchAvailability.isEnabled(.createWorktree))
    }

    func testCherryPickedComparisonRejectsStaleOrCancelledResults() {
        XCTAssertTrue(
            isCurrentCherryPickedComparison(
                highlightingEnabled: true,
                currentComparisonGeneration: 4,
                resultComparisonGeneration: 4,
                currentLogGeneration: 9,
                resultLogGeneration: 9,
                currentSourceBranch: "feature",
                resultSourceBranch: "feature"
            )
        )
        XCTAssertFalse(
            isCurrentCherryPickedComparison(
                highlightingEnabled: false,
                currentComparisonGeneration: 4,
                resultComparisonGeneration: 4,
                currentLogGeneration: 9,
                resultLogGeneration: 9,
                currentSourceBranch: "feature",
                resultSourceBranch: "feature"
            )
        )
        XCTAssertFalse(
            isCurrentCherryPickedComparison(
                highlightingEnabled: true,
                currentComparisonGeneration: 5,
                resultComparisonGeneration: 4,
                currentLogGeneration: 9,
                resultLogGeneration: 9,
                currentSourceBranch: "feature",
                resultSourceBranch: "feature"
            )
        )
        XCTAssertFalse(
            isCurrentCherryPickedComparison(
                highlightingEnabled: true,
                currentComparisonGeneration: 4,
                resultComparisonGeneration: 4,
                currentLogGeneration: 10,
                resultLogGeneration: 9,
                currentSourceBranch: "release",
                resultSourceBranch: "feature"
            )
        )
    }

    func testCherryPickedHighlightRequiresCompletedBranchAwareComparison() {
        let highlighted = Set(["root\u{1f}picked"])

        XCTAssertFalse(
            isCherryPickedCommitHighlighted(
                highlightingEnabled: true,
                comparisonReady: false,
                identity: "root\u{1f}picked",
                highlightedCommitIDs: highlighted
            )
        )
        XCTAssertFalse(
            isCherryPickedCommitHighlighted(
                highlightingEnabled: true,
                comparisonReady: true,
                identity: "root\u{1f}other",
                highlightedCommitIDs: highlighted
            )
        )
        XCTAssertTrue(
            isCherryPickedCommitHighlighted(
                highlightingEnabled: true,
                comparisonReady: true,
                identity: "root\u{1f}picked",
                highlightedCommitIDs: highlighted
            )
        )
        XCTAssertFalse(
            isCherryPickedCommitHighlighted(
                highlightingEnabled: false,
                comparisonReady: true,
                identity: "root\u{1f}picked",
                highlightedCommitIDs: highlighted
            )
        )
    }

    func testCherryPickTargetUsesOppositeCompareBranch() {
        XCTAssertEqual(
            cherryPickTargetBranch(
                mode: .compareBranches,
                sourceBranch: "feature",
                firstBranch: "feature",
                secondBranch: "main",
                currentBranch: "feature"
            ),
            "main"
        )
        XCTAssertEqual(
            cherryPickTargetBranch(
                mode: .compareBranches,
                sourceBranch: "main",
                firstBranch: "feature",
                secondBranch: "main",
                currentBranch: "main"
            ),
            "feature"
        )
        XCTAssertEqual(
            cherryPickTargetBranch(
                mode: .graph,
                sourceBranch: "feature",
                firstBranch: "feature",
                secondBranch: "main",
                currentBranch: "main"
            ),
            "main"
        )
    }

    func testCherryPickHighlightTurnsOffWhenSourceBranchIsCleared() {
        XCTAssertFalse(
            cherryPickHighlightEnabledAfterSourceChange(
                sourceBranch: "  ",
                currentlyEnabled: true
            )
        )
        XCTAssertTrue(
            cherryPickHighlightEnabledAfterSourceChange(
                sourceBranch: "feature",
                currentlyEnabled: true
            )
        )
        XCTAssertFalse(
            cherryPickHighlightEnabledAfterSourceChange(
                sourceBranch: "feature",
                currentlyEnabled: false
            )
        )
    }

    func testCherryPickSourceBranchEligibilityIsRootScoped() {
        XCTAssertTrue(
            cherryPickSourceBranchExists(
                "feature",
                localBranchNames: ["main"],
                remoteBranchNames: ["origin/feature", "feature"]
            )
        )
        XCTAssertFalse(
            cherryPickSourceBranchExists(
                "feature",
                localBranchNames: ["main"],
                remoteBranchNames: ["origin/other"]
            )
        )
    }

    func testVCSQuickActionItemsMatchGitQuickListOrderAndEnablement() {
        let items = vcsQuickActionItems(
            isShallowRepository: false,
            hasCurrentBranch: false,
            hasConflicts: false,
            hasUnstagedTrackedChanges: false,
            hasUnstagedChanges: false
        )

        XCTAssertEqual(
            items.map(\.action),
            [
                .commit,
                .stageTracked,
                .branches,
                .push,
                .stash,
                .unstash,
                .worktrees,
                .stageAll,
                .copyCurrentBranchName,
                .resolveConflicts
            ]
        )
        XCTAssertFalse(items.first { $0.action == .copyCurrentBranchName }!.isEnabled)
        XCTAssertFalse(items.first { $0.action == .resolveConflicts }!.isEnabled)
        XCTAssertFalse(items.first { $0.action == .commit }!.isEnabled)
        XCTAssertFalse(items.first { $0.action == .stageTracked }!.isEnabled)
        XCTAssertFalse(items.first { $0.action == .stageAll }!.isEnabled)
        XCTAssertTrue(items.first { $0.action == .push }!.isEnabled)

        let stagedOnlyItems = vcsQuickActionItems(
            isShallowRepository: false,
            hasCurrentBranch: true,
            hasConflicts: false,
            hasUnstagedTrackedChanges: false,
            hasUnstagedChanges: false,
            hasCommitChanges: true
        )
        XCTAssertTrue(stagedOnlyItems.first { $0.action == .commit }!.isEnabled)

        let shallowItems = vcsQuickActionItems(
            isShallowRepository: true,
            hasCurrentBranch: true,
            hasConflicts: true,
            hasUnstagedTrackedChanges: true,
            hasUnstagedChanges: true
        )
        XCTAssertEqual(shallowItems.last?.action, .fetchUnshallow)
        XCTAssertTrue(shallowItems.first { $0.action == .copyCurrentBranchName }!.isEnabled)
        XCTAssertTrue(shallowItems.first { $0.action == .resolveConflicts }!.isEnabled)

        let shallowFetchBusyItems = vcsQuickActionItems(
            isShallowRepository: true,
            hasCurrentBranch: true,
            hasConflicts: true,
            hasUnstagedTrackedChanges: true,
            hasUnstagedChanges: true,
            hasFetchInProgress: true
        )
        XCTAssertFalse(shallowFetchBusyItems.first { $0.action == .fetchUnshallow }!.isEnabled)

        let noRepositoryItems = vcsQuickActionItems(
            isShallowRepository: false,
            hasCurrentBranch: true,
            hasConflicts: true,
            hasUnstagedTrackedChanges: true,
            hasUnstagedChanges: true,
            hasRepository: false
        )
        XCTAssertTrue(noRepositoryItems.allSatisfy { !$0.isEnabled })

        let untrackedOnlyItems = vcsQuickActionItems(
            isShallowRepository: false,
            hasCurrentBranch: true,
            hasConflicts: false,
            hasUnstagedTrackedChanges: false,
            hasUnstagedChanges: true
        )
        XCTAssertFalse(untrackedOnlyItems.first { $0.action == .stageTracked }!.isEnabled)
        XCTAssertTrue(untrackedOnlyItems.first { $0.action == .stageAll }!.isEnabled)

        let conflictOnlyItems = vcsQuickActionItems(
            isShallowRepository: false,
            hasCurrentBranch: true,
            hasConflicts: true,
            hasUnstagedTrackedChanges: false,
            hasUnstagedChanges: false
        )
        XCTAssertFalse(conflictOnlyItems.first { $0.action == .stageTracked }!.isEnabled)
        XCTAssertFalse(conflictOnlyItems.first { $0.action == .stageAll }!.isEnabled)
    }

    func testVCSActionContextMatchesGitMenuEnablement() {
        let unavailable = ArborVCSActionContext(
            hasRepository: false,
            hasCurrentBranch: false,
            hasLocalChanges: false,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: false
        )
        XCTAssertFalse(isArborVCSActionEnabled(.showLog, in: unavailable))
        XCTAssertFalse(isArborVCSActionEnabled(.showShelf, in: unavailable))
        XCTAssertFalse(isArborVCSActionEnabled(.showStash, in: unavailable))
        XCTAssertFalse(isArborVCSActionEnabled(.showStagingArea, in: unavailable))
        XCTAssertFalse(isArborVCSActionEnabled(.revertSelectedChanges, in: unavailable))
        XCTAssertFalse(isArborVCSActionEnabled(.configureRemotes, in: unavailable))
        XCTAssertFalse(isArborVCSActionEnabled(.showExternalLog, in: unavailable))
        XCTAssertFalse(isArborVCSActionEnabled(.quickActions, in: unavailable))
        XCTAssertFalse(isArborVCSActionEnabled(.searchEverywhere, in: unavailable))
        XCTAssertFalse(isArborVCSActionEnabled(.applyPatchFromClipboard, in: unavailable))
        XCTAssertFalse(isArborVCSActionEnabled(.commit, in: unavailable))
        XCTAssertFalse(isArborVCSActionVisible(.merge, in: unavailable))
        XCTAssertFalse(isArborVCSActionVisible(.rebase, in: unavailable))

        let clean = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: false,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: false
        )
        XCTAssertTrue(isArborVCSActionEnabled(.branches, in: clean))
        XCTAssertTrue(isArborVCSActionEnabled(.showShelf, in: clean))
        XCTAssertTrue(isArborVCSActionEnabled(.showStash, in: clean))
        XCTAssertTrue(isArborVCSActionEnabled(.showStagingArea, in: clean))
        XCTAssertFalse(isArborVCSActionEnabled(.revertSelectedChanges, in: clean))
        XCTAssertTrue(isArborVCSActionEnabled(.configureRemotes, in: clean))
        XCTAssertTrue(isArborVCSActionEnabled(.update, in: clean))
        XCTAssertTrue(isArborVCSActionEnabled(.reset, in: clean))
        XCTAssertFalse(isArborVCSActionEnabled(.showExternalLog, in: clean))
        XCTAssertTrue(isArborVCSActionEnabled(.newBranch, in: clean))
        XCTAssertTrue(isArborVCSActionEnabled(.merge, in: clean))
        XCTAssertTrue(isArborVCSActionEnabled(.rebase, in: clean))
        XCTAssertTrue(isArborVCSActionVisible(.merge, in: clean))
        XCTAssertTrue(isArborVCSActionEnabled(.push, in: clean))
        XCTAssertTrue(isArborVCSActionEnabled(.pull, in: clean))
        XCTAssertTrue(isArborVCSActionEnabled(.pullMerge, in: clean))
        XCTAssertTrue(pullDialogDefaultRebase(explicit: nil, savedOptions: [.rebase]))
        XCTAssertFalse(pullDialogDefaultRebase(explicit: nil, savedOptions: []))
        XCTAssertFalse(pullDialogDefaultRebase(explicit: false, savedOptions: [.rebase]))
        XCTAssertTrue(isArborVCSActionEnabled(.applyPatchFromClipboard, in: clean))
        XCTAssertFalse(isArborVCSActionEnabled(.commit, in: clean))
        XCTAssertFalse(isArborVCSActionEnabled(.fetch, in: clean))
        XCTAssertFalse(isArborVCSActionEnabled(.revertResolved, in: clean))
        XCTAssertFalse(isArborVCSActionEnabled(.resetToRemoteBranch, in: clean))

        let unbornRepository = ArborVCSActionContext(
            hasRepository: true,
            allRepositoriesHaveHeadCommit: false,
            hasCurrentBranch: false,
            hasLocalChanges: false,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: false
        )
        XCTAssertFalse(isArborVCSActionEnabled(.newBranch, in: unbornRepository))

        let selectedFile = ArborSelectedGitFileContext(
            path: "Sources/App.swift",
            rootRelativePath: "Sources/App.swift",
            isDirectory: false,
            owningRootPath: "/workspace/project",
            isPrimaryRoot: true,
            canCheckin: true,
            canAdd: false,
            canAnnotate: true,
            canCompareWithHead: true,
            canCompareWithSelectedRevision: true
        )
        let fileActions = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: true,
            hasUnstagedTrackedChanges: true,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: false,
            selectedFileAction: selectedFile
        )
        XCTAssertTrue(isArborVCSActionEnabled(.fileCheckin, in: fileActions))
        XCTAssertFalse(isArborVCSActionEnabled(.fileAdd, in: fileActions))
        XCTAssertTrue(isArborVCSActionEnabled(.fileAnnotate, in: fileActions))
        XCTAssertTrue(isArborVCSActionEnabled(.fileCompareSameVersion, in: fileActions))
        XCTAssertTrue(isArborVCSActionEnabled(.fileCompareSelectedRevision, in: fileActions))
        XCTAssertTrue(isArborVCSActionEnabled(.fileCompareWithBranch, in: fileActions))
        XCTAssertTrue(isArborVCSActionEnabled(.fileHistory, in: fileActions))

        let untrackedFile = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: true,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: false,
            selectedFileAction: ArborSelectedGitFileContext(
                path: "new.txt",
                rootRelativePath: "new.txt",
                isDirectory: false,
                owningRootPath: "/workspace/project",
                isPrimaryRoot: true,
                canCheckin: true,
                canAdd: true,
                canAnnotate: true,
                canCompareWithHead: false,
                canCompareWithSelectedRevision: false
            )
        )
        XCTAssertTrue(isArborVCSActionEnabled(.fileAdd, in: untrackedFile))

        let nestedFile = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: true,
            hasUnstagedTrackedChanges: true,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: false,
            selectedFileAction: ArborSelectedGitFileContext(
                path: "vendor/lib/Sources/App.swift",
                rootRelativePath: "Sources/App.swift",
                isDirectory: false,
                owningRootPath: "/workspace/project/vendor/lib",
                isPrimaryRoot: false,
                canCheckin: false,
                canAdd: false,
                canAnnotate: false,
                canCompareWithHead: true,
                canCompareWithSelectedRevision: true
            )
        )
        XCTAssertFalse(isArborVCSActionEnabled(.fileCheckin, in: nestedFile))
        XCTAssertFalse(isArborVCSActionEnabled(.fileAnnotate, in: nestedFile))
        XCTAssertTrue(isArborVCSActionEnabled(.fileCompareSameVersion, in: nestedFile))

        let fileActionBusy = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: true,
            hasUnstagedTrackedChanges: true,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: false,
            hasBackgroundVCSOperation: true,
            selectedFileAction: selectedFile
        )
        XCTAssertFalse(isArborVCSActionEnabled(.fileCheckin, in: fileActionBusy))
        XCTAssertFalse(isArborVCSActionEnabled(.fileAnnotate, in: fileActionBusy))

        let directoryActions = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: false,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: false,
            selectedFileAction: ArborSelectedGitFileContext(
                path: "Sources",
                rootRelativePath: "Sources",
                isDirectory: true,
                owningRootPath: "/workspace/project",
                isPrimaryRoot: true,
                canCheckin: false,
                canAdd: false,
                canAnnotate: false,
                canCompareWithHead: false,
                canCompareWithSelectedRevision: false
            )
        )
        XCTAssertTrue(isArborVCSActionEnabled(.fileCompareWithBranch, in: directoryActions))
        XCTAssertFalse(isArborVCSActionEnabled(.fileHistory, in: directoryActions))

        let resolvedSelection = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: false,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: false,
            selectedLocalChangePath: "conflicted.txt",
            selectedResolvedConflictPath: "conflicted.txt"
        )
        XCTAssertTrue(isArborVCSActionEnabled(.revertResolved, in: resolvedSelection))

        XCTAssertTrue(isArborFetchInProgress(isRunning: true, operationName: "Fetch"))
        XCTAssertTrue(isArborFetchInProgress(isRunning: true, operationName: "Fetch all remotes"))
        XCTAssertTrue(isArborFetchInProgress(isRunning: true, operationName: "Fetch remote branch"))
        XCTAssertTrue(isArborFetchInProgress(isRunning: true, operationName: "Prune remote branches"))
        XCTAssertFalse(isArborFetchInProgress(isRunning: true, operationName: "Pull"))
        XCTAssertFalse(isArborFetchInProgress(isRunning: false, operationName: "Fetch"))
        XCTAssertTrue(isArborBackgroundVCSOperationInProgress(
            feedbackIsRunning: false,
            multiRootIsRunning: false
        ) == false)
        XCTAssertTrue(isArborBackgroundVCSOperationInProgress(
            feedbackIsRunning: true,
            multiRootIsRunning: false
        ))
        XCTAssertTrue(isArborBackgroundVCSOperationInProgress(
            feedbackIsRunning: false,
            multiRootIsRunning: true
        ))

        let trackedRemote = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: false,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: true,
            hasTrackedUpstream: true,
            hasSingleGitRoot: true
        )
        XCTAssertTrue(isArborVCSActionEnabled(.resetToRemoteBranch, in: trackedRemote))

        let dirty = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: true,
            hasUnstagedTrackedChanges: true,
            hasStagedChanges: true,
            hasConflicts: true,
            isShallowRepository: true,
            hasRemotes: true,
            selectedLocalChangePath: "tracked.txt"
        )
        XCTAssertTrue(isArborVCSActionEnabled(.commitAndPush, in: dirty))
        XCTAssertTrue(isArborVCSActionEnabled(.stageTracked, in: dirty))
        XCTAssertTrue(isArborVCSActionEnabled(.stash, in: dirty))
        XCTAssertTrue(isArborVCSActionEnabled(.unstash, in: dirty))
        XCTAssertTrue(isArborVCSActionEnabled(.fetchUnshallow, in: dirty))
        XCTAssertTrue(isArborVCSActionEnabled(.resolveConflicts, in: dirty))
        XCTAssertTrue(isArborVCSActionEnabled(.fetchAll, in: dirty))
        XCTAssertTrue(isArborVCSActionEnabled(.revertSelectedChanges, in: dirty))

        let fetchBusy = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: false,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: true,
            hasRemotes: true,
            hasFetchInProgress: true
        )
        XCTAssertFalse(isArborVCSActionEnabled(.fetch, in: fetchBusy))
        XCTAssertFalse(isArborVCSActionEnabled(.fetchAll, in: fetchBusy))

        let updateBusy = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: false,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: true,
            hasBackgroundVCSOperation: true
        )
        XCTAssertFalse(isArborVCSActionEnabled(.update, in: updateBusy))
        XCTAssertFalse(isArborVCSActionEnabled(.reset, in: updateBusy))
        XCTAssertFalse(isArborVCSActionEnabled(.pullMerge, in: updateBusy))
        XCTAssertFalse(isArborVCSActionEnabled(.pullRebase, in: updateBusy))
        XCTAssertFalse(isArborVCSActionEnabled(.fetchPrune, in: fetchBusy))
        XCTAssertFalse(isArborVCSActionEnabled(.fetchUnshallow, in: fetchBusy))

        let operationBusy = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: false,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: true,
            hasRepositoryOperationInProgress: true,
            selectedLocalChangePath: "tracked.txt"
        )
        XCTAssertFalse(isArborVCSActionEnabled(.pullMerge, in: operationBusy))
        XCTAssertFalse(isArborVCSActionEnabled(.pullRebase, in: operationBusy))
        XCTAssertFalse(isArborVCSActionEnabled(.reset, in: operationBusy))
        XCTAssertFalse(isArborVCSActionEnabled(.revertResolved, in: operationBusy))
        XCTAssertFalse(isArborVCSActionEnabled(.revertSelectedChanges, in: operationBusy))

        let externalLog = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: false,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: false,
            projectPath: "/tmp/project"
        )
        XCTAssertTrue(isArborVCSActionEnabled(.showExternalLog, in: externalLog))

        let stagedOnly = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: true,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: true,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: true
        )
        XCTAssertFalse(isArborVCSActionEnabled(.stageTracked, in: stagedOnly))
        XCTAssertTrue(isArborVCSActionEnabled(.commit, in: stagedOnly))

        let multiRootCommit = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: false,
            hasLocalChanges: false,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: false,
            hasConflicts: false,
            isShallowRepository: false,
            hasRemotes: true,
            hasMultipleGitRoots: true,
            hasProjectCommitChanges: true,
            hasTrackedUpstream: true
        )
        XCTAssertTrue(isArborVCSActionEnabled(.commitAndPush, in: multiRootCommit))
        XCTAssertFalse(isArborVCSActionEnabled(.resetToRemoteBranch, in: multiRootCommit))

        let rebasePaused = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: true,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: true,
            hasConflicts: true,
            isShallowRepository: false,
            hasRemotes: true,
            hasRebaseInProgress: true
        )
        XCTAssertFalse(isArborVCSActionEnabled(.rebase, in: rebasePaused))
        XCTAssertFalse(isArborVCSActionVisible(.rebase, in: rebasePaused))
        XCTAssertTrue(isArborVCSActionVisible(.rebase, in: clean))

        let mergePaused = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: true,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: true,
            hasConflicts: true,
            isShallowRepository: false,
            hasRemotes: true,
            hasMergeInProgress: true
        )
        XCTAssertFalse(isArborVCSActionEnabled(.merge, in: mergePaused))
        XCTAssertFalse(isArborVCSActionVisible(.merge, in: mergePaused))

        let allRepositoriesBusy = ArborVCSActionContext(
            hasRepository: true,
            hasCurrentBranch: true,
            hasLocalChanges: true,
            hasUnstagedTrackedChanges: false,
            hasStagedChanges: true,
            hasConflicts: true,
            isShallowRepository: false,
            hasRemotes: true,
            hasNormalOrDetachedRepository: false
        )
        XCTAssertFalse(isArborVCSActionEnabled(.rebase, in: allRepositoriesBusy))
        XCTAssertTrue(isArborVCSActionVisible(.rebase, in: allRepositoriesBusy))
        XCTAssertFalse(isArborVCSActionEnabled(.merge, in: allRepositoriesBusy))
        XCTAssertTrue(isArborVCSActionVisible(.merge, in: allRepositoriesBusy))

        let secondaryRootMergeOperation = GitRootInfo(
            path: "/workspace/project/vendor/lib",
            displayName: "lib",
            relativePath: "vendor/lib",
            isSubmodule: true,
            headBranch: "feature",
            headId: "abc123",
            dirty: true,
            operation: .merge
        )
        XCTAssertTrue(
            isArborMergeInProgress(
                currentOperation: nil,
                roots: [secondaryRootMergeOperation]
            )
        )
        var secondaryRootCherryPicking = secondaryRootMergeOperation
        secondaryRootCherryPicking.operation = .cherryPick
        XCTAssertFalse(
            isArborMergeInProgress(
                currentOperation: nil,
                roots: [secondaryRootCherryPicking]
            )
        )

        let secondaryRootRebasing = GitRootInfo(
            path: "/workspace/project/vendor/lib",
            displayName: "lib",
            relativePath: "vendor/lib",
            isSubmodule: true,
            headBranch: "feature",
            headId: "abc123",
            dirty: true,
            operation: .rebase
        )
        XCTAssertTrue(
            isArborRebaseInProgress(
                currentOperation: nil,
                roots: [secondaryRootRebasing],
                hasMultiRootSession: false
            )
        )
        var secondaryRootMerging = secondaryRootRebasing
        secondaryRootMerging.operation = .merge
        XCTAssertFalse(
            isArborRebaseInProgress(
                currentOperation: nil,
                roots: [secondaryRootMerging],
                hasMultiRootSession: false
            )
        )

        let cleanRoot = GitRootInfo(
            path: "/workspace/project",
            displayName: "project",
            relativePath: ".",
            isSubmodule: false,
            headBranch: "main",
            headId: "def456",
            dirty: false,
            operation: nil
        )
        XCTAssertFalse(
            isArborRebaseInProgress(
                currentOperation: nil,
                roots: [cleanRoot],
                hasMultiRootSession: false
            )
        )
        XCTAssertFalse(
            hasArborNormalOrDetachedRepository(
                currentOperation: .merge,
                currentRootPath: cleanRoot.path,
                roots: [cleanRoot]
            )
        )
        var secondaryRootNormal = secondaryRootMerging
        secondaryRootNormal.operation = nil
        XCTAssertTrue(
            hasArborNormalOrDetachedRepository(
                currentOperation: .merge,
                currentRootPath: cleanRoot.path,
                roots: [cleanRoot, secondaryRootNormal]
            )
        )
    }

    func testVCSQuickActionFilterRequiresAllQueryTokensCaseInsensitively() {
        let items = vcsQuickActionItems(
            isShallowRepository: true,
            hasCurrentBranch: true,
            hasConflicts: true,
            hasUnstagedTrackedChanges: true,
            hasUnstagedChanges: true
        )

        XCTAssertEqual(
            filteredVCSQuickActionItems(items, query: "FULL history").map(\.action),
            [.fetchUnshallow]
        )
        XCTAssertEqual(
            filteredVCSQuickActionItems(items, query: "branch copy").map(\.action),
            [.copyCurrentBranchName]
        )
        XCTAssertTrue(filteredVCSQuickActionItems(items, query: "does-not-exist").isEmpty)
    }

    func testGitMergeRebaseWidgetItemsPreferLiveCurrentRootState() {
        let currentRoot = GitRootInfo(
            path: "/workspace/project",
            displayName: "project",
            relativePath: ".",
            isSubmodule: false,
            headBranch: "main",
            headId: "head",
            dirty: true,
            operation: .merge
        )
        let secondaryRoot = GitRootInfo(
            path: "/workspace/project/vendor/lib",
            displayName: "lib",
            relativePath: "vendor/lib",
            isSubmodule: true,
            headBranch: "feature",
            headId: "head-2",
            dirty: true,
            operation: .rebase
        )

        let items = gitMergeRebaseWidgetItems(
            currentRootPath: "/workspace/project/.",
            currentOperation: .rebase,
            roots: [currentRoot, secondaryRoot]
        )

        XCTAssertEqual(items.map(\.rootPath), ["/workspace/project", "/workspace/project/vendor/lib"])
        XCTAssertEqual(items.map(\.operation), [.rebase, .rebase])
        XCTAssertTrue(items.first?.isCurrent == true)
    }

    func testGitMergeRebaseWidgetItemsRemoveStaleCurrentSnapshotState() {
        let currentRoot = GitRootInfo(
            path: "/workspace/project",
            displayName: "project",
            relativePath: ".",
            isSubmodule: false,
            headBranch: "main",
            headId: "head",
            dirty: false,
            operation: .merge
        )
        let secondaryRoot = GitRootInfo(
            path: "/workspace/project/vendor/lib",
            displayName: "lib",
            relativePath: "vendor/lib",
            isSubmodule: true,
            headBranch: "feature",
            headId: "head-2",
            dirty: true,
            operation: .cherryPick
        )

        let items = gitMergeRebaseWidgetItems(
            currentRootPath: "/workspace/project",
            currentOperation: nil,
            roots: [currentRoot, secondaryRoot]
        )

        XCTAssertEqual(items.map(\.rootPath), ["/workspace/project/vendor/lib"])
        XCTAssertEqual(items.first?.operation, .cherryPick)
    }

    func testSelectedRevertPathIsTrackedAndSelectionScoped() {
        let tracked = FileEntry(
            path: "tracked.txt",
            oldPath: nil,
            staged: .modified,
            unstaged: .unchanged
        )
        let untracked = FileEntry(
            path: "new.txt",
            oldPath: nil,
            staged: .unchanged,
            unstaged: .untracked
        )
        let conflicted = FileEntry(
            path: "conflict.txt",
            oldPath: nil,
            staged: .conflicted,
            unstaged: .conflicted
        )
        let ignored = FileEntry(
            path: "ignored.log",
            oldPath: nil,
            staged: .unchanged,
            unstaged: .ignored
        )

        XCTAssertEqual(
            arborSelectedRevertPath(
                entries: [tracked, untracked, conflicted, ignored],
                candidates: ["new.txt", "tracked.txt"]
            ),
            "tracked.txt"
        )
        XCTAssertNil(
            arborSelectedRevertPath(
                entries: [tracked],
                candidates: ["tracked.txt"],
                headPresentByPath: ["tracked.txt": false]
            )
        )
        XCTAssertNil(
            arborSelectedRevertPath(
                entries: [tracked, untracked, conflicted, ignored],
                candidates: ["missing.txt", "new.txt", "conflict.txt", "ignored.log"]
            )
        )
    }

    @MainActor
    func testVCSQuickActionsPanelCoordinatorUsesReusableNonModalPanel() {
        let coordinator = VCSQuickActionsPanelCoordinator()
        let items = vcsQuickActionItems(
            isShallowRepository: false,
            hasCurrentBranch: true,
            hasConflicts: false,
            hasUnstagedTrackedChanges: false,
            hasUnstagedChanges: false
        )

        coordinator.present(items: items) { _ in }
        XCTAssertTrue(coordinator.isPresented)
        XCTAssertEqual(coordinator.panelWindow?.title, "Quick Git Actions")
        XCTAssertTrue(coordinator.panelWindow?.styleMask.contains(.utilityWindow) == true)
        let firstPanel = coordinator.panelWindow

        coordinator.present(items: Array(items.dropFirst()), onAction: { _ in })
        XCTAssertTrue(coordinator.isPresented)
        XCTAssertTrue(coordinator.panelWindow === firstPanel)

        coordinator.close()
        XCTAssertFalse(coordinator.isPresented)
        XCTAssertNil(coordinator.panelWindow)
    }

    func testCredentialPersistenceNeverStoresSSHPassphrase() {
        XCTAssertTrue(
            credentialResponseShouldSaveToKeychain(
                kind: .usernamePassword,
                requested: true
            )
        )
        XCTAssertFalse(
            credentialResponseShouldSaveToKeychain(
                kind: .passphrase,
                requested: true
            )
        )
        XCTAssertFalse(
            credentialResponseShouldSaveToKeychain(
                kind: .usernamePassword,
                requested: false
            )
        )
    }

    func testRebaseTodoResetRestoresInitialActionsOrderAndMessages() {
        let initial = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "first", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .reword, commitId: "b", summary: "second", message: "edited", isMergeCommit: false, canSquashOrFixup: true)
        ]
        let current = [
            RebaseTodoItem(action: .drop, commitId: "b", summary: "second", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "a", summary: "first", message: nil, isMergeCommit: false, canSquashOrFixup: false)
        ]

        XCTAssertEqual(
            resetRebaseTodoDraftItems(current: current, initial: initial),
            initial
        )
        XCTAssertEqual(
            resetRebaseTodoDraftItems(current: initial, initial: initial),
            initial
        )
    }

    func testPreparedRootRewordTodoChangesOnlySelectedRootAndPreservesMergeRows() {
        let todo = RebaseTodo(
            onto: "",
            items: [
                RebaseTodoItem(
                    action: .pick,
                    commitId: "root123",
                    summary: "root",
                    message: nil,
                    isMergeCommit: false,
                    canSquashOrFixup: false
                ),
                RebaseTodoItem(
                    action: .pick,
                    commitId: "merge456",
                    summary: "merge",
                    message: nil,
                    isMergeCommit: true,
                    canSquashOrFixup: false
                ),
                RebaseTodoItem(
                    action: .pick,
                    commitId: "post789",
                    summary: "post",
                    message: nil,
                    isMergeCommit: false,
                    canSquashOrFixup: false
                )
            ]
        )

        let prepared = preparedRootRewordTodo(
            todo,
            rootCommitID: "root",
            message: "new root\n\nbody"
        )

        XCTAssertEqual(prepared?.items[0].action, .reword)
        XCTAssertEqual(prepared?.items[0].message, "new root\n\nbody")
        XCTAssertEqual(prepared?.items[1].action, .pick)
        XCTAssertTrue(prepared?.items[1].isMergeCommit == true)
        XCTAssertNil(prepared?.items[2].message)
        XCTAssertEqual(todo.items[0].action, .pick)
        XCTAssertNil(todo.items[0].message)
    }

    func testPreparedRootRewordTodoRejectsMissingRoot() {
        let todo = RebaseTodo(
            onto: "",
            items: [
                RebaseTodoItem(
                    action: .pick,
                    commitId: "root123",
                    summary: "root",
                    message: nil,
                    isMergeCommit: false,
                    canSquashOrFixup: false
                )
            ]
        )

        XCTAssertNil(
            preparedRootRewordTodo(
                todo,
                rootCommitID: "missing",
                message: "new root"
            )
        )
    }

    func testRebaseTodoResetPreservesMergeTopologyMarker() {
        let initial = [
            RebaseTodoItem(
                action: .pick,
                commitId: "merge",
                summary: "merge feature",
                message: nil,
                isMergeCommit: true,
                canSquashOrFixup: false
            )
        ]
        let current = [
            RebaseTodoItem(
                action: .drop,
                commitId: "merge",
                summary: "merge feature",
                message: nil,
                isMergeCommit: false,
                canSquashOrFixup: true
            )
        ]

        let restored = resetRebaseTodoDraftItems(current: current, initial: initial)
        XCTAssertEqual(restored, initial)
        XCTAssertTrue(restored.first?.isMergeCommit == true)
    }

    func testRebaseTodoSquashFixupRequiresKeptPredecessor() {
        let initial = [
            RebaseTodoItem(
                action: .pick,
                commitId: "parent",
                summary: "parent",
                message: nil,
                isMergeCommit: false,
                canSquashOrFixup: false
            ),
            RebaseTodoItem(
                action: .pick,
                commitId: "child",
                summary: "child",
                message: nil,
                isMergeCommit: false,
                canSquashOrFixup: true
            )
        ]

        XCTAssertTrue(
            rebaseTodoCanSquashOrFixup(items: initial, index: 1, preserveMerges: true)
        )

        var dropped = initial
        dropped[0].action = .drop
        XCTAssertFalse(
            rebaseTodoCanSquashOrFixup(items: dropped, index: 1, preserveMerges: true)
        )
        normalizeRebaseTodoActions(&dropped, preserveMerges: true)
        XCTAssertEqual(dropped[1].action, .pick)
    }

    func testPreserveMergeTodoReorderStaysInsideNativeBranchSegments() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "a", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .pick, commitId: "b", summary: "b", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "merge", summary: "merge", message: nil, isMergeCommit: true, canSquashOrFixup: false),
            RebaseTodoItem(action: .pick, commitId: "c", summary: "c", message: nil, isMergeCommit: false, canSquashOrFixup: false)
        ]

        XCTAssertEqual(
            rebaseTodoPreserveMergeSegmentRanges(items).map { Array($0) },
            [[0, 1], [3]]
        )

        let withinSegment = moveRebaseTodoItems(
            items,
            selectedIndices: [1],
            requestedIndex: 1,
            by: -1
        )
        XCTAssertTrue(
            rebaseTodoPreserveMergeReorderIsSafe(original: items, updated: withinSegment)
        )
        XCTAssertTrue(
            rebaseTodoCanMove(
                items,
                selectedIndices: [1],
                requestedIndex: 1,
                by: -1,
                preserveMerges: true
            )
        )

        let acrossBoundary = moveRebaseTodoItems(
            items,
            selectedIndices: [1],
            requestedIndex: 1,
            by: 1
        )
        XCTAssertFalse(
            rebaseTodoPreserveMergeReorderIsSafe(original: items, updated: acrossBoundary)
        )
        XCTAssertFalse(
            rebaseTodoCanMove(
                items,
                selectedIndices: [1],
                requestedIndex: 1,
                by: 1,
                preserveMerges: true
            )
        )
    }

    func testPreserveMergeTodoReorderCannotMoveMergeAnchor() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "a", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .pick, commitId: "merge", summary: "merge", message: nil, isMergeCommit: true, canSquashOrFixup: false),
            RebaseTodoItem(action: .pick, commitId: "b", summary: "b", message: nil, isMergeCommit: false, canSquashOrFixup: false)
        ]

        XCTAssertFalse(
            rebaseTodoCanMove(
                items,
                selectedIndices: [1],
                requestedIndex: 1,
                by: -1,
                preserveMerges: true
            )
        )
    }

    func testMultiRootPreserveMergeOrderChangeIsScopedPerRepository() {
        let rootA = [
            RebaseTodoItem(action: .pick, commitId: "a1", summary: "a1", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .pick, commitId: "a2", summary: "a2", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "am", summary: "merge", message: nil, isMergeCommit: true, canSquashOrFixup: false)
        ]
        var rootAReordered = rootA
        rootAReordered.swapAt(0, 1)
        let rootB = [
            RebaseTodoItem(action: .pick, commitId: "b1", summary: "b1", message: nil, isMergeCommit: false, canSquashOrFixup: false)
        ]

        XCTAssertTrue(
            rebaseTodoPreserveMergeOrderChanged(
                initial: rootA,
                current: rootAReordered,
                preserveMerges: true
            )
        )
        XCTAssertFalse(
            rebaseTodoPreserveMergeOrderChanged(
                initial: rootB,
                current: rootB,
                preserveMerges: true
            )
        )
        XCTAssertFalse(
            rebaseTodoPreserveMergeOrderChanged(
                initial: rootA,
                current: rootAReordered,
                preserveMerges: false
            )
        )
    }

    func testRebaseTodoActionClearsMessageOutsideRewordAndSquash() {
        var item = RebaseTodoItem(
            action: .reword,
            commitId: "commit",
            summary: "message",
            message: "edited",
            isMergeCommit: false,
            canSquashOrFixup: true
        )

        setRebaseTodoAction(&item, action: .pick)
        XCTAssertNil(item.message)

        item.message = "combined"
        setRebaseTodoAction(&item, action: .squash)
        XCTAssertEqual(item.message, "combined")

        setRebaseTodoAction(&item, action: .drop)
        XCTAssertNil(item.message)
    }

    func testRebaseTodoActionDetachesChangedSquashChildAndPreservesGroup() {
        var items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "A", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .squash, commitId: "b", summary: "B", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .fixup, commitId: "c", summary: "C", message: nil, isMergeCommit: false, canSquashOrFixup: true)
        ]

        XCTAssertTrue(applyRebaseTodoAction(&items, at: 1, action: .edit))
        XCTAssertEqual(items.map(\.commitId), ["a", "c", "b"])
        XCTAssertEqual(items.map(\.action), [.pick, .fixup, .edit])
        XCTAssertFalse(rebaseTodoCanReword(items: items, index: 1))
        XCTAssertTrue(rebaseTodoCanReword(items: items, index: 2))
    }

    func testRebaseTodoDropOnSquashRootDropsTheWholeGroup() {
        var items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "A", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .squash, commitId: "b", summary: "B", message: "combined", isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .fixup, commitId: "c", summary: "C", message: nil, isMergeCommit: false, canSquashOrFixup: true)
        ]

        XCTAssertTrue(applyRebaseTodoAction(&items, at: 0, action: .drop))
        XCTAssertEqual(items.map(\.action), [.drop, .drop, .drop])
        XCTAssertTrue(items.allSatisfy { $0.message == nil })
    }

    func testRebaseTodoEditHistorySupportsUndoRedoAndCoalescesMessageTyping() {
        let initial = [
            RebaseTodoItem(
                action: .pick,
                commitId: "a",
                summary: "first",
                message: nil,
                isMergeCommit: false,
                canSquashOrFixup: false
            ),
            RebaseTodoItem(
                action: .pick,
                commitId: "b",
                summary: "second",
                message: nil,
                isMergeCommit: false,
                canSquashOrFixup: true
            )
        ]
        var history = RebaseTodoEditHistory(initial: initial)
        var reworded = initial
        reworded[1].action = .reword
        reworded[1].message = "first edit"
        history.record(reworded, change: .structural)

        var reordered = reworded
        reordered.swapAt(0, 1)
        history.record(reordered, change: .structural)
        XCTAssertEqual(history.undo(), reworded)
        XCTAssertEqual(history.redo(), reordered)

        var typed = reordered
        typed[1].message = "c"
        history.record(typed, change: .message(commitID: "a"))
        typed[1].message = "combined"
        history.record(typed, change: .message(commitID: "a"))
        XCTAssertEqual(history.states.count, 4)
        XCTAssertEqual(history.undo(), reordered)
        XCTAssertTrue(history.canRedo)
    }

    func testRebaseTodoEditHistoryCapsStatesAndDropsRedoAfterBranching() {
        let initial = [
            RebaseTodoItem(
                action: .pick,
                commitId: "a",
                summary: "initial",
                message: nil,
                isMergeCommit: false,
                canSquashOrFixup: false
            )
        ]
        var history = RebaseTodoEditHistory(initial: initial)
        for number in 1...12 {
            var next = initial
            next[0].summary = "state \(number)"
            history.record(next, change: .structural)
        }

        XCTAssertEqual(history.states.count, RebaseTodoEditHistory.maximumStateCount)
        XCTAssertEqual(history.current.first?.summary, "state 12")
        _ = history.undo()
        var branch = history.current
        branch[0].summary = "branched"
        history.record(branch, change: .structural)
        XCTAssertFalse(history.canRedo)
    }

    func testRebaseTodoDiscardConfirmationTracksStructuredAndRawChanges() {
        let initial = [
            RebaseTodoItem(
                action: .pick,
                commitId: "a",
                summary: "initial",
                message: nil,
                isMergeCommit: false,
                canSquashOrFixup: false
            )
        ]

        XCTAssertFalse(
            rebaseTodoHasUnsavedChanges(current: initial, initial: initial)
        )
        var edited = initial
        edited[0].action = .reword
        XCTAssertTrue(
            rebaseTodoHasUnsavedChanges(current: edited, initial: initial)
        )
        XCTAssertTrue(
            rebaseTodoHasUnsavedChanges(
                current: initial,
                initial: initial,
                rawTodo: "pick a initial"
            )
        )
    }

    func testRebaseTodoUniteSquashMovesNonContiguousSelectionIntoOneGroup() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "A", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .pick, commitId: "b", summary: "B", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "c", summary: "C", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "d", summary: "D", message: nil, isMergeCommit: false, canSquashOrFixup: true)
        ]

        let united = uniteRebaseTodoItems(
            items,
            selectedIndices: [0, 2],
            action: .squash,
            preserveMerges: false
        )

        XCTAssertEqual(united?.map(\.commitId), ["a", "c", "b", "d"])
        XCTAssertEqual(united?.map(\.action), [.pick, .squash, .pick, .pick])
        XCTAssertEqual(united?[1].message, "A\n\nC")
    }

    func testRebaseTodoMovePreservesNonContiguousSelectionIdentity() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "A", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .pick, commitId: "b", summary: "B", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "c", summary: "C", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "d", summary: "D", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "e", summary: "E", message: nil, isMergeCommit: false, canSquashOrFixup: true)
        ]

        let movedUp = moveRebaseTodoItems(
            items,
            selectedIndices: [1, 3],
            requestedIndex: 1,
            by: -1
        )
        XCTAssertEqual(movedUp.map(\.commitId), ["b", "a", "d", "c", "e"])

        let movedDown = moveRebaseTodoItems(
            items,
            selectedIndices: [1, 3],
            requestedIndex: 3,
            by: 1
        )
        XCTAssertEqual(movedDown.map(\.commitId), ["a", "c", "b", "e", "d"])
    }

    func testRebaseTodoDragMovePreservesSourceOrderAndDestinationSemantics() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "A", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .pick, commitId: "b", summary: "B", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "c", summary: "C", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "d", summary: "D", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "e", summary: "E", message: nil, isMergeCommit: false, canSquashOrFixup: true)
        ]

        let moved = moveRebaseTodoRows(items, from: IndexSet([1, 3]), to: 5)
        XCTAssertEqual(moved.map(\.commitId), ["a", "c", "e", "b", "d"])

        let movedUp = moveRebaseTodoRows(items, from: IndexSet([1, 3]), to: 1)
        XCTAssertEqual(movedUp.map(\.commitId), ["a", "b", "d", "c", "e"])
    }

    func testRebaseTodoMoveDetachesChildWhenLeavingGroup() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "A", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .squash, commitId: "b", summary: "B", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .fixup, commitId: "c", summary: "C", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "d", summary: "D", message: nil, isMergeCommit: false, canSquashOrFixup: true)
        ]

        let movedUp = moveRebaseTodoItems(
            items,
            selectedIndices: [1],
            requestedIndex: 1,
            by: -1
        )
        XCTAssertEqual(movedUp.map(\.commitId), ["b", "a", "c", "d"])
        XCTAssertEqual(movedUp.map(\.action), [.pick, .pick, .fixup, .pick])

        let movedDown = moveRebaseTodoItems(
            items,
            selectedIndices: [2],
            requestedIndex: 2,
            by: 1
        )
        XCTAssertEqual(movedDown.map(\.commitId), ["a", "b", "d", "c"])
        XCTAssertEqual(movedDown.map(\.action), [.pick, .squash, .pick, .pick])
    }

    func testRebaseTodoMoveKeepsSquashGroupTogether() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "A", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .squash, commitId: "b", summary: "B", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "c", summary: "C", message: nil, isMergeCommit: false, canSquashOrFixup: true)
        ]

        let moved = moveRebaseTodoItems(
            items,
            selectedIndices: [0],
            requestedIndex: 0,
            by: 1
        )
        XCTAssertEqual(moved.map(\.commitId), ["c", "a", "b"])
        XCTAssertEqual(moved.map(\.action), [.pick, .pick, .squash])
    }

    func testRebaseTodoMoveJoinsExistingGroupAtBoundary() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "A", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .pick, commitId: "b", summary: "B", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .squash, commitId: "c", summary: "C", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "d", summary: "D", message: nil, isMergeCommit: false, canSquashOrFixup: true)
        ]

        let moved = moveRebaseTodoItems(
            items,
            selectedIndices: [0],
            requestedIndex: 0,
            by: 1
        )
        XCTAssertEqual(moved.map(\.commitId), ["b", "a", "c", "d"])
        XCTAssertEqual(moved.map(\.action), [.pick, .fixup, .squash, .pick])
    }

    func testRebaseTodoDragMovesWholeSquashGroup() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "A", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .squash, commitId: "b", summary: "B", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "c", summary: "C", message: nil, isMergeCommit: false, canSquashOrFixup: true)
        ]

        let moved = moveRebaseTodoRows(items, from: IndexSet([0]), to: 3)
        XCTAssertEqual(moved.map(\.commitId), ["c", "a", "b"])
        XCTAssertEqual(moved.map(\.action), [.pick, .pick, .squash])
    }

    func testNativeRebaseTodoPreviewParsesCommitAndControlRowsWithoutRejectingUnknownSyntax() {
        let rows = parseNativeRebaseTodoPreview(
            """
            pick abc123 First commit
            label branch-point
            reset onto
            merge -C deadbeef branch-point
            exec make test
            break
            update-ref refs/heads/topic
            # Git-generated comment
            future-command newer-git-syntax
            """
        )

        XCTAssertEqual(rows.count, 9)
        if case let .commit(command, commitID, subject) = rows[0].kind {
            XCTAssertEqual(command, "pick")
            XCTAssertEqual(commitID, "abc123")
            XCTAssertEqual(subject, "First commit")
        } else {
            XCTFail("expected a commit row")
        }
        if case let .control(command, arguments) = rows[1].kind {
            XCTAssertEqual(command, "label")
            XCTAssertEqual(arguments, "branch-point")
        } else {
            XCTFail("expected a label control row")
        }
        if case let .control(command, arguments) = rows[4].kind {
            XCTAssertEqual(command, "exec")
            XCTAssertEqual(arguments, "make test")
        } else {
            XCTFail("expected an exec control row")
        }
        XCTAssertEqual(rows[7].kind, .comment)
        XCTAssertEqual(rows[8].kind, .invalid)
    }

    func testNativeRebaseTodoControlEditingChangesOnlyTheTargetLine() {
        let original = "pick abc First\n  label old-point\n# keep this comment\nexec make test\n"
        let updated = updateNativeRebaseTodoControlLine(
            original,
            lineNumber: 2,
            command: "label",
            arguments: "new-point"
        )

        XCTAssertEqual(
            updated,
            "pick abc First\n  label new-point\n# keep this comment\nexec make test\n"
        )
        XCTAssertEqual(nativeRebaseTodoControlArguments(updated, lineNumber: 2), "new-point")
        XCTAssertNil(nativeRebaseTodoControlArguments(updated, lineNumber: 1))

        let crlf = "label old\r\n# keep CRLF\r\n"
        XCTAssertEqual(
            updateNativeRebaseTodoControlLine(
                crlf,
                lineNumber: 1,
                command: "label",
                arguments: "new"
            ),
            "label new\r\n# keep CRLF\r\n"
        )
        XCTAssertEqual(
            updateNativeRebaseTodoControlLine(
                crlf,
                lineNumber: 4,
                command: "label",
                arguments: "ignored"
            ),
            crlf
        )
    }

    func testNativeRebaseTodoControlRowsSupportTypeConversionAndStableReordering() {
        let original = "pick abc First\r\n# keep this comment\r\nlabel old\r\nexec make test\r\n"
        let converted = updateNativeRebaseTodoControlLine(
            original,
            lineNumber: 3,
            command: "break",
            arguments: "ignored"
        )

        XCTAssertEqual(
            converted,
            "pick abc First\r\n# keep this comment\r\nbreak\r\nexec make test\r\n"
        )
        XCTAssertEqual(nativeRebaseTodoControlCommand(converted, lineNumber: 3), "break")
        XCTAssertEqual(nativeRebaseTodoControlArguments(converted, lineNumber: 3), "")

        let movedUp = moveNativeRebaseTodoControlLine(
            converted,
            lineNumber: 4,
            by: -1
        )
        XCTAssertEqual(
            movedUp,
            "pick abc First\r\n# keep this comment\r\nexec make test\r\nbreak\r\n"
        )
        XCTAssertEqual(nativeRebaseTodoControlCommand(movedUp, lineNumber: 3), "exec")
        XCTAssertEqual(nativeRebaseTodoControlCommand(movedUp, lineNumber: 4), "break")
        XCTAssertEqual(
            moveNativeRebaseTodoControlLine(movedUp, lineNumber: 1, by: 1),
            movedUp
        )
        XCTAssertEqual(
            moveNativeRebaseTodoControlLine(movedUp, lineNumber: 2, by: 1),
            movedUp
        )

        let unknownSyntax = "label point\r\nfuture-command newer-git-syntax\r\n"
        XCTAssertEqual(
            moveNativeRebaseTodoControlLine(unknownSyntax, lineNumber: 1, by: 1),
            "future-command newer-git-syntax\r\nlabel point\r\n"
        )
    }

    func testRebaseTodoCommandsHelpUsesGitCommandNames() {
        XCTAssertEqual(
            [
                RebaseTodoAction.pick,
                .reword,
                .edit,
                .squash,
                .fixup,
                .drop
            ].map(rebaseTodoActionCommand),
            ["pick", "reword", "edit", "squash", "fixup", "drop"]
        )
    }

    func testRebaseTodoContextSelectionKeepsMultiSelectionOnlyWhenInvokedInsideIt() {
        XCTAssertEqual(
            rebaseTodoContextSelection(selectedIndices: [1, 3], row: 3),
            [1, 3]
        )
        XCTAssertEqual(
            rebaseTodoContextSelection(selectedIndices: [1, 3], row: 2),
            [2]
        )
        XCTAssertEqual(
            rebaseTodoContextSelection(selectedIndices: [], row: 0),
            [0]
        )
    }

    func testRebaseStartNeedsNoopConfirmationOnlyForInteractiveEmptyRange() {
        XCTAssertTrue(rebaseStartNeedsNoopConfirmation(interactive: true, rangeCount: 0))
        XCTAssertFalse(rebaseStartNeedsNoopConfirmation(interactive: true, rangeCount: 2))
        XCTAssertFalse(rebaseStartNeedsNoopConfirmation(interactive: false, rangeCount: 0))
    }

    func testRebaseHelpLinksToGitDocumentation() {
        XCTAssertEqual(
            rebaseHelpDocumentationURL.absoluteString,
            "https://git-scm.com/docs/git-rebase"
        )
    }

    func testMultiRootRebaseNoopRootsIgnoreFailedDrafts() {
        let drafts = [
            MultiRootRebaseTodoDraft(
                rootPath: "/workspace/noop",
                displayName: "noop",
                items: [],
                rawTodo: nil,
                loadError: nil
            ),
            MultiRootRebaseTodoDraft(
                rootPath: "/workspace/active",
                displayName: "active",
                items: [
                    RebaseTodoItem(
                        action: .pick,
                        commitId: "commit",
                        summary: "commit",
                        message: nil,
                        isMergeCommit: false,
                        canSquashOrFixup: false
                    )
                ],
                rawTodo: nil,
                loadError: nil
            ),
            MultiRootRebaseTodoDraft(
                rootPath: "/workspace/failed",
                displayName: "failed",
                items: [],
                rawTodo: nil,
                loadError: "range failed"
            )
        ]

        XCTAssertEqual(
            multiRootRebaseNoopRootPaths(drafts),
            ["/workspace/noop"]
        )
    }

    func testMultiRootRebaseDetailsStayInRootTodoOrderAndUseFocusedCommitWhenUnselected() {
        let draft = MultiRootRebaseTodoDraft(
            rootPath: "/workspace/root-b",
            displayName: "root-b",
            items: [
                RebaseTodoItem(action: .pick, commitId: "b1", summary: "B1", message: nil, isMergeCommit: false, canSquashOrFixup: false),
                RebaseTodoItem(action: .pick, commitId: "b2", summary: "B2", message: nil, isMergeCommit: false, canSquashOrFixup: true),
                RebaseTodoItem(action: .pick, commitId: "b3", summary: "B3", message: nil, isMergeCommit: false, canSquashOrFixup: true)
            ],
            rawTodo: nil,
            loadError: nil
        )

        XCTAssertEqual(
            multiRootRebaseDetailCommitIDs(
                draft: draft,
                selectedIDs: ["b3", "b1"],
                focusedID: "b3"
            ),
            ["b1", "b3"]
        )
        XCTAssertEqual(
            multiRootRebaseDetailCommitIDs(
                draft: draft,
                selectedIDs: [],
                focusedID: "b2"
            ),
            ["b2"]
        )
    }

    func testMultiRootRebaseSessionDecodesLegacyRootWithoutStructuredOrder() throws {
        let legacy = Data(#"""
        {
            "rootPath":"/workspace/root",
            "displayName":"root",
            "branch":"main",
            "onto":"base",
            "actions":[],
            "rawTodo":null,
            "preserveMerges":true,
            "autoSquash":false,
            "keepEmpty":false,
            "updateRefs":false,
            "root":false,
            "savePolicyRaw":null,
            "protectionCommitID":null,
            "state":"pending",
            "initialHead":null,
            "expectedHead":null,
            "initialBranch":null,
            "message":""
        }
        """#.utf8)

        let root = try JSONDecoder().decode(MultiRootRebaseSessionRoot.self, from: legacy)
        XCTAssertNil(root.orderedCommitIds)
        XCTAssertEqual(root.makeSpec().orderedCommitIds, [])
    }

    func testRebaseTodoUniteFixupUsesThePreviousKeptRootForSingleSelection() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "A", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .pick, commitId: "b", summary: "B", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "c", summary: "C", message: nil, isMergeCommit: false, canSquashOrFixup: true)
        ]

        let united = uniteRebaseTodoItems(
            items,
            selectedIndices: [2],
            action: .fixup,
            preserveMerges: false
        )

        XCTAssertEqual(united?.map(\.commitId), ["a", "b", "c"])
        XCTAssertEqual(united?.map(\.action), [.pick, .pick, .fixup])
        XCTAssertNil(united?[2].message)
    }

    func testRebaseTodoUnitePreservesExistingGroupMessageWhenAddingFixup() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "A", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .squash, commitId: "b", summary: "B", message: "A\n\nB", isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "c", summary: "C", message: nil, isMergeCommit: false, canSquashOrFixup: true)
        ]

        let united = uniteRebaseTodoItems(
            items,
            selectedIndices: [2],
            action: .fixup,
            preserveMerges: false
        )

        XCTAssertEqual(united?.map(\.action), [.pick, .squash, .fixup])
        XCTAssertEqual(united?[1].message, "A\n\nB")
    }

    func testRebaseTodoUniteRejectsSelectionAlreadyInsideOneGroup() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "A", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .fixup, commitId: "b", summary: "B", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .fixup, commitId: "c", summary: "C", message: nil, isMergeCommit: false, canSquashOrFixup: true)
        ]

        XCTAssertNil(
            uniteRebaseTodoItems(
                items,
                selectedIndices: [1, 2],
                action: .squash,
                preserveMerges: false
            )
        )
    }

    func testRebaseTodoUniteNormalizesSelectedDropIntoKeptGroup() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "a", summary: "A", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .drop, commitId: "b", summary: "B", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "c", summary: "C", message: nil, isMergeCommit: false, canSquashOrFixup: true)
        ]

        let united = uniteRebaseTodoItems(
            items,
            selectedIndices: [1],
            action: .fixup,
            preserveMerges: false
        )

        XCTAssertEqual(united?.map(\.action), [.pick, .fixup, .pick])
    }

    func testRebaseTodoUniteRejectsMergePreservingStructuredSelection() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "merge", summary: "merge", message: nil, isMergeCommit: true, canSquashOrFixup: false),
            RebaseTodoItem(action: .pick, commitId: "child", summary: "child", message: nil, isMergeCommit: false, canSquashOrFixup: false)
        ]

        XCTAssertNil(
            uniteRebaseTodoItems(
                items,
                selectedIndices: [0, 1],
                action: .squash,
                preserveMerges: true
            )
        )
    }

    func testRebaseTodoUniteAllowsOnlyContiguousPreserveMergeBranchSegments() {
        let items = [
            RebaseTodoItem(action: .pick, commitId: "root", summary: "root", message: nil, isMergeCommit: false, canSquashOrFixup: false),
            RebaseTodoItem(action: .pick, commitId: "feature-1", summary: "feature 1", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "feature-2", summary: "feature 2", message: nil, isMergeCommit: false, canSquashOrFixup: true),
            RebaseTodoItem(action: .pick, commitId: "merge", summary: "merge", message: nil, isMergeCommit: true, canSquashOrFixup: false),
            RebaseTodoItem(action: .pick, commitId: "post-merge", summary: "post merge", message: nil, isMergeCommit: false, canSquashOrFixup: false)
        ]

        let united = uniteRebaseTodoItems(
            items,
            selectedIndices: [1, 2],
            action: .squash,
            preserveMerges: true
        )
        XCTAssertEqual(united?.map(\.action), [.pick, .pick, .squash, .pick, .pick])

        XCTAssertNil(
            uniteRebaseTodoItems(
                items,
                selectedIndices: [0, 2],
                action: .fixup,
                preserveMerges: true
            )
        )
    }

    func testRootRebaseAllowsAnEmptyOntoButNonRootRequiresOne() {
        XCTAssertTrue(
            rebaseInputsCanLoadRange(onto: "", branch: "main", root: true)
        )
        XCTAssertTrue(
            rebaseInputsCanLoadRange(onto: "origin/main", branch: "main", root: true)
        )
        XCTAssertFalse(
            rebaseInputsCanLoadRange(onto: "", branch: "main", root: false)
        )
        XCTAssertFalse(
            rebaseInputsCanLoadRange(onto: "origin/main", branch: "", root: true)
        )
    }

    func testMergeDialogRejectsAlreadyMergedLocalBranchesButAllowsRevisions() {
        let merged = Set(["feature/done"])
        XCTAssertTrue(mergeBranchIsAlreadyMerged("feature/done", mergedBranches: merged))
        XCTAssertTrue(mergeBranchIsAlreadyMerged("refs/heads/feature/done", mergedBranches: merged))
        XCTAssertTrue(mergeBranchIsAlreadyMerged("refs/remotes/origin/feature/done", mergedBranches: ["origin/feature/done"]))
        XCTAssertFalse(mergeBranchIsAlreadyMerged("feature/in-progress", mergedBranches: merged))
        XCTAssertFalse(mergeBranchIsAlreadyMerged("a1b2c3d", mergedBranches: merged))
    }

    func testMultiRootMergeChecksMergedBranchesPerRepository() {
        let mergedByRoot = [
            "/workspace/app": Set(["feature/done"]),
            "/workspace/tools": Set(["release/old"])
        ]

        XCTAssertTrue(
            mergeBranchIsAlreadyMerged(
                "feature/done",
                mergedBranches: mergedByRoot["/workspace/app"]!
            )
        )
        XCTAssertFalse(
            mergeBranchIsAlreadyMerged(
                "feature/done",
                mergedBranches: mergedByRoot["/workspace/tools"]!
            )
        )
    }

    func testTrackedRemoteDeletionRequiresTheSoleLiveTrackerAndAnUnprotectedRemote() {
        let soleTracker = [
            SyncStatus(
                branch: "feature",
                upstream: "origin/feature",
                ahead: 0,
                behind: 0,
                trackingExists: true
            )
        ]
        XCTAssertEqual(
            deletableTrackedRemoteBranch(
                branchName: "feature",
                upstream: "origin/feature",
                syncStatuses: soleTracker,
                protectedPatterns: []
            ),
            "origin/feature"
        )
        XCTAssertNil(
            deletableTrackedRemoteBranch(
                branchName: "feature",
                upstream: "feature",
                syncStatuses: soleTracker,
                protectedPatterns: []
            )
        )
        XCTAssertNil(
            deletableTrackedRemoteBranch(
                branchName: "feature",
                upstream: "origin/feature",
                syncStatuses: [
                    soleTracker[0],
                    SyncStatus(
                        branch: "feature-copy",
                        upstream: "origin/feature",
                        ahead: 0,
                        behind: 0,
                        trackingExists: true
                    )
                ],
                protectedPatterns: []
            )
        )
        XCTAssertNil(
            deletableTrackedRemoteBranch(
                branchName: "feature",
                upstream: "origin/main",
                syncStatuses: [
                    SyncStatus(
                        branch: "feature",
                        upstream: "origin/main",
                        ahead: 0,
                        behind: 0,
                        trackingExists: true
                    )
                ],
                protectedPatterns: ["main"]
            )
        )
        XCTAssertEqual(
            deletableTrackedRemoteBranches(
                branchName: "feature",
                syncStatusesByRoot: [
                    soleTracker,
                    [
                        SyncStatus(
                            branch: "feature",
                            upstream: "origin/feature",
                            ahead: 0,
                            behind: 0,
                            trackingExists: true
                        ),
                        SyncStatus(
                            branch: "feature-copy",
                            upstream: "origin/feature",
                            ahead: 0,
                            behind: 0,
                            trackingExists: true
                        )
                    ]
                ],
                protectedPatterns: []
            ),
            []
        )
    }

    func testCheckoutAndUpdateRevalidatesTrackingBeforeSwitching() {
        XCTAssertEqual(
            checkoutAndUpdateUpstream(
                branch: "feature",
                syncStatuses: [
                    SyncStatus(
                        branch: "feature",
                        upstream: "origin/feature",
                        ahead: 0,
                        behind: 1,
                        trackingExists: true
                    )
                ]
            ),
            "origin/feature"
        )
        XCTAssertNil(
            checkoutAndUpdateUpstream(
                branch: "feature",
                syncStatuses: [
                    SyncStatus(
                        branch: "feature",
                        upstream: "origin/feature",
                        ahead: 0,
                        behind: 1,
                        trackingExists: false
                    )
                ]
            )
        )
        XCTAssertNil(
            checkoutAndUpdateUpstream(
                branch: "feature",
                syncStatuses: [
                    SyncStatus(
                        branch: "feature",
                        upstream: "origin/",
                        ahead: 0,
                        behind: 0,
                        trackingExists: true
                    )
                ]
            )
        )
    }

    private let changes = [
        TreeChange(path: "Sources/App.swift", oldPath: nil, isPureMove: false, kind: .modified, oldMode: 0o100644, newMode: 0o100644),
        TreeChange(path: "README.md", oldPath: nil, isPureMove: false, kind: .added, oldMode: 0, newMode: 0o100644),
        TreeChange(path: "Tests/AppTests.swift", oldPath: nil, isPureMove: false, kind: .deleted, oldMode: 0o100644, newMode: 0)
    ]

    private func shelf(
        _ name: String,
        id: String,
        paths: [String],
        deleted: Bool = false
    ) -> ShelveInfo {
        ShelveInfo(
            name: name,
            id: id,
            shortId: String(name.prefix(7)),
            paths: paths,
            description: name,
            timestamp: 0,
            isDeleted: deleted,
            isRecycled: false,
            isPendingDelete: false
        )
    }

    private func logCommit(
        id: String = "commit",
        repositoryPath: String = "/workspace/repo",
        parentIds: [String] = ["parent"]
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
            parentIds: parentIds,
            refs: [],
            tagRefs: [],
            remoteRefs: [],
            isHead: false,
            lane: 0,
            parentLanes: []
        )
    }

    func testBatchRewriteFindsOldestSelectedCommitForReverseNonContiguousSelection() {
        let oldest = logCommit(id: "oldest", parentIds: ["root"])
        let newest = logCommit(id: "newest", parentIds: ["skipped"])
        let selected = [newest, oldest]
        let ancestry: Set<String> = [
            "oldest->newest",
            "oldest->oldest",
            "newest->newest"
        ]

        let result = oldestSelectedLinearCommit(selected) { ancestor, descendant in
            ancestry.contains("\(ancestor)->\(descendant)")
        }

        XCTAssertEqual(result?.id, "oldest")
    }

    func testBatchRewriteFindsInitialCommitAsRootOfSelectedRange() {
        let root = logCommit(id: "root", parentIds: [])
        let child = logCommit(id: "child", parentIds: ["root"])
        let result = oldestSelectedLinearCommit([child, root]) { ancestor, descendant in
            ancestor == "root" && descendant == "child"
        }

        XCTAssertEqual(result?.id, "root")
    }

    func testLogReferenceActionTargetsMirrorSingleCommitRefGroup() {
        let commit = CommitInfo(
            id: "refs",
            repositoryPath: "/workspace/repo",
            shortId: "refs",
            summary: "refs",
            authorName: "A",
            authorEmail: "a@example.com",
            committerName: "A",
            committerEmail: "a@example.com",
            messageBody: "",
            hasSignature: false,
            time: 0,
            parentIds: [],
            refs: ["main", "feature/z", "feature/a", "main"],
            tagRefs: ["v2", "v1", "v2"],
            remoteRefs: ["origin/main", "upstream/main", "origin/main"],
            isHead: true,
            lane: 0,
            parentLanes: []
        )

        XCTAssertTrue(
            isLogSingleCommitActionAvailable(selectionCount: 1, for: commit)
        )
        XCTAssertFalse(
            isLogSingleCommitActionAvailable(selectionCount: 2, for: commit)
        )

        var unresolvedRootCommit = commit
        unresolvedRootCommit.repositoryPath = nil
        XCTAssertFalse(
            isLogSingleCommitActionAvailable(selectionCount: 1, for: unresolvedRootCommit)
        )

        XCTAssertEqual(
            logReferenceActionTargets(for: commit, currentBranchName: "main"),
            [
                LogReferenceActionTarget(kind: .local, name: "feature/a"),
                LogReferenceActionTarget(kind: .local, name: "feature/z"),
                LogReferenceActionTarget(kind: .remote, name: "origin/main"),
                LogReferenceActionTarget(kind: .remote, name: "upstream/main"),
                LogReferenceActionTarget(kind: .tag, name: "v1"),
                LogReferenceActionTarget(kind: .tag, name: "v2")
            ]
        )

        XCTAssertTrue(
            logReferenceActionTargets(for: commit, currentBranchName: nil)
                .contains(LogReferenceActionTarget(kind: .local, name: "main"))
        )
        XCTAssertEqual(
            logReferenceRootPath(for: commit),
            "/workspace/repo"
        )
        XCTAssertNil(
            logReferenceRootPath(for: logCommit(repositoryPath: ""))
        )
    }

    func testFileHistoryCommitActionsRespectRewriteAndTagBoundaries() {
        let commit = logCommit()

        XCTAssertTrue(isLogRewriteActionAvailable(for: commit, action: .fixup))
        XCTAssertTrue(isLogRewriteActionAvailable(for: commit, action: .squash))
        XCTAssertTrue(isLogSingleCommitActionAvailable(selectionCount: 1, for: commit))
        XCTAssertFalse(isLogSingleCommitActionAvailable(selectionCount: 2, for: commit))

        let merge = logCommit(id: "merge", parentIds: ["left", "right"])
        XCTAssertFalse(isLogRewriteActionAvailable(for: merge, action: .fixup))
        XCTAssertFalse(isLogRewriteActionAvailable(for: merge, action: .squash))

        let root = logCommit(id: "root", parentIds: [])
        XCTAssertFalse(isLogRewriteActionAvailable(for: root, action: .fixup))
        XCTAssertFalse(isLogRewriteActionAvailable(for: root, action: .squash))

        let busyRoot = LogActionAvailability(
            hasLocalChanges: true,
            activeOperationRootPath: "/workspace/repo"
        )
        XCTAssertFalse(busyRoot.allowsHistoryRewrite(for: [commit]))
    }

    func testLogCheckoutGroupKeepsOnlyNonCurrentLocalBranches() {
        let commit = CommitInfo(
            id: "checkout-group",
            repositoryPath: "/workspace/repo",
            shortId: "checkout",
            summary: "checkout",
            authorName: "A",
            authorEmail: "a@example.com",
            committerName: "A",
            committerEmail: "a@example.com",
            messageBody: "",
            hasSignature: false,
            time: 0,
            parentIds: ["parent"],
            refs: ["main", "feature/z", "feature/a", "main"],
            tagRefs: ["v1"],
            remoteRefs: ["origin/main"],
            isHead: true,
            lane: 0,
            parentLanes: []
        )

        XCTAssertEqual(
            logCheckoutBranchTargets(for: commit, currentBranchName: "main"),
            [
                LogReferenceActionTarget(kind: .local, name: "feature/a"),
                LogReferenceActionTarget(kind: .local, name: "feature/z")
            ]
        )
        XCTAssertEqual(
            logCheckoutBranchTargets(for: commit, currentBranchName: nil),
            [
                LogReferenceActionTarget(kind: .local, name: "feature/a"),
                LogReferenceActionTarget(kind: .local, name: "feature/z"),
                LogReferenceActionTarget(kind: .local, name: "main")
            ]
        )
    }

    func testLogNavigationPrefersExactBranchHeadOverFirstVisibleCommit() {
        let visibleParent = logCommit(id: "parent-commit")
        let branchHead = logCommit(id: "branch-head", parentIds: [visibleParent.id])

        XCTAssertEqual(
            matchingLogCommitID(requestedID: branchHead.id, in: [visibleParent, branchHead]),
            branchHead.id
        )
        XCTAssertEqual(
            matchingLogCommitID(requestedID: "branch", in: [branchHead]),
            branchHead.id
        )
        XCTAssertNil(matchingLogCommitID(requestedID: "missing", in: [visibleParent, branchHead]))
        XCTAssertNil(matchingLogCommitID(requestedID: "   ", in: [visibleParent, branchHead]))
    }

    func testLogCommandMergeKeepsEqualObjectIDsRootQualified() {
        var firstRoot = logCommit(id: "same", repositoryPath: "/workspace/one")
        firstRoot.time = 10
        firstRoot.lane = 4
        firstRoot.parentLanes = [4]
        var secondRoot = logCommit(id: "same", repositoryPath: "/workspace/two")
        secondRoot.time = 20
        secondRoot.lane = 7
        secondRoot.parentLanes = [7]

        let aggregate = mergedLogCommandEntries(
            [[firstRoot, firstRoot], [secondRoot]],
            limit: 10,
            aggregate: true
        )
        XCTAssertEqual(aggregate.map(\.repositoryPath), ["/workspace/two", "/workspace/one"])
        XCTAssertEqual(aggregate.map(\.id), ["same", "same"])
        XCTAssertEqual(aggregate.map(\.lane), [0, 0])
        XCTAssertEqual(aggregate.map(\.parentLanes), [[], []])

        let singleRoot = mergedLogCommandEntries(
            [[firstRoot, firstRoot]],
            limit: 10,
            aggregate: false
        )
        XCTAssertEqual(singleRoot.map(\.id), ["same"])
        XCTAssertEqual(singleRoot.first?.lane, 4)
    }

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

    func testShelfActionRootGuardFailsClosedForInactiveRoots() {
        XCTAssertTrue(
            shelfActionRootMatchesCurrentRoot(
                requestedRootPath: nil,
                currentRootPath: nil
            )
        )
        XCTAssertTrue(
            shelfActionRootMatchesCurrentRoot(
                requestedRootPath: "/workspace/repo/.",
                currentRootPath: "/workspace/repo"
            )
        )
        XCTAssertFalse(
            shelfActionRootMatchesCurrentRoot(
                requestedRootPath: "/workspace/other",
                currentRootPath: "/workspace/repo"
            )
        )
        XCTAssertFalse(
            shelfActionRootMatchesCurrentRoot(
                requestedRootPath: "/workspace/repo",
                currentRootPath: nil
            )
        )
    }

    func testShelfRootSelectionKeepsPrimaryAndSecondaryBoundaries() {
        XCTAssertTrue(
            shelfRootSelectionIsPrimary(
                selectedRootPath: nil,
                primaryRootPath: "/workspace/repo"
            )
        )
        XCTAssertTrue(
            shelfRootSelectionIsPrimary(
                selectedRootPath: "/workspace/repo/.",
                primaryRootPath: "/workspace/repo"
            )
        )
        XCTAssertFalse(
            shelfRootSelectionIsPrimary(
                selectedRootPath: "/workspace/other",
                primaryRootPath: "/workspace/repo"
            )
        )
        XCTAssertFalse(
            shelfRootSelectionIsPrimary(
                selectedRootPath: "/workspace/other",
                primaryRootPath: nil
            )
        )
    }

    func testShelfRootSnapshotCarriesItsOwnChangeLists() {
        let lists = [
            ChangeListInfo(
                name: "Secondary Work",
                paths: ["Sources/Secondary.swift"],
                isDefault: false,
                isActive: true
            )
        ]
        let snapshot = ShelfRootSnapshot(
            rootPath: "/workspace/secondary",
            shelves: [],
            deletedShelves: [],
            changeLists: lists
        )

        XCTAssertEqual(snapshot.rootPath, "/workspace/secondary")
        XCTAssertEqual(snapshot.changeLists.map(\.name), ["Secondary Work"])
        XCTAssertEqual(snapshot.changeLists.first?.paths, ["Sources/Secondary.swift"])
    }

    func testSecondaryShelfSnapshotRefreshRequiresItsOwnGitMetadataEvent() {
        XCTAssertTrue(
            shouldRefreshSecondaryShelfSnapshot(
                eventRootPath: "/workspace/secondary/.",
                activeRootPath: "/workspace/secondary",
                primaryRootPath: "/workspace/repo",
                scopes: .gitMetadata
            )
        )
        XCTAssertFalse(
            shouldRefreshSecondaryShelfSnapshot(
                eventRootPath: "/workspace/secondary",
                activeRootPath: "/workspace/secondary",
                primaryRootPath: "/workspace/repo",
                scopes: .worktree
            )
        )
        XCTAssertFalse(
            shouldRefreshSecondaryShelfSnapshot(
                eventRootPath: "/workspace/repo",
                activeRootPath: "/workspace/secondary",
                primaryRootPath: "/workspace/repo",
                scopes: .gitMetadata
            )
        )
        XCTAssertFalse(
            shouldRefreshSecondaryShelfSnapshot(
                eventRootPath: "/workspace/repo",
                activeRootPath: nil,
                primaryRootPath: "/workspace/repo",
                scopes: .gitMetadata
            )
        )
    }

    func testShelfNotificationIDsRemainRootScoped() {
        let primary = shelfNotificationID(
            prefix: "shelf-lifecycle.restoreDeleted",
            rootPath: "/workspace/repo"
        )
        let secondary = shelfNotificationID(
            prefix: "shelf-lifecycle.restoreDeleted",
            rootPath: "/workspace/other"
        )

        XCTAssertNotEqual(primary, secondary)
        XCTAssertEqual(
            primary,
            "arbor.shelf-lifecycle.restoreDeleted._workspace_repo"
        )
        XCTAssertEqual(
            secondary,
            "arbor.shelf-lifecycle.restoreDeleted._workspace_other"
        )
    }

    func testShelfFeedbackTitlesMatchApplyAndPopActions() {
        XCTAssertEqual(shelfFeedbackTitle(.apply), "Apply Shelf")
        XCTAssertEqual(
            shelfFeedbackTitle(.apply, removeApplied: true),
            "Unshelve and Remove Shelf"
        )
        XCTAssertEqual(shelfFeedbackTitle(.pop), "Pop Shelf")
        XCTAssertEqual(shelfFeedbackTitle(.drop), "Drop Shelf")
    }

    func testShelfMetadataNotificationIDsRemainDistinctPerOperationAndRoot() {
        let operations = ["import", "export", "clean"]
        let ids = operations.map {
            shelfNotificationID(
                prefix: "shelf-metadata.\($0)",
                rootPath: "/workspace/secondary"
            )
        }

        XCTAssertEqual(Set(ids).count, operations.count)
        XCTAssertTrue(ids.allSatisfy { $0.contains("_workspace_secondary") })
    }

    func testShelfViewSettingsAreProjectScoped() {
        let suiteName = "Arbor.ShelfViewSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstProject = "/workspace/one"
        let secondProject = "/workspace/two"

        XCTAssertFalse(ShelfViewSettings.showRecycled(for: firstProject, defaults: defaults))
        XCTAssertFalse(ShelfViewSettings.showRecycled(for: secondProject, defaults: defaults))

        ShelfViewSettings.saveShowRecycled(true, for: firstProject, defaults: defaults)

        XCTAssertTrue(ShelfViewSettings.showRecycled(for: firstProject, defaults: defaults))
        XCTAssertFalse(ShelfViewSettings.showRecycled(for: secondProject, defaults: defaults))

        ShelfViewSettings.saveShowRecycled(false, for: firstProject, defaults: defaults)
        XCTAssertFalse(ShelfViewSettings.showRecycled(for: firstProject, defaults: defaults))
    }

    func testShelfTreeSettingsAreProjectScoped() {
        let suiteName = "Arbor.ShelfTreeSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstProject = "/workspace/one"
        let secondProject = "/workspace/two"

        XCTAssertTrue(ShelfViewSettings.shelvesExpanded(for: firstProject, defaults: defaults))
        XCTAssertTrue(ShelfViewSettings.groupByDirectory(for: firstProject, defaults: defaults))
        XCTAssertTrue(ShelfViewSettings.deletedShelvesExpanded(for: firstProject, defaults: defaults))

        ShelfViewSettings.saveShelvesExpanded(false, for: firstProject, defaults: defaults)
        ShelfViewSettings.saveGroupByDirectory(false, for: firstProject, defaults: defaults)
        ShelfViewSettings.saveDeletedShelvesExpanded(false, for: firstProject, defaults: defaults)

        XCTAssertFalse(ShelfViewSettings.shelvesExpanded(for: firstProject, defaults: defaults))
        XCTAssertFalse(ShelfViewSettings.groupByDirectory(for: firstProject, defaults: defaults))
        XCTAssertFalse(ShelfViewSettings.deletedShelvesExpanded(for: firstProject, defaults: defaults))
        XCTAssertTrue(ShelfViewSettings.shelvesExpanded(for: secondProject, defaults: defaults))
        XCTAssertTrue(ShelfViewSettings.groupByDirectory(for: secondProject, defaults: defaults))
        XCTAssertTrue(ShelfViewSettings.deletedShelvesExpanded(for: secondProject, defaults: defaults))
    }

    func testGitStageIgnoredFilesSettingIsProjectScoped() {
        let suiteName = "Arbor.GitStageViewSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstProject = "/workspace/one"
        let firstProjectAlias = "/workspace/one/../one"
        let secondProject = "/workspace/two"

        XCTAssertTrue(GitStageViewSettings.ignoredFilesShown(for: firstProject, defaults: defaults))
        XCTAssertTrue(GitStageViewSettings.ignoredFilesShown(for: secondProject, defaults: defaults))
        XCTAssertTrue(GitStageViewSettings.ignoredFilesShown(for: nil, defaults: defaults))

        GitStageViewSettings.saveIgnoredFilesShown(false, for: firstProject, defaults: defaults)

        XCTAssertFalse(GitStageViewSettings.ignoredFilesShown(for: firstProject, defaults: defaults))
        XCTAssertFalse(GitStageViewSettings.ignoredFilesShown(for: firstProjectAlias, defaults: defaults))
        XCTAssertTrue(GitStageViewSettings.ignoredFilesShown(for: secondProject, defaults: defaults))

        GitStageViewSettings.saveIgnoredFilesShown(true, for: firstProject, defaults: defaults)
        XCTAssertTrue(GitStageViewSettings.ignoredFilesShown(for: firstProject, defaults: defaults))
    }

    func testGitAnnotationSettingsMatchIntellijDefaultsAndPersistOptions() {
        let suiteName = "Arbor.GitAnnotationSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let intellijDefaults = GitAnnotationSettings.options(from: defaults)
        XCTAssertTrue(intellijDefaults.ignoreWhitespaces)
        XCTAssertEqual(intellijDefaults.movement, .none)
        XCTAssertFalse(intellijDefaults.preferCommitDate)

        defaults.set(false, forKey: GitAnnotationSettings.ignoreWhitespacesKey)
        defaults.set("outer", forKey: GitAnnotationSettings.movementKey)
        defaults.set(true, forKey: GitAnnotationSettings.preferCommitDateKey)

        let persisted = GitAnnotationSettings.options(from: defaults)
        XCTAssertFalse(persisted.ignoreWhitespaces)
        XCTAssertEqual(persisted.movement, .outer)
        XCTAssertTrue(persisted.preferCommitDate)
    }

    func testShelfRemoveAppliedSettingIsProjectScoped() {
        let suiteName = "Arbor.ShelfRemoveAppliedSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstProject = "/workspace/one"
        let secondProject = "/workspace/two"
        defaults.set(true, forKey: "arbor.commit.shelves.removeApplied.v1")

        XCTAssertFalse(
            ShelfViewSettings.removeAppliedFilesFromShelf(
                for: firstProject,
                defaults: defaults
            )
        )
        XCTAssertFalse(
            ShelfViewSettings.removeAppliedFilesFromShelf(
                for: secondProject,
                defaults: defaults
            )
        )

        ShelfViewSettings.saveRemoveAppliedFilesFromShelf(
            true,
            for: firstProject,
            defaults: defaults
        )

        XCTAssertTrue(
            ShelfViewSettings.removeAppliedFilesFromShelf(
                for: firstProject,
                defaults: defaults
            )
        )
        XCTAssertFalse(
            ShelfViewSettings.removeAppliedFilesFromShelf(
                for: secondProject,
                defaults: defaults
            )
        )

        ShelfViewSettings.saveRemoveAppliedFilesFromShelf(
            false,
            for: firstProject,
            defaults: defaults
        )
        XCTAssertFalse(
            ShelfViewSettings.removeAppliedFilesFromShelf(
                for: firstProject,
                defaults: defaults
            )
        )
    }

    func testSecondaryShelfRootActionAllowlistFailsClosedForWorktreeWrites() {
        XCTAssertTrue(isSecondaryShelfRootScopedAction(.restoreShelf))
        XCTAssertTrue(isSecondaryShelfRootScopedAction(.restoreShelfPaths))
        XCTAssertTrue(isSecondaryShelfRootScopedAction(.deleteDeletedShelfPaths))
        XCTAssertTrue(isSecondaryShelfRootScopedAction(.undoShelfDeletion))
        XCTAssertTrue(isSecondaryShelfRootScopedAction(.undoShelfDeletions))
        XCTAssertTrue(isSecondaryShelfRootScopedAction(.dropShelf))
        XCTAssertTrue(isSecondaryShelfRootScopedAction(.retryShelfBatch))
        XCTAssertTrue(isSecondaryShelfRootScopedAction(.retryShelfMemberBatch))
        XCTAssertTrue(isSecondaryShelfRootScopedAction(.retryShelfLifecycleBatch))
        XCTAssertTrue(isSecondaryShelfRootScopedAction(.retryPush))
        XCTAssertTrue(isSecondaryShelfRootScopedAction(.retryPushRecovery))
        XCTAssertTrue(isSecondaryShelfRootScopedAction(.retryStashBranch))
        XCTAssertTrue(isSecondaryShelfRootScopedAction(.retryLogApply))
        XCTAssertTrue(isSecondaryShelfRootScopedAction(.showLogApplyAffectedFiles))
    }

    func testShelfPreviewRootGuardRejectsStaleRootAndName() {
        XCTAssertTrue(
            shelfPreviewRequestMatches(
                requestedRootPath: "/workspace/repo/.",
                currentRootPath: "/workspace/repo",
                requestedName: "Work",
                currentName: "Work",
                requestedIsDeleted: false,
                currentIsDeleted: false
            )
        )
        XCTAssertFalse(
            shelfPreviewRequestMatches(
                requestedRootPath: "/workspace/other",
                currentRootPath: "/workspace/repo",
                requestedName: "Work",
                currentName: "Work",
                requestedIsDeleted: false,
                currentIsDeleted: false
            )
        )
        XCTAssertFalse(
            shelfPreviewRequestMatches(
                requestedRootPath: "/workspace/repo",
                currentRootPath: "/workspace/repo",
                requestedName: "Work",
                currentName: "Other",
                requestedIsDeleted: false,
                currentIsDeleted: false
            )
        )
        XCTAssertFalse(
            shelfPreviewRequestMatches(
                requestedRootPath: "/workspace/repo",
                currentRootPath: "/workspace/repo",
                requestedName: "Work",
                currentName: "Work",
                requestedIsDeleted: true,
                currentIsDeleted: false
            )
        )
    }

    func testShelfPreviewRootGuardFailsClosedWhenCurrentRootIsUnavailable() {
        XCTAssertFalse(
            shelfPreviewRequestMatches(
                requestedRootPath: "/workspace/repo",
                currentRootPath: nil,
                requestedName: "Work",
                currentName: "Work",
                requestedIsDeleted: false,
                currentIsDeleted: false
            )
        )
    }

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

    func testLogRebaseOntoSelectedCommitRequiresBranchAndNonHeadSingleSelection() {
        let commit = logCommit(repositoryPath: "/workspace/repo")
        XCTAssertTrue(
            isLogRebaseOntoSelectedCommitAvailable(
                selectionCount: 1,
                for: commit,
                currentBranchName: "main"
            )
        )
        XCTAssertFalse(
            isLogRebaseOntoSelectedCommitAvailable(
                selectionCount: 2,
                for: commit,
                currentBranchName: "main"
            )
        )
        XCTAssertFalse(
            isLogRebaseOntoSelectedCommitAvailable(
                selectionCount: 1,
                for: commit,
                currentBranchName: nil
            )
        )

        var head = commit
        head.isHead = true
        XCTAssertFalse(
            isLogRebaseOntoSelectedCommitAvailable(
                selectionCount: 1,
                for: head,
                currentBranchName: "main"
            )
        )
    }

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

    func testUpdateInfoPathFilterSettingsAreProjectScopedAndRootQualified() {
        let suiteName = "Arbor.UpdateInfoPathFilterSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let projectPath = "/workspace/project"
        let roots = [
            "/workspace/project/app",
            "/workspace/project/docs"
        ]
        GitUpdateInfoPathFilterSettings.save(
            "/workspace/project/app/Sources\n/workspace/project/docs/Docs.md\n/workspace/outside/Secret.txt",
            roots: roots,
            for: projectPath,
            defaults: defaults
        )

        XCTAssertEqual(
            GitUpdateInfoPathFilterSettings.selections(for: projectPath, defaults: defaults),
            [
                LogPathFilterSelection(
                    rootPath: "/workspace/project/app",
                    path: "Sources"
                ),
                LogPathFilterSelection(
                    rootPath: "/workspace/project/docs",
                    path: "Docs.md"
                )
            ]
        )
        XCTAssertEqual(
            GitUpdateInfoPathFilterSettings.text(for: projectPath, defaults: defaults),
            "/workspace/project/app/Sources\n/workspace/project/docs/Docs.md"
        )
        XCTAssertTrue(
            GitUpdateInfoPathFilterSettings
                .selections(for: "/workspace/other", defaults: defaults)
                .isEmpty
        )

        GitUpdateInfoPathFilterSettings.save(
            "",
            roots: roots,
            for: projectPath,
            defaults: defaults
        )
        XCTAssertTrue(
            GitUpdateInfoPathFilterSettings.selections(for: projectPath, defaults: defaults).isEmpty
        )
    }

    func testUpdateInfoAutoOpenSettingDefaultsOnAndCanBeDisabledGlobally() {
        let suiteName = "Arbor.UpdateInfoAutoOpenSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let ranges = [
            PersistedLogRevisionRange(
                rootPath: "/workspace/project",
                oldRevision: "before",
                newRevision: "after"
            )
        ]

        XCTAssertTrue(GitUpdateInfoAutoOpenSettings.value(defaults: defaults))
        XCTAssertFalse(GitUpdateInfoAutoOpenSettings.shouldAutoOpen(ranges: [], defaults: defaults))
        XCTAssertTrue(GitUpdateInfoAutoOpenSettings.shouldAutoOpen(ranges: ranges, defaults: defaults))

        GitUpdateInfoAutoOpenSettings.save(false, defaults: defaults)
        XCTAssertFalse(GitUpdateInfoAutoOpenSettings.value(defaults: defaults))
        XCTAssertFalse(GitUpdateInfoAutoOpenSettings.shouldAutoOpen(ranges: ranges, defaults: defaults))

        GitUpdateInfoAutoOpenSettings.save(true, defaults: defaults)
        XCTAssertTrue(GitUpdateInfoAutoOpenSettings.shouldAutoOpen(ranges: ranges, defaults: defaults))
    }

    func testHistoricalRevisionContentAndCommitHookSettingsUseIntellijDefaults() {
        let suiteName = "Arbor.GitAdvancedSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(GitRevisionContentSettings.mode(defaults: defaults), .filters)
        defaults.set("textconv", forKey: GitRevisionContentSettings.key)
        XCTAssertEqual(GitRevisionContentSettings.mode(defaults: defaults), .textconv)
        defaults.set("unknown", forKey: GitRevisionContentSettings.key)
        XCTAssertEqual(GitRevisionContentSettings.mode(defaults: defaults), .filters)

        XCTAssertFalse(GitCommitHooksSettings.value(defaults: defaults))
        XCTAssertFalse(
            GitCommitHooksSettings.effectiveSkipHooks(requested: false, defaults: defaults)
        )
        defaults.set(true, forKey: GitCommitHooksSettings.key)
        XCTAssertTrue(GitCommitHooksSettings.value(defaults: defaults))
        XCTAssertTrue(
            GitCommitHooksSettings.effectiveSkipHooks(requested: false, defaults: defaults)
        )
        XCTAssertTrue(
            GitCommitHooksSettings.effectiveSkipHooks(requested: true, defaults: defaults)
        )
    }

    func testInMemoryCommitEditingSettingDefaultsOnAndPersistsOverride() {
        let suiteName = "Arbor.GitInMemoryCommitEditingSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(GitInMemoryCommitEditingSettings.isEnabled(defaults: defaults))

        defaults.set(false, forKey: GitInMemoryCommitEditingSettings.key)
        XCTAssertFalse(GitInMemoryCommitEditingSettings.isEnabled(defaults: defaults))

        defaults.set(true, forKey: GitInMemoryCommitEditingSettings.key)
        XCTAssertTrue(GitInMemoryCommitEditingSettings.isEnabled(defaults: defaults))

        let pick = RebaseTodoItem(
            action: .pick,
            commitId: "a",
            summary: "a",
            message: nil,
            isMergeCommit: false,
            canSquashOrFixup: false
        )
        let edit = RebaseTodoItem(
            action: .edit,
            commitId: "b",
            summary: "b",
            message: nil,
            isMergeCommit: false,
            canSquashOrFixup: true
        )
        XCTAssertTrue(
            shouldUseInMemoryCommitEditing(
                settingEnabled: true,
                items: [pick],
                preserveMerges: false
            )
        )
        XCTAssertFalse(
            shouldUseInMemoryCommitEditing(
                settingEnabled: false,
                items: [pick],
                preserveMerges: false
            )
        )
        XCTAssertFalse(
            shouldUseInMemoryCommitEditing(
                settingEnabled: true,
                items: [pick, edit],
                preserveMerges: false
            )
        )
        XCTAssertFalse(
            shouldUseInMemoryCommitEditing(
                settingEnabled: true,
                items: [pick],
                preserveMerges: true
            )
        )
        XCTAssertTrue(
            shouldUseInMemoryCommitEditing(
                settingEnabled: true,
                items: [],
                preserveMerges: false
            )
        )
        XCTAssertFalse(
            shouldUseInMemoryCommitEditing(
                settingEnabled: false,
                items: [],
                preserveMerges: false
            )
        )
    }

    func testIncomingOutgoingInfoAdvancedSettingDefaultsOnAndGatesStrategy() {
        let suiteName = "Arbor.GitIncomingOutgoingInfoSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let projectPath = "/workspace/project"
        XCTAssertTrue(GitIncomingOutgoingInfoSettings.isEnabled(defaults: defaults))
        XCTAssertEqual(
            GitIncomingCheckStrategySettings.effectiveStrategy(for: projectPath, defaults: defaults),
            .lsRemote
        )

        defaults.set(GitIncomingCheckStrategy.fetch.rawValue, forKey: GitIncomingCheckStrategy.userDefaultsKey)
        XCTAssertEqual(
            GitIncomingCheckStrategySettings.effectiveStrategy(for: projectPath, defaults: defaults),
            .fetch
        )

        defaults.set(false, forKey: GitIncomingOutgoingInfoSettings.key)
        XCTAssertFalse(GitIncomingOutgoingInfoSettings.isEnabled(defaults: defaults))
        XCTAssertEqual(
            GitIncomingCheckStrategySettings.effectiveStrategy(for: projectPath, defaults: defaults),
            .none
        )

        GitIncomingCheckStrategySettings.saveProjectStrategy(.lsRemote, for: projectPath, defaults: defaults)
        XCTAssertEqual(
            GitIncomingCheckStrategySettings.effectiveStrategy(for: projectPath, defaults: defaults),
            .none
        )

        defaults.set(true, forKey: GitIncomingOutgoingInfoSettings.key)
        XCTAssertEqual(
            GitIncomingCheckStrategySettings.effectiveStrategy(for: projectPath, defaults: defaults),
            .lsRemote
        )
    }

    func testBranchNameCleanupMatchesGitRefValidatorTypingAndFinalRules() {
        let suiteName = "Arbor.GitBranchNameCleanupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            GitBranchNameCleanup.cleanUpOnTyping("feature  name\twith~bad:chars", defaults: defaults),
            "feature-name-withbadchars"
        )
        XCTAssertEqual(
            GitBranchNameCleanup.cleanUp("feature.lock", defaults: defaults),
            "feature"
        )
        XCTAssertEqual(
            GitBranchNameCleanup.cleanUp("feature/", defaults: defaults),
            "feature"
        )
        defaults.set("_", forKey: GitBranchNameCleanupSettings.key)
        XCTAssertEqual(
            GitBranchNameCleanup.cleanUpOnTyping("release candidate", defaults: defaults),
            "release_candidate"
        )
    }

    func testBranchComparisonLogTabIsRootQualifiedAndPreservesRange() throws {
        let tab = makeBranchComparisonLogTab(
            first: " feature ",
            second: "main",
            rootPath: "/workspace/project/./nested"
        )

        XCTAssertEqual(tab.title, "Compare: feature ↔ main")
        XCTAssertEqual(tab.viewMode, .compareBranches)
        XCTAssertEqual(tab.rootPath, "/workspace/project/nested")
        XCTAssertEqual(tab.compareRepositoryPath, "/workspace/project/nested")
        XCTAssertEqual(tab.compareRevision1, "feature")
        XCTAssertEqual(tab.compareRevision2, "main")
        XCTAssertFalse(tab.compareWithWorkingTree)

        var filteredTab = tab
        filteredTab.compareFirstFilter = BranchComparisonFilter(
            message: "fix",
            author: "alice",
            since: "2026-08-01",
            until: "2026-08-26",
            messageRegex: true,
            messageMatchCase: true,
            noMerges: true
        )
        filteredTab.compareSecondFilter = BranchComparisonFilter(author: "bob")

        let decoded = try JSONDecoder().decode(
            LogTabDescriptor.self,
            from: JSONEncoder().encode(filteredTab)
        )
        XCTAssertEqual(decoded, filteredTab)
    }

    func testTreeComparisonLogTabsSeparateCommittedAndWorkingTreeDiffs() {
        let committed = makeTreeComparisonLogTab(
            first: "feature",
            second: "main",
            rootPath: "/workspace/project/./nested",
            comparesWithWorkingTree: false
        )
        XCTAssertEqual(committed.title, "Diff: feature ↔ main")
        XCTAssertEqual(committed.viewMode, .compare)
        XCTAssertEqual(committed.rootPath, "/workspace/project/nested")
        XCTAssertFalse(committed.compareWithWorkingTree)

        let workingTree = makeTreeComparisonLogTab(
            first: "feature",
            second: "ignored",
            rootPath: "/workspace/project/nested",
            comparesWithWorkingTree: true
        )
        XCTAssertEqual(workingTree.title, "Diff: feature ↔ Working Tree")
        XCTAssertTrue(workingTree.compareWithWorkingTree)
        XCTAssertNotEqual(
            committed.compareWithWorkingTree,
            workingTree.compareWithWorkingTree
        )
    }

    func testLogCommitComparisonUsesSelectedRevisionAgainstWorkingTree() {
        let tab = makeTreeComparisonLogTab(
            first: "0123456789abcdef",
            second: "Working Tree",
            rootPath: "/workspace/project",
            comparesWithWorkingTree: true
        )

        XCTAssertEqual(tab.viewMode, .compare)
        XCTAssertEqual(tab.compareRevision1, "0123456789abcdef")
        XCTAssertEqual(tab.compareRevision2, "Working Tree")
        XCTAssertTrue(tab.compareWithWorkingTree)
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

    func testLogCommitRootBatchesPreserveRootAndSelectionOrder() {
        let commits = [
            logCommit(id: "one-a", repositoryPath: "/workspace/one/../one"),
            logCommit(id: "two-a", repositoryPath: "/workspace/two"),
            logCommit(id: "one-b", repositoryPath: "/workspace/one"),
            logCommit(id: "two-b", repositoryPath: "/workspace/two")
        ]

        let batches = logCommitRootBatches(commits)

        XCTAssertEqual(batches.map(\.rootPath), ["/workspace/one", "/workspace/two"])
        XCTAssertEqual(batches.map { $0.commits.map(\.id) }, [["one-a", "one-b"], ["two-a", "two-b"]])
    }

    func testAggregateLogIdentitySeparatesSameObjectIDsAcrossRoots() {
        XCTAssertEqual(
            logCommitDisplayIdentity(
                repositoryPath: "/workspace/one",
                id: "deadbeef",
                aggregate: true
            ),
            "/workspace/one\u{1f}deadbeef"
        )
        XCTAssertNotEqual(
            logCommitDisplayIdentity(
                repositoryPath: "/workspace/one",
                id: "deadbeef",
                aggregate: true
            ),
            logCommitDisplayIdentity(
                repositoryPath: "/workspace/two",
                id: "deadbeef",
                aggregate: true
            )
        )
    }

    func testSingleRootLogIdentityKeepsObjectIDCompatibility() {
        XCTAssertEqual(
            logCommitDisplayIdentity(
                repositoryPath: "/workspace/one",
                id: "deadbeef",
                aggregate: false
            ),
            "deadbeef"
        )
    }

    func testCopiedRevisionIDsUseOldestToNewestSpaceSeparatedOrder() {
        XCTAssertEqual(
            formattedRevisionIDsForClipboard(["new", "middle", "old"]),
            "old middle new"
        )
    }

    func testMultiRootChangeSelectionSeparatesSamePathAcrossRoots() {
        let firstRoot = MultiRootChangeSelection(
            rootPath: "/workspace/one",
            path: "README.md"
        )
        let secondRoot = MultiRootChangeSelection(
            rootPath: "/workspace/two",
            path: "README.md"
        )

        XCTAssertNotEqual(firstRoot, secondRoot)
        XCTAssertNotEqual(firstRoot.id, secondRoot.id)
    }

    func testLogChangeContextMenuPreservesSelectedPatchScope() {
        let commit = logCommit()
        let first = LogChangeRecord(
            commit: commit,
            parentIndex: 0,
            change: changes[0]
        )
        let second = LogChangeRecord(
            commit: commit,
            parentIndex: 0,
            change: changes[1]
        )

        let selected = contextualLogChangeSelection(
            context: first,
            selected: [first, second]
        )
        XCTAssertEqual(selected.map(\.id), [first.id, second.id])
    }

    func testLogChangeContextMenuFallsBackToOneRowForMixedSelection() {
        let commit = logCommit()
        let first = LogChangeRecord(
            commit: commit,
            parentIndex: 0,
            change: changes[0]
        )
        let second = LogChangeRecord(
            commit: commit,
            parentIndex: 1,
            change: changes[1]
        )

        XCTAssertEqual(
            contextualLogChangeSelection(
                context: first,
                selected: [first, second]
            ).map(\.id),
            [first.id]
        )
        XCTAssertEqual(
            contextualLogChangeSelection(
                context: first,
                selected: [first, second]
            ).map(\.id),
            [first.id]
        )
    }

    func testHistoryChangeRewriteAllowsRenamesAndGitlinksButRejectsFullSelection() {
        XCTAssertTrue(
            canRewriteSelectedHistoryChanges(
                commitCount: 1,
                selectedCount: 1,
                totalChangeCount: 2
            )
        )
        XCTAssertFalse(
            canRewriteSelectedHistoryChanges(
                commitCount: 1,
                selectedCount: 2,
                totalChangeCount: 2
            )
        )
    }

    func testHistoryChangeRewriteUsesUnfilteredChangeCount() {
        XCTAssertTrue(
            canRewriteSelectedHistoryChanges(
                commitCount: 1,
                selectedCount: 1,
                totalChangeCount: 3
            )
        )
    }

    func testLogChangeDirectorySelectionReplacesAndTogglesTheWholeGroup() {
        let group = Set(["one", "two"])

        XCTAssertEqual(
            logChangeSelectionAfterGroupClick(
                currentSelection: ["other"],
                groupIDs: group,
                visibleIDs: ["other", "one", "two"],
                anchorID: nil,
                command: false,
                shift: false
            ),
            group
        )
        XCTAssertEqual(
            logChangeSelectionAfterGroupClick(
                currentSelection: ["one"],
                groupIDs: group,
                visibleIDs: ["one", "two", "other"],
                anchorID: "one",
                command: true,
                shift: false
            ),
            Set(["one", "two"])
        )
        XCTAssertEqual(
            logChangeSelectionAfterGroupClick(
                currentSelection: ["one", "two", "other"],
                groupIDs: group,
                visibleIDs: ["one", "two", "other"],
                anchorID: "one",
                command: true,
                shift: false
            ),
            Set(["other"])
        )
        XCTAssertEqual(
            logChangeSelectionAfterGroupClick(
                currentSelection: ["one"],
                groupIDs: Set(["three", "four"]),
                visibleIDs: ["one", "two", "three", "four", "five"],
                anchorID: "one",
                command: false,
                shift: true
            ),
            Set(["one", "two", "three", "four"])
        )
    }

    func testLogBranchesRepositoryGroupingOnlyAppliesToMultiRootDashboard() {
        XCTAssertEqual(
            logBranchesGroupingMode(repositoryCount: 2, groupByRepository: true),
            .repository
        )
        XCTAssertEqual(
            logBranchesGroupingMode(repositoryCount: 2, groupByRepository: false),
            .refKind
        )
        XCTAssertEqual(
            logBranchesGroupingMode(repositoryCount: 1, groupByRepository: true),
            .refKind
        )
    }

    func testHistoryChangeRewriteOnlyAllowsFirstParentMergeSelection() {
        let merge = logCommit(id: "merge", parentIds: ["first", "second"])
        let firstParent = LogChangeRecord(
            commit: merge,
            parentIndex: 0,
            change: changes[0]
        )
        let secondParent = LogChangeRecord(
            commit: merge,
            parentIndex: 1,
            change: changes[1]
        )

        XCTAssertTrue(logChangeSelectionUsesFirstParent([firstParent]))
        XCTAssertFalse(logChangeSelectionUsesFirstParent([secondParent]))
        XCTAssertFalse(logChangeSelectionUsesFirstParent([firstParent, secondParent]))
    }

    func testLogChangePatchGroupsSupportMultipleCommitsInOneRoot() {
        let first = LogChangeRecord(
            commit: logCommit(id: "one"),
            parentIndex: 0,
            change: changes[0]
        )
        let second = LogChangeRecord(
            commit: logCommit(id: "two"),
            parentIndex: 0,
            change: changes[1]
        )

        let groups = logChangePatchGroups([first, second])
        XCTAssertEqual(groups.map { $0.map(\.id) }, [[first.id], [second.id]])
        XCTAssertTrue(canApplyLogChangeSelection([first, second]))
    }

    func testLogChangePatchGroupsSupportCrossRootSelectionsAndRejectMixedParents() {
        let first = LogChangeRecord(
            commit: logCommit(id: "one"),
            parentIndex: 0,
            change: changes[0]
        )
        let otherRoot = LogChangeRecord(
            commit: logCommit(id: "two", repositoryPath: "/workspace/other"),
            parentIndex: 0,
            change: changes[1]
        )
        let mixedParent = LogChangeRecord(
            commit: first.commit,
            parentIndex: 1,
            change: changes[1]
        )

        let crossRootGroups = logChangePatchGroups([first, otherRoot])
        XCTAssertEqual(crossRootGroups.map { $0.map(\.id) }, [[first.id], [otherRoot.id]])
        XCTAssertTrue(canApplyLogChangeSelection([first, otherRoot]))
        XCTAssertTrue(logChangePatchGroups([first, mixedParent]).isEmpty)
        XCTAssertFalse(canApplyLogChangeSelection([first, mixedParent]))
    }

    func testLogChangePatchGroupsKeepEqualCommitIDsSeparateAcrossRoots() {
        let first = LogChangeRecord(
            commit: logCommit(id: "same", repositoryPath: "/workspace/one"),
            parentIndex: 0,
            change: changes[0]
        )
        let second = LogChangeRecord(
            commit: logCommit(id: "same", repositoryPath: "/workspace/two"),
            parentIndex: 0,
            change: changes[0]
        )

        let groups = logChangePatchGroups([first, second])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.flatMap { $0.map(\.id) }, [first.id, second.id])
        XCTAssertTrue(canApplyLogChangeSelection([first, second]))
    }

    func testLogChangesBrowserGroupsEqualCommitIDsByGitRoot() {
        let first = LogChangeRecord(
            commit: logCommit(id: "same", repositoryPath: "/workspace/one"),
            parentIndex: 0,
            change: changes[0]
        )
        let second = LogChangeRecord(
            commit: logCommit(id: "same", repositoryPath: "/workspace/two"),
            parentIndex: 0,
            change: changes[1]
        )

        XCTAssertEqual(
            logChangesCommitRecords([first, second], for: first.commit),
            [first]
        )
        XCTAssertEqual(
            logChangesCommitRecords([first, second], for: second.commit),
            [second]
        )
        XCTAssertNotEqual(
            logChangesCommitIdentity(first.commit),
            logChangesCommitIdentity(second.commit)
        )
        XCTAssertEqual(
            logChangesCommitGroupName(
                first.commit,
                among: [first.commit, second.commit]
            ),
            "one · same  " + first.commit.summary
        )
        let sameNameRoot = logCommit(
            id: "other",
            repositoryPath: "/other/one"
        )
        XCTAssertEqual(
            logChangesCommitGroupName(
                first.commit,
                among: [first.commit, sameNameRoot]
            ),
            "/workspace/one · same  " + first.commit.summary
        )
    }

    func testLogChangesPatchNotificationIDIsRootQualifiedAndOrderIndependent() {
        let roots = ["/workspace/other", "/workspace/one"]
        let notificationID = logChangesPatchNotificationID(
            rootPaths: roots,
            reverse: false
        )
        XCTAssertEqual(
            notificationID,
            logChangesPatchNotificationID(
                rootPaths: roots.reversed(),
                reverse: false
            )
        )
        XCTAssertNotEqual(
            notificationID,
            logChangesPatchNotificationID(rootPaths: roots, reverse: true)
        )
        XCTAssertTrue(notificationID.contains("_workspace_one"))
        XCTAssertTrue(notificationID.contains("_workspace_other"))
    }

    func testHostedFileRevisionTargetUsesParentForDeletedPaths() {
        let deleted = LogChangeRecord(
            commit: logCommit(id: "merge", parentIds: ["first-parent", "second-parent"]),
            parentIndex: 1,
            change: changes[2]
        )
        let deletedTarget = hostedFileRevisionTarget(for: deleted)
        XCTAssertEqual(deletedTarget.commitID, "second-parent")
        XCTAssertEqual(deletedTarget.path, "Tests/AppTests.swift")

        let modified = LogChangeRecord(
            commit: logCommit(id: "modified"),
            parentIndex: 0,
            change: changes[0]
        )
        let modifiedTarget = hostedFileRevisionTarget(for: modified)
        XCTAssertEqual(modifiedTarget.commitID, "modified")
        XCTAssertEqual(modifiedTarget.path, "Sources/App.swift")
    }

    func testCreatePatchSelectionRejectsDuplicatePathsAndPreservesRenameEndpoints() {
        let first = LogChangeRecord(
            commit: logCommit(id: "one"),
            parentIndex: 0,
            change: changes[0]
        )
        let second = LogChangeRecord(
            commit: logCommit(id: "two"),
            parentIndex: 0,
            change: changes[1]
        )
        XCTAssertTrue(canCreateLogPatchSelection([first, second]))
        XCTAssertFalse(
            canCreateLogPatchSelection([
                first,
                LogChangeRecord(
                    commit: second.commit,
                    parentIndex: 0,
                    change: changes[0]
                )
            ])
        )

        let renamed = LogChangeRecord(
            commit: logCommit(id: "rename"),
            parentIndex: 0,
            change: TreeChange(
                path: "Sources/New.swift",
                oldPath: "Sources/Old.swift",
                isPureMove: false,
                kind: .renamed,
                oldMode: 0o100644,
                newMode: 0o100644
            )
        )
        XCTAssertTrue(canCreateLogPatchSelection([renamed]))
    }

    func testLogPatchCommandsKeepParentAndPathspecBoundaries() {
        let merge = logCommit(id: "merge", parentIds: ["left", "right"])
        XCTAssertEqual(
            logPatchGitCommand(
                commit: merge,
                parentIndex: 1,
                paths: ["Sources/App.swift"]
            ),
            LogPatchGitCommand(
                command: "diff",
                args: ["--binary", "--no-ext-diff", "right", "merge", "--", "Sources/App.swift"]
            )
        )
        XCTAssertEqual(
            logPatchGitCommand(
                commit: logCommit(id: "root", parentIds: []),
                parentIndex: nil,
                paths: ["README.md"]
            ),
            LogPatchGitCommand(
                command: "show",
                args: ["--format=", "--binary", "--no-ext-diff", "--root", "root", "--", "README.md"]
            )
        )
        XCTAssertNil(
            logPatchGitCommand(
                commit: merge,
                parentIndex: 2,
                paths: ["Sources/App.swift"]
            )
        )
        XCTAssertNil(
            logPatchGitCommand(
                commit: merge,
                parentIndex: 0,
                paths: []
            )
        )
    }

    func testPatchExportBaseDirectoryRejectsPathsOutsideSelectedBase() {
        let root = "/tmp/arbor-patch-export-root"
        XCTAssertEqual(
            patchExportBaseDirectoryRelativePath(
                repositoryRootPath: root,
                baseDirectory: root + "/Sources",
                paths: ["Sources/App.swift", "Sources/Model.swift"]
            ),
            "Sources"
        )
        XCTAssertTrue(
            patchExportBaseDirectoryIsValid(
                repositoryRootPath: root,
                baseDirectory: root,
                paths: ["Sources/App.swift", "Docs/README.md"]
            )
        )
        XCTAssertFalse(
            patchExportBaseDirectoryIsValid(
                repositoryRootPath: root,
                baseDirectory: root + "/Sources",
                paths: ["Sources/App.swift", "Docs/README.md"]
            )
        )
        XCTAssertNil(
            patchExportBaseDirectoryRelativePath(
                repositoryRootPath: root,
                baseDirectory: "/tmp/arbor-patch-export-root-sibling",
                paths: ["Sources/App.swift"]
            )
        )
    }

    func testPatchExportArgumentsPreserveAndToggleExistingReverseFlag() {
        let baseArguments = ["--binary", "--no-ext-diff", "HEAD", "--", "Sources/App.swift"]
        XCTAssertEqual(
            patchExportGitArguments(
                baseArguments: baseArguments,
                repositoryRootPath: "/tmp/arbor-patch-export-root",
                paths: ["Sources/App.swift"],
                options: PatchExportOptions(
                    baseDirectory: "/tmp/arbor-patch-export-root/Sources",
                    reverse: true,
                    copyToClipboard: false,
                    encoding: .utf8
                )
            ),
            ["--binary", "--no-ext-diff", "HEAD", "--reverse", "--relative=Sources", "--", "Sources/App.swift"]
        )

        XCTAssertEqual(
            patchExportGitArguments(
                baseArguments: ["--binary", "--reverse", "--", "Sources/App.swift"],
                repositoryRootPath: "/tmp/arbor-patch-export-root",
                paths: ["Sources/App.swift"],
                options: PatchExportOptions(
                    baseDirectory: nil,
                    reverse: false,
                    copyToClipboard: false,
                    encoding: .utf8
                )
            ),
            ["--binary", "--reverse", "--", "Sources/App.swift"]
        )
        XCTAssertEqual(
            patchExportGitArguments(
                baseArguments: ["--binary", "--reverse", "--", "Sources/App.swift"],
                repositoryRootPath: "/tmp/arbor-patch-export-root",
                paths: ["Sources/App.swift"],
                options: PatchExportOptions(
                    baseDirectory: nil,
                    reverse: true,
                    copyToClipboard: false,
                    encoding: .utf8
                )
            ),
            ["--binary", "--", "Sources/App.swift"]
        )
    }

    func testPatchExportTextKeepsCommitHeaderAndStableMultiPartBoundary() {
        XCTAssertEqual(
            patchTextWithCommitMessage("diff --git a/a.txt b/a.txt\n", commitMessage: "Add feature\n\nDetails"),
            "Subject: [PATCH] Add feature\n\nDetails\n---\ndiff --git a/a.txt b/a.txt\n"
        )
        XCTAssertEqual(
            joinedGitPatchParts(["first\n", "second", "", "third\n\n"]),
            "first\nsecond\nthird\n"
        )
        XCTAssertEqual(joinedGitPatchParts([]), "")
    }

    func testPatchExportEncodingUsesExplicitBytesAndRejectsLossyConversion() throws {
        XCTAssertEqual(
            try patchExportData("café", encoding: .isoLatin1),
            Data([0x63, 0x61, 0x66, 0xE9])
        )
        XCTAssertThrowsError(try patchExportData("😀", encoding: .isoLatin1))
        XCTAssertEqual(
            try patchExportData("😀", encoding: .utf8),
            Data("😀".utf8)
        )
    }

    func testPatchExportDataPreservesNonUtf8BytesOnlyForExplicitUtf8Output() throws {
        let rawPatch = Data([0x64, 0xE9, 0x0A])
        XCTAssertEqual(
            try patchExportData(rawPatch, encoding: .utf8),
            rawPatch
        )
        XCTAssertThrowsError(try patchExportData(rawPatch, encoding: .utf16))
        XCTAssertThrowsError(try patchExportData(rawPatch, encoding: .isoLatin1))
        XCTAssertThrowsError(try patchExportData(rawPatch, encoding: .windows1252))
    }

    func testJoinedGitPatchDataPreservesPayloadAndNormalizesSeparators() throws {
        XCTAssertEqual(
            joinedGitPatchData([
                Data([0x64, 0xE9, 0x0A]),
                Data([0x73, 0x65, 0x63, 0x6F, 0x6E, 0x64])
            ]),
            Data([0x64, 0xE9, 0x0A, 0x73, 0x65, 0x63, 0x6F, 0x6E, 0x64, 0x0A])
        )
    }

    func testPatchExportCommitHeaderDoesNotCorruptRawBody() throws {
        let rawPatch = Data([0x64, 0xE9, 0x0A])
        XCTAssertEqual(
            try patchExportData(
                rawPatch,
                commitMessage: "subject",
                encoding: .utf8
            ),
            Data("Subject: [PATCH] subject\n---\n".utf8) + rawPatch
        )
    }

    func testPatchExportSettingsAreProjectScopedAndRememberDestination() throws {
        let suiteName = "ArborTests.PatchExport.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstRoot = "/tmp/arbor-patch-settings-one"
        let secondRoot = "/tmp/arbor-patch-settings-two"
        XCTAssertEqual(PatchExportSettings.encoding(for: firstRoot, defaults: defaults), .utf8)
        XCTAssertFalse(PatchExportSettings.copyToClipboard(for: firstRoot, defaults: defaults))

        let options = PatchExportOptions(
            baseDirectory: nil,
            reverse: false,
            copyToClipboard: true,
            encoding: .windows1252
        )
        PatchExportSettings.save(options, for: firstRoot, defaults: defaults)
        XCTAssertEqual(
            PatchExportSettings.encoding(for: firstRoot, defaults: defaults),
            .windows1252
        )
        XCTAssertTrue(PatchExportSettings.copyToClipboard(for: firstRoot, defaults: defaults))
        XCTAssertEqual(PatchExportSettings.encoding(for: secondRoot, defaults: defaults), .utf8)
        XCTAssertFalse(PatchExportSettings.copyToClipboard(for: secondRoot, defaults: defaults))

        let destination = URL(fileURLWithPath: "/tmp/patch.patch")
        PatchExportSettings.saveDestination(destination, for: firstRoot, defaults: defaults)
        XCTAssertEqual(
            PatchExportSettings.lastDirectory(for: firstRoot, defaults: defaults)?.path,
            "/tmp"
        )
    }

    func testLogChangeGetVersionContextPreservesCrossRootSelection() {
        let first = LogChangeRecord(
            commit: logCommit(id: "one"),
            parentIndex: 0,
            change: changes[0]
        )
        let second = LogChangeRecord(
            commit: logCommit(id: "two", repositoryPath: "/workspace/other"),
            parentIndex: 0,
            change: changes[1]
        )

        XCTAssertEqual(
            contextualLogChangeRestoreSelection(
                context: first,
                selected: [first, second]
            ).map(\.id),
            [first.id, second.id]
        )
        XCTAssertEqual(
            contextualLogChangeRestoreSelection(
                context: first,
                selected: [second]
            ).map(\.id),
            [first.id]
        )
    }

    func testLogChangesFromParentsOnlyExpandsOneMergeCommit() {
        let merge = logCommit(id: "merge", parentIds: ["parent-a", "parent-b"])

        XCTAssertEqual(
            logChangeParentIndices(
                commit: merge,
                selectedCommitCount: 1,
                selectedParentIndex: 0,
                showsChangesFromParents: true
            ),
            [0, 1]
        )
        XCTAssertEqual(
            logChangeParentIndices(
                commit: merge,
                selectedCommitCount: 2,
                selectedParentIndex: 0,
                showsChangesFromParents: true
            ),
            [0]
        )
    }

    func testLogChangeAffectedPathMatchesDirectoriesAndRenameEndpoints() {
        let renamed = TreeChange(
            path: "Sources/New/App.swift",
            oldPath: "Legacy/App.swift",
            isPureMove: false,
            kind: .renamed,
            oldMode: 0o100644,
            newMode: 0o100644
        )

        XCTAssertTrue(logChangeAffectsPath(renamed, affectedPath: "Sources"))
        XCTAssertTrue(logChangeAffectsPath(renamed, affectedPath: "Legacy/App.swift"))
        XCTAssertTrue(logChangeAffectsPath(renamed, affectedPath: "./Sources/New/App.swift/"))
        XCTAssertFalse(logChangeAffectsPath(renamed, affectedPath: "Other"))
        XCTAssertFalse(logChangeAffectsPath(renamed, affectedPath: ""))
    }

    func testRelativeLogPathFilterUsesDeepestGitRootAndDirectoryMarker() {
        XCTAssertEqual(
            relativeLogPathFilter(
                for: URL(fileURLWithPath: "/workspace/repo/Package/Sources/App.swift"),
                roots: ["/workspace/repo", "/workspace/repo/Package"]
            ),
            "Sources/App.swift"
        )
        XCTAssertEqual(
            relativeLogPathFilter(
                for: URL(fileURLWithPath: "/workspace/repo/Sources", isDirectory: true),
                roots: ["/workspace/repo"]
            ),
            "Sources/"
        )
        XCTAssertEqual(
            relativeLogPathFilter(
                for: URL(fileURLWithPath: "/workspace/other/File.swift"),
                roots: ["/workspace/repo"]
            ),
            nil
        )
    }

    func testLogPathFiltersNormalizeMultipleLinesAndPreserveOrder() {
        let paths = normalizedLogPathFilters(" Sources/App.swift\n./Tests/\nSources/App.swift\n")

        XCTAssertEqual(paths, ["Sources/App.swift", "Tests"])
        XCTAssertEqual(logPathFilterText(paths), "Sources/App.swift\nTests")
        XCTAssertEqual(logPathFilterSummary(paths), "Sources/App.swift + 1")
    }

    func testRootQualifiedLogPathSelectionsPreserveEqualPathsAcrossRoots() {
        let selections = normalizedLogPathFilterSelections([
            LogPathFilterSelection(rootPath: "/workspace/one", path: "Sources/App.swift"),
            LogPathFilterSelection(rootPath: "/workspace/two", path: "Sources/App.swift"),
            LogPathFilterSelection(rootPath: "/workspace/one", path: "./Sources/App.swift")
        ])
        XCTAssertEqual(selections.count, 2)
        XCTAssertEqual(
            logPathFilterPathsForRoot(selections, rootPath: "/workspace/one"),
            ["Sources/App.swift"]
        )
        XCTAssertEqual(
            logPathFilterPathsForRoot(
                [LogPathFilterSelection(rootPath: "/workspace/one", path: "Sources/App.swift")],
                rootPath: "/workspace/two"
            ),
            []
        )

        let editorText = logPathFilterEditorText(selections)
        XCTAssertTrue(editorText.contains("/workspace/one/Sources/App.swift"))
        XCTAssertTrue(editorText.contains("/workspace/two/Sources/App.swift"))
        XCTAssertEqual(
            parseLogPathFilterEditorText(
                editorText,
                roots: ["/workspace/one", "/workspace/two"]
            ),
            selections
        )

        let change = TreeChange(
            path: "Sources/App.swift",
            oldPath: nil,
            isPureMove: false,
            kind: .modified,
            oldMode: 0o100644,
            newMode: 0o100644
        )
        XCTAssertTrue(logChangeAffectsAnyPath(change, rootPath: "/workspace/one", selections: selections))
        XCTAssertTrue(logChangeAffectsAnyPath(change, rootPath: "/workspace/two", selections: selections))
        XCTAssertFalse(logChangeAffectsAnyPath(change, rootPath: "/workspace/three", selections: selections))
    }

    func testRootQualifiedPathParsingUsesTheDeepestNestedRoot() {
        let roots = ["/workspace/repo", "/workspace/repo/packages/app"]
        let selections = parseLogPathFilterEditorText(
            "/workspace/repo/packages/app/Sources/App.swift",
            roots: roots
        )

        XCTAssertEqual(
            selections,
            [LogPathFilterSelection(
                rootPath: "/workspace/repo/packages/app",
                path: "Sources/App.swift"
            )]
        )
        XCTAssertEqual(
            logRootPathsDeepestFirst(roots),
            ["/workspace/repo/packages/app", "/workspace/repo"]
        )
        XCTAssertTrue(
            parseLogPathFilterEditorText(
                "/workspace/outside/Sources/App.swift",
                roots: roots
            ).isEmpty
        )
    }

    func testLogPathTreeSelectionCollapsesDescendantsButKeepsRootsSeparate() {
        let parent = LogPathFilterSelection(rootPath: "/workspace/one", path: "Sources")
        let child = LogPathFilterSelection(rootPath: "/workspace/one", path: "Sources/App.swift")
        let otherRoot = LogPathFilterSelection(rootPath: "/workspace/two", path: "Sources/App.swift")

        let collapsed = normalizedLogTreeSelections([child, parent, otherRoot])
        XCTAssertEqual(collapsed, [parent, otherRoot])
        XCTAssertEqual(logPathTreeSelectionState(child, in: collapsed), .selectedAbove)
        XCTAssertEqual(logPathTreeSelectionState(parent, in: collapsed), .selected)
        XCTAssertEqual(logPathTreeSelectionState(otherRoot, in: collapsed), .selected)

        let expanded = logPathTreeSelectionsAfterToggle(parent, in: collapsed)
        XCTAssertEqual(expanded, [otherRoot])
    }

    func testLogPathTreeSelectionLimitRejectsIndependentNodeButAllowsParentCollapse() {
        let root = "/workspace/one"
        let selected = Set((0..<logPathTreeSelectionLimit).map { index in
            LogPathFilterSelection(rootPath: root, path: "Sources/File\(index).swift")
        })
        let extra = LogPathFilterSelection(rootPath: root, path: "Sources/Extra.swift")
        XCTAssertEqual(
            logPathTreeSelectionsAfterToggle(extra, in: selected),
            selected
        )

        let descendant = LogPathFilterSelection(rootPath: root, path: "Sources/Folder/File.swift")
        var withDescendant = selected
        withDescendant.remove(LogPathFilterSelection(rootPath: root, path: "Sources/File0.swift"))
        withDescendant.insert(descendant)
        let folder = LogPathFilterSelection(rootPath: root, path: "Sources/Folder")
        let collapsed = logPathTreeSelectionsAfterToggle(folder, in: withDescendant)
        XCTAssertTrue(collapsed.contains(folder))
        XCTAssertFalse(collapsed.contains(descendant))
        XCTAssertEqual(collapsed.count, logPathTreeSelectionLimit)
    }

    func testLogRootVisibilityReconcilesStaleRootsAndSerializesPartialSelection() {
        let roots = ["/workspace/one", "/workspace/two"]
        let visible = reconciledLogVisibleRootPaths(
            allRoots: roots,
            raw: "/workspace/two\n/workspace/missing"
        )

        XCTAssertEqual(visible, ["/workspace/two"])
        XCTAssertEqual(
            serializedLogVisibleRootPaths(selected: visible, allRoots: roots),
            "/workspace/two"
        )
        XCTAssertEqual(
            reconciledLogVisibleRootPaths(allRoots: roots, raw: ""),
            Set(roots)
        )
    }

    func testUncommitChangedPathsIncludesRenameEndpointsOnce() {
        let changes = [
            TreeChange(
                path: "Sources/New.swift",
                oldPath: "Sources/Old.swift",
                isPureMove: true,
                kind: .renamed,
                oldMode: 0o100644,
                newMode: 0o100644
            ),
            TreeChange(
                path: "Sources/New.swift",
                oldPath: nil,
                isPureMove: false,
                kind: .modified,
                oldMode: 0o100644,
                newMode: 0o100644
            )
        ]

        XCTAssertEqual(
            uncommitChangedPaths(changes),
            ["Sources/New.swift", "Sources/Old.swift"]
        )
    }

    func testLogCommitSelectionRequiresOneRootBeforeRemoteActions() {
        let first = CommitInfo(
            id: "a",
            repositoryPath: "/workspace/one",
            shortId: "a",
            summary: "one",
            authorName: "A",
            authorEmail: "a@example.com",
            committerName: "A",
            committerEmail: "a@example.com",
            messageBody: "",
            hasSignature: false,
            time: 0,
            parentIds: [],
            refs: [],
            tagRefs: [],
            remoteRefs: [],
            isHead: false,
            lane: 0,
            parentLanes: []
        )
        let sameRoot = CommitInfo(
            id: "b",
            repositoryPath: "/workspace/one",
            shortId: "b",
            summary: "same root",
            authorName: "A",
            authorEmail: "a@example.com",
            committerName: "A",
            committerEmail: "a@example.com",
            messageBody: "",
            hasSignature: false,
            time: 0,
            parentIds: [],
            refs: [],
            tagRefs: [],
            remoteRefs: [],
            isHead: false,
            lane: 0,
            parentLanes: []
        )
        let otherRoot = CommitInfo(
            id: "c",
            repositoryPath: "/workspace/two",
            shortId: "c",
            summary: "other root",
            authorName: "A",
            authorEmail: "a@example.com",
            committerName: "A",
            committerEmail: "a@example.com",
            messageBody: "",
            hasSignature: false,
            time: 0,
            parentIds: [],
            refs: [],
            tagRefs: [],
            remoteRefs: [],
            isHead: false,
            lane: 0,
            parentLanes: []
        )

        XCTAssertEqual(
            logCommitSelectionRepositoryPath([first, sameRoot]),
            "/workspace/one"
        )
        XCTAssertNil(logCommitSelectionRepositoryPath([first, otherRoot]))
    }

    func testResetSelectionAllowsOneRevisionPerRootOnly() {
        let first = CommitInfo(
            id: "a",
            repositoryPath: "/workspace/one",
            shortId: "a",
            summary: "one",
            authorName: "A",
            authorEmail: "a@example.com",
            committerName: "A",
            committerEmail: "a@example.com",
            messageBody: "",
            hasSignature: false,
            time: 0,
            parentIds: [],
            refs: [],
            tagRefs: [],
            remoteRefs: [],
            isHead: false,
            lane: 0,
            parentLanes: []
        )
        var sameRoot = first
        sameRoot.id = "b"
        var otherRoot = first
        otherRoot.id = "c"
        otherRoot.repositoryPath = "/workspace/two"

        XCTAssertTrue(isResetSelectionAvailable(for: [first]))
        XCTAssertFalse(isResetSelectionAvailable(for: [first, sameRoot]))
        XCTAssertTrue(isResetSelectionAvailable(for: [first, otherRoot]))
    }

    func testMultiRootResetRetryReplacesOnlyRetriedRootResults() {
        let initial = [
            RootOperationResult(
                rootPath: "/workspace/app",
                displayName: "app",
                success: true,
                skipped: false,
                message: "reset to aaaaaaa"
            ),
            RootOperationResult(
                rootPath: "/workspace/docs",
                displayName: "docs",
                success: false,
                skipped: false,
                message: "local changes would be overwritten"
            ),
            RootOperationResult(
                rootPath: "/workspace/tools",
                displayName: "tools",
                success: false,
                skipped: false,
                message: "repository unavailable"
            )
        ]
        let retry = [
            RootOperationResult(
                rootPath: "/workspace/docs",
                displayName: "docs",
                success: true,
                skipped: false,
                message: "reset to aaaaaaa"
            )
        ]

        let merged = mergeRootOperationResults(
            preserved: initial.filter { $0.rootPath != "/workspace/docs" },
            retry: retry,
            rootOrder: ["/workspace/app", "/workspace/docs", "/workspace/tools"]
        )

        XCTAssertEqual(merged.map(\.rootPath), [
            "/workspace/app", "/workspace/docs", "/workspace/tools"
        ])
        XCTAssertTrue(merged[1].success)
        XCTAssertEqual(merged[2].message, "repository unavailable")
    }

    func testMultiRootMergeSmartRetryKeepsNonBlockedResultsAndRollbackMetadata() {
        func result(
            rootPath: String,
            displayName: String,
            success: Bool,
            skipped: Bool = false,
            message: String,
            initialHead: String?,
            finalHead: String?,
            requiresFinish: Bool = false,
            conflicts: [String] = [],
            overwritePaths: [String] = []
        ) -> MultiRootMergeResult {
            MultiRootMergeResult(
                rootPath: rootPath,
                displayName: displayName,
                success: success,
                skipped: skipped,
                message: message,
                initialHead: initialHead,
                finalHead: finalHead,
                completed: success && !requiresFinish,
                requiresFinish: requiresFinish,
                conflicts: conflicts,
                localChangesOverwritePaths: overwritePaths
            )
        }

        let initial = [
            result(
                rootPath: "/workspace/app",
                displayName: "app",
                success: true,
                message: "merge completed",
                initialHead: "a",
                finalHead: "b"
            ),
            result(
                rootPath: "/workspace/docs",
                displayName: "docs",
                success: false,
                message: "local changes would be overwritten",
                initialHead: "c",
                finalHead: "c",
                overwritePaths: ["README.md"]
            ),
            result(
                rootPath: "/workspace/tools",
                displayName: "tools",
                success: true,
                message: "merge paused with 1 conflict(s)",
                initialHead: "d",
                finalHead: "d",
                requiresFinish: true,
                conflicts: ["tool.swift"]
            )
        ]
        let retry = [
            result(
                rootPath: "/workspace/docs",
                displayName: "docs",
                success: true,
                message: "merge completed",
                initialHead: "c",
                finalHead: "e"
            )
        ]

        let merged = mergeMultiRootMergeResults(
            preserved: initial.filter { $0.rootPath != "/workspace/docs" },
            retry: retry,
            rootOrder: ["/workspace/app", "/workspace/docs", "/workspace/tools"]
        )

        XCTAssertEqual(merged.map(\.rootPath), [
            "/workspace/app", "/workspace/docs", "/workspace/tools"
        ])
        XCTAssertEqual(merged[0].initialHead, "a")
        XCTAssertEqual(merged[0].finalHead, "b")
        XCTAssertTrue(merged[1].success)
        XCTAssertEqual(merged[1].finalHead, "e")
        XCTAssertTrue(merged[2].requiresFinish)
        XCTAssertEqual(merged[2].conflicts, ["tool.swift"])
    }

    func testCompletedMergeRevisionRangesExcludePendingFailedSkippedAndUnchangedRoots() {
        let results = [
            MultiRootMergeResult(
                rootPath: "/workspace/app",
                displayName: "app",
                success: true,
                skipped: false,
                message: "merge completed",
                initialHead: "1111111",
                finalHead: "2222222",
                completed: true,
                requiresFinish: false,
                conflicts: [],
                localChangesOverwritePaths: []
            ),
            MultiRootMergeResult(
                rootPath: "/workspace/docs",
                displayName: "docs",
                success: true,
                skipped: false,
                message: "already up to date",
                initialHead: "3333333",
                finalHead: "3333333",
                completed: true,
                requiresFinish: false,
                conflicts: [],
                localChangesOverwritePaths: []
            ),
            MultiRootMergeResult(
                rootPath: "/workspace/tools",
                displayName: "tools",
                success: true,
                skipped: false,
                message: "merge applied; explicit finish required",
                initialHead: "4444444",
                finalHead: "5555555",
                completed: false,
                requiresFinish: true,
                conflicts: [],
                localChangesOverwritePaths: []
            ),
            MultiRootMergeResult(
                rootPath: "/workspace/web",
                displayName: "web",
                success: false,
                skipped: false,
                message: "merge failed",
                initialHead: "6666666",
                finalHead: "7777777",
                completed: false,
                requiresFinish: false,
                conflicts: [],
                localChangesOverwritePaths: []
            ),
            MultiRootMergeResult(
                rootPath: "/workspace/worker",
                displayName: "worker",
                success: true,
                skipped: true,
                message: "not attempted",
                initialHead: "8888888",
                finalHead: "9999999",
                completed: false,
                requiresFinish: false,
                conflicts: [],
                localChangesOverwritePaths: []
            )
        ]

        let ranges = ContentView.completedMergeRevisionRanges(results)

        XCTAssertEqual(ranges, [
            PersistedLogRevisionRange(
                rootPath: "/workspace/app",
                oldRevision: "1111111",
                newRevision: "2222222"
            )
        ])
    }

    func testAddCommitsToRemoteBranchRequiresOneRootAndLinearCommits() {
        let first = CommitInfo(
            id: "a",
            repositoryPath: "/workspace/one",
            shortId: "a",
            summary: "one",
            authorName: "A",
            authorEmail: "a@example.com",
            committerName: "A",
            committerEmail: "a@example.com",
            messageBody: "",
            hasSignature: false,
            time: 0,
            parentIds: [],
            refs: [],
            tagRefs: [],
            remoteRefs: [],
            isHead: false,
            lane: 0,
            parentLanes: []
        )
        var merge = first
        merge.id = "merge"
        merge.parentIds = ["left", "right"]
        var otherRoot = first
        otherRoot.id = "other"
        otherRoot.repositoryPath = "/workspace/two"

        XCTAssertTrue(isAddCommitsToRemoteBranchAvailable(for: [first]))
        XCTAssertFalse(isAddCommitsToRemoteBranchAvailable(for: [first, merge]))
        XCTAssertFalse(isAddCommitsToRemoteBranchAvailable(for: [first, otherRoot]))
    }

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

    func testRebaseUndoTargetAfterContinueKeepsExpectedHeadSafetyBoundary() {
        let seed = RebaseUndoSeed(
            repositoryPath: "/project/app",
            branch: "feature",
            initialHead: "1111111",
            updateRefs: false,
            protectionCommitID: "first-changed"
        )

        let target = rebaseUndoTargetAfterCompletion(
            seed: seed,
            currentBranch: "feature",
            finalHead: "2222222"
        )
        XCTAssertEqual(target?.initialHead, "1111111")
        XCTAssertEqual(target?.expectedHead, "2222222")
        XCTAssertEqual(target?.protectionCommitID, "first-changed")
        XCTAssertNil(rebaseUndoTargetAfterCompletion(seed: seed, currentBranch: "other", finalHead: "2222222"))
        XCTAssertNil(rebaseUndoTargetAfterCompletion(seed: seed, currentBranch: "feature", finalHead: "1111111"))
        XCTAssertNil(rebaseUndoTargetAfterCompletion(
            seed: RebaseUndoSeed(
                repositoryPath: "/project/app",
                branch: "feature",
                initialHead: "1111111",
                updateRefs: true
            ),
            currentBranch: "feature",
            finalHead: "2222222"
        ))
    }

    func testRebaseUndoTargetSupportsDetachedHeadIdentity() {
        let seed = RebaseUndoSeed(
            repositoryPath: "/project/app",
            branch: "",
            initialHead: "1111111",
            updateRefs: false
        )

        let target = rebaseUndoTargetAfterCompletion(
            seed: seed,
            currentBranch: nil,
            finalHead: "2222222"
        )

        XCTAssertEqual(target?.branch, "")
        XCTAssertEqual(target?.initialHead, "1111111")
        XCTAssertEqual(target?.expectedHead, "2222222")
    }

    func testCheckoutWithRebaseReusesExistingBranchUnlessResetIsExplicit() {
        XCTAssertFalse(
            branchCreateAndRebaseShouldCreateBranch(
                branchAlreadyExists: true,
                resetExisting: false
            )
        )
        XCTAssertTrue(
            branchCreateAndRebaseShouldCreateBranch(
                branchAlreadyExists: true,
                resetExisting: true
            )
        )
        XCTAssertTrue(
            branchCreateAndRebaseShouldCreateBranch(
                branchAlreadyExists: false,
                resetExisting: false
            )
        )
    }

    func testRebaseUndoSeedCodableRoundTripsRecoveryBoundary() throws {
        let seed = RebaseUndoSeed(
            repositoryPath: "/project/app",
            branch: "feature",
            initialHead: "1111111",
            updateRefs: false,
            protectionCommitID: "first-changed"
        )

        let decoded = try JSONDecoder().decode(
            RebaseUndoSeed.self,
            from: JSONEncoder().encode(seed)
        )

        XCTAssertEqual(decoded, seed)

        let legacy = Data(
            #"{"repositoryPath":"/project/app","branch":"feature","initialHead":"1111111","updateRefs":false}"#.utf8
        )
        XCTAssertNil(try JSONDecoder().decode(RebaseUndoSeed.self, from: legacy).protectionCommitID)
    }

    func testRebaseUndoBlocksPublishedProtectedRemoteHistory() {
        let remoteBranches = [
            RemoteBranchInfo(name: "origin/main", remote: "origin", shortId: "1111111"),
            RemoteBranchInfo(name: "origin/feature", remote: "origin", shortId: "2222222")
        ]

        XCTAssertEqual(
            ContentView.protectedRemoteBranchNameContainingCommit(
                commitID: "1111111",
                remoteBranches: remoteBranches,
                protectedPatterns: ["main"],
                isReachable: { commitID, branchName in
                    commitID == "1111111" && branchName == "origin/main"
                }
            ),
            "origin/main"
        )
        XCTAssertNil(
            ContentView.protectedRemoteBranchNameContainingCommit(
                commitID: "1111111",
                remoteBranches: remoteBranches,
                protectedPatterns: ["main"],
                isReachable: { _, _ in false }
            )
        )
        XCTAssertNil(
            ContentView.protectedRemoteBranchNameContainingCommit(
                commitID: "1111111",
                remoteBranches: remoteBranches,
                protectedPatterns: ["release"],
                isReachable: { _, _ in true }
            )
        )
    }

    func testDropUndoTargetAndSemanticActionRoundTripAcrossPersistence() throws {
        let target = RebaseUndoTarget(
            repositoryPath: "/project/app",
            branch: "feature",
            initialHead: "1111111",
            expectedHead: "2222222",
            protectionCommitID: "first-changed"
        )
        let request = ArborVCSActionRequest(
            kind: .undoRebase,
            projectPath: "/project",
            rootPath: target.repositoryPath,
            shelfName: "",
            rebaseUndoInitialHead: target.initialHead,
            rebaseUndoExpectedHead: target.expectedHead,
            rebaseUndoBranch: target.branch,
            rebaseUndoProtectionCommit: target.protectionCommitID
        )

        XCTAssertEqual(
            try JSONDecoder().decode(RebaseUndoTarget.self, from: JSONEncoder().encode(target)),
            target
        )
        XCTAssertEqual(
            try JSONDecoder().decode(ArborVCSActionRequest.self, from: JSONEncoder().encode(request)),
            request
        )
    }

    func testSelectedChangesUndoTargetAndSemanticActionRoundTripAcrossPersistence() throws {
        let target = LogSelectedChangesUndoTarget(
            repositoryPath: "/project/app",
            branch: "feature",
            initialHead: "1111111",
            expectedHead: "2222222"
        )
        let request = ArborVCSActionRequest(
            kind: .undoLogSelectedChanges,
            projectPath: "/project",
            rootPath: target.repositoryPath,
            shelfName: "",
            logSelectedChangesUndoInitialHead: target.initialHead,
            logSelectedChangesUndoExpectedHead: target.expectedHead,
            logSelectedChangesUndoBranch: target.branch
        )

        XCTAssertEqual(
            try JSONDecoder().decode(
                LogSelectedChangesUndoTarget.self,
                from: JSONEncoder().encode(target)
            ),
            target
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                ArborVCSActionRequest.self,
                from: JSONEncoder().encode(request)
            ),
            request
        )
    }

    func testRebaseUndoSemanticActionRemainsRootScopedAcrossReload() throws {
        func request(rootPath: String) -> ArborVCSActionRequest {
            ArborVCSActionRequest(
                kind: .undoRebase,
                projectPath: "/project",
                rootPath: rootPath,
                shelfName: "",
                rebaseUndoInitialHead: "1111111",
                rebaseUndoExpectedHead: "2222222",
                rebaseUndoBranch: "feature",
                rebaseUndoProtectionCommit: "first-changed"
            )
        }

        let first = request(rootPath: "/project/app")
        let sameRootAfterReload = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(first)
        )
        let otherRoot = request(rootPath: "/project/lib")

        XCTAssertEqual(sameRootAfterReload, first)
        XCTAssertNotEqual(first, otherRoot)
    }

    func testPullLocalChangesPreservationCodableKeepsExactShelfOrStashIdentity() throws {
        let shelf = PullLocalChangesPreservation(
            shelfName: "Arbor: pull 123",
            stashMessage: nil
        )
        let stash = PullLocalChangesPreservation(
            shelfName: nil,
            stashMessage: "Arbor: pull 456",
            stashID: "abcdef1234567890"
        )

        XCTAssertEqual(
            try JSONDecoder().decode(
                PullLocalChangesPreservation.self,
                from: JSONEncoder().encode(shelf)
            ),
            shelf
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                PullLocalChangesPreservation.self,
                from: JSONEncoder().encode(stash)
            ),
            stash
        )

        // Markers written before stash IDs were persisted remain decodable and
        // continue through the message-based compatibility fallback.
        let legacy = try JSONSerialization.data(
            withJSONObject: ["shelfName": NSNull(), "stashMessage": "Arbor: pull legacy"]
        )
        let decodedLegacy = try JSONDecoder().decode(
            PullLocalChangesPreservation.self,
            from: legacy
        )
        XCTAssertEqual(decodedLegacy.stashMessage, "Arbor: pull legacy")
        XCTAssertNil(decodedLegacy.stashID)
    }

    func testMultiRootCheckoutRollbackRequestRoundTripsExactTargets() throws {
        let target = PersistedMultiRootCheckoutTarget(
            MultiRootBranchTarget(
                rootPath: "/project/app",
                checkedOut: true,
                previousBranch: "main",
                previousHead: "1111111",
                expectedHead: "2222222",
                expectedBranch: "feature",
                createdBranch: "feature"
            )
        )
        let request = ArborVCSActionRequest(
            kind: .rollbackMultiRootCheckout,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            checkoutReference: "feature",
            checkoutTargets: [target]
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.checkoutTargets?.map(\.rootPath), ["/project/app"])
        XCTAssertEqual(decoded.checkoutTargets?.first?.makeLiveTarget().previousHead, "1111111")
    }

    func testMultiRootBranchCreateRollbackRequestRoundTripsExactTipState() throws {
        let target = PersistedMultiRootBranchCreateTarget(
            MultiRootBranchCreateTarget(
                rootPath: "/project/app",
                checkedOut: true,
                previousBranch: "main",
                previousHead: "1111111",
                expectedHead: "3333333",
                expectedBranch: "topic",
                previousBranchTip: "2222222",
                expectedBranchTip: "3333333"
            )
        )
        let request = ArborVCSActionRequest(
            kind: .rollbackMultiRootBranchCreate,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootBranchName: "topic",
            multiRootBranchCreateRollbackTargets: [target]
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(
            decoded.multiRootBranchCreateRollbackTargets?.first?.previousBranchTip,
            "2222222"
        )
        XCTAssertEqual(
            decoded.multiRootBranchCreateRollbackTargets?.first?.makeLiveTarget().expectedBranchTip,
            "3333333"
        )
    }

    @MainActor
    func testFeedbackHistoryRestoresMultiRootBranchCreateRollbackActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterMultiRootBranchCreateRollbackTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .rollbackMultiRootBranchCreate,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootBranchName: "topic",
            multiRootBranchCreateRollbackTargets: [
                PersistedMultiRootBranchCreateTarget(
                    MultiRootBranchCreateTarget(
                        rootPath: "/project/app",
                        checkedOut: false,
                        previousBranch: "main",
                        previousHead: "1111111",
                        expectedHead: nil,
                        expectedBranch: nil,
                        previousBranchTip: "2222222",
                        expectedBranchTip: "3333333"
                    )
                )
            ]
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Multi-root branch creation partially completed",
            additionalActions: [
                FeedbackAction(
                    title: "Rollback Successful Roots",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testFeedbackHistoryRestoresMultiRootCheckoutRollbackActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterMultiRootRollbackTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .rollbackMultiRootCheckout,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            checkoutReference: "feature",
            checkoutTargets: [
                PersistedMultiRootCheckoutTarget(
                    MultiRootBranchTarget(
                        rootPath: "/project/app",
                        checkedOut: true,
                        previousBranch: "main",
                        previousHead: "1111111",
                        expectedHead: "2222222",
                        expectedBranch: "feature",
                        createdBranch: nil
                    )
                )
            ]
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Checkout partially completed",
            additionalActions: [
                FeedbackAction(
                    title: "Rollback Successful Roots",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testMultiRootUpdateRollbackActionRoundTripsAndSurvivesReload() throws {
        let request = ArborVCSActionRequest(
            kind: .rollbackMultiRootUpdate,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootUpdateRollbackTargets: [
                PersistedMultiRootUpdateRollbackTarget(
                    rootPath: "/project/vendor/lib",
                    displayName: "lib",
                    initialHead: "1111111",
                    expectedHead: "2222222"
                )
            ]
        )
        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.multiRootUpdateRollbackTargets?.first?.expectedHead, "2222222")

        let suiteName = "Arbor.FeedbackCenterMultiRootUpdateRollbackTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Update Project partially completed",
            additionalActions: [
                FeedbackAction(
                    title: "Rollback Updated Roots",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testSubmoduleUpdateUndoActionKeepsItsDedicatedRecoveryKind() throws {
        let request = ArborVCSActionRequest(
            kind: .rollbackSubmoduleUpdate,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootUpdateRollbackTargets: [
                PersistedMultiRootUpdateRollbackTarget(
                    rootPath: "/project/vendor/lib",
                    displayName: "lib",
                    initialHead: "child-old",
                    expectedHead: "child-new",
                    expectedHeadBranch: ""
                )
            ]
        )
        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.kind, .rollbackSubmoduleUpdate)
        XCTAssertEqual(decoded.multiRootUpdateRollbackTargets?.count, 1)
    }

    @MainActor
    func testMultiRootSoftResetRollbackActionRoundTripsAndSurvivesReload() throws {
        let target = PersistedMultiRootResetRollbackTarget(
            rootPath: "/project/app",
            displayName: "app",
            initialHead: "1111111",
            expectedHead: "2222222",
            expectedHeadBranch: "main"
        )
        let request = ArborVCSActionRequest(
            kind: .rollbackMultiRootReset,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootResetRollbackTargets: [target]
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(
            decoded.multiRootResetRollbackTargets?.first?.makeLiveTarget().expectedHead,
            "2222222"
        )
        XCTAssertEqual(
            decoded.multiRootResetRollbackTargets?.first?.expectedHeadBranch,
            "main"
        )

        let suiteName = "Arbor.FeedbackCenterMultiRootSoftResetRollbackTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.success(
            "Multi-root soft reset completed",
            additionalActions: [
                FeedbackAction(
                    title: "Rollback Soft Reset",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testResetRecoveryUndoAndKeepActionsRoundTripAndSurviveReload() throws {
        let target = PersistedResetRecoveryTarget(
            rootPath: "/project/app",
            displayName: "app",
            initialHead: "1111111",
            expectedHead: "2222222",
            expectedHeadBranch: "main",
            mode: .hard,
            rollbackID: "reset-undo-1"
        )
        let undoRequest = ArborVCSActionRequest(
            kind: .rollbackResetRecovery,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            resetRecoveryTargets: [target]
        )
        let keepRequest = ArborVCSActionRequest(
            kind: .keepResetRecovery,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            resetRecoveryTargets: [target]
        )

        let decodedUndo = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(undoRequest)
        )
        let decodedKeep = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(keepRequest)
        )
        XCTAssertEqual(decodedUndo, undoRequest)
        XCTAssertEqual(decodedKeep, keepRequest)
        XCTAssertEqual(decodedUndo.resetRecoveryTargets?.first?.makeLiveTarget().mode, .hard)
        XCTAssertEqual(decodedUndo.resetRecoveryTargets?.first?.rollbackID, "reset-undo-1")

        let suiteName = "Arbor.FeedbackCenterResetRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Reset completed",
            additionalActions: [
                FeedbackAction(title: "Undo Reset", semanticAction: undoRequest) {},
                FeedbackAction(title: "Keep Reset Result", semanticAction: keepRequest) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.map(\.semanticAction), [undoRequest, keepRequest])
    }

    @MainActor
    func testMultiRootBranchRenameRollbackActionRoundTripsAndSurvivesReload() throws {
        let target = PersistedMultiRootBranchRenameRollbackTarget(
            rootPath: "/project/app",
            displayName: "app",
            oldName: "feature",
            newName: "feature-renamed",
            expectedNewTip: "2222222",
            expectedCurrentBranch: "main",
            expectedUpstream: nil,
            upstream: "origin/feature"
        )
        let request = ArborVCSActionRequest(
            kind: .rollbackMultiRootBranchRename,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootBranchRenameOldName: "feature",
            multiRootBranchRenameNewName: "feature-renamed",
            multiRootBranchRenameRollbackTargets: [target]
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(
            decoded.multiRootBranchRenameRollbackTargets?.first?.expectedNewTip,
            "2222222"
        )
        XCTAssertEqual(
            decoded.multiRootBranchRenameRollbackTargets?.first?.expectedCurrentBranch,
            "main"
        )

        let suiteName = "Arbor.FeedbackCenterMultiRootBranchRenameRollbackTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Multi-root branch rename partially completed",
            additionalActions: [
                FeedbackAction(
                    title: "Rollback Successful Roots",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testMultiRootMergeRollbackActionRoundTripsAndSurvivesReload() throws {
        let target = PersistedMultiRootMergeRollbackTarget(
            MultiRootMergeRollbackTarget(
                rootPath: "/project/app",
                displayName: "app",
                initialHead: "1111111",
                expectedHead: "2222222",
                operationPending: true
            )
        )
        let request = ArborVCSActionRequest(
            kind: .rollbackMultiRootMerge,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootMergeBranchName: "feature",
            multiRootMergeRollbackTargets: [target],
            multiRootMergeRollbackResultRows: [
                FeedbackResultRow(
                    rootPath: "/project/docs",
                    displayName: "docs",
                    state: .success,
                    detail: "Restored the original HEAD"
                )
            ]
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.multiRootMergeBranchName, "feature")
        XCTAssertEqual(decoded.multiRootMergeRollbackTargets?.first?.makeLiveTarget().expectedHead, "2222222")
        XCTAssertTrue(decoded.multiRootMergeRollbackTargets?.first?.operationPending == true)
        XCTAssertEqual(decoded.multiRootMergeRollbackResultRows?.first?.rootPath, "/project/docs")

        let suiteName = "Arbor.FeedbackCenterMultiRootMergeRollbackTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Multi-root merge partially completed",
            additionalActions: [
                FeedbackAction(
                    title: "Rollback Successful Roots",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testMultiRootMergeDeleteActionRoundTripsAndSurvivesReload() throws {
        let request = ArborVCSActionRequest(
            kind: .deleteMultiRootMergeBranch,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootMergeDeleteBranchName: "feature",
            multiRootMergeDeleteRootPaths: ["/project/docs", "/project/app"]
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.multiRootMergeDeleteBranchName, "feature")
        XCTAssertEqual(decoded.multiRootMergeDeleteRootPaths, ["/project/docs", "/project/app"])

        let suiteName = "Arbor.FeedbackCenterMultiRootMergeDeleteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.success(
            "Multi-root merge completed",
            additionalActions: [
                FeedbackAction(
                    title: "Delete branch",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testMultiRootMergeDeleteNotificationExpiresAfterAction() {
        let request = ArborVCSActionRequest(
            kind: .deleteMultiRootMergeBranch,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootMergeDeleteBranchName: "feature",
            multiRootMergeDeleteRootPaths: ["/project/app"]
        )
        let suiteName = "Arbor.FeedbackCenterMultiRootMergeDeleteExpiryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.success(
            "Multi-root merge completed",
            additionalActions: [
                FeedbackAction(title: "Delete branch", semanticAction: request) {}
            ],
            notificationID: "arbor.multi-root-merge.delete._project",
            localized: false
        )
        XCTAssertEqual(feedbackCenter.history.first?.actions.count, 1)

        feedbackCenter.expire(notificationID: "arbor.multi-root-merge.delete._project")

        XCTAssertTrue(feedbackCenter.history.first?.actions.isEmpty == true)
        XCTAssertNil(feedbackCenter.history.first?.notificationID)
    }

    @MainActor
    func testMultiRootMergeRollbackResultRowsPersistAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterMultiRootMergeRollbackRowsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let feedbackCenter = FeedbackCenter(defaults: defaults)
        let notificationID = "arbor.multi-root-merge.rollback._project"
        feedbackCenter.warning(
            "Multi-root merge rollback partially failed",
            detail: "Docs: HEAD changed after the merge",
            notificationID: notificationID,
            localized: false
        )
        let rows = [
            FeedbackResultRow(
                rootPath: "/project/app",
                displayName: "App",
                state: .success,
                detail: "Restored the original HEAD"
            ),
            FeedbackResultRow(
                rootPath: "/project/docs",
                displayName: "Docs",
                state: .failed,
                detail: "HEAD changed after the merge; rollback was skipped."
            )
        ]
        let retriedRows = [
            FeedbackResultRow(
                rootPath: "/project/docs",
                displayName: "Docs",
                state: .success,
                detail: "Restored the original HEAD"
            )
        ]
        let cumulativeRows = mergeFeedbackResultRows(
            preserved: rows,
            retry: retriedRows
        )
        XCTAssertEqual(cumulativeRows, [rows[0], retriedRows[0]])
        feedbackCenter.attachResultRows(cumulativeRows, notificationID: notificationID)

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.resultRows, cumulativeRows)
    }

    @MainActor
    func testBranchDeleteRestoreActionRoundTripsAndSurvivesReload() throws {
        let commit = PersistedBranchDeleteCommit(
            id: "2222222",
            shortID: "2222222",
            summary: "unmerged work",
            time: 1_700_000_000
        )
        let target = PersistedBranchDeleteRecoveryTarget(
            rootPath: "/project/app",
            branchName: "feature",
            tipID: "1111111",
            upstream: "origin/feature",
            baseBranches: ["main"],
            unmergedCommits: [commit]
        )
        let request = ArborVCSActionRequest(
            kind: .restoreDeletedBranches,
            projectPath: "/project",
            rootPath: "/project/app",
            shelfName: "",
            branchDeleteRecoveryTargets: [target]
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.branchDeleteRecoveryTargets?.first?.tipID, "1111111")
        XCTAssertEqual(decoded.branchDeleteRecoveryTargets?.first?.upstream, "origin/feature")
        XCTAssertEqual(decoded.branchDeleteRecoveryTargets?.first?.baseBranches, ["main"])
        XCTAssertEqual(decoded.branchDeleteRecoveryTargets?.first?.unmergedCommits, [commit])

        let suiteName = "Arbor.FeedbackCenterBranchDeleteRestoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.success(
            "Branch deleted",
            additionalActions: [
                FeedbackAction(
                    title: "Restore",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testBranchDeleteViewCommitsActionRoundTripsAndSurvivesReload() throws {
        let target = PersistedBranchDeleteRecoveryTarget(
            rootPath: "/project/app",
            branchName: "feature",
            tipID: "1111111",
            upstream: nil,
            baseBranches: ["main"],
            unmergedCommits: [
                PersistedBranchDeleteCommit(
                    id: "2222222",
                    shortID: "2222222",
                    summary: "unmerged work",
                    time: 1_700_000_000
                )
            ]
        )
        let request = ArborVCSActionRequest(
            kind: .viewDeletedBranchCommits,
            projectPath: "/project",
            rootPath: "/project/app",
            shelfName: "",
            branchDeleteRecoveryTargets: [target]
        )
        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)

        let suiteName = "Arbor.FeedbackCenterBranchDeleteViewCommitsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.success(
            "Branch deleted",
            additionalActions: [
                FeedbackAction(
                    title: "View Commits",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    func testMultiRootRetryActionRequestRoundTripsOperationAndRootScopes() throws {
        let request = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRetryOperation: .pushRecovery,
            multiRootRetryRootPaths: ["/project/app"],
            multiRootRetryUpdateRootPaths: ["/project/app", "/project/docs"],
            multiRootRetryRebase: true,
            multiRootRetryRebaseRootPaths: ["/project/app"],
            multiRootRetryLogRevisionRanges: [
                PersistedLogRevisionRange(
                    rootPath: "/project/app",
                    oldRevision: "old-app",
                    newRevision: "new-app"
                )
            ],
            multiRootRetryResultRows: [
                FeedbackResultRow(
                    rootPath: "/project/app",
                    displayName: "App",
                    state: .success,
                    detail: "pushed App"
                ),
                FeedbackResultRow(
                    rootPath: "/project/docs",
                    displayName: "Docs",
                    state: .failed,
                    detail: "push rejected"
                )
            ]
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.multiRootRetryOperation, .pushRecovery)
        XCTAssertEqual(decoded.multiRootRetryRootPaths, ["/project/app"])
        XCTAssertEqual(decoded.multiRootRetryUpdateRootPaths, ["/project/app", "/project/docs"])
        XCTAssertEqual(decoded.multiRootRetryRebase, true)
        XCTAssertEqual(decoded.multiRootRetryRebaseRootPaths, ["/project/app"])
        XCTAssertEqual(
            decoded.multiRootRetryLogRevisionRanges,
            [
                PersistedLogRevisionRange(
                    rootPath: "/project/app",
                    oldRevision: "old-app",
                    newRevision: "new-app"
                )
            ]
        )
        XCTAssertEqual(
            decoded.multiRootRetryResultRows,
            [
                FeedbackResultRow(
                    rootPath: "/project/app",
                    displayName: "App",
                    state: .success,
                    detail: "pushed App"
                ),
                FeedbackResultRow(
                    rootPath: "/project/docs",
                    displayName: "Docs",
                    state: .failed,
                    detail: "push rejected"
                )
            ]
        )
    }

    func testMultiRootForcePushRetryActionRoundTripsLeaseOptions() throws {
        let request = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRetryOperation: .push,
            multiRootRetryRootPaths: ["/project/app"],
            multiRootPushTagMode: .all,
            multiRootPushSkipHooks: true,
            multiRootPushForce: true,
            multiRootPushForceWithLease: true
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.multiRootPushTagMode, .all)
        XCTAssertEqual(decoded.multiRootPushSkipHooks, true)
        XCTAssertEqual(decoded.multiRootPushForce, true)
        XCTAssertEqual(decoded.multiRootPushForceWithLease, true)
    }

    func testMultiRootGenericRetryOperationsRoundTrip() throws {
        for operation in [
            ArborVCSActionRequest.MultiRootRetryOperation.fetch,
            .pullMerge,
            .pullRebase
        ] {
            let request = ArborVCSActionRequest(
                kind: .retryMultiRootOperation,
                projectPath: "/project",
                rootPath: nil,
                shelfName: "",
                multiRootRetryOperation: operation,
                multiRootRetryRootPaths: ["/project/app"]
            )
            let decoded = try JSONDecoder().decode(
                ArborVCSActionRequest.self,
                from: JSONEncoder().encode(request)
            )
            XCTAssertEqual(decoded, request)
            XCTAssertEqual(decoded.multiRootRetryOperation, operation)
            XCTAssertEqual(decoded.multiRootRetryRootPaths, ["/project/app"])
        }
    }

    func testGitRootsPullAllUsesPreservingUpdateRoute() {
        XCTAssertEqual(multiRootPullRebaseMode(.pullMerge), false)
        XCTAssertEqual(multiRootPullRebaseMode(.pullRebase), true)
        XCTAssertNil(multiRootPullRebaseMode(.fetch))
        XCTAssertNil(multiRootPullRebaseMode(.push))
        XCTAssertNil(multiRootPullRebaseMode(.commit))
    }

    func testSubmoduleRetryActionRequestRoundTripsCompleteOperationContext() throws {
        let retry = PersistedSubmoduleRetry(
            operation: .update,
            url: "https://example.com/lib.git",
            path: "vendor/lib",
            branch: "main",
            force: true,
            initFlag: true,
            recursive: true,
            remote: true
        )
        let request = ArborVCSActionRequest(
            kind: .retrySubmoduleOperation,
            projectPath: "/project",
            rootPath: "/project",
            shelfName: "",
            submoduleRetry: retry
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.submoduleRetry, retry)
        XCTAssertEqual(decoded.submoduleRetry?.operation, .update)
        XCTAssertEqual(decoded.submoduleRetry?.path, "vendor/lib")
        XCTAssertEqual(decoded.submoduleRetry?.recursive, true)
    }

    func testSubmoduleSyncRetryRequestRetainsTheSyncOperation() throws {
        let retry = PersistedSubmoduleRetry(operation: .sync)
        let request = ArborVCSActionRequest(
            kind: .retrySubmoduleOperation,
            projectPath: "/project",
            rootPath: "/project",
            shelfName: "",
            submoduleRetry: retry
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded.submoduleRetry?.operation, .sync)
        XCTAssertNil(decoded.submoduleRetry?.path)
    }

    func testSubmoduleDeinitUndoRequiresExpectedCleanStateAndRoundTrips() throws {
        let before = [
            SubmoduleInfo(
                path: "vendor/lib",
                headId: "child-head",
                state: .clean,
                branch: nil,
                dirty: false
            )
        ]
        let context = try XCTUnwrap(
            ContentView.submoduleDeinitUndoContext(
                path: "./vendor/lib",
                before: before,
                gitmodulesPresent: true,
                gitmodulesContents: "[submodule \"vendor/lib\"]\n"
            )
        )
        XCTAssertEqual(context.path, "vendor/lib")
        XCTAssertEqual(context.expectedHeadID, "child-head")

        let afterDeinit = [
            SubmoduleInfo(
                path: "vendor/lib",
                headId: "child-head",
                state: .uninitialized,
                branch: nil,
                dirty: false
            )
        ]
        XCTAssertNotNil(
            ContentView.submoduleDeinitUndoTargetAfterDeinit(
                context,
                modules: afterDeinit,
                gitmodulesPresent: true,
                gitmodulesContents: "[submodule \"vendor/lib\"]\n"
            )
        )
        XCTAssertNil(
            ContentView.submoduleDeinitUndoTargetAfterDeinit(
                context,
                modules: afterDeinit,
                gitmodulesPresent: true,
                gitmodulesContents: "changed"
            )
        )

        let restored = [
            SubmoduleInfo(
                path: "vendor/lib",
                headId: "child-head",
                state: .clean,
                branch: nil,
                dirty: false
            )
        ]
        XCTAssertTrue(
            ContentView.submoduleDeinitUndoTargetAfterRestore(
                context,
                modules: restored,
                gitmodulesPresent: true,
                gitmodulesContents: "[submodule \"vendor/lib\"]\n"
            )
        )

        let request = ArborVCSActionRequest(
            kind: .undoSubmoduleOperation,
            projectPath: "/project",
            rootPath: "/project",
            shelfName: "",
            submoduleUndo: context
        )
        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.submoduleUndo, context)
    }

    func testSubmoduleDeinitUndoIsNotProposedForDirtyBeforeState() {
        let dirty = [
            SubmoduleInfo(
                path: "vendor/lib",
                headId: "child-head",
                state: .clean,
                branch: nil,
                dirty: true
            )
        ]
        XCTAssertNil(
            ContentView.submoduleDeinitUndoContext(
                path: "vendor/lib",
                before: dirty,
                gitmodulesPresent: true,
                gitmodulesContents: "same"
            )
        )
    }

    func testSubmoduleAddUndoPersistsExpectedStateAndRejectsOccupiedPath() throws {
        let seed = try XCTUnwrap(
            ContentView.submoduleAddUndoSeed(
                path: "./vendor/lib",
                before: [],
                parentHeadID: "parent-head",
                gitmodulesPresent: false,
                gitmodulesContents: nil,
                pathExists: false
            )
        )
        let added = SubmoduleInfo(
            path: "vendor/lib",
            headId: "child-head",
            state: .clean,
            branch: nil,
            dirty: false
        )
        let context = try XCTUnwrap(
            ContentView.submoduleAddUndoContext(
                seed,
                module: added,
                gitmodulesPresent: true,
                gitmodulesContents: "[submodule \"vendor/lib\"]\n"
            )
        )
        XCTAssertEqual(context.operation, .add)
        XCTAssertEqual(context.expectedParentHeadID, "parent-head")
        XCTAssertEqual(context.restoreGitmodulesPresent, false)

        let request = ArborVCSActionRequest(
            kind: .undoSubmoduleOperation,
            projectPath: "/project",
            rootPath: "/project",
            shelfName: "",
            submoduleUndo: context
        )
        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)
        XCTAssertNil(
            ContentView.submoduleAddUndoSeed(
                path: "vendor/lib",
                before: [],
                parentHeadID: "parent-head",
                gitmodulesPresent: false,
                gitmodulesContents: nil,
                pathExists: true
            )
        )
        XCTAssertNil(
            ContentView.submoduleAddUndoContext(
                seed,
                module: SubmoduleInfo(
                    path: "vendor/lib",
                    headId: "child-head",
                    state: .clean,
                    branch: nil,
                    dirty: true
                ),
                gitmodulesPresent: true,
                gitmodulesContents: "[submodule \"vendor/lib\"]\n"
            )
        )
    }

    func testRewordUndoPersistsExpectedHeadAndDetachedBranchState() throws {
        let attached = PersistedRewordUndo(
            initialHeadID: "old-head",
            expectedHeadID: "reworded-head",
            expectedBranch: "main"
        )
        let request = ArborVCSActionRequest(
            kind: .undoRewordCommit,
            projectPath: "/project",
            rootPath: "/project",
            shelfName: "",
            rewordUndo: attached
        )
        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.rewordUndo, attached)

        let detached = PersistedRewordUndo(
            initialHeadID: "old-head",
            expectedHeadID: "reworded-head",
            expectedBranch: ""
        )
        XCTAssertNotEqual(attached, detached)
        XCTAssertEqual(detached.expectedBranch, "")
    }

    func testSubmoduleRemoveUndoPersistsCompareAndSwapStateAndLegacyDeinitPayloads() throws {
        let seed = ContentView.SubmoduleRemoveUndoSeed(
            path: "vendor/lib",
            parentHeadID: "parent-head",
            gitlinkID: "child-head",
            gitmodulesPresent: true,
            gitmodulesContents: "[submodule \"vendor/lib\"]\npath = vendor/lib\n"
        )
        let context = try XCTUnwrap(
            ContentView.submoduleRemoveUndoContextAfterRemove(
                seed,
                gitmodulesPresent: true,
                gitmodulesContents: ""
            )
        )
        XCTAssertEqual(context.operation, .remove)
        XCTAssertEqual(context.path, "vendor/lib")
        XCTAssertEqual(context.expectedHeadID, "child-head")
        XCTAssertEqual(context.expectedParentHeadID, "parent-head")
        XCTAssertEqual(context.expectedGitmodulesContents, "")
        XCTAssertEqual(context.restoreGitmodulesContents, seed.gitmodulesContents)

        let request = ArborVCSActionRequest(
            kind: .undoSubmoduleOperation,
            projectPath: "/project",
            rootPath: "/project",
            shelfName: "",
            submoduleUndo: context
        )
        let decodedRequest = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decodedRequest, request)

        let legacy = PersistedSubmoduleUndo(
            operation: .deinitialize,
            path: "vendor/lib",
            expectedHeadID: "child-head",
            expectedGitmodulesPresent: true,
            expectedGitmodulesContents: seed.gitmodulesContents
        )
        let decodedLegacy = try JSONDecoder().decode(
            PersistedSubmoduleUndo.self,
            from: JSONEncoder().encode(legacy)
        )
        XCTAssertEqual(decodedLegacy, legacy)
        XCTAssertNil(decodedLegacy.expectedParentHeadID)
        XCTAssertNil(decodedLegacy.restoreGitmodulesPresent)
        XCTAssertNil(decodedLegacy.restoreGitmodulesContents)
    }

    func testUpdateRootRecoveryTargetsStayRootQualifiedAndSkipSubmodules() {
        let results = [
            RootOperationResult(
                rootPath: "/workspace/app",
                displayName: "app",
                success: true,
                skipped: true,
                message: "no configured upstream"
            ),
            RootOperationResult(
                rootPath: "/workspace/vendor/lib",
                displayName: "lib",
                success: true,
                skipped: true,
                message: "detached HEAD"
            ),
            RootOperationResult(
                rootPath: "/workspace/docs",
                displayName: "docs",
                success: true,
                skipped: true,
                message: "detached HEAD"
            )
        ]
        let roots = [
            ContentView.UpdateRootRecoveryRoot(
                path: "/workspace/app",
                displayName: "app",
                isSubmodule: false,
                headBranch: "main"
            ),
            ContentView.UpdateRootRecoveryRoot(
                path: "/workspace/vendor/lib",
                displayName: "lib",
                isSubmodule: true,
                headBranch: nil
            ),
            ContentView.UpdateRootRecoveryRoot(
                path: "/workspace/docs",
                displayName: "docs",
                isSubmodule: false,
                headBranch: nil
            )
        ]

        let targets = ContentView.updateRootRecoveryTargets(results: results, roots: roots)

        XCTAssertEqual(targets, [
            ContentView.UpdateRootRecoveryTarget(
                kind: .chooseUpstream,
                rootPath: "/workspace/app",
                displayName: "app",
                branch: "main"
            ),
            ContentView.UpdateRootRecoveryTarget(
                kind: .openBranches,
                rootPath: "/workspace/docs",
                displayName: "docs",
                branch: nil
            )
        ])
    }

    func testStagingComparisonActionsRequireTheExpectedStatusDimensions() {
        let stagedOnly = FileEntry(
            path: "staged.txt",
            oldPath: nil,
            staged: .modified,
            unstaged: .unchanged
        )
        XCTAssertEqual(
            stagingComparisonActions(for: stagedOnly),
            [.stagedWithHead]
        )

        let partiallyStaged = FileEntry(
            path: "partial.txt",
            oldPath: nil,
            staged: .modified,
            unstaged: .modified
        )
        XCTAssertEqual(
            stagingComparisonActions(for: partiallyStaged),
            [.localWithStaged, .stagedWithLocal, .threeVersions, .stagedWithHead]
        )

        let untracked = FileEntry(
            path: "new.txt",
            oldPath: nil,
            staged: .unchanged,
            unstaged: .untracked
        )
        XCTAssertTrue(stagingComparisonActions(for: untracked).isEmpty)

        let stagedAdded = FileEntry(
            path: "new-staged.txt",
            oldPath: nil,
            staged: .added,
            unstaged: .modified
        )
        XCTAssertEqual(
            stagingComparisonActions(for: stagedAdded),
            [.localWithStaged, .stagedWithLocal]
        )

        let conflicted = FileEntry(
            path: "conflict.txt",
            oldPath: nil,
            staged: .conflicted,
            unstaged: .conflicted
        )
        XCTAssertTrue(stagingComparisonActions(for: conflicted).isEmpty)
    }

    func testStagingPreviewKeepsRequestedDimensionWhenAvailable() {
        XCTAssertEqual(
            resolvedStagingPreviewMode(preferred: .staged, available: [.unstaged, .staged]),
            .staged
        )
        XCTAssertEqual(
            resolvedStagingPreviewMode(preferred: .staged, available: [.unstaged]),
            .unstaged
        )
        XCTAssertNil(resolvedStagingPreviewMode(preferred: .unstaged, available: []))
    }

    func testDiffReadRejectsOlderPathGeneration() {
        XCTAssertFalse(
            isCurrentDiffRequest(
                path: "file.txt",
                generation: 2,
                currentPath: "file.txt",
                currentGeneration: 3
            )
        )
        XCTAssertFalse(
            isCurrentDiffRequest(
                path: "old.txt",
                generation: 3,
                currentPath: "new.txt",
                currentGeneration: 3
            )
        )
        XCTAssertTrue(
            isCurrentDiffRequest(
                path: "file.txt",
                generation: 3,
                currentPath: "file.txt",
                currentGeneration: 3
            )
        )
    }

    func testStagingPreviewLineModeUsesTheActiveDiffDimension() {
        XCTAssertEqual(stagingPreviewDiffMode(for: .unstaged), .worktreeToIndex)
        XCTAssertEqual(stagingPreviewDiffMode(for: .staged), .indexToHead)
    }

    func testStagingComparisonActionsUseTheReferenceStagingCoordinateSystem() {
        XCTAssertEqual(
            stagingComparisonDiffMode(for: .localWithStaged),
            .worktreeToIndex
        )
        XCTAssertEqual(
            stagingComparisonDiffMode(for: .stagedWithLocal),
            .worktreeToIndex
        )
        XCTAssertEqual(
            stagingComparisonDiffMode(for: .stagedWithHead),
            .indexToHead
        )
        XCTAssertNil(stagingComparisonDiffMode(for: .threeVersions))
    }

    func testStagingActionsUseExactVersionPresenceWhenAvailable() {
        let unstagedOnly = FileEntry(
            path: "unstaged.txt",
            oldPath: nil,
            staged: .unchanged,
            unstaged: .modified
        )
        XCTAssertEqual(
            stagingComparisonActions(
                for: unstagedOnly,
                presence: StagingVersionPresence(head: true, staged: true, local: true)
            ),
            [.localWithStaged, .stagedWithLocal, .threeVersions, .stagedWithHead]
        )

        let stagedAdded = FileEntry(
            path: "added.txt",
            oldPath: nil,
            staged: .added,
            unstaged: .modified
        )
        XCTAssertEqual(
            stagingComparisonActions(
                for: stagedAdded,
                presence: StagingVersionPresence(head: false, staged: true, local: true)
            ),
            [.localWithStaged, .stagedWithLocal]
        )

        let stagedDeletion = FileEntry(
            path: "deleted.txt",
            oldPath: nil,
            staged: .deleted,
            unstaged: .unchanged
        )
        XCTAssertTrue(
            stagingVersionActions(
                for: stagedDeletion,
                presence: StagingVersionPresence(head: true, staged: false, local: false)
            ).isEmpty
        )
    }

    func testStagingPreviewFileActionsRespectIndexAndWorktreeBoundaries() {
        let partiallyStaged = FileEntry(
            path: "partial.txt",
            oldPath: nil,
            staged: .modified,
            unstaged: .modified
        )
        XCTAssertEqual(
            stagingPreviewFileActions(for: partiallyStaged, mode: .unstaged),
            [.stage, .revertUnstaged]
        )
        XCTAssertEqual(
            stagingPreviewFileActions(for: partiallyStaged, mode: .staged),
            [.unstage]
        )

        let untracked = FileEntry(
            path: "new.txt",
            oldPath: nil,
            staged: .unchanged,
            unstaged: .untracked
        )
        XCTAssertEqual(
            stagingPreviewFileActions(for: untracked, mode: .unstaged),
            [.stage]
        )

        let conflicted = FileEntry(
            path: "conflict.txt",
            oldPath: nil,
            staged: .conflicted,
            unstaged: .conflicted
        )
        XCTAssertTrue(stagingPreviewFileActions(for: conflicted, mode: .unstaged).isEmpty)
        XCTAssertTrue(stagingPreviewFileActions(for: nil, mode: .staged).isEmpty)
    }

    func testStagingHunkActionsExposeStageUnstageAndRollbackPerDimension() {
        let diff = FileDiff(
            path: "partial.txt",
            binary: false,
            hunks: [DiffHunk(oldStart: 1, newStart: 1, oldLines: [], newLines: [])]
        )
        let partiallyStaged = FileEntry(
            path: "partial.txt",
            oldPath: nil,
            staged: .modified,
            unstaged: .modified
        )
        XCTAssertEqual(
            stagingHunkActions(for: partiallyStaged, mode: .unstaged, diff: diff),
            [.stage, .rollback]
        )
        XCTAssertEqual(
            stagingHunkActions(for: partiallyStaged, mode: .staged, diff: diff),
            [.unstage]
        )

        let untracked = FileEntry(
            path: "new.txt",
            oldPath: nil,
            staged: .unchanged,
            unstaged: .untracked
        )
        XCTAssertEqual(
            stagingHunkActions(for: untracked, mode: .unstaged, diff: diff),
            [.stage]
        )
        XCTAssertTrue(
            stagingHunkActions(for: partiallyStaged, mode: .unstaged,
                               diff: FileDiff(path: "partial.txt", binary: true, hunks: []))
                .isEmpty
        )
    }

    func testThreeVersionComparisonModesRouteHunksToTheCorrectStagingDimension() {
        XCTAssertNil(ThreeVersionComparisonMode.overview.diffMode)
        XCTAssertNil(ThreeVersionComparisonMode.overview.stagingMode)
        XCTAssertEqual(ThreeVersionComparisonMode.headToStaged.diffMode, .indexToHead)
        XCTAssertEqual(ThreeVersionComparisonMode.headToStaged.stagingMode, .staged)
        XCTAssertEqual(ThreeVersionComparisonMode.stagedToLocal.diffMode, .worktreeToIndex)
        XCTAssertEqual(ThreeVersionComparisonMode.stagedToLocal.stagingMode, .unstaged)
    }

    func testLineSelectionMapsDeletionAndPureInsertionToTheirOwnSides() {
        let selections = makeLineSelections(from: [
            SelectedDiffLine(hunkIndex: 1, oldLine: 7),
            SelectedDiffLine(hunkIndex: 1, oldLine: 0, newLine: 8)
        ])

        XCTAssertEqual(selections.count, 1)
        XCTAssertEqual(selections[0].hunkIndex, 1)
        XCTAssertEqual(selections[0].oldLines, [7])
        XCTAssertEqual(selections[0].newLines, [8])
    }

    func testStagingVersionActionsOnlyExposePresentVersions() {
        let partiallyStaged = FileEntry(
            path: "partial.txt",
            oldPath: nil,
            staged: .modified,
            unstaged: .modified
        )
        XCTAssertEqual(
            stagingVersionActions(for: partiallyStaged),
            [.local, .staged]
        )

        let deletedLocally = FileEntry(
            path: "deleted.txt",
            oldPath: nil,
            staged: .modified,
            unstaged: .deleted
        )
        XCTAssertEqual(
            stagingVersionActions(for: deletedLocally),
            [.staged]
        )

        let stagedDeletion = FileEntry(
            path: "removed.txt",
            oldPath: nil,
            staged: .deleted,
            unstaged: .unchanged
        )
        XCTAssertTrue(stagingVersionActions(for: stagedDeletion).isEmpty)
    }

    @MainActor
    func testFeedbackHistoryRestoresMultiRootRetryActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterMultiRootRetryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRetryOperation: .update,
            multiRootRetryRootPaths: ["/project/app"],
            multiRootRetryRebase: false
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Update partially completed",
            additionalActions: [
                FeedbackAction(
                    title: "Retry Failed Update Roots",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testFeedbackHistoryRestoresAggregatePullRetryWithPriorRanges() {
        let suiteName = "Arbor.FeedbackCenterAggregatePullRetryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRetryOperation: .pullMerge,
            multiRootRetryRootPaths: ["/project/app", "/project/lib"],
            multiRootRetryLogRevisionRanges: [
                PersistedLogRevisionRange(
                    rootPath: "/project/app",
                    oldRevision: "old-app",
                    newRevision: "new-app"
                )
            ]
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.error(
            "Multi-root Pull failed",
            additionalActions: [FeedbackAction(title: "Retry Pull Roots (Merge)", semanticAction: request) {}],
            notificationID: "arbor.multi-root-retry.pullMerge._project",
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.title, "Retry Pull Roots (Merge)")
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testFeedbackHistoryRestoresPushRecoveryRetryActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterPushRecoveryRetryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRetryOperation: .pushRecovery,
            multiRootRetryRootPaths: ["/project/app"],
            multiRootRetryUpdateRootPaths: ["/project/app", "/project/lib"],
            multiRootRetryRebase: true,
            multiRootPushTagMode: .all,
            multiRootPushSkipHooks: true
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.error(
            "Update Push Roots failed",
            additionalActions: [
                FeedbackAction(
                    title: "Retry Push Recovery",
                    semanticAction: request
                ) {}
            ],
            notificationID: "arbor.multi-root-retry.pushRecovery._project",
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.title, "Retry Push Recovery")
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    func testMultiRootCheckoutUpdateRetryActionRoundTripsCheckoutContext() throws {
        let request = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            checkoutReference: "origin/feature",
            multiRootRetryOperation: .checkoutUpdate,
            multiRootRetryRootPaths: ["/project/app"],
            multiRootRetryRebase: true,
            multiRootRetryDetach: false,
            multiRootRetryCheckoutMode: .smart
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.checkoutReference, "origin/feature")
        XCTAssertEqual(decoded.multiRootRetryOperation, .checkoutUpdate)
        XCTAssertEqual(decoded.multiRootRetryRootPaths, ["/project/app"])
        XCTAssertEqual(decoded.multiRootRetryRebase, true)
        XCTAssertEqual(decoded.multiRootRetryDetach, false)
        XCTAssertEqual(decoded.multiRootRetryCheckoutMode, .smart)
    }

    func testMultiRootChangesMutationRetryRequestsRoundTripRootAndPath() throws {
        let cases: [(ArborVCSActionRequest.MultiRootRetryOperation, String?)] = [
            (.stage, "Sources/App.swift"),
            (.unstage, "Sources/App.swift"),
            (.stageAll, nil),
            (.unstageAll, nil)
        ]

        for (operation, path) in cases {
            let request = ArborVCSActionRequest(
                kind: .retryMultiRootOperation,
                projectPath: "/project",
                rootPath: nil,
                shelfName: "",
                multiRootRetryOperation: operation,
                multiRootRetryRootPaths: ["/project/app"],
                multiRootRetryPath: path
            )
            let decoded = try JSONDecoder().decode(
                ArborVCSActionRequest.self,
                from: JSONEncoder().encode(request)
            )

            XCTAssertEqual(decoded, request)
            XCTAssertEqual(decoded.multiRootRetryOperation, operation)
            XCTAssertEqual(decoded.multiRootRetryRootPaths, ["/project/app"])
            XCTAssertEqual(decoded.multiRootRetryPath, path)
        }
    }

    func testMultiRootChangesBatchRetryPreservesRootQualifiedPaths() throws {
        let first = PersistedMultiRootChangePath(
            rootPath: "/project/app",
            path: "README.md"
        )
        let second = PersistedMultiRootChangePath(
            rootPath: "/project/lib",
            path: "README.md"
        )
        let request = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRetryOperation: .stage,
            multiRootRetryRootPaths: ["/project/app", "/project/lib"],
            multiRootRetryChangePaths: [first, second]
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.multiRootRetryChangePaths, [first, second])
        XCTAssertNotEqual(
            first.makeLiveSelection(),
            second.makeLiveSelection()
        )
    }

    @MainActor
    func testFeedbackHistoryRestoresMultiRootChangesMutationRetryActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterMultiRootChangesMutationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notificationID = "arbor.multi-root-changes.stage.project.app.Sources_App.swift"

        let request = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRetryOperation: .stage,
            multiRootRetryRootPaths: ["/project/app"],
            multiRootRetryPath: "Sources/App.swift"
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.error(
            "Stage failed",
            detail: "/project/app: Sources/App.swift",
            additionalActions: [
                FeedbackAction(
                    title: "Retry Stage",
                    semanticAction: request
                ) {}
            ],
            notificationID: notificationID,
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.title, "Retry Stage")
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)

        reloaded.success(
            "Changes staged",
            detail: "/project/app: Sources/App.swift",
            notificationID: notificationID,
            localized: false
        )
        XCTAssertEqual(reloaded.history.count, 1)
        XCTAssertEqual(reloaded.history.first?.title, "Changes staged")
        XCTAssertTrue(reloaded.history.first?.actions.isEmpty == true)
        XCTAssertEqual(reloaded.history.first?.notificationID, notificationID)
    }

    func testMultiRootCommitRetryRequestRoundTripsFullCommitContext() throws {
        let options = MultiRootCommitOptions(
            skipHooks: true,
            authorName: "Author",
            authorEmail: "author@example.com",
            committerName: "Committer",
            committerEmail: "committer@example.com",
            signOff: true,
            coAuthors: ["Co Author <co@example.com>"],
            amend: true,
            runBeforeCommitChecks: true,
            beforeCommitCommands: [
                MultiRootCommitCheck(command: "swift", args: ["test", "--parallel"])
            ]
        )
        let persisted = PersistedMultiRootCommitRetry(
            message: "release: retry failed roots",
            options: options,
            pushAfterCommit: true,
            pushRootPaths: ["/project/app"],
            selectedPaths: [
                PersistedMultiRootChangePath(
                    rootPath: "/project/app",
                    path: "Sources/App.swift",
                    oldPath: "Sources/LegacyApp.swift"
                ),
                PersistedMultiRootChangePath(
                    rootPath: "/project/lib",
                    path: "README.md"
                )
            ]
        )
        let request = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRetryOperation: .commit,
            multiRootRetryRootPaths: ["/project/app", "/project/lib"],
            multiRootCommitRetry: persisted
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.multiRootRetryOperation, .commit)
        XCTAssertEqual(decoded.multiRootRetryRootPaths, ["/project/app", "/project/lib"])
        XCTAssertEqual(decoded.multiRootCommitRetry?.message, persisted.message)
        XCTAssertEqual(decoded.multiRootCommitRetry?.pushAfterCommit, true)
        XCTAssertEqual(decoded.multiRootCommitRetry?.pushRootPaths, ["/project/app"])
        XCTAssertEqual(
            decoded.multiRootCommitRetry?.selectedPaths,
            persisted.selectedPaths
        )
        XCTAssertEqual(
            decoded.multiRootCommitRetry?.makeLiveOptions().beforeCommitCommands.first?.command,
            "swift"
        )
        XCTAssertEqual(
            decoded.multiRootCommitRetry?.makeLiveOptions().beforeCommitCommands.first?.args,
            ["test", "--parallel"]
        )
        XCTAssertEqual(decoded.multiRootCommitRetry?.makeLiveOptions().authorEmail, options.authorEmail)
        XCTAssertEqual(decoded.multiRootCommitRetry?.makeLiveOptions().amend, options.amend)

        let pushRequest = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRetryOperation: .pushAfterCommit,
            multiRootRetryRootPaths: ["/project/app"]
        )
        let decodedPushRequest = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(pushRequest)
        )
        XCTAssertEqual(decodedPushRequest, pushRequest)
        XCTAssertEqual(decodedPushRequest.multiRootRetryOperation, .pushAfterCommit)
    }

    func testMultiRootCommitAndPushOnlyStartsPushAfterAnAllSuccessfulCommitPhase() {
        XCTAssertTrue(
            shouldAutomaticallyOpenMultiRootCommitPushOptions(
                pushAfterCommit: true,
                pushRootPaths: ["/project/app"],
                failedRootPaths: []
            )
        )
        XCTAssertFalse(
            shouldAutomaticallyOpenMultiRootCommitPushOptions(
                pushAfterCommit: true,
                pushRootPaths: ["/project/app"],
                failedRootPaths: ["/project/lib"]
            )
        )
        XCTAssertFalse(
            shouldAutomaticallyOpenMultiRootCommitPushOptions(
                pushAfterCommit: true,
                pushRootPaths: [],
                failedRootPaths: []
            )
        )
        XCTAssertFalse(
            shouldAutomaticallyOpenMultiRootCommitPushOptions(
                pushAfterCommit: false,
                pushRootPaths: ["/project/app"],
                failedRootPaths: []
            )
        )
    }

    func testAggregateAuthenticationFailureMessageMatchesSingleRootClassification() {
        XCTAssertTrue(arborAuthenticationFailureMessage("fatal: Authentication failed for 'https://github.com/acme/repo.git'"))
        XCTAssertTrue(arborAuthenticationFailureMessage("fatal: could not read Username for 'https://github.com/acme/repo.git'"))
        XCTAssertTrue(arborAuthenticationFailureMessage("git@github.com: Permission denied (publickey)."))
        XCTAssertTrue(arborAuthenticationFailureMessage("remote returned HTTP 401"))
        XCTAssertFalse(arborAuthenticationFailureMessage("remote rejected the update because it is not a fast-forward"))
        XCTAssertFalse(arborAuthenticationFailureMessage("credential helper returned an empty response"))
    }

    @MainActor
    func testFeedbackHistoryRestoresMultiRootCommitRetryActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterMultiRootCommitRetryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRetryOperation: .commit,
            multiRootRetryRootPaths: ["/project/app"],
            multiRootCommitRetry: PersistedMultiRootCommitRetry(
                message: "retry commit",
                options: MultiRootCommitOptions(
                    skipHooks: false,
                    authorName: nil,
                    authorEmail: nil,
                    committerName: nil,
                    committerEmail: nil,
                    signOff: false,
                    coAuthors: [],
                    amend: false,
                    runBeforeCommitChecks: true,
                    beforeCommitCommands: []
                )
            )
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Multi-root commit partially completed",
            additionalActions: [
                FeedbackAction(
                    title: "Retry Failed Commits",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testFeedbackHistoryRestoresCatastrophicCommitRetryContextAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterCatastrophicCommitRetryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let options = MultiRootCommitOptions(
            skipHooks: true,
            authorName: "Author",
            authorEmail: "author@example.com",
            committerName: nil,
            committerEmail: nil,
            signOff: true,
            coAuthors: [],
            amend: false,
            runBeforeCommitChecks: false,
            beforeCommitCommands: []
        )
        let request = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRetryOperation: .commit,
            multiRootRetryRootPaths: ["/project/app"],
            multiRootCommitRetry: PersistedMultiRootCommitRetry(
                message: "release",
                options: options,
                pushAfterCommit: true,
                pushRootPaths: ["/project/lib"]
            )
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.error(
            "Multi-root commit failed",
            additionalActions: [
                FeedbackAction(
                    title: "Retry Failed Commits",
                    semanticAction: request
                ) {}
            ],
            notificationID: "arbor.multi-root-retry.commit._project",
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.title, "Retry Failed Commits")
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
        XCTAssertEqual(reloaded.history.first?.notificationID, "arbor.multi-root-retry.commit._project")
    }

    @MainActor
    func testFeedbackHistoryRestoresMultiRootCommitPushActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterMultiRootCommitPushTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRetryOperation: .pushAfterCommit,
            multiRootRetryRootPaths: ["/project/app", "/project/lib"]
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.success(
            "Multi-root commit complete",
            additionalActions: [
                FeedbackAction(
                    title: "Push Committed Roots",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.title, "Push Committed Roots")
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testMultiRootCommitPushKeepsFailedCommitRecoveryAlongsidePushNotification() {
        let suiteName = "Arbor.FeedbackCenterMultiRootCommitPushRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let retryRequest = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRetryOperation: .commit,
            multiRootRetryRootPaths: ["/project/lib"]
        )
        let pushRequest = ArborVCSActionRequest(
            kind: .retryMultiRootOperation,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRetryOperation: .pushAfterCommit,
            multiRootRetryRootPaths: ["/project/app"]
        )
        let commitNotificationID = "arbor.multi-root-retry.commit._project"
        let pushNotificationID = "arbor.multi-root-retry.push._project"
        let feedbackCenter = FeedbackCenter(defaults: defaults)

        feedbackCenter.warning(
            "Multi-root commit partially completed",
            additionalActions: [FeedbackAction(title: "Retry Failed Commits", semanticAction: retryRequest) {}],
            notificationID: commitNotificationID,
            localized: false
        )
        feedbackCenter.success(
            "Multi-root Push completed",
            additionalActions: [FeedbackAction(title: "Push Committed Roots", semanticAction: pushRequest) {}],
            notificationID: pushNotificationID,
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        let commitEntry = reloaded.history.first { $0.notificationID == commitNotificationID }
        let pushEntry = reloaded.history.first { $0.notificationID == pushNotificationID }
        XCTAssertEqual(commitEntry?.actions.first?.title, "Retry Failed Commits")
        XCTAssertEqual(commitEntry?.actions.first?.semanticAction, retryRequest)
        XCTAssertEqual(pushEntry?.actions.first?.title, "Push Committed Roots")
        XCTAssertEqual(pushEntry?.actions.first?.semanticAction, pushRequest)
    }

    @MainActor
    func testCommitRewordActionRoundTripsRootAndHeadAcrossReload() throws {
        let request = ArborVCSActionRequest(
            kind: .rewordCommit,
            projectPath: "/project",
            rootPath: "/project/nested",
            shelfName: "",
            rewordCommitID: "0123456789abcdef"
        )
        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)

        let suiteName = "Arbor.FeedbackCenterCommitRewordTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.success(
            "Commit completed",
            additionalActions: [
                FeedbackAction(
                    title: "Reword Commit",
                    semanticAction: request
                ) {}
            ],
            notificationID: "arbor.commit._project_nested",
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.title, "Reword Commit")
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
        XCTAssertEqual(reloaded.history.first?.notificationID, "arbor.commit._project_nested")
    }

    func testSingleRootPushRecoveryRequestRoundTripsExpectedBranch() throws {
        let recovery = PersistedPushRecovery(
            remote: "origin",
            branch: "feature/login",
            force: false,
            forceWithLease: true,
            setUpstream: true,
            tagModeRaw: PushDialogTagMode.currentBranch.rawValue,
            skipHooks: true,
            rebase: true
        )
        let request = ArborVCSActionRequest(
            kind: .retryPushRecovery,
            projectPath: "/project",
            rootPath: "/project/app",
            shelfName: "",
            pushRecovery: recovery,
            logRevisionRanges: [PersistedLogRevisionRange(
                rootPath: "/project/app",
                oldRevision: "base",
                newRevision: "local-tip"
            )]
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.pushRecovery?.remote, "origin")
        XCTAssertEqual(decoded.pushRecovery?.branch, "feature/login")
        XCTAssertEqual(decoded.pushRecovery?.tagModeRaw, "currentBranch")
        XCTAssertEqual(decoded.pushRecovery?.rebase, true)
        XCTAssertEqual(decoded.logRevisionRanges?.first?.oldRevision, "base")
        XCTAssertEqual(decoded.logRevisionRanges?.first?.newRevision, "local-tip")
    }

    func testSingleRootPushRetryAndShowDetailsRequestsRoundTripAcrossReload() throws {
        let push = PersistedPushRecovery(
            remote: "origin",
            branch: "feature/login",
            force: true,
            forceWithLease: false,
            setUpstream: false,
            refspec: "refs/heads/feature/login:refs/heads/release",
            tagModeRaw: PushDialogTagMode.all.rawValue,
            skipHooks: true,
            rebase: false
        )
        let retry = ArborVCSActionRequest(
            kind: .retryPush,
            projectPath: "/project",
            rootPath: "/project/app",
            shelfName: "",
            pushRecovery: push,
            logRevisionRanges: [PersistedLogRevisionRange(
                rootPath: "/project/app",
                oldRevision: "base",
                newRevision: "local-tip"
            )]
        )
        let details = ArborVCSActionRequest(
            kind: .showOperationDetails,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            operationNotificationID: "arbor.push.v1.project-app"
        )

        let decodedRetry = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(retry)
        )
        let decodedDetails = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(details)
        )

        XCTAssertEqual(decodedRetry, retry)
        XCTAssertEqual(decodedRetry.pushRecovery?.refspec, push.refspec)
        XCTAssertEqual(decodedRetry.pushRecovery?.force, true)
        XCTAssertEqual(decodedDetails, details)
        XCTAssertEqual(decodedDetails.operationNotificationID, "arbor.push.v1.project-app")
    }

    func testDetachedRefspecPushRetryPayloadDoesNotRequireBranch() throws {
        let push = PersistedPushRecovery(
            remote: "origin",
            branch: "",
            force: false,
            forceWithLease: false,
            setUpstream: false,
            refspec: "refs/tags/v1:refs/tags/v1",
            tagModeRaw: nil,
            skipHooks: false,
            rebase: false
        )
        let request = ArborVCSActionRequest(
            kind: .retryPush,
            projectPath: "/project",
            rootPath: "/project/app",
            shelfName: "",
            pushRecovery: push
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.pushRecovery?.branch, "")
        XCTAssertEqual(decoded.pushRecovery?.refspec, push.refspec)
    }

    func testMultiRootPushGroupsRejectionsSeparatelyFromTransportErrors() {
        let rejected = RootOperationResult(
            rootPath: "/project/app",
            displayName: "app",
            success: false,
            skipped: false,
            message: "push rejected for origin/main: non-fast-forward"
        )
        let stale = RootOperationResult(
            rootPath: "/project/lib",
            displayName: "lib",
            success: false,
            skipped: false,
            message: "push rejected: stale info"
        )
        let authentication = RootOperationResult(
            rootPath: "/project/auth",
            displayName: "auth",
            success: false,
            skipped: false,
            message: "push rejected: authentication failed"
        )

        XCTAssertTrue(pushResultIsRejected(rejected))
        XCTAssertTrue(pushResultIsRejected(stale))
        XCTAssertFalse(pushResultIsRejected(authentication))
    }

    @MainActor
    func testFeedbackBeginReusesStableNotificationHistoryEntryForRetry() {
        let suiteName = "Arbor.FeedbackCenterStableRetryHistoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notificationID = "arbor.multi-root-retry.fetch./project"

        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Fetch All partially completed",
            notificationID: notificationID,
            localized: false
        )
        feedbackCenter.begin("Retry Fetch All", notificationID: notificationID)
        feedbackCenter.success(
            "Fetch All completed",
            detail: "1 ok",
            notificationID: notificationID,
            localized: false
        )

        XCTAssertEqual(feedbackCenter.history.count, 1)
        XCTAssertEqual(feedbackCenter.history.first?.title, "Fetch All completed")
        XCTAssertEqual(feedbackCenter.history.first?.notificationID, notificationID)
    }

    @MainActor
    func testPushAllRecoveryActionsStayOnTheOriginalNotification() {
        let suiteName = "Arbor.FeedbackCenterPushAllRecoveryNotificationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let notificationID = "arbor.multi-root-retry.push./project"
        let feedbackCenter = FeedbackCenter(defaults: defaults)

        feedbackCenter.begin("Push All", notificationID: notificationID)
        feedbackCenter.warning(
            "Multi-root Push partially completed",
            detail: "root-a: non-fast-forward",
            additionalActions: [FeedbackAction(title: "Update with Merge") {}],
            notificationID: notificationID,
            localized: false
        )

        XCTAssertEqual(feedbackCenter.history.count, 1)
        XCTAssertEqual(feedbackCenter.history.first?.title, "Multi-root Push partially completed")
        XCTAssertEqual(feedbackCenter.history.first?.notificationID, notificationID)
    }

    @MainActor
    func testCompoundRetryNotificationIDsAvoidWorkingHistoryRows() {
        let suiteName = "Arbor.FeedbackCenterCompoundRetryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let updatePartialID = "git.project.partially.updated._project"
        let updateCompletedID = "git.project.updated._project"
        let checkoutID = "arbor.multi-root-retry.checkoutUpdate._project"
        let feedbackCenter = FeedbackCenter(defaults: defaults)

        feedbackCenter.warning(
            "Update Project partially completed",
            notificationID: updatePartialID,
            localized: false
        )
        feedbackCenter.begin("Retry Update Project", notificationID: updateCompletedID)
        feedbackCenter.success(
            "Update Project completed",
            notificationID: updateCompletedID,
            localized: false
        )
        XCTAssertEqual(feedbackCenter.history.first?.title, "Update Project completed")
        XCTAssertFalse(feedbackCenter.history.contains { $0.title == "Working…" })

        feedbackCenter.warning(
            "Checkout and Update partially completed",
            notificationID: checkoutID,
            localized: false
        )
        feedbackCenter.begin("Retry Checkout and Update", notificationID: checkoutID)
        feedbackCenter.success(
            "Checkout and Update completed",
            notificationID: checkoutID,
            localized: false
        )
        XCTAssertEqual(feedbackCenter.history.first?.title, "Checkout and Update completed")
        XCTAssertFalse(feedbackCenter.history.contains { $0.title == "Working…" })

        let rollbackID = "arbor.multi-root-checkout.rollback._project"
        feedbackCenter.warning(
            "Checkout rollback partially failed",
            additionalActions: [FeedbackAction(title: "Retry Checkout Rollback") {}],
            notificationID: rollbackID,
            localized: false
        )
        feedbackCenter.begin("Rollback multi-root checkout", notificationID: rollbackID)
        feedbackCenter.success(
            "Checkout rollback completed",
            notificationID: rollbackID,
            localized: false
        )
        XCTAssertEqual(feedbackCenter.history.first?.title, "Checkout rollback completed")
        XCTAssertEqual(feedbackCenter.history.first?.notificationID, rollbackID)
        XCTAssertFalse(feedbackCenter.history.contains { $0.title == "Working…" })
    }

    func testMultiRootRebaseRecoveryActionRequestsRoundTripAllRecoveryModes() throws {
        let rollbackTarget = PersistedMultiRootRebaseRollbackTarget(
            MultiRootRebaseRollbackTarget(
                rootPath: "/project/app",
                displayName: "app",
                initialHead: "1111111",
                expectedHead: "2222222",
                branch: "feature",
                protectionCommitID: "first-changed"
            )
        )
        let sessionID = UUID().uuidString
        for action in [
            ArborVCSActionRequest.MultiRootRebaseRecoveryAction.resume,
            .retry,
            .stageAndRetry,
            .openRecovery,
            .rollback,
            .keepPartial,
            .undo
        ] {
            let request = ArborVCSActionRequest(
                kind: .multiRootRebaseRecovery,
                projectPath: "/project",
                rootPath: action == .openRecovery || action == .stageAndRetry ? "/project/app" : nil,
                shelfName: "",
                multiRootRebaseRecoveryAction: action,
                multiRootRebaseSessionID: action == .undo ? nil : sessionID,
                multiRootRebaseRollbackTargets: action == .undo ? [rollbackTarget] : nil
            )

            let decoded = try JSONDecoder().decode(
                ArborVCSActionRequest.self,
                from: JSONEncoder().encode(request)
            )

            XCTAssertEqual(decoded, request)
            XCTAssertEqual(decoded.multiRootRebaseRecoveryAction, action)
            XCTAssertEqual(decoded.multiRootRebaseSessionID, request.multiRootRebaseSessionID)
            XCTAssertEqual(decoded.multiRootRebaseRollbackTargets, request.multiRootRebaseRollbackTargets)
        }
    }

    func testOperationRecoveryActionRequestRoundTripsAllOperationModes() throws {
        for action in [
            ArborVCSActionRequest.OperationRecoveryAction.continueOperation,
            .skip,
            .abort,
            .openRecovery
        ] {
            let request = ArborVCSActionRequest(
                kind: .operationRecovery,
                projectPath: "/project",
                rootPath: "/project/app",
                shelfName: "",
                operationRecoveryAction: action
            )

            let decoded = try JSONDecoder().decode(
                ArborVCSActionRequest.self,
                from: JSONEncoder().encode(request)
            )

            XCTAssertEqual(decoded, request)
            XCTAssertEqual(decoded.operationRecoveryAction, action)
            XCTAssertEqual(decoded.rootPath, "/project/app")
        }
    }

    func testUncommitUndoActionRequestRoundTripsBranchAndHeadScope() throws {
        let request = ArborVCSActionRequest(
            kind: .undoUncommit,
            projectPath: "/project",
            rootPath: "/project/app",
            shelfName: "",
            uncommitCommitID: "0123456789abcdef",
            uncommitExpectedHead: "fedcba9876543210",
            uncommitExpectedBranch: "main"
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.kind, .undoUncommit)
        XCTAssertEqual(decoded.uncommitExpectedBranch, "main")
    }

    @MainActor
    func testFeedbackHistoryRestoresUncommitUndoActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterUncommitUndoTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .undoUncommit,
            projectPath: "/project",
            rootPath: "/project/app",
            shelfName: "",
            uncommitCommitID: "0123456789abcdef",
            uncommitExpectedHead: "fedcba9876543210",
            uncommitExpectedBranch: "main"
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.success(
            "Latest commit undone",
            additionalActions: [
                FeedbackAction(
                    title: "Undo Uncommit",
                    semanticAction: request
                ) {}
            ],
            notificationID: "arbor.uncommit-undo._project_app"
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testFeedbackHistoryRestoresOperationRecoveryActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterOperationRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .operationRecovery,
            projectPath: "/project",
            rootPath: "/project/app",
            shelfName: "",
            operationRecoveryAction: .abort
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Rebase recovery available",
            additionalActions: [
                FeedbackAction(
                    title: "Abort",
                    semanticAction: request
                ) {}
            ],
            notificationID: "arbor.operation-recovery._project_app",
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    func testAutoFetchRecoveryActionRequestRoundTripsRootScope() throws {
        for action in [
            ArborVCSActionRequest.AutoFetchRecoveryAction.fetchAll,
            .retryCheck,
            .enable,
            .doNotAskAgain
        ] {
            let request = ArborVCSActionRequest(
                kind: .autoFetchRecovery,
                projectPath: "/project",
                rootPath: "/project/app",
                shelfName: "",
                autoFetchRecoveryAction: action,
                autoFetchRootPaths: ["/project/app", "/project/docs"]
            )

            let decoded = try JSONDecoder().decode(
                ArborVCSActionRequest.self,
                from: JSONEncoder().encode(request)
            )

            XCTAssertEqual(decoded, request)
            XCTAssertEqual(decoded.autoFetchRecoveryAction, action)
            XCTAssertEqual(decoded.autoFetchRootPaths, ["/project/app", "/project/docs"])
        }
    }

    @MainActor
    func testFeedbackHistoryRestoresAutoFetchActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterAutoFetchRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .autoFetchRecovery,
            projectPath: "/project",
            rootPath: "/project/app",
            shelfName: "",
            autoFetchRecoveryAction: .fetchAll,
            autoFetchRootPaths: ["/project/app", "/project/docs"]
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Incoming changes available",
            additionalActions: [
                FeedbackAction(
                    title: "Fetch All",
                    semanticAction: request
                ) {}
            ],
            notificationID: "git.fetch._project.incoming",
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testFeedbackHistoryRestoresMultiRootRebaseRecoveryActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterMultiRootRebaseTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .multiRootRebaseRecovery,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            multiRootRebaseRecoveryAction: .undo,
            multiRootRebaseRollbackTargets: [
                PersistedMultiRootRebaseRollbackTarget(
                    MultiRootRebaseRollbackTarget(
                        rootPath: "/project/app",
                        displayName: "app",
                        initialHead: "1111111",
                        expectedHead: "2222222",
                        branch: "feature"
                    )
                )
            ]
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Multi-root rebase recovery available",
            additionalActions: [
                FeedbackAction(
                    title: "Undo Rebase",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testFeedbackHistoryRestoresMultiRootRebaseStageAndRetryActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterMultiRootRebaseStageRetryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .multiRootRebaseRecovery,
            projectPath: "/project",
            rootPath: "/project/app",
            shelfName: "",
            multiRootRebaseRecoveryAction: .stageAndRetry,
            multiRootRebaseSessionID: UUID().uuidString
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.error(
            "Multi-root recovery failed",
            additionalActions: [
                FeedbackAction(
                    title: "Stage-and-Retry",
                    semanticAction: request
                ) {}
            ],
            notificationID: "arbor.multi-root-rebase.stage-retry",
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    func testFindMergedReportKeepsRootErrorsAndStableRows() {
        let merged = BranchInfo(
            name: "feature/merged",
            isCurrent: false,
            shortId: "1234567",
            lastCommitTime: 10
        )
        let okRoot = BranchCleanupRoot(
            rootPath: "/project/app",
            displayName: "app",
            relativePath: ".",
            branches: [merged],
            trackingByBranch: [:],
            mergedBranches: [merged.name],
            calculatedTarget: "main",
            calculatedPrefix: "feature/",
            calculationError: nil
        )
        let failedRoot = BranchCleanupRoot(
            rootPath: "/project/tools",
            displayName: "tools",
            relativePath: "tools",
            branches: [],
            trackingByBranch: [:],
            mergedBranches: [],
            calculatedTarget: nil,
            calculatedPrefix: nil,
            calculationError: "target branch 'main' was not found"
        )
        let summary = FindMergedScanSummary(
            targetBranch: "main",
            prefix: "feature/",
            repositoriesDiscovered: 2,
            repositoriesScanned: 1,
            candidateBranchesChecked: 1,
            mergedBranchesFound: 1,
            errors: ["tools: target branch 'main' was not found"],
            elapsedMilliseconds: 7,
            isCancelled: false
        )

        let report = findMergedBranchesReportText(
            summary: summary,
            roots: [failedRoot, okRoot],
            projectName: "project"
        )

        XCTAssertEqual(
            mergedBranchNames(in: okRoot, targetBranch: "main", prefix: "feature/"),
            ["feature/merged"]
        )
        XCTAssertTrue(report.contains("Root: /project/app"))
        XCTAssertTrue(report.contains("  feature/merged"))
        XCTAssertTrue(report.contains("Root: /project/tools"))
        XCTAssertTrue(report.contains("  Error: target branch 'main' was not found"))
        XCTAssertTrue(report.contains("Project: project"))
        XCTAssertTrue(report.contains("Repositories scanned: 1"))
        XCTAssertTrue(report.contains("Errors count: 1"))
    }

    func testFindMergedSkipsRootsWithoutTheTargetBranch() {
        let target = BranchInfo(
            name: "main",
            isCurrent: true,
            shortId: "target",
            lastCommitTime: 10
        )
        let matching = BranchCleanupRoot(
            rootPath: "/project/app",
            displayName: "app",
            relativePath: ".",
            branches: [target],
            trackingByBranch: [:],
            mergedBranches: [],
            calculatedTarget: nil,
            calculatedPrefix: nil,
            calculationError: nil
        )
        let unrelated = BranchCleanupRoot(
            rootPath: "/project/tools",
            displayName: "tools",
            relativePath: "tools",
            branches: [
                BranchInfo(
                    name: "develop",
                    isCurrent: true,
                    shortId: "develop",
                    lastCommitTime: 10
                )
            ],
            trackingByBranch: [:],
            mergedBranches: [],
            calculatedTarget: nil,
            calculatedPrefix: nil,
            calculationError: nil
        )

        XCTAssertEqual(
            ContentView.findMergedRootsContainingTarget("main", in: [matching, unrelated])
                .map(\.rootPath),
            ["/project/app"]
        )
    }

    func testCleanupBranchesClipboardUsesIntellijTableColumnsAndOrder() {
        let rows = [
            BranchCleanupClipboardRow(
                branchName: "feature/z",
                lastCommitDate: "Aug 21, 2026 at 10:00 AM",
                trackedBranch: "origin/feature/z"
            ),
            BranchCleanupClipboardRow(
                branchName: "feature/a",
                lastCommitDate: "",
                trackedBranch: ""
            )
        ]

        XCTAssertEqual(
            formattedBranchCleanupClipboardRows(rows),
            "feature/z\tAug 21, 2026 at 10:00 AM\torigin/feature/z\nfeature/a\t\t"
        )
    }

    func testCleanupBranchesCopyUsesTableRowsNotDeleteCheckboxSelection() {
        let ordered = [
            BranchCleanupSelection(rootPath: "/project/app", branchName: "feature/a"),
            BranchCleanupSelection(rootPath: "/project/app", branchName: "feature/b"),
            BranchCleanupSelection(rootPath: "/project/tools", branchName: "feature/a")
        ]

        XCTAssertEqual(
            branchCleanupSelectedRows(
                ordered,
                selected: [
                    BranchCleanupSelection(rootPath: "/project/tools", branchName: "feature/a"),
                    BranchCleanupSelection(rootPath: "/project/app", branchName: "feature/b")
                ]
            ),
            [
                BranchCleanupSelection(rootPath: "/project/app", branchName: "feature/b"),
                BranchCleanupSelection(rootPath: "/project/tools", branchName: "feature/a")
            ]
        )
    }

    func testFindMergedReportMarksCancelledScans() {
        let summary = FindMergedScanSummary(
            targetBranch: "main",
            prefix: "",
            repositoriesDiscovered: 3,
            repositoriesScanned: 1,
            candidateBranchesChecked: 2,
            mergedBranchesFound: 1,
            errors: [],
            elapsedMilliseconds: 12,
            isCancelled: true
        )

        let report = findMergedBranchesReportText(
            summary: summary,
            roots: [],
            projectName: "project"
        )

        XCTAssertTrue(report.contains("Status: Cancelled"))
        XCTAssertTrue(report.contains("Repositories discovered: 3"))
    }

    func testFindMergedReportPersistsAndSemanticActionRoundTrips() throws {
        let suiteName = "FindMergedReportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let saved = PersistedFindMergedReport(
            id: "report-1",
            projectPath: "/workspace/project",
            targetBranch: "main",
            prefix: "feature/",
            report: "=== Merged local branches into 'main' ===\n",
            createdAt: Date(timeIntervalSince1970: 42)
        )

        FindMergedReportStore.save(saved, defaults: defaults)
        XCTAssertEqual(FindMergedReportStore.load(id: saved.id, defaults: defaults), saved)

        let request = ArborVCSActionRequest(
            kind: .showFindMergedReport,
            projectPath: saved.projectPath,
            rootPath: nil,
            shelfName: "",
            findMergedReportID: saved.id
        )
        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ArborVCSActionRequest.self, from: encoded)
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.findMergedReportID, saved.id)
    }

    func testSelectionFollowsTreeDiffOrder() {
        let selected = orderedCompareSelection(
            changes: changes,
            selectedPaths: ["Tests/AppTests.swift", "Sources/App.swift"]
        )

        XCTAssertEqual(selected.map(\.path), ["Sources/App.swift", "Tests/AppTests.swift"])
    }

    func testSelectionDropsPathsThatAreNoLongerInComparison() {
        let selected = orderedCompareSelection(
            changes: changes,
            selectedPaths: ["README.md", "stale.txt"]
        )

        XCTAssertEqual(selected.map(\.path), ["README.md"])
    }

    func testEmptySelectionHasNoChanges() {
        XCTAssertTrue(orderedCompareSelection(changes: changes, selectedPaths: []).isEmpty)
    }

    func testAdjacentChangeNavigationStopsAtBothBoundaries() {
        XCTAssertEqual(adjacentChangeIndex(count: 3, current: 1, offset: -1), 0)
        XCTAssertEqual(adjacentChangeIndex(count: 3, current: 1, offset: 1), 2)
        XCTAssertNil(adjacentChangeIndex(count: 3, current: 0, offset: -1))
        XCTAssertNil(adjacentChangeIndex(count: 3, current: 2, offset: 1))
    }

    func testAdjacentChangeNavigationRejectsInvalidRows() {
        XCTAssertNil(adjacentChangeIndex(count: 0, current: 0, offset: 1))
        XCTAssertNil(adjacentChangeIndex(count: 2, current: -1, offset: 1))
        XCTAssertNil(adjacentChangeIndex(count: 2, current: 2, offset: -1))
    }

    func testKeyboardChangeIndexStartsAtVisibleBoundaryWithoutSelection() {
        XCTAssertEqual(keyboardChangeIndex(count: 3, current: nil, offset: 1), 0)
        XCTAssertEqual(keyboardChangeIndex(count: 3, current: nil, offset: -1), 2)
        XCTAssertNil(keyboardChangeIndex(count: 0, current: nil, offset: 1))
        XCTAssertNil(keyboardChangeIndex(count: 3, current: nil, offset: 0))
    }

    func testKeyboardChangeIndexUsesAdjacentSelectionOnceFocused() {
        XCTAssertEqual(keyboardChangeIndex(count: 3, current: 1, offset: -1), 0)
        XCTAssertEqual(keyboardChangeIndex(count: 3, current: 1, offset: 1), 2)
        XCTAssertNil(keyboardChangeIndex(count: 3, current: 0, offset: -1))
        XCTAssertNil(keyboardChangeIndex(count: 3, current: 2, offset: 1))
    }

    func testShelfTreeGroupsDirectoriesAndKeepsFilesStable() {
        let rows = shelfTreeRows(
            paths: ["Sources/Z.swift", "README.md", "Sources/App.swift", "Tests/AppTests.swift"],
            groupByDirectory: true
        )

        XCTAssertEqual(rows.map(\.path), ["README.md", "Sources", "Sources/App.swift", "Sources/Z.swift", "Tests", "Tests/AppTests.swift"])
        XCTAssertEqual(rows.filter(\.isFolder).map(\.path), ["Sources", "Tests"])
        XCTAssertEqual(rows.first(where: { $0.path == "Sources/App.swift" })?.depth, 1)
    }

    func testShelfTreeFlatModeDoesNotInventFolders() {
        let rows = shelfTreeRows(
            paths: ["b/file.swift", "a/file.swift"],
            groupByDirectory: false
        )

        XCTAssertEqual(rows.map(\.path), ["a/file.swift", "b/file.swift"])
        XCTAssertTrue(rows.allSatisfy { !$0.isFolder && $0.depth == 0 })
    }

    func testShelfTreeFlatModeMatchesIntelliJFilenameFirstOrdering() {
        let rows = shelfTreeRows(
            paths: ["z/README.md", "a/App.swift", "b/README.md", "a/Z.swift"],
            groupByDirectory: false
        )

        XCTAssertEqual(
            rows.map(\.path),
            ["a/App.swift", "b/README.md", "z/README.md", "a/Z.swift"]
        )
    }

    func testShelfMemberSelectionIDIncludesShelfIdentity() {
        XCTAssertNotEqual(
            shelfMemberSelectionID(shelfID: "shelf-a", path: "same.swift"),
            shelfMemberSelectionID(shelfID: "shelf-b", path: "same.swift")
        )
    }

    func testShelfDropPayloadParsesWholeShelf() {
        XCTAssertEqual(parseShelfDropPayload("arbor-shelf:Review fixes"), .shelf("Review fixes"))
    }

    func testShelfDropPayloadParsesSelectedMember() {
        XCTAssertEqual(
            parseShelfDropPayload("arbor-shelf-member:Review fixes\u{1F}Sources/App.swift"),
            .member(shelf: "Review fixes", path: "Sources/App.swift")
        )
    }

    func testShelfDropPayloadRejectsMalformedValues() {
        XCTAssertNil(parseShelfDropPayload(""))
        XCTAssertNil(parseShelfDropPayload("arbor-shelf:"))
        XCTAssertNil(parseShelfDropPayload("arbor-shelf-member:Review fixes"))
        XCTAssertNil(parseShelfDropPayload("arbor-shelf-member:\u{1F}Sources/App.swift"))
    }

    func testConflictSelectionKeepsOnlyConflictedPathsInStableOrder() {
        XCTAssertEqual(
            conflictPathsForSelection(
                ["z.swift", "stale.swift", "a.swift"],
                paths: ["z.swift", "a.swift", "b.swift"]
            ),
            ["a.swift", "z.swift"]
        )
    }

    func testConflictSelectionCanBeEmpty() {
        XCTAssertTrue(conflictPathsForSelection([], paths: ["a.swift"]).isEmpty)
    }

    func testMultiRootConflictTargetsAreRootQualifiedAndStable() {
        let groups = [
            MultiRootConflictGroup(
                rootPath: "/workspace/z-root",
                displayName: "Z",
                relativePath: "z",
                operation: nil,
                paths: ["z.swift", "a.swift"]
            ),
            MultiRootConflictGroup(
                rootPath: "/workspace/a-root",
                displayName: "A",
                relativePath: "a",
                operation: nil,
                paths: ["same.swift"]
            )
        ]

        let targets = multiRootConflictTargets(from: groups)

        XCTAssertEqual(
            targets.map { "\($0.rootPath):\($0.path)" },
            ["/workspace/a-root:same.swift", "/workspace/z-root:a.swift", "/workspace/z-root:z.swift"]
        )
        XCTAssertNotEqual(
            MultiRootConflictTarget(rootPath: "/workspace/a-root", path: "same.swift").id,
            MultiRootConflictTarget(rootPath: "/workspace/z-root", path: "same.swift").id
        )
    }

    func testMultiRootConflictResolverQueueIsStableAndRebaseSupportsSkip() {
        let roots = stableMultiRootConflictResolverRoots([
            MultiRootConflictResolverRoot(
                rootPath: "/workspace/z-root",
                displayName: "Z",
                relativePath: "z",
                paths: ["z.swift"],
                kind: .operation(.merge)
            ),
            MultiRootConflictResolverRoot(
                rootPath: "/workspace/a-root",
                displayName: "A",
                relativePath: "a",
                paths: ["a.swift"],
                kind: .operation(.rebase)
            )
        ])

        XCTAssertEqual(roots.map(\.rootPath), ["/workspace/a-root", "/workspace/z-root"])
        XCTAssertTrue(roots[0].canSkip)
        XCTAssertFalse(roots[1].canSkip)
    }

    func testMultiRootRemoteTagRowsKeepRepositoryIdentityAndSortStably() {
        let rows = [
            MultiRootRemoteTagRow(
                rootPath: "/workspace/z-root",
                displayName: "Z",
                relativePath: "z",
                tag: RemoteTagInfo(
                    remote: "origin",
                    name: "release",
                    objectId: "1111111111111111111111111111111111111111",
                    id: "1111111111111111111111111111111111111111",
                    shortId: "1111111",
                    kind: .lightweight
                )
            ),
            MultiRootRemoteTagRow(
                rootPath: "/workspace/a-root",
                displayName: "A",
                relativePath: "a",
                tag: RemoteTagInfo(
                    remote: "origin",
                    name: "release",
                    objectId: "2222222222222222222222222222222222222222",
                    id: "2222222222222222222222222222222222222222",
                    shortId: "2222222",
                    kind: .lightweight
                )
            )
        ]

        let sorted = stableMultiRootRemoteTagRows(rows)
        XCTAssertEqual(sorted.map(\.relativePath), ["a", "z"])
        XCTAssertNotEqual(sorted[0].id, sorted[1].id)
        XCTAssertEqual(
            filteredMultiRootRemoteTagRows(sorted, query: "z-root").map(\.relativePath),
            ["z"]
        )
    }

    @MainActor
    func testFeedbackWarningPreservesAndInvokesNotificationAction() {
        let feedbackCenter = FeedbackCenter()
        var invoked = false

        feedbackCenter.warning(
            "Update Project partially completed",
            actionTitle: "Resolve Conflicts",
            action: { invoked = true }
        )

        XCTAssertEqual(feedbackCenter.current?.actionTitle, "Resolve Conflicts")
        feedbackCenter.current?.action?()
        XCTAssertTrue(invoked)
    }

    @MainActor
    func testFeedbackWarningSupportsMultipleNotificationActions() {
        let feedbackCenter = FeedbackCenter()
        var selectedAction = ""

        feedbackCenter.warning(
            "Push rejected",
            actionTitle: "Update with Merge",
            action: { selectedAction = "merge" },
            additionalActions: [
                FeedbackAction(title: "Update with Rebase") { selectedAction = "rebase" },
                FeedbackAction(title: "Retry Push") { selectedAction = "retry" }
            ],
            localized: false
        )

        XCTAssertEqual(feedbackCenter.current?.actions.map(\.title), [
            "Update with Merge",
            "Update with Rebase",
            "Retry Push"
        ])
        feedbackCenter.current?.actions[2].action()
        XCTAssertEqual(selectedAction, "retry")
    }

    func testStalePushRejectionKeepsStructuredLeaseGuidance() {
        let stale = EngineError.PushRejected(
            kind: .staleInfo,
            remote: "origin",
            branch: "main",
            message: "remote rejected: stale info"
        )
        let nonFastForward = EngineError.PushRejected(
            kind: .nonFastForward,
            remote: "origin",
            branch: "main",
            message: "remote rejected: non-fast-forward"
        )

        XCTAssertEqual(stalePushRejectionDetails(stale)?.remote, "origin")
        XCTAssertEqual(stalePushRejectionDetails(stale)?.branch, "main")
        XCTAssertEqual(stalePushRejectionDetails(stale)?.message, "remote rejected: stale info")
        XCTAssertNil(stalePushRejectionDetails(nonFastForward))
    }

    @MainActor
    func testFeedbackNotificationIDUpdatesOneGroupedHistoryEntry() {
        let suiteName = "Arbor.FeedbackGroupingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feedbackCenter = FeedbackCenter(defaults: defaults)

        feedbackCenter.warning(
            "Incoming changes available",
            detail: "root-a · origin/main",
            notificationID: "git.fetch.project.incoming",
            localized: false
        )
        feedbackCenter.warning(
            "Incoming changes available",
            detail: "root-a · origin/main\nroot-b · upstream/dev",
            notificationID: "git.fetch.project.incoming",
            localized: false
        )

        XCTAssertEqual(feedbackCenter.history.count, 1)
        XCTAssertEqual(
            feedbackCenter.history.first?.detail,
            "root-a · origin/main\nroot-b · upstream/dev"
        )
    }

    func testFeedbackResultRowsPreserveExecutionOrderAndState() {
        let rows = feedbackResultRows(from: [
            RootOperationResult(
                rootPath: "/workspace/app",
                displayName: "App",
                success: true,
                skipped: false,
                message: "updated 2 commits"
            ),
            RootOperationResult(
                rootPath: "/workspace/docs",
                displayName: "Docs",
                success: true,
                skipped: true,
                message: "detached HEAD"
            ),
            RootOperationResult(
                rootPath: "/workspace/tools",
                displayName: "Tools",
                success: false,
                skipped: false,
                message: "authentication failed"
            )
        ])

        XCTAssertEqual(rows.map(\.rootPath), [
            "/workspace/app", "/workspace/docs", "/workspace/tools"
        ])
        XCTAssertEqual(rows.map(\.state), [.success, .skipped, .failed])
        XCTAssertEqual(rows.map(\.detail), [
            "updated 2 commits", "detached HEAD", "authentication failed"
        ])
    }

    func testFeedbackResultRowsMarkPausedRootsAsPartialUsingCanonicalPaths() {
        let rows = feedbackResultRows(
            from: [
                RootOperationResult(
                    rootPath: "/workspace/app/../app",
                    displayName: "App",
                    success: true,
                    skipped: false,
                    message: "conflicts need resolution"
                ),
                RootOperationResult(
                    rootPath: "/workspace/docs",
                    displayName: "Docs",
                    success: true,
                    skipped: false,
                    message: "rebase completed"
                )
            ],
            partialRootPaths: ["/workspace/app"]
        )

        XCTAssertEqual(rows.map(\.state), [.partial, .success])
    }

    @MainActor
    func testFeedbackResultRowsPersistAcrossOperationLogReload() {
        let suiteName = "Arbor.FeedbackResultRowsReloadTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let notificationID = "git.fetch.project"
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Fetch All partially completed",
            detail: "1 ok · 1 failed",
            notificationID: notificationID,
            localized: false
        )
        feedbackCenter.attachResultRows(
            [
                FeedbackResultRow(
                    rootPath: "/workspace/app",
                    displayName: "App",
                    state: .success,
                    detail: "updated refs"
                ),
                FeedbackResultRow(
                    rootPath: "/workspace/docs",
                    displayName: "Docs",
                    state: .failed,
                    detail: "remote unavailable"
                )
            ],
            notificationID: notificationID
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.resultRows.map(\.displayName), ["App", "Docs"])
        XCTAssertEqual(reloaded.history.first?.resultRows.map(\.state), [.success, .failed])
        XCTAssertEqual(reloaded.history.first?.resultRows[1].rootPath, "/workspace/docs")
    }

    @MainActor
    func testFeedbackOperationItemsPersistShelfBatchOutcomesAcrossReload() {
        let suiteName = "Arbor.FeedbackOperationItemsReloadTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let notificationID = "arbor.shelf.batch.apply./workspace/app"
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Some shelves were not unshelved",
            detail: "1/2 applied",
            notificationID: notificationID,
            localized: false
        )
        feedbackCenter.attachResultRows(
            [
                FeedbackResultRow(
                    rootPath: "/workspace/app",
                    displayName: "App",
                    state: .success,
                    detail: "Shelf batch finished"
                )
            ],
            notificationID: notificationID
        )
        feedbackCenter.attachOperationItems(
            [
                FeedbackOperationItem(
                    scope: "/workspace/app",
                    name: "feature-a",
                    state: .success,
                    detail: "Applied → Review",
                    children: [
                        FeedbackOperationSubitem(
                            scope: "/workspace/app\u{1f}feature-a",
                            path: "Sources/App.swift",
                            state: .success,
                            detail: "Applied"
                        ),
                        FeedbackOperationSubitem(
                            scope: "/workspace/app\u{1f}feature-a",
                            path: "Tests/AppTests.swift",
                            state: .skipped,
                            detail: "Not attempted"
                        )
                    ]
                ),
                FeedbackOperationItem(
                    scope: "/workspace/app",
                    name: "feature-b",
                    state: .failed,
                    detail: "Conflict paused: Sources/App.swift"
                )
            ],
            notificationID: notificationID
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.resultRows.map(\.displayName), ["App"])
        XCTAssertEqual(reloaded.history.first?.resultItems.map(\.name), ["feature-a", "feature-b"])
        XCTAssertEqual(reloaded.history.first?.resultItems.map(\.state), [.success, .failed])
        XCTAssertEqual(
            reloaded.history.first?.resultItems[1].scope,
            "/workspace/app"
        )
        XCTAssertEqual(
            reloaded.history.first?.resultItems[1].detail,
            "Conflict paused: Sources/App.swift"
        )
        XCTAssertEqual(
            reloaded.history.first?.resultItems[0].children.map(\.path),
            ["Sources/App.swift", "Tests/AppTests.swift"]
        )
        XCTAssertEqual(
            reloaded.history.first?.resultItems[0].children.map(\.state),
            [.success, .skipped]
        )
    }

    @MainActor
    func testFeedbackShelfRetryPreservesAndMergesStableItemResults() {
        let suiteName = "Arbor.FeedbackShelfRetryItemsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let notificationID = "arbor.shelf.batch.apply./workspace/app"
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        let completedItem = FeedbackOperationItem(
            scope: "/workspace/app",
            name: "feature-a",
            state: .success,
            detail: "Applied"
        )
        let pendingItem = FeedbackOperationItem(
            scope: "/workspace/app",
            name: "feature-b",
            state: .failed,
            detail: "Conflict paused"
        )

        feedbackCenter.begin("Unshelve shelves", notificationID: notificationID)
        feedbackCenter.attachOperationItems(
            [completedItem, pendingItem],
            notificationID: notificationID
        )
        feedbackCenter.begin(
            "Retry remaining shelves",
            notificationID: notificationID,
            preserveResultItems: true
        )
        XCTAssertEqual(
            feedbackCenter.history.first?.resultItems.map(\.name),
            ["feature-a", "feature-b"]
        )

        let retriedItem = FeedbackOperationItem(
            scope: "/workspace/app",
            name: "feature-b",
            state: .success,
            detail: "Applied"
        )
        feedbackCenter.success(
            "Shelves unshelved",
            notificationID: notificationID,
            localized: false
        )
        feedbackCenter.attachOperationItems(
            [retriedItem],
            notificationID: notificationID,
            mergeWithExisting: true
        )

        XCTAssertEqual(
            feedbackCenter.history.first?.resultItems.map(\.name),
            ["feature-a", "feature-b"]
        )
        XCTAssertEqual(
            feedbackCenter.history.first?.resultItems.map(\.state),
            [.success, .success]
        )
        XCTAssertEqual(
            feedbackCenter.history.first?.resultItems.map(\.detail),
            ["Applied", "Applied"]
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(
            reloaded.history.first?.resultItems.map(\.name),
            ["feature-a", "feature-b"]
        )
        feedbackCenter.begin("Fresh Shelf batch", notificationID: notificationID)
        XCTAssertTrue(feedbackCenter.history.first?.resultItems.isEmpty == true)
    }

    @MainActor
    func testFeedbackShelfMemberRetryPreservesGroupedPathResults() {
        let suiteName = "Arbor.FeedbackShelfMemberRetryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let rootPath = "/workspace/app"
        let notificationID = shelfNotificationID(
            prefix: "shelf-member-batch.drop",
            rootPath: rootPath
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        let completedItem = FeedbackOperationItem(
            scope: rootPath,
            name: "Shelf A",
            state: .success,
            detail: "Moved to Recently Deleted",
            children: [FeedbackOperationSubitem(
                scope: "\(rootPath)\u{1f}Shelf A",
                path: "Sources/A.swift",
                state: .success,
                detail: "Moved to Recently Deleted"
            )]
        )
        let pendingItem = FeedbackOperationItem(
            scope: rootPath,
            name: "Shelf B",
            state: .failed,
            detail: "Permission denied"
        )

        feedbackCenter.begin("Drop Shelf changes", notificationID: notificationID)
        feedbackCenter.attachOperationItems(
            [completedItem, pendingItem],
            notificationID: notificationID
        )
        feedbackCenter.begin(
            "Retry remaining Shelf changes",
            notificationID: notificationID,
            preserveResultItems: true
        )
        let retriedItem = FeedbackOperationItem(
            scope: rootPath,
            name: "Shelf B",
            state: .success,
            detail: "Moved to Recently Deleted",
            children: [FeedbackOperationSubitem(
                scope: "\(rootPath)\u{1f}Shelf B",
                path: "Sources/B.swift",
                state: .success,
                detail: "Moved to Recently Deleted"
            )]
        )
        feedbackCenter.success(
            "Shelf changes dropped",
            notificationID: notificationID,
            localized: false
        )
        feedbackCenter.attachOperationItems(
            [retriedItem],
            notificationID: notificationID,
            mergeWithExisting: true
        )

        XCTAssertEqual(
            feedbackCenter.history.first?.resultItems.map(\.name),
            ["Shelf A", "Shelf B"]
        )
        XCTAssertEqual(
            feedbackCenter.history.first?.resultItems.map(\.state),
            [.success, .success]
        )
        XCTAssertEqual(
            feedbackCenter.history.first?.resultItems[0].children.map(\.path),
            ["Sources/A.swift"]
        )
        XCTAssertEqual(
            FeedbackCenter(defaults: defaults).history.first?.resultItems.map(\.name),
            ["Shelf A", "Shelf B"]
        )

        feedbackCenter.begin("Fresh Shelf member batch", notificationID: notificationID)
        XCTAssertTrue(feedbackCenter.history.first?.resultItems.isEmpty == true)
    }

    @MainActor
    func testFeedbackNotificationIDRebuildsDisplayIndexAfterReload() {
        let suiteName = "Arbor.FeedbackGroupingReloadTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let notificationID = "arbor.update.project"
        let first = FeedbackCenter(defaults: defaults)
        first.warning(
            "Update Project partially completed",
            detail: "root-a failed",
            notificationID: notificationID,
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        reloaded.warning(
            "Update Project completed",
            detail: "root-a and root-b updated",
            notificationID: notificationID,
            localized: false
        )

        XCTAssertEqual(reloaded.history.count, 1)
        XCTAssertEqual(reloaded.history.first?.title, "Update Project completed")
        XCTAssertEqual(reloaded.history.first?.detail, "root-a and root-b updated")
        XCTAssertEqual(reloaded.history.first?.notificationID, notificationID)
    }

    @MainActor
    func testFeedbackExpirationRemovesDisplayIndexButKeepsHistory() {
        let suiteName = "Arbor.FeedbackExpirationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let notificationID = "arbor.branch.recovery"
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Branch restored",
            additionalActions: [FeedbackAction(title: "Retry") {}],
            notificationID: notificationID,
            localized: false
        )
        feedbackCenter.expire(notificationID: notificationID)

        XCTAssertEqual(feedbackCenter.history.count, 1)
        XCTAssertNil(feedbackCenter.history.first?.notificationID)
        XCTAssertTrue(feedbackCenter.history.first?.actions.isEmpty == true)
        XCTAssertTrue(feedbackCenter.history.first?.actionTitles.isEmpty == true)

        let reloadedExpired = FeedbackCenter(defaults: defaults)
        XCTAssertTrue(reloadedExpired.history.first?.actions.isEmpty == true)
        XCTAssertTrue(reloadedExpired.history.first?.actionTitles.isEmpty == true)

        let reloaded = FeedbackCenter(defaults: defaults)
        reloaded.warning(
            "Another branch restored",
            notificationID: notificationID,
            localized: false
        )

        XCTAssertEqual(reloaded.history.count, 2)
        XCTAssertEqual(reloaded.history.first?.title, "Another branch restored")
    }

    func testAutoFetchNotificationFingerprintGroupsAndSortsValues() {
        XCTAssertEqual(
            groupedAutoFetchValues(["root-b", "root-a", "root-b"]),
            ["root-a", "root-b"]
        )
        XCTAssertEqual(
            autoFetchNotificationFingerprint(["root-b", "root-a", "root-b"]),
            "root-a\nroot-b"
        )
    }

    func testAutoFetchIncomingBranchesStayQualifiedByRootAndRemote() {
        let values = groupedAutoFetchIncomingBranches([
            GitIncomingBranch(rootPath: "/repo-b", remote: "origin", branch: "main"),
            GitIncomingBranch(rootPath: "/repo-a", remote: "upstream", branch: "main"),
            GitIncomingBranch(rootPath: "/repo-a", remote: "origin", branch: "feature/x"),
            GitIncomingBranch(rootPath: "/repo-a", remote: "origin", branch: "feature/x")
        ])

        XCTAssertEqual(
            values.map(\.displayValue),
            [
                "/repo-a · origin/feature/x",
                "/repo-a · upstream/main",
                "/repo-b · origin/main"
            ]
        )

        let state = Set(values)
        XCTAssertTrue(hasUnfetchedIncomingBranch(rootPath: "/repo-a", branch: "feature/x", in: state))
        XCTAssertFalse(hasUnfetchedIncomingBranch(rootPath: "/repo-b", branch: "feature/x", in: state))
        XCTAssertTrue(hasUnfetchedIncomingRemoteBranch(
            rootPath: "/repo-a",
            remote: "upstream",
            branch: "main",
            in: state
        ))
        XCTAssertFalse(hasUnfetchedIncomingRemoteBranch(
            rootPath: "/repo-a",
            remote: "origin",
            branch: "main",
            in: state
        ))
        XCTAssertEqual(
            autoFetchRemoteBranchIdentity("origin/feature/x")?.remote,
            "origin"
        )
        XCTAssertEqual(
            autoFetchRemoteBranchIdentity("origin/feature/x")?.branch,
            "feature/x"
        )
        XCTAssertNil(autoFetchRemoteBranchIdentity("main"))
    }

    func testAutoFetchIncomingSnapshotPreservesUncheckedRemotes() {
        let existing: Set<GitIncomingBranch> = [
            GitIncomingBranch(rootPath: "/repo-a", remote: "origin", branch: "old-origin"),
            GitIncomingBranch(rootPath: "/repo-a", remote: "upstream", branch: "old-upstream"),
            GitIncomingBranch(rootPath: "/repo-b", remote: "origin", branch: "old-b")
        ]
        let snapshot = GitIncomingBranchesSnapshot(
            branches: [GitIncomingBranch(rootPath: "/repo-a", remote: "origin", branch: "new-origin")],
            configuredRoots: ["/repo-a"],
            configuredRemotes: [
                GitIncomingRemote(rootPath: "/repo-a", remote: "origin"),
                GitIncomingRemote(rootPath: "/repo-a", remote: "upstream")
            ],
            checkedRemotes: [GitIncomingRemote(rootPath: "/repo-a", remote: "origin")]
        )

        let merged = applyingAutoFetchIncomingSnapshot(snapshot, to: existing)
        XCTAssertTrue(merged.contains(GitIncomingBranch(
            rootPath: "/repo-a",
            remote: "origin",
            branch: "new-origin"
        )))
        XCTAssertFalse(merged.contains(GitIncomingBranch(
            rootPath: "/repo-a",
            remote: "origin",
            branch: "old-origin"
        )))
        XCTAssertTrue(merged.contains(GitIncomingBranch(
            rootPath: "/repo-a",
            remote: "upstream",
            branch: "old-upstream"
        )))
        XCTAssertTrue(merged.contains(GitIncomingBranch(
            rootPath: "/repo-b",
            remote: "origin",
            branch: "old-b"
        )))

        let noRemoteSnapshot = GitIncomingBranchesSnapshot(
            branches: [],
            configuredRoots: ["/repo-b"]
        )
        let afterRemoteRemoval = applyingAutoFetchIncomingSnapshot(noRemoteSnapshot, to: merged)
        XCTAssertFalse(afterRemoteRemoval.contains(where: { $0.rootPath == "/repo-b" }))
    }

    func testAutoFetchStartsImmediatelyThenUsesIntelliJTwentyMinuteCadence() {
        XCTAssertEqual(
            autoFetchDelaySeconds(firstRun: false),
            20 * 60
        )
        XCTAssertNil(autoFetchDelaySeconds(firstRun: true))
    }

    func testAutoFetchScheduleUsesPositiveInternalIntervalAndFallsBackForInvalidValues() {
        let suiteName = "Arbor.IncomingCheckScheduleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            GitIncomingCheckSchedule.intervalMinutes(defaults: defaults),
            GitIncomingCheckSchedule.defaultIntervalMinutes
        )
        defaults.set(7, forKey: GitIncomingCheckSchedule.intervalMinutesKey)
        XCTAssertEqual(GitIncomingCheckSchedule.intervalSeconds(defaults: defaults), 7 * 60)
        defaults.set(0, forKey: GitIncomingCheckSchedule.intervalMinutesKey)
        XCTAssertEqual(
            GitIncomingCheckSchedule.intervalMinutes(defaults: defaults),
            GitIncomingCheckSchedule.defaultIntervalMinutes
        )
        defaults.set(-1, forKey: GitIncomingCheckSchedule.intervalMinutesKey)
        XCTAssertEqual(
            GitIncomingCheckSchedule.intervalMinutes(defaults: defaults),
            GitIncomingCheckSchedule.defaultIntervalMinutes
        )
    }

    func testAutoFetchRootFailureIncludesRootAndPreparationStage() {
        struct TestError: LocalizedError {
            var errorDescription: String? { "permission denied" }
        }

        XCTAssertEqual(
            autoFetchRootFailure(
                rootPath: "/tmp/project",
                stage: "Load Git remotes",
                error: TestError()
            ),
            "/tmp/project · Load Git remotes: permission denied"
        )
    }

    func testShelfLifecycleRunsImmediatelyThenDaily() {
        XCTAssertNil(shelfLifecycleDelaySeconds(firstRun: true))
        XCTAssertEqual(shelfLifecycleDelaySeconds(firstRun: false), 24 * 60 * 60)
    }

    func testAutomaticChangelistSettingDefaultsOffAndPersists() {
        let suiteName = "Arbor.ChangelistSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(GitChangelistSettings.createAutomatically(from: defaults))
        defaults.set(true, forKey: GitChangelistSettings.createAutomaticallyKey)
        XCTAssertTrue(GitChangelistSettings.createAutomatically(from: defaults))
    }

    func testCherryPickPublishedSuffixSettingIsProjectScopedWithGlobalFallback() {
        let suiteName = "Arbor.CherryPickSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstProject = "/workspace/cherry-pick-one"
        let secondProject = "/workspace/cherry-pick-two"
        defaults.set(false, forKey: GitCherryPickSettings.appendPublishedSuffixKey)

        XCTAssertFalse(
            GitCherryPickSettings.effectiveAppendPublishedSuffix(
                for: firstProject,
                defaults: defaults
            )
        )
        XCTAssertNil(
            GitCherryPickSettings.projectAppendPublishedSuffix(
                for: firstProject,
                defaults: defaults
            )
        )

        GitCherryPickSettings.saveProjectAppendPublishedSuffix(
            true,
            for: firstProject,
            defaults: defaults
        )

        XCTAssertTrue(
            GitCherryPickSettings.effectiveAppendPublishedSuffix(
                for: firstProject,
                defaults: defaults
            )
        )
        XCTAssertFalse(
            GitCherryPickSettings.effectiveAppendPublishedSuffix(
                for: secondProject,
                defaults: defaults
            )
        )

        GitCherryPickSettings.saveProjectAppendPublishedSuffix(
            nil,
            for: firstProject,
            defaults: defaults
        )
        XCTAssertFalse(
            GitCherryPickSettings.effectiveAppendPublishedSuffix(
                for: firstProject,
                defaults: defaults
            )
        )
    }

    func testPushTagModeSettingIsProjectScopedAndDefaultsToOff() {
        let suiteName = "Arbor.PushTagSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstProject = "/workspace/push-tags-one"
        let secondProject = "/workspace/push-tags-two"
        XCTAssertFalse(
            GitPushTagSettings.hasProjectOverride(
                for: firstProject,
                defaults: defaults
            )
        )
        XCTAssertNil(
            GitPushTagSettings.projectTagMode(
                for: firstProject,
                defaults: defaults
            )
        )

        GitPushTagSettings.saveProjectTagMode(
            .currentBranch,
            for: firstProject,
            defaults: defaults
        )

        XCTAssertTrue(
            GitPushTagSettings.hasProjectOverride(
                for: firstProject,
                defaults: defaults
            )
        )
        XCTAssertEqual(
            GitPushTagSettings.projectTagMode(
                for: firstProject,
                defaults: defaults
            ),
            .currentBranch
        )
        XCTAssertNil(
            GitPushTagSettings.projectTagMode(
                for: secondProject,
                defaults: defaults
            )
        )

        GitPushTagSettings.saveProjectTagMode(
            nil,
            for: firstProject,
            defaults: defaults
        )
        XCTAssertFalse(
            GitPushTagSettings.hasProjectOverride(
                for: firstProject,
                defaults: defaults
            )
        )
    }

    func testPushAutoUpdateSettingIsProjectScopedAndGuarded() {
        let suiteName = "Arbor.PushAutoUpdateSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstProject = "/workspace/push-auto-one"
        let secondProject = "/workspace/push-auto-two"
        XCTAssertFalse(
            GitPushAutoUpdateSettings.value(
                for: firstProject,
                defaults: defaults
            )
        )

        GitPushAutoUpdateSettings.save(
            true,
            for: firstProject,
            defaults: defaults
        )

        XCTAssertTrue(
            GitPushAutoUpdateSettings.value(
                for: firstProject,
                defaults: defaults
            )
        )
        XCTAssertFalse(
            GitPushAutoUpdateSettings.value(
                for: secondProject,
                defaults: defaults
            )
        )
        XCTAssertTrue(
            gitPushAutoUpdateIsEligible(
                enabled: true,
                force: false,
                refspec: nil,
                currentBranch: "main",
                rejectedBranch: "main",
                hasTracking: true
            )
        )
        XCTAssertFalse(
            gitPushAutoUpdateIsEligible(
                enabled: true,
                force: true,
                refspec: nil,
                currentBranch: "main",
                rejectedBranch: "main",
                hasTracking: true
            )
        )
        XCTAssertFalse(
            gitPushAutoUpdateIsEligible(
                enabled: true,
                force: false,
                refspec: "HEAD:refs/heads/main",
                currentBranch: "main",
                rejectedBranch: "main",
                hasTracking: true
            )
        )
        XCTAssertFalse(
            gitPushAutoUpdateIsEligible(
                enabled: true,
                force: false,
                refspec: nil,
                currentBranch: "feature",
                rejectedBranch: "main",
                hasTracking: true
            )
        )
        XCTAssertFalse(
            gitPushAutoUpdateIsEligible(
                enabled: true,
                force: false,
                refspec: nil,
                currentBranch: "main",
                rejectedBranch: "main",
                hasTracking: false
            )
        )
    }

    func testSignOffCommitSettingIsProjectScopedWithGlobalFallback() {
        let suiteName = "Arbor.SignOffCommitSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstProject = "/workspace/signoff-one"
        let secondProject = "/workspace/signoff-two"
        defaults.set(true, forKey: GitSignOffCommitSettings.globalKey)

        XCTAssertTrue(
            GitSignOffCommitSettings.value(
                for: firstProject,
                defaults: defaults
            )
        )
        XCTAssertNil(
            GitSignOffCommitSettings.projectValue(
                for: firstProject,
                defaults: defaults
            )
        )

        GitSignOffCommitSettings.saveProjectValue(
            false,
            for: firstProject,
            defaults: defaults
        )

        XCTAssertFalse(
            GitSignOffCommitSettings.value(
                for: firstProject,
                defaults: defaults
            )
        )
        XCTAssertTrue(
            GitSignOffCommitSettings.value(
                for: secondProject,
                defaults: defaults
            )
        )
    }

    func testResetModeSettingIsProjectScopedAndDefaultsToMixed() {
        let suiteName = "Arbor.ResetModeSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstProject = "/workspace/reset-one"
        let secondProject = "/workspace/reset-two"
        XCTAssertEqual(
            GitResetModeSettings.mode(for: firstProject, defaults: defaults),
            .mixed
        )

        GitResetModeSettings.save(.hard, for: firstProject, defaults: defaults)

        XCTAssertEqual(
            GitResetModeSettings.mode(for: firstProject, defaults: defaults),
            .hard
        )
        XCTAssertEqual(
            GitResetModeSettings.mode(for: secondProject, defaults: defaults),
            .mixed
        )
        XCTAssertEqual(GitResetModeChoice(ResetMode.keep).engineValue, .keep)
    }

    func testCommitWarningSettingsAreProjectScopedAndDefaultToIntelliJValues() {
        let suiteName = "Arbor.CommitWarningSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstProject = "/workspace/commit-warning-one"
        let secondProject = "/workspace/commit-warning-two"
        for setting in GitCommitWarningSetting.allCases {
            XCTAssertTrue(
                GitCommitWarningSettings.warningEnabled(
                    setting,
                    for: firstProject,
                    defaults: defaults
                )
            )
        }
        XCTAssertEqual(
            GitCommitWarningSettings.largeFileLimitMB(for: firstProject, defaults: defaults),
            50
        )

        GitCommitWarningSettings.saveWarning(
            false,
            .crlf,
            for: firstProject,
            defaults: defaults
        )
        GitCommitWarningSettings.saveWarning(
            false,
            .badFileName,
            for: firstProject,
            defaults: defaults
        )
        GitCommitWarningSettings.saveLargeFileLimitMB(
            75,
            for: firstProject,
            defaults: defaults
        )

        XCTAssertFalse(
            GitCommitWarningSettings.warningEnabled(
                .crlf,
                for: firstProject,
                defaults: defaults
            )
        )
        XCTAssertFalse(
            GitCommitWarningSettings.warningEnabled(
                .badFileName,
                for: firstProject,
                defaults: defaults
            )
        )
        XCTAssertTrue(
            GitCommitWarningSettings.warningEnabled(
                .detachedHead,
                for: firstProject,
                defaults: defaults
            )
        )
        XCTAssertEqual(
            GitCommitWarningSettings.largeFileLimitMB(for: firstProject, defaults: defaults),
            75
        )
        XCTAssertEqual(
            GitCommitWarningSettings.largeFileLimitBytes(for: firstProject, defaults: defaults),
            75 * 1024 * 1024
        )

        XCTAssertTrue(
            GitCommitWarningSettings.warningEnabled(
                .crlf,
                for: secondProject,
                defaults: defaults
            )
        )
        XCTAssertEqual(
            GitCommitWarningSettings.largeFileLimitMB(for: secondProject, defaults: defaults),
            50
        )
    }

    func testRebaseCommitWarningUsesTheDetachedHeadProjectSetting() {
        XCTAssertEqual(
            commitWarningSetting(for: .rebaseInProgress),
            .detachedHead,
            "IntelliJ uses the detached-head warning setting for its rebase warning"
        )
    }

    func testGitIdentityScopeIsProjectScopedAndDefaultsGlobal() {
        let suiteName = "Arbor.GitIdentityScopeSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstProject = "/workspace/identity-one"
        let secondProject = "/workspace/identity-two"
        XCTAssertTrue(
            GitIdentityScopeSettings.setNameEmailGlobally(
                for: firstProject,
                defaults: defaults
            )
        )

        GitIdentityScopeSettings.saveSetNameEmailGlobally(
            false,
            for: firstProject,
            defaults: defaults
        )

        XCTAssertFalse(
            GitIdentityScopeSettings.setNameEmailGlobally(
                for: firstProject,
                defaults: defaults
            )
        )
        XCTAssertTrue(
            GitIdentityScopeSettings.setNameEmailGlobally(
                for: secondProject,
                defaults: defaults
            )
        )
    }

    func testRootSyncSettingIsProjectScopedAndDefaultsToNotDecided() {
        let suiteName = "Arbor.GitRootSyncSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstProject = "/workspace/root-sync-one"
        let secondProject = "/workspace/root-sync-two"
        XCTAssertEqual(
            GitRootSyncSettings.choice(for: firstProject, defaults: defaults),
            .notDecided
        )
        XCTAssertTrue(GitRootSyncChoice.notDecided.shouldExecuteOperationsOnAllRoots)
        XCTAssertFalse(GitRootSyncChoice.dontSync.shouldExecuteOperationsOnAllRoots)

        GitRootSyncSettings.save(.sync, for: firstProject, defaults: defaults)
        GitRootSyncSettings.save(.dontSync, for: secondProject, defaults: defaults)

        XCTAssertEqual(
            GitRootSyncSettings.choice(for: firstProject, defaults: defaults),
            .sync
        )
        XCTAssertEqual(
            GitRootSyncSettings.choice(for: secondProject, defaults: defaults),
            .dontSync
        )

        GitRootSyncSettings.save(.notDecided, for: firstProject, defaults: defaults)
        XCTAssertEqual(
            GitRootSyncSettings.choice(for: firstProject, defaults: defaults),
            .notDecided
        )
    }

    func testCompareBranchesSwapSidesSettingIsProjectScoped() {
        let suiteName = "Arbor.GitCompareBranchesSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstProject = "/workspace/compare-one"
        let secondProject = "/workspace/compare-two"
        XCTAssertFalse(
            GitCompareBranchesSettings.swapSides(for: firstProject, defaults: defaults)
        )

        GitCompareBranchesSettings.saveSwapSides(
            true,
            for: firstProject,
            defaults: defaults
        )

        XCTAssertTrue(
            GitCompareBranchesSettings.swapSides(for: firstProject, defaults: defaults)
        )
        XCTAssertFalse(
            GitCompareBranchesSettings.swapSides(for: secondProject, defaults: defaults)
        )
    }

    func testReversedFileDiffForPresentationSwapsSidesAndLineKinds() {
        let diff = FileDiff(
            path: "file.txt",
            binary: false,
            hunks: [
                DiffHunk(
                    oldStart: 2,
                    newStart: 3,
                    oldLines: [
                        DiffLine(
                            kind: .context,
                            oldLine: 2,
                            newLine: 3,
                            text: "same",
                            spans: [],
                            highlights: []
                        ),
                        DiffLine(
                            kind: .deletion,
                            oldLine: 3,
                            newLine: 0,
                            text: "branch",
                            spans: [],
                            highlights: []
                        )
                    ],
                    newLines: [
                        DiffLine(
                            kind: .context,
                            oldLine: 2,
                            newLine: 3,
                            text: "same",
                            spans: [],
                            highlights: []
                        ),
                        DiffLine(
                            kind: .addition,
                            oldLine: 0,
                            newLine: 4,
                            text: "working",
                            spans: [],
                            highlights: []
                        )
                    ]
                )
            ]
        )

        let reversed = reversedFileDiffForPresentation(diff)
        XCTAssertEqual(reversed.hunks.first?.oldStart, 3)
        XCTAssertEqual(reversed.hunks.first?.newStart, 2)
        XCTAssertEqual(reversed.hunks.first?.oldLines.map(\.kind), [.context, .deletion])
        XCTAssertEqual(reversed.hunks.first?.newLines.map(\.kind), [.context, .addition])
        XCTAssertEqual(reversed.hunks.first?.oldLines.last?.text, "working")
        XCTAssertEqual(reversed.hunks.first?.newLines.last?.text, "branch")
    }

    func testCommitAuthorHistoryIsProjectScopedMRUAndCapped() {
        let suiteName = "Arbor.GitCommitAuthorHistorySettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstProject = "/workspace/authors-one"
        let secondProject = "/workspace/authors-two"
        for index in 0..<(GitCommitAuthorHistorySettings.limit + 2) {
            GitCommitAuthorHistorySettings.save(
                "User \(index) <user\(index)@example.test>",
                for: firstProject,
                defaults: defaults
            )
        }
        GitCommitAuthorHistorySettings.save(
            "User 3 <user3@example.test>",
            for: firstProject,
            defaults: defaults
        )

        let authors = GitCommitAuthorHistorySettings.authors(
            for: firstProject,
            defaults: defaults
        )
        XCTAssertEqual(authors.count, GitCommitAuthorHistorySettings.limit)
        XCTAssertEqual(authors.first, "User 3 <user3@example.test>")
        XCTAssertFalse(authors.contains("User 0 <user0@example.test>"))
        XCTAssertTrue(
            GitCommitAuthorHistorySettings.authors(
                for: secondProject,
                defaults: defaults
            ).isEmpty
        )
        XCTAssertEqual(
            GitCommitAuthorHistorySettings.parse("User 3 <user3@example.test>")?.email,
            "user3@example.test"
        )
        XCTAssertEqual(
            GitCommitAuthorHistorySettings.formattedAuthor(
                name: " User 3 ",
                email: " user3@example.test "
            ),
            "User 3 <user3@example.test>"
        )
        XCTAssertNil(
            GitCommitAuthorHistorySettings.formattedAuthor(name: "", email: "user@example.test")
        )
        XCTAssertNil(GitCommitAuthorHistorySettings.parse("not-an-author"))
    }

    func testCloneRecursiveSubmodulesSettingDefaultsOnAndPersists() {
        let suiteName = "Arbor.CloneSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(GitCloneSettings.recurseSubmodules(from: defaults))
        GitCloneSettings.saveRecurseSubmodules(false, defaults: defaults)
        XCTAssertFalse(GitCloneSettings.recurseSubmodules(from: defaults))
        GitCloneSettings.saveRecurseSubmodules(true, defaults: defaults)
        XCTAssertTrue(GitCloneSettings.recurseSubmodules(from: defaults))
    }

    func testDropCommitConfirmationDefaultsOnAndPersists() {
        let suiteName = "Arbor.DropCommitSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(GitDropCommitSettings.showConfirmation(from: defaults))
        defaults.set(false, forKey: GitDropCommitSettings.showConfirmationKey)
        XCTAssertFalse(GitDropCommitSettings.showConfirmation(from: defaults))
        defaults.set(true, forKey: GitDropCommitSettings.showConfirmationKey)
        XCTAssertTrue(GitDropCommitSettings.showConfirmation(from: defaults))
    }

    func testFetchTagsModeIsProjectScopedAndDefaultIsGitDefault() {
        let suiteName = "Arbor.FetchTagsSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstProject = "/tmp/arbor-fetch-tags-one"
        let secondProject = "/tmp/arbor-fetch-tags-two"
        XCTAssertEqual(
            GitFetchTagsSettings.mode(for: firstProject, defaults: defaults),
            .default
        )

        GitFetchTagsSettings.save(.allTags, for: firstProject, defaults: defaults)
        XCTAssertEqual(
            GitFetchTagsSettings.mode(for: firstProject, defaults: defaults),
            .allTags
        )
        XCTAssertEqual(
            GitFetchTagsSettings.mode(for: firstProject, defaults: defaults).engineValue,
            .allTags
        )
        XCTAssertEqual(
            GitFetchTagsSettings.mode(for: secondProject, defaults: defaults),
            .default
        )

        GitFetchTagsSettings.save(.default, for: firstProject, defaults: defaults)
        XCTAssertEqual(
            GitFetchTagsSettings.mode(for: firstProject, defaults: defaults),
            .default
        )
    }

    func testUpdateMethodIsProjectScopedAndDefaultsToMerge() {
        let suiteName = "Arbor.UpdateMethodSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstProject = "/tmp/arbor-update-method-one"
        let secondProject = "/tmp/arbor-update-method-two"
        XCTAssertEqual(
            GitUpdateMethodSettings.method(for: firstProject, defaults: defaults),
            .merge
        )

        GitUpdateMethodSettings.save(.rebase, for: firstProject, defaults: defaults)
        XCTAssertEqual(
            GitUpdateMethodSettings.method(for: firstProject, defaults: defaults),
            .rebase
        )
        XCTAssertEqual(
            GitUpdateMethodSettings.method(for: secondProject, defaults: defaults),
            .merge
        )

        GitUpdateMethodSettings.save(.merge, for: firstProject, defaults: defaults)
        XCTAssertEqual(
            GitUpdateMethodSettings.method(for: firstProject, defaults: defaults),
            .merge
        )
    }

    func testUpdateOptionsDialogVisibilityIsProjectScopedAndDefaultsToShown() {
        let suiteName = "Arbor.UpdateOptionsDialogSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstProject = "/tmp/arbor-update-options-one"
        let secondProject = "/tmp/arbor-update-options-two"
        XCTAssertTrue(
            GitUpdateOptionsDialogSettings.shouldShow(for: firstProject, defaults: defaults)
        )

        GitUpdateOptionsDialogSettings.saveShouldShow(
            false,
            for: firstProject,
            defaults: defaults
        )
        XCTAssertFalse(
            GitUpdateOptionsDialogSettings.shouldShow(for: firstProject, defaults: defaults)
        )
        XCTAssertTrue(
            GitUpdateOptionsDialogSettings.shouldShow(for: secondProject, defaults: defaults)
        )

        GitUpdateOptionsDialogSettings.saveShouldShow(
            true,
            for: firstProject,
            defaults: defaults
        )
        XCTAssertTrue(
            GitUpdateOptionsDialogSettings.shouldShow(for: firstProject, defaults: defaults)
        )
    }

    func testLocalChangesSavePolicyIsProjectScopedAndFallsBackToGlobal() {
        let suiteName = "Arbor.LocalChangesSavePolicySettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(GitLocalChangesSavePolicyChoice.stash.rawValue, forKey: GitLocalChangesSavePolicySettings.key)

        let firstProject = "/tmp/arbor-save-policy-one"
        let secondProject = "/tmp/arbor-save-policy-two"
        XCTAssertEqual(
            GitLocalChangesSavePolicySettings.choice(for: firstProject, defaults: defaults),
            .stash
        )
        XCTAssertEqual(
            GitLocalChangesSavePolicySettings.engineValue(for: secondProject, defaults: defaults),
            GitLocalChangesSavePolicyChoice.stash.engineValue
        )

        GitProjectLocalChangesSavePolicySettings.save(.shelve, for: firstProject, defaults: defaults)
        XCTAssertEqual(
            GitLocalChangesSavePolicySettings.choice(for: firstProject, defaults: defaults),
            .shelve
        )
        XCTAssertEqual(
            GitLocalChangesSavePolicySettings.choice(for: secondProject, defaults: defaults),
            .stash
        )

        GitProjectLocalChangesSavePolicySettings.save(nil, for: firstProject, defaults: defaults)
        XCTAssertEqual(
            GitLocalChangesSavePolicySettings.choice(for: firstProject, defaults: defaults),
            .stash
        )
    }

    func testMergeOptionsMirrorIntelliJCompatibilityMatrix() {
        XCTAssertEqual(mergeEngineMode(for: .automatic), .fastForward)
        XCTAssertEqual(mergeEngineMode(for: .fastForwardOnly), .fastForwardOnly)
        XCTAssertEqual(mergeEngineMode(for: .noFastForward), .noFastForward)
        XCTAssertEqual(mergeEngineMode(for: .squash), .squash)
        XCTAssertFalse(
            mergeOptionIsEnabled(
                .commitMessage,
                strategy: .fastForwardOnly,
                selectedOptions: []
            )
        )
        XCTAssertFalse(
            mergeOptionIsEnabled(
                .commitMessage,
                strategy: .noFastForward,
                selectedOptions: [.noCommit]
            )
        )
        XCTAssertFalse(
            mergeOptionIsEnabled(
                .noCommit,
                strategy: .automatic,
                selectedOptions: [.commitMessage]
            )
        )
        XCTAssertTrue(
            mergeOptionIsEnabled(
                .noVerify,
                strategy: .squash,
                selectedOptions: [.commitMessage]
            )
        )
        XCTAssertFalse(
            mergeStrategyIsEnabled(
                .squash,
                selectedOptions: [.commitMessage]
            )
        )
        XCTAssertTrue(
            mergeStrategyIsEnabled(
                .noFastForward,
                selectedOptions: [.commitMessage, .noCommit]
            )
        )
    }

    func testMergeDialogSettingsAreProjectScopedAndRoundTrip() {
        let suiteName = "Arbor.MergeDialogSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstProject = "/tmp/arbor-merge-one"
        let secondProject = "/tmp/arbor-merge-two"
        let settings = GitMergeDialogSettings(
            branch: "feature/one",
            strategyRaw: MergeStrategyChoice.noFastForward.rawValue,
            useCustomCommitMessage: true,
            noCommit: false,
            noVerify: true,
            allowUnrelatedHistories: false
        )

        XCTAssertEqual(
            GitMergeDialogSettingsStore.load(for: firstProject, defaults: defaults),
            GitMergeDialogSettings()
        )
        GitMergeDialogSettingsStore.save(settings, for: firstProject, defaults: defaults)
        XCTAssertEqual(
            GitMergeDialogSettingsStore.load(for: firstProject, defaults: defaults),
            settings
        )
        XCTAssertEqual(
            GitMergeDialogSettingsStore.load(for: secondProject, defaults: defaults),
            GitMergeDialogSettings()
        )
    }

    func testRebaseDialogSettingsAreProjectScopedAndRoundTrip() {
        let suiteName = "Arbor.RebaseDialogSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstProject = "/tmp/arbor-rebase-one"
        let secondProject = "/tmp/arbor-rebase-two"
        let settings = GitRebaseDialogSettings(
            onto: "origin/main",
            interactive: true,
            preserveMerges: true,
            autoSquash: true,
            keepEmpty: true,
            updateRefs: true,
            root: false
        )

        XCTAssertEqual(
            GitRebaseDialogSettingsStore.load(for: firstProject, defaults: defaults),
            GitRebaseDialogSettings()
        )
        GitRebaseDialogSettingsStore.save(settings, for: firstProject, defaults: defaults)
        XCTAssertEqual(
            GitRebaseDialogSettingsStore.load(for: firstProject, defaults: defaults),
            settings
        )
        XCTAssertEqual(
            GitRebaseDialogSettingsStore.load(for: secondProject, defaults: defaults),
            GitRebaseDialogSettings()
        )

        let legacyData = Data(#"{"onto":"legacy/main","preserveMerges":true}"#.utf8)
        let legacy = try? JSONDecoder().decode(GitRebaseDialogSettings.self, from: legacyData)
        XCTAssertEqual(legacy?.onto, "legacy/main")
        XCTAssertEqual(legacy?.interactive, false)
        XCTAssertEqual(legacy?.preserveMerges, true)
    }

    func testMultiRootUpdateGroupsSubmoduleFailureAndDependentSkip() {
        let results = [
            RootOperationResult(
                rootPath: "/workspace/project",
                displayName: "project",
                success: false,
                skipped: false,
                message: "parent update failed"
            ),
            RootOperationResult(
                rootPath: "/workspace/project/vendor/lib",
                displayName: "lib",
                success: true,
                skipped: true,
                message: "detached submodule parent update did not complete"
            ),
            RootOperationResult(
                rootPath: "/workspace/independent",
                displayName: "independent",
                success: false,
                skipped: false,
                message: "remote unavailable"
            )
        ]

        XCTAssertEqual(
            ContentView.multiRootUpdateFailureDetails(
                results,
                submoduleRootPaths: ["/workspace/project/vendor/lib"]
            ),
            [
                "independent: remote unavailable",
                "project: parent update failed",
                "  lib: detached submodule parent update did not complete"
            ]
        )
    }

    func testMultiRootUpdateCancellationRemainsVisibleInPartialDetails() {
        let results = [
            RootOperationResult(
                rootPath: "/workspace/project",
                displayName: "project",
                success: true,
                skipped: true,
                message: "cancelled before update"
            )
        ]

        XCTAssertEqual(
            ContentView.multiRootUpdateFailureDetails(
                results,
                submoduleRootPaths: []
            ),
            ["project (cancelled before update)"]
        )
    }

    func testMultiRootUpdateRollbackTargetsIncludeOnlyAdvancedSuccessfulRoots() {
        let results = [
            RootOperationResult(
                rootPath: "/workspace/project",
                displayName: "project",
                success: true,
                skipped: false,
                message: "updated"
            ),
            RootOperationResult(
                rootPath: "/workspace/project/vendor/lib",
                displayName: "lib",
                success: true,
                skipped: false,
                message: "updated detached submodule"
            ),
            RootOperationResult(
                rootPath: "/workspace/failed",
                displayName: "failed",
                success: false,
                skipped: false,
                message: "remote unavailable"
            ),
            RootOperationResult(
                rootPath: "/workspace/skipped",
                displayName: "skipped",
                success: true,
                skipped: true,
                message: "no upstream"
            )
        ]
        let targets = ContentView.updateSessionRollbackTargets(
            previousHeads: [
                "/workspace/project": "p-old",
                "/workspace/project/vendor/lib": "c-old",
                "/workspace/failed": "f-old",
                "/workspace/skipped": "s-old"
            ],
            currentHeads: [
                "/workspace/project": "p-new",
                "/workspace/project/vendor/lib": "c-new",
                "/workspace/failed": "f-new",
                "/workspace/skipped": "s-new"
            ],
            results: results,
            submoduleRootPaths: ["/workspace/project/vendor/lib"],
            previousHeadBranches: [
                "/workspace/project": "main",
                "/workspace/project/vendor/lib": ""
            ]
        )

        XCTAssertEqual(
            targets.map(\.rootPath),
            ["/workspace/project/vendor/lib", "/workspace/project"]
        )
        XCTAssertEqual(targets.map(\.initialHead), ["c-old", "p-old"])
        XCTAssertEqual(targets.map(\.expectedHead), ["c-new", "p-new"])
        XCTAssertEqual(targets.map { $0.expectedHeadBranch ?? "<missing>" }, ["", "main"])
        XCTAssertEqual(targets.map(\.ignoredPaths), [[], ["vendor/lib"]])
    }

    func testStandaloneSubmoduleUpdateBuildsOnlyMovedChildUndoTargets() {
        let before = [
            GitRootInfo(
                path: "/workspace/project",
                displayName: "project",
                relativePath: ".",
                isSubmodule: false,
                headBranch: "main",
                headId: "parent",
                dirty: false,
                operation: nil
            ),
            GitRootInfo(
                path: "/workspace/project/vendor/lib",
                displayName: "lib",
                relativePath: "vendor/lib",
                isSubmodule: true,
                headBranch: nil,
                headId: "child-old",
                dirty: false,
                operation: nil
            )
        ]
        let after = [
            before[0],
            GitRootInfo(
                path: "/workspace/project/vendor/lib",
                displayName: "lib",
                relativePath: "vendor/lib",
                isSubmodule: true,
                headBranch: nil,
                headId: "child-new",
                dirty: false,
                operation: nil
            )
        ]

        let targets = ContentView.submoduleUpdateRollbackTargets(before: before, after: after)

        XCTAssertEqual(targets.map(\.rootPath), ["/workspace/project/vendor/lib"])
        XCTAssertEqual(targets.map(\.initialHead), ["child-old"])
        XCTAssertEqual(targets.map(\.expectedHead), ["child-new"])
        XCTAssertEqual(targets.map { $0.expectedHeadBranch ?? "<missing>" }, [""])
        XCTAssertEqual(targets.map(\.ignoredPaths), [[]])
    }

    func testAutoFetchRootPathsIncludePrimaryAndDiscoveredRootsExactlyOnce() {
        XCTAssertEqual(
            mergedAutoFetchRootPaths(
                primary: "/project",
                discovered: ["/project/root-b", "/project", "/project/root-a"]
            ),
            ["/project", "/project/root-a", "/project/root-b"]
        )
    }

    func testNativeNotificationActionTitlesRouteToVCSActions() {
        XCTAssertEqual(
            arborVCSAction(forNativeNotificationActionTitle: "Fetch All")?.rawValue,
            ArborVCSAction.fetchAll.rawValue
        )
        XCTAssertEqual(
            arborVCSAction(forNativeNotificationActionTitle: "Retry Check")?.rawValue,
            ArborVCSAction.retryAutoFetch.rawValue
        )
        XCTAssertEqual(
            arborVCSAction(forNativeNotificationActionTitle: "Enable Auto-fetch")?.rawValue,
            ArborVCSAction.enableAutoFetch.rawValue
        )
        XCTAssertNil(arborVCSAction(forNativeNotificationActionTitle: "Unknown"))
    }

    func testNativeNotificationActionsOnlyExposeReplayableActions() {
        let semanticAction = FeedbackAction(
            title: "Configure GPG Agent…",
            semanticAction: ArborVCSActionRequest(
                kind: .openGpgAgentSettings,
                projectPath: "/project",
                rootPath: nil,
                shelfName: ""
            )
        ) {}
        let fallbackAction = FeedbackAction(title: "Fetch All") {}
        let closureOnlyAction = FeedbackAction(title: "Resolve Conflicts") {}

        XCTAssertEqual(
            arborNativeNotificationActions([
                closureOnlyAction,
                semanticAction,
                fallbackAction
            ]).map(\.title),
            ["Configure GPG Agent…", "Fetch All"]
        )
    }

    func testShelfActionRequestRoundTripsAcrossPersistenceBoundary() throws {
        let request = ArborVCSActionRequest(
            kind: .restoreShelf,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "WIP: review"
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ArborVCSActionRequest.self, from: data)

        XCTAssertEqual(decoded, request)
    }

    func testShelfDeletePlanMatchesIntellijDeleteProviderSelectionScope() {
        let active = shelf("active", id: "active-id", paths: ["Sources/A.swift", "Sources/B.swift"])
        let activeMemberOnly = shelf("active-member", id: "active-member-id", paths: ["Sources/C.swift"])
        let deleted = shelf("deleted", id: "deleted-id", paths: ["Tests/A.swift", "Tests/B.swift"], deleted: true)

        let plan = shelfDeletePlan(
            visibleShelves: [active, activeMemberOnly],
            deletedShelves: [deleted],
            selectedShelfIDs: [active.id],
            selectedShelfMemberIDs: [
                shelfMemberSelectionID(shelfID: active.id, path: "Sources/B.swift"),
                shelfMemberSelectionID(shelfID: activeMemberOnly.id, path: "Sources/C.swift")
            ],
            selectedDeletedShelfIDs: [],
            selectedDeletedShelfMemberIDs: [
                shelfMemberSelectionID(shelfID: deleted.id, path: "Tests/A.swift")
            ]
        )

        XCTAssertEqual(plan.activeShelfNames, ["active"])
        XCTAssertEqual(
            plan.activePathGroups,
            [ShelfPathDeleteGroup(shelfName: "active-member", paths: ["Sources/C.swift"])]
        )
        XCTAssertEqual(plan.deletedShelfNames, [])
        XCTAssertEqual(
            plan.deletedPathGroups,
            [ShelfPathDeleteGroup(shelfName: "deleted", paths: ["Tests/A.swift"])]
        )
    }

    func testShelfDeletePlanExpandsMixedScopesInStableOrder() {
        let plan = ShelfDeletePlan(
            activeShelfNames: ["active-whole"],
            activePathGroups: [
                ShelfPathDeleteGroup(shelfName: "active-members", paths: ["Sources/A.swift"])
            ],
            deletedShelfNames: ["deleted-whole"],
            deletedPathGroups: [
                ShelfPathDeleteGroup(shelfName: "deleted-members", paths: ["Tests/A.swift"])
            ]
        )

        XCTAssertEqual(
            shelfDeleteOperations(plan),
            [
                ShelfDeleteOperation(kind: .activeShelf, shelfName: "active-whole", paths: []),
                ShelfDeleteOperation(
                    kind: .activePaths,
                    shelfName: "active-members",
                    paths: ["Sources/A.swift"]
                ),
                ShelfDeleteOperation(kind: .deletedShelf, shelfName: "deleted-whole", paths: []),
                ShelfDeleteOperation(
                    kind: .deletedPaths,
                    shelfName: "deleted-members",
                    paths: ["Tests/A.swift"]
                )
            ]
        )
        XCTAssertEqual(
            Set(shelfDeleteOperations(plan).map(\.key)).count,
            4
        )
        XCTAssertEqual(
            shelfDeleteOperations(plan).map(\.displayName),
            [
                "active-whole",
                "active-members",
                "deleted-whole (Recently Deleted)",
                "deleted-members (Recently Deleted)"
            ]
        )
    }

    func testDeletedShelfMemberDeleteActionKeepsRootAndPaths() throws {
        let request = ArborVCSActionRequest(
            kind: .deleteDeletedShelfPaths,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "WIP: review (deleted)",
            shelfPaths: ["Sources/App.swift", "Tests/AppTests.swift"]
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.rootPath, "/project/app")
        XCTAssertEqual(decoded.shelfPaths, ["Sources/App.swift", "Tests/AppTests.swift"])
    }

    func testUpdateSessionLogRangeActionRoundTripsRootQualifiedRanges() throws {
        let request = ArborVCSActionRequest(
            kind: .showLogRanges,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            logRevisionRanges: [
                PersistedLogRevisionRange(
                    rootPath: "/project/app",
                    oldRevision: "1111111",
                    newRevision: "2222222"
                ),
                PersistedLogRevisionRange(
                    rootPath: "/project/docs",
                    oldRevision: "3333333",
                    newRevision: "4444444"
                )
            ]
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.logRevisionRanges?.map(\.rootPath), ["/project/app", "/project/docs"])
        XCTAssertEqual(decoded.logRevisionRanges?.last?.oldRevision, "3333333")
    }

    @MainActor
    func testFeedbackHistoryRestoresUpdateSessionLogRangeActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterUpdateSessionLogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .showLogRanges,
            projectPath: "/project",
            rootPath: nil,
            shelfName: "",
            logRevisionRanges: [
                PersistedLogRevisionRange(
                    rootPath: "/project/app",
                    oldRevision: "1111111",
                    newRevision: "2222222"
                )
            ]
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.success(
            "Update completed",
            additionalActions: [
                FeedbackAction(title: "View Commits", semanticAction: request) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(
            reloaded.history.first?.actions.first?.semanticAction,
            request
        )
    }

    @MainActor
    func testFeedbackHistoryRestoresPushRecoveryViewCommitsActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterPushRecoveryLogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .showLogRanges,
            projectPath: "/project",
            rootPath: "/project/app",
            shelfName: "",
            logRevisionRanges: [
                PersistedLogRevisionRange(
                    rootPath: "/project/app",
                    oldRevision: "push-before",
                    newRevision: "push-after"
                )
            ]
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.success(
            "Update Push Roots completed",
            detail: "App updated and pushed",
            additionalActions: [
                FeedbackAction(title: "View Commits", semanticAction: request) {}
            ],
            notificationID: "git.multi-root.push.recovery",
            notificationGroup: .standard,
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.notificationID, "git.multi-root.push.recovery")
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testFeedbackHistoryRestoresRootPushRecoveryViewCommitsActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterRootPushRecoveryLogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .showLogRanges,
            projectPath: "/project",
            rootPath: "/project/app",
            shelfName: "",
            logRevisionRanges: [
                PersistedLogRevisionRange(
                    rootPath: "/project/app",
                    oldRevision: "update-before",
                    newRevision: "update-after"
                )
            ]
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.success(
            "Push completed",
            detail: "origin/main · /project/app",
            additionalActions: [
                FeedbackAction(title: "View Commits", semanticAction: request) {}
            ],
            notificationID: "arbor.push.v1.root-app",
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.notificationID, "arbor.push.v1.root-app")
        XCTAssertEqual(reloaded.history.first?.actions.first?.title, "View Commits")
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    func testRebaseRecoveryActionRequestRoundTripsBranchContext() throws {
        let request = ArborVCSActionRequest(
            kind: .resumeRebase,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "",
            rebaseBranch: "feature"
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.rebaseBranch, "feature")
    }

    func testShelfDeletionUndoActionRequestPreservesOriginalTimestamp() throws {
        let request = ArborVCSActionRequest(
            kind: .undoShelfDeletion,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "WIP: review",
            shelfRestoreTimestamp: 1_725_000_123
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ArborVCSActionRequest.self, from: data)

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.shelfRestoreTimestamp, 1_725_000_123)
    }

    func testShelfBatchDeletionUndoActionPreservesAllOriginalTimestamps() throws {
        let request = ArborVCSActionRequest(
            kind: .undoShelfDeletions,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "",
            shelfRestoreTimestamps: [
                "WIP: one": 1_725_000_123,
                "WIP: two": 1_725_000_456
            ],
            shelfNames: ["WIP: one", "WIP: two"]
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.shelfRestoreTimestamps?["WIP: two"], 1_725_000_456)
    }

    func testShelfDeletedMemberUndoActionRequestPreservesPaths() throws {
        let request = ArborVCSActionRequest(
            kind: .restoreShelfPaths,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "WIP: review-deleted-members",
            shelfPaths: ["Sources/App.swift", "README.md"],
            shelfRestoreTimestamp: 1_725_000_123
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ArborVCSActionRequest.self, from: data)

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.shelfPaths, ["Sources/App.swift", "README.md"])
    }

    func testSavedChangesActionRequestRoundTripsAndKeepsLegacyPayloadsReadable() throws {
        let request = ArborVCSActionRequest(
            kind: .showSavedChanges,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "",
            savedChangesKind: .stash,
            savedChangesID: "stash@{2}:abc123"
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ArborVCSActionRequest.self, from: data)

        XCTAssertEqual(decoded, request)

        let legacyJSON = #"{"kind":"restoreShelf","projectPath":"/project/app","rootPath":"/project/app","shelfName":"WIP: review"}"#
        let legacyRequest = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertEqual(legacyRequest.kind, .restoreShelf)
        XCTAssertNil(legacyRequest.savedChangesKind)
        XCTAssertNil(legacyRequest.savedChangesID)
    }

    func testShelfBatchRetryActionRequestRoundTripsAndKeepsLegacyPayloadsReadable() throws {
        let request = ArborVCSActionRequest(
            kind: .retryShelfBatch,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "",
            shelfNames: ["WIP: one", "WIP: two"],
            shelfBatchOperation: .pop,
            shelfBatchTargetName: nil,
            shelfBatchRemoveApplied: true
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ArborVCSActionRequest.self, from: data)

        XCTAssertEqual(decoded, request)

        let legacyJSON = #"{"kind":"restoreShelf","projectPath":"/project/app","rootPath":"/project/app","shelfName":"WIP: review"}"#
        let legacyRequest = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertNil(legacyRequest.shelfNames)
        XCTAssertNil(legacyRequest.shelfBatchOperation)
        XCTAssertNil(legacyRequest.shelfBatchRemoveApplied)
    }

    func testShelfBatchDropActionRequestRoundTrips() throws {
        let request = ArborVCSActionRequest(
            kind: .retryShelfBatch,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "",
            shelfNames: ["WIP: one", "WIP: two"],
            shelfBatchOperation: .drop,
            shelfBatchTargetName: nil,
            shelfBatchRemoveApplied: false
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ArborVCSActionRequest.self, from: data)

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.shelfBatchOperation, .drop)
    }

    func testShelfDeletePlanRetryActionRequestRoundTrips() throws {
        let plan = ShelfDeletePlan(
            activeShelfNames: ["active"],
            activePathGroups: [
                ShelfPathDeleteGroup(shelfName: "active-members", paths: ["Sources/A.swift"])
            ],
            deletedShelfNames: ["deleted"],
            deletedPathGroups: [
                ShelfPathDeleteGroup(shelfName: "deleted-members", paths: ["Tests/A.swift"])
            ]
        )
        let request = ArborVCSActionRequest(
            kind: .retryShelfDeletePlan,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "",
            shelfDeletePlan: PersistedShelfDeletePlan(plan)
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.shelfDeletePlan?.shelfDeletePlan, plan)
    }

    func testShelfMemberBatchRetryActionRequestRoundTripsGroupedPaths() throws {
        let request = ArborVCSActionRequest(
            kind: .retryShelfMemberBatch,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "",
            shelfMemberGroups: [
                PersistedShelfPathGroup(
                    shelfName: "WIP: one",
                    paths: ["Sources/App.swift", "Tests/AppTests.swift"]
                ),
                PersistedShelfPathGroup(
                    shelfName: "WIP: two",
                    paths: ["README.md"]
                )
            ],
            shelfMemberBatchOperation: .unshelveDeletedAndRemove,
            shelfMemberBatchTargetName: "Review"
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ArborVCSActionRequest.self, from: data)

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.shelfMemberGroups?.count, 2)
        XCTAssertEqual(decoded.shelfMemberBatchOperation, .unshelveDeletedAndRemove)
        XCTAssertEqual(decoded.shelfMemberBatchTargetName, "Review")

        let legacyJSON = #"{"kind":"retryShelfMemberBatch","projectPath":"/project/app","rootPath":"/project/app","shelfName":"","shelfMemberGroups":[{"shelfName":"WIP: one","paths":["Sources/App.swift"]}],"shelfMemberBatchOperation":"unshelve"}"#
        let legacyRequest = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertNil(legacyRequest.shelfMemberBatchTargetName)
    }

    func testShelfLifecycleBatchRetryActionRequestRoundTrips() throws {
        let request = ArborVCSActionRequest(
            kind: .retryShelfLifecycleBatch,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "",
            shelfNames: ["WIP: one", "WIP: two"],
            shelfLifecycleOperation: .deleteDeleted
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ArborVCSActionRequest.self, from: data)

        XCTAssertEqual(decoded, request)
        XCTAssertNil(decoded.shelfBatchOperation)
        XCTAssertNil(decoded.shelfBatchRemoveApplied)
    }

    func testLogApplyRecoveryActionRequestRoundTripsRootAndHeadGuard() throws {
        let recovery = PersistedLogApplyRecovery(
            operation: .cherryPick,
            rootPath: "/project/app",
            commitIDs: ["older", "newer"],
            sessionID: "log-session",
            batchIndex: 0,
            batchCount: 1,
            initialHead: "head-before-retry",
            preserveLocalChanges: true,
            emptyPolicyRaw: "createEmpty",
            appendPublishedSuffix: true,
            savePolicyRaw: "shelve"
        )
        let request = ArborVCSActionRequest(
            kind: .retryLogApply,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "",
            logApplyRecovery: recovery
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ArborVCSActionRequest.self, from: data)

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.logApplyRecovery?.commitIDs, ["older", "newer"])
        XCTAssertEqual(decoded.logApplyRecovery?.initialHead, "head-before-retry")
        XCTAssertEqual(decoded.logApplyRecovery?.operation, .cherryPick)
        XCTAssertEqual(decoded.logApplyRecovery?.affectedPaths, [])
    }

    func testLogApplyRecoverySaveAndRetryContextPreservesGuardsAndAffectedPaths() {
        let direct = PersistedLogApplyRecovery(
            operation: .revert,
            rootPath: "/project/app",
            commitIDs: ["commit"],
            sessionID: "session",
            batchIndex: 0,
            batchCount: 1,
            initialHead: "head-before-retry",
            preserveLocalChanges: false,
            emptyPolicyRaw: "skip",
            appendPublishedSuffix: false,
            savePolicyRaw: "shelve"
        )

        let saveAndRetry = direct.updating(
            preserveLocalChanges: true,
            affectedPaths: ["Sources/App.swift", "Resources/Info.plist"]
        )

        XCTAssertEqual(saveAndRetry.operation, direct.operation)
        XCTAssertEqual(saveAndRetry.rootPath, direct.rootPath)
        XCTAssertEqual(saveAndRetry.commitIDs, direct.commitIDs)
        XCTAssertEqual(saveAndRetry.sessionID, direct.sessionID)
        XCTAssertEqual(saveAndRetry.batchIndex, direct.batchIndex)
        XCTAssertEqual(saveAndRetry.batchCount, direct.batchCount)
        XCTAssertEqual(saveAndRetry.initialHead, direct.initialHead)
        XCTAssertEqual(saveAndRetry.emptyPolicyRaw, direct.emptyPolicyRaw)
        XCTAssertEqual(saveAndRetry.appendPublishedSuffix, direct.appendPublishedSuffix)
        XCTAssertEqual(saveAndRetry.savePolicyRaw, direct.savePolicyRaw)
        XCTAssertTrue(saveAndRetry.preserveLocalChanges)
        XCTAssertEqual(saveAndRetry.affectedPaths, ["Sources/App.swift", "Resources/Info.plist"])
        XCTAssertEqual(logApplyRecoveryActionTitle(direct), "Retry Revert")
        XCTAssertEqual(logApplyRecoveryActionTitle(saveAndRetry), "Save and Retry Revert (Shelf)")
    }

    func testLogApplyShowFilesActionRequestRoundTripsAffectedPaths() throws {
        let recovery = PersistedLogApplyRecovery(
            operation: .cherryPick,
            rootPath: "/project/app",
            commitIDs: ["commit"],
            sessionID: "session",
            batchIndex: 0,
            batchCount: 1,
            initialHead: "head-before-retry",
            preserveLocalChanges: true,
            emptyPolicyRaw: "skip",
            appendPublishedSuffix: false,
            savePolicyRaw: "stash",
            affectedPaths: ["Sources/App.swift"]
        )
        let request = ArborVCSActionRequest(
            kind: .showLogApplyAffectedFiles,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "",
            logApplyRecovery: recovery
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.kind, .showLogApplyAffectedFiles)
        XCTAssertEqual(decoded.logApplyRecovery?.affectedPaths, ["Sources/App.swift"])
    }

    func testStashBranchRetryRequestRoundTripsIdentityAndExpectedState() throws {
        let retry = PersistedStashBranchRetry(
            stashID: "stash-object-id",
            branch: "wip/branch",
            expectedCurrentBranch: "main",
            expectedCurrentHead: "head-before-retry"
        )
        let request = ArborVCSActionRequest(
            kind: .retryStashBranch,
            projectPath: "/project",
            rootPath: "/project/nested",
            shelfName: "",
            stashBranchRetry: retry
        )

        let decoded = try JSONDecoder().decode(
            ArborVCSActionRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertTrue(
            stashBranchRetryStateIsSafe(
                retry,
                currentBranch: "main",
                currentHead: "head-before-retry",
                stashIDs: ["other", "stash-object-id"],
                localBranches: ["main"]
            )
        )
        XCTAssertFalse(
            stashBranchRetryStateIsSafe(
                retry,
                currentBranch: "wip/branch",
                currentHead: "head-before-retry",
                stashIDs: ["stash-object-id"],
                localBranches: ["main", "wip/branch"]
            )
        )
    }

    func testLegacyLogApplyRecoveryPayloadDefaultsToSingleRootSession() throws {
        let legacyPayload = #"""
        {
            "operation": "revert",
            "rootPath": "/project/app",
            "commitIDs": ["commit"],
            "initialHead": "head-before-retry",
            "preserveLocalChanges": false,
            "emptyPolicyRaw": "skip",
            "appendPublishedSuffix": false,
            "savePolicyRaw": "stash"
        }
        """#.data(using: .utf8)!

        let recovery = try JSONDecoder().decode(
            PersistedLogApplyRecovery.self,
            from: legacyPayload
        )

        XCTAssertEqual(recovery.sessionID, "legacy:/project/app")
        XCTAssertEqual(recovery.batchIndex, 0)
        XCTAssertEqual(recovery.batchCount, 1)
        XCTAssertEqual(recovery.commitIDs, ["commit"])
    }

    func testLogApplyRecoveryOnlyRunsTheEarliestPendingRoot() {
        let first = PersistedLogApplyRecovery(
            operation: .revert,
            rootPath: "/project/one",
            commitIDs: ["one"],
            sessionID: "ordered-session",
            batchIndex: 0,
            batchCount: 2,
            initialHead: "head-one",
            preserveLocalChanges: false,
            emptyPolicyRaw: "skip",
            appendPublishedSuffix: false,
            savePolicyRaw: "stash"
        )
        let second = PersistedLogApplyRecovery(
            operation: .revert,
            rootPath: "/project/two",
            commitIDs: ["two"],
            sessionID: "ordered-session",
            batchIndex: 1,
            batchCount: 2,
            initialHead: "head-two",
            preserveLocalChanges: false,
            emptyPolicyRaw: "skip",
            appendPublishedSuffix: false,
            savePolicyRaw: "stash"
        )

        XCTAssertTrue(logApplyRecoveryCanRun(first, pending: [second, first]))
        XCTAssertFalse(logApplyRecoveryCanRun(second, pending: [first, second]))
    }

    func testAbortingLogApplyCancelsEveryPendingRootInTheSession() {
        let first = PersistedLogApplyRecovery(
            operation: .cherryPick,
            rootPath: "/project/one",
            commitIDs: ["one"],
            sessionID: "cancelled-session",
            batchIndex: 0,
            batchCount: 2,
            initialHead: "head-one",
            preserveLocalChanges: false,
            emptyPolicyRaw: "skip",
            appendPublishedSuffix: false,
            savePolicyRaw: "stash"
        )
        let second = PersistedLogApplyRecovery(
            operation: .cherryPick,
            rootPath: "/project/two",
            commitIDs: ["two"],
            sessionID: "cancelled-session",
            batchIndex: 1,
            batchCount: 2,
            initialHead: "head-two",
            preserveLocalChanges: false,
            emptyPolicyRaw: "skip",
            appendPublishedSuffix: false,
            savePolicyRaw: "stash"
        )
        let unrelated = PersistedLogApplyRecovery(
            operation: .cherryPick,
            rootPath: "/project/other",
            commitIDs: ["other"],
            sessionID: "other-session",
            batchIndex: 0,
            batchCount: 1,
            initialHead: "other-head",
            preserveLocalChanges: false,
            emptyPolicyRaw: "skip",
            appendPublishedSuffix: false,
            savePolicyRaw: "stash"
        )

        let targets = logApplyRecoveryCancellationTargets(
            current: first,
            pending: [unrelated, second, first]
        )

        XCTAssertEqual(targets.map(\.rootPath), ["/project/one", "/project/two"])
        XCTAssertEqual(targets.map(\.batchIndex), [0, 1])
    }

    @MainActor
    func testFeedbackHistoryRetainsNotificationActions() {
        let feedbackCenter = FeedbackCenter()
        var invoked = false

        feedbackCenter.warning(
            "Push rejected",
            actionTitle: "Retry Push",
            action: { invoked = true },
            localized: false
        )

        XCTAssertEqual(feedbackCenter.history.first?.actions.map(\.title), ["Retry Push"])
        feedbackCenter.history.first?.actions.first?.action()
        XCTAssertTrue(invoked)
    }

    @MainActor
    func testFeedbackCenterTracksBatchProgressUntilOperationFinishes() {
        let feedbackCenter = FeedbackCenter()
        feedbackCenter.begin("Unshelve shelves silently")
        XCTAssertTrue(feedbackCenter.history.first?.isRunning == true)
        feedbackCenter.updateBatchProgress(
            completed: 1,
            total: 4,
            phase: "Unshelve Shelf",
            detail: "WIP: one"
        )

        XCTAssertEqual(feedbackCenter.batchProgress?.completed, 1)
        XCTAssertEqual(feedbackCenter.batchProgress?.total, 4)
        XCTAssertEqual(feedbackCenter.batchProgress?.percentage, 25)
        XCTAssertEqual(feedbackCenter.batchProgress?.detail, "WIP: one")

        feedbackCenter.success("Shelves unshelved silently", localized: false)
        XCTAssertNil(feedbackCenter.batchProgress)
        XCTAssertFalse(feedbackCenter.history.first?.isRunning == true)
    }

    @MainActor
    func testFeedbackCleanShelfLifecycleReusesStableNotificationEntry() {
        let suiteName = "Arbor.FeedbackCleanShelfTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let notificationID = shelfNotificationID(
            prefix: "shelf-metadata.clean",
            rootPath: "/workspace/app"
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)

        feedbackCenter.begin("Clear Already Unshelved", notificationID: notificationID)
        feedbackCenter.success(
            "Already unshelved shelves cleared",
            detail: "WIP: first",
            notificationID: notificationID,
            localized: false
        )
        feedbackCenter.begin("Clear Already Unshelved", notificationID: notificationID)
        feedbackCenter.warning(
            "No already unshelved shelves to clear",
            notificationID: notificationID,
            localized: false
        )

        XCTAssertEqual(feedbackCenter.history.count, 1)
        XCTAssertEqual(feedbackCenter.history.first?.notificationID, notificationID)
        XCTAssertEqual(feedbackCenter.history.first?.title, "No already unshelved shelves to clear")
    }

    @MainActor
    func testFeedbackHistoryPersistsSafeSummaryAcrossCenterReload() {
        let suiteName = "Arbor.FeedbackCenterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Push rejected",
            detail: "origin/main rejected the update",
            actionTitle: "Retry Push",
            action: {},
            additionalActions: [FeedbackAction(title: "Open Git Roots") {}],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.count, 1)
        XCTAssertEqual(reloaded.history.first?.title, "Push rejected")
        XCTAssertEqual(reloaded.history.first?.detail, "origin/main rejected the update")
        XCTAssertEqual(reloaded.history.first?.actionTitles, ["Retry Push", "Open Git Roots"])
        XCTAssertTrue(reloaded.history.first?.actions.isEmpty == true)
        XCTAssertNil(reloaded.history.first?.command)
        XCTAssertNil(reloaded.history.first?.stdout)
        XCTAssertNil(reloaded.history.first?.stderr)
    }

    @MainActor
    func testFeedbackHistoryRestoresSemanticSubsetFromMixedActions() {
        let suiteName = "Arbor.FeedbackCenterMixedActionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .showLogRanges,
            projectPath: "/project",
            rootPath: "/project/app",
            shelfName: "",
            logRevisionRanges: [
                PersistedLogRevisionRange(
                    rootPath: "/project/app",
                    oldRevision: "1111111",
                    newRevision: "2222222"
                )
            ]
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Update partially completed",
            actionTitle: "Resolve Conflicts",
            action: {},
            additionalActions: [
                FeedbackAction(title: "View Commits", semanticAction: request) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.actionTitles, ["Resolve Conflicts", "View Commits"])
        XCTAssertEqual(reloaded.history.first?.actions.map(\.title), ["View Commits"])
        XCTAssertEqual(reloaded.history.first?.actions.first?.semanticAction, request)
    }

    @MainActor
    func testFeedbackHistoryRestoresSemanticShelfActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterShelfActionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .dropShelf,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "WIP: review"
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.success(
            "Shelf restored",
            additionalActions: [
                FeedbackAction(title: "Drop", semanticAction: request) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        let action = reloaded.history.first?.actions.first
        XCTAssertEqual(action?.title, "Drop")
        XCTAssertEqual(action?.semanticAction, request)
    }

    @MainActor
    func testFeedbackHistoryRestoresShelfBatchRetryActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterShelfBatchActionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .retryShelfBatch,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "",
            shelfNames: ["WIP: remaining"],
            shelfBatchOperation: .apply,
            shelfBatchRemoveApplied: false
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Some shelves were not unshelved",
            additionalActions: [
                FeedbackAction(
                    title: "Retry Remaining Shelves",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        let action = reloaded.history.first?.actions.first
        XCTAssertEqual(action?.title, "Retry Remaining Shelves")
        XCTAssertEqual(action?.semanticAction, request)
    }

    @MainActor
    func testFeedbackHistoryRestoresShelfMemberTargetRetryActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterShelfMemberTargetActionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .retryShelfMemberBatch,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "",
            shelfMemberGroups: [
                PersistedShelfPathGroup(shelfName: "WIP: one", paths: ["Sources/App.swift"]),
                PersistedShelfPathGroup(shelfName: "WIP: two", paths: ["Tests/AppTests.swift"])
            ],
            shelfMemberBatchOperation: .unshelveAndRemove,
            shelfMemberBatchTargetName: "Review"
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Some Shelf changes were not unshelved",
            additionalActions: [
                FeedbackAction(
                    title: "Retry Remaining Shelf Changes",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        let action = reloaded.history.first?.actions.first
        XCTAssertEqual(action?.title, "Retry Remaining Shelf Changes")
        XCTAssertEqual(action?.semanticAction, request)
    }

    @MainActor
    func testFeedbackHistoryRestoresShelfLifecycleBatchRetryActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterShelfLifecycleBatchActionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .retryShelfLifecycleBatch,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "",
            shelfNames: ["WIP: remaining"],
            shelfLifecycleOperation: .restoreDeleted
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Some shelves restored",
            additionalActions: [
                FeedbackAction(
                    title: "Retry Remaining Shelf Actions",
                    semanticAction: request
                ) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        let action = reloaded.history.first?.actions.first
        XCTAssertEqual(action?.title, "Retry Remaining Shelf Actions")
        XCTAssertEqual(action?.semanticAction, request)
    }

    @MainActor
    func testFeedbackHistoryRestoresSavedChangesPreviewActionAcrossReload() {
        let suiteName = "Arbor.FeedbackCenterSavedChangesActionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = ArborVCSActionRequest(
            kind: .showSavedChanges,
            projectPath: "/project/app",
            rootPath: "/project/app",
            shelfName: "",
            savedChangesKind: .stash,
            savedChangesID: "stash@{2}:abc123"
        )
        let feedbackCenter = FeedbackCenter(defaults: defaults)
        feedbackCenter.warning(
            "Local changes were not restored",
            additionalActions: [
                FeedbackAction(title: "View saved changes…", semanticAction: request) {}
            ],
            localized: false
        )

        let reloaded = FeedbackCenter(defaults: defaults)
        let action = reloaded.history.first?.actions.first
        XCTAssertEqual(action?.title, "View saved changes…")
        XCTAssertEqual(action?.semanticAction, request)
    }

    func testAutoFetchSuggestionStopsAfterDismissalOrThreePrompts() {
        XCTAssertTrue(
            shouldSuggestAutoFetch(
                autoFetchEnabled: false,
                suggestionDisabled: false,
                shownCount: 0
            )
        )
        XCTAssertFalse(
            shouldSuggestAutoFetch(
                autoFetchEnabled: true,
                suggestionDisabled: false,
                shownCount: 0
            )
        )
        XCTAssertFalse(
            shouldSuggestAutoFetch(
                autoFetchEnabled: false,
                suggestionDisabled: true,
                shownCount: 0
            )
        )
        XCTAssertFalse(
            shouldSuggestAutoFetch(
                autoFetchEnabled: false,
                suggestionDisabled: false,
                shownCount: 3
            )
        )
    }

    func testIncomingCheckStrategyMigratesLegacyAutoFetchAndRejectsUnknownValues() {
        XCTAssertEqual(
            resolveGitIncomingCheckStrategy(storedRawValue: nil, legacyAutoFetch: true),
            .fetch
        )
        XCTAssertEqual(
            resolveGitIncomingCheckStrategy(storedRawValue: nil, legacyAutoFetch: false),
            .lsRemote
        )
        XCTAssertEqual(
            resolveGitIncomingCheckStrategy(storedRawValue: GitIncomingCheckStrategy.lsRemote.rawValue, legacyAutoFetch: true),
            .lsRemote
        )
        XCTAssertEqual(
            resolveGitIncomingCheckStrategy(storedRawValue: "future", legacyAutoFetch: true),
            .none
        )
    }

    func testProjectIncomingStrategyOverridesOnlyItsProjectAndCanInheritGlobal() {
        let suiteName = "Arbor.IncomingStrategyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(GitIncomingCheckStrategy.fetch.rawValue, forKey: GitIncomingCheckStrategy.userDefaultsKey)
        let firstProject = "/tmp/arbor-first-project"
        let secondProject = "/tmp/arbor-second-project"

        XCTAssertEqual(
            GitIncomingCheckStrategySettings.effectiveStrategy(for: firstProject, defaults: defaults),
            .fetch
        )

        GitIncomingCheckStrategySettings.saveProjectStrategy(.lsRemote, for: firstProject, defaults: defaults)
        XCTAssertEqual(
            GitIncomingCheckStrategySettings.effectiveStrategy(for: firstProject, defaults: defaults),
            .lsRemote
        )
        XCTAssertEqual(
            GitIncomingCheckStrategySettings.effectiveStrategy(for: secondProject, defaults: defaults),
            .fetch
        )

        GitIncomingCheckStrategySettings.saveProjectStrategy(nil, for: firstProject, defaults: defaults)
        XCTAssertEqual(
            GitIncomingCheckStrategySettings.projectChoice(for: firstProject, defaults: defaults),
            .useGlobal
        )
        XCTAssertEqual(
            GitIncomingCheckStrategySettings.effectiveStrategy(for: firstProject, defaults: defaults),
            .fetch
        )
        XCTAssertNotEqual(
            GitIncomingCheckStrategySettings.projectKey(for: firstProject),
            GitIncomingCheckStrategySettings.projectKey(for: secondProject)
        )
    }

    func testIncomingAutoFetchSuggestionStateIsProjectScoped() {
        let suiteName = "Arbor.IncomingSuggestionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(3, forKey: "arbor.git.autoFetchSuggestionCount.v1")
        defaults.set(true, forKey: "arbor.git.autoFetchSuggestionDisabled.v1")
        let project = "/tmp/arbor-suggestion-project"

        XCTAssertEqual(
            GitIncomingCheckStrategySettings.suggestionCount(for: project, defaults: defaults),
            0
        )
        XCTAssertFalse(
            GitIncomingCheckStrategySettings.suggestionDisabled(for: project, defaults: defaults)
        )

        GitIncomingCheckStrategySettings.setSuggestionCount(2, for: project, defaults: defaults)
        GitIncomingCheckStrategySettings.setSuggestionDisabled(true, for: project, defaults: defaults)
        XCTAssertEqual(
            GitIncomingCheckStrategySettings.suggestionCount(for: project, defaults: defaults),
            2
        )
        XCTAssertTrue(
            GitIncomingCheckStrategySettings.suggestionDisabled(for: project, defaults: defaults)
        )
    }
}
