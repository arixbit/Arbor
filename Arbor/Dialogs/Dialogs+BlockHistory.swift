import SwiftUI

/// 选区标题：单行是 Line n，多行是 Lines a–b。
func blockHistoryLineRangeLabel(startLine: Int, endLine: Int) -> String {
    startLine == endLine ? "Line \(startLine)" : "Lines \(startLine)–\(endLine)"
}

/// IntelliJ 对照：`Vcs.ShowHistoryForBlock` → `SelectedBlockHistoryAction` →
/// `VcsSelectionHistoryDialog`。
///
/// fork 侧 `GitVcs.getVcsBlockHistoryProvider()` 复用普通 `GitHistoryProvider`，
/// 由 `BlockLoader` 把编辑器选区逐版本跟随；这里改用引擎的 `blockHistory`
/// （`git log -L`），直接拿到「改动过这段选区的提交」以及每个提交之后该选区
/// 的内容，不需要在 Swift 层重建 `Block` 跟随算法。
@MainActor
final class BlockHistoryRequest: ObservableObject, Identifiable {
    let id = UUID()
    let repo: Repository
    let path: String
    let startLine: Int
    let endLine: Int
    /// 一条提交能改动的行区间上限来自用户选择，这里只限制返回条数。
    let limit: UInt32

    @Published private(set) var entries: [BlockHistoryEntry] = []
    @Published private(set) var loading = true
    @Published private(set) var error: String?
    /// 引擎错误的本地化由调用方注入：`errorMessage` 是 `ContentView` 的成员，
    /// 模型不能反向依赖它。
    private let formatError: (Error) -> String

    init(
        repo: Repository,
        path: String,
        startLine: Int,
        endLine: Int,
        limit: UInt32 = 200,
        formatError: @escaping (Error) -> String = { "\($0)" }
    ) {
        self.repo = repo
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
        self.limit = limit
        self.formatError = formatError
    }

    var lineRangeLabel: String {
        blockHistoryLineRangeLabel(startLine: startLine, endLine: endLine)
    }

    func load() {
        loading = true
        error = nil
        let repo = repo
        let path = path
        let formatError = formatError
        let start = UInt32(clamping: startLine)
        let end = UInt32(clamping: endLine)
        let limit = limit
        Task.detached(priority: .userInitiated) {
            let result = Result {
                try repo.blockHistory(
                    path: path,
                    startLine: start,
                    endLine: end,
                    limit: limit
                )
            }
            await MainActor.run {
                self.loading = false
                switch result {
                case .success(let entries):
                    self.entries = entries
                case .failure(let failure):
                    // Git 的拒绝原因（未跟踪路径、二进制文件、越界行号）原样展示，
                    // 不伪装成「没有历史」。
                    self.error = formatError(failure)
                }
            }
        }
    }
}

struct BlockHistoryView: View {
    @ObservedObject var request: BlockHistoryRequest
    let onClose: () -> Void

    @State private var selection: String?

    private var selectedEntry: BlockHistoryEntry? {
        guard let selection else { return request.entries.first }
        return request.entries.first { $0.commit.id == selection } ?? request.entries.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 820, minHeight: 480)
        .background(Design.Colors.canvas)
        .onAppear {
            if request.entries.isEmpty, request.error == nil {
                request.load()
            }
            if selection == nil {
                selection = request.entries.first?.commit.id
            }
        }
        .onChange(of: request.entries.map(\.commit.id)) { _, ids in
            if selection == nil { selection = ids.first }
        }
    }

    private var header: some View {
        HStack(spacing: Design.Spacing.sm) {
            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .foregroundStyle(Design.Colors.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("History for Selection")
                    .font(.headline)
                Text("\(request.path) · \(request.lineRangeLabel)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if request.loading {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Close", action: onClose)
        }
        .padding(.horizontal, Design.Spacing.md)
        .padding(.vertical, Design.Spacing.sm)
    }

    @ViewBuilder
    private var content: some View {
        if let error = request.error {
            VStack(spacing: Design.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Design.Colors.error)
                Text("Selection history unavailable")
                    .font(.headline)
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Design.Spacing.lg)
        } else if request.loading, request.entries.isEmpty {
            ProgressView("Loading selection history…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if request.entries.isEmpty {
            VStack(spacing: Design.Spacing.sm) {
                Image(systemName: "clock.badge.questionmark")
                    .foregroundStyle(.secondary)
                Text("No commits touched this selection")
                    .font(.headline)
                Text("Only tracked lines with committed history appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                revisionList
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
                blockPane
                    .frame(minWidth: 380, maxWidth: .infinity)
            }
        }
    }

    private var revisionList: some View {
        List(selection: $selection) {
            ForEach(request.entries, id: \.commit.id) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.commit.summary.isEmpty ? entry.commit.shortId : entry.commit.summary)
                        .font(.callout)
                        .lineLimit(2)
                    HStack(spacing: Design.Spacing.xs) {
                        Text(entry.commit.shortId)
                            .font(.system(.caption, design: .monospaced))
                        Text(entry.commit.authorName)
                            .font(.caption)
                        Text(dateStr(entry.commit.time))
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .padding(.vertical, 2)
                .tag(entry.commit.id)
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private var blockPane: some View {
        if let entry = selectedEntry {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Design.Spacing.sm) {
                    Text(entry.commit.shortId)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("Selection at this revision")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, Design.Spacing.md)
                .padding(.vertical, Design.Spacing.xs)
                Divider()
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(entry.lines.enumerated()), id: \.offset) { offset, line in
                            HStack(alignment: .top, spacing: 0) {
                                Text(String(Int(entry.startLine) + offset))
                                    .font(Design.Typography.codeSmall)
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 52, alignment: .trailing)
                                    .padding(.trailing, Design.Spacing.md)
                                Text(line.isEmpty ? " " : line)
                                    .font(Design.Typography.code)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 1)
                        }
                    }
                    .padding(.vertical, Design.Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        } else {
            Color.clear
        }
    }
}
