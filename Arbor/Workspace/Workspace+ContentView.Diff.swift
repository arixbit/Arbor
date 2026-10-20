import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
nonisolated func branchComparisonMap(repo: Repository) -> [String: BranchCompare] {
    guard let comparisons = try? repo.branchCompareAll() else { return [:] }
    return Dictionary(uniqueKeysWithValues: comparisons.map {
        ($0.name, BranchCompare(ahead: $0.ahead, behind: $0.behind))
    })
}

/// Compare a dashboard branch in its owning root. The compare loader already
/// has root-scoped repository identity checks, so the result cannot be
/// replaced by a stale comparison from another Git root.
func compareLogBranch(rootPath: String?, branch: String) {
    let comparisonRepo: Repository?
    var rootHeadBranch: String?
    if let rootPath {
        guard let rootRepo = try? openRepository(path: rootPath) else {
            feedbackCenter.error("Compare unavailable", detail: "Unable to open Git root: \(rootPath)")
            return
        }
        comparisonRepo = rootRepo
        rootHeadBranch = multiRootBranchSnapshots.first(where: { $0.rootPath == rootPath })?.headBranch
            ?? (try? rootRepo.branchList().first(where: { $0.isCurrent })?.name)
    } else {
        comparisonRepo = repo
    }
    let current = if rootPath != nil {
        rootHeadBranch ?? "HEAD"
    } else {
        currentBranchName
    }
    guard let comparisonRepo,
          let owningRoot = rootPath ?? comparisonRepo.workdir() else { return }
    openBranchComparisonTab(
        rootPath: owningRoot,
        first: current,
        second: branch
    )
}

/// Open the Compare with Branch or Tag action against the deepest Git root
/// containing the selected project-tree file or directory. Root discovery may
/// still be in flight when the user opens the context menu, so refresh the
/// candidate list on demand if the cached multi-root list is empty.
func openFileReferenceComparison(path: String, isDirectory: Bool) {
    fileTreeDiffRequest = nil
    guard let primaryRepo = repo,
          let primaryRootPath = primaryRepo.workdir(),
          normalizedRepositoryRelativePath(path) != nil else {
        feedbackCenter.error(
            "Unable to compare project path",
            detail: "The selected project-tree path is not a safe repository-relative path.",
            nextStep: "Refresh the project tree, then try again."
        )
        return
    }

    let cachedRoots = multiRoots
    Task.detached(priority: .userInitiated) {
        let roots = cachedRoots.isEmpty
            ? ((try? discoverGitRoots(scanRoot: primaryRootPath, maxDepth: nil)) ?? [])
            : cachedRoots
        guard let target = fileReferenceComparisonTarget(
            path: path,
            primaryRootPath: primaryRootPath,
            roots: roots
        ) else {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Unable to compare project path",
                    detail: "The selected file is outside the discovered Git roots.",
                    nextStep: "Refresh the project roots, then try again."
                )
            }
            return
        }

        do {
            let targetRepo: Repository
            if canonicalExternalLogPath(primaryRootPath) == target.rootPath {
                targetRepo = primaryRepo
            } else {
                targetRepo = try openRepository(path: target.rootPath)
            }
            await MainActor.run {
                self.fileReferenceComparisonRequest = FileReferenceComparisonRequest(
                    repo: targetRepo,
                    path: target.relativePath,
                    isDirectory: isDirectory,
                    mode: .references
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Unable to open Git root",
                    detail: "\(target.rootPath)\n\(errorMessage(error))",
                    nextStep: "Check that the nested repository is still available, then retry."
                )
            }
        }
    }
}

