import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Splits a file into display lines. CRLF is normalized because the diff
/// engine compares logical lines, and a trailing newline must not add an empty
/// numbered line.
func fileTextLines(_ text: String) -> [String] {
    var normalized = text
    if normalized.contains("\r\n") {
        normalized = normalized.replacingOccurrences(of: "\r\n", with: "\n")
    }
    var lines = normalized.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    return lines
}

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


/// Changes Browser 的独立 diff 视图，打开在 Log 编辑区的 tab 里。
///
/// The inline preview is optional in IntelliJ, but Show Diff, double-click,
/// and Enter remain meaningful when that preview is hidden; keep the same
/// distinction instead of making the action silently reselect the current
/// row. The toolbar mirrors IntelliJ's diff viewer: previous/next difference,
/// the file list, previous/next file, the difference count, the view mode and
/// diff settings.
struct LogFileDiffView: View {
    let record: LogChangeRecord
    let source: LogDiffSource
    let repositoryForCommit: (CommitInfo) -> Repository?
    var siblings: [LogChangeRecord] = []
    var onSelectFile: ((LogChangeRecord) -> Void)?
    var onClose: (() -> Void)?
    var onSelectPrevious: (() -> Void)?
    var onSelectNext: (() -> Void)?

    @State var fileDiff: FileDiff?
    @State var fullFile: FullFileDiff?
    @State var diffError: String?
    @State var presentationMode: DiffPresentationMode = .sideBySide
    @State var activeDifference: Int?
    @State var ignoreWhitespace = false
    @State var wordDiff = false
    @State var crlfSensitive = true
    @State var selectionMode = false
    @State var selectedLines: Set<SelectedDiffLine> = []
    @State var showsPatch = false
    @State var showsLineNumbers = true
    @State var showsProperties = false
    @State var showsDimensions = false
    @State var showsBlame = false
    @State var showsClipboardDiff = false
    @State var clipboardDiffText = ""
    @State var actionError: String?
    @State var diffTask: Task<Void, Never>?

    var requestIdentity: String {
        "\(record.id)\u{1f}\(source.identity)"
            + "\u{1f}\(ignoreWhitespace ? 1 : 0)\(wordDiff ? 1 : 0)\(crlfSensitive ? 1 : 0)"
    }

    var isLocalSource: Bool {
        if case .local = source { return true }
        return false
    }

    var differenceCount: Int {
        guard let fileDiff else { return 0 }
        switch presentationMode {
        case .sideBySide: return sideBySideDifferenceCount(in: fileDiff.hunks)
        case .unified: return unifiedDifferenceCount(in: fileDiff.hunks)
        }
    }

    var baseRevisionLabel: String {
        switch source {
        case .commit:
            guard let parentIndex = record.parentIndex,
                  record.commit.parentIds.indices.contains(Int(parentIndex)) else { return "" }
            return String(record.commit.parentIds[Int(parentIndex)].prefix(7))
        case let .local(revision):
            return String(revision.prefix(7))
        }
    }

