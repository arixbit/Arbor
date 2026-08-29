import SwiftUI
import UserNotifications
import Foundation
import AppKit

enum FeedbackLevel: Equatable {
    case info
    case success
    case warning
    case error

    var color: Color {
        switch self {
        case .info: .secondary
        case .success: Design.Colors.success
        case .warning: .orange
        case .error: Design.Colors.error
        }
    }

    var systemImage: String {
        switch self {
        case .info: "info.circle"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}

/// The four notification channels exposed by IntelliJ's VcsNotifier. The
/// group controls presentation independently from severity and display ID:
/// tool-window messages remain in Arbor's VCS surface, standard messages may
/// auto-dismiss, important messages stay visible, and silent messages only
/// update operation history.
enum VcsNotificationGroup: String, CaseIterable, Codable, Sendable {
    case toolWindow
    case standard
    case important
    case silent
}

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

/// Progress for an IntelliJ-style batch action whose individual work is
/// performed by the repository engine rather than Git transport.
struct FeedbackBatchProgress: Equatable {
    let completed: Int
    let total: Int
    let phase: String
    let detail: String?

    var percentage: Int? {
        guard total > 0 else { return nil }
        return min(100, max(0, Int((Double(completed) / Double(total) * 100).rounded())))
    }
}

/// One repository row in an IntelliJ-style compound Git result. Keep this
/// separate from the engine's RootOperationResult so the operation log can
/// persist a safe presentation model without retaining UniFFI values.
enum FeedbackResultState: String, Codable, Equatable, Sendable {
    case success
    case partial
    case skipped
    case failed
    case aborted
}

struct FeedbackResultRow: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let rootPath: String
    let displayName: String
    let state: FeedbackResultState
    let detail: String

    init(
        rootPath: String,
        displayName: String,
        state: FeedbackResultState,
        detail: String
    ) {
        self.id = rootPath
        self.rootPath = rootPath
        self.displayName = displayName
        self.state = state
        self.detail = detail
    }
}

/// A persisted file-level outcome below one Shelf/list item. Keep this
/// separate from FeedbackResultRow: root rows model IntelliJ's repository
/// result tree, while operation items model the children inside one root.
struct FeedbackOperationSubitem: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let path: String
    let state: FeedbackResultState
    let detail: String

    init(
        scope: String,
        path: String,
        state: FeedbackResultState,
        detail: String
    ) {
        self.path = path
        self.state = state
        self.detail = detail
        self.id = "\(scope)\u{1f}\(path)"
    }
}

/// A persisted item-level outcome for operations whose unit is not a Git root
/// (for example a selected Shelf or a batch of deleted Shelf lists). Keep this
/// separate from FeedbackResultRow: root rows model IntelliJ's repository
/// result tree, while operation items model the children inside one root.
struct FeedbackOperationItem: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let scope: String
    let name: String
    let state: FeedbackResultState
    let detail: String
    let children: [FeedbackOperationSubitem]

    private enum CodingKeys: String, CodingKey {
        case id
        case scope
        case name
        case state
        case detail
        case children
    }

    init(
        scope: String,
        name: String,
        state: FeedbackResultState,
        detail: String,
        children: [FeedbackOperationSubitem] = []
    ) {
        self.scope = scope
        self.name = name
        self.state = state
        self.detail = detail
        self.children = children
        self.id = "\(scope)\u{1f}\(name)"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        scope = try container.decode(String.self, forKey: .scope)
        name = try container.decode(String.self, forKey: .name)
        state = try container.decode(FeedbackResultState.self, forKey: .state)
        detail = try container.decode(String.self, forKey: .detail)
        children = try container.decodeIfPresent(
            [FeedbackOperationSubitem].self,
            forKey: .children
        ) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(scope, forKey: .scope)
        try container.encode(name, forKey: .name)
        try container.encode(state, forKey: .state)
        try container.encode(detail, forKey: .detail)
        try container.encode(children, forKey: .children)
    }
}

/// Convert the engine's per-root result records at the feedback boundary.
/// Preserve engine order: it is the user-visible execution order and matches
/// IntelliJ's UpdateInfoTree repository ordering. Some compound operations
/// finish with a recoverable paused root; callers can mark those rows
/// explicitly without changing the engine's success/skipped contract.
func feedbackResultRows(
    from results: [RootOperationResult],
    partialRootPaths: Set<String> = []
) -> [FeedbackResultRow] {
    let normalizedPartialRootPaths = Set(
        partialRootPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    )
    return results.map { result in
        let state: FeedbackResultState
        let normalizedRootPath = URL(fileURLWithPath: result.rootPath)
            .standardizedFileURL.path
        if normalizedPartialRootPaths.contains(normalizedRootPath) {
            state = .partial
        } else if !result.success {
            state = .failed
        } else if result.skipped {
            state = .skipped
        } else {
            state = .success
        }
        return FeedbackResultRow(
            rootPath: result.rootPath,
            displayName: result.displayName,
            state: state,
            detail: result.message
        )
    }
}

/// Preserve the complete repository result tree when a compound operation
/// retries only failed roots. IntelliJ's Push operation keeps one cumulative
/// result map across attempts; replacing the display rows with the retry
/// subset would hide roots that already completed successfully.
func mergeFeedbackResultRows(
    preserved: [FeedbackResultRow],
    retry: [FeedbackResultRow]
) -> [FeedbackResultRow] {
    let rootKey: (FeedbackResultRow) -> String = {
        URL(fileURLWithPath: $0.rootPath).standardizedFileURL.path
    }
    var rowsByRoot = Dictionary(uniqueKeysWithValues: preserved.map { (rootKey($0), $0) })
    retry.forEach { rowsByRoot[rootKey($0)] = $0 }

    var order = preserved.map(rootKey)
    order.append(contentsOf: retry.map(rootKey).filter { !order.contains($0) })
    return order.compactMap { rowsByRoot[$0] }
}

