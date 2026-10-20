import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
    /// Presents the shared IntelliJ-style Create Patch configuration before
    /// any Git process starts. The callback is dispatched after the sheet is
    /// dismissed so a native save panel never competes with SwiftUI modal
    /// presentation.
    func presentPatchExportDialog(
        title: String,
        defaultFileName: String,
        repositoryRootPath: String,
        paths: [String],
        allowsBaseDirectory: Bool,
        onExport: @escaping (PatchExportOptions) -> Void
    ) {
        patchExportRequest = PatchExportRequest(
            title: title,
            defaultFileName: defaultFileName,
            repositoryRootPath: repositoryRootPath,
            paths: paths,
            allowsBaseDirectory: allowsBaseDirectory,
            initialCopyToClipboard: PatchExportSettings.copyToClipboard(for: repositoryRootPath),
            initialEncoding: PatchExportSettings.encoding(for: repositoryRootPath),
            onExport: onExport
        )
    }

    func patchExportDestination(
        defaultFileName: String,
        repositoryRootPath: String
    ) -> URL? {
        choosePatchExportDestination(
            defaultFileName: defaultFileName,
            repositoryRootPath: repositoryRootPath
        )
    }

/// Register the persisted project Git executable for the roots currently
/// known by this window. The Rust engine resolves the longest matching root
/// for every system-Git command, while the application-level executable stays
/// the fallback for projects without an override.
func applyProjectGitExecutableOverride(for projectPath: String, roots: [String]) {
    guard let override = GitExecutableSettings.projectOverride(for: projectPath) else {
        clearProjectGitExecutable(projectPath: projectPath)
        return
    }
    let registeredRoots = GitExecutableSettings.registeredRoots(
        projectPath: projectPath,
        repositoryRoot: nil,
        discoveredRoots: roots
    )
    do {
        _ = try setProjectGitExecutable(
            projectPath: projectPath,
            rootPaths: registeredRoots,
            path: override
        )
    } catch {
        DiagnosticsLogger.shared.record(
            operation: "settings",
            repositoryPath: projectPath,
            code: "project-git-executable-invalid"
        )
    }
}

/// Applies the multi-root Branches dashboard selection as one VCS Log query.
/// The root is part of every filter, so identically named branches in two
/// repositories remain independent while their histories are shown together.
func applyLogBranchFilters(_ filters: [LogRootBranchFilter]) {
    var seen = Set<LogRootBranchFilter>()
    let normalized = filters.filter { filter in
        let rootPath = filter.rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = filter.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootPath.isEmpty, !branch.isEmpty else { return false }
        return seen.insert(LogRootBranchFilter(rootPath: rootPath, branch: branch)).inserted
    }
    guard !normalized.isEmpty else { return }
    logAggregateBranchFilters = normalized
    logAggregateRevisionRanges = []
    logAggregateRootPaths = []
    logAggregateRepositories = [:]
    logAggregateLoadedCounts = [:]
    logActiveRootPath = nil
    logActiveRepo = nil
    logActiveBranches = []
    logActiveRemoteBranches = []
    logActiveRemotes = []
    logStartRevision = ""
    logStartRevisions = []
    logSelection = nil
    logSelectedIDs = []
    logViewMode = .graph
    loadLog()
}

func applyLogTab(_ tab: LogTabDescriptor) {
    applyLogTabRootContext(tab.rootPath)
    logAggregateBranchFilters = tab.aggregateBranchFilters ?? []
    logAggregateRevisionRanges = (tab.aggregateRevisionRanges ?? tab.updateInfoRanges ?? [])
        .map(LogRootRevisionRange.init)
    if let aggregateRootPaths = tab.aggregateRootPaths {
        logAggregateRootPaths = Set(normalizedLogRootPaths(aggregateRootPaths))
    } else if !externalLogWindow {
        logAggregateRootPaths = []
    }
    logAggregateRepositories = [:]
    logAggregateLoadedCounts = [:]
    logAggregatePageCursors = [:]
    logViewMode = tab.viewMode
    let tabRevisions = tab.startRevisions.isEmpty
        ? (tab.startRevision.isEmpty ? [] : [tab.startRevision])
        : tab.startRevisions
    setLogStartRevisions(tabRevisions)
    logPathFilter = tab.pathFilter
    logPathFilterSelections = normalizedLogPathFilterSelections(tab.pathSelections)
    logVisibleRootPathsRaw = tab.visibleRootPathsRaw
    logAuthorFilter = tab.authorFilter
    logMessageFilter = tab.messageFilter
    logMessageRegex = tab.messageRegex
    logMessageMatchCase = tab.messageMatchCase
    logSinceText = tab.sinceText
    logUntilText = tab.untilText
    logCommandFilter = tab.commandFilter
    logCommandEntries = []
    hasMoreLogCommand = true
    logCommandError = nil
    logFollow = tab.follow
    logGraphSortModeRaw = tab.graphSortModeRaw
    compareRev1 = tab.compareRevision1
    compareRev2 = tab.compareRevision2
    compareRepositoryPath = tab.compareRepositoryPath
    compareWithWorkingTree = tab.compareWithWorkingTree
    branchCompareFirstFilter = tab.compareFirstFilter ?? BranchComparisonFilter()
    branchCompareSecondFilter = tab.compareSecondFilter ?? BranchComparisonFilter()
    if let path = tab.compareRepositoryPath,
       let comparisonRepo = try? openRepository(path: path) {
        activateComparisonRepository(comparisonRepo, rootPath: path)
    } else {
        activeCompareRepo = nil
    }
    logEntries = []
    isShowingCachedLogSnapshot = false
    logSelection = tab.selection
    logSelectedIDs = tab.selectedIDs
    logPageCursor = nil
    reflogEntries = []
    let restoredReflogRoot = tab.reflogRootPath
        ?? (tab.viewMode == .reflog ? tab.rootPath : nil)
    reflogRootPath = restoredReflogRoot.map(canonicalExternalLogPath)
    reflogRootRepo = nil
    reflogSelection = tab.reflogSelection
    reflogSelectedIDs = Set(tab.reflogSelectedIDs ?? [])
    logDetailCommit = nil
    reflogDetailCommit = nil
    reflogDetailCommits = []
    reflogDetailLoadTask?.cancel()
    reflogDetailLoadTask = nil
    hasMoreLog = true
}

func applyLogTabRootContext(_ rootPath: String?) {
    guard let rootPath,
          !rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        clearLogActiveRootContext()
        return
    }
    let normalizedRootPath = canonicalExternalLogPath(rootPath)
    let primaryRootPath = repo?.workdir().map(canonicalExternalLogPath)
    if normalizedRootPath == primaryRootPath {
        clearLogActiveRootContext()
        return
    }
    logActiveRootPath = normalizedRootPath
    guard let rootRepo = try? openRepository(path: normalizedRootPath) else {
        logActiveRepo = nil
        logActiveBranches = []
        logActiveRemoteBranches = []
        logActiveRemotes = []
        return
    }
    logActiveRepo = rootRepo
    logActiveBranches = (try? rootRepo.branchList()) ?? []
    logActiveRemoteBranches = (try? rootRepo.remoteBranchList()) ?? []
    logActiveRemotes = (try? rootRepo.remoteList()) ?? []
}

