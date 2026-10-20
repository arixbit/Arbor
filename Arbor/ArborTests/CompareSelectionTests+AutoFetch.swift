import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {

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

    func testAutoFetchRootPathsIncludePrimaryAndDiscoveredRootsExactlyOnce() {
        XCTAssertEqual(
            mergedAutoFetchRootPaths(
                primary: "/project",
                discovered: ["/project/root-b", "/project", "/project/root-a"]
            ),
            ["/project", "/project/root-a", "/project/root-b"]
        )
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
