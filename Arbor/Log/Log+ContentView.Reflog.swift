import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {


func synchronizeReflogSelection() {
    let validIDs = Set(reflog.entries.map(reflogEntryIdentifier))
    let normalized = reflog.selectedIDs.intersection(validIDs)
    if normalized != reflog.selectedIDs {
        reflog.selectedIDs = normalized
        return
    }
    if let selection = reflog.selection, normalized.contains(selection) {
        return
    }
    reflog.selection = orderedReflogSelection(
        entries: reflog.entries,
        selectedIDs: normalized
    ).first.map(reflogEntryIdentifier)
}


func copySelectedReflogIDs() {
    let ids = orderedUniqueReflogCommitIDs(selectedReflogEntries)
    guard !ids.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(ids.joined(separator: "\n"), forType: .string)
}


var hasSelectedReflogEntries: Bool {
    !reflog.selectedIDs.isEmpty
}


var reflogHistoryContent: some View {
    VStack(spacing: 0) {
        HStack(spacing: 8) {
            Text("Reflog")
                .font(.headline)
            Text("\(reflog.entries.count) entries")
                .font(.caption)
                .foregroundStyle(.secondary)
            if hasSelectedReflogEntries {
                Text("\(reflog.selectedIDs.count) selected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ForEach(availableReflogRootPaths, id: \.self) { rootPath in
                    Button {
                        selectReflogRoot(rootPath)
                    } label: {
                        Text(rootPath)
                    }
                }
            } label: {
                Label(reflogRootTitle, systemImage: "externaldrive")
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .help("Reflog repository")
            Button {
                loadReflog()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh Reflog")
            Menu {
                Button("Select All") {
                    reflog.selectedIDs = Set(reflog.entries.map(reflogEntryIdentifier))
                    reflog.selection = reflog.entries.first.map(reflogEntryIdentifier)
                }
                .disabled(reflog.entries.isEmpty)
                Button("Clear") {
                    reflog.selectedIDs = []
                    reflog.selection = nil
                }
                .disabled(reflog.selectedIDs.isEmpty)
                Divider()
                Button("Copy Selected Revision IDs") {
                    copySelectedReflogIDs()
                }
                .disabled(reflog.selectedIDs.isEmpty)
                if !selectedReflogCommits.isEmpty {
                    Divider()
                    Menu("Reflog actions") {
                        if selectedReflogCommits.count == 1,
                           let commit = selectedReflogCommits.first {
                            Button("Checkout Revision") {
                                checkoutFromLog(commit)
                            }
                            Button("Reset Current Branch to Here…") {
                                resetFromLog(commit)
                            }
                            Button("Create Branch from Commit") {
                                createBranchFromCommit(commit)
                            }
                            Button("Compare with Current…") {
                                compareFromLog(commit)
                            }
                            Button("Interactive Rebase from Here…") {
                                interactiveRebaseFromLog(commit)
                            }
                            .disabled(!isInteractiveRebaseAvailable(for: commit))
                            Divider()
                            Button("Cherry-pick") {
                                cherryPickFromLog(commit)
                            }
                            Button("Revert Commit") {
                                revertFromLog(commit)
                            }
                            .disabled(commit.parentIds.count != 1)
                        } else {
                            Button("Cherry-pick Selected Commits") {
                                cherryPickCommitsFromLog(selectedReflogCommits)
                            }
                            Button("Revert Selected Commits") {
                                revertCommitsFromLog(selectedReflogCommits)
                            }
                            .disabled(
                                selectedReflogCommits.contains { $0.parentIds.count != 1 }
                            )
                            Text("Checkout, reset, branch, compare and rebase require one selected revision.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .help("Reflog actions")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .overlay(alignment: .bottom) { Divider() }

        List(selection: $reflog.selectedIDs) {
            ForEach(reflog.entries, id: \.self) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.message).lineLimit(1)
                    Text("\(entry.oldId.prefix(7)) → \(entry.newId.prefix(7)) · \(dateStr(entry.time))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(reflogEntryIdentifier(entry))
                .simultaneousGesture(TapGesture().onEnded {
                    reflog.selection = reflogEntryIdentifier(entry)
                })
                .contextMenu {
                    Button("View Commit Details") {
                        let id = reflogEntryIdentifier(entry)
                        reflog.selection = id
                        reflog.selectedIDs = [id]
                    }
                    Button("Copy Revision ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.newId, forType: .string)
                    }
                    if let commit = reflogCommit(for: entry) {
                        Divider()
                        Button("Checkout Revision") { checkoutFromLog(commit) }
                        Button("Reset Current Branch to Here…") { resetFromLog(commit) }
                        Button("Create Branch from Commit") { createBranchFromCommit(commit) }
                        Button("Compare with Current…") { compareFromLog(commit) }
                        Button("Interactive Rebase from Here…") {
                            interactiveRebaseFromLog(commit)
                        }
                        .disabled(!isInteractiveRebaseAvailable(for: commit))
                        Divider()
                        Button("Cherry-pick") { cherryPickFromLog(commit) }
                        Button("Revert Commit") { revertFromLog(commit) }
                            .disabled(commit.parentIds.count != 1)
                    }
                }
            }
        }
        .listStyle(.inset)
        if reflog.hasMore || reflog.isLoadingMore {
            HStack(spacing: 8) {
                Spacer()
                if reflog.isLoadingMore {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading older entries…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Load Older Entries") {
                        loadMoreReflog()
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .background(Design.Colors.canvas)
        }
    }
}

}
