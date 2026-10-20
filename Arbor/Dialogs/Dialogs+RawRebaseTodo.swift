import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum NativeRebaseTodoLineKind: Equatable {
    case blank
    case comment
    case commit(command: String, commitID: String, subject: String)
    case control(command: String, arguments: String)
    case invalid
}
struct NativeRebaseTodoPreviewRow: Identifiable, Equatable {
    let lineNumber: Int
    let source: String
    let kind: NativeRebaseTodoLineKind

    var id: Int { lineNumber }
}
/// Parse only enough of Git's native todo syntax to make control rows
/// legible while editing. Git remains the execution authority; this preview
/// deliberately warns about unknown/malformed rows instead of rejecting a
/// command that a newer Git version may understand.
func parseNativeRebaseTodoPreview(_ text: String) -> [NativeRebaseTodoPreviewRow] {
    let commitCommands: Set<String> = [
        "pick", "p", "reword", "r", "edit", "e", "squash", "s", "fixup", "f", "drop", "d"
    ]
    let controlCommands: Set<String> = [
        "label", "reset", "merge", "exec", "break", "update-ref"
    ]

    let normalizedLines = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .components(separatedBy: "\n")

    return normalizedLines.enumerated().map { offset, source in
        let lineNumber = offset + 1
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return NativeRebaseTodoPreviewRow(lineNumber: lineNumber, source: source, kind: .blank)
        }
        if trimmed.hasPrefix("#") {
            return NativeRebaseTodoPreviewRow(lineNumber: lineNumber, source: source, kind: .comment)
        }

        let tokens = trimmed.split { character in
            character == " " || character == "\t"
        }
        guard let commandToken = tokens.first else {
            return NativeRebaseTodoPreviewRow(lineNumber: lineNumber, source: source, kind: .blank)
        }
        let command = String(commandToken).lowercased()
        if commitCommands.contains(command), tokens.count >= 2 {
            let subject = tokens.dropFirst(2).map(String.init).joined(separator: " ")
            return NativeRebaseTodoPreviewRow(
                lineNumber: lineNumber,
                source: source,
                kind: .commit(
                    command: command,
                    commitID: String(tokens[tokens.index(tokens.startIndex, offsetBy: 1)]),
                    subject: subject
                )
            )
        }
        if controlCommands.contains(command) {
            return NativeRebaseTodoPreviewRow(
                lineNumber: lineNumber,
                source: source,
                kind: .control(
                    command: command,
                    arguments: tokens.dropFirst().map(String.init).joined(separator: " ")
                )
            )
        }
        return NativeRebaseTodoPreviewRow(lineNumber: lineNumber, source: source, kind: .invalid)
    }
}
/// Update only the argument payload of one native control row. Keeping this
/// transformation line-scoped preserves comments, commit rows, unknown Git
/// syntax, and the original newline convention; Git still validates the
/// resulting todo before execution.
func updateNativeRebaseTodoControlLine(
    _ text: String,
    lineNumber: Int,
    command: String,
    arguments: String
) -> String {
    guard lineNumber > 0 else { return text }
    let newline = text.contains("\r\n") ? "\r\n" : "\n"
    var lines = text.components(separatedBy: newline)
    let index = lineNumber - 1
    guard lines.indices.contains(index) else { return text }

    let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedCommand.isEmpty else { return text }
    let indentation = lines[index].prefix { character in
        character == " " || character == "\t"
    }
    let trimmedArguments = trimmedCommand.lowercased() == "break"
        ? ""
        : arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    lines[index] = String(indentation) + trimmedCommand
        + (trimmedArguments.isEmpty ? "" : " \(trimmedArguments)")
    return lines.joined(separator: newline)
}
let nativeRebaseTodoControlCommands = [
    "label", "reset", "merge", "exec", "break", "update-ref"
]
/// Move one native control row without interpreting the surrounding todo.
/// Raw text remains the source of truth, so comments, unknown commands, and
/// Git-version-specific syntax travel with the line exactly as entered.
func moveNativeRebaseTodoControlLine(
    _ text: String,
    lineNumber: Int,
    by delta: Int
) -> String {
    guard lineNumber > 0, delta != 0 else { return text }
    let newline = text.contains("\r\n") ? "\r\n" : "\n"
    var lines = text.components(separatedBy: newline)
    let sourceIndex = lineNumber - 1
    let destinationIndex = sourceIndex + delta
    guard lines.indices.contains(sourceIndex),
          lines.indices.contains(destinationIndex),
          let sourceRow = parseNativeRebaseTodoPreview(text)
              .first(where: { $0.lineNumber == lineNumber }),
          case .control = sourceRow.kind else {
        return text
    }
    lines.swapAt(sourceIndex, destinationIndex)
    return lines.joined(separator: newline)
}
func nativeRebaseTodoControlCommand(_ text: String, lineNumber: Int) -> String? {
    guard let row = parseNativeRebaseTodoPreview(text)
        .first(where: { $0.lineNumber == lineNumber }),
        case let .control(command, _) = row.kind else { return nil }
    return command
}
func nativeRebaseTodoControlArguments(_ text: String, lineNumber: Int) -> String? {
    guard let row = parseNativeRebaseTodoPreview(text)
        .first(where: { $0.lineNumber == lineNumber }),
        case let .control(_, arguments) = row.kind else { return nil }
    return arguments
}
private struct NativeRebaseTodoPreviewView: View {
    @Binding var text: String

    private var rows: [NativeRebaseTodoPreviewRow] {
        parseNativeRebaseTodoPreview(text)
    }

