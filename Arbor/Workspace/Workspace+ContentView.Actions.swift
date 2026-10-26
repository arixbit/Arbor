import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
func startNextExternalVCSAction(repo: Repository) {
    guard let rawWorkdir = repo.workdir() else { return }
    let workdir = URL(fileURLWithPath: rawWorkdir).standardizedFileURL.path
    guard let ticket = repositoryStatus.externalVCSActionManager.begin(
        repositoryPath: workdir
    ) else { return }
    let event = ticket.event
    let pathspecs: Set<String> = Set(
        event.dirtyPaths.flatMap { dirtyPath -> [String] in
            guard dirtyPath.kind == .created || dirtyPath.kind == .removed
                || dirtyPath.kind == .renamed else { return [] }
            let endpoints = [dirtyPath.path] + (dirtyPath.oldPath.map { [$0] } ?? [])
            return endpoints
                .compactMap {
                    repositoryRelativeWorktreeEventPath(
                        workdir: workdir,
                        path: $0
                    )
                }
        }
    )
    guard !pathspecs.isEmpty else {
        finishExternalVCSAction(ticket, repo: repo)
        return
    }

    Task.detached(priority: .utility) {
        do {
            let requiresRenameReconciliation = event.dirtyPaths.contains {
                $0.kind == .renamed && $0.oldPath == nil
            }
            let status = requiresRenameReconciliation
                ? try repo.status()
                : try repo.statusPaths(paths: pathspecs.sorted())
            let contentRenameMatches: [RepositoryExternalVCSMove]
            if requiresRenameReconciliation {
                let exactMatches = repositoryUniqueContentRenameMatches(
                    repo: repo,
                    event: event,
                    workdir: workdir,
                    status: status
                )
                let modifiedMatches = repositoryModifiedContentRenameMatches(
                    repo: repo,
                    event: event,
                    workdir: workdir,
                    status: status,
                    reservedMoves: exactMatches
                )
                contentRenameMatches = repositoryNonConflictingExternalVCSMoves(
                    exactMatches + modifiedMatches
                )
            } else {
                contentRenameMatches = []
            }
            let actionPaths = repositoryExternalVCSActionPaths(
                event: event,
                workdir: workdir,
                status: status,
                contentRenameMatches: contentRenameMatches
            )
            guard !actionPaths.isEmpty else {
                await MainActor.run {
                    self.finishExternalVCSAction(ticket, repo: repo)
                }
                return
            }
            await MainActor.run {
                self.confirmAndPerformExternalVCSActions(
                    actionPaths,
                    event: event,
                    repo: repo,
                    ticket: ticket
                )
            }
        } catch {
            DiagnosticsLogger.shared.record(
                level: .error,
                operation: "vfs-listener",
                repositoryPath: workdir,
                code: "status-failed"
            )
            await MainActor.run {
                self.finishExternalVCSAction(ticket, repo: repo)
            }
        }
    }
}

func finishExternalVCSAction(
    _ ticket: RepositoryExternalVCSActionTicket,
    repo: Repository
) {
    guard repositoryStatus.externalVCSActionManager.finish(ticket) else { return }
    startNextExternalVCSAction(repo: repo)
}

func confirmAndPerformExternalVCSActions(
    _ paths: RepositoryExternalVCSActionPaths,
    event: RepositoryChangeEvent,
    repo: Repository,
    ticket: RepositoryExternalVCSActionTicket
) {
    var addPaths: [String] = []
    var stageAddPaths: [String] = []
    var removePaths: [String] = []
    let forceMoves = paths.forceMove
    let addAction = GitVFSListenerSettings.addAction()
    let removeAction = GitVFSListenerSettings.removeAction()
    let selectedReviewMoves: [RepositoryExternalVCSMove]
    if !paths.reviewMoves.isEmpty,
       addAction != .ignore || removeAction != .ignore {
        let selectedMoves = selectExternalVCSMoves(
            title: "Review ambiguous Git moves",
            actionTitle: "Apply selected moves",
            moves: paths.reviewMoves
        )
        selectedReviewMoves = repositoryNonConflictingExternalVCSMoves(selectedMoves)
    } else {
        selectedReviewMoves = []
    }
    let reviewAddPaths = addAction == .ignore
        ? []
        : selectedReviewMoves.map(\.newPath)
    let reviewRemovePaths = removeAction == .ignore
        ? []
        : selectedReviewMoves.map(\.oldPath)

    if !paths.add.isEmpty || !paths.stageAdd.isEmpty || !reviewAddPaths.isEmpty {
        let allAddPaths = paths.add + paths.stageAdd
        switch addAction {
        case .perform:
            addPaths = paths.add
            stageAddPaths = paths.stageAdd
        case .ask:
            let selected = Set(selectExternalVCSActionPaths(
                title: "Add files to Git?",
                actionTitle: "Add to Git",
                paths: allAddPaths
            ))
            addPaths = repositorySelectedExternalVCSPaths(
                paths: paths.add,
                selected: selected
            )
            stageAddPaths = repositorySelectedExternalVCSPaths(
                paths: paths.stageAdd,
                selected: selected
            )
        case .ignore:
            break
        }
        addPaths.append(contentsOf: reviewAddPaths)
    }
    if !paths.remove.isEmpty || !reviewRemovePaths.isEmpty {
        switch removeAction {
        case .perform:
            removePaths = paths.remove
        case .ask:
            let selected = Set(selectExternalVCSActionPaths(
                title: "Remove files from Git?",
                actionTitle: "Remove from Git",
                paths: paths.remove
            ))
            removePaths = repositorySelectedExternalVCSPaths(
                paths: paths.remove,
                selected: selected
            )
        case .ignore:
            break
        }
        removePaths.append(contentsOf: reviewRemovePaths)
    }
    guard !addPaths.isEmpty || !stageAddPaths.isEmpty || !removePaths.isEmpty || !forceMoves.isEmpty else {
        finishExternalVCSAction(ticket, repo: repo)
        return
    }

    let rootPath = URL(fileURLWithPath: event.repositoryPath)
        .standardizedFileURL
        .path
    let action = RepositoryExternalVCSAction(
        addPaths: addPaths,
        stageAddPaths: stageAddPaths,
        removePaths: removePaths,
        forceMoves: forceMoves
    )
    let notificationID = externalVCSActionNotificationID(repositoryPath: rootPath)
    beginFeedbackOperation("Update Git files", notificationID: notificationID)
    Task.detached(priority: .userInitiated) {
        do {
            let completedDetail = try runRepositoryExternalVCSActions(repo: repo, action: action)
            await MainActor.run {
                self.refreshRepositoryChange(event) {
                    self.finishExternalVCSAction(ticket, repo: repo)
                }
                self.feedbackCenter.success(
                    "External Git files updated",
                    detail: completedDetail,
                    notificationID: notificationID
                )
            }
        } catch {
            let executionError = error as? RepositoryExternalVCSActionExecutionError
            let retryAction = repositoryExternalVCSActionCapturingSnapshots(
                executionError?.remainingAction ?? action,
                rootPath: rootPath
            )
            await MainActor.run {
                self.refreshRepositoryChange(event) {
                    self.finishExternalVCSAction(ticket, repo: repo)
                }
                self.feedbackCenter.error(
                    "External Git file action failed",
                    detail: executionError?.message ?? errorMessage(error),
                    nextStep: "Review the affected paths, then retry the external Git action.",
                    additionalActions: [
                        self.externalVCSRetryFeedbackAction(rootPath: rootPath, action: retryAction)
                    ],
                    notificationID: notificationID
                )
            }
        }
    }
}

