import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// SwiftUI equivalent of IntelliJ's GitUpdateOptionsDialog. The method
/// picker is the GitUpdateConfigurable panel; Reset is a dialog-side action
/// and is deliberately not persisted as an update method.
struct UpdateProjectOptionsDialogView: View {
    let projectPath: String
    let rootCount: Int
    let showsResetAction: Bool
    let onUpdate: (GitUpdateMethodChoice, Bool) -> Void
    let onResetToRemote: () -> Void
    let onCancel: () -> Void

    @State private var selectedUpdateMethod: GitUpdateMethodChoice
    @State private var doNotShowAgain: Bool

    init(
        projectPath: String,
        rootCount: Int,
        initialUpdateMethod: GitUpdateMethodChoice,
        showsResetAction: Bool,
        onUpdate: @escaping (GitUpdateMethodChoice, Bool) -> Void,
        onResetToRemote: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.projectPath = projectPath
        self.rootCount = rootCount
        self.showsResetAction = showsResetAction
        self.onUpdate = onUpdate
        self.onResetToRemote = onResetToRemote
        self.onCancel = onCancel
        _selectedUpdateMethod = State(initialValue: initialUpdateMethod)
        _doNotShowAgain = State(
            initialValue: !GitUpdateOptionsDialogSettings.shouldShow(for: projectPath)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Update Project")
                .font(.title2.weight(.semibold))
            Text(projectPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 8) {
                Text(rootCount == 1 ? "Git root" : "Git roots")
                    .font(.headline)
                Text(rootCount == 1
                     ? "Update the current Git root."
                     : "Update all discovered Git roots in project order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Update method", selection: $selectedUpdateMethod) {
                ForEach(GitUpdateMethodChoice.allCases) { method in
                    Text(method.title).tag(method)
                }
            }
            .pickerStyle(.radioGroup)
            Text(selectedUpdateMethod.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Do not show this dialog again", isOn: $doNotShowAgain)
                .help("Skip the Update Project options dialog for this project after confirmation.")

            if showsResetAction {
                Divider()
                Button("Reset to Remote Branch…", action: onResetToRemote)
                    .foregroundStyle(.red)
                    .help("Fetch the tracked upstream and reset the current branch to it.")
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Update Project") {
                    onUpdate(selectedUpdateMethod, !doNotShowAgain)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 500)
    }
}
/// Rebased/IntelliJ Git Reset 面板：目标提交固定展示，模式用单选互斥，
/// Hard/Keep 的破坏性边界在确认前明确说明。
struct RebasedResetDialog: View {
    let commit: CommitInfo
    var targetCommits: [CommitInfo] = []
    @Binding var mode: ResetMode
    let onReset: () -> Void
    let onCancel: () -> Void
    var multiRootResetAvailable = false
    var onResetAcrossRoots: (ResetMode) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(targetCommits.count > 1 ? "Reset Selected Git Roots" : "Reset Current Branch")
                .font(.title3.weight(.semibold))
            if targetCommits.count > 1 {
                Text("One selected revision will be used for each Git root.")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(targetCommits, id: \.id) { target in
                        HStack(spacing: 8) {
                            Text(URL(fileURLWithPath: target.repositoryPath ?? "").lastPathComponent)
                                .font(.headline)
                                .lineLimit(1)
                            Text("HEAD → \(target.shortId)")
                                .font(.system(.body, design: .monospaced))
                            Spacer(minLength: 4)
                        }
                        Text(target.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text("HEAD → \(commit.shortId)")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                    Text(commit.summary)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Divider()
            Picker("Reset mode", selection: $mode) {
                Text("Soft — keep index and working tree").tag(ResetMode.soft)
                Text("Mixed — reset index, keep working tree").tag(ResetMode.mixed)
                Text("Hard — reset index and working tree").tag(ResetMode.hard)
                Text("Keep — keep non-overlapping local changes").tag(ResetMode.keep)
            }
            .pickerStyle(.radioGroup)
            Text(description)
                .font(.caption)
                .foregroundStyle(mode == .hard ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if multiRootResetAvailable {
                    Button(targetCommits.count > 1 ? "Reset selected Git roots…" : "Reset in all Git roots…") {
                        onResetAcrossRoots(mode)
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Reset", role: mode == .hard ? .destructive : nil, action: onReset)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var description: String {
        switch mode {
        case .soft:
            return "Only the current branch pointer moves. Staged and unstaged changes stay exactly where they are."
        case .mixed:
            return "The index is reset to the target commit. Working-tree files are not rewritten."
        case .hard:
            return "Uncommitted staged and unstaged changes may be discarded. This cannot be undone from the working tree."
        case .keep:
            return "Git refuses overlapping local changes and keeps edits on paths unaffected by the reset."
        }
    }
}
/// IntelliJ GitResetHead equivalent: choose a Git root, enter any revision
/// expression, validate it, then select the reset mode before execution.
struct RebasedHeadResetDialog: View {
    let roots: [GitRootInfo]
    @Binding var selectedRootPath: String
    @Binding var target: String
    @Binding var mode: ResetMode
    let onValidate: (String, String) -> RebasedResetTargetValidation
    let onReset: () -> Void
    let onCancel: () -> Void

    @State private var validation: RebasedResetTargetValidation?

    private var selectedRoot: GitRootInfo? {
        roots.first {
            canonicalExternalLogPath($0.path) == canonicalExternalLogPath(selectedRootPath)
        }
    }

    private var targetIsUsable: Bool {
        !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Reset Head")
                .font(.title3.weight(.semibold))
            if roots.count > 1 {
                Picker("Git root", selection: $selectedRootPath) {
                    ForEach(roots, id: \.path) { root in
                        Text("\(root.displayName) · \(root.relativePath)")
                            .tag(root.path)
                    }
                }
                .onChange(of: selectedRootPath) { _, _ in
                    validation = nil
                }
            }
            HStack {
                Text("Current branch")
                Spacer()
                Text(selectedRoot?.headBranch ?? "Detached HEAD")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                TextField("Revision", text: $target)
                    .textFieldStyle(.roundedBorder)
                Button("Validate") {
                    validation = onValidate(target, selectedRootPath)
                }
                .disabled(!targetIsUsable)
            }
            Text("Enter HEAD, a branch or tag name, a commit hash, or another Git revision expression.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let validation {
                Label(
                    validation.message,
                    systemImage: validation.isValid
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(validation.isValid ? .green : .red)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Picker("Reset mode", selection: $mode) {
                Text("Soft — keep index and working tree").tag(ResetMode.soft)
                Text("Mixed — reset index, keep working tree").tag(ResetMode.mixed)
                Text("Hard — reset index and working tree").tag(ResetMode.hard)
            }
            .pickerStyle(.radioGroup)
            Text(description)
                .font(.caption)
                .foregroundStyle(mode == .hard ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Reset", role: mode == .hard ? .destructive : nil, action: onReset)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!targetIsUsable)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onChange(of: target) { _, _ in
            validation = nil
        }
    }

    private var description: String {
        switch mode {
        case .soft:
            return "Only the current branch pointer moves. Staged and unstaged changes stay exactly where they are."
        case .mixed:
            return "The index is reset to the target commit. Working-tree files are not rewritten."
        case .hard:
            return "Uncommitted staged and unstaged changes may be discarded. This cannot be undone from the working tree."
        case .keep:
            return "Git refuses overlapping local changes and keeps edits on paths unaffected by the reset."
        }
    }
}
/// Full-message dialog for the Log HEAD Reword fast path.
/// It intentionally does not expose staged-file controls: the engine uses
/// `git commit --amend --only` and leaves the current index untouched.
struct LogRewordDialogView: View {
    let commit: CommitInfo
    @Binding var message: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reword Commit")
                .font(.title3.weight(.semibold))
            Text("HEAD \(commit.shortId) · Edit the complete commit message. Staged changes are not included.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $message)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 560, minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Reword", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 320)
    }
}
