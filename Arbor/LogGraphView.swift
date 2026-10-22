import SwiftUI
import AppKit


/// Git log 的图表列。它对应 IntelliJ 的 VcsLogGraphTable：
/// 图和提交信息是同一张可横向滚动的表，而不是一块固定宽度的装饰性 Canvas。
struct LogGraphView: View {
    let commits: [CommitInfo]
    @Binding var selection: String?
    @Binding var selectedIDs: Set<String>
    var rootQualifiedIdentity = false

    private func commitIdentity(_ commit: CommitInfo) -> String {
        logCommitDisplayIdentity(repositoryPath: commit.repositoryPath, id: commit.id, aggregate: rootQualifiedIdentity)
    }
    let compactReferences: Bool
    let showCommitColumns: Bool
    let showAuthorColumn: Bool
    let showDateColumn: Bool
    let showHashColumn: Bool
    let showRootColumn: Bool
    let showSignatureColumn: Bool
    let signatureStatuses: [String: CommitSignatureInfo]
    let signatureLoadingIDs: Set<String>
    let signatureFailedIDs: Set<String>
    let columnLayout: LogColumnLayout
    let showTagNames: Bool
    let alignLabels: Bool
    let showLongEdges: Bool
    let collapseGraph: Bool
    var graphCommand: LinearBekGraphCommand? = nil
    let highlightCherryPickedCommits: Bool
    var actionAvailability: LogActionAvailability = .permissive
    /// File History uses the narrower `Git.FileHistory.ContextMenu` action
    /// group. Keep it separate from the full VCS Log menu even though both
    /// views share the same graph/table renderer.
    var isFileHistory = false
    var onReachedEnd: () -> Void = {}
    var hasMore: Bool = false
    var isLoadingMore: Bool = false
    var pullRequestRemotesForCommit: (CommitInfo) -> [RemoteInfo] = { _ in [] }
    var onOpenPullRequest: (CommitInfo, RemoteInfo) -> Void = { _, _ in }
    var commentRemotesForCommit: (CommitInfo) -> [RemoteInfo] = { _ in [] }
    var onComment: (CommitInfo, RemoteInfo) -> Void = { _, _ in }
    var onCreateBranch: (CommitInfo) -> Void = { _ in }
    var onCreateTag: (CommitInfo) -> Void = { _ in }
    var onCherryPick: (CommitInfo) -> Void = { _ in }
    var onCherryPickSelected: ([CommitInfo]) -> Void = { _ in }
    var onRevert: (CommitInfo) -> Void = { _ in }
    var onRevertSelected: ([CommitInfo]) -> Void = { _ in }
    var onCheckout: (CommitInfo) -> Void = { _ in }
    var onReset: (CommitInfo) -> Void = { _ in }
    var onResetSelected: ([CommitInfo]) -> Void = { _ in }
    var onCompare: (CommitInfo) -> Void = { _ in }
    var currentBranchNameForCommit: (CommitInfo) -> String? = { _ in nil }
    var onReferenceAction: (CommitInfo, LogReferenceActionTarget, LogReferenceAction) -> Void = { _, _, _ in }
    var onRebaseOntoCommit: (CommitInfo) -> Void = { _ in }
    var onInteractiveRebase: (CommitInfo) -> Void = { _ in }
    var onCreateAutoSquashCommit: (CommitInfo, AutoSquashCommitKind) -> Void = { _, _ in }
    var onRewriteCommit: (CommitInfo, RebaseTodoAction) -> Void = { _, _ in }
    var onRewriteSelected: ([CommitInfo], RebaseTodoAction) -> Void = { _, _ in }
    var onPushUpToCommit: (CommitInfo) -> Void = { _ in }
    var onAddCommitsToRemoteBranch: ([CommitInfo]) -> Void = { _ in }
    var highlightedCherryPickedCommitIDs: Set<String> = []
    var cherryPickComparisonReady = false
    var hostedRemotesForCommit: (CommitInfo) -> [RemoteInfo] = { _ in [] }
    var onBrowseHostedRevision: (CommitInfo, RemoteInfo) -> Void = { _, _ in }
    var onBrowseRevision: (CommitInfo) -> Void = { _ in }
    var onCopyRevisionLink: (CommitInfo, RemoteInfo) -> Void = { _, _ in }
    var onUncommit: (CommitInfo) -> Void = { _ in }
    var onColumnOrderChanged: ([LogColumnID]) -> Void = { _ in }
    var onColumnWidthChanged: (LogColumnID, CGFloat) -> Void = { _, _ in }
    @State private var expandedLinearBekMergeIDs: Set<String> = []
    @State private var collapsedLinearBekMergeIDs: Set<String> = []
    @State private var hoveredLinearBekElement: LinearBekGraphElement?
    @State private var hoveredLinearBekHighlight: LinearBekGraphHighlight?
    @State private var resizingColumn: LogColumnID?
    @State private var resizeStartWidth: CGFloat?
    /// Topmost visible row of the vertical history scroll view. Drives the
    /// render window for the Canvas and the graph hit-target overlays.
    @State private var scrolledRowID: Int?
    @State private var linearBekGraphCache = LinearBekGraphCache()

    private func resolvedLinearBekGraph() -> LinearBekGraphSnapshot {
        linearBekGraphCache.resolve(
            commits: commits,
            collapseAll: collapseGraph,
            expandedMergeIDs: expandedLinearBekMergeIDs,
            collapsedMergeIDs: collapsedLinearBekMergeIDs,
            rootQualifiedIdentity: rootQualifiedIdentity
        )
    }

    // Rebased keeps the log dense enough to scan dozens of commits at once.
    // The old 58pt rows made the graph look like a card list and diverged
    // visibly from the reference workspace.
    private let rowHeight: CGFloat = 31
    // Rebased keeps a real graph gutter in front of the commit table. It is
    // deliberately wide enough for merge-heavy histories: collapsing this
    // column to a tiny decoration makes all branches look like one line and
    // also puts the filter controls in the wrong visual column.
    // IntelliJ's graph column grows with the permanent graph. Capping it at
    // 180pt collapses merge-heavy histories into an apparent single line and
    // makes the commit text start on top of the lanes. Keep enough room for
    // the dense histories used by rebased; the surrounding table remains
    // horizontally scrollable when a repository has even more active lanes.
    private let laneWidth: CGFloat = 18
    private let maximumGraphWidth: CGFloat = 360
    private let minimumCommitColumnWidth: CGFloat = 276
    private let preferredTableWidth: CGFloat = 720
    private let columnHeaderHeight: CGFloat = 28

    private enum RefKind {
        case head
        case local
        case tag
        case remote

        var foreground: Color {
            switch self {
            case .head: .white
            case .local: .orange
            case .tag: .green
            case .remote: .blue
            }
        }