func externalVCSActionRefreshEvent(
    rootPath: String,
    action: RepositoryExternalVCSAction
) -> RepositoryChangeEvent {
    let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL
    var dirtyPaths: [RepositoryDirtyPath] = []
    var seen = Set<String>()

    func absolutePath(_ relativePath: String) -> String {
        rootURL.appendingPathComponent(relativePath).standardizedFileURL.path
    }

    func appendPath(_ relativePath: String, kind: RepositoryDirtyChangeKind) {
        let path = absolutePath(relativePath)
        guard seen.insert("\(kind.rawValue):\(path)").inserted else { return }
        dirtyPaths.append(
            RepositoryDirtyPath(path: path, isDirectory: false, kind: kind)
        )
    }

    action.addPaths.forEach { appendPath($0, kind: .created) }
    action.stageAddPaths.forEach { appendPath($0, kind: .created) }
    action.removePaths.forEach { appendPath($0, kind: .removed) }
    for move in action.forceMoves {
        let newPath = absolutePath(move.newPath)
        guard seen.insert("renamed:\(newPath)").inserted else { continue }
        dirtyPaths.append(
            RepositoryDirtyPath(
                path: newPath,
                isDirectory: false,
                kind: .renamed,
                oldPath: absolutePath(move.oldPath)
            )
        )
    }
    return RepositoryChangeEvent(
        repositoryPath: rootURL.path,
        scopes: .worktree,
        dirtyPaths: dirtyPaths
    )
}

func externalVCSRetryFeedbackAction(
        rootPath: String,
        action: RepositoryExternalVCSAction
    ) -> FeedbackAction {
        let request = ArborVCSActionRequest(
            kind: .retryExternalVCSAction,
            projectPath: projectWorkspace.path,
            rootPath: rootPath,
            shelfName: "",
            externalVCSAction: action
        )
        return FeedbackAction(
            id: "retry-external-vcs:\(rootPath)",
            title: "Retry External Git Action",
            semanticAction: request
        ) {
            self.handleVCSActionRequest(request)
        }
    }

func retryExternalVCSAction(
        rootPath: String,
        action: RepositoryExternalVCSAction
    ) {
        guard repositoryExternalVCSActionIsSafe(action),
              repositoryExternalVCSActionMatchesSnapshots(action, rootPath: rootPath),
              !action.isEmpty,
              let repo,
              let currentRoot = repo.workdir(),
              URL(fileURLWithPath: currentRoot).standardizedFileURL.path
                  == URL(fileURLWithPath: rootPath).standardizedFileURL.path else {
            feedbackCenter.error(
                "External Git retry unavailable",
                detail: "The affected files changed after the failed Git action, so the saved operation is stale.",
                nextStep: "Refresh the repository and retry the file action from the current changes."
            )
            return
        }

        let normalizedRoot = URL(fileURLWithPath: rootPath)
            .standardizedFileURL
            .path
        let notificationID = externalVCSActionNotificationID(
            repositoryPath: normalizedRoot
        )
        beginFeedbackOperation("Update Git files", notificationID: notificationID)
        Task.detached(priority: .userInitiated) {
            do {
                let detail = try runRepositoryExternalVCSActions(repo: repo, action: action)
                await MainActor.run {
                    self.refreshRepositoryChange(
                        externalVCSActionRefreshEvent(
                            rootPath: normalizedRoot,
                            action: action
                        )
                    )
                    self.feedbackCenter.success(
                        "External Git files updated",
                        detail: detail,
                        notificationID: notificationID
                    )
                }
            } catch {
                let executionError = error as? RepositoryExternalVCSActionExecutionError
                let retryAction = repositoryExternalVCSActionCapturingSnapshots(
                    executionError?.remainingAction ?? action,
                    rootPath: normalizedRoot
                )
                await MainActor.run {
                    self.feedbackCenter.error(
                        "External Git file retry failed",
                        detail: executionError?.message ?? errorMessage(error),
                        nextStep: "Review the affected paths and retry again after fixing the cause.",
                        additionalActions: [
                            self.externalVCSRetryFeedbackAction(
                                rootPath: normalizedRoot,
                                action: retryAction
                            )
                        ],
                        notificationID: notificationID
                    )
                }
            }
        }
}