func applyManualLogPathFilter() {
    let roots = logStructureFilterRootPaths + availableReflogRootPaths
    setLogPathFilterSelections(parseLogPathFilterEditorText(logPathFilter, roots: roots))
}

func applyLogPathsEditor() {
    isLogPathsEditorPresented = false
    let roots = logStructureFilterRootPaths + availableReflogRootPaths
    setLogPathFilterSelections(parseLogPathFilterEditorText(logPathsEditorText, roots: roots))
}

func applyLogPathsTreeChooser() {
    isLogPathsTreeChooserPresented = false
    setLogPathFilterSelections(Array(logPathsTreeChooserSelections))
}

/// Export the selected commit's parent-to-commit diff as a portable patch.
/// Keep the revision arguments separate from the Git command so commit ids
/// and repository content can never become shell syntax. Merge commits use
/// the first parent, matching the default parent shown by the Changes browser.
func createPatchFromLog(_ commit: CommitInfo) {
    guard let repo = logRepository(for: commit) else { return }

    guard let repositoryRootPath = repo.workdir(), !repositoryRootPath.isEmpty else { return }
    presentPatchExportDialog(
        title: "Create Patch",
        defaultFileName: "\(commit.shortId).patch",
        repositoryRootPath: repositoryRootPath,
        paths: [],
        allowsBaseDirectory: false
    ) { options in
        let destination = options.copyToClipboard
            ? nil
            : self.patchExportDestination(
                defaultFileName: "\(commit.shortId).patch",
                repositoryRootPath: repositoryRootPath
            )
        guard options.copyToClipboard || destination != nil else { return }
        PatchExportSettings.save(options, for: repositoryRootPath)

        let command: String
        let baseArguments: [String]
        if let parent = commit.parentIds.first {
            command = "diff"
            baseArguments = ["--binary", "--no-ext-diff", parent, commit.id]
        } else {
            command = "show"
            baseArguments = ["--format=", "--binary", "--no-ext-diff", "--root", commit.id]
        }
        guard let arguments = patchExportGitArguments(
            baseArguments: baseArguments,
            repositoryRootPath: repositoryRootPath,
            paths: [],
            options: options
        ) else { return }

        self.beginFeedbackOperation(options.copyToClipboard ? "Copy patch" : "Create patch")
        Task.detached(priority: .userInitiated) {
            do {
                let result = try repo.runGitCommand(command: command, args: arguments)
                guard result.exitCode == 0 else {
                    let detail = result.stderr.isEmpty ? result.stdout : result.stderr
                    throw NSError(
                        domain: "Arbor.Git",
                        code: Int(result.exitCode),
                        userInfo: [NSLocalizedDescriptionKey: detail]
                    )
                }
                guard !result.stdoutBytes.isEmpty else {
                    throw NSError(
                        domain: "Arbor.Git",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The selected revision has no patch output."]
                    )
                }
                let message = commit.summary + (commit.messageBody.isEmpty ? "" : "\n\n\(commit.messageBody)")
                let patch = patchTextWithCommitMessage(result.stdout, commitMessage: message)
                guard !patch.isEmpty else {
                    throw NSError(
                        domain: "Arbor.Git",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The selected revision has no patch output."]
                    )
                }
                if let destination {
                    try patchExportData(
                        result.stdoutBytes,
                        commitMessage: message,
                        encoding: options.encoding
                    )
                        .write(to: destination, options: .atomic)
                }
                await MainActor.run {
                    if options.copyToClipboard {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(patch, forType: .string)
                    }
                    self.feedbackCenter.success(
                        options.copyToClipboard ? "Patch copied" : "Patch created",
                        detail: options.copyToClipboard
                            ? commit.shortId
                            : destination?.lastPathComponent ?? ""
                    )
                }
            } catch {
                await MainActor.run {
                    self.feedbackCenter.error(
                        options.copyToClipboard ? "Copy patch failed" : "Create patch failed",
                        detail: errorMessage(error),
                        nextStep: "Check the selected revision and destination, then retry."
                    )
                }
            }
        }
    }
}

/// Export or copy the selected Changes Browser rows as one patch. Each group
/// is diffed against its own commit parent, then the textual patches are
/// joined only after every Git command succeeds. The action is intentionally
/// fail-closed for duplicate paths because a plain patch cannot express the
/// ordering of two revisions of the same file.
func createPatchFromLogSelection(_ records: [LogChangeRecord]) {
    createPatchFromLogSelection(records, copyToClipboard: false)
}

func copyPatchFromLogSelection(_ records: [LogChangeRecord]) {
    createPatchFromLogSelection(records, copyToClipboard: true)
}

