import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {

    func testGitStageIgnoredFilesSettingIsProjectScoped() {
        let suiteName = "Arbor.GitStageViewSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstProject = "/workspace/one"
        let firstProjectAlias = "/workspace/one/../one"
        let secondProject = "/workspace/two"

        XCTAssertFalse(GitStageViewSettings.ignoredFilesShown(for: firstProject, defaults: defaults))
        XCTAssertFalse(GitStageViewSettings.ignoredFilesShown(for: secondProject, defaults: defaults))
        XCTAssertFalse(GitStageViewSettings.ignoredFilesShown(for: nil, defaults: defaults))

        GitStageViewSettings.saveIgnoredFilesShown(true, for: firstProject, defaults: defaults)

        XCTAssertTrue(GitStageViewSettings.ignoredFilesShown(for: firstProject, defaults: defaults))
        XCTAssertTrue(GitStageViewSettings.ignoredFilesShown(for: firstProjectAlias, defaults: defaults))
        XCTAssertFalse(GitStageViewSettings.ignoredFilesShown(for: secondProject, defaults: defaults))

        GitStageViewSettings.saveIgnoredFilesShown(false, for: firstProject, defaults: defaults)
        XCTAssertFalse(GitStageViewSettings.ignoredFilesShown(for: firstProject, defaults: defaults))
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

    func testAutomaticChangelistSettingDefaultsOffAndPersists() {
        let suiteName = "Arbor.ChangelistSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(GitChangelistSettings.createAutomatically(from: defaults))
        defaults.set(true, forKey: GitChangelistSettings.createAutomaticallyKey)
        XCTAssertTrue(GitChangelistSettings.createAutomatically(from: defaults))
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
}