/// IntelliJ's `Compare.Selected`: choose a revision from the selected path's
/// file history, then compare that revision with the current working tree.
/// The owning Git root is resolved before presenting the picker so nested
/// repositories cannot leak the parent repository's history.
func openFileSelectedRevisionComparison(path: String, isDirectory: Bool) {
    fileTreeDiffRequest = nil
    guard let primaryRepo = repo,
          let primaryRootPath = primaryRepo.workdir(),
          normalizedRepositoryRelativePath(path) != nil else {
        feedbackCenter.error(
            "Unable to compare project path",
            detail: "The selected project-tree path is not a safe repository-relative path.",
            nextStep: "Refresh the project tree, then try again."
        )
        return
    }

    let cachedRoots = multiRoots
    Task.detached(priority: .userInitiated) {
        let roots = cachedRoots.isEmpty
            ? ((try? discoverGitRoots(scanRoot: primaryRootPath, maxDepth: nil)) ?? [])
            : cachedRoots
        guard let target = fileReferenceComparisonTarget(
            path: path,
            primaryRootPath: primaryRootPath,
            roots: roots
        ) else {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Unable to compare project path",
                    detail: "The selected path is outside the discovered Git roots.",
                    nextStep: "Refresh the project roots, then retry."
                )
            }
            return
        }

        do {
            let targetRepo: Repository
            if canonicalExternalLogPath(primaryRootPath) == target.rootPath {
                targetRepo = primaryRepo
            } else {
                targetRepo = try openRepository(path: target.rootPath)
            }
            await MainActor.run {
                self.fileReferenceComparisonRequest = FileReferenceComparisonRequest(
                    repo: targetRepo,
                    path: target.relativePath,
                    isDirectory: isDirectory,
                    mode: .selectedRevision
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Unable to open Git root",
                    detail: "\(target.rootPath)\n\(errorMessage(error))",
                    nextStep: "Check that the nested repository is still available, then retry."
                )
            }
        }
    }
}

/// IntelliJ's `Compare.SameVersion`: compare the selected worktree file with
/// the current revision in its owning Git root. This is intentionally a
/// separate path from `Compare with Branch or Tag…`, which opens a ref picker.
func openFileSameVersionComparison(path: String) {
    guard let primaryRepo = repo,
          let primaryRootPath = primaryRepo.workdir(),
          normalizedRepositoryRelativePath(path) != nil else {
        feedbackCenter.error(
            "Unable to compare project path",
            detail: "The selected project-tree path is not a safe repository-relative path.",
            nextStep: "Refresh the project tree, then try again."
        )
        return
    }

    let cachedRoots = multiRoots
    Task.detached(priority: .userInitiated) {
        let roots = cachedRoots.isEmpty
            ? ((try? discoverGitRoots(scanRoot: primaryRootPath, maxDepth: nil)) ?? [])
            : cachedRoots
        guard let target = fileReferenceComparisonTarget(
            path: path,
            primaryRootPath: primaryRootPath,
            roots: roots
        ) else {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Unable to compare project path",
                    detail: "The selected file is outside the discovered Git roots.",
                    nextStep: "Refresh the project roots, then try again."
                )
            }
            return
        }

        do {
            let targetRepo: Repository
            if canonicalExternalLogPath(primaryRootPath) == target.rootPath {
                targetRepo = primaryRepo
            } else {
                targetRepo = try openRepository(path: target.rootPath)
            }
            guard targetRepo.headCommitId() != nil else {
                throw NSError(
                    domain: "Arbor.Git",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The repository has no HEAD revision."]
                )
            }
            let entry = FileEntry(
                path: target.relativePath,
                oldPath: nil,
                staged: .unchanged,
                unstaged: .modified
            )
            await MainActor.run {
                self.toolWindowMode = .commit
                self.selection = nil
                self.fileSelection = nil
                self.selectionModePath = nil
                self.commitPreviewPath = nil
                self.commitPreviewVisible = false
                self.fileTreeDiffRequest = FileTreeDiffRequest(
                    repo: targetRepo,
                    entry: entry,
                    initialMode: .worktreeToHead
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Unable to compare with HEAD",
                    detail: "\(target.rootPath)\n\(errorMessage(error))",
                    nextStep: "Check that the repository has a committed HEAD and retry."
                )
            }
        }
    }
}

