import SwiftUI
import UserNotifications
import Foundation
import AppKit


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

    /// `clearHistory()` keeps the entry of the operation that is still
    /// running, so a history that contains nothing else cannot be cleared.
    /// The button must be disabled in that case: an enabled “Clear” that
    /// silently does nothing is exactly the dead control this UI does not
    /// ship.
    var hasClearableHistory: Bool {
        history.contains { $0.id != activeOperationID }
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