func createPatchFromLogSelection(
    _ records: [LogChangeRecord],
    copyToClipboard: Bool
) {
    guard canCreateLogPatchSelection(records) else { return }

    let groups = logChangePatchGroups(records)
    let requests = groups.compactMap { group -> (Repository, CommitInfo, UInt32?, [String])? in
        guard let first = group.first,
              let repo = logRepository(for: first.commit) else {
            return nil
        }

        var paths: [String] = []
        var seenPaths = Set<String>()
        for record in group {
            for path in [record.change.oldPath, record.change.path].compactMap({ $0 }) {
                guard !path.isEmpty, seenPaths.insert(path).inserted else { continue }
                paths.append(path)
            }
        }
        guard !paths.isEmpty else { return nil }
        return (repo, first.commit, first.parentIndex, paths)
    }
    guard requests.count == groups.count, !requests.isEmpty else { return }

    let firstCommit = records[0].commit
    let defaultFileName = records.count == 1
        ? "\(firstCommit.shortId).patch"
        : "selected.patch"
    let repositoryRootPaths = Set(requests.compactMap { $0.0.workdir() })
    guard !repositoryRootPaths.isEmpty else { return }
    let sharedRootPath = repositoryRootPaths.count == 1 ? repositoryRootPaths.first : nil
    let exportRootPath = sharedRootPath ?? repositoryRootPaths.sorted().first!
    let allPaths = requests.flatMap { $0.3 }

    let performExport: (PatchExportOptions) -> Void = { options in
        let destination = options.copyToClipboard
            ? nil
            : self.patchExportDestination(
                defaultFileName: defaultFileName,
                repositoryRootPath: exportRootPath
            )
        guard options.copyToClipboard || destination != nil else { return }
        PatchExportSettings.save(options, for: exportRootPath)

        self.beginFeedbackOperation(options.copyToClipboard ? "Copy patch" : "Create patch")
        Task.detached(priority: .userInitiated) {
            do {
                var patchParts: [Data] = []
                var patchTextParts: [String] = []
                for (repo, commit, parentIndex, paths) in requests {
                    guard let plannedCommand = logPatchGitCommand(
                        commit: commit,
                        parentIndex: parentIndex,
                        paths: paths
                    ), let repositoryRootPath = repo.workdir(),
                    let arguments = patchExportGitArguments(
                        baseArguments: plannedCommand.args,
                        repositoryRootPath: repositoryRootPath,
                        paths: paths,
                        options: options
                    ) else {
                        throw NSError(
                            domain: "Arbor.Git",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Selected revision, base directory, or path is no longer available."]
                        )
                    }

                    let result = try repo.runGitCommand(
                        command: plannedCommand.command,
                        args: arguments
                    )
                    guard result.exitCode == 0 else {
                        let detail = result.stderr.isEmpty ? result.stdout : result.stderr
                        throw NSError(
                            domain: "Arbor.Git",
                            code: Int(result.exitCode),
                            userInfo: [NSLocalizedDescriptionKey: detail]
                        )
                    }
                    patchParts.append(result.stdoutBytes)
                    patchTextParts.append(result.stdout)
                }

                let patchData = joinedGitPatchData(patchParts)
                let patchText = joinedGitPatchParts(patchTextParts)
                guard !patchData.isEmpty else {
                    throw NSError(
                        domain: "Arbor.Git",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The selected changes have no patch output."]
                    )
                }
                if let destination {
                    try patchExportData(patchData, encoding: options.encoding)
                        .write(to: destination, options: .atomic)
                }
                await MainActor.run {
                    if options.copyToClipboard {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(patchText, forType: .string)
                    }
                    self.feedbackCenter.success(
                        options.copyToClipboard ? "Patch copied" : "Patch created",
                        detail: options.copyToClipboard
                            ? "\(records.count) selected change(s)"
                            : "\(records.count) selected change(s) → \(destination?.lastPathComponent ?? "")"
                    )
                }
            } catch {
                await MainActor.run {
                    self.feedbackCenter.error(
                        options.copyToClipboard ? "Copy patch failed" : "Create patch failed",
                        detail: errorMessage(error),
                        nextStep: "Check the selected revisions and destination, then retry."
                    )
                }
            }
        }
    }

    if copyToClipboard {
        performExport(PatchExportOptions(
            baseDirectory: nil,
            reverse: false,
            copyToClipboard: true,
            encoding: PatchExportSettings.encoding(for: exportRootPath)
        ))
    } else {
        presentPatchExportDialog(
            title: "Create Selected Patch",
            defaultFileName: defaultFileName,
            repositoryRootPath: exportRootPath,
            paths: allPaths,
            allowsBaseDirectory: sharedRootPath != nil,
            onExport: performExport
        )
    }
}

/// Apply or reverse selected Changes Browser records as worktree patches.
/// Unlike Get Version this keeps the index untouched and leaves unrelated
/// files alone. IntelliJ applies every selected commit/parent patch in one
/// action; keep root-qualified batches ordered and stop at the first failure
/// so a conflict never allows later patches to run against an unresolved tree.
func applySelectedChangesFromLog(
    _ records: [LogChangeRecord],
    reverse: Bool
) {
    let groups = logChangePatchGroups(records)
    guard !groups.isEmpty else { return }
    let requests = groups.compactMap { group -> (Repository, CommitInfo, UInt32?, [String])? in
        guard let first = group.first,
              let repo = logRepository(for: first.commit) else {
            return nil
        }
        return (
            repo,
            first.commit,
            first.parentIndex,
            group.map(\.change.path)
        )
    }
    guard requests.count == groups.count else { return }
    let requestRootPaths = Set(requests.compactMap { request in
        request.0.workdir().map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    })
    let refreshMultiRootChanges = requestRootPaths.count > 1

    let action = reverse ? "Revert Selected Changes" : "Apply Selected Changes"
    let question = reverse ? "Revert selected changes?" : "Apply selected changes?"
    let fileCount = records.count
    let commitCount = Set(records.map { record in
        "\(record.commit.repositoryPath ?? "")\u{1f}\(record.commit.id)"
    }).count
    let worktreeScope = requestRootPaths.count > 1
        ? " across \(requestRootPaths.count) Git roots"
        : " in the current worktree"
    let notificationID = logChangesPatchNotificationID(
        rootPaths: Array(requestRootPaths),
        reverse: reverse
    )
    let detail = reverse
        ? "Reverse \(fileCount) file change(s) from \(commitCount) commit(s)\(worktreeScope)."
        : "Apply \(fileCount) file change(s) from \(commitCount) commit(s)\(worktreeScope)."
    let alert = NSAlert()
    alert.messageText = question
    alert.informativeText = detail + " The index and unrelated files will not be changed."
    alert.alertStyle = .warning
    alert.addButton(withTitle: reverse ? "Revert Changes" : "Apply Changes")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    beginFeedbackOperation(action, notificationID: notificationID)
    Task.detached(priority: .userInitiated) {
        var appliedFiles = 0
        for (repo, commit, parentIndex, paths) in requests {
            do {
                try repo.applySelectedCommitChanges(
                    commitId: commit.id,
                    parentIndex: parentIndex,
                    paths: paths,
                    reverse: reverse
                )
                appliedFiles += paths.count
            } catch {
                let completed = appliedFiles
                if case let .ShelveApplyConflict(conflictName, conflictPaths) = error as? EngineError {
                    let restoreInfo = (try? repo.shelveRestoreInfo()) ?? nil
                    let patchText = restoreInfo?.patch
                    await MainActor.run {
                        self.presentShelveConflict(
                            name: conflictName,
                            paths: conflictPaths,
                            isPop: false,
                            isDirectPatch: true,
                            patchText: patchText,
                            repository: repo,
                            notificationID: notificationID
                        )
                        if refreshMultiRootChanges {
                            self.loadMultiRootChanges()
                        }
                    }
                } else {
                    await MainActor.run {
                        self.refreshAll(showFeedback: false)
                        if refreshMultiRootChanges {
                            self.loadMultiRootChanges()
                        }
                        if completed > 0 {
                            self.feedbackCenter.warning(
                                "Some selected changes applied",
                                detail: "Applied \(completed) file(s); the remaining patch failed: \(errorMessage(error))",
                                nextStep: "Review the worktree and retry the failed selection.",
                                notificationID: notificationID
                            )
                        } else {
                            self.feedbackCenter.error(
                                "\(action) failed",
                                detail: errorMessage(error),
                                nextStep: "Review local changes and patch applicability, then retry.",
                                notificationID: notificationID
                            )
                        }
                    }
                }
                return
            }
        }
        let totalAppliedFiles = appliedFiles
        await MainActor.run {
            self.feedbackCenter.success(
                action,
                detail: "\(totalAppliedFiles) file(s) from \(commitCount) commit(s)\(requestRootPaths.count > 1 ? " across \(requestRootPaths.count) Git roots" : "")",
                notificationID: notificationID
            )
            self.refreshAll(showFeedback: false)
            if refreshMultiRootChanges {
                self.loadMultiRootChanges()
            }
        }
    }
}

