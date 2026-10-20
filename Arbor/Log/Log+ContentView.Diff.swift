import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {

/// Git Log is the editor workspace to the right of the selected Git tool
/// window. It owns the graph, the changes browser, and the commit details
/// panel; Commit/Stash remains visible as the left tool-window column just as
/// it does in rebased.
var branchComparisonPagination: BranchComparisonPagination {
    BranchComparisonPagination(
        onRefresh: refreshBranchComparison,
        onLoadMore: loadMoreBranchComparison,
        hasMore: { side in
            side == .first ? branchComparison.firstHasMore : branchComparison.secondHasMore
        },
        isLoading: { side in
            side == .first ? branchComparison.firstLoading : branchComparison.secondLoading
        },
        error: { side in
            side == .first ? branchComparison.firstError : branchComparison.secondError
        }
    )
}


var branchComparisonLogActions: BranchComparisonLogActions {
    BranchComparisonLogActions(
        availability: logActionAvailability,
        pullRequestRemotesForCommit: pullRequestRemotesForCommit,
        onOpenPullRequest: openPullRequestsForCommit,
        commentRemotesForCommit: commentRemotesForCommit,
        onComment: beginReviewComment,
        onCreateTag: beginCreateTagFromLog,
        onCherryPickSelected: cherryPickCommitsFromLog,
        onRevertSelected: revertCommitsFromLog,
        onResetSelected: { commits in resetFromLog(commits) },
        currentBranchNameForCommit: currentLogBranchName,
        onReferenceAction: performLogReferenceAction,
        onRebaseOntoCommit: rebaseOntoCommitFromLog,
        onCreateAutoSquashCommit: beginAutoSquashCommitFromLog,
        onRewriteCommit: { commit, action in
            rewriteCommitFromLog(commit, action: action)
        },
        onRewriteSelected: { commits, action in
            rewriteSelectedCommitsFromLog(commits, action: action)
        },
        onPushUpToCommit: pushUpToCommitFromLog,
        onAddCommitsToRemoteBranch: addCommitsToRemoteBranchFromLog,
        hostedRemotesForCommit: hostedRemotesForCommit,
        onBrowseHostedRevision: browseHostedRevisionFromLog,
        onBrowseRevision: browseRevisionFromLog,
        onCopyRevisionLink: copyRevisionLinkFromLog,
        onUncommit: uncommitFromLog
    )
}


/// IntelliJ's Compare Branches action shows the commits unique to each ref in
/// two synchronized log panes. The file-level Show Files Diff action remains
/// the separate TreeCompareDetailView path.
enum BranchComparisonCommitAction {
    case checkout
    case reset
    case createBranch
    case compare
    case interactiveRebase
    case cherryPick
    case revert
}


struct BranchComparisonPagination {
    let onRefresh: (BranchComparisonSide) -> Void
    let onLoadMore: (BranchComparisonSide) -> Void
    let hasMore: (BranchComparisonSide) -> Bool
    let isLoading: (BranchComparisonSide) -> Bool
    let error: (BranchComparisonSide) -> String?
}


struct BranchComparisonLogActions {
    let availability: LogActionAvailability
    let pullRequestRemotesForCommit: (CommitInfo) -> [RemoteInfo]
    let onOpenPullRequest: (CommitInfo, RemoteInfo) -> Void
    let commentRemotesForCommit: (CommitInfo) -> [RemoteInfo]
    let onComment: (CommitInfo, RemoteInfo) -> Void
    let onCreateTag: (CommitInfo) -> Void
    let onCherryPickSelected: ([CommitInfo]) -> Void
    let onRevertSelected: ([CommitInfo]) -> Void
    let onResetSelected: ([CommitInfo]) -> Void
    let currentBranchNameForCommit: (CommitInfo) -> String?
    let onReferenceAction: (CommitInfo, LogReferenceActionTarget, LogReferenceAction) -> Void
    let onRebaseOntoCommit: (CommitInfo) -> Void
    let onCreateAutoSquashCommit: (CommitInfo, AutoSquashCommitKind) -> Void
    let onRewriteCommit: (CommitInfo, RebaseTodoAction) -> Void
    let onRewriteSelected: ([CommitInfo], RebaseTodoAction) -> Void
    let onPushUpToCommit: (CommitInfo) -> Void
    let onAddCommitsToRemoteBranch: ([CommitInfo]) -> Void
    let hostedRemotesForCommit: (CommitInfo) -> [RemoteInfo]
    let onBrowseHostedRevision: (CommitInfo, RemoteInfo) -> Void
    let onBrowseRevision: (CommitInfo) -> Void
    let onCopyRevisionLink: (CommitInfo, RemoteInfo) -> Void
    let onUncommit: (CommitInfo) -> Void
}


struct BranchCommitComparisonView: View {
    let firstBranch: String
    let secondBranch: String
    let firstCommits: [CommitInfo]
    let secondCommits: [CommitInfo]
    @Binding var firstFilter: BranchComparisonFilter
    @Binding var secondFilter: BranchComparisonFilter
    let isLoading: Bool
    let error: String?
    @Binding var selectedID: String?
    @Binding var selectedSide: BranchComparisonSide
    let onFilterChanged: (BranchComparisonSide) -> Void
    let pagination: BranchComparisonPagination
    let onSelect: (BranchComparisonSide, String) -> Void
    let onAction: (BranchComparisonCommitAction, CommitInfo) -> Void
    let logActions: BranchComparisonLogActions
    @State var firstGraphSelectedIDs: Set<String> = []
    @State var secondGraphSelectedIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error,
               pagination.error(.first) == nil,
               pagination.error(.second) == nil {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .padding(10)
            }
            HStack(spacing: 0) {
                comparisonColumn(
                    title: firstBranch,
                    commits: firstCommits,
                    side: .first,
                    filter: $firstFilter,
                    selection: $selectedID,
                    selectedIDs: $firstGraphSelectedIDs
                )
                Divider()
                comparisonColumn(
                    title: secondBranch,
                    commits: secondCommits,
                    side: .second,
                    filter: $secondFilter,
                    selection: $selectedID,
                    selectedIDs: $secondGraphSelectedIDs
                )
            }
            .overlay {
                if isLoading && firstCommits.isEmpty && secondCommits.isEmpty {
                    ProgressView("Loading branch comparison…")
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    func comparisonColumn(
        title: String,
        commits: [CommitInfo],
        side: BranchComparisonSide,
        filter: Binding<BranchComparisonFilter>,
        selection: Binding<String?>,
        selectedIDs: Binding<Set<String>>
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text("\(commits.count) unique")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    pagination.onRefresh(side)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh comparison pane")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Design.Colors.chrome.opacity(0.72))
            HStack(spacing: 6) {
                TextField("Message or hash", text: filter.message)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { onFilterChanged(side) }
                TextField("Author", text: filter.author)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { onFilterChanged(side) }
                Menu {
                    Toggle("Regex", isOn: filter.messageRegex)
                    Toggle("Match Case", isOn: filter.messageMatchCase)
                    Toggle("No Merges", isOn: filter.noMerges)
                    Divider()
                    Button("Clear Filters") {
                        filter.wrappedValue = BranchComparisonFilter()
                        onFilterChanged(side)
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton)
                .help("Compare pane filter settings")
                .onChange(of: filter.wrappedValue.messageRegex) { _, _ in onFilterChanged(side) }
                .onChange(of: filter.wrappedValue.messageMatchCase) { _, _ in onFilterChanged(side) }
                .onChange(of: filter.wrappedValue.noMerges) { _, _ in onFilterChanged(side) }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .background(Design.Colors.chrome.opacity(0.72))
            HStack(spacing: 6) {
                TextField("Since (YYYY-MM-DD)", text: filter.since)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { onFilterChanged(side) }
                TextField("Until (YYYY-MM-DD)", text: filter.until)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { onFilterChanged(side) }
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .background(Design.Colors.chrome.opacity(0.72))

            if let paneError = pagination.error(side) {
                Text(paneError)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            if commits.isEmpty && !pagination.isLoading(side) {
                Text("No unique commits")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if commits.isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LogGraphView(
                    commits: commits,
                    selection: selection,
                    selectedIDs: selectedIDs,
                    commitIdentity: { $0.id },
                    compactReferences: true,
                    showCommitColumns: false,
                    showAuthorColumn: true,
                    showDateColumn: true,
                    showHashColumn: true,
                    showRootColumn: false,
                    showSignatureColumn: false,
                    signatureStatuses: [:],
                    signatureLoadingIDs: [],
                    signatureFailedIDs: [],
                    columnLayout: LogColumnLayout(
                        order: [.commit, .author, .date, .hash]
                    ),
                    showTagNames: false,
                    alignLabels: false,
                    showLongEdges: true,
                    collapseGraph: false,
                    highlightCherryPickedCommits: false,
                    actionAvailability: logActions.availability,
                    onReachedEnd: { pagination.onLoadMore(side) },
                    hasMore: pagination.hasMore(side),
                    isLoadingMore: pagination.isLoading(side),
                    pullRequestRemotesForCommit: logActions.pullRequestRemotesForCommit,
                    onOpenPullRequest: logActions.onOpenPullRequest,
                    commentRemotesForCommit: logActions.commentRemotesForCommit,
                    onComment: logActions.onComment,
                    onCreateBranch: { onAction(.createBranch, $0) },
                    onCreateTag: logActions.onCreateTag,
                    onCherryPick: { onAction(.cherryPick, $0) },
                    onCherryPickSelected: logActions.onCherryPickSelected,
                    onRevert: { onAction(.revert, $0) },
                    onRevertSelected: logActions.onRevertSelected,
                    onCheckout: { onAction(.checkout, $0) },
                    onReset: { onAction(.reset, $0) },
                    onResetSelected: logActions.onResetSelected,
                    onCompare: { onAction(.compare, $0) },
                    currentBranchNameForCommit: logActions.currentBranchNameForCommit,
                    onReferenceAction: logActions.onReferenceAction,
                    onRebaseOntoCommit: logActions.onRebaseOntoCommit,
                    onInteractiveRebase: { onAction(.interactiveRebase, $0) },
                    onCreateAutoSquashCommit: logActions.onCreateAutoSquashCommit,
                    onRewriteCommit: logActions.onRewriteCommit,
                    onRewriteSelected: logActions.onRewriteSelected,
                    onPushUpToCommit: logActions.onPushUpToCommit,
                    onAddCommitsToRemoteBranch: logActions.onAddCommitsToRemoteBranch,
                    hostedRemotesForCommit: logActions.hostedRemotesForCommit,
                    onBrowseHostedRevision: logActions.onBrowseHostedRevision,
                    onBrowseRevision: logActions.onBrowseRevision,
                    onCopyRevisionLink: logActions.onCopyRevisionLink,
                    onUncommit: logActions.onUncommit
                )
                .onChange(of: selection.wrappedValue) { _, id in
                    let validIDs = Set(commits.map(\.id))
                    guard let nextSelection = branchComparisonGraphSelection(
                        current: selectedIDs.wrappedValue,
                        selectedID: id,
                        validIDs: validIDs
                    ) else {
                        selectedIDs.wrappedValue = []
                        return
                    }
                    selectedIDs.wrappedValue = nextSelection
                    guard let id else { return }
                    onSelect(side, id)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}


enum LogDiffSource: Equatable {
    case commit
    case local(revision: String)
}


/// Standalone Changes Browser diff action. The inline preview is optional in
/// IntelliJ, but Show Diff, double-click, and Enter remain meaningful when
/// that preview is hidden; keep the same distinction instead of making the
/// action silently reselect the current row.
struct LogStandaloneDiffView: View {
    let record: LogChangeRecord
    let repositoryForCommit: (CommitInfo) -> Repository?

    @Environment(\.dismiss) private var dismiss
    @State var fileDiff: FileDiff?
    @State var diffError: String?
    @State var presentationMode: DiffPresentationMode = .sideBySide
    @State var diffTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Diff")
                    .font(.headline)
                Text(record.change.path)
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(1)
                Text(record.commit.shortId)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Diff View", selection: $presentationMode) {
                    ForEach(DiffPresentationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 150)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            .overlay(alignment: .bottom) { Divider() }

            if let diffError {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Unable to load diff", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Design.Colors.error)
                    Text(diffError)
                        .font(.caption)
                        .textSelection(.enabled)
                    Button("Retry") { load() }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
            } else if let fileDiff {
                if fileDiff.binary && fileDiff.hunks.isEmpty {
                    ContentUnavailableView(
                        "Binary File",
                        systemImage: "doc.zipper",
                        description: Text("Git reported a binary change for this path.")
                    )
                } else if presentationMode == .unified {
                    UnifiedDiffView(fileDiff: fileDiff)
                } else {
                    SideBySideDiffView(fileDiff: fileDiff)
                }
            } else {
                ProgressView("Loading diff…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .task(id: record.id) { load() }
        .onDisappear { diffTask?.cancel() }
    }

    func load() {
        diffTask?.cancel()
        fileDiff = nil
        diffError = nil
        guard let repo = repositoryForCommit(record.commit) else {
            diffError = "The repository for this change is no longer available."
            return
        }
        let commitID = record.commit.id
        let parentIndex = record.parentIndex
        let path = record.change.path
        let expectedID = record.id
        diffTask = Task.detached(priority: .userInitiated) {
            do {
                let diff = try repo.commitFileDiffWithSettings(
                    commitId: commitID,
                    parentIndex: parentIndex,
                    path: path,
                    settings: makeArborGitDiffSettings()
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.record.id == expectedID else { return }
                    self.fileDiff = diff
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.record.id == expectedID else { return }
                    self.diffError = "\(error)"
                }
            }
        }
    }
}


func copySelectedComparePaths() {
    let paths = orderedCompareSelection(
        changes: comparisonWorkspace.treeChanges,
        selectedPaths: comparisonWorkspace.selectedPaths
    ).map(\.path)
    guard !paths.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
}


var cherryPickCompareBranchChoices: [String] {
    var names: [String]
    if isLogAggregate {
        // An aggregate Log has no single active Repository. Apply the chosen
        // source name independently to every root that exposes that ref.
        let aggregateRootPaths = Set(
            logRuntime.aggregateBranchFilters.map(\.rootPath)
                + logRuntime.aggregateRevisionRanges.map(\.rootPath)
                + Array(logRuntime.aggregateRootPaths)
        )
        let eligibleSnapshots = multiRootWorkspace.branchSnapshots.filter {
            aggregateRootPaths.contains($0.rootPath)
        }
        names = eligibleSnapshots.flatMap { snapshot in
            snapshot.branches.map(\.name) + snapshot.remoteBranches.map(\.name)
        }
    } else {
        names = branchWorkspace.branches.map(\.name) + branchWorkspace.remoteBranches.map(\.name)
    }
    if !logCherryPickCompareBranch.isEmpty && !names.contains(logCherryPickCompareBranch) {
        names.append(logCherryPickCompareBranch)
    }
    return Array(Set(names)).sorted()
}

}
