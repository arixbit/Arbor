import SwiftUI
import UserNotifications
import Foundation
import AppKit


/// Map Arbor's IntelliJ-style VCS notification groups to native macOS
/// presentation without leaking operation-specific IDs into the thread.
/// Stable request IDs still replace one operation, while the shared thread
/// keeps related standard/important notifications grouped by channel.
func arborNativeNotificationThreadIdentifier(for group: VcsNotificationGroup) -> String {
    "arbor.git.\(group.rawValue)"
}

func arborNativeNotificationCategoryIdentifier(for notificationID: String) -> String {
    "arbor.notification.category.\(notificationID)"
}

func arborNativeNotificationAuthorizationAllowed(
    authorizationStatus: UNAuthorizationStatus,
    alertSetting: UNNotificationSetting
) -> Bool? {
    switch authorizationStatus {
    case .authorized, .provisional:
        return alertSetting == .disabled ? false : true
    case .denied:
        return false
    case .notDetermined:
        return nil
    @unknown default:
        return nil
    }
}

@discardableResult
func openArborNotificationSettings() -> Bool {
    if let notificationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    ), NSWorkspace.shared.open(notificationSettingsURL) {
        return true
    }
    return NSWorkspace.shared.open(
        URL(fileURLWithPath: "/System/Applications/System Settings.app")
    )
}

func arborNativeNotificationPresentationOptions(
    for group: VcsNotificationGroup
) -> UNNotificationPresentationOptions {
    switch group {
    case .toolWindow, .silent:
        []
    case .standard:
        [.banner]
    case .important:
        [.banner, .sound]
    }
}

