import SwiftUI
import AppKit
import UniformTypeIdentifiers

func rebaseInputsCanLoadRange(onto: String, branch: String, root: Bool) -> Bool {
    !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && (root || !onto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
}
struct MultiRootRawTodoContext: Identifiable, Sendable {
    let rootPath: String
    let displayName: String
    let onto: String
    let preserveMerges: Bool
    let root: Bool

    var id: String { rootPath }
}
/// The Git contributor's searchable project scope. Keeping the repository
/// path with each ref is essential in a multi-root project: the same branch
/// or tag name may resolve to different commits in different roots.
struct SearchEverywhereGitRoot {
    let rootPath: String
    let displayName: String
    let relativePath: String
    let branches: [BranchInfo]
    let remoteBranches: [RemoteBranchInfo]
    let tags: [TagInfo]
}
enum MultiRootRecoveryAction: Equatable {
    case continueOperation
    case skip
    case abort
}
/// REPO-001：多 Git root 聚合视图——逐 root 状态 + 聚合操作按钮,
/// 显示部分成功、部分失败与跳过。
struct MultiRootPanel: View {
    let roots: [GitRootInfo]
    let results: [RootOperationResult]
    let conflictGroups: [MultiRootConflictGroup]
    let isRunning: Bool
    let canRetryFailedUpdate: Bool
    let canRetryFailedCheckoutUpdate: Bool
    let canRetryFailedPush: Bool
    let onOperation: (MultiRootOperation) -> Void
    let onCommitAll: () -> Void
    let onCheckout: (String, Bool) -> Void
    let onRecovery: (String, MultiRootRecoveryAction) -> Void
    let onRetryFailedUpdate: () -> Void
    let onRetryFailedCheckoutUpdate: () -> Void
    let onRetryFailedPush: () -> Void
    let onResolveOperationConflict: (String, String?) -> Void
    let onAcceptConflicts: ([MultiRootConflictTarget], FilePick) -> Void
    let conflictBatchWorking: Bool
    let conflictBatchError: String?
    let stashConflicts: [String: [String]]
    let onResolveStashConflict: (String) -> Void
    let updateStashRoots: Set<String>
    let onRestoreUpdateStash: (String) -> Void
    let onRefresh: () -> Void
    let onShowChanges: () -> Void
    @State private var checkoutReference = ""
    @State private var checkoutDetached = false
    @State private var selectedConflictIDs: Set<String> = []

    private var conflictTargets: [MultiRootConflictTarget] {
        multiRootConflictTargets(from: conflictGroups)
    }

    private var selectedConflictTargets: [MultiRootConflictTarget] {
        conflictTargets.filter { selectedConflictIDs.contains($0.id) }
    }

    private var hasRetryableFailedUpdate: Bool {
        guard canRetryFailedUpdate else { return false }
        return results.contains { result in
            guard !result.success,
                  !updateStashRoots.contains(result.rootPath) else { return false }
            return roots.first(where: { $0.path == result.rootPath })?.operation == nil
        }
    }

    private var hasRetryableFailedCheckoutUpdate: Bool {
        guard canRetryFailedCheckoutUpdate else { return false }
        return results.contains { result in
            guard !result.success,
                  !updateStashRoots.contains(result.rootPath) else { return false }
            return roots.first(where: { $0.path == result.rootPath })?.operation == nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Git Roots").font(.headline)
                Text("\(roots.count) roots")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Fetch All") { onOperation(.fetch) }
                    .controlSize(.small)
                    .disabled(isRunning)
                Button("Pull All (Merge)") { onOperation(.pullMerge) }
                    .controlSize(.small)
                    .disabled(isRunning)
                Button("Pull All (Rebase)") { onOperation(.pullRebase) }
                    .controlSize(.small)
                    .disabled(isRunning)
                Button("Push All") { onOperation(.push) }
                    .controlSize(.small)
                    .disabled(isRunning)
                if hasRetryableFailedUpdate {
                    Button("Retry Failed Roots") { onRetryFailedUpdate() }
                        .controlSize(.small)
                        .disabled(isRunning)
                }
                if hasRetryableFailedCheckoutUpdate {
                    Button("Retry Failed Checkout Roots") { onRetryFailedCheckoutUpdate() }
                        .controlSize(.small)
                        .disabled(isRunning)
                }
                if canRetryFailedPush {
                    Button("Retry Failed Push Roots") { onRetryFailedPush() }
                        .controlSize(.small)
                        .disabled(isRunning)
                }
                Button("Commit All", action: onCommitAll)
                    .controlSize(.small)
                    .disabled(isRunning)
                Button("View Changes", action: onShowChanges)
                    .controlSize(.small)
                Button("Refresh") { onRefresh() }
                    .controlSize(.small)
            }
            HStack(spacing: 8) {
                TextField("Branch / tag / revision", text: $checkoutReference)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220)
                Toggle("Detached", isOn: $checkoutDetached)
                    .toggleStyle(.checkbox)
                Button("Checkout") {
                    let reference = checkoutReference.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !reference.isEmpty else { return }
                    onCheckout(reference, checkoutDetached)
                }
                .controlSize(.small)
                .disabled(isRunning || checkoutReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !conflictGroups.isEmpty || !stashConflicts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Label("Conflicts", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        if !selectedConflictTargets.isEmpty {
                            Text("\(selectedConflictTargets.count) selected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Accept Ours") {
                                onAcceptConflicts(selectedConflictTargets, .ours)
                            }
                            .controlSize(.small)
                            .disabled(isRunning || conflictBatchWorking)
                            Button("Accept Theirs") {
                                onAcceptConflicts(selectedConflictTargets, .theirs)
                            }
                            .controlSize(.small)
                            .disabled(isRunning || conflictBatchWorking)
                        }
                        if conflictBatchWorking {
                            ProgressView()
                                .controlSize(.small)
                            Text("Resolving…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let conflictBatchError {
                        Text(conflictBatchError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if !conflictTargets.isEmpty {
                        List(selection: $selectedConflictIDs) {
                            ForEach(conflictGroups) { group in
                                Section {
                                    ForEach(group.paths, id: \.self) { path in
                                        let targetID = MultiRootConflictTarget(
                                            rootPath: group.rootPath,
                                            path: path
                                        ).id
                                        HStack(spacing: 6) {
                                            Label(path, systemImage: "exclamationmark.triangle")
                                                .font(.caption)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Spacer(minLength: 4)
                                            Button("Open") {
                                                onResolveOperationConflict(group.rootPath, path)
                                            }
                                            .buttonStyle(.link)
                                            .controlSize(.small)
                                            .disabled(isRunning || conflictBatchWorking)
                                        }
                                        .tag(targetID)
                                    }
                                } header: {
                                    HStack(spacing: 6) {
                                        Text(group.displayName)
                                            .font(.system(size: 13, weight: .medium))
                                        Text(group.relativePath)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if let operation = group.operation {
                                            Text(operationText(operation))
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                }
                            }
                        }
                        .listStyle(.inset)
                        .frame(minHeight: 72, maxHeight: 240)
                    }
                    ForEach(stashConflicts.keys.sorted(), id: \.self) { rootPath in
                        if let paths = stashConflicts[rootPath] {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(URL(fileURLWithPath: rootPath).lastPathComponent)
                                        .font(.system(size: 13, weight: .medium))
                                    Text("stash")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                    Spacer()
                                    Button("Resolve…") {
                                        onResolveStashConflict(rootPath)
                                    }
                                    .controlSize(.small)
                                    .disabled(isRunning)
                                }
                                ForEach(paths, id: \.self) { path in
                                    Text("• \(path)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .padding(.leading, 6)
                        }
                    }
                }
                .padding(8)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                Divider()
            }
            if isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Running per root…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if roots.isEmpty {
                ContentUnavailableView {
                    Label("No Git Roots", systemImage: "externaldrive.badge.questionmark")
                } description: {
                    Text("The current project directory does not contain a Git repository.")
                }
            } else {
                List {
                    ForEach(roots, id: \.path) { root in
                        let result = results.first { $0.rootPath == root.path }
                        HStack(spacing: 8) {
                            Image(systemName: statusIcon(result))
                                .foregroundStyle(statusColor(result))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(root.displayName)
                                    .font(.system(size: 13, weight: .medium))
                                Text(root.relativePath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if root.dirty {
                                Text("dirty")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            if let operation = root.operation {
                                Text(operationText(operation))
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                Button("Resolve…") {
                                    onResolveOperationConflict(root.path, nil)
                                }
                                .controlSize(.small)
                                .disabled(isRunning)
                            }
                            if let conflicts = stashConflicts[root.path] {
                                Text("stash conflict (\(conflicts.count))")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                Button("Resolve…") {
                                    onResolveStashConflict(root.path)
                                }
                                .controlSize(.small)
                                .disabled(isRunning)
                            }
                            if updateStashRoots.contains(root.path), root.operation == nil {
                                Text("Update stash pending")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                Button("Restore…") {
                                    onRestoreUpdateStash(root.path)
                                }
                                .controlSize(.small)
                                .disabled(isRunning)
                            }
                            if let result {
                                Text(result.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            if let operation = root.operation {
                                HStack(spacing: 4) {
                                    Button("Continue") {
                                        onRecovery(root.path, .continueOperation)
                                    }
                                    .controlSize(.small)
                                    if operation == .rebase {
                                        Button("Skip") {
                                            onRecovery(root.path, .skip)
                                        }
                                        .controlSize(.small)
                                    }
                                    Button("Abort", role: .destructive) {
                                        onRecovery(root.path, .abort)
                                    }
                                    .controlSize(.small)
                                }
                                .disabled(isRunning)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
            }
        }
        .onChange(of: conflictTargets.map(\.id)) { _, ids in
            selectedConflictIDs.formIntersection(Set(ids))
        }
        .padding(12)
    }

    private func statusIcon(_ result: RootOperationResult?) -> String {
        guard let result else { return "circle.dotted" }
        if result.skipped { return "arrow.right.square" }
        return result.success ? "checkmark.circle" : "xmark.circle"
    }

    private func statusColor(_ result: RootOperationResult?) -> Color {
        guard let result else { return .secondary }
        if result.skipped { return .secondary }
        return result.success ? .green : .red
    }

    private func operationText(_ kind: OperationKind) -> String {
        switch kind {
        case .merge: return "merge"
        case .rebase: return "rebase"
        case .cherryPick: return "cherry-pick"
        case .revert: return "revert"
        }
    }
}
