import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RebasedNewBranchDialog: View {
    let title: String
    @Binding var name: String
    @Binding var baseRevision: String
    @Binding var checkout: Bool
    @Binding var resetExisting: Bool
    let validateName: (String) -> String?
    let branches: [BranchInfo]
    let onCreate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let validationMessage = validateName(name)
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.weight(.semibold))
            TextField("Branch name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onChange(of: name) { _, value in
                    let cleaned = GitBranchNameCleanup.cleanUpOnTyping(value)
                    if cleaned != value { name = cleaned }
                }
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                Text("Create from")
                    .foregroundStyle(.secondary)
                TextField("HEAD", text: $baseRevision)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    Button("HEAD") { baseRevision = "" }
                    ForEach(branches, id: \.name) { branch in
                        Button(branch.name) { baseRevision = branch.name }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
            }
            Toggle("Checkout branch", isOn: $checkout)
                .toggleStyle(.checkbox)
            Toggle("Overwrite existing branch", isOn: $resetExisting)
                .toggleStyle(.checkbox)
                .disabled(!branches.contains { $0.name == name.trimmingCharacters(in: .whitespacesAndNewlines) })
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Create", action: onCreate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || validationMessage != nil
                    )
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
/// IntelliJ-style multi-root branch creation. The branch name is shared, while
/// each selected Git root remains an independent operation target.
struct RebasedMultiRootNewBranchDialog: View {
    @Binding var name: String
    @Binding var baseRevision: String
    @Binding var checkout: Bool
    @Binding var resetExisting: Bool
    @Binding var selectedRootPaths: Set<String>
    let roots: [GitRootInfo]
    let existingBranchNames: [String: Set<String>]
    let validateName: (String) -> String?
    let onCreate: () -> Void
    let onCancel: () -> Void

    private var allSelected: Bool {
        !roots.isEmpty && roots.allSatisfy { selectedRootPaths.contains($0.path) }
    }

    private var hasExistingBranch: Bool {
        let candidate = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return false }
        return selectedRootPaths.contains { path in
            existingBranchNames[path]?.contains(candidate) == true
        }
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
        let validationMessage = validateName(name)
        VStack(alignment: .leading, spacing: 14) {
            Text("New Branch").font(.title3.weight(.semibold))
            Text("Create in Git roots")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Branch name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onChange(of: name) { _, value in
                    let cleaned = GitBranchNameCleanup.cleanUpOnTyping(value)
                    if cleaned != value { name = cleaned }
                }
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                Text("Create from")
                    .foregroundStyle(.secondary)
                TextField("HEAD", text: $baseRevision)
                    .textFieldStyle(.roundedBorder)
            }
            Toggle("Checkout branch", isOn: $checkout)
                .toggleStyle(.checkbox)
            Toggle("Overwrite existing branch", isOn: $resetExisting)
                .toggleStyle(.checkbox)
                .disabled(!hasExistingBranch)
            Divider()
            Toggle(
                "All repositories",
                isOn: Binding(
                    get: { allSelected },
                    set: { isSelected in
                        selectedRootPaths = isSelected ? Set(roots.map(\.path)) : []
                    }
                )
            )
            .toggleStyle(.checkbox)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(roots, id: \.path) { root in
                        Toggle(isOn: selectionBinding(for: root.path)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(root.displayName)
                                Text(root.relativePath)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(maxHeight: 150)
            if selectedRootPaths.isEmpty {
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
                Button("Create", action: onCreate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || validationMessage != nil
                            || selectedRootPaths.isEmpty
                    )
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}
