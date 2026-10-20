import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {

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
}