enum LogApplyOperation: Equatable {
    case cherryPick
    case revert

    var title: String {
        switch self {
        case .cherryPick: "Cherry-pick"
        case .revert: "Revert"
        }
    }

    var smartTitle: String {
        switch self {
        case .cherryPick: "Smart Cherry-pick"
        case .revert: "Smart Revert"
        }
    }

    var pausedMessage: String {
        switch self {
        case .cherryPick: "Cherry-pick paused: resolve conflicts, then Continue or Abort"
        case .revert: "Revert paused: resolve conflicts, then Continue or Abort"
        }
    }
}

nonisolated func executeLogApply(
    operation: LogApplyOperation,
    repo: Repository,
    commitIDs: [String],
    emptyPolicy: CherryPickEmptyPolicy,
    appendPublishedSuffix: Bool,
    preserveLocalChanges: Bool,
    savePolicy: LocalChangesSavePolicy
) throws -> String {
    switch operation {
    case .cherryPick:
        if preserveLocalChanges {
            return try repo.cherryPickManyWithOptionsAndPolicy(
                commitIds: commitIDs,
                emptyPolicy: emptyPolicy,
                appendSuffix: appendPublishedSuffix,
                savePolicy: savePolicy
            )
        }
        return try repo.cherryPickManyWithOptions(
            commitIds: commitIDs,
            emptyPolicy: emptyPolicy,
            appendSuffix: appendPublishedSuffix
        )
    case .revert:
        if preserveLocalChanges {
            return try repo.revertManyWithPolicy(
                commitIds: commitIDs,
                mainline: nil,
                savePolicy: savePolicy
            )
        }
        return try repo.revertMany(commitIds: commitIDs, mainline: nil)
    }
}

func runLogApplyOperation(
    _ operation: LogApplyOperation,
    commits: [CommitInfo],
    confirm: Bool,
    preserveLocalChanges: Bool
) {
    guard !commits.isEmpty else { return }
    let batches = logCommitRootBatches(commits)
    guard !batches.isEmpty,
          batches.flatMap(\.commits).count == commits.count else {
        feedbackCenter.warning(
            "\(operation.title) unavailable",
            detail: "Every selected commit must belong to an available Git root.",
            nextStep: "Refresh Git Roots, then retry from the Log."
        )
        return
    }

    if operation == .revert,
       !commits.allSatisfy({ $0.parentIds.count == 1 }) {
        feedbackCenter.warning(
            "Revert unavailable",
            detail: "Root and merge commits cannot be reverted from this selection."
        )
        return
    }

    if confirm {
        let alert = NSAlert()
        if commits.count == 1, let commit = commits.first {
            alert.messageText = operation == .revert ? "Revert this commit?" : "Cherry-pick this commit?"
            alert.informativeText = operation == .revert
                ? "A new inverse commit will be created for \(commit.shortId) \(commit.summary)."
                : "A new commit will be created from \(commit.shortId) \(commit.summary)."
        } else {
            alert.messageText = operation == .revert ? "Revert selected commits?" : "Cherry-pick selected commits?"
            alert.informativeText = operation == .revert
                ? "A new inverse commit will be created for each selected commit across its Git root."
                : "A new commit will be created for each selected commit in its Git root."
        }
        alert.addButton(withTitle: operation == .revert ? "Revert" : "Cherry-pick")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
    }

    beginFeedbackOperation(operation.title)
    let emptyPolicyChoice = configuredCherryPickEmptyPolicyChoice()
    let emptyPolicy = emptyPolicyChoice.engineValue
    let protectedPatterns = effectiveProtectedBranchPatterns
    let savePolicyChoice = GitLocalChangesSavePolicySettings.choice(for: projectPath)
    let operationProjectPath = projectPath
    let logApplySessionID = UUID().uuidString
    let logApplyBatchCount = batches.count
    Task.detached(priority: .userInitiated) {
        // Save every root before the first engine mutation. A process exit
        // between two roots must not erase the remaining Log selection.
        var preparedRecoveries: [String: PersistedLogApplyRecovery] = [:]
        for (batchIndex, batch) in batches.enumerated() {
            let orderedCommits = operation == .cherryPick && batch.commits.count > 1
                ? Array(batch.commits.reversed())
                : batch.commits
            guard let batchRepo = try? openRepository(path: batch.rootPath),
                  let initialHead = batchRepo.headCommitId(),
                  let rootPath = batchRepo.workdir() else { continue }
            let remoteBranches = (try? batchRepo.remoteBranchList()) ?? []
            let appendSuffix = operation == .cherryPick && shouldAppendCherryPickSuffix(
                projectPath: operationProjectPath,
                commits: orderedCommits,
                repo: batchRepo,
                remoteBranches: remoteBranches,
                protectedPatterns: protectedPatterns
            )
            let recovery = PersistedLogApplyRecovery(
                operation: operation == .cherryPick ? .cherryPick : .revert,
                rootPath: rootPath,
                commitIDs: orderedCommits.map(\.id),
                sessionID: logApplySessionID,
                batchIndex: batchIndex,
                batchCount: logApplyBatchCount,
                initialHead: initialHead,
                preserveLocalChanges: preserveLocalChanges,
                emptyPolicyRaw: emptyPolicyChoice.rawValue,
                appendPublishedSuffix: appendSuffix,
                savePolicyRaw: savePolicyChoice.rawValue
            )
            saveLogApplyRecovery(recovery)
            preparedRecoveries[rootPath] = recovery
        }

        var completedCommits: [CommitInfo] = []
        var resultIDs: [(String, String)] = []
        for (batchIndex, batch) in batches.enumerated() {
            do {
                let repo = try openRepository(path: batch.rootPath)
                // The Log is newest-first; Cherry-pick replays each root's
                // selected sequence oldest-first. Revert keeps IntelliJ's
                // existing UI order and Git's sequencer semantics.
                let orderedCommits = operation == .cherryPick && batch.commits.count > 1
                    ? Array(batch.commits.reversed())
                    : batch.commits
                let ids = orderedCommits.map(\.id)
                let resultID: String
                switch operation {
                case .cherryPick:
                    let recovery = preparedRecoveries[batch.rootPath]
                    let appendSuffix = recovery?.appendPublishedSuffix ?? {
                        let remoteBranches = (try? repo.remoteBranchList()) ?? []
                        return shouldAppendCherryPickSuffix(
                            projectPath: operationProjectPath,
                            commits: orderedCommits,
                            repo: repo,
                            remoteBranches: remoteBranches,
                            protectedPatterns: protectedPatterns
                        )
                    }()
                    if let initialHead = repo.headCommitId(),
                       let rootPath = repo.workdir(),
                       recovery == nil {
                        saveLogApplyRecovery(
                            PersistedLogApplyRecovery(
                                operation: operation == .cherryPick ? .cherryPick : .revert,
                                rootPath: rootPath,
                                commitIDs: ids,
                                sessionID: logApplySessionID,
                                batchIndex: batchIndex,
                                batchCount: logApplyBatchCount,
                                initialHead: initialHead,
                                preserveLocalChanges: preserveLocalChanges,
                                emptyPolicyRaw: emptyPolicyChoice.rawValue,
                                appendPublishedSuffix: appendSuffix,
                                savePolicyRaw: savePolicyChoice.rawValue
                            )
                        )
                    }
                    resultID = try executeLogApply(
                        operation: operation,
                        repo: repo,
                        commitIDs: ids,
                        emptyPolicy: emptyPolicy,
                        appendPublishedSuffix: appendSuffix,
                        preserveLocalChanges: preserveLocalChanges,
                        savePolicy: savePolicyChoice.engineValue
                    )
                case .revert:
                    let recovery = preparedRecoveries[batch.rootPath]
                    if let initialHead = repo.headCommitId(),
                       let rootPath = repo.workdir(),
                       recovery == nil {
                        saveLogApplyRecovery(
                            PersistedLogApplyRecovery(
                                operation: .revert,
                                rootPath: rootPath,
                                commitIDs: ids,
                                sessionID: logApplySessionID,
                                batchIndex: batchIndex,
                                batchCount: logApplyBatchCount,
                                initialHead: initialHead,
                                preserveLocalChanges: preserveLocalChanges,
                                emptyPolicyRaw: emptyPolicyChoice.rawValue,
                                appendPublishedSuffix: false,
                                savePolicyRaw: savePolicyChoice.rawValue
                            )
                        )
                    }
                    resultID = try executeLogApply(
                        operation: operation,
                        repo: repo,
                        commitIDs: ids,
                        emptyPolicy: emptyPolicy,
                        appendPublishedSuffix: false,
                        preserveLocalChanges: preserveLocalChanges,
                        savePolicy: savePolicyChoice.engineValue
                    )
                }
                if let rootPath = repo.workdir() {
                    clearLogApplyRecovery(repositoryPath: rootPath)
                }
                completedCommits.append(contentsOf: orderedCommits)
                resultIDs.append((batch.rootPath, resultID))
            } catch {
                let repo = try? openRepository(path: batch.rootPath)
                let pendingCommits = batches[batchIndex...].flatMap(\.commits)
                let status = repo.flatMap { try? $0.status() } ?? []
                let state = repo.flatMap { try? $0.operationState() }
                let firstConflict = status.first {
                    $0.staged == .conflicted || $0.unstaged == .conflicted
                }?.path
                let completedCommitsSnapshot = completedCommits
                await MainActor.run {
                    self.handleLogApplyFailure(
                        operation: operation,
                        error: error,
                        repo: repo,
                        status: status,
                        state: state,
                        firstConflict: firstConflict,
                        pendingCommits: pendingCommits,
                        completedCommits: completedCommitsSnapshot
                    )
                }
                return
            }
        }
        let resultIDsSnapshot = resultIDs
        await MainActor.run {
            let details = resultIDsSnapshot.map { rootPath, id in
                "\(rootPath): \(String(id.prefix(7)))"
            }.joined(separator: "\n")
            self.commitFeedback = operation.title
            self.feedbackCenter.success(operation.title, detail: details)
            self.logSelection = nil
            self.logSelectedIDs = []
            self.refreshAll(showFeedback: false)
        }
    }
}

