import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {

var cherryPickTargetBranchLabel: String {
    if isLogAggregate {
        return "each repository's current branch"
    }
    return Arbor.cherryPickTargetBranch(
        mode: logList.viewMode,
        sourceBranch: logCherryPickCompareBranch,
        firstBranch: compareRev1,
        secondBranch: compareRev2,
        currentBranch: branches.first(where: \.isCurrent)?.name
    )
}


@ViewBuilder
var logBranchesPanelView: some View {
    if multiRootBranchSnapshots.count > 1 {
        MultiRootLogBranchesPanel(
            projectPath: projectPath,
            snapshots: multiRootBranchSnapshots,
            groupByDirectory: $logBranchesPanel.groupByDirectory,
            groupByRepository: $logBranchesPanel.groupByRepository,
            selectionActionRaw: $logBranchesPanel.selectionActionRaw,
            showOnlyMy: $logBranchesPanel.showOnlyMy,
            myBranchIDs: logBranchesPanel.myBranchIDs,
            isLoadingMyBranches: isLoadingMyBranches,
            onShowOnlyMyChanged: setLogBranchesShowOnlyMy,
            onNavigate: navigateLogToBranch,
            onCompare: compareLogBranch,
            onFilter: applyLogBranchFilters,
            onNewBranch: presentMultiRootNewBranchDialog,
            onCleanup: deleteMergedBranches,
            onFindMerged: beginFindMergedBranches,
            onHide: { logBranchesVisible = false },
            onDelete: { rootPath, name in
                deleteBranchInRoot(rootPath: rootPath, name: name)
            },
            onCheckout: { rootPath, name, isRemote in
                checkoutBranchInRoot(rootPath: rootPath, reference: name, isRemote: isRemote)
            },
            onCheckoutAsNewBranch: { rootPath, name, isRemote in
                presentMultiRootNewBranchFromReference(
                    rootPath: rootPath,
                    reference: name,
                    isRemote: isRemote
                )
            },
            onOpenWorktree: { path in
                openWindow(value: path)
            },
            onCreateWorktreeFromReference: { rootPath, reference, isTag in
                presentNewWorktreeFromReference(
                    reference,
                    isTag: isTag,
                    rootPath: rootPath
                )
            },
            onCheckoutTag: { rootPath, name in
                checkoutTagInRoot(rootPath: rootPath, name: name)
            },
            onCheckoutAndUpdate: { rootPath, name, _ in
                executeMultiRootCheckoutAndUpdate(
                    reference: name,
                    rootPath: rootPath,
                    detach: false,
                    rebase: false
                )
            },
            onCheckoutWithRebase: { rootPath, name, isRemote in
                if isRemote {
                    presentNewBranchFromReference(
                        name,
                        isRemote: true,
                        afterCreateRebase: true,
                        rootPath: rootPath
                    )
                } else {
                    executeMultiRootCheckoutWithRebase(rootPath: rootPath, branch: name)
                }
            },
            onPullBranch: { rootPath, branch, rebase in
                pullBranchInRoot(rootPath: rootPath, branch: branch, rebase: rebase)
            },
            onUpdate: { rootPath, name in
                updateBranchInRoot(rootPath: rootPath, branch: name)
            },
            onMerge: { rootPath, name in
                mergeBranchInRoot(rootPath: rootPath, branch: name)
            },
            onRebase: { rootPath, name in
                rebaseCurrentInRoot(rootPath: rootPath, onto: name)
            },
            onShowDiffWithWorkingTree: { rootPath, branch in
                showBranchDiffWithWorkingTree(rootPath: rootPath, branch: branch)
            },
            onDeleteTag: { rootPath, name in
                deleteTagInRoot(rootPath: rootPath, name: name)
            },
            onPushTag: { rootPath, name in
                pushTagInRoot(rootPath: rootPath, name: name)
            },
            onPushTagToRemote: { rootPath, name, remote in
                pushTagInRoot(rootPath: rootPath, name: name, remote: remote)
            },
            onCompareSelected: { rootPath, first, second in
                compareBranchesCommitWiseInRoot(rootPath: rootPath, first: first, second: second)
            },
            onCompareSelectedFiles: { rootPath, first, second in
                compareBranchesInRoot(rootPath: rootPath, first: first, second: second)
            },
            onUpdateSelected: { targets in
                updateSelectedBranchesInRoots(targets)
            },
            onDeleteSelected: { targets in
                deleteSelectedBranchesInRoots(targets)
            },
            onEditRemote: { rootPath, name in
                beginMultiRootRemoteConfig(rootPath: rootPath, selectedRemote: name)
            },
            onRemoveRemote: { rootPath, name in
                removeRemoteInRoot(rootPath: rootPath, name: name)
            },
            onRemoveRemoteSelected: { groups in
                removeSelectedRemotesInRoots(groups)
            },
            onConfigureRemotes: beginConfigureRemotes,
            onPush: { rootPath, name in
                beginMultiRootPushDialog(rootPath: rootPath, branch: name)
            },
            onFetch: { rootPath, name in
                fetchRemoteBranchInRoot(rootPath: rootPath, branch: name)
            },
            onFetchAll: { doFetchAll() },
            onSetUpstream: { rootPath, name in
                setBranchUpstreamInRoot(rootPath: rootPath, branch: name)
            },
            onUnsetUpstream: { rootPath, name in
                unsetBranchUpstreamInRoot(rootPath: rootPath, branch: name)
            },
            onRename: { rootPath, name in
                renameBranchInRoot(rootPath: rootPath, oldName: name)
            },
            onDeleteRemote: { rootPath, name in
                deleteRemoteBranchInRoot(rootPath: rootPath, branch: name)
            },
            protectedBranchPatterns: effectiveProtectedBranchPatterns
        )
    } else {
        LogBranchesPanel(
            projectPath: projectPath,
            branches: branches,
            remoteBranches: remoteBranches,
            remotes: remotes,
            tags: tagWorkspace.tags,
            hasHeadCommit: headId != nil,
            syncStatuses: syncStatuses,
            protectedBranchPatterns: effectiveProtectedBranchPatterns,
            groupByDirectory: $logBranchesPanel.groupByDirectory,
            selectionActionRaw: $logBranchesPanel.selectionActionRaw,
            showOnlyMy: $logBranchesPanel.showOnlyMy,
            myBranchIDs: logBranchesPanel.myBranchIDs,
            isLoadingMyBranches: isLoadingMyBranches,
            onShowOnlyMyChanged: setLogBranchesShowOnlyMy,
            onNavigate: { branch in
                navigateLogToBranch(rootPath: nil, branch: branch)
            },
            onFilter: { filters in
                applyLogBranchFilters(filters)
            },
            onCompare: { branch in
                compareLogBranch(rootPath: nil, branch: branch)
            },
            onNewBranch: { presentNewBranchDialog() },
            onCleanup: deleteMergedBranches,
            onFindMerged: beginFindMergedBranches,
            onHide: { logBranchesVisible = false },
            onDelete: branchDelete,
            onCheckout: { reference, isRemote in
                if isRemote {
                    guard let branch = remoteBranches.first(where: { $0.name == reference }) else { return }
                    checkoutRemoteBranch(branch)
                } else {
                    switchBranch(reference)
                }
            },
            onCheckoutAsNewBranch: { reference, isRemote in
                presentNewBranchFromReference(reference, isRemote: isRemote)
            },
            worktrees: worktrees,
            onOpenWorktree: { path in
                openWindow(value: path)
            },
            onCreateWorktreeFromReference: { reference, isTag in
                presentNewWorktreeFromReference(reference, isTag: isTag)
            },
            onCheckoutTag: checkoutTag,
            onCheckoutAndUpdate: { reference, rebase in
                checkoutAndUpdate(reference, rebase: rebase)
            },
            onCheckoutWithRebase: { reference, isRemote in
                if isRemote {
                    presentNewBranchFromReference(reference, isRemote: true, afterCreateRebase: true)
                } else {
                    checkoutAndUpdate(reference, rebase: true)
                }
            },
            onPullBranch: { branch, rebase in
                pullSelectedBranch(branch, rebase: rebase)
            },
            onUpdate: updateSelectedBranch,
            onMerge: { branch in
                openMergeDialog(branch)
            },
            onRebase: { branch in
                openRebaseDialog(branch)
            },
            onShowDiffWithWorkingTree: { branch in
                showBranchDiffWithWorkingTree(rootPath: nil, branch: branch)
            },
            onDeleteTag: { tag in tagDelete(tag.name) },
            onPushTag: { tag in tagPushToRemote(tag) },
            onPushTagToRemote: { name, remote in
                tagPushToRemote(name, remote: remote)
            },
            onCompareSelected: { selection in
                guard let pair = branchDashboardComparisonPair(selection: selection),
                      let rootPath = projectPath,
                      pair.rootPath == rootPath else { return }
                compareBranchesCommitWiseInRoot(
                    rootPath: rootPath,
                    first: pair.first,
                    second: pair.second
                )
            },
            onCompareSelectedFiles: { selection in
                guard let pair = branchDashboardComparisonPair(selection: selection),
                      let rootPath = projectPath,
                      pair.rootPath == rootPath else { return }
                compareBranchesInRoot(
                    rootPath: rootPath,
                    first: pair.first,
                    second: pair.second
                )
            },
            onUpdateSelected: updateSelectedBranchesInRoots,
            onDeleteSelected: deleteSelectedBranchesInRoots,
            onPush: { branch in
                beginPushDialog(branch: branch)
            },
            onFetch: { reference in
                guard let branch = remoteBranches.first(where: { $0.name == reference }) else { return }
                fetchRemoteBranch(branch)
            },
            onFetchAll: { doFetchAll() },
            onSetUpstream: { branch in
                upstreamLocalBranch = branch
                showUpstreamDialog = true
            },
            onUnsetUpstream: unsetBranchUpstream,
            onRename: renameBranchFromPopup,
            onDeleteRemote: deleteRemoteBranch
        )
    }
}


/// IntelliJ 的 Log 分支 dashboard：分支树与历史过滤处于同一工作区，
/// 而不是把用户强制带回顶部 Branches popup。
struct MultiRootLogBranchesPanel: View {
    let projectPath: String?
    let snapshots: [GitRootBranchSnapshot]
    @Binding var groupByDirectory: Bool
    @Binding var groupByRepository: Bool
    @Binding var selectionActionRaw: String
    @Binding var showOnlyMy: Bool
    let myBranchIDs: Set<String>
    let isLoadingMyBranches: Bool
    let onShowOnlyMyChanged: (Bool) -> Void
    let onNavigate: (String, String) -> Void
    let onCompare: (String, String) -> Void
    let onFilter: ([LogRootBranchFilter]) -> Void
    let onNewBranch: () -> Void
    let onCleanup: () -> Void
    let onFindMerged: () -> Void
    let onHide: () -> Void
    let onDelete: (String, String) -> Void
    let onCheckout: (String, String, Bool) -> Void
    let onCheckoutAsNewBranch: (String, String, Bool) -> Void
    let onOpenWorktree: (String) -> Void
    let onCreateWorktreeFromReference: (String, String, Bool) -> Void
    let onCheckoutTag: (String, String) -> Void
    let onCheckoutAndUpdate: (String, String, Bool) -> Void
    let onCheckoutWithRebase: (String, String, Bool) -> Void
    let onPullBranch: (String, String, Bool) -> Void
    let onUpdate: (String, String) -> Void
    let onMerge: (String, String) -> Void
    let onRebase: (String, String) -> Void
    let onShowDiffWithWorkingTree: (String, String) -> Void
    let onDeleteTag: (String, String) -> Void
    let onPushTag: (String, String) -> Void
    let onPushTagToRemote: (String, String, String) -> Void
    let onCompareSelected: (String, String, String) -> Void
    let onCompareSelectedFiles: (String, String, String) -> Void
    let onUpdateSelected: ([BranchDashboardReference]) -> Void
    let onDeleteSelected: ([BranchDashboardReference]) -> Void
    let onEditRemote: (String, String) -> Void
    let onRemoveRemote: (String, String) -> Void
    let onRemoveRemoteSelected: ([BranchDashboardRemoteGroup]) -> Void
    let onConfigureRemotes: () -> Void
    let onPush: (String, String) -> Void
    let onFetch: (String, String) -> Void
    let onFetchAll: () -> Void
    let onSetUpstream: (String, String) -> Void
    let onUnsetUpstream: (String, String) -> Void
    let onRename: (String, String) -> Void
    let onDeleteRemote: (String, String) -> Void
    let protectedBranchPatterns: [String]

    @State var query = ""
    @State var collapsedDirectoryGroups: Set<String> = []
    @State var selectedBranchTargetID: String?
    @State var selectedBranchTargetIDs: Set<String> = []
    @State var branchSelectionAnchorID: String?
    @State var selectedRemoteGroupIDs: Set<String> = []
    @State var favoriteReferenceIDs: Set<String> = []
    @State var showTags = GitBranchesPopupSettings.defaultShowTags

    var dashboardRemoteGroups: [BranchDashboardRemoteGroup] {
        filteredSnapshots.flatMap { snapshot in
            let names = Set(snapshot.remotes.map(\.name) + snapshot.remoteBranches.map(\.remote))
            return names.map { name in
                BranchDashboardRemoteGroup(rootPath: snapshot.rootPath, name: name)
            }
        }
        .sorted {
            if $0.rootPath == $1.rootPath { return $0.name < $1.name }
            return $0.rootPath < $1.rootPath
        }
    }

    var selectedDashboardRemoteGroups: [BranchDashboardRemoteGroup] {
        dashboardRemoteGroups.filter { group in
            selectedRemoteGroupIDs.contains(remoteGroupTargetID(
                rootPath: group.rootPath,
                name: group.name
            ))
        }
    }

    var hasMixedDashboardSelection: Bool {
        !selectedDashboardReferences.isEmpty && !selectedDashboardRemoteGroups.isEmpty
    }

    var selectionAction: LogBranchSelectionAction {
        get { LogBranchSelectionAction(rawValue: selectionActionRaw) ?? .navigate }
        set { selectionActionRaw = newValue.rawValue }
    }

    var selectionActionBinding: Binding<LogBranchSelectionAction> {
        Binding(
            get: { LogBranchSelectionAction(rawValue: selectionActionRaw) ?? .navigate },
            set: {
                selectionActionRaw = $0.rawValue
                GitBranchesPopupSettings.save(
                    $0.rawValue,
                    GitBranchesPopupSettings.logSelectionActionKey,
                    for: projectPath
                )
            }
        )
    }

    var filteredSnapshots: [GitRootBranchSnapshot] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !showOnlyMy && normalized.isEmpty && showTags {
            return snapshots
        }
        return snapshots.compactMap { snapshot in
            let localCandidates = showOnlyMy
                ? snapshot.branches.filter {
                    myBranchIDs.contains(BranchDashboardReference.referenceID(
                        rootPath: snapshot.rootPath,
                        name: $0.name,
                        kind: .local
                    ))
                }
                : snapshot.branches
            let remoteCandidates = showOnlyMy
                ? snapshot.remoteBranches.filter {
                    myBranchIDs.contains(BranchDashboardReference.referenceID(
                        rootPath: snapshot.rootPath,
                        name: $0.name,
                        kind: .remote
                    ))
                }
                : snapshot.remoteBranches
            let local = normalized.isEmpty
                ? localCandidates
                : localCandidates.filter { branchSearchMatches($0.name, query: query) }
            let remote = normalized.isEmpty
                ? remoteCandidates
                : remoteCandidates.filter { branchSearchMatches($0.name, query: query) }
            let remotes = showOnlyMy
                ? snapshot.remotes.filter { Set(remoteCandidates.map(\.remote)).contains($0.name) }
                : snapshot.remotes.filter { branchSearchMatches($0.name, query: query) }
            let tags = showTags && !showOnlyMy
                ? (normalized.isEmpty
                    ? snapshot.tags
                    : snapshot.tags.filter { branchSearchMatches($0.name, query: query) })
                : []
            // IntelliJ keeps the synthetic HEAD node visible for every
            // repository, including detached and unborn roots, even when
            // the selected filter hides every named ref.
            return GitRootBranchSnapshot(
                rootPath: snapshot.rootPath,
                displayName: snapshot.displayName,
                relativePath: snapshot.relativePath,
                headBranch: snapshot.headBranch,
                headId: snapshot.headId,
                branches: local,
                remoteBranches: remote,
                remotes: remotes,
                syncStatuses: snapshot.syncStatuses,
                recentBranches: snapshot.recentBranches,
                tags: tags,
                stashes: snapshot.stashes,
                shelves: snapshot.shelves,
                worktrees: snapshot.worktrees
            )
        }
    }

    var keyboardTargets: [BranchTreeTarget] {
        filteredSnapshots.flatMap { snapshot in
            let head = BranchTreeTarget(
                id: targetID(rootPath: snapshot.rootPath, kind: .head, value: "HEAD"),
                value: "HEAD",
                title: "HEAD",
                kind: .head,
                rootPath: snapshot.rootPath
            )
            let local = visibleBranchDirectoryRefNames(
                snapshot.branches.map(\.name),
                grouped: groupByDirectory,
                scope: "\(snapshot.rootPath).log.local",
                collapsedGroups: collapsedDirectoryGroups
            ).map {
                BranchTreeTarget(
                    id: targetID(rootPath: snapshot.rootPath, kind: .local, value: $0),
                    value: $0,
                    title: $0,
                    kind: .local,
                    rootPath: snapshot.rootPath
                )
            }
            let remote = visibleBranchDirectoryRefNames(
                snapshot.remoteBranches.map(\.name),
                grouped: groupByDirectory,
                scope: "\(snapshot.rootPath).log.remote",
                collapsedGroups: collapsedDirectoryGroups
            ).map {
                BranchTreeTarget(
                    id: targetID(rootPath: snapshot.rootPath, kind: .remote, value: $0),
                    value: $0,
                    title: $0,
                    kind: .remote,
                    rootPath: snapshot.rootPath
                )
            }
            let remoteGroups = remoteGroupNames(snapshot).map { name in
                BranchTreeTarget(
                    id: remoteGroupTargetID(rootPath: snapshot.rootPath, name: name),
                    value: name,
                    title: name,
                    kind: .remoteGroup,
                    rootPath: snapshot.rootPath
                )
            }
            let tags = visibleBranchDirectoryRefNames(
                snapshot.tags.map(\.name),
                grouped: groupByDirectory,
                scope: "\(snapshot.rootPath).log.tags",
                collapsedGroups: collapsedDirectoryGroups
            ).map {
                BranchTreeTarget(
                    id: targetID(rootPath: snapshot.rootPath, kind: .tag, value: $0),
                    value: $0,
                    title: $0,
                    kind: .tag,
                    rootPath: snapshot.rootPath
                )
            }
            return [head] + local + remoteGroups + remote + tags
        }
    }

    var visibleBranchSelectionIDs: [String] {
        keyboardTargets.compactMap { target in
            guard target.kind == .head
                    || target.kind == .local
                    || target.kind == .remote
                    || target.kind == .tag else {
                return nil
            }
            return target.id
        }
    }

    var dashboardReferences: [BranchDashboardReference] {
        filteredSnapshots.flatMap { snapshot in
            let head = BranchDashboardReference(
                rootPath: snapshot.rootPath,
                name: "HEAD",
                kind: .head,
                remote: nil,
                isCurrent: true,
                hasUpstream: false,
                hasTracking: false,
                hasRemote: false,
                isProtected: false,
                hasHeadCommit: snapshot.headId != nil,
                worktreePath: snapshot.headBranch.flatMap { branch in
                    linkedWorktreePathForBranch(
                        branch: branch,
                        worktrees: snapshot.worktrees,
                        currentRootPath: snapshot.rootPath
                    )
                },
                headBranchName: snapshot.headBranch
            )
            let locals = snapshot.branches.map { branch in
                let sync = snapshot.syncStatuses.first { $0.branch == branch.name }
                return BranchDashboardReference(
                    rootPath: snapshot.rootPath,
                    name: branch.name,
                    kind: .local,
                    remote: nil,
                    isCurrent: branch.isCurrent,
                    hasUpstream: sync != nil,
                    hasTracking: sync?.trackingExists == true,
                    hasRemote: hasConfiguredRemote(in: snapshot.rootPath) || sync != nil,
                    isProtected: GitProtectedBranchRules.matches(
                        branch.name,
                        patterns: protectedBranchPatterns
                    ),
                    worktreePath: linkedWorktreePathForBranch(
                        branch: branch.name,
                        worktrees: snapshot.worktrees,
                        currentRootPath: snapshot.rootPath
                    )
                )
            }
            let remotes = snapshot.remoteBranches.map { branch in
                let branchName = branch.name.split(separator: "/", maxSplits: 1)
                    .dropFirst()
                    .joined(separator: "/")
                let localBranchName = snapshot.syncStatuses
                    .first { $0.upstream == branch.name }?
                    .branch
                return BranchDashboardReference(
                    rootPath: snapshot.rootPath,
                    name: branch.name,
                    kind: .remote,
                    remote: branch.remote,
                    localBranchName: localBranchName,
                    isCurrent: false,
                    hasUpstream: false,
                    hasTracking: false,
                    hasRemote: true,
                    isProtected: GitProtectedBranchRules.matches(
                        branchName.isEmpty ? branch.name : branchName,
                        patterns: protectedBranchPatterns
                    )
                )
            }
            let tags = snapshot.tags.map { tag in
                BranchDashboardReference(
                    rootPath: snapshot.rootPath,
                    name: tag.name,
                    kind: .tag,
                    remote: nil,
                    isCurrent: tag.isCurrent,
                    hasUpstream: false,
                    hasTracking: false,
                    hasRemote: hasConfiguredRemote(in: snapshot.rootPath),
                    isProtected: false
                )
            }
            return [head] + locals + remotes + tags
        }
    }

    func dashboardReference(
        rootPath: String,
        name: String,
        kind: BranchDashboardReferenceKind
    ) -> BranchDashboardReference? {
        dashboardReferences.first {
            $0.rootPath == rootPath && $0.name == name && $0.kind == kind
        }
    }

    func hasConfiguredRemote(in rootPath: String) -> Bool {
        snapshots.first(where: { $0.rootPath == rootPath })?.remotes.isEmpty == false
    }

    func dashboardTargetKind(
        for kind: BranchDashboardReferenceKind
    ) -> BranchTreeTargetKind {
        switch kind {
        case .head: return .head
        case .local: return .local
        case .remote: return .remote
        case .tag: return .tag
        }
    }

    var selectedDashboardReferences: [BranchDashboardReference] {
        dashboardReferences.filter { reference in
            selectedBranchTargetIDs.contains(
                targetID(
                    rootPath: reference.rootPath,
                    kind: dashboardTargetKind(for: reference.kind),
                    value: reference.name
                )
            )
        }
    }

    var selectedBranchReferencesForCurrentComparison: [BranchDashboardReference] {
        selectedDashboardReferences.filter { reference in
            (reference.kind == .local || reference.kind == .remote) && !reference.isCurrent
        }
    }

    func dashboardSelection(
        for reference: BranchDashboardReference
    ) -> [BranchDashboardReference] {
        let selected = dashboardReferences.filter { target in
            selectedBranchTargetIDs.contains(
                targetID(
                    rootPath: target.rootPath,
                    kind: dashboardTargetKind(for: target.kind),
                    value: target.name
                )
            )
        }
        return selected.contains(reference) ? selected : [reference]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    .foregroundStyle(.blue)
                Text("Branches")
                    .font(.headline)
                Text("\(filteredSnapshots.count) repositories")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { createNewBranchFromSelection() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("New branch")
                Button { onHide() } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(.borderless)
                    .help("Hide branches")
            }
            TextField("Filter branches", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { activateSelectedBranch() }
                .onKeyPress(.downArrow, action: handleDownKeyPress)
                .onKeyPress(.upArrow, action: handleUpKeyPress)
            HStack(spacing: 6) {
                Toggle("Group by repository", isOn: $groupByRepository)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Toggle("Group by directory", isOn: $groupByDirectory)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Toggle("Show My Branches", isOn: $showOnlyMy)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Toggle("Show Tags", isOn: $showTags)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                if isLoadingMyBranches {
                    ProgressView()
                        .controlSize(.small)
                }
                Picker("On selection", selection: selectionActionBinding) {
                    ForEach(LogBranchSelectionAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .help("Choose what selecting a branch does")
                Spacer()
                Button("Filter Selected") { filterSelectedBranches() }
                    .controlSize(.small)
                    .disabled(selectedDashboardReferences.isEmpty)
                Menu("Actions…") {
                    if !selectedDashboardRemoteGroups.isEmpty,
                       selectedDashboardReferences.isEmpty {
                        remoteGroupActionMenu(for: selectedDashboardRemoteGroups)
                    } else if selectedDashboardRemoteGroups.isEmpty {
                        BranchDashboardActionMenu(
                            selection: selectedDashboardReferences,
                            handlers: dashboardActionHandlers,
                            allowsWorktreeAction: true
                        )
                    }
                }
                .controlSize(.small)
                .disabled(
                    (selectedDashboardReferences.isEmpty && selectedDashboardRemoteGroups.isEmpty)
                        || hasMixedDashboardSelection
                )
                Button("Find Merged…") { onFindMerged() }
                    .controlSize(.small)
                Button("Cleanup…") { onCleanup() }
                    .controlSize(.small)
            }
            dashboardActionToolbar
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if filteredSnapshots.isEmpty {
                        Text("No matching branches")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if logBranchesGroupingMode(
                        repositoryCount: snapshots.count,
                        groupByRepository: groupByRepository
                    ) == .repository {
                        ForEach(filteredSnapshots, id: \.rootPath) { snapshot in
                            rootSection(snapshot)
                        }
                    } else {
                        refKindSections
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(10)
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Colors.surface.opacity(0.55))
        .onAppear {
            groupByRepository = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.groupByRepositoryKey,
                for: projectPath
            )
            groupByDirectory = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.groupByDirectoryKey,
                for: projectPath
            )
            favoriteReferenceIDs = GitBranchesPopupSettings.favorites(for: projectPath)
            showTags = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.showTagsKey,
                for: projectPath
            )
            selectedBranchTargetID = bestBranchTreeTargetID(
                query: query,
                targets: keyboardTargets,
                preserving: selectedBranchTargetID
            )
            if selectedBranchTargetIDs.isEmpty, let selectedBranchTargetID {
                if visibleBranchSelectionIDs.contains(selectedBranchTargetID) {
                    selectedBranchTargetIDs = [selectedBranchTargetID]
                } else if selectedRemoteGroupIDs.isEmpty {
                    selectedRemoteGroupIDs = [selectedBranchTargetID]
                }
            }
            reconcileDashboardSelection()
            collapsedDirectoryGroups = GitBranchesPopupSettings.collapsedDirectoryGroups(
                for: projectPath,
                setting: GitBranchesPopupSettings.logCollapsedDirectoryGroupsKey
            )
        }
        .onChange(of: projectPath) { _, path in
            groupByRepository = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.groupByRepositoryKey,
                for: path
            )
            groupByDirectory = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.groupByDirectoryKey,
                for: path
            )
            collapsedDirectoryGroups = GitBranchesPopupSettings.collapsedDirectoryGroups(
                for: path,
                setting: GitBranchesPopupSettings.logCollapsedDirectoryGroupsKey
            )
            reconcileDashboardSelection()
        }
        .onChange(of: query) { _, _ in
            selectedBranchTargetID = bestBranchTreeTargetID(
                query: query,
                targets: keyboardTargets,
                preserving: selectedBranchTargetID
            )
            reconcileDashboardSelection()
        }
        .onChange(of: showOnlyMy) { _, value in
            onShowOnlyMyChanged(value)
            selectedBranchTargetID = bestBranchTreeTargetID(
                query: query,
                targets: keyboardTargets,
                preserving: selectedBranchTargetID
            )
            reconcileDashboardSelection()
        }
        .onChange(of: showTags) { _, value in
            GitBranchesPopupSettings.save(
                value,
                GitBranchesPopupSettings.showTagsKey,
                for: projectPath
            )
            selectedBranchTargetID = bestBranchTreeTargetID(
                query: query,
                targets: keyboardTargets,
                preserving: selectedBranchTargetID
            )
            reconcileDashboardSelection()
        }
        .onChange(of: groupByRepository) { _, value in
            GitBranchesPopupSettings.save(
                value,
                GitBranchesPopupSettings.groupByRepositoryKey,
                for: projectPath
            )
            reconcileDashboardSelection()
        }
        .onChange(of: groupByDirectory) { _, value in
            GitBranchesPopupSettings.save(
                value,
                GitBranchesPopupSettings.groupByDirectoryKey,
                for: projectPath
            )
            reconcileDashboardSelection()
        }
        .onChange(of: snapshots) { _, _ in
            reconcileDashboardSelection()
        }
        .onChange(of: collapsedDirectoryGroups) { _, value in
            GitBranchesPopupSettings.saveCollapsedDirectoryGroups(
                value,
                for: projectPath,
                setting: GitBranchesPopupSettings.logCollapsedDirectoryGroupsKey
            )
        }
    }

    var dashboardActionToolbar: some View {
        let selection = selectedDashboardReferences
        let availability = BranchDashboardActionAvailability.resolve(selection: selection)
        let compareTargets = selectedBranchReferencesForCurrentComparison
        let canToggleFavorite = !selection.isEmpty
            && selection.allSatisfy { $0.kind != .head }
            && selectedDashboardRemoteGroups.isEmpty

        return HStack(spacing: 5) {
            Button {
                onFetchAll()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
            .help("Fetch All Remotes")

            Button {
                toggleFavorites(selection)
            } label: {
                Image(systemName: "star")
            }
            .buttonStyle(.borderless)
            .disabled(!canToggleFavorite)
            .help("Mark/Unmark As Favorite")

            Button {
                compareTargets.forEach { onCompare($0.rootPath, $0.name) }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.borderless)
            .disabled(compareTargets.isEmpty)
            .help("Compare with Current")

            Button {
                onUpdateSelected(selection)
            } label: {
                Image(systemName: "arrow.down.to.line.compact")
            }
            .buttonStyle(.borderless)
            .disabled(!availability.isEnabled(.updateSelected))
            .help("Update Selected Branches")

            Button(role: .destructive) {
                onDeleteSelected(selection)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!availability.isEnabled(.deleteSelected))
            .help("Delete Selected")

            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    func createNewBranchFromSelection() {
        guard selectedDashboardReferences.count == 1,
              let reference = selectedDashboardReferences.first else {
            onNewBranch()
            return
        }
        onCheckoutAsNewBranch(
            reference.rootPath,
            reference.name,
            reference.kind == .remote
        )
    }

    func targetID(rootPath: String, kind: BranchTreeTargetKind, value: String) -> String {
        let kindValue: String
        switch kind {
        case .action: kindValue = "action"
        case .repository: kindValue = "repository"
        case .head: kindValue = "head"
        case .local: kindValue = "local"
        case .remote: kindValue = "remote"
        case .remoteGroup: kindValue = "remote-group"
        case .recent: kindValue = "recent"
        case .tag: kindValue = "tag"
        }
        return "log.multi:\(rootPath):\(kindValue):\(value)"
    }

    func remoteGroupTargetID(rootPath: String, name: String) -> String {
        targetID(rootPath: rootPath, kind: .remoteGroup, value: name)
    }

    func moveSelectedBranch(by offset: Int) {
        let nextID = movedBranchTreeSelection(
            currentID: selectedBranchTargetID,
            selectableIDs: keyboardTargets.map(\.id),
            offset: offset
        )
        selectedBranchTargetID = nextID
        selectedRemoteGroupIDs = []
        if let nextID,
           let kind = keyboardTargets.first(where: { $0.id == nextID })?.kind,
           kind == .head || kind == .local || kind == .remote || kind == .tag {
            selectedBranchTargetIDs = [nextID]
            branchSelectionAnchorID = nextID
        } else if let nextID,
                  keyboardTargets.first(where: { $0.id == nextID })?.kind == .remoteGroup {
            selectedBranchTargetIDs = []
            selectedRemoteGroupIDs = [nextID]
            branchSelectionAnchorID = nil
        } else {
            selectedBranchTargetIDs = []
            branchSelectionAnchorID = nil
        }
    }

    func handleDownKeyPress() -> KeyPress.Result {
        moveSelectedBranch(by: 1)
        return .handled
    }

    func handleUpKeyPress() -> KeyPress.Result {
        moveSelectedBranch(by: -1)
        return .handled
    }

    func activateSelectedBranch() {
        guard let selectedBranchTargetID,
              let target = keyboardTargets.first(where: { $0.id == selectedBranchTargetID }) else { return }
        if target.kind == .remoteGroup {
            selectRemoteGroupTarget(id: target.id)
            return
        }
        performSelectionAction()
    }

    func reconcileDashboardSelection() {
        let visibleBranchIDs = Set(visibleBranchSelectionIDs)
        selectedBranchTargetIDs.formIntersection(visibleBranchIDs)
        if let branchSelectionAnchorID,
           !visibleBranchIDs.contains(branchSelectionAnchorID) {
            self.branchSelectionAnchorID = nil
        }
        let visibleRemoteGroupIDs = Set(filteredSnapshots.flatMap { snapshot in
            remoteGroupNames(snapshot).map {
                remoteGroupTargetID(rootPath: snapshot.rootPath, name: $0)
            }
        })
        selectedRemoteGroupIDs.formIntersection(visibleRemoteGroupIDs)
        if selectedBranchTargetIDs.isEmpty,
           selectedRemoteGroupIDs.isEmpty,
           let selectedBranchTargetID {
            if visibleBranchIDs.contains(selectedBranchTargetID) {
                selectedBranchTargetIDs = [selectedBranchTargetID]
                if branchSelectionAnchorID == nil {
                    branchSelectionAnchorID = selectedBranchTargetID
                }
            } else if visibleRemoteGroupIDs.contains(selectedBranchTargetID) {
                selectedRemoteGroupIDs = [selectedBranchTargetID]
            }
        }
    }

    func filterSelectedBranches() {
        let filters = logBranchFiltersForDashboardSelection(selectedDashboardReferences)
        guard !filters.isEmpty else { return }
        onFilter(filters)
    }

    func toggleFavorites(_ selection: [BranchDashboardReference]) {
        var updated = favoriteReferenceIDs
        for reference in selection {
            if updated.contains(reference.favoriteID) {
                updated.remove(reference.favoriteID)
            } else {
                updated.insert(reference.favoriteID)
            }
        }
        favoriteReferenceIDs = updated
        GitBranchesPopupSettings.saveFavorites(updated, for: projectPath)
    }

    func performSelectionAction() {
        guard let reference = selectedDashboardReferences.first else { return }
        switch selectionAction {
        case .navigate:
            onNavigate(reference.rootPath, reference.name)
        case .filter:
            let filters = logBranchFiltersForDashboardSelection(selectedDashboardReferences)
            guard !filters.isEmpty else { return }
            onFilter(filters)
        case .none:
            break
        }
    }

    @ViewBuilder
    var refKindSections: some View {
        refKindSectionHeader("HEAD")
        ForEach(filteredSnapshots, id: \.rootPath) { snapshot in
            repositoryLabel(snapshot)
            headRow(snapshot)
        }

        refKindSectionHeader("LOCAL")
        ForEach(filteredSnapshots, id: \.rootPath) { snapshot in
            repositoryLabel(snapshot)
            branchSection(
                title: "",
                names: snapshot.branches.map(\.name),
                rootPath: snapshot.rootPath,
                isRemote: false,
                snapshot: snapshot
            )
        }

        remoteRefKindSectionHeader
        ForEach(filteredSnapshots, id: \.rootPath) { snapshot in
            repositoryLabel(snapshot)
            remoteBranchRows(snapshot)
        }

        if filteredSnapshots.contains(where: { !$0.tags.isEmpty }) {
            refKindSectionHeader("TAGS")
            ForEach(filteredSnapshots, id: \.rootPath) { snapshot in
                if !snapshot.tags.isEmpty {
                    repositoryLabel(snapshot)
                    tagRows(snapshot)
                }
            }
        }
    }

    func refKindSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    var remoteRefKindSectionHeader: some View {
        HStack(spacing: 6) {
            Text("REMOTE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Configure…") { onConfigureRemotes() }
                .buttonStyle(.borderless)
                .font(.caption2)
        }
        .padding(.top, 4)
    }

    func repositoryLabel(_ snapshot: GitRootBranchSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(snapshot.displayName)
                .font(.caption2.weight(.semibold))
            Text(snapshot.relativePath)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    func rootSection(_ snapshot: GitRootBranchSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.displayName)
                    .font(.system(size: 12, weight: .semibold))
                Text(snapshot.relativePath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            headRow(snapshot)
            branchSection(
                title: "LOCAL",
                names: snapshot.branches.map(\.name),
                rootPath: snapshot.rootPath,
                isRemote: false,
                snapshot: snapshot
            )
            remoteSection(snapshot)
            tagSection(snapshot)
        }
        .padding(.bottom, 4)
    }

    func headRow(_ snapshot: GitRootBranchSnapshot) -> some View {
        let id = targetID(rootPath: snapshot.rootPath, kind: .head, value: "HEAD")
        return Button {
            selectBranchTarget(id: id, rootPath: snapshot.rootPath, branch: "HEAD")
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "circle.hexagongrid.fill")
                    .foregroundStyle(.blue)
                Text("HEAD")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.semibold)
                if let headBranch = snapshot.headBranch, !headBranch.isEmpty {
                    Text("(\(headBranch))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("(detached)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            selectedBranchTargetIDs.contains(id) ? Color.accentColor.opacity(0.22) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .help("Navigate Log to HEAD")
        .contextMenu {
            if let reference = dashboardReference(
                rootPath: snapshot.rootPath,
                name: "HEAD",
                kind: .head
            ) {
                BranchDashboardActionMenu(
                    selection: dashboardSelection(for: reference),
                    handlers: dashboardActionHandlers,
                    allowsWorktreeAction: true
                )
            }
        }
    }

    @ViewBuilder
    func remoteSection(_ snapshot: GitRootBranchSnapshot) -> some View {
        HStack(spacing: 6) {
            Text("REMOTE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Configure…") { onConfigureRemotes() }
                .buttonStyle(.borderless)
                .font(.caption2)
        }
        .padding(.top, 4)

        remoteBranchRows(snapshot)
    }

    @ViewBuilder
    func remoteBranchRows(_ snapshot: GitRootBranchSnapshot) -> some View {
        ForEach(remoteGroupNames(snapshot), id: \.self) { remoteName in
            remoteGroupRow(
                rootPath: snapshot.rootPath,
                name: remoteName,
                branchCount: snapshot.remoteBranches.filter { $0.remote == remoteName }.count
            )
            branchSection(
                title: "",
                names: snapshot.remoteBranches
                    .filter { $0.remote == remoteName }
                    .map(\.name),
                rootPath: snapshot.rootPath,
                isRemote: true,
                snapshot: snapshot,
                scopeSuffix: remoteName
            )
        }
    }

    func remoteGroupNames(_ snapshot: GitRootBranchSnapshot) -> [String] {
        var names = snapshot.remotes.map(\.name)
        for remote in snapshot.remoteBranches.map(\.remote) where !names.contains(remote) {
            names.append(remote)
        }
        return names.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    @ViewBuilder
    func tagSection(_ snapshot: GitRootBranchSnapshot) -> some View {
        if !snapshot.tags.isEmpty {
            Text("TAGS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            tagRows(snapshot)
        }
    }

    @ViewBuilder
    func tagRows(_ snapshot: GitRootBranchSnapshot) -> some View {
            ForEach(visibleBranchDirectoryRows(
                branchDirectoryRows(
                    for: snapshot.tags.map(\.name),
                    grouped: groupByDirectory,
                    scope: "\(snapshot.rootPath).log.tags"
                ),
                collapsedGroups: collapsedDirectoryGroups
            )) { row in
                if row.isGroup {
                    directoryGroupRow(row)
                } else if let tagName = branchReferenceName(row),
                          let tag = snapshot.tags.first(where: { $0.name == tagName }) {
                    tagRow(
                        tag,
                        title: row.name,
                        depth: row.depth,
                        rootPath: snapshot.rootPath
                    )
                }
            }
    }

    @ViewBuilder
    func branchSection(
        title: String,
        names: [String],
        rootPath: String,
        isRemote: Bool,
        snapshot: GitRootBranchSnapshot,
        scopeSuffix: String? = nil
    ) -> some View {
        if !title.isEmpty {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        ForEach(visibleBranchDirectoryRows(
            branchDirectoryRows(
                for: names,
                grouped: groupByDirectory,
                scope: "\(rootPath).log.\(isRemote ? "remote" : "local")\(scopeSuffix.map { ".\($0)" } ?? "")"
            ),
            collapsedGroups: collapsedDirectoryGroups
        )) { row in
            if row.isGroup {
                directoryGroupRow(row)
            } else if let branchName = branchReferenceName(row) {
                if isRemote,
                   let branch = snapshot.remoteBranches.first(where: { $0.name == branchName }) {
                    remoteBranchRow(branch, title: row.name, depth: row.depth, rootPath: rootPath)
                } else if !isRemote,
                          let branch = snapshot.branches.first(where: { $0.name == branchName }) {
                    localBranchRow(branch, title: row.name, depth: row.depth, rootPath: rootPath)
                }
            }
        }
    }

    func localBranchRow(
        _ branch: BranchInfo,
        title: String,
        depth: Int,
        rootPath: String
    ) -> some View {
        let id = targetID(rootPath: rootPath, kind: .local, value: branch.name)
        let isFavorite = dashboardReference(rootPath: rootPath, name: branch.name, kind: .local)
            .map { favoriteReferenceIDs.contains($0.favoriteID) } == true
        return Button {
            selectBranchTarget(id: id, rootPath: rootPath, branch: branch.name)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: branch.isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch")
                    .foregroundStyle(branch.isCurrent ? .blue : .secondary)
                Text(title)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(branch.isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                Spacer()
                if isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                }
                Text(branch.shortId)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, CGFloat(depth) * 14)
        .background(
            selectedBranchTargetIDs.contains(id) ? Color.accentColor.opacity(0.22) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .help(branch.isCurrent ? "Current branch" : "Navigate Log to \(branch.name)")
        .contextMenu {
            if let reference = dashboardReference(
                rootPath: rootPath,
                name: branch.name,
                kind: .local
            ) {
                branchActionMenu(for: reference)
            }
        }
    }

    func remoteBranchRow(
        _ branch: RemoteBranchInfo,
        title: String,
        depth: Int,
        rootPath: String
    ) -> some View {
        let id = targetID(rootPath: rootPath, kind: .remote, value: branch.name)
        let isFavorite = dashboardReference(rootPath: rootPath, name: branch.name, kind: .remote)
            .map { favoriteReferenceIDs.contains($0.favoriteID) } == true
        return Button {
            selectBranchTarget(id: id, rootPath: rootPath, branch: branch.name)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cloud")
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                if isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                }
                Text(branch.shortId)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, CGFloat(depth) * 14)
        .background(
            selectedBranchTargetIDs.contains(id) ? Color.accentColor.opacity(0.22) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .help("Navigate Log to \(branch.name)")
        .contextMenu {
            if let reference = dashboardReference(
                rootPath: rootPath,
                name: branch.name,
                kind: .remote
            ) {
                branchActionMenu(for: reference)
            }
        }
    }

    func tagRow(
        _ tag: TagInfo,
        title: String,
        depth: Int,
        rootPath: String
    ) -> some View {
        let id = targetID(rootPath: rootPath, kind: .tag, value: tag.name)
        let isFavorite = dashboardReference(rootPath: rootPath, name: tag.name, kind: .tag)
            .map { favoriteReferenceIDs.contains($0.favoriteID) } == true
        return Button {
            selectBranchTarget(id: id, rootPath: rootPath, branch: tag.name)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "tag")
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                if isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                }
                Text(tag.shortId)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, CGFloat(depth) * 14)
        .background(
            selectedBranchTargetIDs.contains(id) ? Color.accentColor.opacity(0.22) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .help("Navigate Log to \(tag.name)")
        .contextMenu {
            if let reference = dashboardReference(
                rootPath: rootPath,
                name: tag.name,
                kind: .tag
            ) {
                BranchDashboardActionMenu(
                    selection: dashboardSelection(for: reference),
                    handlers: dashboardActionHandlers,
                    allowsWorktreeAction: true
                )
            }
        }
    }

    func remoteGroupRow(
        rootPath: String,
        name: String,
        branchCount: Int
    ) -> some View {
        let id = remoteGroupTargetID(rootPath: rootPath, name: name)
        return Button {
            selectRemoteGroupTarget(id: id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "network")
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                Text("\(branchCount)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            selectedRemoteGroupIDs.contains(id) ? Color.accentColor.opacity(0.22) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .help("Remote \(name)")
        .contextMenu {
            remoteGroupActionMenu(for: [
                BranchDashboardRemoteGroup(rootPath: rootPath, name: name)
            ])
        }
    }

    var dashboardActionHandlers: BranchDashboardActionHandlers {
        BranchDashboardActionHandlers(
            onFilterLog: { reference in
                onFilter([
                    LogRootBranchFilter(rootPath: reference.rootPath, branch: reference.name)
                ])
            },
            onCompareWithCurrent: { reference in
                onCompare(reference.rootPath, reference.name)
            },
            onShowDiffWithWorkingTree: { reference in
                onShowDiffWithWorkingTree(reference.rootPath, reference.name)
            },
            onDeleteTag: { reference in
                onDeleteTag(reference.rootPath, reference.name)
            },
            onPushTag: { reference in
                onPushTag(reference.rootPath, reference.name)
            },
            onPushTagToRemote: { reference, remote in
                onPushTagToRemote(reference.rootPath, reference.name, remote)
            },
            tagPushRemotes: { reference in
                snapshots.first(where: { $0.rootPath == reference.rootPath })?.remotes.map(\.name) ?? []
            },
            trackedReference: { reference in
                guard let snapshot = snapshots.first(where: { $0.rootPath == reference.rootPath }),
                      let sync = snapshot.syncStatuses.first(where: {
                          $0.branch == reference.name && $0.trackingExists
                      }),
                      let remoteBranch = snapshot.remoteBranches.first(where: {
                          $0.name == sync.upstream
                      }) else { return nil }
                let shortName = remoteBranch.name.split(separator: "/", maxSplits: 1)
                    .dropFirst()
                    .joined(separator: "/")
                return BranchDashboardReference(
                    rootPath: snapshot.rootPath,
                    name: remoteBranch.name,
                    kind: .remote,
                    remote: remoteBranch.remote,
                    localBranchName: reference.name,
                    isCurrent: false,
                    hasUpstream: false,
                    hasTracking: false,
                    hasRemote: true,
                    isProtected: GitProtectedBranchRules.matches(
                        shortName.isEmpty ? remoteBranch.name : shortName,
                        patterns: protectedBranchPatterns
                    )
                )
            },
            onCompareSelected: { selection in
                guard let pair = branchDashboardComparisonPair(selection: selection) else { return }
                onCompareSelected(pair.rootPath, pair.first, pair.second)
            },
            onCompareSelectedFiles: { selection in
                guard let pair = branchDashboardComparisonPair(selection: selection) else { return }
                onCompareSelectedFiles(pair.rootPath, pair.first, pair.second)
            },
            onUpdateSelected: onUpdateSelected,
            onDeleteSelected: onDeleteSelected,
            onCheckout: { reference in
                if reference.kind == .tag {
                    onCheckoutTag(reference.rootPath, reference.name)
                } else {
                    onCheckout(reference.rootPath, reference.name, reference.kind == .remote)
                }
            },
            onCheckoutAsNewBranch: { reference in
                onCheckoutAsNewBranch(reference.rootPath, reference.name, reference.kind == .remote)
            },
            onOpenWorktree: { reference in
                guard let path = reference.worktreePath else { return }
                onOpenWorktree(path)
            },
            onCreateWorktreeFromReference: { reference in
                let source = reference.kind == .head
                    ? snapshots.first(where: { $0.rootPath == reference.rootPath })?.headBranch ?? "HEAD"
                    : reference.name
                onCreateWorktreeFromReference(
                    reference.rootPath,
                    source,
                    reference.kind == .tag
                )
            },
            onCheckoutAndUpdate: { reference in
                onCheckoutAndUpdate(reference.rootPath, reference.name, false)
            },
            onCheckoutWithRebase: { reference in
                onCheckoutWithRebase(reference.rootPath, reference.name, reference.kind == .remote)
            },
            onUpdate: { reference in
                onUpdate(reference.rootPath, reference.name)
            },
            onMerge: { reference in
                onMerge(reference.rootPath, reference.name)
            },
            onRebase: { reference in
                onRebase(reference.rootPath, reference.name)
            },
            onPush: { reference in
                onPush(reference.rootPath, reference.name)
            },
            onFetch: { reference in
                onFetch(reference.rootPath, reference.name)
            },
            onPull: { reference, rebase in
                guard let localBranchName = reference.localBranchName else { return }
                onPullBranch(reference.rootPath, localBranchName, rebase)
            },
            onSetUpstream: { reference in
                onSetUpstream(reference.rootPath, reference.name)
            },
            onUnsetUpstream: { reference in
                onUnsetUpstream(reference.rootPath, reference.name)
            },
            onRename: { reference in
                onRename(reference.rootPath, reference.name)
            },
            onDelete: { reference in
                onDelete(reference.rootPath, reference.name)
            },
            onDeleteRemote: { reference in
                onDeleteRemote(reference.rootPath, reference.name)
            }
        )
    }

    @ViewBuilder
    func branchActionMenu(for reference: BranchDashboardReference) -> some View {
        BranchDashboardActionMenu(
            selection: dashboardSelection(for: reference),
            handlers: dashboardActionHandlers,
            allowsWorktreeAction: true
        )
    }

    @ViewBuilder
    func remoteGroupActionMenu(for selection: [BranchDashboardRemoteGroup]) -> some View {
        let availability = BranchDashboardRemoteGroupActionAvailability.resolve(selection: selection)
        if availability.contains(.editRemote), let group = selection.first {
            Button("Edit Remote…") {
                onEditRemote(group.rootPath, group.name)
            }
        }
        if availability.contains(.removeRemote) {
            if availability.contains(.editRemote) {
                Divider()
            }
            Button(
                selection.count == 1 ? "Remove Remote…" : "Remove Selected Remotes…",
                role: .destructive
            ) {
                if selection.count == 1, let group = selection.first {
                    onRemoveRemote(group.rootPath, group.name)
                } else {
                    onRemoveRemoteSelected(selection)
                }
            }
        }
    }

    func directoryGroupRow(_ row: BranchDirectoryRow) -> some View {
        Button {
            if collapsedDirectoryGroups.contains(row.id) {
                collapsedDirectoryGroups.remove(row.id)
            } else {
                collapsedDirectoryGroups.insert(row.id)
            }
        } label: {
            Label(
                row.name,
                systemImage: collapsedDirectoryGroups.contains(row.id) ? "chevron.right" : "chevron.down"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, CGFloat(row.depth) * 14)
        }
        .buttonStyle(.plain)
    }

    func selectBranchTarget(id: String, rootPath: String, branch: String) {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        selectedBranchTargetID = id
        selectedRemoteGroupIDs = []
        let selection = branchTreeSelectionAfterClick(
            current: selectedBranchTargetIDs,
            anchorID: branchSelectionAnchorID,
            orderedIDs: visibleBranchSelectionIDs,
            id: id,
            command: flags.contains(.command),
            shift: flags.contains(.shift)
        )
        selectedBranchTargetIDs = selection.selection
        branchSelectionAnchorID = selection.anchorID
        performSelectionAction()
    }

    func selectRemoteGroupTarget(id: String) {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        selectedBranchTargetID = id
        selectedBranchTargetIDs = []
        branchSelectionAnchorID = nil
        if flags.contains(.command) {
            if selectedRemoteGroupIDs.contains(id) {
                selectedRemoteGroupIDs.remove(id)
            } else {
                selectedRemoteGroupIDs.insert(id)
            }
            return
        }
        selectedRemoteGroupIDs = [id]
    }

    func branchReferenceName(_ row: BranchDirectoryRow) -> String? {
        guard !row.isGroup, row.id.hasPrefix("branch:") else { return nil }
        return String(row.id.dropFirst("branch:".count))
    }
}


struct BranchDashboardActionHandlers {
    let onFilterLog: (BranchDashboardReference) -> Void
    let onCompareWithCurrent: (BranchDashboardReference) -> Void
    let onShowDiffWithWorkingTree: (BranchDashboardReference) -> Void
    let onDeleteTag: (BranchDashboardReference) -> Void
    let onPushTag: (BranchDashboardReference) -> Void
    let onPushTagToRemote: (BranchDashboardReference, String) -> Void
    let tagPushRemotes: (BranchDashboardReference) -> [String]
    let trackedReference: (BranchDashboardReference) -> BranchDashboardReference?
    let onCompareSelected: ([BranchDashboardReference]) -> Void
    let onCompareSelectedFiles: ([BranchDashboardReference]) -> Void
    let onUpdateSelected: ([BranchDashboardReference]) -> Void
    let onDeleteSelected: ([BranchDashboardReference]) -> Void
    let onCheckout: (BranchDashboardReference) -> Void
    let onCheckoutAsNewBranch: (BranchDashboardReference) -> Void
    let onOpenWorktree: (BranchDashboardReference) -> Void
    let onCreateWorktreeFromReference: (BranchDashboardReference) -> Void
    let onCheckoutAndUpdate: (BranchDashboardReference) -> Void
    let onCheckoutWithRebase: (BranchDashboardReference) -> Void
    let onUpdate: (BranchDashboardReference) -> Void
    let onMerge: (BranchDashboardReference) -> Void
    let onRebase: (BranchDashboardReference) -> Void
    let onPush: (BranchDashboardReference) -> Void
    let onFetch: (BranchDashboardReference) -> Void
    let onPull: (BranchDashboardReference, Bool) -> Void
    let onSetUpstream: (BranchDashboardReference) -> Void
    let onUnsetUpstream: (BranchDashboardReference) -> Void
    let onRename: (BranchDashboardReference) -> Void
    let onDelete: (BranchDashboardReference) -> Void
    let onDeleteRemote: (BranchDashboardReference) -> Void
}


struct BranchDashboardActionMenu: View {
    let selection: [BranchDashboardReference]
    let handlers: BranchDashboardActionHandlers
    var allowsWorktreeAction = true

    var body: some View {
        let availability = BranchDashboardActionAvailability.resolve(selection: selection)
        let reference = selection.first

        Group {
            if let reference, availability.contains(.filterLog) {
                Button("Filter Log Here") {
                    handlers.onFilterLog(reference)
                }
            }
            if let reference, availability.contains(.compareWithCurrent) {
                Button("Compare with Current…") {
                    handlers.onCompareWithCurrent(reference)
                }
            }
            if let reference, availability.contains(.showDiffWithWorkingTree) {
                Button("Show Diff with Working Tree") {
                    handlers.onShowDiffWithWorkingTree(reference)
                }
            }
            if let reference,
               reference.kind == .local,
               reference.hasTracking,
               let tracked = handlers.trackedReference(reference) {
                Divider()
                Menu("Tracked Branch ((tracked.name))") {
                    AnyView(
                        BranchDashboardActionMenu(
                            selection: [tracked],
                            handlers: handlers,
                            allowsWorktreeAction: allowsWorktreeAction
                        )
                    )
                }
            }
            if let reference, availability.contains(.deleteTag) || availability.contains(.pushTag) {
                Divider()
                if availability.contains(.pushTag) {
                    let pushRemotes = handlers.tagPushRemotes(reference)
                    if pushRemotes.count > 1 {
                        Menu("Push Tag…") {
                            ForEach(pushRemotes, id: \.self) { remote in
                                Button(remote) {
                                    handlers.onPushTagToRemote(reference, remote)
                                }
                            }
                        }
                    } else {
                        Button("Push Tag…") {
                            handlers.onPushTag(reference)
                        }
                    }
                }
                if availability.contains(.deleteTag) {
                    Button("Delete Tag…", role: .destructive) {
                        handlers.onDeleteTag(reference)
                    }
                }
            }
            if availability.contains(.compareSelected), selection.count == 2 {
                Button("Compare Branches") {
                    handlers.onCompareSelected(selection)
                }
                .disabled(!availability.isEnabled(.compareSelected))
            }
            if availability.contains(.compareSelectedFiles), selection.count == 2 {
                Button("Show Files Diff") {
                    handlers.onCompareSelectedFiles(selection)
                }
                .disabled(!availability.isEnabled(.compareSelectedFiles))
            }

            if availability.contains(.updateSelected) {
                Button("Update Selected Branches") {
                    handlers.onUpdateSelected(selection)
                }
                .disabled(!availability.isEnabled(.updateSelected))
                .help(
                    availability.disabledDescription(for: .updateSelected)
                        ?? "Update Selected Branches"
                )
            }
            if availability.contains(.deleteSelected) {
                Button("Delete Selected Branches…", role: .destructive) {
                    handlers.onDeleteSelected(selection)
                }
                .disabled(!availability.isEnabled(.deleteSelected))
            }

            if availability.contains(.checkout)
                || availability.contains(.checkoutAsNewBranch)
                || (allowsWorktreeAction && availability.contains(.openWorktree))
                || availability.contains(.checkoutWithUpdate)
                || availability.contains(.checkoutWithRebase)
                || availability.contains(.update)
                || availability.contains(.merge)
                || availability.contains(.rebase)
                || (allowsWorktreeAction && availability.contains(.createWorktree))
                || availability.contains(.push)
                || availability.contains(.fetch)
                || availability.contains(.pull)
                || availability.contains(.pullWithRebase) {
                Divider()
            }
            if let reference, availability.contains(.checkout) {
                Button(reference.kind == .remote ? "Checkout as Local Branch" : "Checkout") {
                    handlers.onCheckout(reference)
                }
            }
            if let reference, availability.contains(.checkoutAsNewBranch) {
                Button(reference.kind == .head ? "New Branch from HEAD…" : "Checkout as New Branch…") {
                    handlers.onCheckoutAsNewBranch(reference)
                }
                .disabled(!availability.isEnabled(.checkoutAsNewBranch))
            }
            if let reference,
               allowsWorktreeAction,
               availability.contains(.openWorktree),
               reference.worktreePath != nil {
                Button("Open Worktree…") {
                    handlers.onOpenWorktree(reference)
                }
            }
            if let reference, availability.contains(.checkoutWithUpdate) {
                Button("Checkout and Update") {
                    handlers.onCheckoutAndUpdate(reference)
                }
                .disabled(!availability.isEnabled(.checkoutWithUpdate))
                .help(
                    availability.disabledDescription(for: .checkoutWithUpdate)
                        ?? "Checkout and Update"
                )
            }
            if let reference, availability.contains(.checkoutWithRebase) {
                Button("Checkout with Rebase") {
                    handlers.onCheckoutWithRebase(reference)
                }
                .disabled(!availability.isEnabled(.checkoutWithRebase))
            }
            if let reference, availability.contains(.update) {
                Button("Update") {
                    handlers.onUpdate(reference)
                }
                .disabled(!availability.isEnabled(.update))
                .help(
                    availability.disabledDescription(for: .update)
                        ?? "Update Branch"
                )
            }
            if let reference, availability.contains(.merge) {
                Button("Merge into Current…") {
                    handlers.onMerge(reference)
                }
            }
            if let reference, availability.contains(.rebase) {
                Button("Rebase Current onto…") {
                    handlers.onRebase(reference)
                }
            }
            if let reference,
               allowsWorktreeAction,
               availability.contains(.createWorktree) {
                Button(
                    reference.kind == .tag
                        ? "New Working Tree from Tag…"
                        : reference.kind == .head
                            ? "New Working Tree from HEAD…"
                            : "New Working Tree from Branch…"
                ) {
                    handlers.onCreateWorktreeFromReference(reference)
                }
                .disabled(!availability.isEnabled(.createWorktree))
            }
            if let reference, availability.contains(.push) {
                Button("Push…") {
                    handlers.onPush(reference)
                }
            }
            if let reference, availability.contains(.fetch) {
                Button("Fetch") {
                    handlers.onFetch(reference)
                }
            }
            if let reference, availability.contains(.pull), let localBranchName = reference.localBranchName {
                Button("Pull Local Branch (\(localBranchName))") {
                    handlers.onPull(reference, false)
                }
            }
            if let reference,
               availability.contains(.pullWithRebase),
               let localBranchName = reference.localBranchName {
                Button("Pull Local Branch (\(localBranchName)) with Rebase") {
                    handlers.onPull(reference, true)
                }
            }

            if let reference,
               availability.contains(.setUpstream) || availability.contains(.unsetUpstream) {
                Divider()
                if availability.contains(.setUpstream) {
                    Button("Set Upstream…") {
                        handlers.onSetUpstream(reference)
                    }
                }
                if availability.contains(.unsetUpstream) {
                    Button("Unset Upstream") {
                        handlers.onUnsetUpstream(reference)
                    }
                }
            }

            if let reference,
               availability.contains(.rename)
                || availability.contains(.deleteLocal)
                || availability.contains(.deleteRemote) {
                Divider()
                if availability.contains(.rename) {
                    Button("Rename Branch…") {
                        handlers.onRename(reference)
                    }
                }
                if availability.contains(.deleteLocal) {
                    Button("Delete Branch…", role: .destructive) {
                        handlers.onDelete(reference)
                    }
                }
                if availability.contains(.deleteRemote) {
                    Button("Delete Remote Branch…", role: .destructive) {
                        handlers.onDeleteRemote(reference)
                    }
                }
            }
        }
    }
}


struct LogBranchesPanel: View {
    let projectPath: String?
    let branches: [BranchInfo]
    let remoteBranches: [RemoteBranchInfo]
    let remotes: [RemoteInfo]
    let tags: [TagInfo]
    let hasHeadCommit: Bool
    let syncStatuses: [SyncStatus]
    let protectedBranchPatterns: [String]
    @Binding var groupByDirectory: Bool
    @Binding var selectionActionRaw: String
    @Binding var showOnlyMy: Bool
    let myBranchIDs: Set<String>
    let isLoadingMyBranches: Bool
    let onShowOnlyMyChanged: (Bool) -> Void
    let onNavigate: (String) -> Void
    let onFilter: ([LogRootBranchFilter]) -> Void
    let onCompare: (String) -> Void
    let onNewBranch: () -> Void
    let onCleanup: () -> Void
    let onFindMerged: () -> Void
    let onHide: () -> Void
    let onDelete: (String) -> Void
    let onCheckout: (String, Bool) -> Void
    let onCheckoutAsNewBranch: (String, Bool) -> Void
    let worktrees: [WorktreeInfo]
    let onOpenWorktree: (String) -> Void
    let onCreateWorktreeFromReference: (String, Bool) -> Void
    let onCheckoutTag: (String) -> Void
    let onCheckoutAndUpdate: (String, Bool) -> Void
    let onCheckoutWithRebase: (String, Bool) -> Void
    let onPullBranch: (String, Bool) -> Void
    let onUpdate: (String) -> Void
    let onMerge: (String) -> Void
    let onRebase: (String) -> Void
    let onShowDiffWithWorkingTree: (String) -> Void
    let onDeleteTag: (TagInfo) -> Void
    let onPushTag: (String) -> Void
    let onPushTagToRemote: (String, String) -> Void
    let onCompareSelected: ([BranchDashboardReference]) -> Void
    let onCompareSelectedFiles: ([BranchDashboardReference]) -> Void
    let onUpdateSelected: ([BranchDashboardReference]) -> Void
    let onDeleteSelected: ([BranchDashboardReference]) -> Void
    let onPush: (String) -> Void
    let onFetch: (String) -> Void
    let onFetchAll: () -> Void
    let onSetUpstream: (String) -> Void
    let onUnsetUpstream: (String) -> Void
    let onRename: (String) -> Void
    let onDeleteRemote: (RemoteBranchInfo) -> Void

    @State var query = ""
    @State var pendingDelete: String?
    @State var collapsedDirectoryGroups: Set<String> = []
    @State var selectedBranchTargetID: String?
    @State var selectedBranchTargetIDs: Set<String> = []
    @State var favoriteReferenceIDs: Set<String> = []
    @State var showTags = GitBranchesPopupSettings.defaultShowTags

    var dashboardReferences: [BranchDashboardReference] {
        let rootPath = projectPath ?? ""
        let headReference = BranchDashboardReference(
            rootPath: rootPath,
            name: "HEAD",
            kind: .head,
            remote: nil,
            isCurrent: true,
            hasUpstream: false,
            hasTracking: false,
            hasRemote: false,
            isProtected: false,
            hasHeadCommit: hasHeadCommit,
            worktreePath: branches.first(where: { $0.isCurrent }).flatMap { branch in
                linkedWorktreePathForBranch(
                    branch: branch.name,
                    worktrees: worktrees,
                    currentRootPath: rootPath
                )
            },
            headBranchName: branches.first(where: { $0.isCurrent })?.name
        )
        let localReferences = filteredBranches.map { branch in
            let sync = syncStatuses.first { $0.branch == branch.name }
            return BranchDashboardReference(
                rootPath: rootPath,
                name: branch.name,
                kind: .local,
                remote: nil,
                isCurrent: branch.isCurrent,
                hasUpstream: sync != nil,
                hasTracking: sync?.trackingExists == true,
                hasRemote: !remoteBranches.isEmpty || sync != nil,
                isProtected: GitProtectedBranchRules.matches(
                    branch.name,
                    patterns: protectedBranchPatterns
                ),
                worktreePath: linkedWorktreePathForBranch(
                    branch: branch.name,
                    worktrees: worktrees,
                    currentRootPath: rootPath
                )
            )
        }
        let remoteReferences = filteredRemoteBranches.map { branch in
            let localBranchName = syncStatuses.first { $0.upstream == branch.name }?.branch
            let shortName = branch.name.split(separator: "/", maxSplits: 1)
                .dropFirst()
                .joined(separator: "/")
            return BranchDashboardReference(
                rootPath: rootPath,
                name: branch.name,
                kind: .remote,
                remote: branch.remote,
                localBranchName: localBranchName,
                isCurrent: false,
                hasUpstream: false,
                hasTracking: false,
                hasRemote: true,
                isProtected: GitProtectedBranchRules.matches(
                    shortName.isEmpty ? branch.name : shortName,
                    patterns: protectedBranchPatterns
                )
            )
        }
        let tagReferences = filteredTags.map { tag in
            BranchDashboardReference(
                rootPath: rootPath,
                name: tag.name,
                kind: .tag,
                remote: nil,
                isCurrent: tag.isCurrent,
                hasUpstream: false,
                hasTracking: false,
                hasRemote: !remotes.isEmpty,
                isProtected: false
            )
        }
        return [headReference] + localReferences + remoteReferences + tagReferences
    }

    var selectedDashboardReferences: [BranchDashboardReference] {
        dashboardReferences.filter { reference in
            selectedBranchTargetIDs.contains(dashboardTargetID(for: reference))
        }
    }

    var selectedBranchReferencesForCurrentComparison: [BranchDashboardReference] {
        selectedDashboardReferences.filter { reference in
            (reference.kind == .local || reference.kind == .remote) && !reference.isCurrent
        }
    }

    func dashboardTargetID(for reference: BranchDashboardReference) -> String {
        let kind: String
        switch reference.kind {
        case .head: kind = "head"
        case .local: kind = "local"
        case .remote: kind = "remote"
        case .tag: kind = "tag"
        }
        return "log.\(kind):\(reference.name)"
    }

    func dashboardSelection(
        for reference: BranchDashboardReference
    ) -> [BranchDashboardReference] {
        let selected = selectedDashboardReferences
        return selected.contains(reference) ? selected : [reference]
    }

    var dashboardActionHandlers: BranchDashboardActionHandlers {
        BranchDashboardActionHandlers(
            onFilterLog: { reference in
                guard let rootPath = projectPath, !rootPath.isEmpty else { return }
                onFilter([
                    LogRootBranchFilter(rootPath: rootPath, branch: reference.name)
                ])
            },
            onCompareWithCurrent: { reference in
                onCompare(reference.name)
            },
            onShowDiffWithWorkingTree: { reference in
                onShowDiffWithWorkingTree(reference.name)
            },
            onDeleteTag: { reference in
                guard let tag = tags.first(where: { $0.name == reference.name }) else { return }
                onDeleteTag(tag)
            },
            onPushTag: { reference in
                guard let tag = tags.first(where: { $0.name == reference.name }) else { return }
                onPushTag(tag.name)
            },
            onPushTagToRemote: { reference, remote in
                onPushTagToRemote(reference.name, remote)
            },
            tagPushRemotes: { _ in remotes.map(\.name) },
            trackedReference: { reference in
                guard let sync = syncStatuses.first(where: {
                    $0.branch == reference.name && $0.trackingExists
                }),
                      let remoteBranch = remoteBranches.first(where: {
                          $0.name == sync.upstream
                      }) else { return nil }
                let shortName = remoteBranch.name.split(separator: "/", maxSplits: 1)
                    .dropFirst()
                    .joined(separator: "/")
                return BranchDashboardReference(
                    rootPath: reference.rootPath,
                    name: remoteBranch.name,
                    kind: .remote,
                    remote: remoteBranch.remote,
                    localBranchName: reference.name,
                    isCurrent: false,
                    hasUpstream: false,
                    hasTracking: false,
                    hasRemote: true,
                    isProtected: GitProtectedBranchRules.matches(
                        shortName.isEmpty ? remoteBranch.name : shortName,
                        patterns: protectedBranchPatterns
                    )
                )
            },
            onCompareSelected: onCompareSelected,
            onCompareSelectedFiles: onCompareSelectedFiles,
            onUpdateSelected: onUpdateSelected,
            onDeleteSelected: onDeleteSelected,
            onCheckout: { reference in
                if reference.kind == .tag {
                    onCheckoutTag(reference.name)
                } else {
                    onCheckout(reference.name, reference.kind == .remote)
                }
            },
            onCheckoutAsNewBranch: { reference in
                onCheckoutAsNewBranch(reference.name, reference.kind == .remote)
            },
            onOpenWorktree: { reference in
                guard let path = reference.worktreePath else { return }
                onOpenWorktree(path)
            },
            onCreateWorktreeFromReference: { reference in
                let source = reference.kind == .head
                    ? branches.first(where: { $0.isCurrent })?.name ?? "HEAD"
                    : reference.name
                onCreateWorktreeFromReference(source, reference.kind == .tag)
            },
            onCheckoutAndUpdate: { reference in
                onCheckoutAndUpdate(reference.name, false)
            },
            onCheckoutWithRebase: { reference in
                onCheckoutWithRebase(reference.name, reference.kind == .remote)
            },
            onUpdate: { reference in
                onUpdate(reference.name)
            },
            onMerge: { reference in
                onMerge(reference.name)
            },
            onRebase: { reference in
                onRebase(reference.name)
            },
            onPush: { reference in
                onPush(reference.name)
            },
            onFetch: { reference in
                onFetch(reference.name)
            },
            onPull: { reference, rebase in
                guard let localBranchName = reference.localBranchName else { return }
                onPullBranch(localBranchName, rebase)
            },
            onSetUpstream: { reference in
                onSetUpstream(reference.name)
            },
            onUnsetUpstream: { reference in
                onUnsetUpstream(reference.name)
            },
            onRename: { reference in
                onRename(reference.name)
            },
            onDelete: { reference in
                pendingDelete = reference.name
            },
            onDeleteRemote: { reference in
                guard let branch = remoteBranches.first(where: { $0.name == reference.name }) else { return }
                onDeleteRemote(branch)
            }
        )
    }

    var filteredBranches: [BranchInfo] {
        branches.filter { branch in
            branchSearchMatches(branch.name, query: query)
                && (!showOnlyMy || myBranchIDs.contains(BranchDashboardReference.referenceID(
                    rootPath: projectPath ?? "",
                    name: branch.name,
                    kind: .local
                )))
        }
    }

    var filteredRemoteBranches: [RemoteBranchInfo] {
        remoteBranches.filter { branch in
            branchSearchMatches(branch.name, query: query)
                && (!showOnlyMy || myBranchIDs.contains(BranchDashboardReference.referenceID(
                    rootPath: projectPath ?? "",
                    name: branch.name,
                    kind: .remote
                )))
        }
    }

    var filteredTags: [TagInfo] {
        guard showTags, !showOnlyMy else { return [] }
        return tags.filter { branchSearchMatches($0.name, query: query) }
    }

    var selectionAction: LogBranchSelectionAction {
        get { LogBranchSelectionAction(rawValue: selectionActionRaw) ?? .navigate }
        set { selectionActionRaw = newValue.rawValue }
    }

    var selectionActionBinding: Binding<LogBranchSelectionAction> {
        Binding(
            get: { LogBranchSelectionAction(rawValue: selectionActionRaw) ?? .navigate },
            set: {
                selectionActionRaw = $0.rawValue
                GitBranchesPopupSettings.save(
                    $0.rawValue,
                    GitBranchesPopupSettings.logSelectionActionKey,
                    for: projectPath
                )
            }
        )
    }

    var keyboardTargets: [BranchTreeTarget] {
        let head = BranchTreeTarget(
            id: "log.head:HEAD",
            value: "HEAD",
            title: "HEAD",
            kind: .head
        )
        let localNames = visibleBranchDirectoryRefNames(
            filteredBranches.map(\.name),
            grouped: groupByDirectory,
            scope: "log.local",
            collapsedGroups: collapsedDirectoryGroups
        )
        let remoteNames = visibleBranchDirectoryRefNames(
            filteredRemoteBranches.map(\.name),
            grouped: groupByDirectory,
            scope: "log.remote",
            collapsedGroups: collapsedDirectoryGroups
        )
        let tagNames = visibleBranchDirectoryRefNames(
            filteredTags.map(\.name),
            grouped: groupByDirectory,
            scope: "log.tags",
            collapsedGroups: collapsedDirectoryGroups
        )
        return [head] + localNames.map {
            BranchTreeTarget(id: "log.local:\($0)", value: $0, title: $0, kind: .local)
        } + remoteNames.map {
            BranchTreeTarget(id: "log.remote:\($0)", value: $0, title: $0, kind: .remote)
        } + tagNames.map {
            BranchTreeTarget(id: "log.tag:\($0)", value: $0, title: $0, kind: .tag)
        }
    }

    var localDirectoryRows: [BranchDirectoryRow] {
        branchDirectoryRows(
            for: filteredBranches.map(\.name),
            grouped: groupByDirectory,
            scope: "log.local"
        )
    }

    var remoteDirectoryRows: [BranchDirectoryRow] {
        branchDirectoryRows(
            for: filteredRemoteBranches.map(\.name),
            grouped: groupByDirectory,
            scope: "log.remote"
        )
    }

    var tagDirectoryRows: [BranchDirectoryRow] {
        branchDirectoryRows(
            for: filteredTags.map(\.name),
            grouped: groupByDirectory,
            scope: "log.tags"
        )
    }

    var pendingDeleteBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerView
            filterView
            optionsView
            dashboardActionToolbar

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    headRow
                    Text("LOCAL")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(visibleBranchDirectoryRows(
                        localDirectoryRows,
                        collapsedGroups: collapsedDirectoryGroups
                    )) { row in
                        if row.isGroup {
                            directoryGroupRow(row)
                        } else if let branchName = branchDirectoryRefNameForLog(row),
                                  let branch = filteredBranches.first(where: { $0.name == branchName }) {
                            branchRow(
                                branch,
                                title: row.name,
                                depth: row.depth,
                                selected: selectedBranchTargetIDs.contains("log.local:\(branch.name)")
                            )
                        }
                    }

                    Text("REMOTE")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    ForEach(visibleBranchDirectoryRows(
                        remoteDirectoryRows,
                        collapsedGroups: collapsedDirectoryGroups
                    )) { row in
                        if row.isGroup {
                            directoryGroupRow(row)
                        } else if let branchName = branchDirectoryRefNameForLog(row),
                                  let branch = filteredRemoteBranches.first(where: { $0.name == branchName }) {
                            remoteBranchRow(
                                branch,
                                title: row.name,
                                depth: row.depth,
                                selected: selectedBranchTargetIDs.contains("log.remote:\(branch.name)")
                            )
                        }
                    }
                    if !filteredTags.isEmpty {
                        Text("TAGS")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        ForEach(visibleBranchDirectoryRows(
                            tagDirectoryRows,
                            collapsedGroups: collapsedDirectoryGroups
                        )) { row in
                            if row.isGroup {
                                directoryGroupRow(row)
                            } else if let tagName = branchDirectoryRefNameForLog(row),
                                      let tag = filteredTags.first(where: { $0.name == tagName }) {
                                tagRow(
                                    tag,
                                    title: row.name,
                                    depth: row.depth,
                                    selected: selectedBranchTargetIDs.contains("log.tag:\(tag.name)")
                                )
                            }
                        }
                    }
                    if filteredBranches.isEmpty && filteredRemoteBranches.isEmpty && filteredTags.isEmpty {
                        Text("No matching branches")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(10)
        .frame(width: 230)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Colors.surface.opacity(0.55))
        .onAppear {
            groupByDirectory = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.groupByDirectoryKey,
                for: projectPath
            )
            favoriteReferenceIDs = GitBranchesPopupSettings.favorites(for: projectPath)
            showTags = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.showTagsKey,
                for: projectPath
            )
            selectedBranchTargetID = bestBranchTreeTargetID(
                query: query,
                targets: keyboardTargets,
                preserving: selectedBranchTargetID
            )
            if selectedBranchTargetIDs.isEmpty, let selectedBranchTargetID {
                selectedBranchTargetIDs = [selectedBranchTargetID]
            }
            collapsedDirectoryGroups = GitBranchesPopupSettings.collapsedDirectoryGroups(
                for: projectPath,
                setting: GitBranchesPopupSettings.logCollapsedDirectoryGroupsKey
            )
        }
        .onChange(of: collapsedDirectoryGroups) { _, value in
            GitBranchesPopupSettings.saveCollapsedDirectoryGroups(
                value,
                for: projectPath,
                setting: GitBranchesPopupSettings.logCollapsedDirectoryGroupsKey
            )
        }
        .onChange(of: groupByDirectory) { _, value in
            GitBranchesPopupSettings.save(
                value,
                GitBranchesPopupSettings.groupByDirectoryKey,
                for: projectPath
            )
            selectedBranchTargetID = bestBranchTreeTargetID(
                query: query,
                targets: keyboardTargets,
                preserving: selectedBranchTargetID
            )
            let visibleIDs = Set(keyboardTargets.map(\.id))
            selectedBranchTargetIDs = selectedBranchTargetIDs.intersection(visibleIDs)
        }
        .onChange(of: query) { _, _ in
            selectedBranchTargetID = bestBranchTreeTargetID(
                query: query,
                targets: keyboardTargets,
                preserving: selectedBranchTargetID
            )
            let visibleIDs = Set(keyboardTargets.map(\.id))
            selectedBranchTargetIDs = selectedBranchTargetIDs.intersection(visibleIDs)
            if selectedBranchTargetIDs.isEmpty, let selectedBranchTargetID {
                selectedBranchTargetIDs = [selectedBranchTargetID]
            }
        }
        .onChange(of: showOnlyMy) { _, value in
            onShowOnlyMyChanged(value)
            selectedBranchTargetID = bestBranchTreeTargetID(
                query: query,
                targets: keyboardTargets,
                preserving: selectedBranchTargetID
            )
            let visibleIDs = Set(keyboardTargets.map(\.id))
            selectedBranchTargetIDs = selectedBranchTargetIDs.intersection(visibleIDs)
            if selectedBranchTargetIDs.isEmpty, let selectedBranchTargetID {
                selectedBranchTargetIDs = [selectedBranchTargetID]
            }
        }
        .onChange(of: showTags) { _, value in
            GitBranchesPopupSettings.save(
                value,
                GitBranchesPopupSettings.showTagsKey,
                for: projectPath
            )
            selectedBranchTargetID = bestBranchTreeTargetID(
                query: query,
                targets: keyboardTargets,
                preserving: selectedBranchTargetID
            )
            let visibleIDs = Set(keyboardTargets.map(\.id))
            selectedBranchTargetIDs = selectedBranchTargetIDs.intersection(visibleIDs)
            if selectedBranchTargetIDs.isEmpty, let selectedBranchTargetID,
               visibleIDs.contains(selectedBranchTargetID) {
                selectedBranchTargetIDs = [selectedBranchTargetID]
            }
        }
        .alert("Delete branch?", isPresented: pendingDeleteBinding) {
            Button("Delete", role: .destructive) {
                if let pendingDelete { onDelete(pendingDelete) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Only the local branch reference will be removed. Unmerged commits remain in the repository until garbage collection.")
        }
    }

    var headerView: some View {
        HStack(spacing: 6) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .foregroundStyle(.blue)
            Text("Branches")
                .font(.headline)
            Spacer()
            Button { createNewBranchFromSelection() } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New branch")
            Button { onHide() } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .help("Hide branches")
        }
    }

    var headRow: some View {
        let id = "log.head:HEAD"
        return Button {
            selectBranchTarget(id: id, branch: "HEAD")
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "circle.hexagongrid.fill")
                    .foregroundStyle(.blue)
                Text("HEAD")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.semibold)
                if let current = branches.first(where: { $0.isCurrent })?.name {
                    Text("(\(current))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("(detached)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            selectedBranchTargetIDs.contains(id) ? Color.accentColor.opacity(0.22) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .help("Navigate Log to HEAD")
        .contextMenu {
            if let reference = dashboardReferences.first(where: {
                $0.kind == .head && $0.name == "HEAD"
            }) {
                BranchDashboardActionMenu(
                    selection: dashboardSelection(for: reference),
                    handlers: dashboardActionHandlers
                )
            }
        }
    }

    var filterView: some View {
        TextField("Filter branches", text: $query)
            .textFieldStyle(.roundedBorder)
            .onSubmit { activateSelectedBranch() }
            .onKeyPress(.downArrow, action: handleDownKeyPress)
            .onKeyPress(.upArrow, action: handleUpKeyPress)
    }

    var optionsView: some View {
        HStack(spacing: 6) {
            Toggle("Group by directory", isOn: $groupByDirectory)
                .toggleStyle(.checkbox)
                .font(.caption)
            Toggle("Show My Branches", isOn: $showOnlyMy)
                .toggleStyle(.checkbox)
                .font(.caption)
            Toggle("Show Tags", isOn: $showTags)
                .toggleStyle(.checkbox)
                .font(.caption)
            if isLoadingMyBranches {
                ProgressView()
                    .controlSize(.small)
            }
            Picker("On selection", selection: selectionActionBinding) {
                ForEach(LogBranchSelectionAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .help("Choose what selecting a branch does")
            Spacer()
            Menu("Actions…") {
                BranchDashboardActionMenu(
                    selection: selectedDashboardReferences,
                    handlers: dashboardActionHandlers
                )
            }
            .controlSize(.small)
            .disabled(selectedDashboardReferences.isEmpty)
            Button("Find Merged…") { onFindMerged() }
                .controlSize(.small)
            Button("Cleanup…") { onCleanup() }
                .controlSize(.small)
        }
    }

    var dashboardActionToolbar: some View {
        let selection = selectedDashboardReferences
        let availability = BranchDashboardActionAvailability.resolve(selection: selection)
        let compareTargets = selectedBranchReferencesForCurrentComparison
        let canToggleFavorite = !selection.isEmpty
            && selection.allSatisfy { $0.kind != .head }

        return HStack(spacing: 5) {
            Button {
                onFetchAll()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
            .help("Fetch All Remotes")

            Button {
                toggleFavorites(selection)
            } label: {
                Image(systemName: "star")
            }
            .buttonStyle(.borderless)
            .disabled(!canToggleFavorite)
            .help("Mark/Unmark As Favorite")

            Button {
                compareTargets.forEach { onCompare($0.name) }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.borderless)
            .disabled(compareTargets.isEmpty)
            .help("Compare with Current")

            Button {
                onUpdateSelected(selection)
            } label: {
                Image(systemName: "arrow.down.to.line.compact")
            }
            .buttonStyle(.borderless)
            .disabled(!availability.isEnabled(.updateSelected))
            .help("Update Selected Branches")

            Button(role: .destructive) {
                onDeleteSelected(selection)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!availability.isEnabled(.deleteSelected))
            .help("Delete Selected")

            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    func createNewBranchFromSelection() {
        guard selectedDashboardReferences.count == 1,
              let reference = selectedDashboardReferences.first,
              reference.kind != .head else {
            onNewBranch()
            return
        }
        onCheckoutAsNewBranch(reference.name, reference.kind == .remote)
    }

    @ViewBuilder
    func branchRow(
        _ branch: BranchInfo,
        title: String? = nil,
        depth: Int = 0,
        selected: Bool = false
    ) -> some View {
        let isFavorite = dashboardReferences.first {
            $0.kind == .local && $0.name == branch.name
        }.map { favoriteReferenceIDs.contains($0.favoriteID) } == true
        Button {
            selectBranchTarget(
                id: "log.local:\(branch.name)",
                branch: branch.name
            )
        } label: {
            HStack(spacing: 6) {
                Image(systemName: branch.isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch")
                    .foregroundStyle(branch.isCurrent ? .blue : .secondary)
                Text(title ?? branch.name)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(branch.isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                Spacer()
                if isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                }
                Text(branch.shortId)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, CGFloat(depth) * 14)
        .background(selected ? Color.accentColor.opacity(0.22) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .help(branch.isCurrent ? "Current branch" : "Navigate Log to \(branch.name)")
        .contextMenu {
            if let reference = dashboardReferences.first(where: {
                $0.kind == .local && $0.name == branch.name
            }) {
                BranchDashboardActionMenu(
                    selection: dashboardSelection(for: reference),
                    handlers: dashboardActionHandlers
                )
            }
        }
    }

    @ViewBuilder
    func remoteBranchRow(
        _ branch: RemoteBranchInfo,
        title: String? = nil,
        depth: Int = 0,
        selected: Bool = false
    ) -> some View {
        let isFavorite = dashboardReferences.first {
            $0.kind == .remote && $0.name == branch.name
        }.map { favoriteReferenceIDs.contains($0.favoriteID) } == true
        Button {
            selectBranchTarget(
                id: "log.remote:\(branch.name)",
                branch: branch.name
            )
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cloud")
                    .foregroundStyle(.secondary)
                Text(title ?? branch.name)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                if isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                }
                Text(branch.shortId)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, CGFloat(depth) * 14)
        .background(selected ? Color.accentColor.opacity(0.22) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .help("Navigate Log to \(branch.name)")
        .contextMenu {
            if let reference = dashboardReferences.first(where: {
                $0.kind == .remote && $0.name == branch.name
            }) {
                BranchDashboardActionMenu(
                    selection: dashboardSelection(for: reference),
                    handlers: dashboardActionHandlers
                )
            }
        }
    }

    @ViewBuilder
    func tagRow(
        _ tag: TagInfo,
        title: String? = nil,
        depth: Int = 0,
        selected: Bool = false
    ) -> some View {
        let isFavorite = dashboardReferences.first {
            $0.kind == .tag && $0.name == tag.name
        }.map { favoriteReferenceIDs.contains($0.favoriteID) } == true
        Button {
            selectBranchTarget(
                id: "log.tag:\(tag.name)",
                branch: tag.name
            )
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "tag")
                    .foregroundStyle(.secondary)
                Text(title ?? tag.name)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                if isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                }
                Text(tag.shortId)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, CGFloat(depth) * 14)
        .background(selected ? Color.accentColor.opacity(0.22) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .help("Navigate Log to \(tag.name)")
        .contextMenu {
            if let reference = dashboardReferences.first(where: {
                $0.kind == .tag && $0.name == tag.name
            }) {
                BranchDashboardActionMenu(
                    selection: dashboardSelection(for: reference),
                    handlers: dashboardActionHandlers
                )
            }
        }
    }

    @ViewBuilder
    func directoryGroupRow(_ row: BranchDirectoryRow) -> some View {
        Button {
            if collapsedDirectoryGroups.contains(row.id) {
                collapsedDirectoryGroups.remove(row.id)
            } else {
                collapsedDirectoryGroups.insert(row.id)
            }
        } label: {
            Label(
                row.name,
                systemImage: collapsedDirectoryGroups.contains(row.id) ? "chevron.right" : "chevron.down"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, CGFloat(row.depth) * 14)
        }
        .buttonStyle(.plain)
    }

    func branchDirectoryRefNameForLog(_ row: BranchDirectoryRow) -> String? {
        guard !row.isGroup, row.id.hasPrefix("branch:") else { return nil }
        return String(row.id.dropFirst("branch:".count))
    }

    func selectBranchTarget(id: String, branch: String) {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let anchor = selectedBranchTargetID
        selectedBranchTargetID = id
        if flags.contains(.shift),
           let anchor,
           let start = keyboardTargets.firstIndex(where: { $0.id == anchor }),
           let end = keyboardTargets.firstIndex(where: { $0.id == id }) {
            let range = start <= end ? start...end : end...start
            selectedBranchTargetIDs = Set(range.map { keyboardTargets[$0].id })
            performSelectionAction()
            return
        }
        if flags.contains(.command) {
            if selectedBranchTargetIDs.contains(id) {
                selectedBranchTargetIDs.remove(id)
            } else {
                selectedBranchTargetIDs.insert(id)
            }
            performSelectionAction()
            return
        }
        selectedBranchTargetIDs = [id]
        performSelectionAction()
    }

    func moveSelectedBranch(by offset: Int) {
        let nextID = movedBranchTreeSelection(
            currentID: selectedBranchTargetID,
            selectableIDs: keyboardTargets.map(\.id),
            offset: offset
        )
        selectedBranchTargetID = nextID
        if let nextID {
            selectedBranchTargetIDs = [nextID]
        }
    }

    func handleDownKeyPress() -> KeyPress.Result {
        moveSelectedBranch(by: 1)
        return .handled
    }

    func handleUpKeyPress() -> KeyPress.Result {
        moveSelectedBranch(by: -1)
        return .handled
    }

    func activateSelectedBranch() {
        guard let selectedBranchTargetID,
              keyboardTargets.contains(where: { $0.id == selectedBranchTargetID }) else { return }
        performSelectionAction()
    }

    func performSelectionAction() {
        guard let reference = selectedDashboardReferences.first else { return }
        switch selectionAction {
        case .navigate:
            onNavigate(reference.name)
        case .filter:
            let filters = logBranchFiltersForDashboardSelection(selectedDashboardReferences)
            guard !filters.isEmpty else { return }
            onFilter(filters)
        case .none:
            break
        }
    }

    func toggleFavorites(_ selection: [BranchDashboardReference]) {
        var updated = favoriteReferenceIDs
        for reference in selection {
            if updated.contains(reference.favoriteID) {
                updated.remove(reference.favoriteID)
            } else {
                updated.insert(reference.favoriteID)
            }
        }
        favoriteReferenceIDs = updated
        GitBranchesPopupSettings.saveFavorites(updated, for: projectPath)
    }
}

}
