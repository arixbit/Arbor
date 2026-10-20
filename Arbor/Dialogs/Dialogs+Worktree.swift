import SwiftUI
import AppKit
import UniformTypeIdentifiers

func linkedWorktreePathForBranch(
    branch: String,
    worktrees: [WorktreeInfo],
    currentRootPath: String
) -> String? {
    let currentPath = currentRootPath.isEmpty
        ? nil
        : URL(fileURLWithPath: currentRootPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    return worktrees.first { worktree in
        guard worktree.branch == branch, !worktree.path.isEmpty else { return false }
        guard let currentPath else { return true }
        return URL(fileURLWithPath: worktree.path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path != currentPath
    }?.path
}
/// IntelliJ's Create New Working Tree action keeps the selected branch or tag
/// as the source ref.  The optional branch field mirrors the dialog's
/// existing-branch versus new-branch choice; a remote branch is intentionally
/// not offered here because the fork hides this action for remote refs.
struct RebasedNewWorktreeDialog: View {
    let rootPath: String?
    let reference: String
    let isTag: Bool
    let occupiedBranches: Set<String>
    let validateBranchName: (String) -> String?
    @Binding var path: String
    @Binding var branch: String
    let onCreate: (String, String) -> Void
    let onCancel: () -> Void

    private var trimmedPath: String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedBranch: String {
        GitBranchNameCleanup.cleanUp(branch)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var branchError: String? {
        guard !trimmedBranch.isEmpty else { return nil }
        if occupiedBranches.contains(trimmedBranch) {
            return "该分支已被其他 worktree 占用。"
        }
        return validateBranchName(trimmedBranch)
    }

    private var sourceRefError: String? {
        guard !isTag,
              trimmedBranch.isEmpty,
              occupiedBranches.contains(reference) else { return nil }
        return "来源分支已被其他 worktree 占用；请填写一个新分支名。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isTag ? "New Working Tree from Tag" : "New Working Tree from Branch")
                .font(.title3.weight(.semibold))
            if let rootPath {
                LabeledContent("Repository", value: rootPath)
                    .lineLimit(1)
            }
            LabeledContent("Source ref", value: reference)
                .font(.system(.body, design: .monospaced))
            TextField("Worktree path", text: $path)
                .textFieldStyle(.roundedBorder)
            TextField("New branch (optional)", text: $branch)
                .textFieldStyle(.roundedBorder)
                .onChange(of: branch) { _, value in
                    let cleaned = GitBranchNameCleanup.cleanUpOnTyping(value)
                    if cleaned != value { branch = cleaned }
                }
            Text("留空将直接检出来源引用；填写后会从来源引用创建新分支。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let branchError {
                Text(branchError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let sourceRefError {
                Text(sourceRefError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Create") {
                    onCreate(trimmedPath, trimmedBranch)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    trimmedPath.isEmpty
                        || branchError != nil
                        || sourceRefError != nil
                )
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