func handleLogApplyFailure(
    operation: LogApplyOperation,
    error: Error,
    repo: Repository?,
    status: [FileEntry],
    state: OperationState?,
    firstConflict: String?,
    pendingCommits: [CommitInfo],
    completedCommits: [CommitInfo]
) {
    if case let .LocalChangesWouldBeOverwritten(paths) = error as? EngineError {
        let expectedRecoveryOperation: PersistedLogApplyRecovery.Operation = operation == .revert
            ? .revert
            : .cherryPick
        if let recovery = repo?.workdir().flatMap({ loadLogApplyRecovery(repositoryPath: $0) }),
           recovery.operation == expectedRecoveryOperation {
            let savedRecovery = recovery.updating(
                preserveLocalChanges: true,
                affectedPaths: paths
            )
            saveLogApplyRecovery(savedRecovery)
            _ = publishLogApplyRecoveryNoticeIfNeeded(rootPath: savedRecovery.rootPath)
            return
        }

        feedbackCenter.warning(
            "\(operation.title) needs a decision",
            detail: paths.joined(separator: ", "),
            nextStep: "Choose \(operation.smartTitle) to preserve local changes, or cancel and keep the current worktree."
        )
        presentSmartOperationDecision(
            operationTitle: operation.title,
            paths: paths,
            detail: errorMessage(error),
            smartButtonTitle: operation.smartTitle,
            onSmart: {
                self.runLogApplyOperation(
                    operation,
                    commits: pendingCommits,
                    confirm: false,
                    preserveLocalChanges: true
                )
            }
        )
        return
    }

    if state != nil || firstConflict != nil {
        entries = status
        operationState = state
        mergeInProgress = true
        mergeInitialPath = firstConflict
        showMergeRevisionsDialog = true
        let completedDetail = completedCommits.isEmpty
            ? ""
            : " (\(completedCommits.count) commit(s) completed before this root)"
        commitFeedback = operation.pausedMessage + completedDetail
    } else {
        let expectedRecoveryOperation: PersistedLogApplyRecovery.Operation = operation == .revert
            ? .revert
            : .cherryPick
        let recovery = repo?.workdir().flatMap {
            loadLogApplyRecovery(repositoryPath: $0)
        }.flatMap { $0.operation == expectedRecoveryOperation ? $0 : nil }
        let recoveryRootPath = recovery?.rootPath
        feedbackCenter.error(
            "\(operation.title) failed",
            detail: errorMessage(error),
            nextStep: repo == nil
                ? "Refresh Git Roots, then retry."
                : "Review the selected root's status, then retry.",
            additionalActions: recovery.map {
                logApplyRecoveryActions($0)
            } ?? [],
            notificationID: recoveryRootPath.map {
                logApplyRecoveryNotificationID(rootPath: $0)
            }
        )
    }
}