/// Export selected revision/tree comparison changes as a portable patch.
/// Revision and path arguments stay separate so unusual branch names and
/// filenames cannot become shell syntax. This is the compare-view equivalent
/// of IntelliJ's Changes Browser Create Patch action.
func createPatchFromCompare() {
    let selectedChanges = orderedCompareSelection(
        changes: treeChanges,
        selectedPaths: compareSelectedPaths
    )
    guard let comparisonRepo = activeCompareRepo ?? repo,
          !selectedChanges.isEmpty,
          !compareRev1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          compareWithWorkingTree || !compareRev2.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return
    }

    var paths: [String] = []
    var seenPaths = Set<String>()
    for change in selectedChanges {
        for path in [change.oldPath, change.path].compactMap({ $0 }) {
            guard !path.isEmpty, seenPaths.insert(path).inserted else { continue }
            paths.append(path)
        }
    }
    guard !paths.isEmpty else { return }

    let expectedRev1 = compareRev1
    let expectedRev2 = compareRev2
    let expectedWorkingTree = compareWithWorkingTree
    guard let comparisonRootPath = comparisonRepo.workdir(), !comparisonRootPath.isEmpty else { return }
    presentPatchExportDialog(
        title: "Create Compare Patch",
        defaultFileName: "compare.patch",
        repositoryRootPath: comparisonRootPath,
        paths: paths,
        allowsBaseDirectory: true
    ) { options in
        let destination = options.copyToClipboard
            ? nil
            : self.patchExportDestination(
                defaultFileName: "compare.patch",
                repositoryRootPath: comparisonRootPath
            )
        guard options.copyToClipboard || destination != nil else { return }
        PatchExportSettings.save(options, for: comparisonRootPath)

        let baseArguments = comparePatchGitArguments(
            rev1: expectedRev1,
            rev2: expectedRev2,
            comparesWithWorkingTree: expectedWorkingTree,
            paths: paths
        )
        guard let arguments = patchExportGitArguments(
            baseArguments: baseArguments,
            repositoryRootPath: comparisonRootPath,
            paths: paths,
            options: options
        ) else { return }

        self.beginFeedbackOperation(options.copyToClipboard ? "Copy compare patch" : "Create compare patch")
        Task.detached(priority: .userInitiated) {
            do {
                let result = try comparisonRepo.runGitCommand(command: "diff", args: arguments)
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
                        userInfo: [NSLocalizedDescriptionKey: "The selected comparison has no patch output."]
                    )
                }
                if let destination {
                    try patchExportData(result.stdoutBytes, encoding: options.encoding)
                        .write(to: destination, options: .atomic)
                }
                await MainActor.run {
                    if options.copyToClipboard {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.stdout, forType: .string)
                    }
                    self.feedbackCenter.success(
                        options.copyToClipboard ? "Compare patch copied" : "Compare patch created",
                        detail: options.copyToClipboard
                            ? "\(selectedChanges.count) selected change(s)"
                            : "\(selectedChanges.count) selected change(s) → \(destination?.lastPathComponent ?? "")"
                    )
                }
            } catch {
                await MainActor.run {
                    self.feedbackCenter.error(
                        options.copyToClipboard ? "Copy compare patch failed" : "Create compare patch failed",
                        detail: errorMessage(error),
                        nextStep: "Check the compared revisions and destination, then retry."
                    )
                }
            }
        }
    }
}

func compareFromLog(_ commit: CommitInfo) {
    guard let selectedRepo = logRepository(for: commit) else {
        feedbackCenter.warning(
            "Compare unavailable",
            detail: "The selected commit's Git root could not be opened.",
            nextStep: "Refresh Git roots and retry from the commit history."
        )
        return
    }
    let selectedRootPath = commit.repositoryPath ?? selectedRepo.workdir()
    guard let selectedRootPath else {
        feedbackCenter.warning(
            "Compare unavailable",
            detail: "The selected commit's Git root could not be resolved.",
            nextStep: "Refresh Git roots and retry from the commit history."
        )
        return
    }
    // GitLogDiffHandler.showDiffWithLocal compares the selected revision with
    // the current worktree. Keep that direction explicit and use the same
    // independent Changes Browser tab as the branch comparison actions.
    openTreeComparisonTab(
        rootPath: selectedRootPath,
        first: commit.id,
        second: "Working Tree",
        comparesWithWorkingTree: true
    )
}

