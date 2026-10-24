import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

@ViewBuilder
var logWorkspace: some View {
    GeometryReader { geometry in
        // Both columns need their minimum plus the native 6pt divider.
        // Below that width, drill into details without sacrificing the list
        // or persisting a temporary, compressed divider position.
        let showsInlineInspector = geometry.size.width >= 540 + 6 + 280
        Group {
            if showsInlineInspector {
                WorkspaceHorizontalSplit(
                    persistedLeftWidth: $savedLogGraphWidth,
                    minimumLeftWidth: 540,
                    minimumRightWidth: 280
                ) {
                    logGraphPanel
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } rightContent: {
                    logInspector
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                compactLogWorkspace
            }
        }
        .onChange(of: showsInlineInspector) { _, inline in
            if inline { logSelectionState.inspectorPresented = false }
        }
    }
}

var compactLogWorkspace: some View {
    ZStack {
        logGraphPanel
            .overlay(alignment: .topTrailing) {
                Button {
                    logSelectionState.inspectorPresented = true
                } label: {
                    Label("View Commit Details", systemImage: "sidebar.right")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("log-open-inspector")
                .padding(.trailing, 12)
                .frame(height: 46)
            }
            .opacity(logSelectionState.inspectorPresented ? 0 : 1)
            .allowsHitTesting(!logSelectionState.inspectorPresented)
            .accessibilityHidden(logSelectionState.inspectorPresented)

        if logSelectionState.inspectorPresented {
            VStack(spacing: 0) {
                HStack {
                    Button {
                        logSelectionState.inspectorPresented = false
                    } label: {
                        Label("Log", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("log-close-inspector")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(height: 46)
                .background(Design.Colors.chrome)
                Divider()
                logInspector
            }
        }
    }
}


@ViewBuilder
var logInspector: some View {
    ZStack {
        switch logList.viewMode {
        case .compare:
            TreeCompareDetailView(
                repo: comparisonWorkspace.repository ?? repo,
                change: selectedTreeChange,
                selectedChanges: selectedTreeChanges,
                selectedPaths: comparisonWorkspace.selectedPaths,
                rev1: comparisonWorkspace.revision1,
                rev2: comparisonWorkspace.revision2,
                comparesWithWorkingTree: comparisonWorkspace.withWorkingTree,
                projectPath: projectWorkspace.path,
                onSelectPath: { path in
                    guard comparisonWorkspace.treeChanges.contains(where: { $0.path == path }) else { return }
                    comparisonWorkspace.selection = path
                }
            )
        case .compareBranches:
            LogCommitInspectorView(
                repo: comparisonWorkspace.repository ?? repo,
                repositoryForCommit: logRepository(for:),
                remotesForCommit: logRemotes(for:),
                commits: selectedBranchComparisonCommit.map { [$0] } ?? [],
                onReverted: { loadBranchComparison() },
                onCherryPicked: { loadBranchComparison(); refreshAll(showFeedback: false) },
                onRevertRequested: revertFromLog,
                onCherryPickRequested: cherryPickFromLog,
                onDropSelectedChanges: dropSelectedChangesFromLog,
                onExtractSelectedChanges: extractSelectedChangesFromLog,
                onShowFileHistory: { path in showFileHistory(path) },
                onShowFileHistoryForRevision: showFileHistoryForRevision,
                onOpenRepositoryVersion: browseFileRevisionFromLog,
                onBrowseHostedFileRevision: browseHostedFileRevisionFromLog,
                onCopyHostedFileRevision: copyHostedFileRevisionFromLog,
                onRestoreRepositoryVersion: restoreSelectedFilesFromRevisions,
                onEditSource: editSourceFromLog,
                onApplySelectedChanges: applySelectedChangesFromLog,
                onCreatePatch: createPatchFromLog,
                onCreatePatchSelection: createPatchFromLogSelection,
                onCopyPatchSelection: copyPatchFromLogSelection,
                onCreateBranch: createBranchFromCommit,
                showsMetadata: logShowDetails,
                showsDiffPreview: logShowDiffPreview,
                diffPreviewVertical: logDiffPreviewVertical,
                showsChangesFromParents: $logShowChangesFromParents,
                showsOnlyAffectedChanges: $logShowOnlyAffectedChanges,
                affectedPathSelections: activeLogPathFilterSelections()
            )
        case .tags:
            LogWorkspaceEmptyView(message: "选择 History 查看提交详情")
        case .reflog:
            LogCommitInspectorView(
                repo: logRepository,
                repositoryForCommit: logRepository(for:),
                remotesForCommit: logRemotes(for:),
                commits: selectedReflogCommits,
                onReverted: { reloadLogView() },
                onCherryPicked: { reloadLogView(); refreshAll(showFeedback: false) },
                onRevertRequested: revertFromLog,
                onCherryPickRequested: cherryPickFromLog,
                onDropSelectedChanges: dropSelectedChangesFromLog,
                onExtractSelectedChanges: extractSelectedChangesFromLog,
                onShowFileHistory: { path in showFileHistory(path) },
                onShowFileHistoryForRevision: showFileHistoryForRevision,
                onOpenRepositoryVersion: browseFileRevisionFromLog,
                onBrowseHostedFileRevision: browseHostedFileRevisionFromLog,
                onCopyHostedFileRevision: copyHostedFileRevisionFromLog,
                onRestoreRepositoryVersion: restoreSelectedFilesFromRevisions,
                onEditSource: editSourceFromLog,
                onApplySelectedChanges: applySelectedChangesFromLog,
                onCreatePatch: createPatchFromLog,
                onCreatePatchSelection: createPatchFromLogSelection,
                onCopyPatchSelection: copyPatchFromLogSelection,
                onCreateBranch: createBranchFromCommit,
                showsMetadata: logShowDetails,
                showsDiffPreview: logShowDiffPreview,
                diffPreviewVertical: logDiffPreviewVertical,
                showsChangesFromParents: $logShowChangesFromParents,
                showsOnlyAffectedChanges: $logShowOnlyAffectedChanges,
                affectedPathSelections: activeLogPathFilterSelections()
            )
        default:
            LogCommitInspectorView(
                repo: logRepository,
                repositoryForCommit: logRepository(for:),
                remotesForCommit: logRemotes(for:),
                commits: selectedLogCommits,
                onReverted: { loadLog() },
                onCherryPicked: { loadLog(); refreshAll(showFeedback: false) },
                onRevertRequested: revertFromLog,
                onCherryPickRequested: cherryPickFromLog,
                onDropSelectedChanges: dropSelectedChangesFromLog,
                onExtractSelectedChanges: extractSelectedChangesFromLog,
                onShowFileHistory: { path in showFileHistory(path) },
                onShowFileHistoryForRevision: showFileHistoryForRevision,
                onOpenRepositoryVersion: browseFileRevisionFromLog,
                onBrowseHostedFileRevision: browseHostedFileRevisionFromLog,
                onCopyHostedFileRevision: copyHostedFileRevisionFromLog,
                onRestoreRepositoryVersion: restoreSelectedFilesFromRevisions,
                onEditSource: editSourceFromLog,
                onApplySelectedChanges: applySelectedChangesFromLog,
                onCreatePatch: createPatchFromLog,
                onCreatePatchSelection: createPatchFromLogSelection,
                onCopyPatchSelection: copyPatchFromLogSelection,
                onCreateBranch: createBranchFromCommit,
                showsMetadata: logShowDetails,
                showsDiffPreview: logShowDiffPreview,
                diffPreviewVertical: logDiffPreviewVertical,
                showsChangesFromParents: $logShowChangesFromParents,
                showsOnlyAffectedChanges: $logShowOnlyAffectedChanges,
                affectedPathSelections: activeLogPathFilterSelections(),
                affectedHistoryPath: currentLogTabSnapshot().historyPath
            )
        }

    }
}


var logRefreshButtonTitle: String {
    logList.viewMode == .reflog ? "Refresh Reflog" : "Refresh Log"
}


var shouldShowLogError: Bool {
    logList.viewMode != .command
}


struct LogTabBar: View {
    let tabs: [LogTabDescriptor]
    let activeID: UUID
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onNew: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                HStack(spacing: 4) {
                    Button(tab.title) { onSelect(tab.id) }
                        .buttonStyle(.plain)
                        .font(.caption.weight(tab.id == activeID ? .semibold : .regular))
                        .foregroundStyle(tab.id == activeID ? .primary : .secondary)
                    Button { onClose(tab.id) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(tabs.count == 1)
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(
                    tab.id == activeID
                        ? Design.Colors.surface
                        : Design.Colors.surface.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 5)
                )
            }
            Button(action: onNew) {
                Image(systemName: "plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)
            .help("Open another Log tab")
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(Design.Colors.chrome.opacity(0.7))
    }
}


struct LogWorkspaceEmptyView: View {
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "sidebar.right")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

}
