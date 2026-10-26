import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RebasedMultiRootTagDeleteRecoveryView: View {
    let tagName: String
    let contexts: [TagDeleteRecoveryContext]
    let onRestore: () -> Void
    let onDeleteRemote: () -> Void
    let onDone: () -> Void

    private var hasRemotes: Bool {
        contexts.contains { !$0.remotes.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(.orange)
                Text("Tags deleted")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            Text(
                String(localized: "The tag %@ was deleted from the selected repositories.")
                    .replacingOccurrences(of: "%@", with: tagName)
            )
                .foregroundStyle(.secondary)
            List(contexts, id: \.id) { context in
                HStack(spacing: 8) {
                    Image(systemName: "tag")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(context.rootPath ?? String(localized: "Repository"))
                            .lineLimit(1)
                        Text(context.tag.id)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(context.tag.kind == .annotated ? "Annotated" : "Lightweight")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
            HStack {
                Text(
                    String(localized: "%@ repositories available to restore")
                        .replacingOccurrences(of: "%@", with: String(contexts.count))
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", role: .cancel, action: onDone)
                if hasRemotes {
                    Button("Delete on Remote", role: .destructive, action: onDeleteRemote)
                }
                Button("Restore All", action: onRestore)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 420)
    }
}
/// Recovery surface shown after deleting a local tag. The saved peeled tip
/// mirrors IntelliJ's notification restore action and is independent of the
/// repository reflog.
struct TagDeleteRecoveryView: View {
    let tag: TagInfo
    let rootPath: String?
    let remotes: [RemoteInfo]
    let onRestore: () -> Void
    let onDeleteRemote: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(.orange)
                Text("Tag deleted")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            Text("The tag reference was removed, but its saved target is still available to restore.")
                .foregroundStyle(.secondary)
            LabeledContent("Tag", value: tag.name)
            LabeledContent("Target", value: tag.id)
                .font(.system(.caption, design: .monospaced))
            LabeledContent(
                "Kind",
                value: tagKindLabel
            )
            Text("Restore will recreate a lightweight tag at this target.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let rootPath {
                LabeledContent("Repository", value: rootPath)
                    .lineLimit(1)
            }
            if !tag.message.isEmpty {
                Divider()
                Text("Original message")
                    .font(.headline)
                Text(tag.message)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done", role: .cancel, action: onDone)
                if !remotes.isEmpty {
                    Button("Delete on Remote", role: .destructive, action: onDeleteRemote)
                }
                Button("Restore Tag", action: onRestore)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 320)
    }

    private var tagKindLabel: String {
        switch tag.kind {
        case .lightweight: "Lightweight"
        case .annotated: "Annotated"
        case .signed: "Signed"
        }
    }
}
struct RebasedMultiRootDeleteTagDialog: View {
    let tagName: String
    @Binding var selectedRootPaths: Set<String>
    let snapshots: [GitRootBranchSnapshot]
    let onDelete: () -> Void
    let onCancel: () -> Void

    private var tagSnapshots: [GitRootBranchSnapshot] {
        snapshots
            .filter { snapshot in
                snapshot.tags.contains { $0.name == tagName }
            }
            .sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
    }

    private var allSelected: Bool {
        !tagSnapshots.isEmpty
            && tagSnapshots.allSatisfy { selectedRootPaths.contains($0.rootPath) }
    }

    private func selectionBinding(for path: String) -> Binding<Bool> {
        Binding(
            get: { selectedRootPaths.contains(path) },
            set: { isSelected in
                if isSelected {
                    selectedRootPaths.insert(path)
                } else {
                    selectedRootPaths.remove(path)
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete Tag")
                .font(.title3.weight(.semibold))
            Text(
                String(localized: "Delete %@ from Git roots")
                    .replacingOccurrences(of: "%@", with: tagName)
            )
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("This removes the local tag in every selected root; its exact target remains available to restore.")
                .font(.caption)
                .foregroundStyle(.orange)
            Divider()
            Toggle(
                "All repositories",
                isOn: Binding(
                    get: { allSelected },
                    set: { isSelected in
                        selectedRootPaths = isSelected ? Set(tagSnapshots.map(\.rootPath)) : []
                    }
                )
            )
            .toggleStyle(.checkbox)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tagSnapshots, id: \.rootPath) { snapshot in
                        Toggle(isOn: selectionBinding(for: snapshot.rootPath)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(snapshot.displayName)
                                Text(snapshot.relativePath)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(maxHeight: 180)
            if tagSnapshots.isEmpty {
                Text("No repository contains this tag.")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if selectedRootPaths.isEmpty {
                Text("Select at least one repository")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text("\(selectedRootPaths.count) repositories selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Delete", role: .destructive, action: onDelete)
                    .keyboardShortcut(.defaultAction)
                    .disabled(tagSnapshots.isEmpty || selectedRootPaths.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
struct RebasedTagDialog: View {
    @Binding var name: String
    @Binding var revision: String
    @Binding var message: String
    @Binding var signKey: String
    @Binding var annotated: Bool
    @Binding var force: Bool
    let onCreate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Tag").font(.title3.weight(.semibold))
            TextField("Tag name", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("Revision (empty = HEAD)", text: $revision)
                .textFieldStyle(.roundedBorder)
            Toggle("Replace existing tag", isOn: $force)
                .toggleStyle(.checkbox)
            if force {
                Label(
                    "If this tag already exists, its target will be replaced.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            Toggle("Annotated tag", isOn: $annotated)
                .toggleStyle(.checkbox)
            if annotated {
                TextField("Tag message", text: $message)
                    .textFieldStyle(.roundedBorder)
                TextField("GPG key (optional)", text: $signKey)
                    .textFieldStyle(.roundedBorder)
                Text("A non-empty GPG key creates a signed tag via git tag -s.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Create", action: onCreate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