/// 用路径范围状态替换文件树中的对应条目，避免每次单文件操作都重建整棵状态树。
func applyIncrementalStatus(_ updates: [FileEntry], paths: [String]) {
    let pathSet = Set(paths)
    entries.removeAll { pathSet.contains($0.path) }
    entries.append(contentsOf: updates)
    entries.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    isShowingCachedStatusSnapshot = false
    fileContentRefreshToken &+= 1
}

func applyExternalLogRootSelection(_ requestedPaths: Set<String>) {
    guard externalLogWindow else { return }
    let availablePaths = normalizedLogRootPaths(multiRoots.map(\.path))
    let next = reconciledExternalLogRootSelection(
        availableRoots: availablePaths,
        selectedRoots: requestedPaths,
        initialized: true
    )
    guard !next.isEmpty, next != logAggregateRootPaths else { return }
    logAggregateBranchFilters = []
    logAggregateRevisionRanges = []
    logAggregateRootPaths = next
    logAggregateRepositories = [:]
    logAggregateLoadedCounts = [:]
    logSelection = nil
    logSelectedIDs = []
    logError = nil
    logViewMode = .graph
    loadLog()
}

func logApplyRecoveryNotificationID(rootPath: String) -> String {
    let stableRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    return "arbor.log-apply-recovery.\(stableRoot)"
}

func logApplyRecoveryTitle(
    _ operation: PersistedLogApplyRecovery.Operation
) -> String {
    switch operation {
    case .cherryPick: "Cherry-pick"
    case .revert: "Revert"
    }
}

func logApplyRecoveryAction(
    _ recovery: PersistedLogApplyRecovery
) -> FeedbackAction {
    let request = ArborVCSActionRequest(
        kind: .retryLogApply,
        projectPath: projectPath,
        rootPath: recovery.rootPath,
        shelfName: "",
        logApplyRecovery: recovery
    )
    return FeedbackAction(
        title: logApplyRecoveryActionTitle(recovery),
        semanticAction: request
    ) {
        self.handleVCSActionRequest(request)
    }
}

func logApplyAffectedFilesAction(
    _ recovery: PersistedLogApplyRecovery
) -> FeedbackAction? {
    guard !recovery.affectedPaths.isEmpty else { return nil }
    let request = ArborVCSActionRequest(
        kind: .showLogApplyAffectedFiles,
        projectPath: projectPath,
        rootPath: recovery.rootPath,
        shelfName: "",
        logApplyRecovery: recovery
    )
    return FeedbackAction(title: "Show Files", semanticAction: request) {
        self.handleVCSActionRequest(request)
    }
}

func logApplyRecoveryActions(
    _ recovery: PersistedLogApplyRecovery
) -> [FeedbackAction] {
    [logApplyAffectedFilesAction(recovery), logApplyRecoveryAction(recovery)]
        .compactMap { $0 }
}

func logApplyRecoveryFingerprint(
    _ recovery: PersistedLogApplyRecovery
) -> String {
    [
        recovery.operation.rawValue,
        recovery.rootPath,
        recovery.sessionID,
        String(recovery.batchIndex),
        String(recovery.batchCount),
        recovery.initialHead,
        recovery.commitIDs.joined(separator: "\u{1f}"),
        recovery.preserveLocalChanges ? "preserve" : "direct",
        recovery.emptyPolicyRaw,
        recovery.appendPublishedSuffix ? "suffix" : "no-suffix",
        recovery.savePolicyRaw,
        recovery.affectedPaths.joined(separator: "\u{1f}")
    ].joined(separator: "\u{1e}")
}

func nextLogApplyRecovery(
    after completed: PersistedLogApplyRecovery
) -> PersistedLogApplyRecovery? {
    pendingLogApplyRecoveries(sessionID: completed.sessionID).first {
        $0.operation == completed.operation
            && $0.batchCount == completed.batchCount
            && $0.batchIndex == completed.batchIndex + 1
    }
}

func retryNextLogApplyRoot(
    after completed: PersistedLogApplyRecovery
) {
    guard let nextRecovery = nextLogApplyRecovery(after: completed) else { return }
    retryLogApplyRecovery(nextRecovery, automatic: true)
}

func publishLogApplyRecoveryNoticeIfNeeded(rootPath: String) -> Bool {
    let normalizedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
    guard let recovery = loadLogApplyRecovery(repositoryPath: normalizedRoot),
          recovery.rootPath == normalizedRoot,
          !recovery.commitIDs.isEmpty,
          !recovery.initialHead.isEmpty else {
        feedbackCenter.expire(notificationID: logApplyRecoveryNotificationID(rootPath: normalizedRoot))
        logApplyRecoveryNotificationFingerprints.removeValue(
            forKey: operationRecoveryNotificationRootKey(normalizedRoot)
        )
        return false
    }
    let key = operationRecoveryNotificationRootKey(normalizedRoot)
    let fingerprint = logApplyRecoveryFingerprint(recovery)
    guard logApplyRecoveryNotificationFingerprints[key] != fingerprint else { return true }
    let title = logApplyRecoveryTitle(recovery.operation)
    if recovery.preserveLocalChanges, !recovery.affectedPaths.isEmpty {
        feedbackCenter.error(
            "\(title) failed",
            detail: "Local changes would be overwritten: \(recovery.affectedPaths.joined(separator: ", ")).",
            nextStep: "Show the affected files or choose \(logApplyRecoveryActionTitle(recovery)).",
            additionalActions: logApplyRecoveryActions(recovery),
            notificationID: logApplyRecoveryNotificationID(rootPath: normalizedRoot),
            notificationGroup: .important,
            localized: false
        )
    } else {
        feedbackCenter.warning(
            "\(title) recovery available",
            detail: "A previous Log \(title) action was interrupted before its final result was recorded.",
            nextStep: "Retry is allowed only while the repository HEAD remains \(String(recovery.initialHead.prefix(7))).",
            additionalActions: logApplyRecoveryActions(recovery),
            notificationID: logApplyRecoveryNotificationID(rootPath: normalizedRoot),
            notificationGroup: .important,
            localized: false
        )
    }
    logApplyRecoveryNotificationFingerprints[key] = fingerprint
    return true
}

