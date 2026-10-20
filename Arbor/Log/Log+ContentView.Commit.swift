import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {

/// The real Vcs Log frame has three independent pieces of state:
///
///   graph selection -> commit metadata/details
///   graph selection -> async Changes browser
///   Changes selection -> async file diff preview
///
/// Keeping those pieces in one `CommitDetailView` made a stale detail load
/// able to replace or hide the Changes browser. This wrapper mirrors
/// `MainFrame`: metadata is one splitter component and the Changes browser is
/// another, with its own selected path and diff task.
struct LogCommitInspectorView: View {
    let repo: Repository?
    let repositoryForCommit: (CommitInfo) -> Repository?
    let remotesForCommit: (CommitInfo) -> [RemoteInfo]
    let commits: [CommitInfo]
    let onReverted: () -> Void
    let onCherryPicked: () -> Void
    let onRevertRequested: (CommitInfo) -> Void
    let onCherryPickRequested: (CommitInfo) -> Void
    let onDropSelectedChanges: (CommitInfo, [String]) -> Void
    let onExtractSelectedChanges: (CommitInfo, [String]) -> Void
    let onShowFileHistory: (String) -> Void
    let onShowFileHistoryForRevision: (CommitInfo, String) -> Void
    let onOpenRepositoryVersion: (CommitInfo, String) -> Void
    let onBrowseHostedFileRevision: (LogChangeRecord, RemoteInfo) -> Void
    let onCopyHostedFileRevision: (LogChangeRecord, RemoteInfo) -> Void
    let onRestoreRepositoryVersion: ([LogChangeRecord]) -> Void
    let onEditSource: (String) -> Void
    let onApplySelectedChanges: ([LogChangeRecord], Bool) -> Void
    let onCreatePatch: (CommitInfo) -> Void
    let onCreatePatchSelection: ([LogChangeRecord]) -> Void
    let onCopyPatchSelection: ([LogChangeRecord]) -> Void
    let onCreateBranch: (CommitInfo) -> Void
    let showsMetadata: Bool
    let showsDiffPreview: Bool
    let diffPreviewVertical: Bool
    @Binding var showsChangesFromParents: Bool
    @Binding var showsOnlyAffectedChanges: Bool
    let affectedPathSelections: [LogPathFilterSelection]

    var body: some View {
        Group {
            if commits.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.left.circle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("选择一个提交查看 Changes")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showsMetadata {
                VSplitView {
                    Group {
                        if commits.count == 1 {
                            CommitDetailsMetadataView(
                                commit: commits[0],
                                repositoryForCommit: repositoryForCommit,
                                remotes: remotesForCommit(commits[0]),
                                onReverted: onReverted,
                                onCherryPicked: onCherryPicked,
                                onRevertRequested: onRevertRequested,
                                onCherryPickRequested: onCherryPickRequested,
                                onCreateBranch: onCreateBranch
                            )
                        } else {
                            LogMultiMetadataView(
                                commits: commits,
                                onCreateBranch: onCreateBranch
                            )
                        }
                    }
                    .frame(minHeight: 170, idealHeight: commits.count > 1 ? 250 : 300, maxHeight: .infinity)

                    LogChangesBrowserView(
                        repo: repo,
                        repositoryForCommit: repositoryForCommit,
                        remotesForCommit: remotesForCommit,
                        commits: commits,
                        showsDiffPreview: showsDiffPreview,
                        diffPreviewVertical: diffPreviewVertical,
                        showsChangesFromParents: $showsChangesFromParents,
                        showsOnlyAffectedChanges: $showsOnlyAffectedChanges,
                        affectedPathSelections: affectedPathSelections,
                        onDropSelectedChanges: onDropSelectedChanges,
                        onExtractSelectedChanges: onExtractSelectedChanges,
                        onShowFileHistory: onShowFileHistory,
                        onShowFileHistoryForRevision: onShowFileHistoryForRevision,
                        onOpenRepositoryVersion: onOpenRepositoryVersion,
                        onBrowseHostedFileRevision: onBrowseHostedFileRevision,
                        onCopyHostedFileRevision: onCopyHostedFileRevision,
                        onRestoreRepositoryVersion: onRestoreRepositoryVersion,
                        onEditSource: onEditSource,
                        onApplySelectedChanges: onApplySelectedChanges,
                        onCreatePatch: onCreatePatch,
                        onCreatePatchSelection: onCreatePatchSelection,
                        onCopyPatchSelection: onCopyPatchSelection
                    )
                    .frame(minHeight: 180, idealHeight: 390, maxHeight: .infinity)
                }
            } else {
                LogChangesBrowserView(
                    repo: repo,
                    repositoryForCommit: repositoryForCommit,
                    remotesForCommit: remotesForCommit,
                    commits: commits,
                    showsDiffPreview: showsDiffPreview,
                    diffPreviewVertical: diffPreviewVertical,
                    showsChangesFromParents: $showsChangesFromParents,
                    showsOnlyAffectedChanges: $showsOnlyAffectedChanges,
                    affectedPathSelections: affectedPathSelections,
                    onDropSelectedChanges: onDropSelectedChanges,
                    onExtractSelectedChanges: onExtractSelectedChanges,
                    onShowFileHistory: onShowFileHistory,
                    onShowFileHistoryForRevision: onShowFileHistoryForRevision,
                    onOpenRepositoryVersion: onOpenRepositoryVersion,
                    onBrowseHostedFileRevision: onBrowseHostedFileRevision,
                    onCopyHostedFileRevision: onCopyHostedFileRevision,
                    onRestoreRepositoryVersion: onRestoreRepositoryVersion,
                    onEditSource: onEditSource,
                    onApplySelectedChanges: onApplySelectedChanges,
                    onCreatePatch: onCreatePatch,
                    onCreatePatchSelection: onCreatePatchSelection,
                    onCopyPatchSelection: onCopyPatchSelection
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}


/// Metadata-only adapter for the existing action-rich commit inspector.
/// `CommitDetailView` intentionally does not load changed files in this mode;
/// the sibling `LogChangesBrowserView` owns that model, matching rebased's
/// `CommitDetailsListPanel` + `VcsLogChangesBrowser` split.
struct CommitDetailsMetadataView: View {
    let commit: CommitInfo?
    let repositoryForCommit: (CommitInfo) -> Repository?
    let remotes: [RemoteInfo]
    let onReverted: () -> Void
    let onCherryPicked: () -> Void
    let onRevertRequested: (CommitInfo) -> Void
    let onCherryPickRequested: (CommitInfo) -> Void
    let onCreateBranch: (CommitInfo) -> Void

    var selectedRepository: Repository? {
        guard let commit else { return nil }
        return repositoryForCommit(commit)
    }

    var body: some View {
        CommitDetailView(
            repo: selectedRepository,
            commit: commit,
            remotes: remotes,
            onReverted: onReverted,
            onCherryPicked: onCherryPicked,
            onCreateBranch: onCreateBranch,
            onRevertRequested: onRevertRequested,
            onCherryPickRequested: onCherryPickRequested,
            showsMetadata: true,
            showsDiffPreview: false,
            showsChanges: false
        )
    }
}


/// IntelliJ's details panel is a list panel, not a single-commit inspector:
/// Cmd/Shift selection in the graph produces one details card per selected
/// commit while the changes browser remains usable below it. The old Arbor
/// view highlighted several rows but silently kept showing only the active
/// row, which made multi-selection look broken. Keep the common changes and
/// diff surface lightweight, and load each selected commit's tree off the
/// main actor.
var selectedLogCommits: [CommitInfo] {
    let entries = logList.viewMode == .command ? logRuntime.commandEntries : logList.entries
    let selected = entries.filter { logSelectionState.selectedIDs.contains(logCommitIdentity($0)) }
    if selected.count > 1 { return selected }
    if let selectedCommit { return [selectedCommit] }
    return []
}

}