/// Bridges the app's grouped Git feedback into the macOS notification center.
/// IntelliJ's VcsNotifier replaces notifications by display id; local
/// notification requests use the same stable id and remove the delivered
/// predecessor before posting the replacement. Action closures remain in
/// memory for the current process, while known Git actions have a semantic
/// fallback when macOS relaunches Arbor for a notification response.
@MainActor
final class ArborNativeNotificationCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ArborNativeNotificationCenter()

    private enum AuthorizationState {
        case unknown
        case authorized
        case denied
    }

    private let center = UNUserNotificationCenter.current()
    private var authorizationState: AuthorizationState = .unknown
    private var authorizationRequestInFlight = false
    private var pendingMessages: [String: FeedbackMessage] = [:]
    private var actionsByNotification: [String: [FeedbackAction]] = [:]
    private var categoriesByID: [String: UNNotificationCategory] = [:]
    var onAuthorizationStatusChange: ((Bool?) -> Void)?

    private override init() {
        super.init()
        center.delegate = self
    }

    func install() {
        center.delegate = self
        refreshAuthorizationStatus()
    }

    func refreshAuthorizationStatus() {
        center.getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                guard let self else { return }
                let allowed = arborNativeNotificationAuthorizationAllowed(
                    authorizationStatus: settings.authorizationStatus,
                    alertSetting: settings.alertSetting
                )
                switch allowed {
                case .some(true):
                    self.authorizationState = .authorized
                    self.schedulePendingMessages()
                case .some(false):
                    self.authorizationState = .denied
                    self.pendingMessages.removeAll()
                case .none:
                    self.authorizationState = .unknown
                }
                self.onAuthorizationStatusChange?(allowed)
            }
        }
    }

    func publish(_ message: FeedbackMessage) {
        // Hosted XCTest must stay headless and must never trigger a system
        // permission prompt while testing FeedbackCenter's in-app behavior.
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCTestBundlePath"] == nil,
              environment["XCTestSessionIdentifier"] == nil,
              let notificationID = message.notificationID else { return }

        // Tool-window and silent messages belong to Arbor's in-app history;
        // never mirror them into Notification Center. Remove a prior native
        // replacement when an operation changes group during its lifecycle.
        guard message.notificationGroup == .standard
                || message.notificationGroup == .important else {
            pendingMessages.removeValue(forKey: notificationID)
            actionsByNotification.removeValue(forKey: notificationID)
            removeCategory(for: notificationID)
            center.removePendingNotificationRequests(withIdentifiers: [notificationID])
            center.removeDeliveredNotifications(withIdentifiers: [notificationID])
            return
        }

        install()
        pendingMessages[notificationID] = message
        switch authorizationState {
        case .authorized:
            schedulePendingMessages()
        case .denied:
            pendingMessages.removeValue(forKey: notificationID)
        case .unknown:
            requestAuthorizationIfNeeded()
        }
    }

    private func requestAuthorizationIfNeeded() {
        guard !authorizationRequestInFlight else { return }
        authorizationRequestInFlight = true
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                guard let self else { return }
                self.authorizationRequestInFlight = false
                self.authorizationState = granted ? .authorized : .denied
                if granted {
                    self.schedulePendingMessages()
                } else {
                    self.pendingMessages.removeAll()
                }
                self.onAuthorizationStatusChange?(granted)
                self.refreshAuthorizationStatus()
            }
        }
    }

    private func schedulePendingMessages() {
        let messages = pendingMessages.values
        pendingMessages.removeAll()
        for message in messages {
            schedule(message)
        }
    }

    private func schedule(_ message: FeedbackMessage) {
        guard let notificationID = message.notificationID else { return }
        let replayableActions = arborNativeNotificationActions(message.actions)

        let content = UNMutableNotificationContent()
        content.title = displayText(message.title, isLocalized: message.titleIsLocalized)
        content.body = [message.detail, message.nextStep]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: "\n")
        if content.body.isEmpty {
            content.body = content.title
        }
        content.sound = message.notificationGroup == .important ? .default : nil
        content.threadIdentifier = arborNativeNotificationThreadIdentifier(
            for: message.notificationGroup
        )
        content.userInfo = [
            "arborNotificationID": notificationID,
            "arborNotificationGroup": message.notificationGroup.rawValue,
            "arborActionTitles": replayableActions.map { $0.title },
            "arborActionRequests": replayableActions.map { action in
                guard let semanticAction = action.semanticAction,
                      let data = try? JSONEncoder().encode(semanticAction),
                      let json = String(data: data, encoding: .utf8) else {
                    return ""
                }
                return json
            }
        ]

        let notificationActions = replayableActions.enumerated().map { index, item in
            UNNotificationAction(
                identifier: actionIdentifier(index),
                title: displayText(item.title, isLocalized: true),
                options: [.foreground]
            )
        }
        if !notificationActions.isEmpty {
            let categoryID = categoryIdentifier(notificationID)
            categoriesByID[categoryID] = UNNotificationCategory(
                identifier: categoryID,
                actions: notificationActions,
                intentIdentifiers: [],
                options: []
            )
            refreshCategories()
            content.categoryIdentifier = categoryID
            actionsByNotification[notificationID] = replayableActions
        } else {
            actionsByNotification.removeValue(forKey: notificationID)
            removeCategory(for: notificationID)
        }

        // A stable request id makes the notification replaceable instead of
        // creating one macOS banner for every polling cycle.
        center.removePendingNotificationRequests(withIdentifiers: [notificationID])
        center.removeDeliveredNotifications(withIdentifiers: [notificationID])
        let request = UNNotificationRequest(identifier: notificationID, content: content, trigger: nil)
        center.add(request) { error in
            guard error != nil else { return }
            DiagnosticsLogger.shared.record(
                level: .error,
                operation: "native-notification",
                code: "schedule-failed"
            )
        }
    }

    func expire(notificationID: String) {
        pendingMessages.removeValue(forKey: notificationID)
        actionsByNotification.removeValue(forKey: notificationID)
        removeCategory(for: notificationID)
        center.removePendingNotificationRequests(withIdentifiers: [notificationID])
        center.removeDeliveredNotifications(withIdentifiers: [notificationID])
    }

    private func refreshCategories() {
        center.setNotificationCategories(Set(categoriesByID.values))
    }

    private func removeCategory(for notificationID: String) {
        guard categoriesByID.removeValue(forKey: categoryIdentifier(notificationID)) != nil else {
            return
        }
        refreshCategories()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let group = (notification.request.content.userInfo["arborNotificationGroup"] as? String)
            .flatMap(VcsNotificationGroup.init(rawValue:))
            ?? .important
        completionHandler(arborNativeNotificationPresentationOptions(for: group))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        let notificationID = request.identifier
        let actionIdentifier = response.actionIdentifier
        let fallbackTitles = request.content.userInfo["arborActionTitles"] as? [String]
        let fallbackRequests = request.content.userInfo["arborActionRequests"] as? [String]
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                completionHandler()
                return
            }
            if actionIdentifier != UNNotificationDefaultActionIdentifier,
               let index = self.actionIndex(actionIdentifier),
               let action = self.actionsByNotification[notificationID]?[safe: index]
            {
                action.action()
            } else if let index = self.actionIndex(actionIdentifier),
                      let encodedRequest = fallbackRequests?[safe: index],
                      !encodedRequest.isEmpty,
                      let data = encodedRequest.data(using: .utf8),
                      let actionRequest = try? JSONDecoder().decode(
                          ArborVCSActionRequest.self,
                          from: data
                      )
            {
                self.postFallbackAction(for: actionRequest)
            } else if let fallbackTitles,
                      let index = self.actionIndex(actionIdentifier),
                      let title = fallbackTitles[safe: index]
            {
                self.postFallbackAction(for: title)
            }
            self.actionsByNotification.removeValue(forKey: notificationID)
            completionHandler()
        }
    }

    private func postFallbackAction(for request: ArborVCSActionRequest) {
        NotificationCenter.default.post(name: .arborVCSAction, object: request)
    }

    private func postFallbackAction(for title: String) {
        let action = arborVCSAction(forNativeNotificationActionTitle: title)
        guard let action else { return }
        NotificationCenter.default.post(name: .arborVCSAction, object: action.rawValue)
    }

    private func actionIdentifier(_ index: Int) -> String {
        "arbor.notification.action.\(index)"
    }

    private func actionIndex(_ identifier: String) -> Int? {
        let prefix = "arbor.notification.action."
        guard identifier.hasPrefix(prefix) else { return nil }
        return Int(identifier.dropFirst(prefix.count))
    }

    private func categoryIdentifier(_ notificationID: String) -> String {
        arborNativeNotificationCategoryIdentifier(for: notificationID)
    }

    private func displayText(_ value: String, isLocalized: Bool) -> String {
        isLocalized ? NSLocalizedString(value, comment: "") : value
    }
}

func arborVCSAction(forNativeNotificationActionTitle title: String) -> ArborVCSAction? {
    switch title {
    case "Fetch All", "Retry Fetch All":
        .fetchAll
    case "Retry Check":
        .retryAutoFetch
    case "Enable Auto-fetch":
        .enableAutoFetch
    case "Do Not Ask Again":
        .disableAutoFetchSuggestion
    default:
        nil
    }
}

/// Native notification buttons must survive a process restart. A closure-only
/// action is still useful in Arbor's in-process feedback history, but it has no
/// safe replay target after relaunch and must not become a dead system button.
func arborNativeNotificationActions(_ actions: [FeedbackAction]) -> [FeedbackAction] {
    actions.filter { action in
        action.semanticAction != nil
            || arborVCSAction(forNativeNotificationActionTitle: action.title) != nil
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