    private var invalidCount: Int {
        rows.filter { $0.kind == .invalid }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Structured Preview", systemImage: "list.bullet.rectangle")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text("Git remains authoritative")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if invalidCount > 0 {
                Label(
                    String(invalidCount) + " line(s) are not recognized by this preview; Git will validate them on start.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            List(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(String(row.lineNumber))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .frame(width: 32, alignment: .trailing)
                    previewRow(row)
                }
                .listRowSeparator(.visible)
            }
            .listStyle(.inset)
        }
        .padding(.leading, 8)
    }

    @ViewBuilder
    private func previewRow(_ row: NativeRebaseTodoPreviewRow) -> some View {
        switch row.kind {
        case .blank:
            Text("blank")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .comment:
            Text(row.source.trimmingCharacters(in: .whitespaces))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case let .commit(command, commitID, subject):
            Text(command)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 64, alignment: .leading)
            Text(String(commitID.prefix(10)))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(subject.isEmpty ? "(commit message)" : subject)
                .lineLimit(1)
        case let .control(command, arguments):
            Picker(
                "control command",
                selection: Binding(
                    get: {
                        nativeRebaseTodoControlCommand(text, lineNumber: row.lineNumber)
                            ?? command
                    },
                    set: { newCommand in
                        let newArguments = newCommand == "break" ? "" : arguments
                        text = updateNativeRebaseTodoControlLine(
                            text,
                            lineNumber: row.lineNumber,
                            command: newCommand,
                            arguments: newArguments
                        )
                    }
                )
            ) {
                ForEach(nativeRebaseTodoControlCommands, id: \.self) { controlCommand in
                    Text(controlCommand).tag(controlCommand)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(.caption.monospaced().weight(.semibold))
            .frame(width: 120, alignment: .leading)

            if command == "break" {
                Text("(stop here)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                TextField(
                    "arguments",
                    text: Binding(
                        get: {
                            nativeRebaseTodoControlArguments(text, lineNumber: row.lineNumber)
                                ?? arguments
                        },
                        set: { newValue in
                            text = updateNativeRebaseTodoControlLine(
                                text,
                                lineNumber: row.lineNumber,
                                command: nativeRebaseTodoControlCommand(
                                    text,
                                    lineNumber: row.lineNumber
                                ) ?? command,
                                arguments: newValue
                            )
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity)
            }
            Button {
                text = moveNativeRebaseTodoControlLine(
                    text,
                    lineNumber: row.lineNumber,
                    by: -1
                )
            } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.plain)
            .disabled(row.lineNumber == 1)
            .help("Move control row up")
            Button {
                text = moveNativeRebaseTodoControlLine(
                    text,
                    lineNumber: row.lineNumber,
                    by: 1
                )
            } label: {
                Image(systemName: "arrow.down")
            }
            .buttonStyle(.plain)
            .disabled(row.lineNumber == rows.count)
            .help("Move control row down")
        case .invalid:
            Label(row.source, systemImage: "questionmark.square")
                .font(.caption.monospaced())
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }
}
/// Text fallback for Git's native interactive-rebase todo. The editor keeps
/// comments and control rows intact, while the adjacent preview makes
/// `label/reset/merge/exec/break/update-ref` understandable without taking
/// ownership of Git's evolving native syntax.
struct RawRebaseTodoEditorView: View {
    let onto: String
    @Binding var text: String
    let preserveMerges: Bool
    let root: Bool
    let onStart: () -> Void
    let onCancel: () -> Void
    private let initialText: String
    @State private var showDiscardChangesAlert = false

    init(
        onto: String,
        text: Binding<String>,
        preserveMerges: Bool,
        root: Bool,
        onStart: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onto = onto
        self._text = text
        self.preserveMerges = preserveMerges
        self.root = root
        self.onStart = onStart
        self.onCancel = onCancel
        self.initialText = text.wrappedValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Native Git Rebase Todo")
                        .font(.title3.weight(.semibold))
                    Text(root ? "repository root" : "onto \(shortId(onto))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label("Git syntax", systemImage: "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("This is Git's complete todo file. Keep commit IDs and control rows valid; commands such as exec run with the repository's normal Git permissions.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if preserveMerges {
                Label("Merge-preserving topology is controlled by the native label/reset/merge rows.", systemImage: "arrow.triangle.merge")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HSplitView {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(minWidth: 680, minHeight: 520)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25))
                    }

                NativeRebaseTodoPreviewView(text: $text)
                    .frame(minWidth: 390, idealWidth: 460, maxWidth: .infinity)
            }
            HStack {
                Button("Cancel", role: .cancel, action: requestCancel)
                Spacer()
                Button("Start Rebase", action: onStart)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 1180, minHeight: 680)
        .alert("Discard Native Todo Changes?", isPresented: $showDiscardChangesAlert) {
            Button("Keep Editing", role: .cancel) {}
            Button("Discard Changes", role: .destructive, action: onCancel)
        } message: {
            Text("The native Git rebase todo has unsaved changes.")
        }
    }

    private func shortId(_ id: String) -> String {
        String(id.prefix(7))
    }

    private func requestCancel() {
        if text == initialText {
            onCancel()
        } else {
            showDiscardChangesAlert = true
        }
    }
}
/// SwiftUI counterpart of Git's unstructured commit-message editor request
/// during a native raw-todo rebase.
struct RawRebaseMessageEditorView: View {
    @Binding var message: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Commit Message")
                .font(.title3.weight(.semibold))
            Text("Git is waiting for the message for a reword or squash step.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $message)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 620, minHeight: 300)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25))
                }
            HStack {
                Button("Cancel Message Edit", role: .cancel, action: onCancel)
                Spacer()
                Button("Save Message", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 700, minHeight: 420)
    }
}