func selectExternalVCSActionPaths(
    title: String,
    actionTitle: String,
    paths: [String]
) -> [String] {
    var uniquePaths: [String] = []
    for path in paths where !uniquePaths.contains(path) {
        uniquePaths.append(path)
    }
    let paths = uniquePaths
    guard !paths.isEmpty else { return [] }

    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = String(localized: "Select the paths to process.")
    alert.alertStyle = .informational
    alert.addButton(withTitle: actionTitle)
    alert.addButton(withTitle: "Skip")

    let rowHeight: CGFloat = 22
    let width: CGFloat = 440
    let contentHeight = max(rowHeight, CGFloat(paths.count) * rowHeight)
    let visibleHeight = min(contentHeight, 280)
    let checkboxes = paths.map { path -> NSButton in
        let button = NSButton(checkboxWithTitle: path, target: nil, action: nil)
        button.state = .on
        button.toolTip = path
        button.lineBreakMode = .byTruncatingMiddle
        return button
    }
    let stack = NSStackView(views: checkboxes)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 2
    stack.frame = NSRect(
        x: 0,
        y: 0,
        width: width - 20,
        height: contentHeight
    )

    let scrollView = NSScrollView(
        frame: NSRect(x: 0, y: 0, width: width, height: visibleHeight)
    )
    scrollView.hasVerticalScroller = contentHeight > visibleHeight
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    scrollView.documentView = stack
    alert.accessoryView = scrollView

    guard alert.runModal() == .alertFirstButtonReturn else { return [] }
    return zip(paths, checkboxes).compactMap { path, checkbox in
        checkbox.state == .on ? path : nil
    }
}

/// Presents ambiguous directory rename candidates as one choice per new
/// endpoint. Independent checkboxes are unsafe here because several old paths
/// can share the same unchanged suffix; a popup makes the one-to-one rule
/// visible and defaults ambiguous groups to Skip.
func selectExternalVCSMoves(
    title: String,
    actionTitle: String,
    moves: [RepositoryExternalVCSMove]
) -> [RepositoryExternalVCSMove] {
    let groups = Dictionary(grouping: moves, by: \.newPath)
        .map { newPath, candidates in
            (newPath: newPath, candidates: candidates.sorted { $0.oldPath < $1.oldPath })
        }
        .sorted { $0.newPath < $1.newPath }
    guard !groups.isEmpty else { return [] }

    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = String(localized: "Choose at most one old path for each new path. Ambiguous matches default to Skip.")
    alert.alertStyle = .informational
    alert.addButton(withTitle: actionTitle)
    alert.addButton(withTitle: "Skip")

    let width: CGFloat = 560
    let rowHeight: CGFloat = 28
    let contentHeight = max(rowHeight, CGFloat(groups.count) * rowHeight)
    let visibleHeight = min(contentHeight, 320)

    enum MoveControl {
        case checkbox(RepositoryExternalVCSMove, NSButton)
        case popup([RepositoryExternalVCSMove], NSPopUpButton)
    }
    var controls: [MoveControl] = []
    var rowViews: [NSView] = []
    for group in groups {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let newLabel = NSTextField(labelWithString: group.newPath)
        newLabel.lineBreakMode = .byTruncatingMiddle
        newLabel.toolTip = group.newPath
        newLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        newLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(newLabel)

        let arrow = NSTextField(labelWithString: "←")
        arrow.textColor = .secondaryLabelColor
        row.addArrangedSubview(arrow)

        if group.candidates.count == 1 {
            let checkbox = NSButton(checkboxWithTitle: group.candidates[0].oldPath, target: nil, action: nil)
            checkbox.state = .on
            checkbox.toolTip = group.candidates[0].oldPath
            checkbox.lineBreakMode = .byTruncatingMiddle
            checkbox.setContentHuggingPriority(.defaultLow, for: .horizontal)
            checkbox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(checkbox)
            controls.append(.checkbox(group.candidates[0], checkbox))
        } else {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItem(withTitle: "Skip")
            popup.addItems(withTitles: group.candidates.map { $0.oldPath })
            popup.selectItem(at: 0)
            popup.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(popup)
            controls.append(.popup(group.candidates, popup))
        }
        row.frame = NSRect(x: 0, y: 0, width: width - 20, height: rowHeight)
        rowViews.append(row)
    }

    let stack = NSStackView(views: rowViews)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 4
    stack.frame = NSRect(x: 0, y: 0, width: width - 20, height: contentHeight)

    let scrollView = NSScrollView(
        frame: NSRect(x: 0, y: 0, width: width, height: visibleHeight)
    )
    scrollView.hasVerticalScroller = contentHeight > visibleHeight
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    scrollView.documentView = stack
    alert.accessoryView = scrollView

    guard alert.runModal() == .alertFirstButtonReturn else { return [] }

    var selected: [RepositoryExternalVCSMove] = []
    for control in controls {
        switch control {
        case let .checkbox(move, checkbox):
            if checkbox.state == .on { selected.append(move) }
        case let .popup(candidates, popup):
            let selectedIndex = popup.indexOfSelectedItem - 1
            guard candidates.indices.contains(selectedIndex) else { continue }
            selected.append(candidates[selectedIndex])
        }
    }
    return repositoryNonConflictingExternalVCSMoves(selected)
}