        var background: Color {
            switch self {
            case .head: .blue.opacity(0.78)
            case .local: .orange.opacity(0.16)
            case .tag: .green.opacity(0.16)
            case .remote: .blue.opacity(0.16)
            }
        }

        var border: Color {
            switch self {
            case .head: .blue.opacity(0.95)
            case .local: .orange.opacity(0.36)
            case .tag: .green.opacity(0.36)
            case .remote: .blue.opacity(0.36)
            }
        }
    }

    @ViewBuilder
    private func fileHistoryContextMenu(for commit: CommitInfo) -> some View {
        let hasSingleLogSelection = selectedIDs.count <= 1
        let contextSelectionCount = max(selectedIDs.count, 1)
        let selectedCommits = commits.filter { selectedIDs.contains(commitIdentity($0)) }
        let commitsForRevert = selectedCommits.count > 1 ? selectedCommits : [commit]
        if selectedCommits.count > 1, selectedIDs.contains(commitIdentity(commit)) {
            Button("Revert Selected Commits") {
                onRevertSelected(commitsForRevert)
            }
            .disabled(
                commitsForRevert.contains { $0.parentIds.count != 1 }
                    || !actionAvailability.allowsMutation(for: commitsForRevert)
            )
        } else {
            Button("Revert Commit") { onRevert(commit) }
                .disabled(
                    commit.parentIds.count != 1
                        || !actionAvailability.allowsMutation(for: [commit])
                )
        }
        Button("Create Fixup Commit…") { onCreateAutoSquashCommit(commit, .fixup) }
            .disabled(
                !hasSingleLogSelection
                    || !actionAvailability.hasLocalChanges
                    || !isLogRewriteActionAvailable(for: commit, action: .fixup)
                    || !actionAvailability.allowsHistoryRewrite(for: [commit])
            )
        Button("Create Squash Commit…") { onCreateAutoSquashCommit(commit, .squash) }
            .disabled(
                !hasSingleLogSelection
                    || !actionAvailability.hasLocalChanges
                    || !isLogRewriteActionAvailable(for: commit, action: .squash)
                    || !actionAvailability.allowsHistoryRewrite(for: [commit])
            )
        Divider()
        Button("Create Tag at Commit…") { onCreateTag(commit) }
            .disabled(!isLogSingleCommitActionAvailable(
                selectionCount: contextSelectionCount,
                for: commit
            ))
    }

    private struct RefLabel: Identifiable {
        let id: String
        let title: String
        let kind: RefKind
    }

    /// 留出左右边距，lane 数增多时只在极端历史上轻微压缩 lane 间距。
    /// `maxLane` 现在随图模型一起缓存，不再每次 body 求值都对全部
    /// 提交做一次 reduce。
    private func graphWidth(maxLane: Int) -> CGFloat {
        min(
            maximumGraphWidth,
            max(120, CGFloat(maxLane + 1) * effectiveLaneWidth(maxLane: maxLane) + 28)
        )
    }

    private func effectiveLaneWidth(maxLane: Int) -> CGFloat {
        max(
            8,
            min(laneWidth, (maximumGraphWidth - 32) / CGFloat(maxLane + 1))
        )
    }