/// Preserve completed Shelf items when a stable batch notification retries
/// only the remaining lists. The item id includes the root scope, so the
/// merge remains correct when the same Shelf name exists in multiple roots.
func mergeFeedbackOperationItems(
    preserved: [FeedbackOperationItem],
    retry: [FeedbackOperationItem]
) -> [FeedbackOperationItem] {
    var itemsByID = Dictionary(uniqueKeysWithValues: preserved.map { ($0.id, $0) })
    retry.forEach { itemsByID[$0.id] = $0 }

    var order = preserved.map(\.id)
    order.append(contentsOf: retry.map(\.id).filter { !order.contains($0) })
    return order.compactMap { itemsByID[$0] }
}

struct FeedbackMessage: Identifiable {
    let id = UUID()
    let level: FeedbackLevel
    let title: String
    let titleIsLocalized: Bool
    let detail: String?
    let nextStep: String?
    let actionTitle: String?
    let action: (() -> Void)?
    let additionalActions: [FeedbackAction]
    let notificationGroup: VcsNotificationGroup
    /// Stable display identity for notifications that should replace/update
    /// an existing message instead of creating another history row.
    let notificationID: String?
    let createdAt = Date()

    var actions: [FeedbackAction] {
        var result: [FeedbackAction] = []
        if let actionTitle, let action {
            result.append(FeedbackAction(id: "primary", title: actionTitle, action: action))
        }
        result.append(contentsOf: additionalActions)
        return result
    }

    static func localized(
        _ title: String,
        level: FeedbackLevel,
        detail: String? = nil,
        nextStep: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        additionalActions: [FeedbackAction] = [],
        notificationID: String? = nil,
        notificationGroup: VcsNotificationGroup = .toolWindow
    ) -> FeedbackMessage {
        FeedbackMessage(
            level: level,
            title: title,
            titleIsLocalized: true,
            detail: detail,
            nextStep: nextStep,
            actionTitle: actionTitle,
            action: action,
            additionalActions: additionalActions,
            notificationGroup: notificationGroup,
            notificationID: notificationID
        )
    }

    static func raw(
        _ title: String,
        level: FeedbackLevel,
        detail: String? = nil,
        nextStep: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        additionalActions: [FeedbackAction] = [],
        notificationID: String? = nil,
        notificationGroup: VcsNotificationGroup = .toolWindow
    ) -> FeedbackMessage {
        FeedbackMessage(
            level: level,
            title: title,
            titleIsLocalized: false,
            detail: detail,
            nextStep: nextStep,
            actionTitle: actionTitle,
            action: action,
            additionalActions: additionalActions,
            notificationGroup: notificationGroup,
            notificationID: notificationID
        )
    }
}

struct FeedbackAction: Identifiable {
    let id: String
    let title: String
    let semanticAction: ArborVCSActionRequest?
    let action: () -> Void

