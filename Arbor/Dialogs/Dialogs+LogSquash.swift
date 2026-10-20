import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// IntelliJ's multi-commit Squash action edits the final combined message
/// before starting the rewrite; it does not open the generic todo editor.
struct LogSquashDialogView: View {
    let commitSummaries: [String]
    @Binding var message: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Squash Commits")
                .font(.title3.weight(.semibold))
            Text("Edit the combined commit message. The selected commits will be replayed as one commit.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(commitSummaries.enumerated()), id: \.offset) { _, summary in
                        Text("• \(summary)")
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 86)
            .padding(8)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            TextEditor(text: $message)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 600, minHeight: 210)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Squash", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 660, minHeight: 430)
    }
}