func retryLogApplyRecovery(
    _ requestedRecovery: PersistedLogApplyRecovery,
    automatic: Bool = false
) {
    guard let recovery = loadLogApplyRecovery(repositoryPath: requestedRecovery.rootPath),
          recovery == requestedRecovery else {
        feedbackCenter.warning(
            "Retry unavailable",
            detail: "The saved Log operation is no longer pending.",
            nextStep: "Refresh the Log and select the commits again."
        )
        return
    }
    let normalizedRoot = URL(fileURLWithPath: recovery.rootPath).standardizedFileURL.path
    guard recovery.rootPath == normalizedRoot,
          !recovery.commitIDs.isEmpty,
          !recovery.initialHead.isEmpty else {
        feedbackCenter.warning(
            "Retry unavailable",
            detail: "The saved Log operation context is incomplete."
        )
        return
    }
    let pendingRecoveries = pendingLogApplyRecoveries(sessionID: recovery.sessionID)
    if let firstPending = pendingRecoveries.first,
       !logApplyRecoveryCanRun(recovery, pending: pendingRecoveries) {
        feedbackCenter.warning(
            "Retry unavailable",
            detail: "An earlier Git root in this Log operation is still pending.",
            nextStep: "Complete or retry root \(firstPending.batchIndex + 1) before continuing this root."
        )
        return
    }
    guard let targetRepo = try? openRepository(path: normalizedRoot) else {
        feedbackCenter.warning(
            "Retry unavailable",
            detail: "The saved Git root could not be opened.",
            nextStep: "Refresh Git Roots, then retry from the recovery notification."
        )
        return
    }
    do {
        guard try targetRepo.operationState() == nil else {
            feedbackCenter.warning(
                "Retry unavailable",
                detail: "This repository still has an active Git operation.",
                nextStep: "Continue or Abort the active operation first."
            )
            return
        }
    } catch {
        feedbackCenter.warning(
            "Retry unavailable",
            detail: "The current Git operation state could not be read.",
            nextStep: "Refresh Git Roots, then retry when the repository is readable."
        )
        return
    }
    guard targetRepo.headCommitId() == recovery.initialHead else {
        clearLogApplyRecovery(repositoryPath: normalizedRoot)
        feedbackCenter.expire(notificationID: logApplyRecoveryNotificationID(rootPath: normalizedRoot))
        logApplyRecoveryNotificationFingerprints.removeValue(
            forKey: operationRecoveryNotificationRootKey(normalizedRoot)
        )
        feedbackCenter.warning(
            "Retry refused",
            detail: "The repository HEAD changed after the interrupted Log operation.",
            nextStep: "Re-select the commits from the current Log instead of replaying the old action."
        )
        return
    }

    let operation: LogApplyOperation = recovery.operation == .cherryPick
        ? .cherryPick
        : .revert
    let emptyPolicy = GitCherryPickEmptyPolicyChoice(rawValue: recovery.emptyPolicyRaw)
        ?? GitCherryPickSettings.defaultEmptyPolicy
    let savePolicy = GitLocalChangesSavePolicyChoice(rawValue: recovery.savePolicyRaw)
        ?? GitLocalChangesSavePolicySettings.defaultPolicy
    beginFeedbackOperation(logApplyRecoveryTitle(recovery.operation))
    Task.detached(priority: .userInitiated) {
        do {
            let resultID = try executeLogApply(
                operation: operation,
                repo: targetRepo,
                commitIDs: recovery.commitIDs,
                emptyPolicy: emptyPolicy.engineValue,
                appendPublishedSuffix: recovery.appendPublishedSuffix,
                preserveLocalChanges: recovery.preserveLocalChanges,
                savePolicy: savePolicy.engineValue
            )
            clearLogApplyRecovery(repositoryPath: normalizedRoot)
            await MainActor.run {
                self.logApplyRecoveryNotificationFingerprints.removeValue(
                    forKey: operationRecoveryNotificationRootKey(normalizedRoot)
                )
                self.feedbackCenter.expire(
                    notificationID: self.logApplyRecoveryNotificationID(rootPath: normalizedRoot)
                )
                let nextRecovery = self.nextLogApplyRecovery(after: recovery)
                self.feedbackCenter.success(
                    automatic || nextRecovery != nil
                        ? "\(logApplyRecoveryTitle(recovery.operation)) root completed"
                        : "\(logApplyRecoveryTitle(recovery.operation)) retried",
                    detail: nextRecovery == nil
                        ? "\(normalizedRoot): \(String(resultID.prefix(7)))"
                        : "\(normalizedRoot): \(String(resultID.prefix(7))). Continuing the next Git root."
                )
                self.refreshAll(showFeedback: false)
                if let nextRecovery {
                    self.retryLogApplyRecovery(nextRecovery, automatic: true)
                }
            }
        } catch {
            let latestState = try? targetRepo.operationState()
            await MainActor.run {
                self.refreshAll(showFeedback: false)
                if let latestState, let rootPath = targetRepo.workdir() {
                    self.operationState = latestState
                    self.publishOperationRecoveryNoticeIfNeeded(
                        state: latestState,
                        rootPath: rootPath
                    )
                } else {
                    self.feedbackCenter.error(
                        "\(logApplyRecoveryTitle(recovery.operation)) retry failed",
                        detail: errorMessage(error),
                        nextStep: "Review the current root, then retry the saved Log action.",
                        additionalActions: [self.logApplyRecoveryAction(recovery)],
                        notificationID: self.logApplyRecoveryNotificationID(rootPath: normalizedRoot)
                    )
                }
            }
        }
    }
}

/// Import one or more portable unified/binary patches into the active Shelf.
/// The panel is intentionally kept as a small AppKit boundary; the engine
/// owns patch validation and isolated-index construction.
func applyPatchFromFile() {
    guard repo != nil else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.prompt = "Apply Patch"
    guard panel.runModal() == .OK, let url = panel.url else { return }

    do {
        let patch = try String(contentsOf: url, encoding: .utf8)
        presentApplyPatchRequest(fileName: url.lastPathComponent, patch: patch)
    } catch {
        feedbackCenter.error(
            "Patch apply failed",
            detail: errorMessage(error),
            nextStep: "Choose a UTF-8 unified or Git patch and try again."
        )
    }
}

/// Mirrors IntelliJ's ApplyPatchFromClipboardAction. Clipboard content enters
/// the same differentiated preview and conflict-recovery flow as a patch file;
/// it is never applied directly without path/hunk review.
func applyPatchFromClipboard() {
    guard repo != nil else { return }
    guard let patch = NSPasteboard.general.string(forType: .string),
          !patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        feedbackCenter.error(
            "Patch apply failed",
            detail: "The clipboard does not contain text.",
            nextStep: "Copy a unified or Git patch and try again."
        )
        return
    }
    presentApplyPatchRequest(fileName: "Clipboard Patch", patch: patch)
}

func presentApplyPatchRequest(fileName: String, patch: String) {
    let files = RebasedUnshelveDialog.parsePatchFiles(patch, allowedPaths: [])
    let paths = files.map(\.path)
    guard !paths.isEmpty else {
        feedbackCenter.error(
            "Patch apply failed",
            detail: "The source does not contain a supported unified or Git patch.",
            nextStep: "Choose a valid patch source and try again."
        )
        return
    }
    pendingApplyPatch = RebasedApplyPatchRequest(
        fileName: fileName,
        patch: patch,
        paths: paths
    )
}

