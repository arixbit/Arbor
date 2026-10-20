import SwiftUI
import AppKit
import UniformTypeIdentifiers


struct WorktreePanel: View {
    let worktrees: [WorktreeInfo]
    let feedback: String?
    let onRefresh: () -> Void
    let onCreate: (String, String, String) -> Void
    let onOpen: (String) -> Void
    let onRemove: (String, Bool) -> Void
    let onLock: (String) -> Void
    let onUnlock: (String) -> Void
    let onPrune: () -> Void
    @State var path = ""
    @State var branch = ""
    @State var revision = ""

    var occupiedBranches: Set<String> {
        Set(worktrees.map(\.branch).filter { !$0.isEmpty })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.split.2x1")
                    .foregroundStyle(Design.Colors.accent)
                Text("Worktrees")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(worktrees.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Prune", action: onPrune)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("新 worktree 路径", text: $path)
                        .textFieldStyle(.roundedBorder)
                    TextField("新分支（可选）", text: $branch)
                        .textFieldStyle(.roundedBorder)
                    TextField("revision（可选）", text: $revision)
                        .textFieldStyle(.roundedBorder)
                    Button("创建") {
                        onCreate(path, branch, revision)
                        path = ""
                        branch = ""
                        revision = ""
                    }
                    .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || occupiedBranches.contains(branch))
                }
                if occupiedBranches.contains(branch), !branch.isEmpty {
                    Text("分支 (branch) 已被其他 worktree 占用；请换一个分支或只填写 revision。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let feedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(feedback.hasPrefix("已") ? .green : .red)
                }
            }
            .padding(14)
            Divider()
            if worktrees.isEmpty {
                ContentUnavailableView("暂无 worktree", systemImage: "square.split.2x1")
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(worktrees.enumerated()), id: \.element.path) { index, item in
                            worktreeRow(item, isMain: index == 0)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .background(Design.Colors.canvas)
    }

    func worktreeRow(_ item: WorktreeInfo, isMain: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: isMain ? "house" : "square.split.2x1")
                    .foregroundStyle(isMain ? .blue : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.path)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 8) {
                        Text(item.branch.isEmpty ? "detached" : item.branch)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(item.headId.prefix(8))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if item.prunable { Text("prunable").foregroundStyle(.orange) }
                        if item.locked { Text("locked").foregroundStyle(.orange) }
                    }
                }
                Spacer()
                Button("打开") { onOpen(item.path) }
                    .buttonStyle(.borderless)
                if item.locked {
                    Button("解锁") { onUnlock(item.path) }
                        .buttonStyle(.borderless)
                } else {
                    Button("锁定") { onLock(item.path) }
                        .buttonStyle(.borderless)
                }
                Button("删除") { onRemove(item.path, false) }
                    .buttonStyle(.borderless)
                    .disabled(isMain)
                if !isMain {
                    Button("强制") { onRemove(item.path, true) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
    }
}
