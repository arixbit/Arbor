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
                    TextField("New worktree path", text: $path)
                        .textFieldStyle(.roundedBorder)
                    TextField("New branch (optional)", text: $branch)
                        .textFieldStyle(.roundedBorder)
                    TextField("Revision (optional)", text: $revision)
                        .textFieldStyle(.roundedBorder)
                    Button("Create") {
                        onCreate(path, branch, revision)
                        path = ""
                        branch = ""
                        revision = ""
                    }
                    .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || occupiedBranches.contains(branch))
                }
                if occupiedBranches.contains(branch), !branch.isEmpty {
                    Text("The branch is already used by another worktree; choose another branch or enter only a revision.")
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
                Button("Open") { onOpen(item.path) }
                    .buttonStyle(.borderless)
                if item.locked {
                    Button("Unlock") { onUnlock(item.path) }
                        .buttonStyle(.borderless)
                } else {
                    Button("Lock") { onLock(item.path) }
                        .buttonStyle(.borderless)
                }
                Button("Delete") { onRemove(item.path, false) }
                    .buttonStyle(.borderless)
                    .disabled(isMain)
                if !isMain {
                    Button("Force") { onRemove(item.path, true) }
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
