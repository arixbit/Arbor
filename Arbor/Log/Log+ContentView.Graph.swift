import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {


var externalLogRootsMenu: some View {
    Menu {
        if multiRootWorkspace.roots.isEmpty {
            Text("No Git roots available")
        } else {
            Button("Select All Roots") {
                selectAllExternalLogRoots()
            }
            Button("Select Current Project Root") {
                selectPrimaryExternalLogRoot()
            }
            Divider()
            ForEach(multiRootWorkspace.roots, id: \.path) { root in
                let normalizedPath = canonicalExternalLogPath(root.path)
                let title = root.relativePath == "."
                    ? root.displayName
                    : "\(root.displayName) · \(root.relativePath)"
                Toggle(
                    isOn: Binding(
                        get: { logRuntime.aggregateRootPaths.contains(normalizedPath) },
                        set: { setExternalLogRootSelection(root.path, selected: $0) }
                    )
                ) {
                    Text(title)
                }
                .disabled(logRuntime.aggregateRootPaths.count == 1 && logRuntime.aggregateRootPaths.contains(normalizedPath))
            }
        }
    } label: {
        Label(
            "Git Roots \(logRuntime.aggregateRootPaths.count)/\(multiRootWorkspace.roots.count)",
            systemImage: "folder"
        )
    }
    .menuStyle(.borderlessButton)
    .help("Choose which Git roots appear in this external Log window")
}


var logGraphPanel: some View {
    logGraphBody
        .onChange(of: logSelectionState.selection) { _, id in
            guard let id else { return }
            loadCommitDetailsIfNeeded(id)
        }
    .onChange(of: reflog.selection) { _, selection in
        guard logList.viewMode == .reflog, let selection else { return }
        if !reflog.selectedIDs.contains(selection) {
            reflog.selectedIDs.insert(selection)
        }
    }
    .onChange(of: reflog.selectedIDs) { _, _ in
        synchronizeReflogSelection()
        loadReflogCommitDetails()
        if externalLogWindow {
            persistExternalLogTabs()
        }
    }
        .onChange(of: reflog.entries.map(reflogEntryIdentifier)) { _, _ in
            synchronizeReflogSelection()
            loadReflogCommitDetails()
        }
        .onAppear {
            loadLogSignatureStatuses()
        }
        .onChange(of: logShowSignatureColumn) { _, _ in
            loadLogSignatureStatuses()
        }
        .onChange(of: logList.entries.map(logCommitIdentity)) { _, _ in
            loadLogSignatureStatuses()
        }
        .sheet(isPresented: $logList.pathsEditorPresented) {
            LogPathsEditorView(
                text: $logList.pathsEditorText,
                onCancel: { logList.pathsEditorPresented = false },
                onApply: applyLogPathsEditor
            )
        }
        .sheet(isPresented: $logList.pathsTreeChooserPresented) {
            LogPathsTreeChooserView(
                roots: logList.pathsTreeChooserRoots,
                selections: $logList.pathsTreeChooserSelections,
                onCancel: { logList.pathsTreeChooserPresented = false },
                onApply: applyLogPathsTreeChooser
            )
        }
    .alert("Enter branch, tag, or commit", isPresented: $logList.revisionFilterPresented) {
        TextField("branch or revision", text: $logList.revisionInput)
        Button("Cancel", role: .cancel) {}
        Button("Add") {
            let value = logList.revisionInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            // A typed value is a complete filter expression. Replacing the
            // popup selection prevents a branch head and an A..B range from
            // being accidentally treated as a union when IntelliJ would keep
            // range/revision filters as a separate filter category.
            setLogStartRevisions([value])
        }
        .disabled(logList.revisionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .confirmationDialog(
        logSelectionState.navigationChoosesParent ? "Select Parent Commit" : "Select Child Commit",
        isPresented: $logSelectionState.isNavigationChoicePresented,
        titleVisibility: .visible
    ) {
        ForEach(Array(logSelectionState.pendingNavigationCommits.enumerated()), id: \.offset) { _, commit in
            Button(logNavigationChoiceTitle(commit)) {
                choosePendingLogNavigationCommit(commit)
            }
        }
        Button("Cancel", role: .cancel) {
            logSelectionState.pendingNavigationCommits = []
            logSelectionState.pendingNavigationSelection = nil
            logSelectionState.pendingNavigationGeneration = nil
        }
    } message: {
        Text(logSelectionState.navigationChoosesParent ? "Choose a parent commit" : "Choose a child commit")
    }
}


var logCommandFilterBar: some View {
    HStack(spacing: 8) {
        Text("git log")
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.secondary)
        TextField("command and arguments", text: $logRuntime.commandFilter)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .onSubmit { runLogCommand() }
        Button("Run") { runLogCommand() }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        Button("History") { logList.viewMode = .graph }
            .buttonStyle(.bordered)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(height: 48)
    .background(Design.Colors.surface.opacity(0.55))
}


@ViewBuilder
var logGraphHistoryContent: some View {
    let isCommand = logList.viewMode == .command
    let isFileHistory = logSelectionState.tabs.first { $0.id == currentLogTabID }?.historyPath != nil
    let entries = isCommand ? logRuntime.commandEntries : logList.entries
    let isLoading = isCommand ? logRuntime.isLoadingCommand : logList.isLoading
    if isLoading && entries.isEmpty {
        ProgressView("Loading history…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if entries.isEmpty {
        HStack(spacing: 0) {
            if logBranchesVisible && !isCommand {
                logBranchesPanelView
                Divider()
            }
            VStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                Text(isCommand
                    ? (logRuntime.commandError ?? "No commits match the command")
                    : (logList.error ?? "No commits match the current filters"))
                    .foregroundStyle(.secondary)
                Button("Refresh") {
                    if isCommand { runLogCommand() } else { loadLog() }
                }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
        HStack(spacing: 0) {
            if logBranchesVisible && !isCommand {
                logBranchesPanelView
                Divider()
            }
            LogGraphView(
                commits: entries,
                selection: $logSelectionState.selection,
                selectedIDs: $logSelectionState.selectedIDs,
                rootQualifiedIdentity: isLogRootQualified,
                showColumnHeaders: logShowColumnHeaders,
                compactReferences: logCompactReferences,
                showCommitColumns: logShowCommitColumns,
                showAuthorColumn: logShowAuthorColumn,
                showDateColumn: logShowDateColumn,
                showHashColumn: logShowHashColumn,
                showRootColumn: logShowRootColumn,
                showSignatureColumn: logShowSignatureColumn,
                signatureStatuses: logRuntime.signatureStatuses,
                signatureLoadingIDs: logRuntime.signatureLoadingIDs,
                signatureFailedIDs: logRuntime.signatureFailedIDs,
                columnLayout: LogColumnLayout(
                    orderRaw: logColumnOrderRaw,
                    widthsRaw: logColumnWidthsRaw
                ),
                showTagNames: logShowTagNames,
                alignLabels: logAlignLabels,
                showLongEdges: logShowLongEdges,
                collapseGraph: logCollapseGraph,
                graphCommand: logRuntime.graphCommand,
                highlightCherryPickedCommits: logHighlightCherryPicked,
                actionAvailability: logActionAvailability,
                isFileHistory: isFileHistory,
                onReachedEnd: loadMoreLog,
                hasMore: isCommand ? logRuntime.hasMoreCommand : logList.hasMore,
                isLoadingMore: isCommand ? logRuntime.isLoadingCommand : logList.isLoadingMore,
                pullRequestRemotesForCommit: pullRequestRemotesForCommit,
                onOpenPullRequest: openPullRequestsForCommit,
                commentRemotesForCommit: commentRemotesForCommit,
                onComment: beginReviewComment,
                onCreateBranch: createBranchFromCommit,
                onCreateTag: beginCreateTagFromLog,
                onCherryPick: cherryPickFromLog,
                onCherryPickSelected: cherryPickCommitsFromLog,
                onRevert: revertFromLog,
                onRevertSelected: revertCommitsFromLog,
                onCheckout: checkoutFromLog,
                onReset: resetFromLog,
                onResetSelected: { commits in
                    resetFromLog(commits)
                },
                onCompare: compareFromLog,
                currentBranchNameForCommit: currentLogBranchName,
                onReferenceAction: performLogReferenceAction,
                onRebaseOntoCommit: rebaseOntoCommitFromLog,
                onInteractiveRebase: interactiveRebaseFromLog,
                onCreateAutoSquashCommit: beginAutoSquashCommitFromLog,
                onRewriteCommit: { commit, action in
                    rewriteCommitFromLog(commit, action: action)
                },
                onRewriteSelected: { commits, action in
                    rewriteSelectedCommitsFromLog(commits, action: action)
                },
                onPushUpToCommit: pushUpToCommitFromLog,
                onAddCommitsToRemoteBranch: addCommitsToRemoteBranchFromLog,
                highlightedCherryPickedCommitIDs: logCherryPick.cherryPickedCommitIDs,
                cherryPickComparisonReady: logCherryPick.comparisonReady,
                hostedRemotesForCommit: hostedRemotesForCommit,
                onBrowseHostedRevision: browseHostedRevisionFromLog,
                onBrowseRevision: browseRevisionFromLog,
                onCopyRevisionLink: copyRevisionLinkFromLog,
                onUncommit: uncommitFromLog,
                onColumnOrderChanged: { order in
                    logColumnOrderRaw = order.map(\.rawValue).joined(separator: ",")
                },
                onColumnWidthChanged: { column, width in
                    setLogColumnWidth(column, to: width)
                }
            )
        }
        .frame(minHeight: 0, maxHeight: .infinity)
    }
}


/// Log 工具栏齿轮菜单。
///
/// 单独成属性：整块 HStack 加上这些 Toggle/Picker 后，Swift 类型检查在
/// 单个表达式里会超时（"unable to type-check this expression in reasonable time"）。
var logGraphGearMenu: some View {
    Menu {
        Picker("Log view", selection: $logList.viewMode) {
            Text("History").tag(LogViewMode.graph)
            Text("Git Log Command").tag(LogViewMode.command)
            Text("Compare").tag(LogViewMode.compare)
            Text("Tags").tag(LogViewMode.tags)
            Text("Reflog").tag(LogViewMode.reflog)
        }
        Picker("Sort", selection: $logRuntime.sortModeRaw) {
            ForEach(LogGraphSortChoice.allCases) { choice in
                Text(choice.title).tag(choice.rawValue)
            }
        }
        Divider()
        Toggle("Show Commit Details", isOn: $logShowDetails)
        Toggle("Show Diff Preview", isOn: $logShowDiffPreview)
        Toggle("Diff Preview on Bottom", isOn: $logDiffPreviewVertical)
        Divider()
        Toggle("Compact References", isOn: $logCompactReferences)
        Menu("Log Columns") {
            Toggle("Show Column Headers", isOn: $logShowColumnHeaders)
            Toggle("Show Author and Date", isOn: showAuthorAndDateBinding)
            Toggle("Show Author", isOn: showAuthorColumnBinding)
            Toggle("Show Date", isOn: showDateColumnBinding)
            Toggle("Show Commit Hash", isOn: $logShowHashColumn)
            Toggle("Show Root Names", isOn: $logShowRootColumn)
            Toggle("Show Commit Signature", isOn: $logShowSignatureColumn)
            Divider()
            ForEach(LogColumnID.allCases) { column in
                Menu(column.title) {
                    Button("Wider") { resizeLogColumn(column, by: 16) }
                        .disabled(!column.isResizable)
                    Button("Narrower") { resizeLogColumn(column, by: -16) }
                        .disabled(!column.isResizable)
                    Divider()
                    Button("Move Left") { moveLogColumn(column, by: -1) }
                        .disabled(!canMoveLogColumn(column, by: -1))
                    Button("Move Right") { moveLogColumn(column, by: 1) }
                        .disabled(!canMoveLogColumn(column, by: 1))
                }
            }
            Divider()
            Button("Reset Column Order") {
                logColumnOrderRaw = LogColumnLayout.defaultOrder.map(\.rawValue).joined(separator: ",")
            }
            Button("Reset Column Widths") {
                logColumnWidthsRaw = ""
            }
        }
        Toggle("Show Tag Names", isOn: $logShowTagNames)
        Toggle("Align Labels", isOn: $logAlignLabels)
        Toggle("Show Long Edges", isOn: $logShowLongEdges)
        Button("Collapse All Graph") {
            issueLogGraphCommand(.buttonCollapse)
        }
        .disabled(logList.viewMode != .graph)
        Button("Expand All Graph") {
            issueLogGraphCommand(.buttonExpand)
        }
        .disabled(logList.viewMode != .graph)
        Toggle("Collapse Graph", isOn: $logCollapseGraph)
        Toggle("No Merges", isOn: $logNoMerges)
        Toggle("Show Branches", isOn: $logBranchesVisible)
        Divider()
        Button("Go to Parent") { selectParentLogCommit() }
            .disabled(selectedCommit?.parentIds.isEmpty ?? true)
        Button("Go to Child") { selectChildLogCommit() }
            .disabled(selectedCommit == nil)
        Button("Copy Selected Revision IDs") { copySelectedLogIDs() }
            .disabled(logSelectionState.selectedIDs.isEmpty)
        Divider()
        Menu("More Log Actions") {
            Button("Show Git Log Command…") {
                logRuntime.commandFilter = ""
                logRuntime.commandEntries = []
                logRuntime.commandError = nil
                logList.viewMode = .command
            }
            Button("Create Patch…") {
                if let selectedCommit { createPatchFromLog(selectedCommit) }
            }
            .disabled(selectedCommit == nil || logSelectionState.selectedIDs.count > 1)
            .help("Create a patch for one selected commit")
            Button("Reset Selected Revisions…") {
                resetFromLog(selectedLogCommits)
            }
            .disabled(
                !isResetSelectionAvailable(for: selectedLogCommits)
                    || !logActionAvailability.allowsMutation(for: selectedLogCommits)
            )
            .help("Reset one selected revision per Git root")
            Button("Create Fixup Commit…") {
                if let selectedCommit {
                    beginAutoSquashCommitFromLog(selectedCommit, kind: .fixup)
                }
            }
            .disabled(
                selectedCommit == nil
                    || !logActionAvailability.hasLocalChanges
                    || (selectedCommit.map { !logActionAvailability.allowsHistoryRewrite(for: [$0]) } ?? true)
            )
            Button("Create Squash Commit…") {
                if let selectedCommit {
                    beginAutoSquashCommitFromLog(selectedCommit, kind: .squash)
                }
            }
            .disabled(
                selectedCommit == nil
                    || !logActionAvailability.hasLocalChanges
                    || (selectedCommit.map { !logActionAvailability.allowsHistoryRewrite(for: [$0]) } ?? true)
            )
            Button("Squash Selected Commits…") {
                rewriteSelectedCommitsFromLog(selectedLogCommits, action: .squash)
            }
            .disabled(
                !areLogRewriteSelectionActionsAvailable(for: selectedLogCommits)
                    || !logActionAvailability.allowsSingleRootHistoryRewrite(for: selectedLogCommits)
            )
            Button("Reword Selected Commits…") {
                rewriteSelectedCommitsFromLog(selectedLogCommits, action: .reword)
            }
            .disabled(
                !areLogRewriteSelectionActionsAvailable(for: selectedLogCommits)
                    || !logActionAvailability.allowsSingleRootHistoryRewrite(for: selectedLogCommits)
            )
            Button("Drop Selected Commits…", role: .destructive) {
                rewriteSelectedCommitsFromLog(selectedLogCommits, action: .drop)
            }
            .disabled(
                !areLogRewriteSelectionActionsAvailable(for: selectedLogCommits)
                    || !logActionAvailability.allowsSingleRootHistoryRewrite(for: selectedLogCommits)
            )
            Button("Toggle Log Columns") {
                showAuthorAndDateBinding.wrappedValue.toggle()
            }
            Menu("Highlight Cherry-Picked Commits") {
                Picker("Compared branch", selection: $logCherryPickCompareBranch) {
                    Text("Choose source branch…").tag("")
                    ForEach(cherryPickCompareBranchChoices, id: \.self) { branch in
                        Text(branch).tag(branch)
                    }
                }
                Toggle("Enable Highlighting", isOn: $logHighlightCherryPicked)
                    .disabled(logCherryPickCompareBranch.isEmpty)
                if !logCherryPickCompareBranch.isEmpty {
                    Text("Target: \(cherryPickTargetBranchLabel)")
                }
                if logCherryPick.inProgress {
                    Label(
                        "Comparing cherry-picked commits… (\(logCherryPick.completedRoots)/\(logCherryPick.totalRoots))",
                        systemImage: "hourglass"
                    )
                    Button("Cancel Comparison") {
                        cancelCherryPickedHighlighting()
                    }
                }
            }
            Toggle("Show Changes from Parents", isOn: $logShowChangesFromParents)
            if logList.viewMode == .graph, !activeLogPathFilterSelections().isEmpty {
                Toggle("Show Only Affected Changes", isOn: $logShowOnlyAffectedChanges)
            }
            Button("Open Log in New Window") {
                guard let projectPath = projectWorkspace.path,
                      let request = chooseExternalLogWindowRequest(for: projectPath) else {
                    return
                }
                openWindow(id: "git-log", value: request)
            }
            .disabled(projectWorkspace.repository == nil || projectWorkspace.path == nil)
            Button("Open Another Log Tab") { openAnotherLogTab() }
        }
        Divider()
        Button(logRefreshButtonTitle) {
            reloadLogView()
        }
    } label: {
        HStack(spacing: 3) {
            Image(systemName: "ellipsis")
            Image(systemName: "chevron.down")
        }
        .foregroundStyle(.secondary)
        .frame(width: 34, height: 32)
    }
    .menuStyle(.borderlessButton)
}


/// Log 面板主体：工具栏 + 过滤条 + 各视图内容。
///
/// 从 `logGraphPanel` 拆出来，让外层只保留弹窗与 onChange 修饰符。
var logGraphBody: some View {
VStack(spacing: 0) {
    logGraphHeader

    if logSelectionState.tabs.count > 1 {
        LogTabBar(
            tabs: logSelectionState.tabs,
            activeID: currentLogTabID,
            onSelect: switchLogTab,
            onClose: closeLogTab,
            onNew: openAnotherLogTab
        )
    }

    if logList.viewMode == .command {
        logCommandFilterBar
    } else if logList.viewMode == .graph {
    logFilterBar
    }
    if shouldShowLogError {
        if let error = logList.error {
            Text(error).foregroundStyle(.red).font(.callout).padding(8)
        }
    }
    switch logList.viewMode {
    case .graph:
        logGraphHistoryContent
    case .command:
        logGraphHistoryContent
    case .compareBranches:
        BranchCommitComparisonView(
            firstBranch: comparisonWorkspace.revision1,
            secondBranch: comparisonWorkspace.revision2,
            firstCommits: branchComparison.firstEntries,
            secondCommits: branchComparison.secondEntries,
            firstFilter: $branchComparison.firstFilter,
            secondFilter: $branchComparison.secondFilter,
            isLoading: branchComparison.isLoading,
            error: branchComparison.error,
            selectedID: $branchComparison.selectionID,
            selectedSide: $branchComparison.selectionSide,
            onFilterChanged: refreshBranchComparison,
            pagination: branchComparisonPagination,
            onSelect: { side, id in
                branchComparison.selectionSide = side
                branchComparison.selectionID = id
            },
            onAction: { action, commit in
                switch action {
                case .checkout:
                    checkoutFromLog(commit)
                case .reset:
                    resetFromLog(commit)
                case .createBranch:
                    createBranchFromCommit(commit)
                case .compare:
                    compareFromLog(commit)
                case .interactiveRebase:
                    interactiveRebaseFromLog(commit)
                case .cherryPick:
                    cherryPickFromLog(commit)
                case .revert:
                    revertFromLog(commit)
                }
            },
            logActions: branchComparisonLogActions
        )
    case .compare:
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("旧版本 / 分支", text: $comparisonWorkspace.revision1)
                    .textFieldStyle(.roundedBorder)
                Text("→").foregroundStyle(.secondary)
                TextField("新版本 / 分支", text: $comparisonWorkspace.revision2)
                    .textFieldStyle(.roundedBorder)
                Button("比较") {
                    comparisonWorkspace.withWorkingTree = false
                    loadTreeChanges()
                }
                Menu {
                    Button("Select All") {
                        comparisonWorkspace.selectedPaths = Set(comparisonWorkspace.treeChanges.map(\.path))
                        comparisonWorkspace.selection = comparisonWorkspace.treeChanges.first?.path
                    }
                    .disabled(comparisonWorkspace.treeChanges.isEmpty)
                    Button("Clear") {
                        comparisonWorkspace.selectedPaths = []
                        comparisonWorkspace.selection = nil
                    }
                    .disabled(comparisonWorkspace.selectedPaths.isEmpty)
                    Divider()
                    Button("Copy Selected Paths") {
                        copySelectedComparePaths()
                    }
                    .disabled(comparisonWorkspace.selectedPaths.isEmpty)
                    Divider()
                    Button("Create Patch…") {
                        createPatchFromCompare()
                    }
                    .disabled(comparisonWorkspace.selectedPaths.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .help("Compare actions")
            }
            .padding(.horizontal, 8)
            HStack(spacing: 8) {
                Text("\(comparisonWorkspace.treeChanges.count) files")
                if !comparisonWorkspace.selectedPaths.isEmpty {
                    Text("\(comparisonWorkspace.selectedPaths.count) selected")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .font(.caption2)
            .padding(.horizontal, 8)
            if let compareError = comparisonWorkspace.error {
                Text(compareError).foregroundStyle(.red).font(.caption).padding(.horizontal, 8)
            }
            List(comparisonWorkspace.treeChanges, id: \.path, selection: $comparisonWorkspace.selectedPaths) { change in
                HStack {
                    Text(treeChangeKindText(change.kind))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)
                    Text(change.path).font(.system(.body, design: .monospaced))
                }
                .tag(change.path)
                .simultaneousGesture(TapGesture().onEnded {
                    comparisonWorkspace.selection = change.path
                })
            }
            .listStyle(.inset)
            .onChange(of: comparisonWorkspace.selectedPaths) { _, selectedPaths in
                let validPaths = Set(comparisonWorkspace.treeChanges.map(\.path))
                let normalized = selectedPaths.intersection(validPaths)
                if normalized != selectedPaths {
                    comparisonWorkspace.selectedPaths = normalized
                    return
                }
                if let compareSelection = comparisonWorkspace.selection, normalized.contains(compareSelection) {
                    return
                }
                comparisonWorkspace.selection = orderedCompareSelection(
                    changes: comparisonWorkspace.treeChanges,
                    selectedPaths: normalized
                ).first?.path
            }
        }
    case .tags:
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("tag 名称", text: $tagWorkspace.name)
                    .textFieldStyle(.roundedBorder)
                TextField("指向 rev（空=HEAD）", text: $tagWorkspace.at)
                    .textFieldStyle(.roundedBorder)
                Button("创建") { createTag() }
            }
            .padding(.horizontal, 8)
            if let feedback = tagWorkspace.feedback {
                Text(feedback).font(.caption)
                    .foregroundStyle(feedback.hasPrefix("已") ? .green : .red)
                    .padding(.horizontal, 8)
            }
            List(tagWorkspace.tags, id: \.name) { tag in
                HStack {
                    Text(tag.name).font(.system(.body, design: .monospaced))
                    Text(tag.shortId).font(.caption).foregroundStyle(.secondary)
                    Text(tag.kind == .lightweight ? "lightweight" : tag.kind == .signed ? "signed" : "annotated")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(tag.message)
                    Spacer()
                    pushTagAction(for: tag.name)
                    Button("删除") { deleteTag(tag.name) }
                }
            }
            .listStyle(.inset)
        }
    case .reflog:
        reflogHistoryContent
    }
}
}

}