    init(
        id: String? = nil,
        title: String,
        semanticAction: ArborVCSActionRequest? = nil,
        action: @escaping () -> Void
    ) {
        self.id = id ?? title
        self.title = title
        self.semanticAction = semanticAction
        self.action = action
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

/// 用户可回看的 Git 操作记录。它和 DiagnosticsLogger 不同：这是产品界面
/// 中的操作历史，保留操作名称、结果、时间和用户可采取的下一步；仅保存
/// 安全摘要，Git 命令输出与可执行闭包不会跨进程持久化。
struct OperationLogEntry: Identifiable {
    let id: UUID
    let operation: String
    let title: String
    let titleIsLocalized: Bool
    let level: FeedbackLevel
    let detail: String?
    let nextStep: String?
    let actions: [FeedbackAction]
    let notificationGroup: VcsNotificationGroup
    /// Stable VcsNotifier-style display identity. Persisting it lets a new
    /// process update the same operation-log row after relaunch.
    let notificationID: String?
    /// Action labels are persisted as historical context. Closures are only
    /// valid for the current process and are intentionally never serialized.
    let actionTitles: [String]
    let command: String?
    let stdout: String?
    let stderr: String?
    let startedAt: Date
    let finishedAt: Date?
    /// Root-qualified outcome rows for compound Git operations. This is a
    /// presentation snapshot, not an authority for retry safety.
    let resultRows: [FeedbackResultRow]
    /// Item-level outcome rows for one root-scoped batch operation. This is a
    /// presentation snapshot, not an authority for retry safety.
    let resultItems: [FeedbackOperationItem]

    init(
        id: UUID,
        operation: String,
        title: String,
        titleIsLocalized: Bool,
        level: FeedbackLevel,
        detail: String?,
        nextStep: String?,
        actions: [FeedbackAction],
        notificationGroup: VcsNotificationGroup,
        notificationID: String?,
        actionTitles: [String],
        command: String?,
        stdout: String?,
        stderr: String?,
        startedAt: Date,
        finishedAt: Date?,
        resultRows: [FeedbackResultRow] = [],
        resultItems: [FeedbackOperationItem] = []
    ) {
        self.id = id
        self.operation = operation
        self.title = title
        self.titleIsLocalized = titleIsLocalized
        self.level = level
        self.detail = detail
        self.nextStep = nextStep
        self.actions = actions
        self.notificationGroup = notificationGroup
        self.notificationID = notificationID
        self.actionTitles = actionTitles
        self.command = command
        self.stdout = stdout
        self.stderr = stderr
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.resultRows = resultRows
        self.resultItems = resultItems
    }

    var isRunning: Bool { finishedAt == nil }

    var visibleActionTitles: [String] {
        actions.isEmpty ? actionTitles : actions.map(\.title)
    }

    var durationText: String? {
        guard let finishedAt else { return nil }
        return String(format: "%.1fs", max(0, finishedAt.timeIntervalSince(startedAt)))
    }
}

private struct PersistedOperationLogEntry: Codable {
    private struct PersistedFeedbackAction: Codable {
        let title: String
        let request: ArborVCSActionRequest?
    }

    let id: UUID
    let operation: String
    let title: String
    let titleIsLocalized: Bool
    let level: String
    let detail: String?
    let nextStep: String?
    let actionTitles: [String]
    let notificationGroup: VcsNotificationGroup
    let notificationID: String?
    private let actionContexts: [PersistedFeedbackAction]
    let startedAt: Date
    let finishedAt: Date?
    let resultRows: [FeedbackResultRow]
    let resultItems: [FeedbackOperationItem]

    private enum CodingKeys: String, CodingKey {
        case id
        case operation
        case title
        case titleIsLocalized
        case level
        case detail
        case nextStep
        case actionTitles
        case notificationGroup
        case notificationID
        case actionContexts
        case startedAt
        case finishedAt
        case resultRows
        case resultItems
    }

    init(_ entry: OperationLogEntry) {
        id = entry.id
        operation = entry.operation
        title = entry.title
        titleIsLocalized = entry.titleIsLocalized
        level = switch entry.level {
        case .info: "info"
        case .success: "success"
        case .warning: "warning"
        case .error: "error"
        }
        detail = entry.detail
        nextStep = entry.nextStep
        actionTitles = entry.visibleActionTitles
        notificationGroup = entry.notificationGroup
        notificationID = entry.notificationID
        actionContexts = entry.actions.map {
            PersistedFeedbackAction(title: $0.title, request: $0.semanticAction)
        }
        startedAt = entry.startedAt
        finishedAt = entry.finishedAt
        resultRows = entry.resultRows
        resultItems = entry.resultItems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        operation = try container.decode(String.self, forKey: .operation)
        title = try container.decode(String.self, forKey: .title)
        titleIsLocalized = try container.decode(Bool.self, forKey: .titleIsLocalized)
        level = try container.decode(String.self, forKey: .level)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        nextStep = try container.decodeIfPresent(String.self, forKey: .nextStep)
        actionTitles = try container.decode([String].self, forKey: .actionTitles)
        notificationGroup = try container.decodeIfPresent(
            VcsNotificationGroup.self,
            forKey: .notificationGroup
        ) ?? .toolWindow
        notificationID = try container.decodeIfPresent(String.self, forKey: .notificationID)
        actionContexts = try container.decodeIfPresent(
            [PersistedFeedbackAction].self,
            forKey: .actionContexts
        ) ?? []
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        resultRows = try container.decodeIfPresent(
            [FeedbackResultRow].self,
            forKey: .resultRows
        ) ?? []
        resultItems = try container.decodeIfPresent(
            [FeedbackOperationItem].self,
            forKey: .resultItems
        ) ?? []
    }

    func operationLogEntry() -> OperationLogEntry {
        let recoveredLevel: FeedbackLevel = switch level {
        case "success": .success
        case "warning": .warning
        case "error": .error
        default: .info
        }
        let wasInterrupted = finishedAt == nil
        let recoveredDetail: String?
        if wasInterrupted {
            let interruption = "The previous session ended before this operation finished."
            recoveredDetail = [detail, interruption].compactMap { $0 }.joined(separator: "\n")
        } else {
            recoveredDetail = detail
        }
        // Closure-only actions cannot be reconstructed after relaunch, but a
        // mixed notification may still contain safe semantic actions beside
        // them (for example View Commits and Retry next to Resolve Conflicts).
        // Recover only the requests whose routing context is complete.
        let recoveredActions = actionContexts.compactMap { item -> FeedbackAction? in
            guard let request = item.request else { return nil }
            return FeedbackAction(title: item.title, semanticAction: request) {
                NotificationCenter.default.post(name: .arborVCSAction, object: request)
            }
        }
        return OperationLogEntry(
            id: id,
            operation: operation,
            title: wasInterrupted ? "Operation interrupted" : title,
            titleIsLocalized: wasInterrupted ? false : titleIsLocalized,
            level: wasInterrupted ? .warning : recoveredLevel,
            detail: recoveredDetail,
            nextStep: nextStep,
            actions: recoveredActions,
            notificationGroup: notificationGroup,
            notificationID: notificationID,
            actionTitles: actionTitles,
            command: nil,
            stdout: nil,
            stderr: nil,
            startedAt: startedAt,
            finishedAt: wasInterrupted ? startedAt : finishedAt,
            resultRows: resultRows,
            resultItems: resultItems
        )
    }
}

@MainActor
final class FeedbackCenter: ObservableObject {
    @Published private(set) var current: FeedbackMessage?
    @Published private(set) var toast: FeedbackMessage?
    @Published private(set) var nativeNotificationPermissionWarning: FeedbackMessage?
    @Published private(set) var isRunning = false
    @Published private(set) var canCancel = false
    @Published private(set) var operationName: String?
    @Published private(set) var progress: GitProgressState?
    @Published private(set) var batchProgress: FeedbackBatchProgress?
    @Published private(set) var history: [OperationLogEntry] = []

    private var dismissTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var activeOperationID: UUID?
    private var cancelOperation: (() -> Void)?
    private var notificationEntryIDs: [String: UUID] = [:]
    private let maximumHistoryCount = 100
    private let defaults: UserDefaults
    private let historyKey = "arbor.feedback.operationHistory.v2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ArborNativeNotificationCenter.shared.onAuthorizationStatusChange = { [weak self] allowed in
            self?.applyNativeNotificationAuthorizationStatus(allowed)
        }
        ArborNativeNotificationCenter.shared.refreshAuthorizationStatus()
        if let data = defaults.data(forKey: historyKey),
           let persisted = try? JSONDecoder().decode([PersistedOperationLogEntry].self, from: data)
        {
            history = persisted.map { $0.operationLogEntry() }
            // Rebuild the display-id index before the first post-relaunch
            // notification. History is newest-first, so keep the newest row
            // when old data contains duplicate IDs.
            for entry in history {
                guard let notificationID = entry.notificationID,
                      notificationEntryIDs[notificationID] == nil else { continue }
                notificationEntryIDs[notificationID] = entry.id
            }
        } else {
            history = []
        }
    }

