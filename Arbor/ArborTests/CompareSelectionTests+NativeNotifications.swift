import XCTest
import Foundation
import UserNotifications
@testable import Arbor

extension CompareSelectionTests {

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
}
