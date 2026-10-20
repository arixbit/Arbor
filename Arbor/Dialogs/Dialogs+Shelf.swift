import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Repository-scoped Shelf storage configuration. The engine keeps Git refs in
/// the repository and only moves the manifest/patch artifacts, so migration is
/// explicit and cannot be mistaken for a normal folder preference.
struct RebasedShelfLocationDialog: View {
    @Binding var location: String
    @Binding var migrateExisting: Bool
    let currentLocation: String
    let onSave: () -> Void
    let onCancel: () -> Void

    private var normalizedLocation: String {
        location.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationError: String? {
        guard !normalizedLocation.isEmpty else { return "Shelf location is required." }
        guard URL(fileURLWithPath: normalizedLocation).isFileURL,
              normalizedLocation.hasPrefix("/") else {
            return "Shelf location must be an absolute path."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shelf Location")
                .font(.title3.weight(.semibold))
            Text("Choose where Shelf manifests and raw patches are stored for this Git repository.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Absolute folder path", text: $location)
                .textFieldStyle(.roundedBorder)
            Text("Current: \(currentLocation)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Toggle("Migrate existing Shelves", isOn: $migrateExisting)
                .toggleStyle(.checkbox)
            if migrateExisting {
                Text("Existing Shelf files will be copied and verified before this repository switches to the new folder. Git Shelf refs stay in the repository.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("New Shelves use the folder above. Existing Shelves remain at their current location until migrated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let validationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationError != nil || normalizedLocation == currentLocation)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
struct RebasedShelfPatchHunk: Identifiable {
    let path: String
    let index: UInt32
    let header: String
    let preview: String

    var id: String { "\(path)#\(index)" }
}
enum RebasedShelfPatchStatus: String, CaseIterable, Identifiable {
    case added = "Added"
    case deleted = "Deleted"
    case modified = "Modified"
    case renamed = "Renamed"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .added: return .green
        case .deleted: return .red
        case .modified: return .orange
        case .renamed: return .blue
        }
    }
}
struct RebasedShelfPatchFile: Identifiable {
    let path: String
    let hunks: [RebasedShelfPatchHunk]
    let isBinary: Bool
    let status: RebasedShelfPatchStatus
    let rawPatch: String

    var id: String { path }
    var isWholeFileOnly: Bool { hunks.isEmpty }
}
/// Match IntelliJ's modified flag for the structured todo and an optional
/// native-todo override owned by the same editor session.
func rebaseTodoHasUnsavedChanges(
    current: [RebaseTodoItem],
    initial: [RebaseTodoItem],
    rawTodo: String? = nil
) -> Bool {
    current != initial || rawTodo != nil
}