/// Branch file comparison is an editor-style Changes Browser surface in
/// IntelliJ, not a mode switch that replaces the user's current history.
func openTreeComparisonTab(
    rootPath: String,
    first: String,
    second: String,
    comparesWithWorkingTree: Bool
) {
    let tab = makeTreeComparisonLogTab(
        first: first,
        second: second,
        rootPath: rootPath,
        comparesWithWorkingTree: comparesWithWorkingTree
    )
    toolWindowMode = .log
    toolWindowExpanded = true
    projectPanelExpanded = false
    showBranchesPopover = false
    saveCurrentLogTab()
    if let existing = logTabs.first(where: {
        $0.viewMode == .compare
            && $0.rootPath == tab.rootPath
            && $0.compareRepositoryPath == tab.compareRepositoryPath
            && $0.compareRevision1 == tab.compareRevision1
            && $0.compareRevision2 == tab.compareRevision2
            && $0.compareWithWorkingTree == tab.compareWithWorkingTree
    }) {
        if existing.id == currentLogTabID {
            applyLogTab(existing)
            loadActiveLogTab(existing)
        } else {
            switchLogTab(existing.id)
        }
        return
    }
    appendLogTabAndLoad(tab)
}

/// Compare Branches is an editor-style Log surface in IntelliJ, not a mode
/// switch that replaces the user's current history. Keep one tab per exact
/// root/range pair and let the normal Log tab lifecycle own persistence,
/// switching and close behavior.
func openBranchComparisonTab(rootPath: String, first: String, second: String) {
    let tab = makeBranchComparisonLogTab(
        first: first,
        second: second,
        rootPath: rootPath
    )
    toolWindowMode = .log
    toolWindowExpanded = true
    projectPanelExpanded = false
    showBranchesPopover = false
    saveCurrentLogTab()
    if let existing = logTabs.first(where: {
        $0.viewMode == .compareBranches
            && $0.rootPath == tab.rootPath
            && $0.compareRepositoryPath == tab.compareRepositoryPath
            && $0.compareRevision1 == tab.compareRevision1
            && $0.compareRevision2 == tab.compareRevision2
    }) {
        if existing.id == currentLogTabID {
            applyLogTab(existing)
            loadActiveLogTab(existing)
        } else {
            switchLogTab(existing.id)
        }
        return
    }
    appendLogTabAndLoad(tab)
}

func loadMoreBranchComparison(_ side: BranchComparisonSide) {
    guard logList.viewMode == .compareBranches,
          !branchComparisonIsLoading(side),
          branchComparisonSideHasMore(side) else { return }
    startBranchComparisonLoad(side, reset: false)
}

func refreshBranchComparison(_ side: BranchComparisonSide) {
    guard logList.viewMode == .compareBranches else { return }
    let selectedWasInSide = branchComparisonEntries(side).contains {
        $0.id == branchCompareSelectionID
    }
    cancelBranchComparisonTask(side)
    setBranchComparisonEntries([], side: side)
    setBranchComparisonHasMore(false, side: side)
    setBranchComparisonError(nil, side: side)
    if selectedWasInSide {
        branchCompareSelectionID = nil
    }
    repairBranchComparisonSelection()
    startBranchComparisonLoad(side, reset: true)
}

func loadBranchComparison(reset: Bool = true) {
    guard reset, logList.viewMode == .compareBranches else { return }
    branchCompareError = nil
    refreshBranchComparison(.first)
    refreshBranchComparison(.second)
}

func cancelBranchComparisonTasks() {
    cancelBranchComparisonTask(.first)
    cancelBranchComparisonTask(.second)
    branchCompareError = nil
}

