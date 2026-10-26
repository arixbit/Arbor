import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RebasedSingleRootRenameBranchDialog: View {
    let oldName: String
    @Binding var newName: String
    @Binding var unsetUpstream: Bool
    let hasUpstream: Bool
    let validateName: (String) -> String?
    let onRename: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let validationMessage = validateName(newName)
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Branch")
                .font(.title3.weight(.semibold))
            Text("Rename \(oldName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("New branch name", text: $newName)
                .textFieldStyle(.roundedBorder)
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if hasUpstream {
                Toggle("Unset upstream after rename", isOn: $unsetUpstream)
                    .toggleStyle(.checkbox)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Rename", action: onRename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || newName.trimmingCharacters(in: .whitespacesAndNewlines) == oldName
                            || validationMessage != nil
                    )
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
/// IntelliJ GitRenameBranchAction 的多 root 选择器：同名分支可能存在于
/// 多个 Git root，重命名必须先明确受影响仓库以及是否解除 upstream。
struct RebasedMultiRootRenameBranchDialog: View {
    let oldName: String
    @Binding var newName: String
    @Binding var unsetUpstream: Bool
    @Binding var selectedRootPaths: Set<String>
    let snapshots: [GitRootBranchSnapshot]
    let validateName: (String) -> String?
    let onRename: () -> Void
    let onCancel: () -> Void

    private var eligibleSnapshots: [GitRootBranchSnapshot] {
        snapshots
            .filter { snapshot in snapshot.branches.contains(where: { $0.name == oldName }) }
            .sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
    }

    private var allSelected: Bool {
        !eligibleSnapshots.isEmpty
            && eligibleSnapshots.allSatisfy { selectedRootPaths.contains($0.rootPath) }
    }

    private var hasUpstream: Bool {
        eligibleSnapshots.contains { snapshot in
            guard snapshot.branches.contains(where: { $0.name == oldName }) else { return false }
            return snapshot.syncStatuses.contains {
                $0.branch == oldName && $0.trackingExists
            }
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
        let validationMessage = validateName(newName)
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Branch")
                .font(.title3.weight(.semibold))
            Text("Rename \(oldName) in Git roots")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("New branch name", text: $newName)
                .textFieldStyle(.roundedBorder)
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if hasUpstream {
                Toggle("Unset upstream after rename", isOn: $unsetUpstream)
                    .toggleStyle(.checkbox)
            }
            Divider()
            Toggle(
                "All repositories",
                isOn: Binding(
                    get: { allSelected },
                    set: { isSelected in
                        selectedRootPaths = isSelected ? Set(eligibleSnapshots.map(\.rootPath)) : []
                    }
                )
            )
            .toggleStyle(.checkbox)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(eligibleSnapshots, id: \.rootPath) { snapshot in
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
                Button("Rename", action: onRename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || newName.trimmingCharacters(in: .whitespacesAndNewlines) == oldName
                            || validationMessage != nil
                            || selectedRootPaths.isEmpty
                    )
            }
        }
        .padding(20)
        .frame(width: 540)
    }
}