    func applyNativeNotificationAuthorizationStatus(_ allowed: Bool?) {
        switch allowed {
        case .some(true), .none:
            nativeNotificationPermissionWarning = nil
        case .some(false):
            nativeNotificationPermissionWarning = FeedbackMessage.raw(
                "macOS notifications are disabled",
                level: .warning,
                detail: "Arbor still shows Git feedback in the app. Enable notifications for Arbor in macOS System Settings to receive VCS banners.",
                actionTitle: "Open Notification Settings",
                action: {
                    _ = openArborNotificationSettings()
                },
                notificationGroup: .toolWindow
            )
        }
    }

    func begin(
        _ operation: String,
        notificationID: String? = nil,
        preserveResultItems: Bool = false,
        onCancel: (() -> Void)? = nil
    ) {
        dismissTask?.cancel()
        progressTask?.cancel()
        progress = nil
        isRunning = true
        canCancel = onCancel != nil
        cancelOperation = onCancel
        operationName = operation
        batchProgress = nil
        current = .localized("Working…", level: .info, detail: operation)
        toast = nil

        if let notificationID,
           let existingEntryID = notificationEntryIDs[notificationID],
           let index = history.firstIndex(where: { $0.id == existingEntryID })
        {
            let previous = history[index]
            activeOperationID = previous.id
            history[index] = OperationLogEntry(
                id: previous.id,
                operation: operation,
                title: "Working…",
                titleIsLocalized: true,
                level: .info,
                detail: operation,
                nextStep: nil,
                actions: [],
                notificationGroup: previous.notificationGroup,
                notificationID: notificationID,
                actionTitles: [],
                command: previous.command,
                stdout: previous.stdout,
                stderr: previous.stderr,
                startedAt: previous.startedAt,
                finishedAt: nil,
                resultRows: [],
                resultItems: preserveResultItems ? previous.resultItems : []
            )
        } else if let activeOperationID,
           let index = history.firstIndex(where: { $0.id == activeOperationID }) {
            let previous = history[index]
            history[index] = OperationLogEntry(
                id: previous.id,
                operation: operation,
                title: previous.title,
                titleIsLocalized: previous.titleIsLocalized,
                level: previous.level,
                detail: previous.detail,
                nextStep: previous.nextStep,
                actions: [],
                notificationGroup: previous.notificationGroup,
                notificationID: previous.notificationID,
                actionTitles: [],
                command: previous.command,
                stdout: previous.stdout,
                stderr: previous.stderr,
                startedAt: previous.startedAt,
                finishedAt: nil,
                resultRows: [],
                resultItems: preserveResultItems ? previous.resultItems : []
            )
        } else {
            let entry = OperationLogEntry(
                id: UUID(),
                operation: operation,
                title: "Working…",
                titleIsLocalized: true,
                level: .info,
                detail: operation,
                nextStep: nil,
                actions: [],
                notificationGroup: .toolWindow,
                notificationID: notificationID,
                actionTitles: [],
                command: nil,
                stdout: nil,
                stderr: nil,
                startedAt: Date(),
                finishedAt: nil
            )
            activeOperationID = entry.id
            if let notificationID {
                notificationEntryIDs[notificationID] = entry.id
            }
            history.insert(entry, at: 0)
            trimHistory()
        }
        persistHistory()
        startProgressPolling()
    }

    func updateBatchProgress(
        completed: Int,
        total: Int,
        phase: String,
        detail: String? = nil
    ) {
        guard isRunning else { return }
        batchProgress = FeedbackBatchProgress(
            completed: min(max(completed, 0), max(total, 0)),
            total: max(total, 0),
            phase: phase,
            detail: detail
        )
    }

