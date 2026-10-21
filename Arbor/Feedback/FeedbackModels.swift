import SwiftUI
import UserNotifications
import Foundation
import AppKit

func arborNotificationIDComponent(_ value: String) -> String {
    value
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
        .replacingOccurrences(of: "|", with: "_")
        .replacingOccurrences(of: " ", with: "_")
}


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