func cancelBranchComparisonTask(_ side: BranchComparisonSide) {
    switch side {
    case .first:
        branchCompareFirstLoadTask?.cancel()
        branchCompareFirstLoadTask = nil
        branchCompareFirstRequestGeneration += 1
        branchCompareFirstLoading = false
    case .second:
        branchCompareSecondLoadTask?.cancel()
        branchCompareSecondLoadTask = nil
        branchCompareSecondRequestGeneration += 1
        branchCompareSecondLoading = false
    }
    updateBranchComparisonLoadingState()
}

func startBranchComparisonLoad(_ side: BranchComparisonSide, reset: Bool) {
    guard logList.viewMode == .compareBranches else { return }
    let first = compareRev1.trimmingCharacters(in: .whitespacesAndNewlines)
    let second = compareRev2.trimmingCharacters(in: .whitespacesAndNewlines)
    let filter = branchComparisonFilter(side)
    let requestGeneration: Int
    switch side {
    case .first:
        branchCompareFirstRequestGeneration += 1
        requestGeneration = branchCompareFirstRequestGeneration
        branchCompareFirstLoading = true
    case .second:
        branchCompareSecondRequestGeneration += 1
        requestGeneration = branchCompareSecondRequestGeneration
        branchCompareSecondLoading = true
    }
    updateBranchComparisonLoadingState()

    guard !first.isEmpty, !second.isEmpty else {
        finishBranchComparisonLoad(
            side,
            requestGeneration: requestGeneration,
            error: "请输入两个 branch",
            reset: reset
        )
        return
    }
    let comparisonRepo = activeCompareRepo
        ?? compareRepositoryPath.flatMap { path in
            repo?.workdir() == path ? repo : nil
        }
        ?? compareRepositoryPath.flatMap({ try? openRepository(path: $0) })
        ?? repo
    guard let comparisonRepo else {
        finishBranchComparisonLoad(
            side,
            requestGeneration: requestGeneration,
            error: "无法打开比较所需的 Git root",
            reset: reset
        )
        return
    }
    if let filterError = branchComparisonFilterDateError(filter, side: side) {
        finishBranchComparisonLoad(
            side,
            requestGeneration: requestGeneration,
            error: filterError,
            reset: reset
        )
        return
    }

    let sinceText = filter.since.trimmingCharacters(in: .whitespacesAndNewlines)
    let untilText = filter.until.trimmingCharacters(in: .whitespacesAndNewlines)
    let author = filter.author.trimmingCharacters(in: .whitespacesAndNewlines)
    let message = filter.message.trimmingCharacters(in: .whitespacesAndNewlines)
    let hashQuery = isCommitHashQuery(message) ? message.lowercased() : nil
    let since = parseLogSince(sinceText)
    let until = parseLogUntil(untilText)
    let limit = reset
        ? Int(initialLogPageLimit)
        : Int(continuationLogPageLimit)
    let range = side == .first ? "\(second)..\(first)" : "\(first)..\(second)"
    let afterID = reset ? nil : branchComparisonEntries(side).last?.id
    let contextGeneration = branchCompareGeneration
    let filterSnapshot = filter

    let task = Task.detached(priority: .userInitiated) {
        do {
            let loaded = try comparisonRepo.logFilteredWithMessageAndDateOptionsForRevisionsWithAfterId(
                path: nil,
                limit: UInt32(limit),
                follow: false,
                startRevs: [range],
                author: author.isEmpty ? nil : author,
                since: since,
                until: until,
                message: hashQuery == nil && !message.isEmpty ? message : nil,
                messageRegex: filter.messageRegex,
                messageMatchCase: filter.messageMatchCase,
                noMerges: filter.noMerges,
                sortMode: LogGraphSortChoice.byCommitDate.engineValue,
                afterId: afterID
            )
            guard !Task.isCancelled else { return }
            let filtered = hashQuery.map { query in
                loaded.filter { $0.id.lowercased().hasPrefix(query) }
            } ?? loaded
            let hasMore = branchComparisonHasMore(
                returnedCount: loaded.count,
                requestedLimit: limit,
                isHashQuery: hashQuery != nil
            )
            await MainActor.run {
                guard !Task.isCancelled,
                      self.branchCompareGeneration == contextGeneration,
                      self.branchComparisonRequestGeneration(side) == requestGeneration,
                      self.logList.viewMode == .compareBranches,
                      self.compareRev1.trimmingCharacters(in: .whitespacesAndNewlines) == first,
                      self.compareRev2.trimmingCharacters(in: .whitespacesAndNewlines) == second,
                      self.branchComparisonFilter(side) == filterSnapshot,
                      self.activeCompareRepo === comparisonRepo
                        || (self.activeCompareRepo == nil && self.projectRepo === comparisonRepo) else { return }
                if reset {
                    self.setBranchComparisonEntries(filtered, side: side)
                } else {
                    let newEntries = branchComparisonNewEntries(
                        returned: filtered,
                        existingIDs: Set(self.branchComparisonEntries(side).map(\.id))
                    )
                    self.setBranchComparisonEntries(
                        self.branchComparisonEntries(side) + newEntries,
                        side: side
                    )
                }
                self.setBranchComparisonHasMore(hasMore, side: side)
                self.setBranchComparisonError(nil, side: side)
                self.finishBranchComparisonLoad(side, requestGeneration: requestGeneration)
                self.repairBranchComparisonSelection()
            }
        } catch {
            await MainActor.run {
                guard !Task.isCancelled,
                      self.branchCompareGeneration == contextGeneration,
                      self.branchComparisonRequestGeneration(side) == requestGeneration,
                      self.logList.viewMode == .compareBranches,
                      self.compareRev1.trimmingCharacters(in: .whitespacesAndNewlines) == first,
                      self.compareRev2.trimmingCharacters(in: .whitespacesAndNewlines) == second,
                      self.branchComparisonFilter(side) == filterSnapshot,
                      self.activeCompareRepo === comparisonRepo
                        || (self.activeCompareRepo == nil && self.projectRepo === comparisonRepo) else { return }
                self.finishBranchComparisonLoad(
                    side,
                    requestGeneration: requestGeneration,
                    error: errorMessage(error),
                    reset: reset
                )
            }
        }
    }
    switch side {
    case .first:
        branchCompareFirstLoadTask = task
    case .second:
        branchCompareSecondLoadTask = task
    }
}