/// Apply a reviewed patch directly. This is the platform ApplyPatchAction
/// path: the patch is never inserted into the user's Shelf list, while its
/// conflict snapshot still uses the same restart-safe resolver lifecycle.
func applyImportedPatch(
    fileName: String,
    patch: String,
    paths: [String],
    selections: [ShelvePatchSelection],
    targetName: String?,
    basePath: String?,
    pathStrip: UInt32
) {
    guard let repo, !paths.isEmpty else { return }
    let operationName = "Apply Patch: \(fileName)"
    let mappedBasePath = basePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let trimmedTargetName = targetName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let mappedTargetName = trimmedTargetName?.isEmpty == true ? nil : trimmedTargetName
    let cancel = GitCancelHandle()
    beginFeedbackOperation("Apply patch", cancelHandle: cancel)
    Task.detached(priority: .userInitiated) {
        do {
            if let targetName = mappedTargetName,
               !(try repo.changelistList().contains(where: { $0.name == targetName })) {
                throw EngineError.GitOperation(message: "Target Changelist not found: \(targetName)")
            }
            let applyResult = try repo.applyImportedPatchDifferentiatedWithCancel(
                name: operationName,
                patch: patch,
                paths: paths,
                selections: selections,
                basePath: mappedBasePath,
                pathStrip: pathStrip,
                cancel: cancel
            )
            let appliedPaths = applyResult.appliedPaths
            let failedPaths = applyResult.failedPaths

            let status = try repo.status()
            let currentPaths = Set(status.map(\.path))
            let assignablePaths = appliedPaths.filter(currentPaths.contains)
            if let targetName = mappedTargetName {
                if !assignablePaths.isEmpty {
                    try repo.changelistMovePaths(paths: assignablePaths, targetName: targetName)
                }
            }
            await MainActor.run {
                self.entries = status
                self.changeLists = (try? repo.changelistList()) ?? self.changeLists
                self.refreshAfterShelfMutation(
                    repo: repo,
                    paths: appliedPaths
                )
                if applyResult.overallStatus == .abort {
                    self.feedbackCenter.warning(
                        "Patch apply aborted",
                        detail: "(fileName): no patch members were kept",
                        nextStep: "Retry Apply Patch when ready. The original worktree and index were restored."
                    )
                } else if !patchApplyNeedsAttention(applyResult) {
                    self.feedbackCenter.success(
                        "Patch applied",
                        detail: mappedTargetName.map { "\(fileName) → \($0)" } ?? fileName
                    )
                } else {
                    let targetDetail = mappedTargetName.map { " → \($0)" } ?? ""
                    self.feedbackCenter.warning(
                        "Patch partially applied",
                        detail: "\(fileName)\(targetDetail): \(patchApplySummary(applyResult, successDetail: "Applied", failureDetail: "Not applied"))\(failedPaths.isEmpty ? "" : " (\(failedPaths.joined(separator: ", ")))")",
                        nextStep: "Review the failed files and apply those patch members separately."
                    )
                }
            }
        } catch {
            if case let .ShelveApplyConflict(conflictName, conflictPaths) = error as? EngineError {
                let restoreInfo = (try? repo.shelveRestoreInfo()) ?? nil
                let patchText = restoreInfo?.patch ?? patch
                if let targetName = mappedTargetName {
                    _ = try? repo.shelveSetRestoreTarget(
                        name: conflictName,
                        targetChangeList: targetName
                    )
                }
                await MainActor.run {
                    self.presentShelveConflict(
                        name: conflictName,
                        paths: conflictPaths,
                        isPop: false,
                        changeListName: mappedTargetName,
                        isDirectPatch: true,
                        patchText: patchText
                    )
                }
            } else if let engineError = error as? EngineError, case .Cancelled = engineError {
                await MainActor.run {
                    self.feedbackCenter.warning(
                        "Patch apply canceled",
                        detail: fileName,
                        nextStep: "The original worktree and index were kept. Retry Apply Patch when ready."
                    )
                }
            } else {
                await MainActor.run {
                    self.feedbackCenter.error(
                        "Patch apply failed",
                        detail: errorMessage(error),
                        nextStep: "The worktree was not left with a partial patch. Resolve the issue and retry."
                    )
                }
            }
        }
    }
}

nonisolated func patchApplyFeedbackState(
    _ result: PatchApplyResult
) -> FeedbackResultState {
    switch result.overallStatus {
    case .skip:
        .skipped
    case .failure:
        .failed
    case .abort:
        .aborted
    case .success, .alreadyApplied:
        .success
    case .partial:
        .partial
    }
}

nonisolated func patchApplyNeedsAttention(
    _ result: PatchApplyResult
) -> Bool {
    !result.failedPaths.isEmpty
        || result.overallStatus == .partial
        || result.overallStatus == .failure
        || result.overallStatus == .abort
}

nonisolated func patchApplySummary(
    _ result: PatchApplyResult,
    successDetail: String,
    failureDetail: String
) -> String {
    switch result.overallStatus {
    case .success:
        successDetail
    case .alreadyApplied:
        "Already applied"
    case .partial:
        "Partially applied: \(result.appliedPaths.count) applied, \(result.failedPaths.count) not applied"
    case .failure:
        failureDetail
    case .skip:
        "Not attempted"
    case .abort:
        "Aborted"
    }
}

func showLogApplyAffectedFiles(
    _ recovery: PersistedLogApplyRecovery
) {
    guard let persisted = loadLogApplyRecovery(repositoryPath: recovery.rootPath),
          persisted == recovery,
          !recovery.affectedPaths.isEmpty else {
        feedbackCenter.warning(
            "Show Files unavailable",
            detail: "The Log operation is no longer pending.",
            nextStep: "Refresh the Log and select the commits again."
        )
        return
    }

    let rootPath = URL(fileURLWithPath: recovery.rootPath).standardizedFileURL.path
    let preferredPath = recovery.affectedPaths.first
    toolWindowMode = .commit
    toolWindowExpanded = true
    let currentRootMatches = repo?.workdir().map {
        URL(fileURLWithPath: $0).standardizedFileURL.path == rootPath
    } == true
    guard currentRootMatches, let activeRepo = repo else {
        openMultiRootConflictResolver(
            preferredRootPath: rootPath,
            preferredPath: preferredPath
        )
        return
    }

    selection = preferredPath
    fileSelection = nil
    selectionModePath = nil
    commitPreviewPath = nil
    commitPreviewVisible = false
    Task.detached(priority: .userInitiated) {
        let status = (try? activeRepo.status()) ?? []
        await MainActor.run {
            guard self.repo === activeRepo else { return }
            self.entries = status
            self.selection = status.first(where: {
                recovery.affectedPaths.contains($0.path)
            })?.path ?? preferredPath
        }
    }
}

}
