import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Recovery surface shown after force-deleting an unmerged local branch. The
/// exact old tip is retained by the engine, so restoring does not depend on a
/// reflog entry still being available.
struct BranchDeleteRecoveryView: View {
    let preview: BranchDeletePreview
    let rootPath: String?
    let trackedRemoteBranch: String?
    let onRestore: () -> Void
    let onDeleteTrackedRemote: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(.orange)
                Text("Branch deleted")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            Text("The branch reference was removed, but its old tip is still available to restore.")
                .foregroundStyle(.secondary)
            LabeledContent("Branch", value: preview.branchName)
            LabeledContent("Deleted tip", value: preview.tipId)
                .font(.system(.caption, design: .monospaced))
            if let rootPath {
                LabeledContent("Repository", value: rootPath)
                    .lineLimit(1)
            }
            if !preview.baseBranches.isEmpty {
                LabeledContent("Already merged into", value: preview.baseBranches.joined(separator: ", "))
            }
            Divider()
            HStack {
                Text("Unmerged commits")
                    .font(.headline)
                Text("\(preview.unmergedCommits.count)")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if preview.unmergedCommits.isEmpty {
                Text("No unmerged commits were found in the captured snapshot.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                List(preview.unmergedCommits, id: \.id) { commit in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(commit.shortId)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(commit.summary.isEmpty ? "(no subject)" : commit.summary)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
            HStack {
                Spacer()
                Button("Done", role: .cancel, action: onDone)
                if trackedRemoteBranch != nil {
                    Button("Delete Tracked Remote", role: .destructive, action: onDeleteTrackedRemote)
                }
                Button("Restore Branch", action: onRestore)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
    }
}
struct RebasedMultiRootBranchDeleteRecoveryView: View {
    let branchName: String
    let contexts: [BranchDeleteRecoveryContext]
    let onRestore: () -> Void
    let onDeleteTrackedRemote: (String) -> Void
    let onDone: () -> Void

    private var trackedRemoteBranches: [String] {
        Array(Set(contexts.compactMap(\.trackedRemoteBranch))).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(.orange)
                Text("Branches deleted")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            Text("The branch \(branchName) was deleted from the selected repositories.")
                .foregroundStyle(.secondary)
            List(contexts, id: \.id) { context in
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(context.rootPath ?? localizedArborString("Repository", locale: AppLanguage.interfaceLocale))
                            .lineLimit(1)
                        Text(context.preview.tipId)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !context.preview.unmergedCommits.isEmpty {
                        Text(localizedArborString("unmerged", locale: AppLanguage.interfaceLocale))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
            HStack {
                Text("\(contexts.count) repositories available to restore")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", role: .cancel, action: onDone)
                if trackedRemoteBranches.count == 1, let remoteBranch = trackedRemoteBranches.first {
                    Button("Delete Tracked Remote", role: .destructive) {
                        onDeleteTrackedRemote(remoteBranch)
                    }
                } else if trackedRemoteBranches.count > 1 {
                    Menu("Delete Tracked Remote") {
                        ForEach(trackedRemoteBranches, id: \.self) { remoteBranch in
                            Button(remoteBranch, role: .destructive) {
                                onDeleteTrackedRemote(remoteBranch)
                            }
                        }
                    }
                }
                Button("Restore All", action: onRestore)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 420)
    }
}
struct RebasedMultiRootDeleteBranchDialog: View {
    let branchName: String
    @Binding var selectedRootPaths: Set<String>
    let snapshots: [GitRootBranchSnapshot]
    let onDelete: () -> Void
    let onCancel: () -> Void

    private var branchSnapshots: [GitRootBranchSnapshot] {
        snapshots
            .filter { snapshot in
                snapshot.branches.contains { $0.name == branchName && !$0.isCurrent }
            }
            .sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
    }

    private var currentBranchRepositories: Int {
        snapshots.filter { snapshot in
            snapshot.branches.contains { $0.name == branchName && $0.isCurrent }
        }.count
    }

    private var allSelected: Bool {
        !branchSnapshots.isEmpty
            && branchSnapshots.allSatisfy { selectedRootPaths.contains($0.rootPath) }
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
            Text("Delete Branch")
                .font(.title3.weight(.semibold))
            Text("Delete \(branchName) from Git roots")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Unmerged branches are force-deleted like IntelliJ's multi-repository operation; their exact tips remain available for restore.")
                .font(.caption)
                .foregroundStyle(.orange)
            if currentBranchRepositories > 0 {
                Text("\(currentBranchRepositories) repositories are currently on this branch and will be skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            Toggle(
                "All eligible repositories",
                isOn: Binding(
                    get: { allSelected },
                    set: { isSelected in
                        selectedRootPaths = isSelected ? Set(branchSnapshots.map(\.rootPath)) : []
                    }
                )
            )
            .toggleStyle(.checkbox)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(branchSnapshots, id: \.rootPath) { snapshot in
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
            if branchSnapshots.isEmpty {
                Text("No eligible repository contains a deletable copy of this branch.")
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
                    .disabled(branchSnapshots.isEmpty || selectedRootPaths.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
