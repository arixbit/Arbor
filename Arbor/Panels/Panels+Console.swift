import SwiftUI
import AppKit
import UniformTypeIdentifiers


struct GitConsoleView: View {
    let result: GitCommandResult?
    let onRun: (String, [String]) -> Void
    let onClear: () -> Void
    @State var commandLine = "status --short"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .foregroundStyle(Design.Colors.accent)
                Text("Git Console")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Clear", action: onClear)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            HStack(spacing: 8) {
                Text("git")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField("command and arguments", text: $commandLine)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(run)
                Button("Run", action: run)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Text("Commands run as argument vectors, never through a shell; quote complex arguments.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
            Divider()
            if let result {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: result.exitCode == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(result.exitCode == 0 ? .green : .red)
                            Text(result.command)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Text("exit \(result.exitCode) · \(result.durationMs) ms")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !result.stdout.isEmpty {
                            consoleOutput(title: "stdout", value: result.stdout, color: .primary)
                        }
                        if !result.stderr.isEmpty {
                            consoleOutput(title: "stderr", value: result.stderr, color: .red)
                        }
                        if result.stdout.isEmpty && result.stderr.isEmpty {
                            Text("(no output)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView(
                    "No command result",
                    systemImage: "terminal",
                    description: Text("Run a Git subcommand to see it here; full stdout/stderr is kept in the operation history.")
                )
            }
        }
        .background(Design.Colors.canvas)
    }

    func consoleOutput(title: String, value: String, color: Color) -> some View {
        DisclosureGroup(title) {
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(10)
                .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    func run() {
        let tokens = tokenizeGitCommandLine(commandLine)
        guard let command = tokens.first else { return }
        onRun(command, Array(tokens.dropFirst()))
    }

}

func operationRecoveryContinueIsEnabled(for state: OperationState) -> Bool {
    state.kind != .merge || state.conflictedFiles.isEmpty
}

struct OperationRecoveryBar: View {
    let state: OperationState
    let feedback: String?
    let onContinue: () -> Void
    let onSkip: () -> Void
    let onAbort: () -> Void
    let onOpenConflictResolver: () -> Void
    let onOpenConflict: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.medium))
                    HStack(spacing: 6) {
                        if !state.conflictedFiles.isEmpty {
                            Label("\(state.conflictedFiles.count) unresolved", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if state.origin == .engine {
                            Text("Arbor-managed state")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        if state.kind == .rebase, let steps = state.stepsTotal {
                            Text("step \(state.stepsDone ?? 0)/\(steps)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer()
                if state.kind == .rebase {
                    Button("Skip", action: onSkip)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Button("Abort", action: onAbort)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(continueTitle, action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!operationRecoveryContinueIsEnabled(for: state))
            }
            if let context = operationRecoveryContext(for: state) {
                Text(context)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !state.conflictedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Resolve conflicts before continuing")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Resolve Conflicts", action: onOpenConflictResolver)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    ForEach(Array(state.conflictedFiles.prefix(5)), id: \.self) { path in
                        Button {
                            onOpenConflict(path)
                        } label: {
                            Label(path, systemImage: "arrow.up.forward.app")
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.link)
                    }
                    if state.conflictedFiles.count > 5 {
                        Text("and \(state.conflictedFiles.count - 5) more…")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 28)
            }
            if let feedback, !feedback.isEmpty {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.10))
    }

    var icon: String {
        switch state.kind {
        case .merge: return "arrow.triangle.merge"
        case .rebase: return "arrow.triangle.branch"
        case .cherryPick: return "doc.on.clipboard"
        case .revert: return "arrow.uturn.backward"
        }
    }

    var title: String {
        switch state.kind {
        case .merge: return "Merge in progress"
        case .rebase: return "Rebase paused"
        case .cherryPick: return "Cherry-pick in progress"
        case .revert: return "Revert in progress"
        }
    }

    var continueTitle: String {
        switch state.kind {
        case .merge: return "Commit Merge"
        case .rebase: return "Continue Rebase"
        case .cherryPick: return "Continue Cherry-pick"
        case .revert: return "Continue Revert"
        }
    }

}

/// The recovery banner keeps the raw engine state intact, but exposes the
/// rebase context in one deterministic string so the SwiftUI view and tests
/// exercise the same presentation rule.
func operationRecoveryContext(for state: OperationState) -> String? {
    guard state.kind == .rebase else { return nil }
    var details: [String] = []
    if let branch = state.originalBranch, !branch.isEmpty {
        details.append("from \(branch)")
    }
    if let onto = state.onto, !onto.isEmpty {
        details.append("onto \(String(onto.prefix(10)))")
    }
    if state.backend == .apply {
        details.append("apply backend")
    } else if state.backend == .merge {
        details.append(state.interactive ? "interactive merge backend" : "merge backend")
    }
    return details.isEmpty ? nil : details.joined(separator: " · ")
}
