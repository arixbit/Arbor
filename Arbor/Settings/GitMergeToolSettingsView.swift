import SwiftUI
import AppKit
import UniformTypeIdentifiers


/// Repository-scoped mergetool selectors. The actual tool command remains
/// owned by Git (`mergetool.<name>.cmd`); Arbor only edits which configured
/// tool Git should select for conflict resolution.
struct GitMergeToolSettingsView: View {
    let repo: Repository
    let onSaved: () -> Void
    let onCancel: () -> Void

    @State private var mergeTool = ""
    @State private var mergeGUITool = ""
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Git External Merge Tool")
                .font(.title3)
                .bold()
            Text("Choose the tool names Git uses for merge conflicts. Configure each command with Git's mergetool.<name>.cmd settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Merge tool name", text: $mergeTool)
                .textFieldStyle(.roundedBorder)
            TextField("GUI merge tool name (optional)", text: $mergeGUITool)
                .textFieldStyle(.roundedBorder)
            Text("These are repository-local overrides. Empty fields remove the local override and let system or global Git configuration apply.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button(isBusy ? "Saving…" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { load() }
    }

    private func load() {
        guard !isBusy else { return }
        isBusy = true
        Task.detached(priority: .userInitiated) {
            do {
                let settings = try repo.externalMergeToolSettings()
                await MainActor.run {
                    mergeTool = settings.mergeTool
                    mergeGUITool = settings.mergeGuiTool
                    errorMessage = nil
                    isBusy = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Unable to read Git mergetool settings: \(error)"
                    isBusy = false
                }
            }
        }
    }

    private func save() {
        isBusy = true
        errorMessage = nil
        let mergeTool = mergeTool.trimmingCharacters(in: .whitespacesAndNewlines)
        let mergeGUITool = mergeGUITool.trimmingCharacters(in: .whitespacesAndNewlines)
        Task.detached(priority: .userInitiated) {
            do {
                try repo.setExternalMergeToolSettings(
                    mergeTool: mergeTool,
                    mergeGuiTool: mergeGUITool
                )
                await MainActor.run {
                    isBusy = false
                    onSaved()
                }
            } catch {
                await MainActor.run {
                    isBusy = false
                    errorMessage = "Unable to save Git mergetool settings: \(error)"
                }
            }
        }
    }
}