    var targetRevisionLabel: String {
        switch source {
        case .commit: return record.commit.shortId
        case .local: return localizedArborString("Local", locale: AppLanguage.interfaceLocale)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            revisionHeader
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: requestIdentity) { load() }
        .onChange(of: presentationMode) { _, _ in
            // The two presentations have their own row anchors. Leaving the
            // old ordinal selected would highlight an unrelated run.
            activeDifference = nil
        }
        .sheet(isPresented: $showsBlame) {
            LogBlameSheet(path: record.change.path, revisionLabel: targetRevisionLabel) {
                try await loadBlameLines()
            }
        }
        .sheet(isPresented: $showsClipboardDiff) {
            DiffTextSheet(
                title: "Clipboard Diff",
                subtitle: record.change.path,
                text: clipboardDiffText
            )
        }
        .alert("Diff Action Failed", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .onDisappear { diffTask?.cancel() }
    }

    @ViewBuilder
    var toolbar: some View {
        WrappingHStack(spacing: 6, lineSpacing: 6) {
            previousDifferenceButton
            nextDifferenceButton
            toolbarSeparator
            fileMenu
            toolbarSeparator
            previousFileButton
            nextFileButton
            closeButton
            differenceCountLabel
            toolbarSeparator
            ignoreWhitespaceToggle
            wordDiffToggle
            crlfToggle
            selectionModeToggle
            patchToggle
            toolbarSeparator
            externalDiffButton
            clipboardCompareButton
            propertiesButton
            blameButton
            threeVersionButton
            dimensionsButton
            toolbarSeparator
            workspaceControls
            toolbarSeparator
            diffViewControls
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var toolbarSeparator: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1, height: 16)
    }

    var previousDifferenceButton: some View {
        Button { moveDifference(-1) } label: {
            Image(systemName: "arrow.up")
        }
        .buttonStyle(.borderless)
        .help("Previous Difference")
        .keyboardShortcut(.upArrow, modifiers: [.command, .option])
        .disabled(differenceCount == 0 || showsPatch)
        .accessibilityIdentifier("log-diff-previous-difference")
    }

    var nextDifferenceButton: some View {
        Button { moveDifference(1) } label: {
            Image(systemName: "arrow.down")
        }
        .buttonStyle(.borderless)
        .help("Next Difference")
        .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        .disabled(differenceCount == 0 || showsPatch)
        .accessibilityIdentifier("log-diff-next-difference")
    }

    var fileMenu: some View {
        Menu {
            Section("Files") {
                ForEach(siblings, id: \.id) { sibling in
                    Button {
                        onSelectFile?(sibling)
                    } label: {
                        if sibling.id == record.id {
                            Label(sibling.change.path, systemImage: "checkmark")
                        } else {
                            Text(sibling.change.path)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("1 file")
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Files")
        .accessibilityIdentifier("log-diff-files")
    }

    var previousFileButton: some View {
        Button(action: onSelectPrevious ?? {}) {
            Image(systemName: "chevron.left")
        }
        .buttonStyle(.borderless)
        .help("Previous File")
        .keyboardShortcut(.leftArrow, modifiers: [.shift, .option])
        .disabled(onSelectPrevious == nil)
        .accessibilityIdentifier("log-diff-previous-file")
    }

    var nextFileButton: some View {
        Button(action: onSelectNext ?? {}) {
            Image(systemName: "chevron.right")
        }
        .buttonStyle(.borderless)
        .help("Next File")
        .keyboardShortcut(.rightArrow, modifiers: [.shift, .option])
        .disabled(onSelectNext == nil)
        .accessibilityIdentifier("log-diff-next-file")
    }

    @ViewBuilder
    var closeButton: some View {
        if let onClose {
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close")
            .accessibilityLabel("Close")
            .accessibilityIdentifier("log-file-diff-close")
        }
    }

    @ViewBuilder
    var differenceCountLabel: some View {
        if differenceCount == 1 {
            Text("1 difference")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if differenceCount > 1 {
            Text("\(differenceCount) differences")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    var ignoreWhitespaceToggle: some View {
        DiffToolbarToggle(
            title: "Ignore Whitespace",
            isOn: $ignoreWhitespace,
            identifier: "log-diff-ignore-whitespace"
        )
    }

    var wordDiffToggle: some View {
        DiffToolbarToggle(
            title: "Word Differences",
            isOn: $wordDiff,
            identifier: "log-diff-word-differences"
        )
    }

    var crlfToggle: some View {
        DiffToolbarToggle(
            title: "CRLF Sensitive",
            isOn: $crlfSensitive,
            identifier: "log-diff-crlf-sensitive"
        )
    }

    var selectionModeToggle: some View {
        DiffToolbarToggle(
            title: "Selection Mode",
            isOn: Binding(
                get: { selectionMode },
                set: { enabled in
                    selectionMode = enabled
                    if enabled { presentationMode = .sideBySide }
                }
            ),
            identifier: "log-diff-selection-mode"
        )
    }

    var patchToggle: some View {
        DiffToolbarToggle(
            title: "Patch",
            isOn: $showsPatch,
            identifier: "log-diff-patch"
        )
    }

    var externalDiffButton: some View {
        DiffToolbarButton(
            title: "External Diff",
            systemImage: nil,
            identifier: "log-diff-external",
            isEnabled: fullFile != nil,
            help: "Open both versions in an external diff tool",
            action: openExternalDiff
        )
    }

    var clipboardCompareButton: some View {
        DiffToolbarButton(
            title: "Compare with Clipboard",
            systemImage: nil,
            identifier: "log-diff-clipboard",
            isEnabled: fullFile?.newLines != nil,
            help: "Compare the target file with the clipboard",
            action: compareWithClipboard
        )
    }

    var propertiesButton: some View {
        DiffToolbarButton(
            title: "File Properties",
            systemImage: nil,
            identifier: "log-diff-properties",
            action: { showsProperties = true }
        )
        .popover(isPresented: $showsProperties, arrowEdge: .bottom) {
            LogDiffPropertiesView(
                record: record,
                source: source,
                fullFile: fullFile,
                differenceCount: differenceCount,
                isBinary: fileDiff?.binary ?? false
            )
        }
    }

    var blameButton: some View {
        DiffToolbarButton(
            title: "Blame",
            systemImage: nil,
            identifier: "log-diff-blame",
            action: { showsBlame = true }
        )
    }

    var threeVersionButton: some View {
        DiffToolbarButton(
            title: "Three-version Compare",
            systemImage: nil,
            identifier: "log-diff-three-version",
            isEnabled: false,
            help: "Available for local changes",
            action: {}
        )
    }

    var dimensionsButton: some View {
        DiffToolbarButton(
            title: "Dimensions",
            systemImage: nil,
            identifier: "log-diff-dimensions",
            action: { showsDimensions = true }
        )
        .popover(isPresented: $showsDimensions, arrowEdge: .bottom) {
            Toggle("Line Numbers", isOn: $showsLineNumbers)
                .toggleStyle(.checkbox)
                .padding(12)
        }
    }

    var workspaceControls: some View {
        HStack(spacing: 6) {
            workspaceChoice
            stagedChoice
        }
    }

    var workspaceChoice: some View {
        DiffToolbarChoice(
            title: "Workspace",
            isSelected: isLocalSource,
            identifier: "log-diff-workspace",
            isEnabled: false,
            action: {}
        )
    }

    var stagedChoice: some View {
        DiffToolbarChoice(
            title: "Staged",
            isSelected: false,
            identifier: "log-diff-staged",
            isEnabled: false,
            action: {}
        )
    }

    var diffViewControls: some View {
        HStack(spacing: 6) {
            diffViewLabel
            sideBySideChoice
            unifiedChoice
        }
    }

    var diffViewLabel: some View {
        Text("Diff View")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    var sideBySideChoice: some View {
        DiffToolbarChoice(
            title: "Side-by-side",
            isSelected: presentationMode == .sideBySide,
            identifier: "log-diff-side-by-side",
            action: { presentationMode = .sideBySide }
        )
    }

    var unifiedChoice: some View {
        DiffToolbarChoice(
            title: "Unified",
            isSelected: presentationMode == .unified,
            identifier: "log-diff-unified",
            action: {
                presentationMode = .unified
                selectionMode = false
            }
        )
    }

    @ViewBuilder
    var revisionHeader: some View {
        HStack(spacing: 8) {
            if !baseRevisionLabel.isEmpty {
                Text("Old Version")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(baseRevisionLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Image(systemName: repositoryFileSymbol(for: record.change.path))
                .foregroundStyle(repositoryFileIconColor(for: record.change.path))
            Text(record.change.path)
                .font(.system(.subheadline, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(record.change.path)
            if case .local = source {
                Text("Compare with Local")
                    .font(.caption)
                    .foregroundStyle(Design.Colors.accent)
            }
            Spacer(minLength: 8)
            Text("New Version")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(targetRevisionLabel)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    @ViewBuilder
    var content: some View {
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
        } else if let fileDiff, showsPatch {
            ScrollView([.vertical, .horizontal]) {
                Text(logFilePatchText(record: record, fileDiff: fileDiff))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
        } else if let fileDiff {
            if fileDiff.binary && fileDiff.hunks.isEmpty {
                ContentUnavailableView(
                    "Binary File",
                    systemImage: "doc.zipper",
                    description: Text("Git reported a binary change for this path.")
                )
            } else if presentationMode == .unified {
                UnifiedDiffView(
                    fileDiff: fileDiff,
                    fullFile: fullFile,
                    activeDifference: activeDifference,
                    showsLineNumbers: showsLineNumbers
                )
            } else {
                SideBySideDiffView(
                    fileDiff: fileDiff,
                    fullFile: fullFile,
                    selectionMode: selectionMode,
                    selectedLines: selectedLines,
                    onToggleLine: toggleSelectedLine,
                    activeDifference: activeDifference,
                    showsLineNumbers: showsLineNumbers
                )
            }
        } else {
            ProgressView("Loading diff…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func toggleSelectedLine(_ line: SelectedDiffLine) {
        if selectedLines.contains(line) {
            selectedLines.remove(line)
        } else {
            selectedLines.insert(line)
        }
    }

    func moveDifference(_ offset: Int) {
        let count = differenceCount
        guard count > 0 else {
            activeDifference = nil
            return
        }
        if let activeDifference {
            self.activeDifference = min(max(activeDifference + offset, 0), count - 1)
        } else {
            self.activeDifference = offset > 0 ? 0 : count - 1
        }
    }

    func openExternalDiff() {
        guard let fullFile else {
            actionError = localizedArborString(
                "Full file contents are unavailable for an external diff.",
                locale: AppLanguage.interfaceLocale
            )
            return
        }
        let oldLines = fullFile.oldLines ?? []
        let newLines = fullFile.newLines ?? []
        let path = record.change.path
        Task.detached(priority: .userInitiated) {
            do {
                try ExternalDiffLauncher.launch(
                    oldLines: oldLines,
                    newLines: newLines,
                    path: path
                )
            } catch {
                await MainActor.run { actionError = "\(error)" }
            }
        }
    }

    func compareWithClipboard() {
        guard let targetLines = fullFile?.newLines else {
            actionError = localizedArborString(
                "Full file contents are unavailable for a clipboard comparison.",
                locale: AppLanguage.interfaceLocale
            )
            return
        }
        guard let clipboard = NSPasteboard.general.string(forType: .string),
              !clipboard.isEmpty else {
            actionError = localizedArborString(
                "The clipboard does not contain text.",
                locale: AppLanguage.interfaceLocale
            )
            return
        }
        let target = targetLines.joined(separator: "\n")
        Task.detached(priority: .userInitiated) {
            do {
                let diff = try TextDiffRunner.unifiedDiff(left: clipboard, right: target)
                await MainActor.run {
                    clipboardDiffText = diff
                    showsClipboardDiff = true
                }
            } catch {
                await MainActor.run { actionError = "\(error)" }
            }
        }
    }

    func loadBlameLines() async throws -> [BlameLine] {
        guard let repo = repositoryForCommit(record.commit) else {
            throw NSError(
                domain: "Arbor.Blame",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: localizedArborString(
                        "The repository for this change is no longer available.",
                        locale: AppLanguage.interfaceLocale
                    )
                ]
            )
        }
        let path = record.change.path
        switch source {
        case .commit:
            let commitID = record.commit.id
            return try await Task.detached(priority: .userInitiated) {
                try repo.blamePreviousRevision(
                    path: path,
                    commitId: commitID,
                    options: BlameOptions(
                        ignoreWhitespaces: false,
                        movement: .none,
                        preferCommitDate: true
                    )
                )
            }.value
        case .local:
            return try await Task.detached(priority: .userInitiated) {
                try repo.blameWorktree(path: path)
            }.value
        }
    }

    func load() {
        diffTask?.cancel()
        fileDiff = nil
        fullFile = nil
        diffError = nil
        activeDifference = nil
        selectedLines = []
        guard let repo = repositoryForCommit(record.commit) else {
            diffError = localizedArborString("The repository for this change is no longer available.", locale: AppLanguage.interfaceLocale)
            return
        }
        let commitID = record.commit.id
        let parentIndex = record.parentIndex
        let path = record.change.path
        // A rename's base side lives under the old path in the parent tree.
        let oldPath = record.change.oldPath ?? path
        let expectedID = record.id
        let expectedSource = source
        let expectedIdentity = requestIdentity
        let settings = makeArborGitDiffSettings(
            ignoreWhitespace: ignoreWhitespace,
            wordDiff: wordDiff,
            crlfSensitive: crlfSensitive
        )
        let baseRevision: String? = {
            guard case .commit = expectedSource else { return nil }
            if let parentIndex,
               record.commit.parentIds.indices.contains(Int(parentIndex)) {
                return record.commit.parentIds[Int(parentIndex)]
            }
            return record.commit.parentIds.first
        }()
        diffTask = Task.detached(priority: .userInitiated) {
            do {
                let diff: FileDiff
                switch expectedSource {
                case .commit:
                    diff = try repo.commitFileDiffWithSettings(
                        commitId: commitID,
                        parentIndex: parentIndex,
                        path: path,
                        settings: settings
                    )
                case let .local(revision):
                    diff = try repo.diffRevisionPathWithWorktreeWithSettings(
                        revision: revision,
                        revisionPath: path,
                        worktreePath: path,
                        settings: settings
                    )
                }

                // The reference diff viewer shows the complete file, not only
                // the hunks. Read both sides so unchanged lines between hunks
                // can be rendered continuously. Falls back to hunks when a
                // side is binary, truncated or unreadable.
                var loadedFullFile: FullFileDiff?
                if !diff.binary,
                   !settings.useExternalTextconv {
                    let oldContent: FileContent?
                    let newContent: FileContent?
                    switch expectedSource {
                    case .commit:
                        oldContent = baseRevision.flatMap {
                            try? repo.readRevisionFile(revision: $0, path: oldPath)
                        }
                        newContent = try? repo.readRevisionFile(revision: commitID, path: path)
                    case let .local(revision):
                        oldContent = try? repo.readRevisionFile(revision: revision, path: oldPath)
                        newContent = try? repo.readWorktreeFile(path: path)
                    }
                    let oldLines = oldContent.flatMap {
                        $0.binary || $0.truncated ? nil : fileTextLines($0.text)
                    }
                    let newLines = newContent.flatMap {
                        $0.binary || $0.truncated ? nil : fileTextLines($0.text)
                    }
                    if oldLines != nil || newLines != nil {
                        loadedFullFile = FullFileDiff(oldLines: oldLines, newLines: newLines)
                    }
                }

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.requestIdentity == expectedIdentity else { return }
                    self.fileDiff = diff
                    self.fullFile = loadedFullFile
                    self.selectedLines = []
                    // Open on the first difference like the reference diff
                    // viewer; on a large file this avoids landing on an
                    // unchanged page far above every change. Defer one run
                    // loop so the freshly created diff view observes the
                    // change and scrolls to its anchor.
                    if self.differenceCount > 0 {
                        DispatchQueue.main.async {
                            guard self.requestIdentity == expectedIdentity,
                                  self.activeDifference == nil else { return }
                            self.activeDifference = 0
                        }
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.requestIdentity == expectedIdentity else { return }
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
