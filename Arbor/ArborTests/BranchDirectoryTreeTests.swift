import XCTest
@testable import Arbor


final class BranchDirectoryTreeTests: XCTestCase {
    func testBranchDashboardReferencesExposeRootQualifiedFavoriteIDs() {
        let local = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false
        )
        let remote = BranchDashboardReference(
            rootPath: "/repo-b",
            name: "origin/feature/login",
            kind: .remote,
            remote: "origin",
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: false
        )

        XCTAssertEqual(local.favoriteID, "local:/repo-a:feature/login")
        XCTAssertEqual(remote.favoriteID, "remote:/repo-b:origin/feature/login")
        XCTAssertNotEqual(local.favoriteID, remote.favoriteID)
    }

    func testLogBranchSelectionActionPersistsTheThreeIntellijModes() {
        XCTAssertEqual(
            LogBranchSelectionAction.allCases.map(\.rawValue),
            ["navigate", "filter", "none"]
        )
        XCTAssertEqual(LogBranchSelectionAction(rawValue: "navigate")?.title, "Navigate Log")
        XCTAssertEqual(LogBranchSelectionAction(rawValue: "filter")?.title, "Filter Log")
        XCTAssertEqual(LogBranchSelectionAction(rawValue: "none")?.title, "Select Only")
    }

    func testLogBranchDashboardFiltersAreRootQualifiedAndExcludeTags() {
        func reference(
            _ rootPath: String,
            _ name: String,
            _ kind: BranchDashboardReferenceKind
        ) -> BranchDashboardReference {
            BranchDashboardReference(
                rootPath: rootPath,
                name: name,
                kind: kind,
                remote: kind == .remote ? "origin" : nil,
                isCurrent: false,
                hasUpstream: false,
                hasTracking: false,
                hasRemote: kind == .remote,
                isProtected: false
            )
        }

        XCTAssertEqual(
            logBranchFiltersForDashboardSelection([
                reference("/repo-a", "v1.0", .tag),
                reference("/repo-a", "feature/login", .local),
                reference("/repo-b", "origin/main", .remote),
                reference("/repo-a", "feature/login", .local),
                reference("/repo-a", "HEAD", .head)
            ]),
            [
                LogRootBranchFilter(rootPath: "/repo-a", branch: "feature/login"),
                LogRootBranchFilter(rootPath: "/repo-b", branch: "origin/main"),
                LogRootBranchFilter(rootPath: "/repo-a", branch: "HEAD")
            ]
        )
    }

    func testPrefixTreePreservesHierarchyAndScopesCollapsedGroups() {
        let rows = branchDirectoryRows(
            for: ["feature/login", "feature/ui", "hotfix/one"],
            grouped: true,
            scope: "local"
        )

        XCTAssertEqual(
            rows.map { "\($0.name)|\($0.depth)|\($0.isGroup)" },
            [
                "feature|0|true",
                "login|1|false",
                "ui|1|false",
                "hotfix|0|true",
                "one|1|false"
            ]
        )
        XCTAssertTrue(rows[0].id.hasPrefix("group:local:"))
        XCTAssertNotEqual(
            branchDirectoryRows(for: ["feature/login"], grouped: true, scope: "remote")[0].id,
            rows[0].id
        )

        let visible = visibleBranchDirectoryRows(
            rows,
            collapsedGroups: [rows[0].id]
        )
        XCTAssertEqual(
            visible.map { "\($0.name)|\($0.depth)|\($0.isGroup)" },
            [
                "feature|0|true",
                "hotfix|0|true",
                "one|1|false"
            ]
        )
    }

    func testBranchSearchSupportsWordsComponentsAndFuzzyInitials() {
        XCTAssertTrue(branchSearchMatches("feature/login", query: "login"))
        XCTAssertTrue(branchSearchMatches("feature/login", query: "fl"))
        XCTAssertTrue(branchSearchMatches("feature/login", query: "FEATURE"))
        XCTAssertTrue(branchSearchMatches("hotfix/login", query: "hot login"))
        XCTAssertFalse(branchSearchMatches("feature/login", query: "release"))

        let targets = [
            BranchTreeTarget(id: "recent", value: "feature/login", title: "login", kind: .recent),
            BranchTreeTarget(id: "local", value: "feature/login-long", title: "login-long", kind: .local),
            BranchTreeTarget(id: "remote", value: "origin/feature/login", title: "login", kind: .remote)
        ]
        XCTAssertEqual(
            bestBranchTreeTargetID(query: "feature/login", targets: targets),
            "recent"
        )
        XCTAssertEqual(
            bestBranchTreeTargetID(query: "", targets: targets, preserving: "local"),
            "local"
        )
    }

    func testBranchDashboardSingleLocalSelectionUsesRootScopedActionGroup() {
        let reference = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [reference])

        XCTAssertTrue(availability.contains(.checkout))
        XCTAssertTrue(availability.contains(.update))
        XCTAssertTrue(availability.contains(.merge))
        XCTAssertTrue(availability.contains(.rebase))
        XCTAssertTrue(availability.contains(.push))
        XCTAssertTrue(availability.contains(.unsetUpstream))
        XCTAssertTrue(availability.contains(.rename))
        XCTAssertTrue(availability.contains(.deleteLocal))
        XCTAssertTrue(availability.contains(.showDiffWithWorkingTree))
        XCTAssertTrue(availability.contains(.createWorktree))
        XCTAssertFalse(availability.contains(.setUpstream))
    }

    func testNewWorkingTreeRemainsSingleRootScopedForMultiRootReferences() {
        let first = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false
        )
        let second = BranchDashboardReference(
            rootPath: "/repo-b",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false
        )

        XCTAssertTrue(BranchDashboardActionAvailability.resolve(selection: [first]).contains(.createWorktree))
        XCTAssertTrue(BranchDashboardActionAvailability.resolve(selection: [second]).contains(.createWorktree))
        XCTAssertFalse(BranchDashboardActionAvailability.resolve(selection: [first, second]).contains(.createWorktree))
        XCTAssertNotEqual(first.rootPath, second.rootPath)
    }

    func testBranchRenameValidationMirrorsIntelliJLocalAndRemoteConflicts() {
        XCTAssertNil(
            branchRenameConflictMessage(
                oldName: "feature/login",
                newName: "topic",
                localBranchNames: ["feature/login", "feature/ui"],
                remoteBranchNames: ["origin/release"]
            )
        )
        XCTAssertEqual(
            branchRenameConflictMessage(
                oldName: "feature/login",
                newName: "feature",
                localBranchNames: ["feature/login", "feature/ui"],
                remoteBranchNames: []
            ),
            "Branch feature conflicts with an existing local branch."
        )
        XCTAssertEqual(
            branchRenameConflictMessage(
                oldName: "feature/login",
                newName: "release",
                localBranchNames: ["feature/login"],
                remoteBranchNames: ["origin/release"]
            ),
            "Branch release clashes with a remote branch."
        )
        XCTAssertEqual(
            branchRenameConflictMessage(
                oldName: "feature/login",
                newName: "feature/login",
                localBranchNames: ["feature/login"],
                remoteBranchNames: []
            ),
            "The new name must be different."
        )
    }

    func testLocalBranchPushRemainsVisibleWithoutConfiguredRemote() {
        let local = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/local-only",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [local])

        XCTAssertTrue(availability.contains(.push))
        XCTAssertFalse(availability.contains(.update))
    }

    func testBranchDashboardHeadSelectionUsesHeadOnlyActions() {
        let head = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "HEAD",
            kind: .head,
            remote: nil,
            isCurrent: true,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [head])

        XCTAssertTrue(availability.contains(.filterLog))
        XCTAssertTrue(availability.contains(.showDiffWithWorkingTree))
        XCTAssertTrue(availability.contains(.checkoutAsNewBranch))
        XCTAssertTrue(availability.contains(.createWorktree))
        XCTAssertFalse(availability.contains(.checkout))
        XCTAssertFalse(availability.contains(.merge))
        XCTAssertFalse(availability.contains(.deleteSelected))
    }

    func testBranchDashboardUnbornHeadDisablesBranchCreationActions() {
        let head = BranchDashboardReference(
            rootPath: "/repo-fresh",
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

        let availability = BranchDashboardActionAvailability.resolve(selection: [head])

        XCTAssertTrue(availability.contains(.checkoutAsNewBranch))
        XCTAssertTrue(availability.contains(.createWorktree))
        XCTAssertFalse(availability.isEnabled(.checkoutAsNewBranch))
        XCTAssertFalse(availability.isEnabled(.createWorktree))
    }

    func testBranchDashboardHeadAndBranchSelectionExposesPairComparisons() {
        let head = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "HEAD",
            kind: .head,
            remote: nil,
            isCurrent: true,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false,
            hasHeadCommit: true,
            headBranchName: "main"
        )
        let branch = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [head, branch])

        XCTAssertTrue(availability.contains(.compareSelected))
        XCTAssertTrue(availability.contains(.compareSelectedFiles))
        XCTAssertTrue(availability.isEnabled(.compareSelected))
        XCTAssertTrue(availability.isEnabled(.compareSelectedFiles))
        XCTAssertEqual(
            branchDashboardComparisonPair(selection: [head, branch]),
            BranchDashboardComparisonPair(
                rootPath: "/repo-a",
                first: "feature/login",
                second: "main"
            )
        )
        XCTAssertFalse(availability.contains(.updateSelected))
        XCTAssertFalse(availability.contains(.deleteSelected))
    }

    func testBranchDashboardHeadAndCurrentBranchSelectionDisablesPairComparisons() {
        let head = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "HEAD",
            kind: .head,
            remote: nil,
            isCurrent: true,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false,
            hasHeadCommit: true,
            headBranchName: "main"
        )
        let current = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "main",
            kind: .local,
            remote: nil,
            isCurrent: true,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [head, current])

        XCTAssertNil(branchDashboardComparisonPair(selection: [head, current]))
        XCTAssertFalse(availability.isEnabled(.compareSelected))
        XCTAssertFalse(availability.isEnabled(.compareSelectedFiles))
    }

    func testBranchDashboardHeadPairFailsClosedWithoutNamedCurrentBranch() {
        let head = BranchDashboardReference(
            rootPath: "/repo-detached",
            name: "HEAD",
            kind: .head,
            remote: nil,
            isCurrent: true,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false,
            hasHeadCommit: true
        )
        let branch = BranchDashboardReference(
            rootPath: "/repo-detached",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [head, branch])

        XCTAssertNil(branchDashboardComparisonPair(selection: [head, branch]))
        XCTAssertFalse(availability.isEnabled(.compareSelected))
        XCTAssertFalse(availability.isEnabled(.compareSelectedFiles))

        let unbornHead = BranchDashboardReference(
            rootPath: "/repo-unborn",
            name: "HEAD",
            kind: .head,
            remote: nil,
            isCurrent: true,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false,
            hasHeadCommit: false,
            headBranchName: "main"
        )
        let unbornBranch = BranchDashboardReference(
            rootPath: "/repo-unborn",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false
        )
        let unbornAvailability = BranchDashboardActionAvailability.resolve(
            selection: [unbornHead, unbornBranch]
        )

        XCTAssertNil(branchDashboardComparisonPair(selection: [unbornHead, unbornBranch]))
        XCTAssertFalse(unbornAvailability.isEnabled(.compareSelected))
        XCTAssertFalse(unbornAvailability.isEnabled(.compareSelectedFiles))
    }

    func testBranchDashboardTagSelectionUsesReferenceActions() {
        let tag = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "v1.2.3",
            kind: .tag,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [tag])

        XCTAssertTrue(availability.contains(.checkout))
        XCTAssertTrue(availability.contains(.merge))
        XCTAssertTrue(availability.contains(.showDiffWithWorkingTree))
        XCTAssertTrue(availability.contains(.deleteTag))
        XCTAssertTrue(availability.contains(.pushTag))
        XCTAssertFalse(availability.contains(.createWorktree))
        XCTAssertFalse(availability.contains(.compareWithCurrent))
        XCTAssertFalse(availability.contains(.rename))
        XCTAssertFalse(availability.contains(.deleteSelected))

        let currentTag = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "v1.2.3",
            kind: .tag,
            remote: nil,
            isCurrent: true,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: false
        )
        let currentAvailability = BranchDashboardActionAvailability.resolve(selection: [currentTag])

        XCTAssertFalse(currentAvailability.contains(.checkout))
        XCTAssertFalse(currentAvailability.contains(.merge))
        XCTAssertFalse(currentAvailability.contains(.deleteTag))
        XCTAssertTrue(currentAvailability.contains(.pushTag))
        XCTAssertFalse(currentAvailability.contains(.createWorktree))
    }

    func testBranchDashboardTagSelectionDoesNotExposeBranchPairOrBatchBranchActions() {
        let tag = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "v1.2.3",
            kind: .tag,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false
        )
        let branch = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [tag, branch])

        XCTAssertFalse(availability.contains(.compareSelected))
        XCTAssertFalse(availability.contains(.compareSelectedFiles))
        XCTAssertFalse(availability.contains(.deleteSelected))
    }

    func testBranchDashboardMultipleTagSelectionExposesDeleteAction() {
        let first = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "v1.2.3",
            kind: .tag,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: false
        )
        let second = BranchDashboardReference(
            rootPath: "/repo-b",
            name: "v1.2.4",
            kind: .tag,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [first, second])

        XCTAssertTrue(availability.contains(.deleteSelected))
        XCTAssertFalse(availability.contains(.compareSelected))
        XCTAssertFalse(availability.contains(.updateSelected))
    }

    func testBranchDashboardRemoteGroupSelectionUsesIntellijGroupActions() {
        let group = BranchDashboardRemoteGroup(rootPath: "/repo-a", name: "origin")

        let availability = BranchDashboardRemoteGroupActionAvailability.resolve(selection: [group])

        XCTAssertTrue(availability.contains(.editRemote))
        XCTAssertTrue(availability.contains(.removeRemote))
    }

    func testBranchDashboardMultipleRemoteGroupsOnlyExposeRemove() {
        let groups = [
            BranchDashboardRemoteGroup(rootPath: "/repo-a", name: "origin"),
            BranchDashboardRemoteGroup(rootPath: "/repo-b", name: "upstream")
        ]

        let availability = BranchDashboardRemoteGroupActionAvailability.resolve(selection: groups)

        XCTAssertFalse(availability.contains(.editRemote))
        XCTAssertTrue(availability.contains(.removeRemote))
    }

    func testBranchDashboardEmptyRemoteGroupSelectionHasNoActions() {
        let availability = BranchDashboardRemoteGroupActionAvailability.resolve(selection: [])

        XCTAssertFalse(availability.contains(.editRemote))
        XCTAssertFalse(availability.contains(.removeRemote))
    }

    func testBranchDashboardCurrentLocalDisablesDestructiveAndRevisionSwitchActions() {
        let reference = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "main",
            kind: .local,
            remote: nil,
            isCurrent: true,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: true
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [reference])

        XCTAssertTrue(availability.contains(.filterLog))
        XCTAssertTrue(availability.contains(.push))
        XCTAssertTrue(availability.contains(.setUpstream))
        XCTAssertFalse(availability.contains(.compareWithCurrent))
        XCTAssertTrue(availability.contains(.showDiffWithWorkingTree))
        XCTAssertTrue(availability.contains(.createWorktree))
        XCTAssertFalse(availability.contains(.checkout))
        XCTAssertFalse(availability.contains(.merge))
        XCTAssertFalse(availability.contains(.rebase))
        XCTAssertTrue(availability.contains(.rename))
        XCTAssertFalse(availability.contains(.deleteLocal))
    }

    func testBranchDashboardOpenWorktreeRequiresLinkedWorktreePath() {
        let linked = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/worktree",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false,
            worktreePath: "/tmp/repo-a-feature"
        )
        let regular = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/regular",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false
        )

        XCTAssertTrue(
            BranchDashboardActionAvailability.resolve(selection: [linked]).contains(.openWorktree)
        )
        XCTAssertFalse(
            BranchDashboardActionAvailability.resolve(selection: [regular]).contains(.openWorktree)
        )
    }

    func testBranchDashboardUpdateRemainsVisibleButDisabledWithoutTracking() {
        let reference = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/untracked",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [reference])

        XCTAssertTrue(availability.contains(.update))
        XCTAssertFalse(availability.isEnabled(.update))
        XCTAssertTrue(availability.contains(.checkoutWithUpdate))
        XCTAssertFalse(availability.isEnabled(.checkoutWithUpdate))
    }

    func testBranchDashboardUpdateAndRebaseRemainVisibleButDisabledForLinkedWorktree() {
        let reference = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/worktree",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false,
            worktreePath: "/tmp/repo-a-feature"
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [reference])

        XCTAssertTrue(availability.contains(.update))
        XCTAssertFalse(availability.isEnabled(.update))
        XCTAssertTrue(availability.contains(.checkoutWithUpdate))
        XCTAssertFalse(availability.isEnabled(.checkoutWithUpdate))
        XCTAssertTrue(availability.contains(.checkoutWithRebase))
        XCTAssertFalse(availability.isEnabled(.checkoutWithRebase))
    }

    func testBranchDashboardBatchUpdateDisablesWhenAnyBranchIsInLinkedWorktree() {
        let linked = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/worktree",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false,
            worktreePath: "/tmp/repo-a-feature"
        )
        let regular = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/regular",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(
            selection: [linked, regular]
        )

        XCTAssertTrue(availability.contains(.updateSelected))
        XCTAssertFalse(availability.isEnabled(.updateSelected))
    }

    func testLinkedWorktreePathSkipsCurrentRootRegardlessOfListOrder() {
        let worktrees = [
            WorktreeInfo(
                path: "/tmp/repo-a-linked",
                headId: "linked",
                branch: "feature/worktree",
                isBare: false,
                locked: false,
                prunable: false
            ),
            WorktreeInfo(
                path: "/tmp/repo-a",
                headId: "main",
                branch: "feature/worktree",
                isBare: false,
                locked: false,
                prunable: false
            )
        ]

        XCTAssertEqual(
            linkedWorktreePathForBranch(
                branch: "feature/worktree",
                worktrees: worktrees,
                currentRootPath: "/tmp/repo-a"
            ),
            "/tmp/repo-a-linked"
        )
    }

    func testBranchDashboardLocalWithoutRemoteKeepsPushButHidesTrackingActions() {
        let reference = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/local-only",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [reference])

        XCTAssertTrue(availability.contains(.push))
        XCTAssertFalse(availability.contains(.setUpstream))
        XCTAssertTrue(availability.contains(.checkout))
        XCTAssertTrue(availability.contains(.deleteLocal))
        XCTAssertTrue(availability.contains(.createWorktree))
    }

    func testBranchDashboardLocalReferenceExposesCheckoutVariants() {
        let reference = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [reference])

        XCTAssertTrue(availability.contains(.checkout))
        XCTAssertTrue(availability.contains(.checkoutAsNewBranch))
        XCTAssertTrue(availability.contains(.checkoutWithUpdate))
        XCTAssertTrue(availability.contains(.checkoutWithRebase))
    }

    func testBranchDashboardTrackedRemoteReferenceExposesPullVariants() {
        let reference = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "origin/feature/login",
            kind: .remote,
            remote: "origin",
            localBranchName: "feature/login",
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [reference])

        XCTAssertTrue(availability.contains(.checkoutAsNewBranch))
        XCTAssertFalse(availability.contains(.checkoutWithUpdate))
        XCTAssertTrue(availability.contains(.checkoutWithRebase))
        XCTAssertTrue(availability.contains(.showDiffWithWorkingTree))
        XCTAssertTrue(availability.contains(.pull))
        XCTAssertTrue(availability.contains(.pullWithRebase))
        XCTAssertFalse(availability.contains(.createWorktree))
    }

    func testBranchDashboardProtectedRemoteDeleteIsVisibleButDisabled() {
        let reference = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "origin/main",
            kind: .remote,
            remote: "origin",
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: true
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [reference])

        XCTAssertTrue(availability.contains(.checkout))
        XCTAssertTrue(availability.contains(.fetch))
        XCTAssertTrue(availability.contains(.merge))
        XCTAssertTrue(availability.contains(.rebase))
        XCTAssertTrue(availability.contains(.deleteRemote))
        XCTAssertFalse(availability.isEnabled(.deleteRemote))
    }

    func testBranchDashboardMixedOrCrossRootSelectionUsesSafeActions() {
        let local = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )
        let sameNameOtherRoot = BranchDashboardReference(
            rootPath: "/repo-b",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )
        let remote = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "origin/feature/login",
            kind: .remote,
            remote: "origin",
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: false
        )

        let crossRootAvailability = BranchDashboardActionAvailability.resolve(
            selection: [local, sameNameOtherRoot]
        )
        XCTAssertTrue(crossRootAvailability.contains(.compareSelected))
        XCTAssertTrue(crossRootAvailability.contains(.compareSelectedFiles))
        XCTAssertFalse(crossRootAvailability.isEnabled(.compareSelected))
        XCTAssertFalse(crossRootAvailability.isEnabled(.compareSelectedFiles))
        XCTAssertTrue(crossRootAvailability.contains(.updateSelected))
        XCTAssertTrue(crossRootAvailability.contains(.deleteSelected))
        let mixedAvailability = BranchDashboardActionAvailability.resolve(
            selection: [local, remote]
        )
        XCTAssertTrue(mixedAvailability.contains(.compareSelected))
        XCTAssertTrue(mixedAvailability.contains(.compareSelectedFiles))
        XCTAssertTrue(mixedAvailability.contains(.deleteSelected))
        XCTAssertFalse(mixedAvailability.contains(.updateSelected))
    }

    func testBranchDashboardMultipleLocalSelectionExposesIntellijBatchActions() {
        let first = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )
        let second = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/settings",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [first, second])

        XCTAssertTrue(availability.contains(.compareSelected))
        XCTAssertTrue(availability.contains(.compareSelectedFiles))
        XCTAssertTrue(availability.contains(.updateSelected))
        XCTAssertTrue(availability.contains(.deleteSelected))
        XCTAssertFalse(availability.contains(.checkout))
        XCTAssertFalse(availability.contains(.merge))
        XCTAssertFalse(availability.contains(.createWorktree))
    }

    func testBranchDashboardMultipleLocalSelectionBlocksDeleteWhenCurrentIsIncluded() {
        let current = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "main",
            kind: .local,
            remote: nil,
            isCurrent: true,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )
        let feature = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [current, feature])

        XCTAssertTrue(availability.contains(.compareSelected))
        XCTAssertTrue(availability.contains(.compareSelectedFiles))
        XCTAssertTrue(availability.contains(.updateSelected))
        XCTAssertTrue(availability.isEnabled(.updateSelected))
        XCTAssertTrue(availability.contains(.deleteSelected))
        XCTAssertFalse(availability.isEnabled(.deleteSelected))
    }

    func testBranchDashboardSameBranchSelectionShowsDisabledPairComparisons() {
        let first = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: false
        )
        let second = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/login",
            kind: .remote,
            remote: "origin",
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [first, second])

        XCTAssertTrue(availability.contains(.compareSelected))
        XCTAssertTrue(availability.contains(.compareSelectedFiles))
        XCTAssertFalse(availability.isEnabled(.compareSelected))
        XCTAssertFalse(availability.isEnabled(.compareSelectedFiles))
    }

    func testBranchDashboardCrossRootBatchKeepsWritesRootScopedButDisablesCompare() {
        let first = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )
        let second = BranchDashboardReference(
            rootPath: "/repo-b",
            name: "feature/login",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [first, second])

        XCTAssertTrue(availability.contains(.updateSelected))
        XCTAssertTrue(availability.contains(.deleteSelected))
        XCTAssertTrue(availability.contains(.compareSelected))
        XCTAssertTrue(availability.contains(.compareSelectedFiles))
        XCTAssertFalse(availability.isEnabled(.compareSelected))
        XCTAssertFalse(availability.isEnabled(.compareSelectedFiles))
    }

    func testBranchDashboardMultipleRemoteSelectionExposesCompareAndDelete() {
        let first = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "origin/feature/login",
            kind: .remote,
            remote: "origin",
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: false
        )
        let second = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "origin/feature/settings",
            kind: .remote,
            remote: "origin",
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [first, second])

        XCTAssertTrue(availability.contains(.compareSelected))
        XCTAssertTrue(availability.contains(.compareSelectedFiles))
        XCTAssertTrue(availability.contains(.deleteSelected))
        XCTAssertTrue(availability.isEnabled(.deleteSelected))
        XCTAssertFalse(availability.contains(.updateSelected))
    }

    func testSelectedRemoteBranchDeleteGroupsStayRootQualified() {
        let targets = [
            BranchDashboardReference(
                rootPath: "/repo-b",
                name: "origin/release",
                kind: .remote,
                remote: "origin",
                isCurrent: false,
                hasUpstream: false,
                hasTracking: false,
                hasRemote: true,
                isProtected: false
            ),
            BranchDashboardReference(
                rootPath: "/repo-a",
                name: "origin/feature",
                kind: .remote,
                remote: "origin",
                isCurrent: false,
                hasUpstream: false,
                hasTracking: false,
                hasRemote: true,
                isProtected: false
            ),
            BranchDashboardReference(
                rootPath: "/repo-b",
                name: "origin/feature",
                kind: .remote,
                remote: "origin",
                isCurrent: false,
                hasUpstream: false,
                hasTracking: false,
                hasRemote: true,
                isProtected: false
            )
        ]

        XCTAssertEqual(
            ContentView.multiRootRemoteBranchDeleteGroups(targets),
            [
                ContentView.MultiRootRemoteBranchDeleteGroup(
                    remoteBranch: "origin/feature",
                    rootPaths: ["/repo-a", "/repo-b"]
                ),
                ContentView.MultiRootRemoteBranchDeleteGroup(
                    remoteBranch: "origin/release",
                    rootPaths: ["/repo-b"]
                )
            ]
        )
    }

    func testBranchDashboardProtectedRemoteBlocksOnlyBatchDelete() {
        let protected = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "origin/main",
            kind: .remote,
            remote: "origin",
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: true
        )
        let feature = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "origin/feature/login",
            kind: .remote,
            remote: "origin",
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: false
        )

        let availability = BranchDashboardActionAvailability.resolve(
            selection: [protected, feature]
        )

        XCTAssertTrue(availability.contains(.compareSelected))
        XCTAssertTrue(availability.contains(.compareSelectedFiles))
        XCTAssertTrue(availability.contains(.deleteSelected))
        XCTAssertFalse(availability.isEnabled(.deleteSelected))
    }

    func testSingleRemoteReferenceKeepsPullVisibleWithoutLocalTrackingAndDisablesProtectedDelete() {
        let remote = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "origin/release",
            kind: .remote,
            remote: "origin",
            localBranchName: nil,
            isCurrent: false,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: true,
            isProtected: true
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [remote])

        XCTAssertTrue(availability.contains(.pull))
        XCTAssertTrue(availability.contains(.pullWithRebase))
        XCTAssertTrue(availability.contains(.deleteRemote))
        XCTAssertFalse(availability.isEnabled(.deleteRemote))
    }

    func testSingleLocalReferenceDisablesCheckoutActionsForAnotherWorktreeButKeepsRename() {
        let local = BranchDashboardReference(
            rootPath: "/repo-a",
            name: "feature/worktree",
            kind: .local,
            remote: nil,
            isCurrent: false,
            hasUpstream: true,
            hasTracking: true,
            hasRemote: true,
            isProtected: false,
            worktreePath: "/tmp/feature-worktree"
        )

        let availability = BranchDashboardActionAvailability.resolve(selection: [local])

        XCTAssertTrue(availability.contains(.checkout))
        XCTAssertFalse(availability.isEnabled(.checkout))
        XCTAssertTrue(availability.contains(.checkoutWithRebase))
        XCTAssertFalse(availability.isEnabled(.checkoutWithRebase))
        XCTAssertTrue(availability.contains(.rename))
    }

    func testBranchTreeSelectionSkipsGroupsAndWraps() {
        let rows = branchDirectoryRows(
            for: ["feature/login", "feature/ui", "main"],
            grouped: true,
            scope: "selection"
        )
        let ids = branchTreeSelectableIDs(rows, collapsedGroups: [])
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(
            movedBranchTreeSelection(currentID: ids[0], selectableIDs: ids, offset: 1),
            ids[1]
        )
        XCTAssertEqual(
            movedBranchTreeSelection(currentID: ids[0], selectableIDs: ids, offset: -1),
            ids[2]
        )
        XCTAssertEqual(
            movedBranchTreeSelection(currentID: ids[0], selectableIDs: ids, offset: -1, wraps: false),
            ids[0]
        )
        XCTAssertEqual(
            branchTreeSelectableIDs(rows, collapsedGroups: [rows[0].id]),
            [ids[2]]
        )
    }

    func testCommandBranchTreeSelectionTogglesWithoutCrossRootCollision() {
        XCTAssertEqual(
            toggledBranchTreeSelection(current: [], id: "multi:/repo-a:local:feature/a", command: false),
            ["multi:/repo-a:local:feature/a"]
        )
        XCTAssertEqual(
            toggledBranchTreeSelection(
                current: ["multi:/repo-a:local:feature/a"],
                id: "multi:/repo-b:local:feature/a",
                command: true
            ),
            [
                "multi:/repo-a:local:feature/a",
                "multi:/repo-b:local:feature/a"
            ]
        )
        XCTAssertEqual(
            toggledBranchTreeSelection(
                current: ["multi:/repo-a:local:feature/a", "multi:/repo-b:local:feature/a"],
                id: "multi:/repo-a:local:feature/a",
                command: true
            ),
            ["multi:/repo-b:local:feature/a"]
        )
    }

    func testShiftBranchTreeSelectionUsesRootQualifiedVisibleOrder() {
        let orderedIDs = [
            "multi:/repo-a:local:feature/a",
            "multi:/repo-a:local:feature/b",
            "multi:/repo-b:local:feature/a",
            "multi:/repo-b:remote:origin/feature/a"
        ]

        let range = branchTreeSelectionAfterClick(
            current: [orderedIDs[0]],
            anchorID: orderedIDs[0],
            orderedIDs: orderedIDs,
            id: orderedIDs[2],
            command: false,
            shift: true
        )
        XCTAssertEqual(range.selection, Set(orderedIDs[0...2]))
        XCTAssertEqual(range.anchorID, orderedIDs[0])

        let extended = branchTreeSelectionAfterClick(
            current: range.selection,
            anchorID: range.anchorID,
            orderedIDs: orderedIDs,
            id: orderedIDs[3],
            command: true,
            shift: true
        )
        XCTAssertEqual(extended.selection, Set(orderedIDs))
        XCTAssertEqual(extended.anchorID, orderedIDs[0])

        let missingAnchor = branchTreeSelectionAfterClick(
            current: [orderedIDs[1]],
            anchorID: "multi:/repo-c:local:missing",
            orderedIDs: orderedIDs,
            id: orderedIDs[2],
            command: false,
            shift: true
        )
        XCTAssertEqual(missingAnchor.selection, Set([orderedIDs[2]]))
        XCTAssertEqual(missingAnchor.anchorID, orderedIDs[2])
    }

    func testHeadBranchTreeSelectionSharesRootQualifiedRangeIdentity() {
        let orderedIDs = [
            "multi:/repo-a:head:HEAD",
            "multi:/repo-a:local:feature/login"
        ]

        let selection = branchTreeSelectionAfterClick(
            current: [orderedIDs[0]],
            anchorID: orderedIDs[0],
            orderedIDs: orderedIDs,
            id: orderedIDs[1],
            command: false,
            shift: true
        )

        XCTAssertEqual(selection.selection, Set(orderedIDs))
        XCTAssertEqual(selection.anchorID, orderedIDs[0])
    }

    func testMultiRootLogRangeSelectionSkipsRemoteGroupTargets() {
        let visibleBranchIDs = [
            "log.multi:/repo-a:head:HEAD",
            "log.multi:/repo-a:local:feature/login",
            "log.multi:/repo-a:remote:origin/feature/login"
        ]
        let remoteGroupID = "log.multi:/repo-a:remote-group:origin"

        let selection = branchTreeSelectionAfterClick(
            current: [visibleBranchIDs[0]],
            anchorID: visibleBranchIDs[0],
            orderedIDs: visibleBranchIDs,
            id: visibleBranchIDs[2],
            command: false,
            shift: true
        )

        XCTAssertEqual(selection.selection, Set(visibleBranchIDs))
        XCTAssertFalse(selection.selection.contains(remoteGroupID))
    }

    func testVisibleBranchNamesFollowTreeOrderAndCollapsedGroups() {
        let names = ["hotfix/one", "feature/ui", "feature/login"]
        let rows = branchDirectoryRows(for: names, grouped: true, scope: "visible")
        let featureGroupID = rows.first(where: { $0.isGroup && $0.name == "feature" })!.id

        XCTAssertEqual(
            visibleBranchDirectoryRefNames(
                names,
                grouped: true,
                scope: "visible",
                collapsedGroups: []
            ),
            ["hotfix/one", "feature/ui", "feature/login"]
        )
        XCTAssertEqual(
            visibleBranchDirectoryRefNames(
                names,
                grouped: true,
                scope: "visible",
                collapsedGroups: [featureGroupID]
            ),
            ["hotfix/one"]
        )
    }
}
