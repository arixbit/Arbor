import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {

/// REPO-001:发现项目下的所有 Git root(聚合视图数据源)。
func loadMultiRoots(onCompleted: (() -> Void)? = nil) {
    if multiRootWorkspace.loadTask != nil {
        // Native repository calls are synchronous, so cancelling their Swift
        // task does not stop work already running in the engine. Coalesce
        // requests and run one fresh scan after the active one finishes.
        multiRootWorkspace.loadNeedsRefresh = true
        if let onCompleted {
            multiRootWorkspace.loadCompletion = onCompleted
        }
        return
    }
    multiRootWorkspace.loadGeneration &+= 1
    let generation = multiRootWorkspace.loadGeneration
    guard let projectPath = projectWorkspace.path else {
        onCompleted?()
        return
    }
    let requestedProjectPath = canonicalExternalLogPath(projectPath)
    let requestedExternalRootPaths = externalLogWindow
        ? initialExternalLogRootPaths.map(canonicalExternalLogPath)
        : []
    let task = Task.detached(priority: .utility) {
        do {
            var roots = try discoverGitRoots(scanRoot: projectPath, maxDepth: nil)
            guard !Task.isCancelled else { return }
            if !requestedExternalRootPaths.isEmpty {
                var knownRootPaths = Set(roots.map { canonicalExternalLogPath($0.path) })
                for requestedRootPath in requestedExternalRootPaths
                    where !knownRootPaths.contains(requestedRootPath) {
                    guard let requestedRoot = try? discoverGitRoots(
                        scanRoot: requestedRootPath,
                        maxDepth: 0
                    ).first(where: {
                        canonicalExternalLogPath($0.path) == requestedRootPath
                    }) else {
                        continue
                    }
                    roots.append(requestedRoot)
                    knownRootPaths.insert(requestedRootPath)
                }
            }
            guard !Task.isCancelled else { return }
            let operationStates = roots.compactMap { root -> (String, OperationState)? in
                guard root.operation != nil,
                      let rootRepo = try? openRepository(path: root.path),
                      let state = try? rootRepo.operationState() else {
                    return nil
                }
                return (root.path, state)
            }
            if let override = GitExecutableSettings.projectOverride(for: projectPath) {
                let registeredRoots = GitExecutableSettings.registeredRoots(
                    projectPath: projectPath,
                    repositoryRoot: nil,
                    discoveredRoots: roots.map(\.path)
                )
                _ = try? setProjectGitExecutable(
                    projectPath: projectPath,
                    rootPaths: registeredRoots,
                    path: override
                )
            } else {
                clearProjectGitExecutable(projectPath: projectPath)
            }
            guard !Task.isCancelled else { return }
            var snapshots = try listMultiRootBranches(scanRoot: projectPath)
            guard !Task.isCancelled else { return }
            if !requestedExternalRootPaths.isEmpty {
                let knownSnapshotPaths = Set(snapshots.map {
                    canonicalExternalLogPath($0.rootPath)
                })
                for requestedRootPath in requestedExternalRootPaths
                    where !knownSnapshotPaths.contains(requestedRootPath) {
                    if let requestedSnapshot = try? listMultiRootBranches(
                        scanRoot: requestedRootPath
                    ).first(where: {
                        canonicalExternalLogPath($0.rootPath) == requestedRootPath
                    }) {
                        snapshots.append(requestedSnapshot)
                    }
                }
            }
            let conflictGroups = roots.compactMap { root -> MultiRootConflictGroup? in
                guard !Task.isCancelled else { return nil }
                guard let rootRepo = try? openRepository(path: root.path),
                      let entries = try? rootRepo.status() else { return nil }
                let paths = entries
                    .filter { $0.staged == .conflicted || $0.unstaged == .conflicted }
                    .map(\.path)
                    .sorted()
                guard !paths.isEmpty else { return nil }
                return MultiRootConflictGroup(
                    rootPath: root.path,
                    displayName: root.displayName,
                    relativePath: root.relativePath,
                    operation: root.operation,
                    paths: paths
                )
            }
            guard !Task.isCancelled else { return }
            let updateStashRoots = Set(
                snapshots.compactMap { snapshot in
                    snapshot.stashes.contains(where: { isArborUpdateLocalChangesName($0.message) })
                        || snapshot.shelves.contains(where: { isArborTemporaryShelfName($0.name) })
                        ? snapshot.rootPath
                        : nil
                }
            )
            let rootsSnapshot = roots
            let snapshotsSnapshot = snapshots
            await MainActor.run {
                guard !Task.isCancelled,
                      generation == self.multiRootWorkspace.loadGeneration,
                      self.projectWorkspace.path.map(canonicalExternalLogPath) == requestedProjectPath,
                      !(self.externalLogWindow && self.logRuntime.externalSessionDisposed) else { return }
                self.multiRootWorkspace.loadTask = nil
                let needsRefresh = self.multiRootWorkspace.loadNeedsRefresh
                let completion = self.multiRootWorkspace.loadCompletion
                self.multiRootWorkspace.loadNeedsRefresh = false
                self.multiRootWorkspace.loadCompletion = nil
                if needsRefresh {
                    self.loadMultiRoots(onCompleted: completion)
                    return
                }
                let externalLogNeedsInitialLoad = self.externalLogWindow
                    && !self.logRuntime.externalAggregateLoadStarted
                    && !rootsSnapshot.isEmpty
                let externalLogSelection = reconciledExternalLogRootSelection(
                    availableRoots: rootsSnapshot.map(\.path),
                    selectedRoots: self.logRuntime.aggregateRootPaths,
                    initialized: self.logRuntime.externalRootSelectionInitialized
                )
                let externalLogSelectionChanged = self.externalLogWindow
                    && externalLogSelection != self.logRuntime.aggregateRootPaths
                self.multiRootWorkspace.roots = rootsSnapshot
                self.multiRootWorkspace.branchSnapshots = snapshotsSnapshot
                self.gitSettings.remoteProtectedBranchPatternsByRoot = Dictionary(
                    uniqueKeysWithValues: snapshotsSnapshot.compactMap { snapshot -> (String, [String])? in
                        guard !self.hostingRepositories(for: snapshot.remotes).isEmpty else {
                            return nil
                        }
                        let key = canonicalExternalLogPath(snapshot.rootPath)
                        return (key, GitProtectedBranchRules.loadRemotePatterns(for: key))
                    }
                )
                if let primaryPath = self.projectWorkspace.path {
                    let primaryKey = canonicalExternalLogPath(primaryPath)
                    self.gitSettings.remoteProtectedBranchPatterns =
                        self.gitSettings.remoteProtectedBranchPatternsByRoot[primaryKey] ?? []
                }
                self.operationRecovery.multiRootConflictGroups = conflictGroups
                if let selectedShelfRoot = self.shelfWorkspace.rootPath,
                   !rootsSnapshot.contains(where: {
                       canonicalExternalLogPath($0.path)
                           == canonicalExternalLogPath(selectedShelfRoot)
                   }) {
                    self.shelfWorkspace.rootLoadGeneration += 1
                    self.shelfWorkspace.rootPath = nil
                    self.shelfWorkspace.rootLoading = false
                    self.shelfWorkspace.rootRepository = nil
                    self.shelfWorkspace.rootError = nil
                    self.shelfWorkspace.rootSnapshots.removeValue(
                        forKey: canonicalExternalLogPath(selectedShelfRoot)
                    )
                    self.shelfWorkspace.previewName = nil
                    self.shelfWorkspace.previewRootPath = nil
                    self.shelfWorkspace.previewText = nil
                    self.shelfWorkspace.previewIsDeleted = false
                    self.shelfWorkspace.showPreview = false
                }
                if self.externalLogWindow {
                    self.logRuntime.aggregateRootPaths = externalLogSelection
                    self.logRuntime.externalRootSelectionInitialized = !externalLogSelection.isEmpty
                }
                let previousOperationRoots = Set(
                    self.operationRecovery.notificationFingerprints.keys
                )
                let activeOperationRoots = Set(operationStates.map {
                    operationRecoveryNotificationRootKey($0.0)
                })
                for rootKey in previousOperationRoots.subtracting(activeOperationRoots) {
                    self.feedbackCenter.expire(
                        notificationID: operationRecoveryNotificationID(rootPath: rootKey)
                    )
                }
                self.operationRecovery.notificationFingerprints =
                    self.operationRecovery.notificationFingerprints.filter {
                        activeOperationRoots.contains($0.key)
                    }
                for (rootPath, state) in operationStates {
                    self.publishOperationRecoveryNoticeIfNeeded(
                        state: state,
                        rootPath: rootPath
                    )
                }
                if self.logBranchesPanel.showOnlyMy {
                    self.refreshLogMyBranches()
                }
                if let activeRootPath = self.logList.activeRootPath {
                    if snapshotsSnapshot.count <= 1
                        || !snapshotsSnapshot.contains(where: { $0.rootPath == activeRootPath }) {
                        self.logList.activeRootPath = nil
                        self.logList.activeRepo = nil
                        self.logRuntime.activeBranches = []
                        self.logRuntime.activeRemoteBranches = []
                        self.logRuntime.activeRemotes = []
                    } else if let activeSnapshot = snapshotsSnapshot.first(
                        where: { $0.rootPath == activeRootPath }
                    ) {
                        // Keep the Log context tied to the refreshed root while
                        // retaining the live Repository for operations such as
                        // remote URL lookup and credential-aware actions.
                        self.logRuntime.activeBranches = activeSnapshot.branches
                        self.logRuntime.activeRemoteBranches = activeSnapshot.remoteBranches
                        if let activeRepo = self.logList.activeRepo {
                            self.logRuntime.activeRemotes = (try? activeRepo.remoteList()) ?? self.logRuntime.activeRemotes
                        }
                    }
                }
                if self.logRuntime.aggregateBranchFilters.contains(where: { filter in
                    !snapshotsSnapshot.contains(where: { $0.rootPath == filter.rootPath })
                }) {
                    self.logRuntime.aggregateBranchFilters = []
                    self.logRuntime.aggregateRevisionRanges = []
                    self.logRuntime.aggregateRepositories = [:]
                    self.logRuntime.aggregateLoadedCounts = [:]
                    self.logList.entries = []
                    self.logSelectionState.selection = nil
                    self.logSelectionState.selectedIDs = []
                }
                self.applyProjectGitExecutableOverride(
                    for: projectPath,
                    roots: rootsSnapshot.map(\.path)
                )
                // Rebuild this state from Git's stash stack on every refresh.
                // That makes a temporary Update stash discoverable after the
                // app is reopened instead of relying on in-memory bookkeeping.
                self.stashRecovery.multiRootUpdateStashedRoots = updateStashRoots
                self.scanPendingApplyRestores()
                if externalLogSelectionChanged {
                    if self.logRuntime.aggregateRootPaths.isEmpty {
                        self.logList.entries = []
                        self.logSelectionState.selection = nil
                        self.logSelectionState.selectedIDs = []
                    } else {
                        self.logRuntime.externalAggregateLoadStarted = true
                        if self.logList.viewMode == .command {
                            self.runLogCommand()
                        } else {
                            self.loadLog()
                        }
                    }
                } else if externalLogNeedsInitialLoad {
                    self.logRuntime.externalAggregateLoadStarted = true
                    if self.logList.viewMode == .command {
                        self.runLogCommand()
                    } else {
                        self.loadLog()
                    }
                }
                onCompleted?()
            }
        } catch {
            await MainActor.run {
                guard generation == self.multiRootWorkspace.loadGeneration,
                      self.projectWorkspace.path.map(canonicalExternalLogPath) == requestedProjectPath else {
                    return
                }
                self.multiRootWorkspace.loadTask = nil
                let needsRefresh = self.multiRootWorkspace.loadNeedsRefresh
                let completion = self.multiRootWorkspace.loadCompletion
                self.multiRootWorkspace.loadNeedsRefresh = false
                self.multiRootWorkspace.loadCompletion = nil
                if needsRefresh {
                    self.loadMultiRoots(onCompleted: completion)
                    return
                }
                self.multiRootWorkspace.roots = []
                self.multiRootWorkspace.branchSnapshots = []
                self.operationRecovery.multiRootConflictGroups = []
                self.stashRecovery.multiRootUpdateStashedRoots = []
                self.shelfWorkspace.rootLoadGeneration += 1
                self.shelfWorkspace.rootPath = nil
                self.shelfWorkspace.rootSnapshots = [:]
                self.shelfWorkspace.rootRepository = nil
                self.shelfWorkspace.rootLoading = false
                self.shelfWorkspace.rootError = nil
                self.logList.activeRootPath = nil
                self.logList.activeRepo = nil
                self.logRuntime.activeBranches = []
                self.logRuntime.activeRemoteBranches = []
                self.logRuntime.activeRemotes = []
                self.logRuntime.aggregateBranchFilters = []
                self.logRuntime.aggregateRevisionRanges = []
                self.logRuntime.aggregateRootPaths = []
                self.logRuntime.externalRootSelectionInitialized = false
                self.logRuntime.externalAggregateLoadStarted = false
                self.logRuntime.aggregateRepositories = [:]
                self.logRuntime.aggregateLoadedCounts = [:]
                onCompleted?()
            }
        }
    }
    multiRootWorkspace.loadTask = task
}

/// Open the project-level Changes Browser. Its write actions are still routed
/// to an explicit Git root rather than the window's primary repository.
func openMultiRootChanges() {
    multiRootWorkspace.showChanges = true
    loadMultiRootChanges()
}

/// Read status independently for every discovered Git root. The root path is
/// retained alongside the Repository so a diff can never fall back to the
/// primary repository merely because two roots contain the same relative path.
func loadMultiRootChanges() {
    multiRootWorkspace.changesGeneration &+= 1
    let generation = multiRootWorkspace.changesGeneration
    guard !multiRootWorkspace.roots.isEmpty else {
        multiRootWorkspace.changeGroups = []
        multiRootWorkspace.changesError = nil
        multiRootWorkspace.changesLoading = false
        return
    }

    let roots = multiRootWorkspace.roots.map {
        (path: $0.path, displayName: $0.displayName, relativePath: $0.relativePath)
    }
    multiRootWorkspace.changesLoading = true
    multiRootWorkspace.changesError = nil

    Task.detached(priority: .userInitiated) {
        var groups: [MultiRootChangeGroup] = []
        var failures: [String] = []

        for root in roots {
            do {
                let rootRepo = try openRepository(path: root.path)
                let entries = try rootRepo.status()
                groups.append(
                    MultiRootChangeGroup(
                        rootPath: root.path,
                        displayName: root.displayName,
                        relativePath: root.relativePath,
                        repository: rootRepo,
                        entries: entries
                    )
                )
            } catch {
                failures.append("\(root.displayName): \(error.localizedDescription)")
            }
        }

        groups.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        let loadedGroups = groups
        let failureMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
        await MainActor.run {
            guard generation == self.multiRootWorkspace.changesGeneration else { return }
            self.multiRootWorkspace.changeGroups = loadedGroups
            self.multiRootWorkspace.changesLoading = false
            self.multiRootWorkspace.changesError = failureMessage
        }
    }
}

func loadRepoData(includeComparisons: Bool = true) {
    guard let repo else { return }
    Task.detached(priority: .userInitiated) {
        do {
            let bs = try repo.branchList()
            let ignoredRules = (try? repo.ignoredRules()) ?? []
            let comparisons = includeComparisons ? branchComparisonMap(repo: repo) : nil
            let ss = try repo.stashList()
            let sh = try repo.shelveList()
            let dsh = (try? repo.shelveDeletedList()) ?? []
            let rs = try repo.remoteList()
            let isShallow = repo.isShallow()
            let remoteBranches = (try? repo.remoteBranchList()) ?? []
            let recentBranches = (try? repo.recentBranches(limit: 10)) ?? []
            let syncStatuses = (try? repo.syncStatus()) ?? []
            let ts = try repo.tagList()
            let submodules = (try? repo.submoduleList()) ?? []
            let identity = (try? repo.gitIdentity()) ?? GitIdentity(name: nil, email: nil, signingKey: nil, signingFormat: nil, signCommits: false)
            await MainActor.run {
                guard self.projectWorkspace.repository === repo else { return }
                self.branchWorkspace.branches = bs; self.repositoryStatus.ignoredRules = ignoredRules
                self.refreshLogMyBranches()
                if let comparisons { self.branchWorkspace.comparisons = comparisons }
                self.stashUI.stashes = ss; self.remoteWorkspace.remotes = rs
                self.repositoryStatus.isShallowRepository = isShallow
                self.restoreRemoteProtectedBranchPatterns(for: rs, projectPath: self.projectWorkspace.path)
                self.branchWorkspace.remoteBranches = remoteBranches
                self.branchWorkspace.recentBranches = recentBranches; self.branchWorkspace.syncStatuses = syncStatuses
                self.shelfWorkspace.shelves = sh; self.shelfWorkspace.deletedShelves = dsh; self.tagWorkspace.tags = ts
                self.refreshLfsPathMarkers()
                self.submoduleWorkspace.submodules = submodules
                self.gitSettings.identityName = identity.name ?? ""
                self.gitSettings.identityEmail = identity.email ?? ""
                self.gitSettings.identitySetNameEmailGlobally = GitIdentityScopeSettings.setNameEmailGlobally(
                    for: self.projectWorkspace.path
                )
                self.gitSettings.identitySigningKey = identity.signingKey ?? ""
                self.gitSettings.identitySigningFormat = identity.signingFormat ?? "gpg"
                self.gitSettings.identitySignCommits = identity.signCommits
                self.refreshCherryPickedHighlights()
            }
        } catch { await MainActor.run { self.repositoryStatus.loadError = errorMessage(error) } }
    }
}

}
