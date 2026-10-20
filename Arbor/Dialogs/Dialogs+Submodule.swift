import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Phase 5：Submodule 面板——列表 + add/update(+init/recursive/remote)/嵌套 Log/deinit/remove/分支配置。
struct SubmodulePanel: View {
    let submodules: [SubmoduleInfo]
    let feedback: String?
    let onAdd: () -> Void
    let onUpdate: () -> Void
    let onSync: () -> Void
    let onUpdatePath: (String) -> Void
    let onUpdateOptions: (Bool, Bool, Bool) -> Void
    let onDeinit: (String, Bool) -> Void
    let onRemove: (String) -> Void
    let onSetBranch: (String, String) -> Void
    let onLog: (String) -> Void
    let onPush: (String) -> Void
    let onConfigureRemotes: (String) -> Void
    let onRefresh: () -> Void

    @State private var initFlag = true
    @State private var recursiveFlag = false
    @State private var remoteFlag = false
    @State private var branchInput = ""

    private func stateText(_ state: SubmoduleState) -> String {
        switch state {
        case .clean: return "clean"
        case .modified: return "modified"
        case .uninitialized: return "uninitialized"
        case .conflict: return "conflict"
        case .missing: return "missing"
        case .unknown: return "unknown"
        }
    }

    private func canPush(_ state: SubmoduleState) -> Bool {
        switch state {
        case .uninitialized, .missing:
            return false
        case .clean, .modified, .conflict, .unknown:
            return true
        }
    }

    private func canUpdate(_ state: SubmoduleState) -> Bool {
        switch state {
        case .clean, .modified:
            return true
        case .uninitialized, .conflict, .missing, .unknown:
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Submodules").font(.headline)
                Spacer()
                Toggle("init", isOn: $initFlag).toggleStyle(.checkbox).font(.caption)
                Toggle("recursive", isOn: $recursiveFlag).toggleStyle(.checkbox).font(.caption)
                Toggle("--remote", isOn: $remoteFlag).toggleStyle(.checkbox).font(.caption)
                Button("Update") { onUpdateOptions(initFlag, recursiveFlag, remoteFlag) }
                    .controlSize(.small)
                Button("Sync") { onSync() }
                    .controlSize(.small)
                    .help("Synchronize submodule URLs from .gitmodules")
                Button("Add…") { onAdd() }
                    .controlSize(.small)
                Button("Refresh") { onRefresh() }
                    .controlSize(.small)
            }
            if let feedback, !feedback.isEmpty {
                Text(feedback).font(.caption).foregroundStyle(.secondary)
            }
            if submodules.isEmpty {
                ContentUnavailableView {
                    Label("No Submodules", systemImage: "square.stack.3d.up")
                }
            } else {
                List(submodules, id: \.path) { module in
                    HStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(module.path).font(.system(size: 13, weight: .medium))
                            HStack(spacing: 6) {
                                Text(stateText(module.state))
                                    .font(.caption)
                                    .foregroundStyle(module.dirty ? .orange : .secondary)
                                if module.dirty {
                                    Text("dirty")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                                if let branch = module.branch {
                                    Text(branch)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        Spacer()
                        TextField("branch", text: $branchInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                            .font(.caption)
                        Button("Set Branch") { onSetBranch(module.path, branchInput) }
                            .controlSize(.small)
                            .disabled(branchInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Update") { onUpdatePath(module.path) }
                            .controlSize(.small)
                            .disabled(!canUpdate(module.state))
                            .help("Update this initialized submodule from its parent; local changes are preserved.")
                        Button("Log") { onLog(module.path) }
                            .controlSize(.small)
                        Button("Push") { onPush(module.path) }
                            .controlSize(.small)
                            .disabled(!canPush(module.state))
                        Button("Remotes…") { onConfigureRemotes(module.path) }
                            .controlSize(.small)
                        Button("Deinit") { onDeinit(module.path, true) }
                            .controlSize(.small)
                        Button("Remove", role: .destructive) { onRemove(module.path) }
                            .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
        .padding(12)
    }
}
/// 子模块自己的提交日志；数据来自嵌套仓库，而不是父仓库的 gitlink 记录。
struct SubmoduleLogView: View {
    let path: String
    let commits: [CommitInfo]
    let error: String?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Submodule Log")
                        .font(.title2.weight(.semibold))
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Close", action: onClose)
            }

            if let error, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if commits.isEmpty {
                ContentUnavailableView {
                    Label("No commits", systemImage: "clock")
                }
            } else {
                List(commits, id: \.id) { commit in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(commit.summary)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(2)
                            Spacer()
                            Text(commit.shortId)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            Text(commit.authorName.isEmpty ? "—" : commit.authorName)
                            Text(Date(timeIntervalSince1970: TimeInterval(commit.time)), style: .date)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if !commit.messageBody.isEmpty {
                            Text(commit.messageBody)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    .padding(.vertical, 3)
                    .contextMenu {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(commit.id, forType: .string)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 460)
    }
}
