import SwiftUI
import AppKit

/// 一次 diff 请求的来源。提交 diff 与“与本地版本比较”共用同一个 tab
/// 视图，但必须保留 revision，异步结果才能按来源 fail closed。
enum LogDiffSource: Equatable {
    case commit
    case local(revision: String)

    /// 异步结果同时按 change identity 和 revision 校验；只比较 `record.id`
    /// 会让同名文件的 `Compare with Local` 结果覆盖提交 diff。
    var identity: String {
        switch self {
        case .commit: "commit"
        case let .local(revision): "local:\(revision)"
        }
    }
}

/// 在 Log 编辑区打开的提交文件 diff。
///
/// IntelliJ 的 Changes Browser 把 Show Diff / 双击 / Enter 交给
/// `EditorTabPreview`，在编辑器里开一个独立的 `Repository Diff: <file>`
/// tab。Arbor 之前把同一份 diff 塞进最右侧详情栏的窄分栏里，side-by-side
/// 两栏都会被压到读不清；这里改成编辑区自己的 tab，diff 占满整个宽度。
struct LogFileDiffTab: Equatable {
    var record: LogChangeRecord
    var source: LogDiffSource
    /// 打开时 Changes Browser 中可见的文件顺序，用于 tab 内的上一/下一文件
    /// 导航。顺序在打开瞬间固定，避免后台重载让导航跳过文件。
    var siblings: [LogChangeRecord] = []

    var title: String {
        let name = URL(fileURLWithPath: record.change.path).lastPathComponent
        return name.isEmpty ? record.change.path : name
    }

    var previousRecord: LogChangeRecord? {
        adjacentRecord(offset: -1)
    }

    var nextRecord: LogChangeRecord? {
        adjacentRecord(offset: 1)
    }

    func adjacentRecord(offset: Int) -> LogChangeRecord? {
        guard let index = siblings.firstIndex(where: { $0.id == record.id }) else {
            return nil
        }
        let target = index + offset
        guard siblings.indices.contains(target) else { return nil }
        return siblings[target]
    }
}

extension ContentView {
    /// Changes Browser 的独立 diff action。与 IntelliJ 一样，它不依赖内嵌
    /// preview：preview 关闭时 Show Diff、双击和 Enter 仍然打开这个 tab。
    func openLogFileDiffTab(
        _ record: LogChangeRecord,
        source: LogDiffSource = .commit,
        siblings: [LogChangeRecord] = []
    ) {
        let ordered = siblings.contains(where: { $0.id == record.id })
            ? siblings
            : [record]
        logSelectionState.fileDiffTab = LogFileDiffTab(
            record: record,
            source: source,
            siblings: ordered
        )
        logSelectionState.fileDiffTabActive = true
    }

    func showLogFileDiffTab() {
        guard logSelectionState.fileDiffTab != nil else { return }
        logSelectionState.fileDiffTabActive = true
    }

    func showLogTab() {
        logSelectionState.fileDiffTabActive = false
    }

    func closeLogFileDiffTab() {
        logSelectionState.fileDiffTab = nil
        logSelectionState.fileDiffTabActive = false
    }

    func selectLogFileDiffTabRecord(_ record: LogChangeRecord) {
        guard var tab = logSelectionState.fileDiffTab else { return }
        tab.record = record
        logSelectionState.fileDiffTab = tab
    }

    /// Log 编辑区的 tab 条：`Log` 与当前 diff tab。切换页签不会丢失已经
    /// 打开的 diff；关闭 diff tab 才清除它。
    @ViewBuilder
    func logFileDiffTabBar(_ tab: LogFileDiffTab) -> some View {
        let isDiffActive = logSelectionState.fileDiffTabActive
        HStack(spacing: 6) {
            Button(action: showLogTab) {
                Label("Log", systemImage: "point.3.connected.trianglepath.dotted")
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isDiffActive ? .secondary : .primary)
            .background(
                isDiffActive ? Color.clear : Design.Colors.selection,
                in: RoundedRectangle(cornerRadius: 5)
            )
            .accessibilityIdentifier("log-file-diff-return-to-log")

            HStack(spacing: 6) {
                Button(action: showLogFileDiffTab) {
                    HStack(spacing: 6) {
                        Image(systemName: repositoryFileSymbol(for: tab.record.change.path))
                        Text("Repository Diff: \(tab.title)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(isDiffActive ? .primary : .secondary)
                .accessibilityIdentifier("log-file-diff-show-tab")
                Button(action: closeLogFileDiffTab) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close")
                .accessibilityIdentifier("log-file-diff-close")
            }
            .padding(.horizontal, 8)
            .background(
                isDiffActive ? Design.Colors.selection : Color.clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
            .help(tab.record.change.path)
            Spacer(minLength: 0)
        }
        .font(Design.Typography.interface(12))
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Design.Colors.chrome)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("log-file-diff-tab-bar")
    }

    @ViewBuilder
    func logFileDiffTabContent(_ tab: LogFileDiffTab) -> some View {
        let previous = tab.previousRecord
        let next = tab.nextRecord
        LogFileDiffView(
            record: tab.record,
            source: tab.source,
            repositoryForCommit: logRepository(for:),
            siblings: tab.siblings,
            onSelectFile: { record in
                selectLogFileDiffTabRecord(record)
            },
            onClose: closeLogFileDiffTab,
            onSelectPrevious: previous.map { record in
                { selectLogFileDiffTabRecord(record) }
            },
            onSelectNext: next.map { record in
                { selectLogFileDiffTabRecord(record) }
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Design.Colors.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("log-file-diff-tab")
    }
}
