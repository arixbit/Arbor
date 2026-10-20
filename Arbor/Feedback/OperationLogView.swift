import SwiftUI
import UserNotifications
import Foundation
import AppKit


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