    /// Git transport progress is emitted by the Rust process layer on stderr.
    /// Polling a small immutable snapshot keeps existing UniFFI operation
    /// methods source-compatible while making the status bar show the same
    /// phase/percentage feedback as IntelliJ's progress indicator.
    private func startProgressPolling() {
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isRunning else { return }
                self.progress = gitProgressState()
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    func success(
        _ title: String,
        detail: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        additionalActions: [FeedbackAction] = [],
        notificationID: String? = nil,
        notificationGroup: VcsNotificationGroup = .toolWindow,
        localized: Bool = true
    ) {
        let message = localized
            ? FeedbackMessage.localized(
                title,
                level: .success,
                detail: detail,
                actionTitle: actionTitle,
                action: action,
                additionalActions: additionalActions,
                notificationID: notificationID,
                notificationGroup: notificationGroup
            )
            : FeedbackMessage.raw(
                title,
                level: .success,
                detail: detail,
                actionTitle: actionTitle,
                action: action,
                additionalActions: additionalActions,
                notificationID: notificationID,
                notificationGroup: notificationGroup
            )
        finish(with: message)
        // A success message with an action must remain available long enough
        // for the user to invoke it. Plain success toasts keep the existing
        // three-second dismissal behavior.
        publish(message, autoDismiss: message.actions.isEmpty)
    }

    func warning(
        _ title: String,
        detail: String? = nil,
        nextStep: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        additionalActions: [FeedbackAction] = [],
        notificationID: String? = nil,
        notificationGroup: VcsNotificationGroup = .toolWindow,
        localized: Bool = true
    ) {
        let message = localized
            ? FeedbackMessage.localized(
                title,
                level: .warning,
                detail: detail,
                nextStep: nextStep,
                actionTitle: actionTitle,
                action: action,
                additionalActions: additionalActions,
                notificationID: notificationID,
                notificationGroup: notificationGroup
            )
            : FeedbackMessage.raw(
                title,
                level: .warning,
                detail: detail,
                nextStep: nextStep,
                actionTitle: actionTitle,
                action: action,
                additionalActions: additionalActions,
                notificationID: notificationID,
                notificationGroup: notificationGroup
            )
        finish(with: message)
        publish(
            message,
            autoDismiss: message.actions.isEmpty
                && message.notificationGroup == .standard
        )
    }

    func error(
        _ title: String,
        detail: String? = nil,
        nextStep: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        additionalActions: [FeedbackAction] = [],
        notificationID: String? = nil,
        notificationGroup: VcsNotificationGroup = .important,
        localized: Bool = false
    ) {
        let message = localized
            ? FeedbackMessage.localized(
                title,
                level: .error,
                detail: detail,
                nextStep: nextStep,
                actionTitle: actionTitle,
                action: action,
                additionalActions: additionalActions,
                notificationID: notificationID,
                notificationGroup: notificationGroup
            )
            : FeedbackMessage.raw(
                title,
                level: .error,
                detail: detail,
                nextStep: nextStep,
                actionTitle: actionTitle,
                action: action,
                additionalActions: additionalActions,
                notificationID: notificationID,
                notificationGroup: notificationGroup
            )
        finish(with: message)
        publish(message, autoDismiss: false)
    }

    /// Bridges legacy operation-specific feedback into the unified channel.
    /// Existing inline messages remain in their tool window; this is the global
    /// status/toast path restored after the v0.14 layout migration.
    func publishLegacy(_ text: String) {
        let lowercased = text.lowercased()
        let isError = lowercased.contains("失败")
            || lowercased.contains("错误")
            || lowercased.contains("冲突")
            || lowercased.contains("error")
            || lowercased.contains("failed")
        let isWarning = lowercased.contains("请先")
            || lowercased.contains("未推送")
            || lowercased.contains("暂停")
        let message: FeedbackMessage
        let autoDismiss: Bool
        if isError {
            message = .raw(
                "Operation failed",
                level: .error,
                detail: text,
                nextStep: nextStep(for: text),
                notificationGroup: .important
            )
            autoDismiss = false
        } else if isWarning {
            message = .raw(text, level: .warning, notificationGroup: .toolWindow)
            autoDismiss = false
        } else {
            message = .raw(text, level: .success, notificationGroup: .toolWindow)
            autoDismiss = true
        }
        finish(with: message, historyDetail: text)
        publish(message, autoDismiss: autoDismiss)
    }

    func clearHistory() {
        if let activeOperationID {
            history.removeAll { $0.id != activeOperationID }
        } else {
            history.removeAll()
        }
        notificationEntryIDs.removeAll()
        persistHistory()
    }

    /// 将一次原始 Git 命令写入当前操作，完成后仍保留在可折叠历史中。
    func recordGitCommand(_ result: GitCommandResult) {
        guard let activeOperationID,
              let index = history.firstIndex(where: { $0.id == activeOperationID }) else { return }
        let previous = history[index]
        history[index] = OperationLogEntry(
            id: previous.id,
            operation: previous.operation,
            title: previous.title,
            titleIsLocalized: previous.titleIsLocalized,
            level: previous.level,
            detail: previous.detail,
            nextStep: previous.nextStep,
            actions: previous.actions,
            notificationGroup: previous.notificationGroup,
            notificationID: previous.notificationID,
            actionTitles: previous.actionTitles,
            command: result.command,
            stdout: result.stdout,
            stderr: result.stderr,
            startedAt: previous.startedAt,
            finishedAt: previous.finishedAt,
            resultRows: previous.resultRows,
            resultItems: previous.resultItems
        )
        persistHistory()
    }

    /// Attach the root-level result tree after a compound operation has
    /// finished. The stable notification ID is the grouping key used by
    /// retries and by reloaded Operation Log entries.
    func attachResultRows(
        _ rows: [FeedbackResultRow],
        notificationID: String? = nil
    ) {
        guard !rows.isEmpty else { return }
        let entryID: UUID?
        if let notificationID {
            entryID = notificationEntryIDs[notificationID]
        } else {
            entryID = history.first?.id
        }
        guard let entryID,
              let index = history.firstIndex(where: { $0.id == entryID }) else { return }
        let previous = history[index]
        history[index] = OperationLogEntry(
            id: previous.id,
            operation: previous.operation,
            title: previous.title,
            titleIsLocalized: previous.titleIsLocalized,
            level: previous.level,
            detail: previous.detail,
            nextStep: previous.nextStep,
            actions: previous.actions,
            notificationGroup: previous.notificationGroup,
            notificationID: previous.notificationID,
            actionTitles: previous.actionTitles,
            command: previous.command,
            stdout: previous.stdout,
            stderr: previous.stderr,
            startedAt: previous.startedAt,
            finishedAt: previous.finishedAt,
            resultRows: rows,
            resultItems: previous.resultItems
        )
        persistHistory()
    }

    /// Attach item-level outcomes to the same stable operation entry used by
    /// retries and reloaded Operation Log history.
    func attachOperationItems(
        _ items: [FeedbackOperationItem],
        notificationID: String? = nil,
        mergeWithExisting: Bool = false
    ) {
        guard !items.isEmpty else { return }
        let entryID: UUID?
        if let notificationID {
            entryID = notificationEntryIDs[notificationID]
        } else {
            entryID = history.first?.id
        }
        guard let entryID,
              let index = history.firstIndex(where: { $0.id == entryID }) else { return }
        let previous = history[index]
        history[index] = OperationLogEntry(
            id: previous.id,
            operation: previous.operation,
            title: previous.title,
            titleIsLocalized: previous.titleIsLocalized,
            level: previous.level,
            detail: previous.detail,
            nextStep: previous.nextStep,
            actions: previous.actions,
            notificationGroup: previous.notificationGroup,
            notificationID: previous.notificationID,
            actionTitles: previous.actionTitles,
            command: previous.command,
            stdout: previous.stdout,
            stderr: previous.stderr,
            startedAt: previous.startedAt,
            finishedAt: previous.finishedAt,
            resultRows: previous.resultRows,
            resultItems: mergeWithExisting
                ? mergeFeedbackOperationItems(
                    preserved: previous.resultItems,
                    retry: items
                )
                : items
        )
        persistHistory()
    }

    private func nextStep(for text: String) -> String {
        let lowercased = text.lowercased()
        if lowercased.contains("ssh host key changed")
            || lowercased.contains("remote host identification has changed")
        {
            return "The connection was blocked because the remote SSH host key changed. Verify the server identity, review Known Hosts in Git SSH Settings, then retry."
        }
        if lowercased.contains("auth") || lowercased.contains("认证") || lowercased.contains("credential") {
            return "Check the remote credentials in Settings, then retry."
        }
        if lowercased.contains("untracked") || lowercased.contains("未跟踪") {
            return "These local files will not be committed; preserve them temporarily and retry the operation."
        }
        if lowercased.contains("conflict") || lowercased.contains("冲突") {
            return "Open Merge Revisions, resolve the files, then continue the operation."
        }
        if lowercased.contains("upstream") || lowercased.contains("tracking") || lowercased.contains("pull") {
            return "Check the branch upstream and remote-tracking branch, then retry."
        }
        if lowercased.contains("dirty") || lowercased.contains("未跟踪") || lowercased.contains("stash") {
            return "Commit or stash the local changes, then retry."
        }
        return "Open the details button for the full error, then retry after fixing the cause."
    }

    func dismissToast() {
        dismissTask?.cancel()
        toast = nil
    }

    /// Expires a stable VcsNotifier-style display ID in every presentation
    /// channel. History remains intact, but a resolved recovery or retry
    /// notification must not stay actionable after its Git state is gone.
    func expire(notificationID: String) {
        notificationEntryIDs.removeValue(forKey: notificationID)
        var didUpdateHistory = false
        for index in history.indices where history[index].notificationID == notificationID {
            let previous = history[index]
            history[index] = OperationLogEntry(
                id: previous.id,
                operation: previous.operation,
                title: previous.title,
                titleIsLocalized: previous.titleIsLocalized,
                level: previous.level,
                detail: previous.detail,
                nextStep: previous.nextStep,
                actions: [],
                notificationGroup: previous.notificationGroup,
                notificationID: nil,
                actionTitles: [],
                command: previous.command,
                stdout: previous.stdout,
                stderr: previous.stderr,
                startedAt: previous.startedAt,
                finishedAt: previous.finishedAt,
                resultRows: previous.resultRows,
                resultItems: previous.resultItems
            )
            didUpdateHistory = true
        }
        if didUpdateHistory {
            persistHistory()
        }
        if current?.notificationID == notificationID {
            current = nil
        }
        if toast?.notificationID == notificationID {
            toast = nil
        }
        ArborNativeNotificationCenter.shared.expire(notificationID: notificationID)
    }

    func cancel() {
        guard isRunning, let cancelOperation else { return }
        canCancel = false
        current = .localized("Cancelling…", level: .info, detail: operationName)
        cancelOperation()
    }

    private func finish(with message: FeedbackMessage, historyDetail: String? = nil) {
        let finishedAt = Date()
        if let activeOperationID,
           let index = history.firstIndex(where: { $0.id == activeOperationID }) {
            let previous = history[index]
            history[index] = OperationLogEntry(
                id: previous.id,
                operation: previous.operation,
                title: message.title,
                titleIsLocalized: message.titleIsLocalized,
                level: message.level,
                detail: historyDetail ?? message.detail,
                nextStep: message.nextStep,
                actions: message.actions,
                notificationGroup: message.notificationGroup,
                notificationID: message.notificationID,
                actionTitles: message.actions.map(\.title),
                command: previous.command,
                stdout: previous.stdout,
                stderr: previous.stderr,
                startedAt: previous.startedAt,
                finishedAt: finishedAt,
                resultRows: previous.resultRows,
                resultItems: previous.resultItems
            )
            if let notificationID = message.notificationID {
                notificationEntryIDs[notificationID] = previous.id
            }
        } else if let notificationID = message.notificationID,
                  let entryID = notificationEntryIDs[notificationID],
                  let index = history.firstIndex(where: { $0.id == entryID }) {
            let previous = history[index]
            history[index] = OperationLogEntry(
                id: previous.id,
                operation: operationName ?? previous.operation,
                title: message.title,
                titleIsLocalized: message.titleIsLocalized,
                level: message.level,
                detail: historyDetail ?? message.detail,
                nextStep: message.nextStep,
                actions: message.actions,
                notificationGroup: message.notificationGroup,
                notificationID: message.notificationID,
                actionTitles: message.actions.map(\.title),
                command: previous.command,
                stdout: previous.stdout,
                stderr: previous.stderr,
                startedAt: previous.startedAt,
                finishedAt: finishedAt,
                resultRows: previous.resultRows,
                resultItems: previous.resultItems
            )
        } else {
            let entryID = UUID()
            let entry = OperationLogEntry(
                id: entryID,
                operation: operationName ?? "Git operation",
                title: message.title,
                titleIsLocalized: message.titleIsLocalized,
                level: message.level,
                detail: historyDetail ?? message.detail,
                nextStep: message.nextStep,
                actions: message.actions,
                notificationGroup: message.notificationGroup,
                notificationID: message.notificationID,
                actionTitles: message.actions.map(\.title),
                command: nil,
                stdout: nil,
                stderr: nil,
                startedAt: finishedAt,
                finishedAt: finishedAt
            )
            history.insert(entry, at: 0)
            if let notificationID = message.notificationID {
                notificationEntryIDs[notificationID] = entryID
            }
            trimHistory()
        }
        persistHistory()
        activeOperationID = nil
        isRunning = false
        canCancel = false
        cancelOperation = nil
        operationName = nil
        progressTask?.cancel()
        progressTask = nil
        progress = nil
        batchProgress = nil
    }

    private func trimHistory() {
        if history.count > maximumHistoryCount {
            history.removeLast(history.count - maximumHistoryCount)
        }
    }

    private func persistHistory() {
        let persisted = history.map(PersistedOperationLogEntry.init)
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        defaults.set(data, forKey: historyKey)
    }

    private func publish(_ message: FeedbackMessage, autoDismiss: Bool) {
        guard message.notificationGroup != .silent else {
            dismissTask?.cancel()
            current = nil
            toast = nil
            return
        }
        current = message
        toast = message
        ArborNativeNotificationCenter.shared.publish(message)
        dismissTask?.cancel()
        guard autoDismiss else { return }
        let id = message.id
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            guard self?.toast?.id == id else { return }
            self?.toast = nil
        }
    }
}