func finishBranchComparisonLoad(
    _ side: BranchComparisonSide,
    requestGeneration: Int,
    error: String? = nil,
    reset: Bool = false
) {
    guard branchComparisonRequestGeneration(side) == requestGeneration else { return }
    if let error {
        setBranchComparisonError(error, side: side)
        if reset {
            setBranchComparisonEntries([], side: side)
            setBranchComparisonHasMore(false, side: side)
        }
    }
    switch side {
    case .first:
        branchCompareFirstLoading = false
        branchCompareFirstLoadTask = nil
    case .second:
        branchCompareSecondLoading = false
        branchCompareSecondLoadTask = nil
    }
    branchCompareError = branchCompareFirstError ?? branchCompareSecondError
    updateBranchComparisonLoadingState()
}

func updateBranchComparisonLoadingState() {
    isLoadingBranchComparison = branchCompareFirstLoading || branchCompareSecondLoading
}

func branchComparisonIsLoading(_ side: BranchComparisonSide) -> Bool {
    side == .first ? branchCompareFirstLoading : branchCompareSecondLoading
}

func branchComparisonSideHasMore(_ side: BranchComparisonSide) -> Bool {
    side == .first ? branchCompareFirstHasMore : branchCompareSecondHasMore
}

func branchComparisonFilter(_ side: BranchComparisonSide) -> BranchComparisonFilter {
    side == .first ? branchCompareFirstFilter : branchCompareSecondFilter
}

func branchComparisonEntries(_ side: BranchComparisonSide) -> [CommitInfo] {
    side == .first ? branchCompareFirstEntries : branchCompareSecondEntries
}