    var body: some View {
        // The graph model is memoized across body evaluations (see
        // resolvedLinearBekGraph): it is only rebuilt when the commit list
        // or the collapse state actually changes, not on every hover,
        // selection, or scroll tick.
        let resolvedGraph = resolvedLinearBekGraph()
        let linearBekGraph = resolvedGraph.controller.graph
        // LinearBek collapses edges, not the graph column. The gutter remains
        // interactive so a merge node or dotted edge can be restored.
        let layoutGraphWidth = graphWidth(maxLane: resolvedGraph.maxLane)
        let layoutGraphHeight = max(rowHeight, CGFloat(commits.count) * rowHeight)
        let laneSpacing = effectiveLaneWidth(maxLane: resolvedGraph.maxLane)

        // A ScrollView directly inside the resizable tool window can be
        // measured with an unbounded height. In that case SwiftUI lays out
        // the content, but the viewport itself ends up outside the visible
        // tool-window region. Give it a real viewport first, then let the
        // history content scroll inside it.
        GeometryReader { viewport in
            // The reference log is one horizontally scrollable table. The
            // table must at least fill the visible graph workspace so the
            // selection highlight, row hit target, and commit column reach
            // the graph/details divider instead of stopping at an arbitrary
            // fixed width.
            let visibleColumns = columnLayout.visibleOrder(
                showAuthor: showAuthorColumn || showCommitColumns,
                showDate: showDateColumn || showCommitColumns,
                showHash: showHashColumn,
                showRoot: showRootColumn,
                showSignature: showSignatureColumn
            )
            let dynamicColumnWidth = visibleColumns
                .filter { $0 != .commit }
                .reduce(CGFloat.zero) { $0 + columnLayout.width(for: $1) }
            let configuredCommitWidth = max(
                minimumCommitColumnWidth,
                columnLayout.width(for: .commit)
            )
            let layoutCommitColumnWidth = max(
                configuredCommitWidth,
                viewport.size.width - layoutGraphWidth - dynamicColumnWidth - 24
            )
            let layoutContentWidth = max(
                viewport.size.width,
                preferredTableWidth,
                layoutGraphWidth + layoutCommitColumnWidth + dynamicColumnWidth + 24
            )
            // Keep the deterministic pagination fallback inside the
            // scrollable content. The old height ended at the last row and
            // clipped the button below the LazyVStack.
            let layoutContentHeight = layoutGraphHeight + (hasMore ? 36 : 0)
            let verticalViewportHeight = max(0, viewport.size.height - columnHeaderHeight)

            // The Canvas and the graph hit-target overlays only cover a
            // window around the visible rows instead of the entire history.
            // The old `renderRange` was hardcoded to `0..<commits.count`,
            // which forced SwiftUI to create one hit-target view per graph
            // edge and node for the whole repository and made the Canvas
            // re-stroke every edge on each hover highlight.
            let visibleRowCount = max(1, Int(ceil(verticalViewportHeight / rowHeight)) + 1)
            let renderWindowBuffer = max(visibleRowCount, 32)
            let firstVisibleRow = min(max(0, scrolledRowID ?? 0), max(0, commits.count - 1))
            let renderWindowLower = max(0, firstVisibleRow - renderWindowBuffer)
            let renderWindowUpper = min(commits.count, firstVisibleRow + visibleRowCount + renderWindowBuffer)
            let renderWindow = renderWindowLower..<renderWindowUpper
            let renderWindowOriginY = CGFloat(renderWindowLower) * rowHeight
            let renderWindowHeight = max(rowHeight, CGFloat(renderWindow.count) * rowHeight)

            ScrollView(.horizontal, showsIndicators: true) {
                VStack(spacing: 0) {
                    logColumnHeader(
                        graphWidth: layoutGraphWidth,
                        commitColumnWidth: layoutCommitColumnWidth,
                        contentWidth: layoutContentWidth,
                        visibleColumns: visibleColumns
                    )

                    ScrollView(.vertical) {
                        ZStack(alignment: .topLeading) {
                            Canvas { context, _ in
                                drawGraph(
                                    context: &context,
                                    size: CGSize(width: layoutGraphWidth, height: renderWindowHeight),
                                    rows: renderWindow,
                                    originY: renderWindowOriginY,
                                    laneSpacing: laneSpacing,
                                    commitIDs: resolvedGraph.commitIDs,
                                    graph: linearBekGraph,
                                    highlight: hoveredLinearBekHighlight
                                )
                            }
                            .frame(width: layoutGraphWidth, height: renderWindowHeight)
                            .offset(y: renderWindowOriginY)
                            .allowsHitTesting(false)

                            LazyVStack(spacing: 0) {
                                ForEach(commits.indices, id: \.self) { index in
                                    graphRow(
                                        commit: commits[index],
                                        graphWidth: layoutGraphWidth,
                                        commitColumnWidth: layoutCommitColumnWidth,
                                        contentWidth: layoutContentWidth,
                                        visibleColumns: visibleColumns,
                                        showTagNames: showTagNames,
                                        alignLabels: alignLabels,
                                        rowAction: linearBekGraph.rowAction(at: index),
                                        onRowGraphAction: applyLinearBekRowAction
                                    )
                                    .onAppear {
                                        // Rebased fetches the next log block as
                                        // the last visible row enters the lazy
                                        // list. Keep the button below as a
                                        // deterministic fallback for keyboard
                                        // navigation and accessibility clients.
                                        if index == commits.count - 1,
                                           hasMore,
                                           !isLoadingMore {
                                            onReachedEnd()
                                        }
                                    }
                                }
                                if hasMore {
                                    HStack {
                                        Spacer()
                                        Button {
                                            onReachedEnd()
                                        } label: {
                                            if isLoadingMore {
                                                ProgressView()
                                                    .controlSize(.small)
                                            } else {
                                                Text("加载更多提交")
                                            }
                                        }
                                        .buttonStyle(.borderless)
                                        .disabled(isLoadingMore)
                                        Spacer()
                                    }
                                    .frame(width: layoutContentWidth, height: 36)
                                    // Keep the pagination row inside the
                                    // Int identity space so the render
                                    // window stays anchored at the end of
                                    // the history when it becomes the
                                    // topmost scroll target.
                                    .id(commits.count)
                                }
                            }
                            .scrollTargetLayout()

                            linearBekEdgeHitTargets(
                                graph: linearBekGraph,
                                rows: renderWindow,
                                originY: renderWindowOriginY,
                                laneSpacing: laneSpacing,
                                graphWidth: layoutGraphWidth,
                                height: renderWindowHeight
                            )
                            .offset(y: renderWindowOriginY)

                            linearBekNodeHitTargets(
                                graph: linearBekGraph,
                                rows: renderWindow,
                                originY: renderWindowOriginY,
                                laneSpacing: laneSpacing,
                                graphWidth: layoutGraphWidth,
                                height: renderWindowHeight
                            )
                            .offset(y: renderWindowOriginY)
                        }
                        .frame(width: layoutContentWidth, height: layoutContentHeight, alignment: .topLeading)
                    }
                    .scrollPosition(id: $scrolledRowID)
                    .frame(width: layoutContentWidth, height: verticalViewportHeight)
                }
                .frame(width: layoutContentWidth, height: viewport.size.height, alignment: .top)
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .onChange(of: ObjectIdentifier(resolvedGraph)) { _, _ in
            hoveredLinearBekHighlight = nil
            hoveredLinearBekElement = nil
            expandedLinearBekMergeIDs.formIntersection(resolvedGraph.mergeIDs)
            collapsedLinearBekMergeIDs.formIntersection(resolvedGraph.mergeIDs)
        }
        .onChange(of: collapseGraph) { _, _ in
            // The menu toggle is the product's global Collapse Graph action.
            // Do not resurrect stale per-fragment state when the user turns
            // that global mode off again; IntelliJ's Expand All action leaves
            // the graph fully expanded.
            expandedLinearBekMergeIDs.removeAll()
            collapsedLinearBekMergeIDs.removeAll()
            hoveredLinearBekHighlight = nil
            hoveredLinearBekElement = nil
        }
        .onChange(of: graphCommand) { _, command in
            guard let command else { return }
            let controller = resolvedLinearBekGraph().controller
            let answer = controller.perform(
                LinearBekGraphAction(
                    type: command.action,
                    affectedElement: nil
                )
            )
            expandedLinearBekMergeIDs = answer.expandedMergeIDs
            collapsedLinearBekMergeIDs = answer.collapsedMergeIDs
            hoveredLinearBekHighlight = nil
            hoveredLinearBekElement = nil
        }
    }

    private func logColumnHeader(
        graphWidth: CGFloat,
        commitColumnWidth: CGFloat,
        contentWidth: CGFloat,
        visibleColumns: [LogColumnID]
    ) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: graphWidth)
            HStack(spacing: 6) {
                ForEach(visibleColumns) { column in
                    logColumnHeaderCell(
                        column,
                        width: column == .commit ? commitColumnWidth : columnLayout.width(for: column)
                    )
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(width: contentWidth, height: columnHeaderHeight, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func logColumnHeaderCell(_ column: LogColumnID, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(column.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: column == .date || column == .hash ? .trailing : .leading)
                .contentShape(Rectangle())
                .draggable(column.rawValue)

            Rectangle()
                .fill(Color.clear)
                .frame(width: 8)
                .contentShape(Rectangle())
                .allowsHitTesting(column.isResizable)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            guard column.isResizable else { return }
                            if resizingColumn != column {
                                resizingColumn = column
                                resizeStartWidth = width
                            }
                            let start = resizeStartWidth ?? width
                            onColumnWidthChanged(column, max(column.minimumWidth, start + value.translation.width))
                        }
                        .onEnded { _ in
                            resizingColumn = nil
                            resizeStartWidth = nil
                        }
                )
        }
        .frame(width: width, height: columnHeaderHeight)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.secondary.opacity(0.24))
                .frame(width: 1, height: 16)
                .allowsHitTesting(false)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let rawValue = items.first,
                  let source = LogColumnID(rawValue: rawValue),
                  source != column else { return false }
            onColumnOrderChanged(columnLayout.moving(source, before: column).order)
            return true
        }
    }

    @ViewBuilder
    private func graphRow(
        commit: CommitInfo,
        graphWidth: CGFloat,
        commitColumnWidth: CGFloat,
        contentWidth: CGFloat,
        visibleColumns: [LogColumnID],
        showTagNames: Bool,
        alignLabels: Bool,
        rowAction: LinearBekRowAction?,
        onRowGraphAction: @escaping (LinearBekRowAction) -> Void
    ) -> some View {
        let identity = commitIdentity(commit)
        let isCherryPicked = isCherryPickedCommitHighlighted(
            highlightingEnabled: highlightCherryPickedCommits,
            comparisonReady: cherryPickComparisonReady,
            identity: identity,
            highlightedCommitIDs: highlightedCherryPickedCommitIDs
        )
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: graphWidth)
                HStack(spacing: 6) {
                    ForEach(visibleColumns) { column in
                        logColumnView(
                            column,
                            commit: commit,
                            commitWidth: commitColumnWidth,
                            showTagNames: showTagNames,
                            alignLabels: alignLabels
                        )
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(width: contentWidth, height: rowHeight, alignment: .leading)

            // IntelliJ treats the graph and commit summary as one table row.
            // Keep exactly one selection gesture for the whole row. The old
            // split implementation had an `onTapGesture` on the summary plus
            // a transparent Button over the graph; Cmd-clicking a lane could
            // therefore toggle the same commit twice and cancel the selection.
            Button {
                select(commit)
            } label: {
                Color.clear
                    .frame(width: contentWidth, height: rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Select commit \(commit.shortId)")
            // Announce the row as selected: VoiceOver users need the current
            // commit, and automation needs to tell "already selected" apart
            // from "clicked and nothing happened".
            .accessibilityAddTraits(selectedIDs.contains(identity) ? .isSelected : [])

            if let action = rowAction {
                Button {
                    onRowGraphAction(action)
                } label: {
                    Image(systemName: action.isCollapse ? "chevron.down.circle.fill" : "chevron.up.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: graphWidth, height: rowHeight, alignment: .center)
                }
                .buttonStyle(.plain)
                .help(action.isCollapse ? "Collapse linear branch" : "Expand collapsed branch")
                .accessibilityLabel(action.isCollapse ? "Collapse linear branch" : "Expand collapsed branch")
            }
        }
        .frame(width: contentWidth, height: rowHeight, alignment: .leading)
        .background(
            selectedIDs.contains(identity)
                ? Color.accentColor.opacity(0.14)
                : isCherryPicked ? Color.purple.opacity(0.13) : Color.clear
        )
        .overlay(alignment: .leading) {
            if isCherryPicked {
                Capsule()
                    .fill(Color.purple.opacity(0.8))
                    .frame(width: 3, height: rowHeight - 8)
                    .padding(.leading, 2)
                    .help("Cherry-picked commit")
                    .allowsHitTesting(false)
            }
        }
        .contextMenu {
            if isFileHistory {
                fileHistoryContextMenu(for: commit)
            } else {
            let hasSingleLogSelection = selectedIDs.count <= 1
            // A row context menu can open before the table publishes the row
            // selection. IntelliJ's VCS Log still supplies the contextual row
            // as the single commit in that case.
            let contextSelectionCount = max(selectedIDs.count, 1)
            let currentBranchName = hasSingleLogSelection
                ? currentBranchNameForCommit(commit)
                : nil
            let checkoutBranchTargets = hasSingleLogSelection
                ? logCheckoutBranchTargets(
                    for: commit,
                    currentBranchName: currentBranchName
                )
                : []
            let checkoutRevisionAvailable = hasSingleLogSelection
                && logReferenceRootPath(for: commit) != nil
                && actionAvailability.allowsMutation(for: [commit])
            Button("View Commit Details") { select(commit, modifiers: []) }
            Button("Copy Commit ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.id, forType: .string)
            }
            Button("Copy Commit Message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.summary, forType: .string)
            }
            Button("Create Branch from Commit") { onCreateBranch(commit) }
                .disabled(!isLogSingleCommitActionAvailable(
                    selectionCount: contextSelectionCount,
                    for: commit
                ))
            Button("Create Tag at Commit…") { onCreateTag(commit) }
                .disabled(!isLogSingleCommitActionAvailable(
                    selectionCount: contextSelectionCount,
                    for: commit
                ))
            if hasSingleLogSelection {
                let referenceTargets = logReferenceActionTargets(
                    for: commit,
                    currentBranchName: currentBranchName
                )
                let branchTargets = referenceTargets.filter { $0.kind != .tag }
                let tagTargets = referenceTargets.filter { $0.kind == .tag }
                let referenceActionsRoutable = logReferenceRootPath(for: commit) != nil
                let referenceMutationAvailable = referenceActionsRoutable
                    && actionAvailability.allowsMutation(for: [commit])
                let referenceHistoryRewriteAvailable = referenceActionsRoutable
                    && actionAvailability.allowsHistoryRewrite(for: [commit])
                if !branchTargets.isEmpty || !tagTargets.isEmpty {
                    Divider()
                }
                if !branchTargets.isEmpty {
                    Menu("Branches") {
                        ForEach(branchTargets) { target in
                            Menu(target.name) {
                                Button("Checkout") {
                                    onReferenceAction(commit, target, .checkout)
                                }
                                .disabled(!referenceMutationAvailable)
                                if target.kind == .local {
                                    Button("Checkout and Update") {
                                        onReferenceAction(commit, target, .checkoutAndUpdate)
                                    }
                                    .disabled(!referenceMutationAvailable)
                                }
                                Button("Checkout with Rebase") {
                                    onReferenceAction(commit, target, .checkoutWithRebase)
                                }
                                .disabled(!referenceMutationAvailable)
                                Button("Checkout as New Branch…") {
                                    onCreateBranch(commit)
                                }
                                .disabled(!referenceMutationAvailable)
                                Divider()
                                Button("Compare with Current…") {
                                    onReferenceAction(commit, target, .compare)
                                }
                                .disabled(!referenceActionsRoutable)
                                Button("Show Diff with Working Tree") {
                                    onReferenceAction(commit, target, .showDiff)
                                }
                                .disabled(!referenceActionsRoutable)
                                Divider()
                                Button("Rebase Current onto…") {
                                    onReferenceAction(commit, target, .rebase)
                                }
                                .disabled(!referenceHistoryRewriteAvailable)
                                Button("Merge into Current…") {
                                    onReferenceAction(commit, target, .merge)
                                }
                                .disabled(!referenceMutationAvailable)
                                if target.kind == .local {
                                    Divider()
                                    Button("Update") {
                                        onReferenceAction(commit, target, .update)
                                    }
                                    .disabled(!referenceMutationAvailable)
                                    Button("Push…") {
                                        onReferenceAction(commit, target, .push)
                                    }
                                    .disabled(!referenceMutationAvailable)
                                    Divider()
                                    Button("Rename…") {
                                        onReferenceAction(commit, target, .rename)
                                    }
                                    .disabled(!referenceMutationAvailable)
                                } else {
                                    Divider()
                                    Button("Pull with Merge") {
                                        onReferenceAction(commit, target, .pullMerge)
                                    }
                                    .disabled(!referenceMutationAvailable)
                                    Button("Pull with Rebase") {
                                        onReferenceAction(commit, target, .pullRebase)
                                    }
                                    .disabled(!referenceMutationAvailable)
                                }
                                Button("Delete", role: .destructive) {
                                    onReferenceAction(commit, target, .delete)
                                }
                                .disabled(!referenceMutationAvailable)
                            }
                        }
                    }
                } else if referenceActionsRoutable {
                    Button("Rebase Current onto Selected Commit…") {
                        onRebaseOntoCommit(commit)
                    }
                    .disabled(
                        !isLogRebaseOntoSelectedCommitAvailable(
                            selectionCount: contextSelectionCount,
                            for: commit,
                            currentBranchName: currentBranchNameForCommit(commit)
                        ) || !referenceHistoryRewriteAvailable
                    )
                }
                if !tagTargets.isEmpty {
                    Menu("Tags") {
                        ForEach(tagTargets) { target in
                            Menu(target.name) {
                                Button("Merge into Current…") {
                                    onReferenceAction(commit, target, .merge)
                                }
                                .disabled(!referenceMutationAvailable)
                                Button("Delete Tag", role: .destructive) {
                                    onReferenceAction(commit, target, .delete)
                                }
                                .disabled(!referenceMutationAvailable)
                            }
                        }
                    }
                }
            }
            if checkoutBranchTargets.isEmpty {
                Button("Checkout Revision \(commit.shortId)") {
                    onCheckout(commit)
                }
                .disabled(!checkoutRevisionAvailable)
            } else {
                Menu("Checkout") {
                    ForEach(checkoutBranchTargets) { target in
                        Button(target.name) {
                            onReferenceAction(commit, target, .checkout)
                        }
                        .disabled(!checkoutRevisionAvailable)
                    }
                    Divider()
                    Button("Checkout Revision \(commit.shortId)") {
                        onCheckout(commit)
                    }
                    .disabled(!checkoutRevisionAvailable)
                }
            }
            Divider()
            Button("Cherry-pick") { onCherryPick(commit) }
                .disabled(!actionAvailability.allowsMutation(for: [commit]))
            Button("Revert Commit") { onRevert(commit) }
                .disabled(
                    commit.parentIds.count != 1
                        || !actionAvailability.allowsMutation(for: [commit])
                )
            if selectedIDs.count > 1, selectedIDs.contains(identity) {
                let selectedCommits = commits.filter { selectedIDs.contains(commitIdentity($0)) }
                Button("Cherry-pick Selected Commits") {
                    onCherryPickSelected(selectedCommits)
                }
                .disabled(!actionAvailability.allowsMutation(for: selectedCommits))
                Button("Revert Selected Commits") {
                    onRevertSelected(selectedCommits)
                }
                .disabled(
                    selectedCommits.contains { $0.parentIds.count != 1 }
                        || !actionAvailability.allowsMutation(for: selectedCommits)
                )
            }
            Button("Reset Current Branch to Here…") { onReset(commit) }
                .disabled(!actionAvailability.allowsMutation(for: [commit]))
            if selectedIDs.count > 1, selectedIDs.contains(identity) {
                let selectedCommits = commits.filter { selectedIDs.contains(commitIdentity($0)) }
                Button("Reset Selected Revisions…") {
                    onResetSelected(selectedCommits)
                }
                .disabled(
                    !isResetSelectionAvailable(for: selectedCommits)
                        || !actionAvailability.allowsMutation(for: selectedCommits)
                )
            }
            Button("Compare with Current…") { onCompare(commit) }
            Divider()
            Button("Interactive Rebase from Here…") { onInteractiveRebase(commit) }
                .disabled(
                    !hasSingleLogSelection
                        || !isInteractiveRebaseAvailable(for: commit)
                        || !actionAvailability.allowsHistoryRewrite(for: [commit])
                )
            Divider()
            Button("Reword Commit…") { onRewriteCommit(commit, .reword) }
                .disabled(
                    !hasSingleLogSelection
                        || !isLogRewriteActionAvailable(for: commit, action: .reword)
                        || !actionAvailability.allowsHistoryRewrite(for: [commit])
                )
            Button("Create Fixup Commit…") { onCreateAutoSquashCommit(commit, .fixup) }
                .disabled(
                    !hasSingleLogSelection
                        || !actionAvailability.hasLocalChanges
                        || !isLogRewriteActionAvailable(for: commit, action: .fixup)
                        || !actionAvailability.allowsHistoryRewrite(for: [commit])
                )
            Button("Create Squash Commit…") { onCreateAutoSquashCommit(commit, .squash) }
                .disabled(
                    !hasSingleLogSelection
                        || !actionAvailability.hasLocalChanges
                        || !isLogRewriteActionAvailable(for: commit, action: .squash)
                        || !actionAvailability.allowsHistoryRewrite(for: [commit])
                )
            Button("Rewrite Selected Commit as Fixup…") { onRewriteCommit(commit, .fixup) }
                .disabled(
                    !hasSingleLogSelection
                        || !isLogRewriteActionAvailable(for: commit, action: .fixup)
                        || !actionAvailability.allowsHistoryRewrite(for: [commit])
                )
            Button("Rewrite Selected Commit as Squash…") { onRewriteCommit(commit, .squash) }
                .disabled(
                    !hasSingleLogSelection
                        || !isLogRewriteActionAvailable(for: commit, action: .squash)
                        || !actionAvailability.allowsHistoryRewrite(for: [commit])
                )
            Button("Drop Commit…", role: .destructive) { onRewriteCommit(commit, .drop) }
                .disabled(
                    !hasSingleLogSelection
                        || !isLogRewriteActionAvailable(for: commit, action: .drop)
                        || !actionAvailability.allowsHistoryRewrite(for: [commit])
                )
            if selectedIDs.count > 1, selectedIDs.contains(identity) {
                let selectedCommits = commits.filter { selectedIDs.contains(commitIdentity($0)) }
                let batchRewriteAvailable = areLogRewriteSelectionActionsAvailable(for: selectedCommits)
                    && actionAvailability.allowsSingleRootHistoryRewrite(for: selectedCommits)
                Divider()
                Button("Reword Selected Commits…") {
                    onRewriteSelected(selectedCommits, .reword)
                }
                .disabled(!batchRewriteAvailable)
                Button("Squash Selected Commits…") {
                    onRewriteSelected(selectedCommits, .squash)
                }
                .disabled(!batchRewriteAvailable)
                Button("Drop Selected Commits…", role: .destructive) {
                    onRewriteSelected(selectedCommits, .drop)
                }
                .disabled(!batchRewriteAvailable)
            }
            Divider()
            Button("Push Up to Commit…") { onPushUpToCommit(commit) }
                .disabled(
                    !hasSingleLogSelection
                        || !actionAvailability.allowsMutation(for: [commit])
                )
            let selectedCommitsForRemoteBranch = selectedIDs.contains(identity)
                ? commits.filter { selectedIDs.contains(commitIdentity($0)) }
                : [commit]
            Button("Add Commits to Remote Branch…") {
                onAddCommitsToRemoteBranch(selectedCommitsForRemoteBranch)
            }
            .disabled(
                !isAddCommitsToRemoteBranchAvailable(for: selectedCommitsForRemoteBranch)
                    || !actionAvailability.allowsAddCommitsToRemote(for: selectedCommitsForRemoteBranch)
            )
            Button("Browse Repository at Revision") { onBrowseRevision(commit) }
            let hostedRemotes = hostedRemotesForCommit(commit)
            switch hostedRemoteActionPresentation(for: hostedRemotes.count) {
            case .direct where hostedRemotes.count == 1:
                let remote = hostedRemotes[0]
                Button("Open in Browser") { onBrowseHostedRevision(commit, remote) }
                Button("Copy Repository Link") { onCopyRevisionLink(commit, remote) }
            case .submenu:
                Menu("Open in Browser") {
                    ForEach(hostedRemotes, id: \.name) { remote in
                        Button(remote.name) {
                            onBrowseHostedRevision(commit, remote)
                        }
                    }
                }
                Menu("Copy Repository Link") {
                    ForEach(hostedRemotes, id: \.name) { remote in
                        Button(remote.name) {
                            onCopyRevisionLink(commit, remote)
                        }
                    }
                }
            case .direct, .hidden:
                EmptyView()
            }
            if commit.isHead {
                Divider()
                Button("Undo Latest Commit…", role: .destructive) { onUncommit(commit) }
                    .disabled(
                        !hasSingleLogSelection
                            || !isUncommitActionAvailable(for: commit)
                            || !actionAvailability.allowsMutation(for: [commit])
                    )
            }
            Divider()
            let pullRequestRemotes = pullRequestRemotesForCommit(commit)
            switch hostedRemoteActionPresentation(for: pullRequestRemotes.count) {
            case .direct where pullRequestRemotes.count == 1:
                Button("Open Pull Requests") {
                    onOpenPullRequest(commit, pullRequestRemotes[0])
                }
            case .submenu:
                Menu("Open Pull Requests") {
                    ForEach(pullRequestRemotes, id: \.name) { remote in
                        Button(remote.name) {
                            onOpenPullRequest(commit, remote)
                        }
                    }
                }
            case .direct, .hidden:
                EmptyView()
            }
            let commentRemotes = commentRemotesForCommit(commit)
            switch hostedRemoteActionPresentation(for: commentRemotes.count) {
            case .direct where commentRemotes.count == 1:
                Button("Comment this commit") {
                    onComment(commit, commentRemotes[0])
                }
            case .submenu:
                Menu("Comment this commit") {
                    ForEach(commentRemotes, id: \.name) { remote in
                        Button(remote.name) {
                            onComment(commit, remote)
                        }
                    }
                }
            case .direct, .hidden:
                EmptyView()
            }
            }
        }
    }

    /// Hit targets only exist for the rows of the current render window, so
    /// the overlay stays small no matter how large the history is. Point
    /// coordinates are local to the window (`originY`); the caller positions
    /// the overlay at the window's vertical offset.
    @ViewBuilder
    private func linearBekNodeHitTargets(
        graph: LinearBekGraphModel,
        rows: Range<Int>,
        originY: CGFloat,
        laneSpacing: CGFloat,
        graphWidth: CGFloat,
        height: CGFloat
    ) -> some View {
        ZStack {
            ForEach(rows.filter { graph.nodeAction(at: $0) != nil }, id: \.self) { row in
                let element = LinearBekGraphElement.node(row)
                Circle()
                    .fill(Color.clear)
                    .frame(width: 18, height: 18)
                    .contentShape(Circle())
                    .position(point(lane: commits[row].lane, row: row, laneSpacing: laneSpacing, originY: originY))
                    .onHover { isHovering in
                        updateHoveredLinearBekElement(element, isHovering: isHovering)
                    }
                    .onTapGesture {
                        applyLinearBekElement(element)
                    }
            }
        }
        .frame(width: graphWidth, height: height)
    }

    @ViewBuilder
    private func linearBekEdgeHitTargets(
        graph: LinearBekGraphModel,
        rows: Range<Int>,
        originY: CGFloat,
        laneSpacing: CGFloat,
        graphWidth: CGFloat,
        height: CGFloat
    ) -> some View {
        // Keep every edge whose span crosses the window, not only edges with
        // both endpoints inside it: a long edge must stay clickable while it
        // passes through the visible gutter.
        ZStack {
            ForEach(graph.visibleEdges.filter {
                edgeSpans($0.upRow, $0.downRow, intersect: rows) && (showLongEdges || rows.contains($0.downRow))
            }, id: \.self) { edge in
                graphEdgeHitTarget(
                    element: .normal(edge),
                    start: point(lane: edge.fromLane, row: edge.upRow, laneSpacing: laneSpacing, originY: originY),
                    target: point(lane: edge.toLane, row: edge.downRow, laneSpacing: laneSpacing, originY: originY)
                )
            }
            ForEach(graph.dottedEdges.filter { edgeSpans($0.upRow, $0.downRow, intersect: rows) }, id: \.self) { edge in
                graphEdgeHitTarget(
                    element: .dotted(edge),
                    start: point(lane: edge.fromLane, row: edge.upRow, laneSpacing: laneSpacing, originY: originY),
                    target: point(lane: edge.toLane, row: edge.downRow, laneSpacing: laneSpacing, originY: originY)
                )
            }
        }
        .frame(width: graphWidth, height: height)
    }

    private func edgeSpans(_ upRow: Int, _ downRow: Int, intersect rows: Range<Int>) -> Bool {
        min(upRow, downRow) < rows.upperBound && max(upRow, downRow) >= rows.lowerBound
    }

    private func graphEdgeHitTarget(
        element: LinearBekGraphElement,
        start: CGPoint,
        target: CGPoint
    ) -> some View {
        let hitStyle = StrokeStyle(lineWidth: 14, lineCap: .round, lineJoin: .round)
        let path = graphEdgePath(start: start, target: target)
        return path
            .stroke(Color.clear, style: hitStyle)
            .contentShape(path.strokedPath(hitStyle))
            .onHover { isHovering in
                updateHoveredLinearBekElement(element, isHovering: isHovering)
            }
            .onTapGesture {
                applyLinearBekElement(element)
            }
    }

    /// Event handlers resolve the cached controller at event time; hover and
    /// tap must never rebuild the graph just to answer an action.
    private func updateHoveredLinearBekElement(
        _ element: LinearBekGraphElement,
        isHovering: Bool
    ) {
        if isHovering {
            let answer = resolvedLinearBekGraph().controller.perform(
                LinearBekGraphAction(type: .mouseOver, affectedElement: element)
            )
            hoveredLinearBekElement = element
            hoveredLinearBekHighlight = answer.highlight
        } else if hoveredLinearBekElement == element {
            hoveredLinearBekElement = nil
            hoveredLinearBekHighlight = nil
        }
    }

    private func applyLinearBekElement(_ element: LinearBekGraphElement) {
        let controller = resolvedLinearBekGraph().controller
        applyLinearBekAction(controller.graph.action(for: element), controller: controller)
    }

    private func applyLinearBekRowAction(_ action: LinearBekRowAction) {
        applyLinearBekAction(action, controller: resolvedLinearBekGraph().controller)
    }

    private func applyLinearBekAction(
        _ action: LinearBekRowAction?,
        controller: LinearBekGraphController
    ) {
        guard let action else { return }
        let answer = controller.perform(rowAction: action)
        expandedLinearBekMergeIDs = answer.expandedMergeIDs
        collapsedLinearBekMergeIDs = answer.collapsedMergeIDs
    }

    @ViewBuilder
    private func logColumnView(
        _ column: LogColumnID,
        commit: CommitInfo,
        commitWidth: CGFloat,
        showTagNames: Bool,
        alignLabels: Bool
    ) -> some View {
        switch column {
        case .commit:
            HStack(spacing: 6) {
                // VcsLog's default table starts the commit column after the
                // graph gutter and paints branch/HEAD references in the same
                // cell as the subject. Reordering moves this whole semantic
                // column, not just one of its labels.
                if alignLabels {
                    referenceLabels(for: commit, showTagNames: showTagNames)
                    commitSummary(commit)
                } else {
                    commitSummary(commit)
                    referenceLabels(for: commit, showTagNames: showTagNames)
                }
            }
            .frame(width: commitWidth, height: rowHeight, alignment: .leading)
        case .author:
            Text(commit.authorName.isEmpty ? "—" : commit.authorName)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
                .frame(width: columnLayout.width(for: .author), alignment: .leading)
        case .date:
            Text(dateStr(commit.time))
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .frame(width: columnLayout.width(for: .date), alignment: .trailing)
        case .hash:
            Text(commit.shortId)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: columnLayout.width(for: .hash), alignment: .trailing)
        case .root:
            Text(logRepositoryDisplayName(commit.repositoryPath))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .help(logRepositoryDisplayPath(commit.repositoryPath))
                .frame(width: columnLayout.width(for: .root), alignment: .leading)
        case .signature:
            logSignatureCell(commit)
                .frame(width: columnLayout.width(for: .signature), alignment: .leading)
        }
    }

    @ViewBuilder
    private func logSignatureCell(_ commit: CommitInfo) -> some View {
        let key = commitIdentity(commit)
        if let info = signatureStatuses[key] {
            Group {
                switch info.status {
                case .none:
                    Text("—")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("No signature")
                case .valid:
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Verified signature")
                case .invalid:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Bad signature")
                case .unknown:
                    Image(systemName: "questionmark.circle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Unverified signature")
                @unknown default:
                    Image(systemName: "questionmark.circle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Unverified signature")
                }
            }
            .help(logSignatureHelp(info))
        } else if signatureFailedIDs.contains(key) {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.orange)
                .accessibilityLabel("Unable to load signature status")
                .help("Unable to load signature status")
        } else if signatureLoadingIDs.contains(key) || commit.hasSignature {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Loading signature status")
        } else {
            Text("—")
                .foregroundStyle(.secondary)
                .accessibilityLabel("No signature")
        }
    }

    private func logSignatureHelp(_ info: CommitSignatureInfo) -> String {
        let label: String
        switch info.status {
        case .none:
            label = "No signature"
        case .valid:
            label = "Verified signature"
        case .invalid:
            label = "Bad signature"
        case .unknown:
            label = info.reason.isEmpty ? "Unverified signature" : "Unverified signature: \(info.reason)"
        @unknown default:
            label = "Unverified signature"
        }
        var details = [label]
        if !info.signer.isEmpty { details.append("Signer: \(info.signer)") }
        if !info.fingerprint.isEmpty { details.append("Fingerprint: \(info.fingerprint)") }
        return details.joined(separator: "\n")
    }

    @ViewBuilder
    private func commitSummary(_ commit: CommitInfo) -> some View {
        Text(commit.summary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func referenceLabels(for commit: CommitInfo, showTagNames: Bool) -> some View {
        ForEach(refLabels(
            for: commit,
            compact: compactReferences,
            showTagNames: showTagNames
        )) { ref in
            Text(ref.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ref.kind.foreground)
                .padding(.horizontal, 5)
                .frame(height: 18)
                .background(ref.kind.background, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(ref.kind.border, lineWidth: 0.75)
                }
                .lineLimit(1)
                .frame(minWidth: alignLabels ? 56 : nil, alignment: .leading)
                .help(ref.title)
        }
    }

    private func refLabels(
        for commit: CommitInfo,
        compact: Bool,
        showTagNames: Bool
    ) -> [RefLabel] {
        var labels: [RefLabel] = []
        var seen = Set<String>()

        func append(_ label: RefLabel) {
            // A repository can expose the same shortened remote name through
            // more than one ref namespace (and older engine versions did not
            // normalize that list). SwiftUI requires every ForEach identity
            // to be unique; duplicate IDs here made the history table enter
            // undefined rendering state and could erase the commit summary.
            guard seen.insert(label.id).inserted else { return }
            labels.append(label)
        }

        if commit.isHead {
            append(RefLabel(id: "head", title: "HEAD", kind: .head))
        }
        commit.refs.forEach { append(RefLabel(id: "local:\($0)", title: $0, kind: .local)) }
        if showTagNames {
            commit.tagRefs.forEach { append(RefLabel(id: "tag:\($0)", title: $0, kind: .tag)) }
        }
        commit.remoteRefs.forEach { append(RefLabel(id: "remote:\($0)", title: $0, kind: .remote)) }
        if compact, labels.count > 2 {
            let hiddenCount = labels.count - 2
            return Array(labels.prefix(2)) + [RefLabel(
                id: "more:\(commit.id)",
                title: "+\(hiddenCount)",
                kind: .remote
            )]
        }
        return labels
    }

    /// VcsLogGraphTable supports the standard macOS table selection model.
    /// SwiftUI's high-level tap gesture does not expose modifier flags, so use
    /// the current AppKit event at the instant of the click and preserve the
    /// same single / Cmd-toggle / Shift-range semantics.
    private func select(_ commit: CommitInfo, modifiers: NSEvent.ModifierFlags? = nil) {
        let identity = commitIdentity(commit)
        let flags = modifiers ?? NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            var next = selectedIDs
            if next.contains(identity) {
                next.remove(identity)
            } else {
                next.insert(identity)
            }
            if next.isEmpty { next.insert(identity) }
            selectedIDs = next
            if next.contains(identity) {
                selection = identity
            } else if let nextActive = commits.first(where: { next.contains(commitIdentity($0)) }) {
                selection = commitIdentity(nextActive)
            }
            return
        }

        if flags.contains(.shift),
           let anchor = selection,
           let anchorIndex = commits.firstIndex(where: { commitIdentity($0) == anchor }),
           let targetIndex = commits.firstIndex(where: { commitIdentity($0) == identity }) {
            let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
            selectedIDs = Set(commits[range].map(commitIdentity))
            selection = identity
            return
        }

        selectedIDs = [identity]
        selection = identity
    }

    /// Graph-gutter coordinates. `originY` converts absolute row positions
    /// into render-window-local ones; pass `0` for the full-history space.
    private func point(lane: UInt32, row: Int, laneSpacing: CGFloat, originY: CGFloat = 0) -> CGPoint {
        CGPoint(
            x: 16 + CGFloat(lane) * laneSpacing,
            y: CGFloat(row) * rowHeight + rowHeight / 2 - originY
        )
    }

    private func color(for lane: UInt32) -> Color {
        let colors: [Color] = [.blue, .purple, .orange, .green, .pink, .teal, .indigo]
        return colors[Int(lane) % colors.count]
    }

    private func strokeGraphEdge(
        context: inout GraphicsContext,
        start: CGPoint,
        target: CGPoint,
        color: Color,
        style: StrokeStyle
    ) {
        context.stroke(
            graphEdgePath(start: start, target: target),
            with: .color(color),
            style: style
        )
    }

    private func graphEdgePath(start: CGPoint, target: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        let middleY = (start.y + target.y) / 2
        if start.x == target.x {
            path.addLine(to: target)
        } else {
            path.addLine(to: CGPoint(x: start.x, y: middleY))
            path.addCurve(
                to: target,
                control1: CGPoint(x: start.x, y: middleY),
                control2: CGPoint(x: target.x, y: middleY)
            )
        }
        return path
    }

    /// Draws only the rows of the current render window. `size` is the
    /// window height and all points are emitted in window-local coordinates
    /// (`originY`); edges entering from above or leaving below the window
    /// are clipped by the Canvas automatically.
    private func drawGraph(
        context: inout GraphicsContext,
        size: CGSize,
        rows: Range<Int>,
        originY: CGFloat,
        laneSpacing: CGFloat,
        commitIDs: Set<String>,
        graph: LinearBekGraphModel,
        highlight: LinearBekGraphHighlight?
    ) {
        for edge in graph.visibleEdges where edgeSpans(edge.upRow, edge.downRow, intersect: rows) {
            guard rows.contains(edge.downRow) || showLongEdges else { continue }
            let start = point(lane: edge.fromLane, row: edge.upRow, laneSpacing: laneSpacing, originY: originY)
            // Preserve the full curve so drawing and hit testing agree as
            // the render window moves. Canvas clips the offscreen segment.
            let target = point(lane: edge.toLane, row: edge.downRow, laneSpacing: laneSpacing, originY: originY)
            strokeGraphEdge(
                context: &context,
                start: start,
                target: target,
                color: highlight?.normalEdges.contains(edge) == true
                    ? .primary
                    : color(for: edge.toLane),
                style: StrokeStyle(
                    lineWidth: highlight?.normalEdges.contains(edge) == true ? 3.5 : 2,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }

        for edge in graph.dottedEdges {
            guard edgeSpans(edge.upRow, edge.downRow, intersect: rows) else { continue }
            strokeGraphEdge(
                context: &context,
                start: point(lane: edge.fromLane, row: edge.upRow, laneSpacing: laneSpacing, originY: originY),
                target: point(lane: edge.toLane, row: edge.downRow, laneSpacing: laneSpacing, originY: originY),
                color: highlight?.dottedEdges.contains(edge) == true
                    ? .primary
                    : color(for: edge.toLane),
                style: StrokeStyle(
                    lineWidth: highlight?.dottedEdges.contains(edge) == true ? 3.5 : 2,
                    lineCap: .round,
                    lineJoin: .round,
                    dash: [2, 3]
                )
            )
        }

        // A paged log has no row for a parent at the bottom of the current
        // page. Keep that continuation lane visible to the viewport edge.
        for index in rows {
            let commit = commits[index]
            let start = point(lane: commit.lane, row: index, laneSpacing: laneSpacing, originY: originY)
            for (parentIndex, parentId) in commit.parentIds.enumerated() {
                let parentIdentity = logCommitDisplayIdentity(
                    repositoryPath: commit.repositoryPath, id: parentId, aggregate: rootQualifiedIdentity
                )
                guard !commitIDs.contains(parentIdentity) else { continue }
                guard parentIndex < commit.parentLanes.count, showLongEdges else { continue }
                let parentLane = commit.parentLanes[parentIndex]
                strokeGraphEdge(
                    context: &context,
                    start: start,
                    target: CGPoint(
                        x: 16 + CGFloat(parentLane) * laneSpacing,
                        y: size.height
                    ),
                    color: color(for: parentLane),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )
            }
            let radius: CGFloat = commit.parentIds.count > 1 ? 6 : 5
            context.fill(
                Path(ellipseIn: CGRect(
                    x: start.x - radius,
                    y: start.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )),
                with: .color(
                    highlight?.rows.contains(index) == true
                        ? .primary
                        : commit.isHead ? .blue : color(for: commit.lane)
                )
            )
            if commit.isHead {
                context.stroke(
                    Path(ellipseIn: CGRect(
                        x: start.x - radius - 2,
                        y: start.y - radius - 2,
                        width: (radius + 2) * 2,
                        height: (radius + 2) * 2
                    )),
                    with: .color(.blue.opacity(0.35)),
                    lineWidth: 2
                )
            }
        }
    }
}