struct FeedbackMessageView: View {
    let message: FeedbackMessage
    let isCompact: Bool
    let onDetails: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: message.level.systemImage)
                .foregroundStyle(message.level.color)
            titleView
                .lineLimit(isCompact ? 1 : 2)
            if message.detail != nil || message.nextStep != nil {
                Button(action: onDetails) {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Show operation details")
            }
        }
    }

    @ViewBuilder
    private var titleView: some View {
        if message.titleIsLocalized {
            Text(LocalizedStringKey(message.title))
        } else {
            Text(message.title)
        }
    }
}

struct FeedbackDetailView: View {
    let message: FeedbackMessage
    let onDismiss: () -> Void
    let onOpenSSHSettings: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: message.level.systemImage)
                    .foregroundStyle(message.level.color)
                titleView
                    .font(.headline)
                Spacer()
            }
            if let detail = message.detail {
                Text(detail)
                    .textSelection(.enabled)
                    .font(.system(.body, design: .monospaced))
            }
            if let nextStep = message.nextStep {
                Label {
                    Text(LocalizedStringKey(nextStep))
                } icon: {
                    Image(systemName: "arrow.right.circle")
                }
                .foregroundStyle(.secondary)
            }
            if !message.actions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(message.actions.enumerated()), id: \.element.id) { index, item in
                        if index == 0 {
                            Button {
                                onDismiss()
                                item.action()
                            } label: {
                                Text(LocalizedStringKey(item.title))
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button {
                                onDismiss()
                                item.action()
                            } label: {
                                Text(LocalizedStringKey(item.title))
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            if isChangedHostKey, let onOpenSSHSettings {
                Button("Open Git SSH Settings", action: onOpenSSHSettings)
                    .buttonStyle(.bordered)
            }
            HStack {
                Spacer()
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420, alignment: .leading)
    }

    @ViewBuilder
    private var titleView: some View {
        if message.titleIsLocalized {
            Text(LocalizedStringKey(message.title))
        } else {
            Text(message.title)
        }
    }

    private var isChangedHostKey: Bool {
        let detail = message.detail?.lowercased() ?? ""
        return detail.contains("ssh host key changed")
            || detail.contains("remote host identification has changed")
    }
}

struct FeedbackToastView: View {
    let message: FeedbackMessage
    let onDetails: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            FeedbackMessageView(message: message, isCompact: false, onDetails: onDetails)
            if !message.actions.isEmpty {
                ForEach(message.actions) { item in
                    Button {
                        item.action()
                        onDismiss()
                    } label: {
                        Text(LocalizedStringKey(item.title))
                    }
                    .buttonStyle(.bordered)
                }
            }
            if message.level == .error || message.level == .warning {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(message.level.color.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
    }
}

/// Expandable Git task surface: the status bar remains a compact summary, but
/// the user can inspect the active operation's phase/batch progress and cancel
/// it without leaving the workspace. Completed operations remain in the
/// existing Operation Log so this view does not create a second history store.
struct GitTasksView: View {
    @ObservedObject var feedbackCenter: FeedbackCenter
    @Binding var focusNotificationID: String?
    let onOpenHistory: () -> Void

    private var recentEntries: [OperationLogEntry] {
        feedbackCenter.history
            .filter { !$0.isRunning }
            .prefix(20)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "checklist")
                    .foregroundStyle(Design.Colors.accent)
                Text("Git 任务")
                    .font(.system(size: 15, weight: .semibold))
                if feedbackCenter.isRunning {
                    Text("进行中")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("操作历史") { onOpenHistory() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if feedbackCenter.isRunning {
                activeTask
                    .padding(16)
                Divider()
            } else {
                ContentUnavailableView(
                    "暂无运行中的 Git 任务",
                    systemImage: "checklist",
                    description: Text("开始 fetch、pull、push、commit 或其它 Git 操作后，进度和取消入口会显示在这里。")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                Divider()
            }

            HStack {
                Text("最近完成")
                    .font(.headline)
                Text("\(recentEntries.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if recentEntries.isEmpty {
                Text("暂无已完成任务")
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(recentEntries) { entry in
                            Button {
                                focusNotificationID = entry.notificationID
                                onOpenHistory()
                            } label: {
                                OperationLogRow(entry: entry, isSelected: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            Spacer(minLength: 0)
        }
        .background(Design.Colors.canvas)
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private var activeTask: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(feedbackCenter.operationName ?? "Git operation")
                    .font(.headline)
                Spacer()
                if feedbackCenter.canCancel {
                    Button("取消") { feedbackCenter.cancel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            if let message = feedbackCenter.current {
                FeedbackMessageView(
                    message: message,
                    isCompact: false,
                    onDetails: onOpenHistory
                )
                .font(.callout)
            }
            if let progress = feedbackCenter.progress {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        if let percentage = progress.percentage {
                            ProgressView(value: Double(percentage), total: 100)
                                .frame(maxWidth: 260)
                            Text("\(percentage)%")
                                .monospacedDigit()
                        } else {
                            ProgressView()
                                .frame(width: 260)
                        }
                        Text(progress.phase)
                            .foregroundStyle(.secondary)
                    }
                    Text(progress.detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    if progress.totalRoots > 0 {
                        HStack(spacing: 8) {
                            ProgressView(
                                value: Double(progress.completedRoots),
                                total: Double(max(progress.totalRoots, 1))
                            )
                            .frame(maxWidth: 260)
                            Text("\(progress.completedRoots)/\(progress.totalRoots) roots")
                                .monospacedDigit()
                            if !progress.rootName.isEmpty {
                                Text(progress.rootName)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !progress.rootState.isEmpty {
                        Text(progress.rootState)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let batchProgress = feedbackCenter.batchProgress {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        ProgressView(
                            value: Double(batchProgress.completed),
                            total: Double(max(batchProgress.total, 1))
                        )
                        .frame(maxWidth: 260)
                        Text(batchProgress.percentage.map { "\($0)%" }
                             ?? "\(batchProgress.completed)/\(batchProgress.total)")
                            .monospacedDigit()
                        Text(batchProgress.phase)
                            .foregroundStyle(.secondary)
                    }
                    if let detail = batchProgress.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }
}

struct OperationLogView: View {
    @ObservedObject var feedbackCenter: FeedbackCenter
    @Binding var focusNotificationID: String?
    @State private var selectedID: UUID?

    private var selectedEntry: OperationLogEntry? {
        guard let selectedID else { return feedbackCenter.history.first }
        return feedbackCenter.history.first(where: { $0.id == selectedID })
            ?? feedbackCenter.history.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(Design.Colors.accent)
                Text("操作日志")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(feedbackCenter.history.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("清空") { feedbackCenter.clearHistory(); selectedID = nil }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(feedbackCenter.history.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if feedbackCenter.history.isEmpty {
                ContentUnavailableView(
                    "暂无操作记录",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("执行 pull、fetch、push、commit 或分支操作后，结果会显示在这里。")
                )
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(feedbackCenter.history) { entry in
                                OperationLogRow(
                                    entry: entry,
                                    isSelected: selectedEntry?.id == entry.id
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { selectedID = entry.id }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 176)

                    Divider()

                    ScrollView {
                        operationDetail
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(18)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Design.Colors.canvas)
        .foregroundStyle(.primary)
        .onAppear {
            selectFocusedEntry()
            selectedID = selectedID ?? selectedEntry?.id
        }
        .onChange(of: focusNotificationID) { _, _ in
            selectFocusedEntry()
        }
    }

    private func selectFocusedEntry() {
        guard let focusNotificationID,
              let entry = feedbackCenter.history.first(where: {
                  $0.notificationID == focusNotificationID
              }) else { return }
        selectedID = entry.id
    }

    @ViewBuilder
    private var operationDetail: some View {
        if let entry = selectedEntry {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: entry.level.systemImage)
                        .foregroundStyle(entry.level.color)
                    if entry.titleIsLocalized {
                        Text(LocalizedStringKey(entry.title)).font(.headline)
                    } else {
                        Text(entry.title).font(.headline)
                    }
                    Spacer()
                }
                Text(entry.operation)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Text(Self.dateFormatter.string(from: entry.startedAt))
                    if let duration = entry.durationText { Text(duration) }
                    if entry.isRunning { Text("进行中") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let detail = entry.detail {
                    Divider()
                    Text(detail)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                if !entry.resultRows.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Repositories")
                            .font(.headline)
                        ForEach(entry.resultRows) { row in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: resultStateIcon(row.state))
                                    .foregroundStyle(resultStateColor(row.state))
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.displayName)
                                        .font(.callout.weight(.semibold))
                                    Text(row.rootPath)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                    if !row.detail.isEmpty {
                                        Text(row.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                if !entry.resultItems.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Items")
                            .font(.headline)
                        ForEach(entry.resultItems) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: resultStateIcon(item.state))
                                    .foregroundStyle(resultStateColor(item.state))
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .font(.callout.weight(.semibold))
                                    Text(item.scope)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                    if !item.detail.isEmpty {
                                        Text(item.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                    ForEach(item.children) { child in
                                        HStack(alignment: .top, spacing: 6) {
                                            Image(systemName: resultStateIcon(child.state))
                                                .foregroundStyle(resultStateColor(child.state))
                                                .frame(width: 14)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(child.path)
                                                    .font(.caption2.monospaced())
                                                    .textSelection(.enabled)
                                                if !child.detail.isEmpty {
                                                    Text(child.detail)
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                        .textSelection(.enabled)
                                                }
                                            }
                                        }
                                        .padding(.leading, 4)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                if let command = entry.command {
                    Divider()
                    DisclosureGroup("Git Console") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(command)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            if let stdout = entry.stdout, !stdout.isEmpty {
                                Text("stdout")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(stdout)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            if let stderr = entry.stderr, !stderr.isEmpty {
                                Text("stderr")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(stderr)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                if let nextStep = entry.nextStep {
                    Label(nextStep, systemImage: "arrow.right.circle")
                        .foregroundStyle(.secondary)
                }
                if !entry.visibleActionTitles.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        if entry.actions.isEmpty {
                            ForEach(Array(entry.actionTitles.enumerated()), id: \.offset) { _, title in
                                Label(LocalizedStringKey(title), systemImage: "clock.arrow.circlepath")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            ForEach(entry.actions) { item in
                                Button {
                                    item.action()
                                } label: {
                                    Text(LocalizedStringKey(item.title))
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
        }
    }

    fileprivate static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    private func resultStateIcon(_ state: FeedbackResultState) -> String {
        switch state {
        case .success: "checkmark.circle.fill"
        case .partial: "circle.lefthalf.filled"
        case .skipped: "minus.circle"
        case .failed: "xmark.circle.fill"
        case .aborted: "slash.circle.fill"
        }
    }

    private func resultStateColor(_ state: FeedbackResultState) -> Color {
        switch state {
        case .success: Design.Colors.success
        case .partial: .orange
        case .skipped: .orange
        case .failed: Design.Colors.error
        case .aborted: .orange
        }
    }
}

private struct OperationLogRow: View {
    let entry: OperationLogEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            if entry.isRunning {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: entry.level.systemImage)
                    .foregroundStyle(entry.level.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                if entry.titleIsLocalized {
                    Text(LocalizedStringKey(entry.title))
                        .font(.callout.weight(.medium))
                } else {
                    Text(entry.title)
                        .font(.callout.weight(.medium))
                }
                Text(entry.operation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !entry.resultRows.isEmpty || !entry.resultItems.isEmpty {
                    let counts = [
                        entry.resultRows.isEmpty ? nil : "\(entry.resultRows.count) repositories",
                        entry.resultItems.isEmpty ? nil : "\(entry.resultItems.count) items"
                    ].compactMap { $0 }.joined(separator: " · ")
                    Text(counts)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
            Text(OperationLogView.dateFormatter.string(from: entry.startedAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Design.Colors.selection : .clear)
    }
}
