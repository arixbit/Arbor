import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Read-only commit details shown beside the structured rebase table.
/// The selected todo rows remain the source of truth; this pane only loads
/// metadata and changes for inspection, matching IntelliJ's details splitter.
struct RebaseTodoCommitDetailsPane: View {
    let repo: Repository
    let commitIDs: [String]
    @State private var commits: [CommitInfo] = []
    @State private var focusedID: String?
    @State private var loadError: String?

    private var focusedCommit: CommitInfo? {
        guard let focusedID else { return commits.first }
        return commits.first { $0.id == focusedID } ?? commits.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if commits.count > 1 {
                List(selection: $focusedID) {
                    ForEach(commits, id: \.id) { commit in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(commit.summary)
                                .font(.callout.weight(.semibold))
                                .lineLimit(2)
                            Text(commit.shortId)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .tag(commit.id)
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 90, idealHeight: 125, maxHeight: 180)
            }

            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if let focusedCommit {
                CommitDetailView(
                    repo: repo,
                    commit: focusedCommit,
                    remotes: [],
                    onReverted: {},
                    onCherryPicked: {},
                    onCreateBranch: { _ in },
                    showsMetadata: true,
                    showsActions: false,
                    showsDiffPreview: true,
                    showsChanges: true
                )
            } else if commitIDs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sidebar.right")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Select a commit to view details")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Loading commit details…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: commitIDs) {
            commits = []
            focusedID = nil
            loadError = nil
            guard !commitIDs.isEmpty else { return }
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try commitIDs.map { try repo.commitInfo(commitId: $0) }
                }.value
                guard !Task.isCancelled else { return }
                commits = loaded
                focusedID = loaded.first?.id
            } catch {
                guard !Task.isCancelled else { return }
                loadError = error.localizedDescription
            }
        }
    }
}
struct RebaseCommandsHelpContext: Identifiable {
    let id = UUID()
    let title: String
    let items: [RebaseTodoItem]
}
/// IntelliJ's GitRebaseCommandsDialog equivalent. Keep this as a read-only
/// command reference so it cannot mutate the todo while the main editor keeps
/// ownership of selection, history, and execution state.
struct RebaseCommandsHelpView: View {
    let title: String
    let items: [RebaseTodoItem]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
            HStack(spacing: 10) {
                Text("Action")
                    .frame(width: 90, alignment: .leading)
                Text("Commit")
                    .frame(width: 90, alignment: .leading)
                Text("Subject")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Divider()
            List(items.indices, id: \.self) { index in
                let item = items[index]
                HStack(spacing: 10) {
                    Text(rebaseTodoActionCommand(item.action))
                        .font(.system(.callout, design: .monospaced))
                        .frame(width: 90, alignment: .leading)
                    Text(String(item.commitId.prefix(10)))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)
                    Text(item.summary)
                        .lineLimit(1)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
            HStack {
                Text("Native label/reset/merge/exec/break/update-ref rows are available from Edit Native Todo…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 420)
    }
}