func handleArborVCSActionNotification(_ notification: Notification) {
    if let target = notification.userInfo?["projectPath"] as? String {
        guard projectWorkspace.path.map({ URL(fileURLWithPath: $0).standardizedFileURL.path })
            == URL(fileURLWithPath: target).standardizedFileURL.path else { return }
    }
    if let request = notification.object as? ArborVCSActionRequest {
        handleVCSActionRequest(request)
        return
    }
    guard let rawValue = notification.object as? String,
          let action = ArborVCSAction(rawValue: rawValue) else { return }
    switch action {
    case .searchEverywhere:
        projectWorkspace.showSearchEverywhere = true
    case .quickActions:
        presentVCSQuickActionsPanel()
    case .update:
        guard isArborVCSActionEnabled(.update, in: vcsActionContext) else { return }
        requestUpdateProject()
    case .reset:
        guard isArborVCSActionEnabled(.reset, in: vcsActionContext) else { return }
        beginHeadResetDialog()
    case .resetToRemoteBranch:
        resetCurrentBranchToRemote()
    case .commit:
        projectWorkspace.toolWindowMode = .commit
        toolWindowExpanded = true
    case .commitAndPush:
        projectWorkspace.toolWindowMode = .commit
        toolWindowExpanded = true
        beginCommitAndPush()
    case .push:
        beginPushDialog()
    case .fetch:
        guard isArborVCSActionEnabled(.fetch, in: vcsActionContext) else { return }
        doFetch(nil)
    case .fetchAll:
        guard isArborVCSActionEnabled(.fetchAll, in: vcsActionContext) else { return }
        doFetchAll()
    case .retryAutoFetch:
        gitSettings.autoFetchRunGeneration &+= 1
    case .enableAutoFetch:
        if let projectPath = projectWorkspace.path {
            GitIncomingCheckStrategySettings.saveProjectStrategy(.fetch, for: projectPath)
            gitSettings.projectIncomingCheckStrategyRaw = GitIncomingCheckStrategy.fetch.rawValue
        } else {
            incomingCheckStrategyRaw = GitIncomingCheckStrategy.fetch.rawValue
            gitAutoFetch = true
        }
    case .disableAutoFetchSuggestion:
        GitIncomingCheckStrategySettings.setSuggestionDisabled(true, for: projectWorkspace.path)
        GitIncomingCheckStrategySettings.setSuggestionCount(3, for: projectWorkspace.path)
    case .fetchPrune:
        guard isArborVCSActionEnabled(.fetchPrune, in: vcsActionContext) else { return }
        doFetchPrune()
    case .fetchUnshallow:
        guard isArborVCSActionEnabled(.fetchUnshallow, in: vcsActionContext) else { return }
        doFetchUnshallow()
    case .pull:
        presentPullDialog(rebase: nil)
    case .pullMerge:
        presentPullDialog(rebase: false)
    case .pullRebase:
        presentPullDialog(rebase: true)
    case .showStagingArea:
        guard isArborVCSActionEnabled(.showStagingArea, in: vcsActionContext) else { return }
        projectWorkspace.toolWindowMode = .commit
        toolWindowExpanded = true
        shelfWorkspace.isWorkspaceTabActive = false
    case .showShelf:
        guard isArborVCSActionEnabled(.showShelf, in: vcsActionContext) else { return }
        projectWorkspace.toolWindowMode = .commit
        toolWindowExpanded = true
        shelfWorkspace.isWorkspaceTabActive = true
        shelfWorkspace.tabRequestID &+= 1
    case .showStash:
        guard isArborVCSActionEnabled(.showStash, in: vcsActionContext) else { return }
        projectWorkspace.toolWindowMode = .commit
        toolWindowExpanded = true
        shelfWorkspace.isWorkspaceTabActive = true
        shelfWorkspace.tabRequestID &+= 1
    case .revertSelectedChanges:
        guard isArborVCSActionEnabled(.revertSelectedChanges, in: vcsActionContext),
              let path = vcsActionContext.selectedLocalChangePath else { return }
        restoreFileFromHead(
            path,
            prompt: "Revert selected changes?",
            confirmTitle: "Revert",
            feedbackTitle: "Changes reverted"
        )
    case .branches:
        loadRepoData()
        branchWorkspace.showPopover = true
    case .merge:
        guard isArborVCSActionEnabled(.merge, in: vcsActionContext) else { return }
        openMergeDialog(nil)
    case .rebase:
        guard isArborVCSActionEnabled(.rebase, in: vcsActionContext) else { return }
        openRebaseDialog(nil)
    case .stash:
        presentStashDialog()
    case .unstash:
        presentUnstashDialog()
    case .shelve:
        shelfWorkspace.showCreateDialog = true
    case .applyPatch:
        applyPatchFromFile()
    case .applyPatchFromClipboard:
        applyPatchFromClipboard()
    case .newBranch:
        guard isArborVCSActionEnabled(.newBranch, in: vcsActionContext) else { return }
        presentNewBranchDialog()
    case .newTag:
        beginNewTagDialog()
    case .configureRemotes:
        guard isArborVCSActionEnabled(.configureRemotes, in: vcsActionContext) else { return }
        beginConfigureRemotes()
    case .worktrees:
        projectWorkspace.toolWindowMode = .operations
        operationRecovery.viewMode = .worktrees
        toolWindowExpanded = true
        loadWorktrees()
    case .stageTracked:
        stageAll()
    case .stageAll:
        stageEverything()
    case .copyCurrentBranchName:
        guard branchWorkspace.branches.contains(where: { $0.isCurrent }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentBranchName, forType: .string)
        feedbackCenter.success("Copied branch name", detail: currentBranchName)
    case .resolveConflicts:
        openFirstConflictFromAction()
    case .revertResolved:
        guard isArborVCSActionEnabled(.revertResolved, in: vcsActionContext),
              let path = vcsActionContext.selectedResolvedConflictPath else { return }
        revertResolvedPath(path)
    case .fileCheckin:
        guard isArborVCSActionEnabled(.fileCheckin, in: vcsActionContext),
              let file = vcsActionContext.selectedFileAction else { return }
        beginFileCheckin(file.path)
    case .fileAdd:
        guard isArborVCSActionEnabled(.fileAdd, in: vcsActionContext),
              let file = vcsActionContext.selectedFileAction else { return }
        stageSelectedFileFromFileAction(file)
    case .fileAnnotate:
        guard isArborVCSActionEnabled(.fileAnnotate, in: vcsActionContext),
              let file = vcsActionContext.selectedFileAction else { return }
        annotateProjectFile(file.path)
    case .fileCompareSameVersion:
        guard isArborVCSActionEnabled(.fileCompareSameVersion, in: vcsActionContext),
              let file = vcsActionContext.selectedFileAction else { return }
        openFileSameVersionComparison(path: file.path)
    case .fileCompareSelectedRevision:
        guard isArborVCSActionEnabled(.fileCompareSelectedRevision, in: vcsActionContext),
              let file = vcsActionContext.selectedFileAction else { return }
        openFileSelectedRevisionComparison(path: file.path, isDirectory: file.isDirectory)
    case .fileCompareWithBranch:
        guard isArborVCSActionEnabled(.fileCompareWithBranch, in: vcsActionContext),
              let file = vcsActionContext.selectedFileAction else { return }
        openFileReferenceComparison(path: file.path, isDirectory: file.isDirectory)
    case .fileHistory:
        guard isArborVCSActionEnabled(.fileHistory, in: vcsActionContext),
              let file = vcsActionContext.selectedFileAction,
              !file.isDirectory else { return }
        showFileHistory(file.rootRelativePath, rootPath: file.owningRootPath)
    case .showLog:
        projectWorkspace.toolWindowMode = .log
        toolWindowExpanded = true
        projectPanelExpanded = false
        fileWorkspace.selection = nil
        fileWorkspace.fileSelection = nil
        fileWorkspace.selectionModePath = nil
        logList.viewMode = .graph
        loadLog()
    case .showExternalLog:
        // ProjectCommands routes this action directly through openWindow so
        // it targets the focused project's path. Keep the notification
        // handler exhaustive for quick-action/request decoding without
        // opening one external window per subscribed ContentView.
        break
    case .showOperations:
        projectWorkspace.toolWindowMode = .operations
        operationRecovery.viewMode = .history
        toolWindowExpanded = true
    case .showGitRoots:
        projectWorkspace.toolWindowMode = .operations
        operationRecovery.viewMode = .roots
        toolWindowExpanded = true
        loadMultiRoots()
    case .showGitConsole:
        projectWorkspace.toolWindowMode = .operations
        operationRecovery.viewMode = .console
        toolWindowExpanded = true
    case .gitLfs:
        presentLfsPanel()
    case .gitHooks:
        presentHooksPanel()
    case .refresh:
        refreshAll()
    }
}