func branchComparisonRequestGeneration(_ side: BranchComparisonSide) -> Int {
    side == .first ? branchCompareFirstRequestGeneration : branchCompareSecondRequestGeneration
}

func setBranchComparisonEntries(_ entries: [CommitInfo], side: BranchComparisonSide) {
    switch side {
    case .first:
        branchCompareFirstEntries = entries
    case .second:
        branchCompareSecondEntries = entries
    }
}

func setBranchComparisonHasMore(_ hasMore: Bool, side: BranchComparisonSide) {
    switch side {
    case .first:
        branchCompareFirstHasMore = hasMore
    case .second:
        branchCompareSecondHasMore = hasMore
    }
}

func setBranchComparisonError(_ error: String?, side: BranchComparisonSide) {
    switch side {
    case .first:
        branchCompareFirstError = error
    case .second:
        branchCompareSecondError = error
    }
    branchCompareError = branchCompareFirstError ?? branchCompareSecondError
}

func repairBranchComparisonSelection() {
    let selection = branchComparisonSelectionAfterRefresh(
        selectedID: branchCompareSelectionID,
        firstIDs: branchCompareFirstEntries.map(\.id),
        secondIDs: branchCompareSecondEntries.map(\.id)
    )
    branchCompareSelectionSide = selection.side
    branchCompareSelectionID = selection.id
}

func activateComparisonRepository(_ rootRepo: Repository, rootPath: String) {
    activeCompareRepo = rootRepo
    compareRepositoryPath = rootPath
    logList.activeRootPath = rootPath
    logList.activeRepo = rootRepo
    logActiveBranches = (try? rootRepo.branchList()) ?? []
    logActiveRemoteBranches = (try? rootRepo.remoteBranchList()) ?? []
    logActiveRemotes = (try? rootRepo.remoteList()) ?? []
}

/// 多 root Branches Popup 的 Show Files Diff：打开正确 Git root 的
/// 独立 Changes Browser tab，而不是把 revision 交给当前窗口的 repository。
func compareBranchesInRoot(rootPath: String, first: String, second: String) {
    beginFeedbackOperation("Compare selected branches")
    Task.detached(priority: .userInitiated) {
        do {
            _ = try openRepository(path: rootPath)
            await MainActor.run {
                self.openTreeComparisonTab(
                    rootPath: rootPath,
                    first: first,
                    second: second,
                    comparesWithWorkingTree: false
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Compare unavailable",
                    detail: "\(first) ↔ \(second) · \(rootPath): \(errorMessage(error))",
                    nextStep: "Check the selected branches and retry the comparison."
                )
            }
        }
    }
}

/// IntelliJ's Compare Branches action shows the commits unique to each branch
/// in two log panes. It must not silently degrade to the file-level diff used
/// by Show Files Diff.
func compareBranchesCommitWiseInRoot(rootPath: String, first: String, second: String) {
    beginFeedbackOperation("Compare branches")
    Task.detached(priority: .userInitiated) {
        do {
            _ = try openRepository(path: rootPath)
            await MainActor.run {
                self.openBranchComparisonTab(
                    rootPath: rootPath,
                    first: first,
                    second: second
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Compare unavailable",
                    detail: "\(first) ↔ \(second) · \(rootPath): \(errorMessage(error))",
                    nextStep: "Check the selected branches and retry the comparison."
                )
            }
        }
    }
}

func compareBranchInRoot(rootPath: String, branch: String) {
    beginFeedbackOperation("Compare branch")
    Task.detached(priority: .userInitiated) {
        do {
            let rootRepo = try openRepository(path: rootPath)
            let current = try rootRepo.branchList().first(where: { $0.isCurrent })?.name ?? "HEAD"
            await MainActor.run {
                self.openBranchComparisonTab(
                    rootPath: rootPath,
                    first: current,
                    second: branch
                )
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error(
                    "Compare unavailable",
                    detail: "\(branch) · \(rootPath): \(errorMessage(error))",
                    nextStep: "Check the selected Git root and revision, then retry."
                )
            }
        }
    }
}

}
