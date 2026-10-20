import XCTest
@testable import Arbor


final class GitBranchesPopupSettingsTests: XCTestCase {
    func testPopupSettingsAreProjectScopedAndUseIntelliJDefaults() {
        let suiteName = "Arbor.GitBranchesPopupSettingsTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        let projectPath = "/tmp/arbor-branches-popup-\(UUID().uuidString)"
        let otherProjectPath = "/tmp/arbor-branches-popup-other-\(UUID().uuidString)"
        XCTAssertTrue(
            GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.showRecentBranchesKey,
                for: projectPath,
                defaults: suite
            )
        )
        XCTAssertTrue(
            GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.filterByRepositoryKey,
                for: projectPath,
                defaults: suite
            )
        )
        XCTAssertTrue(
            GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.filterByActionInPopupKey,
                for: projectPath,
                defaults: suite
            )
        )
        XCTAssertTrue(
            GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.groupByRepositoryKey,
                for: projectPath,
                defaults: suite
            )
        )
        XCTAssertTrue(
            GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.groupByDirectoryKey,
                for: projectPath,
                defaults: suite
            )
        )
        XCTAssertTrue(
            GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.showTagsKey,
                for: projectPath,
                defaults: suite
            )
        )
        XCTAssertEqual(
            GitBranchesPopupSettings.stringValue(
                GitBranchesPopupSettings.logSelectionActionKey,
                for: projectPath,
                defaults: suite
            ),
            GitBranchesPopupSettings.defaultLogSelectionAction
        )

        GitBranchesPopupSettings.save(
            false,
            GitBranchesPopupSettings.showRecentBranchesKey,
            for: projectPath,
            defaults: suite
        )
        GitBranchesPopupSettings.save(
            false,
            GitBranchesPopupSettings.filterByRepositoryKey,
            for: projectPath,
            defaults: suite
        )
        GitBranchesPopupSettings.save(
            false,
            GitBranchesPopupSettings.filterByActionInPopupKey,
            for: projectPath,
            defaults: suite
        )
        GitBranchesPopupSettings.save(
            false,
            GitBranchesPopupSettings.groupByRepositoryKey,
            for: projectPath,
            defaults: suite
        )
        GitBranchesPopupSettings.save(
            false,
            GitBranchesPopupSettings.groupByDirectoryKey,
            for: projectPath,
            defaults: suite
        )
        GitBranchesPopupSettings.save(
            false,
            GitBranchesPopupSettings.showTagsKey,
            for: projectPath,
            defaults: suite
        )
        GitBranchesPopupSettings.save(
            "filter",
            GitBranchesPopupSettings.logSelectionActionKey,
            for: projectPath,
            defaults: suite
        )
        XCTAssertFalse(
            GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.showRecentBranchesKey,
                for: projectPath,
                defaults: suite
            )
        )
        XCTAssertTrue(
            GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.showRecentBranchesKey,
                for: otherProjectPath,
                defaults: suite
            )
        )
        XCTAssertFalse(
            GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.filterByActionInPopupKey,
                for: projectPath,
                defaults: suite
            )
        )
        XCTAssertTrue(
            GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.filterByActionInPopupKey,
                for: otherProjectPath,
                defaults: suite
            )
        )
        XCTAssertFalse(
            GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.showTagsKey,
                for: projectPath,
                defaults: suite
            )
        )
        XCTAssertTrue(
            GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.showTagsKey,
                for: otherProjectPath,
                defaults: suite
            )
        )
        XCTAssertFalse(
            GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.groupByRepositoryKey,
                for: projectPath,
                defaults: suite
            )
        )
        XCTAssertFalse(
            GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.groupByDirectoryKey,
                for: projectPath,
                defaults: suite
            )
        )
        XCTAssertEqual(
            GitBranchesPopupSettings.stringValue(
                GitBranchesPopupSettings.logSelectionActionKey,
                for: projectPath,
                defaults: suite
            ),
            "filter"
        )
        XCTAssertEqual(
            GitBranchesPopupSettings.stringValue(
                GitBranchesPopupSettings.logSelectionActionKey,
                for: otherProjectPath,
                defaults: suite
            ),
            GitBranchesPopupSettings.defaultLogSelectionAction
        )
        XCTAssertTrue(
            GitBranchesPopupSettings.favorites(
                for: projectPath,
                defaults: suite
            ).isEmpty
        )
        GitBranchesPopupSettings.saveFavorites(
            ["local:/repo-a:feature/login", "remote:/repo-a:origin/main"],
            for: projectPath,
            defaults: suite
        )
        XCTAssertEqual(
            GitBranchesPopupSettings.favorites(
                for: projectPath,
                defaults: suite
            ),
            ["local:/repo-a:feature/login", "remote:/repo-a:origin/main"]
        )
        XCTAssertTrue(
            GitBranchesPopupSettings.favorites(
                for: otherProjectPath,
                defaults: suite
            ).isEmpty
        )
        GitBranchesPopupSettings.saveFavorites([], for: projectPath, defaults: suite)
        XCTAssertTrue(
            GitBranchesPopupSettings.favorites(
                for: projectPath,
                defaults: suite
            ).isEmpty
        )
    }

    func testCollapsedDirectoryGroupsAreProjectScopedAndStable() {
        let suiteName = "Arbor.GitBranchesPopupSettingsTests.collapsed-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }

        let projectPath = "/tmp/arbor-branches-popup-collapsed-\(UUID().uuidString)"
        let otherProjectPath = "/tmp/arbor-branches-popup-collapsed-other-\(UUID().uuidString)"
        let groups: Set<String> = [
            "group:/repo/local/feature",
            "group:/repo/local"
        ]

        XCTAssertTrue(
            GitBranchesPopupSettings.collapsedDirectoryGroups(
                for: projectPath,
                defaults: suite
            ).isEmpty
        )
        GitBranchesPopupSettings.saveCollapsedDirectoryGroups(
            groups,
            for: projectPath,
            defaults: suite
        )
        GitBranchesPopupSettings.saveCollapsedDirectoryGroups(
            ["group:log/local"],
            for: projectPath,
            setting: GitBranchesPopupSettings.logCollapsedDirectoryGroupsKey,
            defaults: suite
        )

        XCTAssertEqual(
            GitBranchesPopupSettings.collapsedDirectoryGroups(
                for: projectPath,
                defaults: suite
            ),
            groups
        )
        XCTAssertEqual(
            GitBranchesPopupSettings.collapsedDirectoryGroups(
                for: projectPath,
                setting: GitBranchesPopupSettings.logCollapsedDirectoryGroupsKey,
                defaults: suite
            ),
            ["group:log/local"]
        )
        XCTAssertTrue(
            GitBranchesPopupSettings.collapsedDirectoryGroups(
                for: otherProjectPath,
                defaults: suite
            ).isEmpty
        )

        GitBranchesPopupSettings.saveCollapsedDirectoryGroups(
            [],
            for: projectPath,
            defaults: suite
        )
        XCTAssertTrue(
            GitBranchesPopupSettings.collapsedDirectoryGroups(
                for: projectPath,
                defaults: suite
            ).isEmpty
        )
    }
}
