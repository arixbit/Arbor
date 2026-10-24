import SwiftUI

/// Git hooks 管理面板：左侧是 hook 列表与状态，右侧是脚本编辑器。
///
/// 视图不直接持有 Repository；所有读取/写入通过闭包回到 `ContentView`，
/// 与 LFS 面板共用同一套 busy/feedback 约定。这里刻意不提供「运行这个
/// hook」按钮：hook 是提交/推送时由 Git 触发的，手动执行容易造成误解。
struct HooksPanelView: View {
    let hooks: [GitHookInfo]
    let location: GitHooksLocation?
    let contents: GitHookContents?
    let busy: Bool
    let feedback: String?

    @Binding var selectedName: String?
    @Binding var draft: String

    let onRefresh: () -> Void
    let onSelect: (String?) -> Void
    let onSave: () -> Void
    let onRevert: () -> Void
    let onToggleEnabled: (GitHookInfo) -> Void
    let onInstallSample: (String) -> Void
    let onDelete: (String) -> Void
    let onDismiss: () -> Void

    @State private var pendingDelete: String?

    private var selectedHook: GitHookInfo? {
        guard let selectedName else { return nil }
        return hooks.first { $0.name == selectedName }
    }

    private var isDirty: Bool {
        guard let contents, !contents.truncated, !contents.isBinary else { return false }
        return contents.content != draft
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                hookList
                    .frame(width: 260)
                Divider()
                editorPane
            }
        }
        .frame(minWidth: 860, minHeight: 540)
        .alert("Delete hook?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let name = pendingDelete { onDelete(name) }
                pendingDelete = nil
            }
        } message: {
            Text("删除 \(pendingDelete ?? "") 脚本文件；对应的 .sample 模板会保留。")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Git Hooks").font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            if let feedback, !feedback.isEmpty {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button("Refresh", action: onRefresh).disabled(busy)
            Button("Done", action: onDismiss).keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private var subtitle: String {
        guard let location else { return "读取 hooks 目录…" }
        if let custom = location.customPath, !custom.isEmpty {
            return "core.hooksPath = \(custom) · \(location.directory)"
        }
        return location.directory
    }

    private var hookList: some View {
        List(selection: $selectedName) {
            ForEach(hooks, id: \.name) { hook in
                row(hook)
                    .tag(Optional(hook.name))
            }
        }
        .listStyle(.sidebar)
        .onChange(of: selectedName) { _, name in onSelect(name) }
    }

    private func row(_ hook: GitHookInfo) -> some View {
        HStack(spacing: 6) {
            Image(systemName: stateIcon(hook.state))
                .foregroundStyle(stateColor(hook.state))
            Text(hook.name)
                .font(.callout.monospaced())
                .lineLimit(1)
            Spacer(minLength: 2)
            if hook.hasSample, hook.state != .enabled, hook.state != .disabled {
                Image(systemName: "shippingbox")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("A .sample template is available to install")
            }
        }
        .padding(.vertical, 2)
    }

    private func stateIcon(_ state: GitHookState) -> String {
        switch state {
        case .enabled: "checkmark.circle.fill"
        case .disabled: "pause.circle"
        case .sample: "shippingbox"
        case .missing: "circle.dashed"
        }
    }

    private func stateColor(_ state: GitHookState) -> Color {
        switch state {
        case .enabled: .green
        case .disabled: .orange
        case .sample: .secondary
        case .missing: .secondary.opacity(0.5)
        }
    }

    private func stateText(_ state: GitHookState) -> String {
        switch state {
        case .enabled: "enabled"
        case .disabled: "disabled（无可执行位，Git 会忽略）"
        case .sample: "sample"
        case .missing: "missing"
        }
    }

    @ViewBuilder
    private var editorPane: some View {
        if let hook = selectedHook {
            VStack(spacing: 0) {
                editorToolbar(hook)
                Divider()
                if let contents {
                    if contents.isBinary {
                        centeredMessage(
                            icon: "doc.zipper",
                            text: "二进制 hook 脚本，无法在 Arbor 中编辑"
                        )
                    } else if contents.truncated {
                        centeredMessage(
                            icon: "exclamationmark.triangle",
                            text: "脚本超过 512 KB，已截断显示；为安全起见禁止保存"
                        )
                    } else {
                        TextEditor(text: $draft)
                            .font(.system(size: 12, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .background(Design.Colors.canvas)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                editorFooter(hook)
            }
        } else {
            centeredMessage(icon: "terminal", text: "从左侧选择一个 hook")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func editorToolbar(_ hook: GitHookInfo) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(hook.name).font(.headline.monospaced())
                Text(stateText(hook.state))
                    .font(.caption)
                    .foregroundStyle(stateColor(hook.state))
            }
            Spacer()
            if hook.state == .sample || hook.state == .missing {
                Button("Install sample") { onInstallSample(hook.name) }
                    .disabled(busy || !hook.hasSample)
            }
            if hook.state == .enabled || hook.state == .disabled {
                Button(hook.state == .enabled ? "Disable" : "Enable") {
                    onToggleEnabled(hook)
                }
                .disabled(busy)
                Button("Delete") { pendingDelete = hook.name }
                    .disabled(busy)
            }
        }
        .padding(12)
    }

    private func editorFooter(_ hook: GitHookInfo) -> some View {
        HStack(spacing: 10) {
            if isDirty {
                Label("Unsaved", systemImage: "pencil")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if hook.state == .missing {
                Text("Saving creates the file and sets its executable bit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revert", action: onRevert)
                .disabled(busy || !isDirty)
            Button("Save", action: onSave)
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(busy || !isDirty)
        }
        .padding(12)
    }

    private func centeredMessage(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}