func handleVCSActionRequest(_ request: ArborVCSActionRequest) {
    let shelfName = request.shelfName

    func pathsMatch(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).standardizedFileURL.path
            == URL(fileURLWithPath: rhs).standardizedFileURL.path
    }

    if let requestedProjectPath = request.projectPath {
        guard let projectPath = projectWorkspace.path, pathsMatch(requestedProjectPath, projectPath) else { return }
    }
    let requestTargetsSecondaryShelfRoot = request.rootPath.map {
        !shelfRootSelectionIsPrimary(
            selectedRootPath: $0,
            primaryRootPath: primaryShelfRootPath
        )
    } ?? false
    if requestTargetsSecondaryShelfRoot,
       !isSecondaryShelfRootScopedAction(request.kind) {
        feedbackCenter.error(
            "Shelf action unavailable",
            detail: request.rootPath ?? "",
            nextStep: "This Shelf action is not yet available for a secondary Git root.",
            localized: false
        )
        return
    }
    if isShelfSemanticAction(request.kind),
       !shelfActionRootMatchesCurrentRoot(
           requestedRootPath: request.rootPath,
           currentRootPath: activeShelfRootPath
       ) {
        feedbackCenter.error(
            "Shelf action unavailable",
            detail: request.rootPath ?? "",
            nextStep: "Activate the Git root that owns this Shelf, then retry the action.",
            localized: false
        )
        return
    }
    if let requestedRootPath = request.rootPath {
        let isCurrentRoot = repo?.workdir().map { pathsMatch(requestedRootPath, $0) } == true
        let isActiveShelfRoot = isShelfSemanticAction(request.kind)
            && shelfActionRootMatchesCurrentRoot(
                requestedRootPath: requestedRootPath,
                currentRootPath: activeShelfRootPath
            )
            && shelfWorkspace.rootRepository != nil
        if isShelfSemanticAction(request.kind) {
            guard isCurrentRoot || isActiveShelfRoot else { return }
        } else {
            guard isCurrentRoot || (try? openRepository(path: requestedRootPath)) != nil else {
                return
            }
        }
    }

    switch request.kind {
    case .restoreShelf:
        guard !shelfName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        restoreDeletedShelve(shelfName, rootPath: request.rootPath)
    case .restoreShelfPaths:
        guard !shelfName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !(request.shelfPaths ?? []).isEmpty else { return }
        if let timestamp = request.shelfRestoreTimestamp {
            undoShelfDeletion(
                shelfName,
                originalTimestamp: timestamp,
                rootPath: request.rootPath
            )
        } else {
            restoreDeletedShelve(shelfName, rootPath: request.rootPath)
        }
    case .deleteDeletedShelfPaths:
        guard !shelfName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let paths = request.shelfPaths,
              !paths.isEmpty else { return }
        doShelveDeleteDeletedPaths(shelfName, paths, rootPath: request.rootPath)
    case .undoShelfDeletion:
        guard !shelfName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let timestamp = request.shelfRestoreTimestamp else { return }
        undoShelfDeletion(
            shelfName,
            originalTimestamp: timestamp,
            rootPath: request.rootPath
        )
    case .undoShelfDeletions:
        guard let names = request.shelfNames,
              let timestamps = request.shelfRestoreTimestamps else { return }
        undoShelfDeletions(
            names,
            originalTimestamps: timestamps,
            rootPath: request.rootPath
        )
    case .dropShelf:
        guard !shelfName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        doShelveDrop(shelfName, rootPath: request.rootPath)
    case .showSavedChanges:
        showSavedChanges(request)
    case .showLogApplyAffectedFiles:
        guard let rootPath = request.rootPath,
              let recovery = request.logApplyRecovery,
              pathsMatch(rootPath, recovery.rootPath) else { return }
        showLogApplyAffectedFiles(recovery)
    case .showOperationDetails:
        guard let notificationID = request.operationNotificationID else { return }
        operationRecovery.logFocusNotificationID = notificationID
        operationRecovery.viewMode = .history
        projectWorkspace.toolWindowMode = .operations
        toolWindowExpanded = true
    case .showLogRanges:
        guard let ranges = request.logRevisionRanges else { return }
        showLogRevisionRanges(ranges)
    case .showFindMergedReport:
        guard let reportID = request.findMergedReportID else { return }
        openFindMergedReport(reportID: reportID)
    case .rewordCommit:
        guard let rootPath = request.rootPath,
              let commitID = request.rewordCommitID else { return }
        openRewordCommit(rootPath: rootPath, commitID: commitID)
    case .undoRewordCommit:
        guard let rootPath = request.rootPath,
              let context = request.rewordUndo else { return }
        undoRewordCommit(rootPath: rootPath, context: context)
    case .undoUncommit:
        guard let rootPath = request.rootPath,
              let originalCommitID = request.uncommitCommitID,
              let expectedHead = request.uncommitExpectedHead,
              let expectedBranch = request.uncommitExpectedBranch else { return }
        undoUncommit(
            rootPath: rootPath,
            originalCommitID: originalCommitID,
            expectedHead: expectedHead,
            expectedBranch: expectedBranch
        )
    case .undoRebase:
        guard let rootPath = request.rootPath,
              let initialHead = request.rebaseUndoInitialHead,
              let expectedHead = request.rebaseUndoExpectedHead,
              let branch = request.rebaseUndoBranch,
              !initialHead.isEmpty,
              !expectedHead.isEmpty,
              !branch.isEmpty else { return }
        undoLastRebase(
            RebaseUndoTarget(
                repositoryPath: rootPath,
                branch: branch,
                initialHead: initialHead,
                expectedHead: expectedHead,
                protectionCommitID: request.rebaseUndoProtectionCommit
            )
        )
    case .undoLogSelectedChanges:
        guard let rootPath = request.rootPath,
              let initialHead = request.logSelectedChangesUndoInitialHead,
              let expectedHead = request.logSelectedChangesUndoExpectedHead,
              let branch = request.logSelectedChangesUndoBranch,
              !initialHead.isEmpty,
              !expectedHead.isEmpty else { return }
        undoLogSelectedChanges(
            LogSelectedChangesUndoTarget(
                repositoryPath: rootPath,
                branch: branch,
                initialHead: initialHead,
                expectedHead: expectedHead
            )
        )
    case .restoreApplyLocalChanges:
        openApplyLocalChangesRestore(request)
    case .resumeRebase:
        guard let rootPath = request.rootPath else { return }
        openPersistedRebaseRecovery(rootPath: rootPath, branch: request.rebaseBranch)
    case .retryShelfBatch:
        guard let names = request.shelfNames,
              let operation = request.shelfBatchOperation else { return }
        switch operation {
        case .apply:
            doShelveUnshelveShelves(
                names,
                targetName: request.shelfBatchTargetName,
                removeApplied: request.shelfBatchRemoveApplied ?? false,
                rootPath: request.rootPath,
                preservePreviousItems: true
            )
        case .pop:
            doShelvePopShelves(
                names,
                rootPath: request.rootPath,
                preservePreviousItems: true
            )
        case .drop:
            doShelveDropShelves(
                names,
                rootPath: request.rootPath,
                preservePreviousItems: true
            )
        }
    case .retryShelfMemberBatch:
        guard let persistedGroups = request.shelfMemberGroups,
              let operation = request.shelfMemberBatchOperation,
              !persistedGroups.isEmpty else { return }
        let groups = persistedGroups.map {
            ShelfPathDeleteGroup(shelfName: $0.shelfName, paths: $0.paths)
        }
        switch operation {
        case .unshelve:
            doShelveUnshelvePathGroups(
                groups,
                removeApplied: false,
                sourceIsDeleted: false,
                targetName: request.shelfMemberBatchTargetName,
                rootPath: request.rootPath,
                preservePreviousItems: true
            )
        case .unshelveAndRemove:
            doShelveUnshelvePathGroups(
                groups,
                removeApplied: true,
                sourceIsDeleted: false,
                targetName: request.shelfMemberBatchTargetName,
                rootPath: request.rootPath,
                preservePreviousItems: true
            )
        case .unshelveDeleted:
            doShelveUnshelvePathGroups(
                groups,
                removeApplied: false,
                sourceIsDeleted: true,
                targetName: request.shelfMemberBatchTargetName,
                rootPath: request.rootPath,
                preservePreviousItems: true
            )
        case .unshelveDeletedAndRemove:
            doShelveUnshelvePathGroups(
                groups,
                removeApplied: true,
                sourceIsDeleted: true,
                targetName: request.shelfMemberBatchTargetName,
                rootPath: request.rootPath,
                preservePreviousItems: true
            )
        case .drop:
            doShelveDropPathGroups(
                groups,
                rootPath: request.rootPath,
                preservePreviousItems: true
            )
        case .deleteDeleted:
            doShelveDeleteDeletedPathGroups(
                groups,
                rootPath: request.rootPath,
                preservePreviousItems: true
            )
        }
    case .retryShelfLifecycleBatch:
        guard let names = request.shelfNames,
              let operation = request.shelfLifecycleOperation else { return }
        switch operation {
        case .restoreDeleted:
            restoreDeletedShelves(
                names,
                rootPath: request.rootPath,
                preservePreviousItems: true
            )
        case .deleteDeleted:
            deleteDeletedShelves(
                names,
                confirm: false,
                rootPath: request.rootPath,
                preservePreviousItems: true
            )
        }
    case .retryShelfDeletePlan:
        guard let persistedPlan = request.shelfDeletePlan else { return }
        deleteShelfPlan(
            persistedPlan.shelfDeletePlan,
            rootPath: request.rootPath,
            preservePreviousItems: true
        )
    case .retryLogApply:
        guard let recovery = request.logApplyRecovery else { return }
        retryLogApplyRecovery(recovery)
    case .retryStashBranch:
        guard let rootPath = request.rootPath,
              let retry = request.stashBranchRetry else { return }
        retryStashBranch(rootPath: rootPath, retry: retry)
    case .retryExternalVCSAction:
        guard let rootPath = request.rootPath,
              let action = request.externalVCSAction else { return }
        retryExternalVCSAction(rootPath: rootPath, action: action)
    case .openGpgAgentSettings:
        gitSettings.showGpgAgentSettings = true
    case .openIdentitySettings:
        gitSettings.showIdentitySettings = true
    case .rollbackMultiRootCheckout:
        guard let reference = request.checkoutReference,
              let persistedTargets = request.checkoutTargets,
              !persistedTargets.isEmpty else { return }
        rollbackMultiRootCheckout(
            persistedTargets.map { $0.makeLiveTarget() },
            reference: reference
        )
    case .rollbackMultiRootBranchCreate:
        guard let branchName = request.multiRootBranchName,
              let persistedTargets = request.multiRootBranchCreateRollbackTargets,
              !persistedTargets.isEmpty else { return }
        rollbackMultiRootBranchCreate(
            persistedTargets.map { $0.makeLiveTarget() },
            branchName: branchName
        )
    case .keepMultiRootBranchCreatePartial:
        guard let branchName = request.multiRootBranchName else { return }
        feedbackCenter.success(
            "Partial branch creation kept",
            detail: branchName,
            notificationID: multiRootBranchCreateRollbackNotificationID(),
            notificationGroup: .standard
        )
    case .rollbackMultiRootBranchRename:
        guard let targets = request.multiRootBranchRenameRollbackTargets,
              !targets.isEmpty else { return }
        rollbackMultiRootBranchRename(targets)
    case .keepMultiRootBranchRenamePartial:
        guard let newName = request.multiRootBranchRenameNewName else { return }
        feedbackCenter.success(
            "Partial branch renames kept",
            detail: newName,
            notificationID: multiRootBranchRenameRollbackNotificationID(),
            notificationGroup: .standard
        )
    case .rollbackMultiRootMerge:
        guard let persistedTargets = request.multiRootMergeRollbackTargets,
              !persistedTargets.isEmpty else { return }
        rollbackMultiRootMerge(
            persistedTargets.map { $0.makeLiveTarget() },
            branchName: request.multiRootMergeBranchName,
            priorResultRows: request.multiRootMergeRollbackResultRows ?? []
        )
    case .deleteMultiRootMergeBranch:
        guard let branchName = request.multiRootMergeDeleteBranchName,
              let rootPaths = request.multiRootMergeDeleteRootPaths,
              !rootPaths.isEmpty else { return }
        confirmAndDeleteMultiRootMergedBranch(
            name: branchName,
            selectedRootPaths: Set(rootPaths)
        )
    case .restoreDeletedBranches:
        guard let targets = request.branchDeleteRecoveryTargets,
              !targets.isEmpty else { return }
        restoreDeletedBranchesFromSemanticTargets(targets)
    case .viewDeletedBranchCommits:
        guard let targets = request.branchDeleteRecoveryTargets,
              !targets.isEmpty else { return }
        viewDeletedBranchCommitsFromSemanticTargets(targets)
    case .rollbackMultiRootUpdate:
        guard let targets = request.multiRootUpdateRollbackTargets,
              !targets.isEmpty else { return }
        if let notificationID = multiRootUpdateNotificationID(partial: true) {
            feedbackCenter.expire(notificationID: notificationID)
        }
        rollbackMultiRootUpdate(targets)
    case .rollbackSubmoduleUpdate:
        guard let targets = request.multiRootUpdateRollbackTargets,
              !targets.isEmpty else { return }
        rollbackMultiRootUpdate(
            targets,
            completionTitle: "Submodule update undone",
            operationTitle: "Undo Submodule Update",
            notificationID: submoduleUpdateRollbackNotificationID(),
            rollbackKind: .rollbackSubmoduleUpdate
        )
    case .retrySubmoduleOperation:
        guard let retry = request.submoduleRetry else { return }
        runSubmoduleOperation(retry)
    case .undoSubmoduleOperation:
        guard let rootPath = request.rootPath,
              let undo = request.submoduleUndo else { return }
        undoSubmoduleOperation(undo, rootPath: rootPath)
    case .rollbackMultiRootReset:
        guard let targets = request.multiRootResetRollbackTargets,
              !targets.isEmpty else { return }
        rollbackMultiRootReset(targets)
    case .rollbackResetRecovery:
        guard let targets = request.resetRecoveryTargets,
              !targets.isEmpty else { return }
        rollbackResetRecovery(targets)
    case .keepResetRecovery:
        guard let targets = request.resetRecoveryTargets,
              !targets.isEmpty else { return }
        keepResetRecovery(targets)
    case .multiRootRebaseRecovery:
        guard let action = request.multiRootRebaseRecoveryAction else { return }
        if let projectPath = projectWorkspace.path {
            restorePersistedMultiRootRebaseSession(for: projectPath)
        }
        if let requestedSessionID = request.multiRootRebaseSessionID {
            guard rebaseWorkspace.multiRootSession?.id.uuidString == requestedSessionID else { return }
        }
        switch action {
        case .resume:
            resumeMultiRootRebase()
        case .retry:
            retryMultiRootRebase()
        case .stageAndRetry:
            guard let rootPath = request.rootPath,
                  let sessionID = request.multiRootRebaseSessionID.flatMap(UUID.init(uuidString:)) else {
                return
            }
            stageAndRetryMultiRootRebaseContinue(
                rootPath: rootPath,
                sessionID: sessionID
            )
        case .openRecovery:
            guard let rootPath = request.rootPath else { return }
            openMultiRootConflictResolver(preferredRootPath: rootPath)
        case .rollback:
            rollbackPersistedMultiRootRebase()
        case .keepPartial:
            keepPersistedMultiRootRebasePartial()
        case .undo:
            guard let persistedTargets = request.multiRootRebaseRollbackTargets,
                  !persistedTargets.isEmpty else { return }
            rollbackMultiRootRebase(
                persistedTargets.map { $0.makeLiveTarget() },
                completionTitle: "Multi-root rebase undone"
            )
        }
    case .operationRecovery:
        guard let action = request.operationRecoveryAction,
              let rootPath = request.rootPath else { return }
        let isCurrentRoot = repo?.workdir().map { pathsMatch(rootPath, $0) } == true
        guard isCurrentRoot else {
            openOperationRecovery(rootPath: rootPath)
            return
        }
        guard let currentRepo = repo else { return }
        let currentState: OperationState?
        do {
            currentState = try currentRepo.operationState()
        } catch {
            return
        }
        guard let currentState else { return }
        operationRecovery.operation = currentState
        switch action {
        case .continueOperation:
            doOperationContinue()
        case .skip:
            doOperationSkip()
        case .abort:
            doOperationAbort()
        case .openRecovery:
            openOperationRecovery(rootPath: rootPath)
        }
    case .autoFetchRecovery:
        guard let action = request.autoFetchRecoveryAction else { return }
        switch action {
        case .fetchAll:
            doFetchAll(rootPaths: request.autoFetchRootPaths)
        case .retryCheck:
            gitSettings.autoFetchRunGeneration &+= 1
        case .enable:
            if let projectPath = projectWorkspace.path {
                GitIncomingCheckStrategySettings.saveProjectStrategy(.fetch, for: projectPath)
                gitSettings.projectIncomingCheckStrategyRaw = GitIncomingCheckStrategy.fetch.rawValue
            } else {
                incomingCheckStrategyRaw = GitIncomingCheckStrategy.fetch.rawValue
                gitAutoFetch = true
            }
        case .doNotAskAgain:
            GitIncomingCheckStrategySettings.setSuggestionDisabled(true, for: projectWorkspace.path)
            GitIncomingCheckStrategySettings.setSuggestionCount(3, for: projectWorkspace.path)
        }
    case .retryMultiRootOperation:
        guard let operation = request.multiRootRetryOperation,
              let rootPaths = request.multiRootRetryRootPaths,
              !rootPaths.isEmpty else { return }
        switch operation {
        case .update:
            guard let rebase = request.multiRootRetryRebase else { return }
            retryMultiRootUpdateFailedRoots(
                rootPaths: rootPaths,
                rebase: rebase,
                rebaseRootPaths: request.multiRootRetryRebaseRootPaths
            )
        case .fetch:
            executeMultiRootOperation(.fetch, rootPaths: rootPaths)
        case .pullMerge:
            executeMultiRootOperation(
                .pullMerge,
                rootPaths: rootPaths,
                priorRevisionRanges: request.multiRootRetryLogRevisionRanges ?? []
            )
        case .pullRebase:
            executeMultiRootOperation(
                .pullRebase,
                rootPaths: rootPaths,
                priorRevisionRanges: request.multiRootRetryLogRevisionRanges ?? []
            )
        case .push:
            retryMultiRootPushFailedRoots(
                rootPaths: rootPaths,
                tagMode: request.multiRootPushTagMode.flatMap { PushDialogTagMode(rawValue: $0.rawValue) },
                skipHooks: request.multiRootPushSkipHooks,
                force: request.multiRootPushForce,
                forceWithLease: request.multiRootPushForceWithLease,
                priorViewCommitRanges: request.multiRootRetryLogRevisionRanges,
                priorResultRows: request.multiRootRetryResultRows
            )
        case .pushRecovery:
            guard let rebase = request.multiRootRetryRebase else { return }
            retryMultiRootPushFailedRoots(
                rootPaths: rootPaths,
                recoveryRebase: rebase,
                recoveryUpdateRootPaths: request.multiRootRetryUpdateRootPaths,
                tagMode: request.multiRootPushTagMode.flatMap { PushDialogTagMode(rawValue: $0.rawValue) },
                skipHooks: request.multiRootPushSkipHooks,
                force: false,
                forceWithLease: false,
                priorViewCommitRanges: request.multiRootRetryLogRevisionRanges,
                priorResultRows: request.multiRootRetryResultRows
            )
        case .checkoutUpdate:
            guard let reference = request.checkoutReference,
                  let detach = request.multiRootRetryDetach,
                  let rebase = request.multiRootRetryRebase,
                  let checkoutMode = request.multiRootRetryCheckoutMode else { return }
            retryMultiRootCheckoutAndUpdateFailedRoots(
                reference: reference,
                selectedRootPaths: rootPaths,
                detach: detach,
                rebase: rebase,
                checkoutMode: checkoutMode
            )
        case .commit:
            guard let retry = request.multiRootCommitRetry else { return }
            let selectedChanges = retry.selectedPaths?.map { $0.makeLiveSelection() }
            performMultiRootCommit(
                rootPaths: rootPaths,
                message: retry.message,
                options: retry.makeLiveOptions(),
                allowForceRetry: true,
                pushAfterCommit: retry.pushAfterCommit ?? false,
                priorPushRootPaths: retry.pushRootPaths ?? [],
                selectedChanges: selectedChanges
            )
        case .pushAfterCommit:
            executeMultiRootPush(selectedRootPaths: rootPaths, fromCommit: true)
        case .stage:
            if let changePaths = request.multiRootRetryChangePaths,
               !changePaths.isEmpty {
                runMultiRootChangeMutation(operation: .stage, paths: changePaths)
                return
            }
            guard rootPaths.count == 1,
                  let rootPath = rootPaths.first,
                  let path = request.multiRootRetryPath else { return }
            stageMultiRootPath(rootPath: rootPath, path: path)
        case .unstage:
            if let changePaths = request.multiRootRetryChangePaths,
               !changePaths.isEmpty {
                runMultiRootChangeMutation(operation: .unstage, paths: changePaths)
                return
            }
            guard rootPaths.count == 1,
                  let rootPath = rootPaths.first,
                  let path = request.multiRootRetryPath else { return }
            unstageMultiRootPath(rootPath: rootPath, path: path)
        case .stageAll:
            guard rootPaths.count == 1, let rootPath = rootPaths.first else { return }
            stageAllMultiRootPath(rootPath: rootPath)
        case .unstageAll:
            guard rootPaths.count == 1, let rootPath = rootPaths.first else { return }
            unstageAllMultiRootPath(rootPath: rootPath)
        }
    case .retryPush:
        guard let rootPath = request.rootPath,
              let push = request.pushRecovery else { return }
        retrySingleRootPush(
            rootPath: rootPath,
            push: push,
            viewCommitRanges: request.logRevisionRanges ?? []
        )
    case .retryPushRecovery:
        guard let rootPath = request.rootPath,
              let recovery = request.pushRecovery else { return }
        retrySingleRootPushRecovery(
            rootPath: rootPath,
            recovery: recovery,
            viewCommitRanges: request.logRevisionRanges ?? []
        )
    }
}

}
