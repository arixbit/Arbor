import SwiftUI
import AppKit
import UniformTypeIdentifiers

private struct MultiRootBranchRow: Identifiable {
    let id: String
    let name: String
    let isCurrent: Bool
    let sync: SyncStatus?
    let rootPath: String
    let isRemote: Bool
    let worktreePath: String?
}
/// IntelliJ Branches Popup 的多 root 展示：分支名称只在所属 Git root 内
/// 解释，避免不同仓库的同名分支被错误合并。
struct MultiRootBranchesPopover: View {
    @Environment(\.locale) private var locale
    var projectPath: String? = nil
    var protectedBranchPatterns: [String] = []
    let snapshots: [GitRootBranchSnapshot]
    var incomingBranches: Set<GitIncomingBranch> = []
    var operationContexts: [BranchPopupOperationContext] = []
    var onOperationAction: (String, BranchPopupOperationActionID) -> Void = { _, _ in }
    var onCommitChanges: () -> Void = {}
    var hasCommitChanges: Bool = false
    var onNewBranch: () -> Void = {}
    var onFindMerged: () -> Void = {}
    var onRemoteTags: () -> Void = {}
    let onCheckout: (String, String, Bool) -> Void
    var onCheckoutAsNewBranch: (String, String, Bool) -> Void = { _, _, _ in }
    let onCheckoutAndUpdate: (String, String, Bool, Bool) -> Void
    let onCheckoutWithRebase: (String, String, Bool) -> Void
    let onCheckoutRecent: (String, String) -> Void
    let onCheckoutTag: (String, String) -> Void
    let onDeleteTag: (String, String) -> Void
    var onDeleteTagAcrossRoots: (String) -> Void = { _ in }
    let onRenameTag: (String, String) -> Void
    let onPushTag: (String, String) -> Void
    var onPushTagToRemote: (String, String, String) -> Void = { _, _, _ in }
    var onShowDiffWithWorkingTree: (String, String) -> Void = { _, _ in }
    var onPushAllTags: (String, String) -> Void = { _, _ in }
    let onApplyStash: (String, String, Bool) -> Void
    let onPopStash: (String, String, Bool) -> Void
    let onDropStash: (String, String) -> Void
    let onStashBranch: (String, String) -> Void
    let onStashDiff: (String, String) -> Void
    let onStashClear: (String) -> Void
    let onUpdateBranch: (String, String) -> Void
    var onForcePushedUpdate: (String, String) -> Void = { _, _ in }
    var onForcePushedUpdateAcrossRoots: (String) -> Void = { _ in }
    let onPullBranch: (String, String, Bool) -> Void
    var onPullRemoteBranch: (String, String, Bool) -> Void = { _, _, _ in }
    let onDeleteRemote: (String, String) -> Void
    var onDeleteRemoteAcrossRoots: (String) -> Void = { _ in }
    let onMerge: (String, String) -> Void
    var onMergeAcrossRoots: (String) -> Void = { _ in }
    let onRebase: (String, String) -> Void
    let onCompare: (String, String) -> Void
    var onCompareSelected: ([BranchDashboardReference]) -> Void = { _ in }
    var onCompareSelectedFiles: ([BranchDashboardReference]) -> Void = { _ in }
    var onUpdateSelected: ([BranchDashboardReference]) -> Void = { _ in }
    var onDeleteSelected: ([BranchDashboardReference]) -> Void = { _ in }
    let onPushDialog: (String, String) -> Void
    var onEditRemote: (String, String) -> Void = { _, _ in }
    var onRemoveRemote: (String, String) -> Void = { _, _ in }
    var onRemoveRemoteSelected: ([BranchDashboardRemoteGroup]) -> Void = { _ in }
    var onConfigureRemotes: () -> Void = {}
    let onSetUpstream: (String, String) -> Void
    let onUnsetUpstream: (String, String) -> Void
    let onRenameBranch: (String, String) -> Void
    var onRenameBranchAcrossRoots: (String) -> Void = { _ in }
    var onDeleteBranchAcrossRoots: (String) -> Void = { _ in }
    let onDeleteBranch: (String, String) -> Void
    var onCheckoutReference: (String?) -> Void = { _ in }
    var onOpenWorktree: (String) -> Void = { _ in }
    var onCreateWorktreeFromReference: (String, String, Bool) -> Void = { _, _, _ in }
    var onProjectGitSettings: () -> Void = {}
    let onCancel: () -> Void

    @AppStorage(GitIncomingOutgoingInfoSettings.key)
    private var incomingOutgoingInfoEnabled = GitIncomingOutgoingInfoSettings.defaultValue
    @State private var query = ""
    @State private var repositoryFilter = ""
    @State private var repositoryScopeParentQuery: String?
    @State private var showRecentBranches = GitBranchesPopupSettings.defaultShowRecentBranches
    @State private var filterByAction = GitBranchesPopupSettings.defaultFilterByActionInPopup
    @State private var showTags = GitBranchesPopupSettings.defaultShowTags
    @State private var rootSyncChoice = GitRootSyncChoice.notDecided
    @State private var filterByRepository = GitBranchesPopupSettings.defaultFilterByRepository
    @State private var groupByRepository = GitBranchesPopupSettings.defaultGroupByRepository
    @State private var groupByDirectory = GitBranchesPopupSettings.defaultGroupByDirectory
    @State private var collapsedDirectoryGroups: Set<String> = []
    @State private var selectedBranchTargetID: String?
    @State private var selectedBranchTargetIDs: Set<String> = []
    @State private var popupSize = GitBranchesPopupSettings.defaultMultiRootPopupSize
    @State private var branchSelectionAnchorID: String?
    @State private var selectedRemoteGroupIDs: Set<String> = []
    @State private var favoriteReferenceIDs: Set<String> = []

    private var allowsSynchronizedBranchActions: Bool {
        rootSyncChoice.shouldExecuteOperationsOnAllRoots
    }

    private var remoteGroups: [BranchDashboardRemoteGroup] {
        snapshots.flatMap { snapshot in
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

    private var selectedRemoteGroups: [BranchDashboardRemoteGroup] {
        remoteGroups.filter { selectedRemoteGroupIDs.contains(remoteGroupTargetID(
            rootPath: $0.rootPath,
            name: $0.name
        )) }
    }

    private var selectableBranchReferences: [BranchDashboardReference] {
        snapshots.flatMap { snapshot in
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
                headBranchName: snapshot.headBranch
            )
            let local = snapshot.branches.map { branch in
                popupReference(
                    name: branch.name,
                    isCurrent: branch.isCurrent,
                    sync: snapshot.syncStatuses.first { $0.branch == branch.name },
                    rootPath: snapshot.rootPath,
                    isRemote: false,
                    hasHeadCommit: snapshot.headId != nil,
                    worktreePath: snapshot.worktrees.first {
                        $0.branch == branch.name && !$0.path.isEmpty
                    }?.path
                )
            }
            let remote = snapshot.remoteBranches.map { branch in
                popupReference(
                    name: branch.name,
                    isCurrent: false,
                    sync: snapshot.syncStatuses.first { $0.upstream == branch.name },
                    rootPath: snapshot.rootPath,
                    isRemote: true,
                    worktreePath: nil
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
                    hasRemote: !snapshot.remotes.isEmpty || !snapshot.remoteBranches.isEmpty,
                    isProtected: false
                )
            }
            return [head] + local + remote + tags
        }
    }

    private var selectedBranchReferences: [BranchDashboardReference] {
        selectableBranchReferences.filter { reference in
            selectedBranchTargetIDs.contains(branchTargetID(for: reference))
        }
    }

    private var selectedBranchActionsEnabled: Bool {
        let selection = selectedBranchReferences
        return selection.count >= 2
            && !BranchDashboardActionAvailability.resolve(selection: selection).actions.isEmpty
    }

    private var canCreateNewBranch: Bool {
        !snapshots.isEmpty && snapshots.allSatisfy { $0.headId != nil }
    }

    private func popupSnapshot(_ snapshot: GitRootBranchSnapshot) -> GitRootBranchSnapshot {
        guard !showTags else { return snapshot }
        return GitRootBranchSnapshot(
            rootPath: snapshot.rootPath,
            displayName: snapshot.displayName,
            relativePath: snapshot.relativePath,
            headBranch: snapshot.headBranch,
            headId: snapshot.headId,
            branches: snapshot.branches,
            remoteBranches: snapshot.remoteBranches,
            remotes: snapshot.remotes,
            syncStatuses: snapshot.syncStatuses,
            recentBranches: snapshot.recentBranches,
            tags: [],
            stashes: snapshot.stashes,
            shelves: snapshot.shelves,
            worktrees: snapshot.worktrees
        )
    }

    private var filteredSnapshots: [GitRootBranchSnapshot] {
        let selectedSnapshots = snapshots.filter {
            !filterByRepository || repositoryFilter.isEmpty || $0.rootPath == repositoryFilter
        }.map(popupSnapshot)
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return selectedSnapshots }
        return selectedSnapshots.compactMap { snapshot in
            let repositoryMatches = filterByRepository
                && branchPopupRepositorySearchMatches(
                    displayName: snapshot.displayName,
                    relativePath: snapshot.relativePath,
                    query: query
                )
            let local = snapshot.branches.filter { branchSearchMatches($0.name, query: query) }
            let remote = snapshot.remoteBranches.filter { branchSearchMatches($0.name, query: query) }
            let remotes = snapshot.remotes.filter { branchSearchMatches($0.name, query: query) }
            let recent = snapshot.recentBranches.filter { branchSearchMatches($0, query: query) }
            let tags = snapshot.tags.filter { branchSearchMatches($0.name, query: query) }
            let stashes = snapshot.stashes.filter {
                branchSearchMatches($0.message, query: query)
                    || branchSearchMatches($0.shortId, query: query)
            }
            let shelves = snapshot.shelves.filter {
                branchSearchMatches($0.name, query: query)
                    || branchSearchMatches($0.shortId, query: query)
            }
            let headMatches = branchSearchMatches("HEAD", query: query)
                || snapshot.headBranch.map { branchSearchMatches($0, query: query) } == true
            let visibleRecent = showRecentBranches ? recent : []
            guard repositoryMatches || headMatches || !local.isEmpty || !remote.isEmpty || !remotes.isEmpty || !visibleRecent.isEmpty
                    || !tags.isEmpty || !stashes.isEmpty || !shelves.isEmpty else {
                return nil
            }
            if repositoryMatches {
                return popupSnapshot(snapshot)
            }
            return GitRootBranchSnapshot(
                rootPath: snapshot.rootPath,
                displayName: snapshot.displayName,
                relativePath: snapshot.relativePath,
                headBranch: snapshot.headBranch,
                headId: snapshot.headId,
                branches: local,
                remoteBranches: remote,
                remotes: remotes.isEmpty ? snapshot.remotes : remotes,
                syncStatuses: snapshot.syncStatuses,
                recentBranches: showRecentBranches
                    ? recent
                    : [],
                tags: tags,
                stashes: stashes,
                shelves: shelves,
                worktrees: snapshot.worktrees
            )
        }
    }

    private var filteredRepositoryTargets: [BranchTreeTarget] {
        guard filterByRepository,
              repositoryFilter.isEmpty,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        return snapshots
            .filter {
                branchPopupRepositorySearchMatches(
                    displayName: $0.displayName,
                    relativePath: $0.relativePath,
                    query: query
                )
            }
            .sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
            .map { snapshot in
                let path = snapshot.relativePath.isEmpty ? snapshot.rootPath : snapshot.relativePath
                return BranchTreeTarget(
                    id: "multi.repository:\(snapshot.rootPath)",
                    value: "\(snapshot.displayName) \(path)",
                    title: snapshot.displayName,
                    kind: .repository,
                    rootPath: snapshot.rootPath
                )
            }
    }

    private var filteredActionTargets: [BranchTreeTarget] {
        branchPopupVisibleActions(
            query: query,
            filterByAction: filterByAction
        ).map { action in
            BranchTreeTarget(
                id: "multi.action:\(action.rawValue)",
                value: action.rawValue,
                title: action.title,
                kind: .action,
                isEnabled: isBranchPopupActionEnabled(
                    action,
                    hasHeadCommit: canCreateNewBranch,
                    hasCommitChanges: hasCommitChanges
                )
            )
        }
    }

    private var filteredOperationActionTargets: [BranchTreeTarget] {
        return operationContexts.flatMap { context in
            let repositoryLabel = context.relativePath.isEmpty
                ? context.displayName
                : "\(context.displayName) · \(context.relativePath)"
            return branchPopupOperationActions(for: context.kind, hasConflicts: context.hasConflicts)
                .filter {
                    !filterByAction
                        || branchSearchMatches("\($0.title) \(repositoryLabel)", query: query)
                }
                .map { action in
                    BranchTreeTarget(
                        id: "multi.operation:\(context.rootPath):\(action.rawValue)",
                        value: action.rawValue,
                        title: "\(action.title) — \(repositoryLabel)",
                        kind: .action,
                        rootPath: context.rootPath,
                        isEnabled: true
                    )
                }
        }
    }

    private var flatBranchRows: [MultiRootBranchRow] {
        filteredSnapshots.flatMap { snapshot in
            let localRows = snapshot.branches.map { branch in
                MultiRootBranchRow(
                    id: "\(snapshot.rootPath)::local::\(branch.name)",
                    name: branch.name,
                    isCurrent: branch.isCurrent,
                    sync: snapshot.syncStatuses.first { $0.branch == branch.name },
                    rootPath: snapshot.rootPath,
                    isRemote: false,
                    worktreePath: snapshot.worktrees.first { $0.branch == branch.name && !$0.path.isEmpty }?.path
                )
            }
            let remoteRows = snapshot.remoteBranches.map { branch in
                MultiRootBranchRow(
                    id: "\(snapshot.rootPath)::remote::\(branch.name)",
                    name: branch.name,
                    isCurrent: false,
                    sync: snapshot.syncStatuses.first { $0.upstream == branch.name },
                    rootPath: snapshot.rootPath,
                    isRemote: true,
                    worktreePath: nil
                )
            }
            return localRows + remoteRows
        }
    }

    private var keyboardTargets: [BranchTreeTarget] {
        let rootTargets = filteredSnapshots.flatMap { snapshot in
            branchTargets(for: snapshot, includeExtras: true)
        }
        let repositoryTargets = filteredRepositoryTargets
        guard groupByRepository || groupByDirectory else {
            let branchOnlyTargets = filteredSnapshots.flatMap { snapshot in
                branchTargets(for: snapshot, includeExtras: false)
            }
            let extraTargets = filteredSnapshots.flatMap { snapshot in
                branchTargets(for: snapshot, includeBranches: false, includeExtras: true)
            }
            let references = repositoryTargets + branchOnlyTargets + extraTargets
            let actionTargets = filterByAction
                ? (filteredOperationActionTargets + filteredActionTargets).filter(\.isEnabled)
                : []
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return references + actionTargets
            }
            return actionTargets + references
        }
        let actionTargets = filterByAction
            ? (filteredOperationActionTargets + filteredActionTargets).filter(\.isEnabled)
            : []
        let references = repositoryTargets + rootTargets
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return references + actionTargets
        }
        return actionTargets + references
    }

    private var visibleBranchSelectionIDs: [String] {
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

    private func branchTargets(
        for snapshot: GitRootBranchSnapshot,
        includeBranches: Bool = true,
        includeExtras: Bool
    ) -> [BranchTreeTarget] {
        let head = includeBranches
            ? [BranchTreeTarget(
                id: multiTargetID(rootPath: snapshot.rootPath, kind: .head, value: "HEAD"),
                value: "HEAD",
                title: "HEAD",
                kind: .head,
                rootPath: snapshot.rootPath
            )]
            : []
        let local = includeBranches
            ? visibleBranchDirectoryRefNames(
                snapshot.branches.map(\.name),
                grouped: groupByDirectory,
                scope: "\(snapshot.rootPath).local",
                collapsedGroups: collapsedDirectoryGroups
            ).map {
                BranchTreeTarget(
                    id: multiTargetID(rootPath: snapshot.rootPath, kind: .local, value: $0),
                    value: $0,
                    title: $0,
                    kind: .local,
                    rootPath: snapshot.rootPath
                )
            }
            : []
        let remote = includeBranches
            ? visibleBranchDirectoryRefNames(
                snapshot.remoteBranches.map(\.name),
                grouped: groupByDirectory,
                scope: "\(snapshot.rootPath).remote",
                collapsedGroups: collapsedDirectoryGroups
            ).map {
                BranchTreeTarget(
                    id: multiTargetID(rootPath: snapshot.rootPath, kind: .remote, value: $0),
                    value: $0,
                    title: $0,
                    kind: .remote,
                    rootPath: snapshot.rootPath
                )
            }
            : []
        let remoteGroups = includeBranches
            ? branchRemoteGroupNames(snapshot).map { name in
                BranchTreeTarget(
                    id: remoteGroupTargetID(rootPath: snapshot.rootPath, name: name),
                    value: name,
                    title: name,
                    kind: .remoteGroup,
                    rootPath: snapshot.rootPath
                )
            }
            : []
        guard includeExtras else { return head + local + remoteGroups + remote }
        let recent = showRecentBranches
            ? visibleBranchDirectoryRefNames(
                snapshot.recentBranches,
                grouped: groupByDirectory,
                scope: "\(snapshot.rootPath).recent",
                collapsedGroups: collapsedDirectoryGroups
            ).map {
                BranchTreeTarget(
                    id: multiTargetID(rootPath: snapshot.rootPath, kind: .recent, value: $0),
                    value: $0,
                    title: $0,
                    kind: .recent,
                    rootPath: snapshot.rootPath
                )
            }
            : []
        let tags = showTags ? visibleBranchDirectoryRefNames(
            snapshot.tags.map(\.name),
            grouped: groupByDirectory,
            scope: "\(snapshot.rootPath).tags",
            collapsedGroups: collapsedDirectoryGroups
        ).map {
            BranchTreeTarget(
                id: multiTargetID(rootPath: snapshot.rootPath, kind: .tag, value: $0),
                value: $0,
                title: $0,
                kind: .tag,
                rootPath: snapshot.rootPath
            )
        } : []
        return head + local + remoteGroups + remote + recent + tags
    }

    private func multiTargetID(
        rootPath: String,
        kind: BranchTreeTargetKind,
        value: String
    ) -> String {
        let kindValue: String
        switch kind {
        case .action: kindValue = "action"
        case .repository: kindValue = "repository"
        case .head: kindValue = "head"
        case .recent: kindValue = "recent"
        case .local: kindValue = "local"
        case .remote: kindValue = "remote"
        case .remoteGroup: kindValue = "remote-group"
        case .tag: kindValue = "tag"
        }
        return "multi:\(rootPath):\(kindValue):\(value)"
    }

    private func remoteGroupTargetID(rootPath: String, name: String) -> String {
        multiTargetID(rootPath: rootPath, kind: .remoteGroup, value: name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Branches", systemImage: "arrow.triangle.branch")
                    .font(.headline)
                if let snapshot = repositoryScopedSnapshot {
                    Text("in \(snapshot.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text("\(String(filteredSnapshots.count)) repositories")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 8) {
                filterField
                if let snapshot = repositoryScopedSnapshot {
                    Button {
                        leaveRepositoryScope()
                    } label: {
                        Label("All Repositories", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Return to all repositories")
                    Text(snapshot.relativePath.isEmpty ? snapshot.displayName : snapshot.relativePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Menu {
                    Toggle("Show Recent Branches", isOn: $showRecentBranches)
                    Toggle("Actions", isOn: $filterByAction)
                    Toggle("Show Tags", isOn: $showTags)
                    Toggle("Filter by Repository", isOn: $filterByRepository)
                    Toggle("Group by repository", isOn: $groupByRepository)
                    Toggle("Group by Directory", isOn: $groupByDirectory)
                    Divider()
                    Picker("Cross-root action scope", selection: $rootSyncChoice) {
                        ForEach(GitRootSyncChoice.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    Divider()
                    Button("Restore Default Size") {
                        popupSize = GitBranchesPopupSettings.defaultMultiRootPopupSize
                        GitBranchesPopupSettings.savePopupSize(popupSize, multiRoot: true, for: projectPath)
                    }
                    .disabled(popupSize == GitBranchesPopupSettings.defaultMultiRootPopupSize)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton)
                .help("Branches Popup Settings")
            }
            HStack {
                Text("Enter branch, tag, or commit")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu("Actions") {
                    Button("Find Merged…") {
                        onFindMerged()
                        onCancel()
                    }
                    .disabled(!isFindMergedBranchesActionEnabled(localBranchCounts: snapshots.map { $0.branches.count }))
                    Button("Remote Tags…") {
                        onRemoteTags()
                        onCancel()
                    }
                    if selectedBranchActionsEnabled {
                        Menu("Actions…") {
                            selectedBranchActionMenu(for: selectedBranchReferences)
                        }
                    }
                    if !selectedRemoteGroups.isEmpty {
                        Menu("Remote Actions…") {
                            remoteGroupActionMenu(for: selectedRemoteGroups)
                        }
                    }
                    Divider()
                    Button("Configure Remotes…", action: onConfigureRemotes)
                    Button(action: { onProjectGitSettings(); onCancel() }) {
                        Label("Project Git Settings…", systemImage: "slider.horizontal.3")
                    }
                }
                .controlSize(.small)
            }
            Divider()
            if filteredSnapshots.isEmpty && filteredActionTargets.isEmpty
                    && filteredOperationActionTargets.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if !filteredOperationActionTargets.isEmpty {
                            Text("ONGOING OPERATIONS")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                            ForEach(filteredOperationActionTargets) { target in
                                Button {
                                    selectedBranchTargetID = target.id
                                    if let action = BranchPopupOperationActionID(rawValue: target.value),
                                       let rootPath = target.rootPath {
                                        onOperationAction(rootPath, action)
                                        onCancel()
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(
                                            systemName: BranchPopupOperationActionID(rawValue: target.value)?.systemImage
                                                ?? "bolt"
                                        )
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                        .frame(width: 16)
                                        Text(target.title)
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                }
                                .buttonStyle(.plain)
                                .disabled(!target.isEnabled)
                                .background(
                                    selectedBranchTargetID == target.id
                                        ? Color.accentColor.opacity(0.22)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5)
                                )
                            }
                        }
                        if !filteredActionTargets.isEmpty {
                            Text("ACTIONS")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                            ForEach(filteredActionTargets) { target in
                                Button {
                                    selectedBranchTargetID = target.id
                                    if let action = BranchPopupActionID(rawValue: target.value) {
                                        activateAction(action)
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: BranchPopupActionID(rawValue: target.value)?.systemImage ?? "bolt")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 16)
                                        Text(localizedArborString(target.title, locale: locale))
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                }
                                .buttonStyle(.plain)
                                .disabled(!target.isEnabled)
                                .help(
                                    BranchPopupActionID(rawValue: target.value).flatMap {
                                        branchPopupActionDisabledDescription(
                                            $0,
                                            hasHeadCommit: canCreateNewBranch,
                                            hasCommitChanges: hasCommitChanges
                                        )
                                    } ?? ""
                                )
                                .background(
                                    selectedBranchTargetID == target.id
                                        ? Color.accentColor.opacity(0.22)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5)
                                )
                            }
                        }
                        if !filteredRepositoryTargets.isEmpty {
                            Text("REPOSITORIES")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                            ForEach(filteredRepositoryTargets) { target in
                                Button {
                                    selectRepositoryTarget(target)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "folder").font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 16)
                                        Text(target.title).lineLimit(1)
                                        if let rootPath = target.rootPath,
                                           let snapshot = snapshots.first(where: { $0.rootPath == rootPath }),
                                           !snapshot.relativePath.isEmpty {
                                            Text(snapshot.relativePath)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                }
                                .buttonStyle(.plain)
                                .background(
                                    selectedBranchTargetID == target.id
                                        ? Color.accentColor.opacity(0.22)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5)
                                )
                            }
                        }
                        if !filteredSnapshots.isEmpty {
                            if groupByRepository {
                                ForEach(filteredSnapshots, id: \.rootPath) { snapshot in
                                    rootSection(snapshot)
                                }
                            } else if groupByDirectory {
                                ForEach(filteredSnapshots, id: \.rootPath) { snapshot in
                                    rootSection(snapshot, compact: true)
                                }
                            } else {
                                ForEach(filteredSnapshots, id: \.rootPath) { snapshot in
                                    headRow(snapshot)
                                }
                                ForEach(flatBranchRows) { row in
                                    branchRow(
                                        row.name,
                                        isCurrent: row.isCurrent,
                                        sync: row.sync,
                                        rootPath: row.rootPath,
                                        isRemote: row.isRemote,
                                        worktreePath: row.worktreePath,
                                        selected: selectedBranchTargetIDs.contains(multiTargetID(
                                            rootPath: row.rootPath,
                                            kind: row.isRemote ? .remote : .local,
                                            value: row.name
                                        ))
                                    )
                                }
                                ForEach(filteredSnapshots, id: \.rootPath) { snapshot in
                                    extraSection(snapshot)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityIdentifier("multi-root-branch-reference-list")
            }
        }
        .padding(12)
        .frame(width: popupSize.width, height: popupSize.height)
        .overlay(alignment: .bottomTrailing) {
            BranchesPopupResizeHandle(
                size: $popupSize,
                minimum: CGSize(width: 560, height: 420),
                maximum: CGSize(width: 1400, height: 1200)
            ) { size in
                GitBranchesPopupSettings.savePopupSize(size, multiRoot: true, for: projectPath)
            }
        }
        .onExitCommand(perform: handleExitCommand)
        .onAppear {
            popupSize = GitBranchesPopupSettings.popupSize(for: projectPath, multiRoot: true)
            favoriteReferenceIDs = GitBranchesPopupSettings.favorites(for: projectPath)
            rootSyncChoice = GitRootSyncSettings.choice(for: projectPath)
            selectedBranchTargetID = bestBranchTreeTargetID(
                query: query,
                targets: keyboardTargets,
                preserving: selectedBranchTargetID
            )
            showRecentBranches = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.showRecentBranchesKey,
                for: projectPath
            )
            filterByAction = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.filterByActionInPopupKey,
                for: projectPath
            )
            showTags = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.showTagsKey,
                for: projectPath
            )
            filterByRepository = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.filterByRepositoryKey,
                for: projectPath
            )
            groupByRepository = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.groupByRepositoryKey,
                for: projectPath
            )
            groupByDirectory = GitBranchesPopupSettings.value(
                GitBranchesPopupSettings.groupByDirectoryKey,
                for: projectPath
            )
            collapsedDirectoryGroups = GitBranchesPopupSettings.collapsedDirectoryGroups(
                for: projectPath
            )
        }
        .onChange(of: showRecentBranches) { _, value in
            GitBranchesPopupSettings.save(
                value,
                GitBranchesPopupSettings.showRecentBranchesKey,
                for: projectPath
            )
        }
        .onChange(of: rootSyncChoice) { _, value in
            GitRootSyncSettings.save(value, for: projectPath)
        }
        .onChange(of: filterByAction) { _, value in
            GitBranchesPopupSettings.save(
                value,
                GitBranchesPopupSettings.filterByActionInPopupKey,
                for: projectPath
            )
            selectedBranchTargetID = bestBranchTreeTargetID(
                query: query,
                targets: keyboardTargets,
                preserving: selectedBranchTargetID
            )
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
        }
        .onChange(of: filterByRepository) { _, value in
            GitBranchesPopupSettings.save(
                value,
                GitBranchesPopupSettings.filterByRepositoryKey,
                for: projectPath
            )
            if !value {
                leaveRepositoryScope()
            }
            reconcileBranchSelection(with: filteredSnapshots)
        }
        .onChange(of: repositoryFilter) { _, _ in
            selectedBranchTargetID = bestBranchTreeTargetID(
                query: query,
                targets: keyboardTargets,
                preserving: selectedBranchTargetID
            )
            reconcileBranchSelection(with: filteredSnapshots)
        }
        .onChange(of: groupByRepository) { _, value in
            GitBranchesPopupSettings.save(
                value,
                GitBranchesPopupSettings.groupByRepositoryKey,
                for: projectPath
            )
        }
        .onChange(of: groupByDirectory) { _, value in
            GitBranchesPopupSettings.save(
                value,
                GitBranchesPopupSettings.groupByDirectoryKey,
                for: projectPath
            )
        }
        .onChange(of: collapsedDirectoryGroups) { _, value in
            GitBranchesPopupSettings.saveCollapsedDirectoryGroups(
                value,
                for: projectPath
            )
        }
        .onChange(of: query) { _, _ in
            selectedBranchTargetID = bestBranchTreeTargetID(
                query: query,
                targets: keyboardTargets,
                preserving: selectedBranchTargetID
            )
            let visibleRemoteGroupIDs = Set(filteredSnapshots.flatMap { snapshot in
                branchRemoteGroupNames(snapshot).map {
                    remoteGroupTargetID(rootPath: snapshot.rootPath, name: $0)
                }
            })
            selectedRemoteGroupIDs.formIntersection(visibleRemoteGroupIDs)
            reconcileBranchSelection(with: filteredSnapshots)
        }
        .onChange(of: snapshots) { _, newSnapshots in
            if filterByRepository,
               !repositoryFilter.isEmpty,
               !newSnapshots.contains(where: { $0.rootPath == repositoryFilter })
            {
                leaveRepositoryScope()
            }
            let validRemoteGroupIDs = Set(newSnapshots.flatMap { snapshot in
                branchRemoteGroupNames(snapshot).map {
                    remoteGroupTargetID(rootPath: snapshot.rootPath, name: $0)
                }
            })
            selectedRemoteGroupIDs.formIntersection(validRemoteGroupIDs)
            reconcileBranchSelection(with: filteredSnapshots)
        }
    }

    private var filterField: some View {
        TextField("Filter branches", text: $query)
            .accessibilityIdentifier("branches-popover-search")
            .textFieldStyle(.roundedBorder)
            .onSubmit { activateSelectedBranch() }
            .onKeyPress(.downArrow, action: handleDownKeyPress)
            .onKeyPress(.upArrow, action: handleUpKeyPress)
    }

    private func moveSelectedBranch(by offset: Int) {
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
        } else {
            selectedBranchTargetIDs = []
            branchSelectionAnchorID = nil
        }
    }

    private func handleDownKeyPress() -> KeyPress.Result {
        moveSelectedBranch(by: 1)
        return .handled
    }

    private func handleUpKeyPress() -> KeyPress.Result {
        moveSelectedBranch(by: -1)
        return .handled
    }

    private var repositoryScopedSnapshot: GitRootBranchSnapshot? {
        guard !repositoryFilter.isEmpty else { return nil }
        return snapshots.first(where: { $0.rootPath == repositoryFilter })
    }

    private func enterRepositoryScope(_ rootPath: String) {
        guard filterByRepository,
              snapshots.contains(where: { $0.rootPath == rootPath }) else { return }
        if repositoryFilter.isEmpty {
            repositoryScopeParentQuery = query
        }
        repositoryFilter = rootPath
        query = ""
        selectedBranchTargetIDs = []
        branchSelectionAnchorID = nil
    }

    private func leaveRepositoryScope() {
        guard !repositoryFilter.isEmpty else { return }
        repositoryFilter = ""
        query = repositoryScopeParentQuery ?? ""
        repositoryScopeParentQuery = nil
        selectedBranchTargetIDs = []
        branchSelectionAnchorID = nil
        selectedBranchTargetID = nil
    }

    private func handleExitCommand() {
        switch branchPopupExitDestination(repositoryFilter: repositoryFilter) {
        case .repositoryList:
            leaveRepositoryScope()
        case .dismiss:
            onCancel()
        }
    }

    private func activateSelectedBranch() {
        guard let selectedBranchTargetID,
              let target = keyboardTargets.first(where: { $0.id == selectedBranchTargetID }) else { return }
        if target.kind == .remoteGroup {
            selectRemoteGroupTarget(id: target.id)
            return
        }
        if target.kind == .action {
            if let action = BranchPopupOperationActionID(rawValue: target.value),
               let rootPath = target.rootPath {
                onOperationAction(rootPath, action)
                onCancel()
            } else if let action = BranchPopupActionID(rawValue: target.value) {
                activateAction(action)
            }
            return
        }
        guard let rootPath = target.rootPath else { return }
        switch target.kind {
        case .head:
            return
        case .action:
            return
        case .repository:
            selectRepositoryTarget(target)
        case .local:
            onCheckout(rootPath, target.value, false)
        case .remote:
            onCheckout(rootPath, target.value, true)
        case .remoteGroup:
            return
        case .recent:
            onCheckoutRecent(rootPath, target.value)
        case .tag:
            onCheckoutTag(rootPath, target.value)
        }
    }

    private func selectRepositoryTarget(_ target: BranchTreeTarget) {
        guard target.kind == .repository,
              let rootPath = target.rootPath else { return }
        selectedBranchTargetID = target.id
        enterRepositoryScope(rootPath)
    }

    private func activateAction(_ action: BranchPopupActionID) {
        switch action {
        case .commitChanges:
            onCommitChanges()
        case .newBranch:
            onNewBranch()
        case .checkoutReference:
            onCheckoutReference(
                filterByRepository && !repositoryFilter.isEmpty ? repositoryFilter : nil
            )
        }
    }

    @ViewBuilder
    private func rootSection(_ snapshot: GitRootBranchSnapshot, compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !compact {
                VStack(alignment: .leading, spacing: 1) {
                    Text(snapshot.displayName)
                        .font(.system(size: 12, weight: .semibold))
                    Text(snapshot.relativePath)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }
            headRow(snapshot)
            ForEach(visibleBranchDirectoryRows(
                branchDirectoryRows(
                    for: snapshot.branches.map(\.name),
                    grouped: groupByDirectory,
                    scope: "\(snapshot.rootPath).local"
                ),
                collapsedGroups: collapsedDirectoryGroups
            )) { row in
                if row.isGroup {
                    directoryGroupRow(row)
                } else if let refName = branchDirectoryRefName(row),
                          let branch = snapshot.branches.first(where: { $0.name == refName }) {
                    branchRow(
                        branch.name,
                        displayName: row.name,
                        isCurrent: branch.isCurrent,
                        sync: snapshot.syncStatuses.first { $0.branch == branch.name },
                        rootPath: snapshot.rootPath,
                        isRemote: false,
                        hasHeadCommit: snapshot.headId != nil,
                        worktreePath: snapshot.worktrees.first { $0.branch == branch.name && !$0.path.isEmpty }?.path,
                        depth: row.depth,
                        selected: selectedBranchTargetIDs.contains(multiTargetID(
                            rootPath: snapshot.rootPath,
                            kind: .local,
                            value: branch.name
                        ))
                    )
                }
            }
            remoteSection(snapshot)
            extraSection(snapshot)
        }
        .padding(.bottom, 4)
    }

    private func headRow(_ snapshot: GitRootBranchSnapshot) -> some View {
        let targetID = multiTargetID(
            rootPath: snapshot.rootPath,
            kind: .head,
            value: "HEAD"
        )
        let reference = BranchDashboardReference(
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
            headBranchName: snapshot.headBranch
        )
        let availability = BranchDashboardActionAvailability.resolve(selection: [reference])
        return HStack(spacing: 7) {
            Image(systemName: "arrow.uturn.backward.circle")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text("HEAD")
                .lineLimit(1)
            if snapshots.count > 1 {
                Text(snapshot.relativePath == "." ? snapshot.displayName : snapshot.relativePath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(snapshot.headBranch ?? "detached")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Menu {
                Button("New Branch from HEAD…") {
                    onCheckoutAsNewBranch(snapshot.rootPath, "HEAD", false)
                }
                .disabled(!availability.isEnabled(.checkoutAsNewBranch))
                if let headBranch = snapshot.headBranch,
                   availability.contains(.createWorktree) {
                    Button("New Working Tree from Current Branch…") {
                        onCreateWorktreeFromReference(snapshot.rootPath, headBranch, false)
                    }
                    .disabled(!availability.isEnabled(.createWorktree))
                }
                if availability.contains(.showDiffWithWorkingTree) {
                    Button("Show Diff with Working Tree") {
                        onShowDiffWithWorkingTree(snapshot.rootPath, "HEAD")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            selectBranchTarget(id: targetID)
        }
        .background(
            selectedBranchTargetIDs.contains(targetID)
                ? Color.accentColor.opacity(0.22)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
    }

    @ViewBuilder
    private func remoteSection(_ snapshot: GitRootBranchSnapshot) -> some View {
        HStack(spacing: 6) {
            Text("REMOTE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Configure…", action: onConfigureRemotes)
                .font(.caption)
                .controlSize(.small)
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)

        ForEach(branchRemoteGroupNames(snapshot), id: \.self) { remoteName in
            remoteGroupRow(
                rootPath: snapshot.rootPath,
                name: remoteName,
                branchCount: snapshot.remoteBranches.filter { $0.remote == remoteName }.count
            )
            ForEach(visibleBranchDirectoryRows(
                branchDirectoryRows(
                    for: snapshot.remoteBranches
                        .filter { $0.remote == remoteName }
                        .map(\.name),
                    grouped: groupByDirectory,
                    scope: "\(snapshot.rootPath).remote.\(remoteName)"
                ),
                collapsedGroups: collapsedDirectoryGroups
            )) { row in
                if row.isGroup {
                    directoryGroupRow(row)
                } else if let refName = branchDirectoryRefName(row),
                          let branch = snapshot.remoteBranches.first(where: { $0.name == refName }) {
                    branchRow(
                        branch.name,
                        displayName: row.name,
                        isCurrent: false,
                        sync: snapshot.syncStatuses.first { $0.upstream == branch.name },
                        rootPath: snapshot.rootPath,
                        isRemote: true,
                        worktreePath: nil,
                        depth: row.depth,
                        selected: selectedBranchTargetIDs.contains(multiTargetID(
                            rootPath: snapshot.rootPath,
                            kind: .remote,
                            value: branch.name
                        ))
                    )
                }
            }
        }
    }

    private func branchFavoriteID(rootPath: String, name: String, isRemote: Bool) -> String {
        BranchDashboardReference.referenceID(
            rootPath: rootPath,
            name: name,
            kind: isRemote ? .remote : .local
        )
    }

    private func branchTargetID(for reference: BranchDashboardReference) -> String {
        let kind: BranchTreeTargetKind
        switch reference.kind {
        case .head: kind = .head
        case .local: kind = .local
        case .remote: kind = .remote
        case .tag: kind = .tag
        }
        return multiTargetID(
            rootPath: reference.rootPath,
            kind: kind,
            value: reference.name
        )
    }

    private func branchTargetIDs(in snapshots: [GitRootBranchSnapshot]) -> Set<String> {
        Set(snapshots.flatMap { snapshot in
            let head = multiTargetID(rootPath: snapshot.rootPath, kind: .head, value: "HEAD")
            let local = snapshot.branches.map {
                multiTargetID(rootPath: snapshot.rootPath, kind: .local, value: $0.name)
            }
            let remote = snapshot.remoteBranches.map {
                multiTargetID(rootPath: snapshot.rootPath, kind: .remote, value: $0.name)
            }
            let tags = snapshot.tags.map {
                multiTargetID(rootPath: snapshot.rootPath, kind: .tag, value: $0.name)
            }
            return [head] + local + remote + tags
        })
    }

    private func reconcileBranchSelection(with snapshots: [GitRootBranchSnapshot]) {
        let validIDs = branchTargetIDs(in: snapshots)
        selectedBranchTargetIDs.formIntersection(validIDs)
        if selectedBranchTargetIDs.isEmpty,
           let selectedBranchTargetID,
           validIDs.contains(selectedBranchTargetID) {
            selectedBranchTargetIDs = [selectedBranchTargetID]
        }
        let visibleIDs = Set(visibleBranchSelectionIDs)
        if let branchSelectionAnchorID,
           !visibleIDs.contains(branchSelectionAnchorID) {
            self.branchSelectionAnchorID = nil
        }
        if self.branchSelectionAnchorID == nil,
           let selectedBranchTargetID,
           visibleIDs.contains(selectedBranchTargetID) {
            self.branchSelectionAnchorID = selectedBranchTargetID
        }
    }

    @ViewBuilder
    private func selectedBranchActionMenu(for selection: [BranchDashboardReference]) -> some View {
        let availability = BranchDashboardActionAvailability.resolve(selection: selection)
        if availability.contains(.compareSelected) {
            Button("Compare Branches…") {
                onCompareSelected(selection)
                onCancel()
            }
            .disabled(!availability.isEnabled(.compareSelected))
        }
        if availability.contains(.compareSelectedFiles) {
            Button("Compare Files…") {
                onCompareSelectedFiles(selection)
                onCancel()
            }
            .disabled(!availability.isEnabled(.compareSelectedFiles))
        }
        if availability.contains(.updateSelected) {
            Divider()
            Button("Update Selected Branches") {
                onUpdateSelected(selection)
                onCancel()
            }
            .disabled(!availability.isEnabled(.updateSelected))
            .help(availability.disabledDescription(for: .updateSelected) ?? "")
        }
        if availability.contains(.deleteSelected) {
            Divider()
            Button("Delete Selected", role: .destructive) {
                onDeleteSelected(selection)
                onCancel()
            }
            .disabled(!availability.isEnabled(.deleteSelected))
        }
    }

    private func favoriteTitle(rootPath: String, name: String, isRemote: Bool) -> String {
        favoriteReferenceIDs.contains(
            branchFavoriteID(rootPath: rootPath, name: name, isRemote: isRemote)
        ) ? "Unmark As Favorite" : "Mark As Favorite"
    }

    private func toggleFavorite(rootPath: String, name: String, isRemote: Bool) {
        let id = branchFavoriteID(rootPath: rootPath, name: name, isRemote: isRemote)
        if favoriteReferenceIDs.contains(id) {
            favoriteReferenceIDs.remove(id)
        } else {
            favoriteReferenceIDs.insert(id)
        }
        GitBranchesPopupSettings.saveFavorites(favoriteReferenceIDs, for: projectPath)
    }

    @ViewBuilder
    private func extraSection(_ snapshot: GitRootBranchSnapshot) -> some View {
        if showRecentBranches && !snapshot.recentBranches.isEmpty {
            Text("RECENT")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.top, 6)
            ForEach(visibleBranchDirectoryRows(
                branchDirectoryRows(
                    for: snapshot.recentBranches,
                    grouped: groupByDirectory,
                    scope: "\(snapshot.rootPath).recent"
                ),
                collapsedGroups: collapsedDirectoryGroups
            )) { row in
                if row.isGroup {
                    directoryGroupRow(row)
                    } else if let refName = branchDirectoryRefName(row) {
                        Button {
                            selectedRemoteGroupIDs = []
                            selectedBranchTargetID = multiTargetID(
                                rootPath: snapshot.rootPath,
                                kind: .recent,
                                value: refName
                            )
                            onCheckoutRecent(snapshot.rootPath, refName)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "clock")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(row.name)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.leading, CGFloat(row.depth) * 14)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    .background(
                        selectedBranchTargetID == multiTargetID(
                            rootPath: snapshot.rootPath,
                            kind: .recent,
                            value: refName
                        ) ? Color.accentColor.opacity(0.22) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                }
            }
        }
        if !snapshot.tags.isEmpty {
            HStack {
                Text("TAGS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                let tagRemotes = snapshot.remotes.map(\.name)
                if tagRemotes.count == 1 {
                    Button("Push All Tags") {
                        onPushAllTags(snapshot.rootPath, tagRemotes[0])
                    }
                    .font(.caption)
                    .controlSize(.small)
                } else if tagRemotes.count > 1 {
                    Menu("Push All Tags") {
                        ForEach(tagRemotes, id: \.self) { remote in
                            Button(remote) {
                                onPushAllTags(snapshot.rootPath, remote)
                            }
                        }
                    }
                    .font(.caption)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 6)
            ForEach(visibleBranchDirectoryRows(
                branchDirectoryRows(
                    for: snapshot.tags.map(\.name),
                    grouped: groupByDirectory,
                    scope: "\(snapshot.rootPath).tags"
                ),
                collapsedGroups: collapsedDirectoryGroups
            )) { row in
                if row.isGroup {
                    directoryGroupRow(row)
                } else if let refName = branchDirectoryRefName(row),
                          let tag = snapshot.tags.first(where: { $0.name == refName }) {
                    let targetID = multiTargetID(
                        rootPath: snapshot.rootPath,
                        kind: .tag,
                        value: tag.name
                    )
                    HStack(spacing: 6) {
                        Image(systemName: "tag")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(row.name)
                            .lineLimit(1)
                        Spacer()
                        Text(tag.shortId)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedRemoteGroupIDs = []
                        selectBranchTarget(id: targetID)
                    }
                    .disabled(tag.isCurrent)
                    .padding(.leading, CGFloat(row.depth) * 14)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        selectedBranchTargetIDs.contains(targetID)
                            ? Color.accentColor.opacity(0.22)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .contextMenu {
                        if !tag.isCurrent {
                            Button("Checkout") {
                                onCheckoutTag(snapshot.rootPath, tag.name)
                            }
                        }
                        Button("Show Diff with Working Tree") {
                            onShowDiffWithWorkingTree(snapshot.rootPath, tag.name)
                        }
                        if !tag.isCurrent {
                            Button("Merge into Current…") {
                                onMerge(snapshot.rootPath, tag.name)
                            }
                            Button("Delete") { onDeleteTag(snapshot.rootPath, tag.name) }
                            if snapshots.filter({ snapshot in
                                snapshot.tags.contains { $0.name == tag.name }
                            }).count > 1,
                            allowsSynchronizedBranchActions {
                                Button("Delete in Repositories…", role: .destructive) {
                                    onDeleteTagAcrossRoots(tag.name)
                                }
                            }
                        }
                        let tagRemotes = snapshot.remotes.map(\.name)
                        if tagRemotes.count > 1 {
                            Menu("Push to Remote") {
                                ForEach(tagRemotes, id: \.self) { remote in
                                    Button(remote) {
                                        onPushTagToRemote(snapshot.rootPath, tag.name, remote)
                                    }
                                }
                            }
                        } else if tagRemotes.count == 1 {
                            Button("Push to Remote") { onPushTag(snapshot.rootPath, tag.name) }
                        }
                    }
                }
            }
        }
        HStack {
            Text("STASHES")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if !snapshot.stashes.isEmpty {
                Button("Clear All") { onStashClear(snapshot.rootPath) }
                    .font(.caption)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 6)
        if snapshot.stashes.isEmpty {
            Text("No stashes")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        } else {
            ForEach(snapshot.stashes, id: \.id) { stash in
                rootStashRow(snapshot.rootPath, stash: stash)
            }
        }
    }

    private func rootStashRow(_ rootPath: String, stash: StashInfo) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full")
                .foregroundStyle(.orange)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(stash.message.isEmpty ? "WIP" : stash.message)
                    .lineLimit(1)
                Text(stash.shortId)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Menu {
                Button("Apply (Keep)") { onApplyStash(rootPath, stash.id, false) }
                Button("Apply + Restore Index (Keep)") { onApplyStash(rootPath, stash.id, true) }
                Button("Pop (Apply and Remove)") { onPopStash(rootPath, stash.id, false) }
                Button("Pop + Restore Index") { onPopStash(rootPath, stash.id, true) }
                Button("Create Branch from Stash…") { onStashBranch(rootPath, stash.id) }
                Button("View Diff") { onStashDiff(rootPath, stash.id) }
                Divider()
                Button("Drop", role: .destructive) { onDropStash(rootPath, stash.id) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }

    private func directoryGroupRow(_ row: BranchDirectoryRow) -> some View {
        BranchDirectoryGroupRow(
            row: row,
            collapsedGroups: $collapsedDirectoryGroups,
            style: .popup
        )
    }

    private func remoteGroupRow(
        rootPath: String,
        name: String,
        branchCount: Int
    ) -> some View {
        let id = remoteGroupTargetID(rootPath: rootPath, name: name)
        return Button {
            selectRemoteGroupTarget(id: id)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "network")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(name)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                Text("\(branchCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            selectedRemoteGroupIDs.contains(id) ? Color.accentColor.opacity(0.22) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .contextMenu {
            remoteGroupActionMenu(for: [
                BranchDashboardRemoteGroup(rootPath: rootPath, name: name)
            ])
        }
    }

    @ViewBuilder
    private func remoteGroupActionMenu(for selection: [BranchDashboardRemoteGroup]) -> some View {
        BranchDashboardRemoteGroupActionMenu(
            selection: selection,
            onEditRemote: onEditRemote,
            onRemoveRemote: onRemoveRemote,
            onRemoveRemoteSelected: onRemoveRemoteSelected
        )
    }

    private func popupReference(
        name: String,
        isCurrent: Bool,
        sync: SyncStatus?,
        rootPath: String,
        isRemote: Bool,
        hasHeadCommit: Bool = true,
        worktreePath: String?
    ) -> BranchDashboardReference {
        if isRemote {
            let shortName = name.split(separator: "/", maxSplits: 1)
                .dropFirst()
                .joined(separator: "/")
            return BranchDashboardReference(
                rootPath: rootPath,
                name: name,
                kind: .remote,
                remote: name.split(separator: "/", maxSplits: 1).first.map(String.init),
                localBranchName: sync?.branch,
                isCurrent: false,
                hasUpstream: false,
                hasTracking: false,
                hasRemote: true,
                isProtected: GitProtectedBranchRules.matches(
                    shortName.isEmpty ? name : shortName,
                    patterns: protectedBranchPatterns
                )
            )
        }

        return BranchDashboardReference(
            rootPath: rootPath,
            name: name,
            kind: .local,
            remote: nil,
            isCurrent: isCurrent,
            hasUpstream: sync != nil,
            hasTracking: sync?.trackingExists == true,
            hasRemote: snapshots.first(where: { $0.rootPath == rootPath }).map {
                !$0.remotes.isEmpty || !$0.remoteBranches.isEmpty
            } ?? false,
            isProtected: GitProtectedBranchRules.matches(
                name,
                patterns: protectedBranchPatterns
            ),
            hasHeadCommit: hasHeadCommit,
            worktreePath: worktreePath
        )
    }

    private func trackedRemoteBranch(rootPath: String, localName: String) -> RemoteBranchInfo? {
        guard let snapshot = snapshots.first(where: { $0.rootPath == rootPath }),
              let sync = snapshot.syncStatuses.first(where: {
                  $0.branch == localName && $0.trackingExists
              }) else { return nil }
        return snapshot.remoteBranches.first(where: { $0.name == sync.upstream })
    }

    @ViewBuilder
    private func trackedBranchMenu(rootPath: String, remote: RemoteBranchInfo) -> some View {
        let sync = snapshots.first(where: { $0.rootPath == rootPath })?.syncStatuses.first {
            $0.upstream == remote.name && $0.trackingExists
        }
        let availability = BranchDashboardActionAvailability.resolve(selection: [
            popupReference(
                name: remote.name,
                isCurrent: false,
                sync: sync,
                rootPath: rootPath,
                isRemote: true,
                worktreePath: nil
            )
        ])
        Menu("Tracked Branch: \(remote.name)") {
            if availability.contains(.compareWithCurrent) {
                Button("Compare with Current…") { onCompare(rootPath, remote.name) }
            }
            if availability.contains(.showDiffWithWorkingTree) {
                Button("Show Diff with Working Tree") {
                    onShowDiffWithWorkingTree(rootPath, remote.name)
                }
            }
            if availability.contains(.rebase) {
                Button("Rebase Current onto…") { onRebase(rootPath, remote.name) }
            }
            if availability.contains(.merge) {
                Button("Merge into Current…") { onMerge(rootPath, remote.name) }
            }
            Divider()
            if availability.contains(.pull) {
                Button("Pull into Current") {
                    onPullRemoteBranch(rootPath, remote.name, false)
                }
            }
            if availability.contains(.pullWithRebase) {
                Button("Pull into Current with Rebase") {
                    onPullRemoteBranch(rootPath, remote.name, true)
                }
            }
            Divider()
            if availability.contains(.checkout) {
                Button("Checkout as Local Branch") {
                    onCheckout(rootPath, remote.name, true)
                }
            }
            if availability.contains(.checkoutAsNewBranch) {
                Button("Checkout as New Branch…") {
                    onCheckoutAsNewBranch(rootPath, remote.name, true)
                }
            }
            if availability.contains(.checkoutWithRebase) {
                Button("Checkout with Rebase") {
                    onCheckoutWithRebase(rootPath, remote.name, true)
                }
            }
            if availability.contains(.deleteRemote) {
                Button("Delete Remote Branch", role: .destructive) {
                    onDeleteRemote(rootPath, remote.name)
                }
                .disabled(!availability.isEnabled(.deleteRemote))
            }
        }
    }

    private func branchRow(
        _ name: String,
        displayName: String? = nil,
        isCurrent: Bool,
        sync: SyncStatus?,
        rootPath: String,
        isRemote: Bool,
        hasHeadCommit: Bool = true,
        worktreePath: String? = nil,
        depth: Int = 0,
        selected: Bool = false
    ) -> some View {
        let reference = popupReference(
            name: name,
            isCurrent: isCurrent,
            sync: sync,
            rootPath: rootPath,
            isRemote: isRemote,
            hasHeadCommit: hasHeadCommit,
            worktreePath: worktreePath
        )
        let availability = BranchDashboardActionAvailability.resolve(selection: [reference])
        let incomingIdentity = isRemote ? autoFetchRemoteBranchIdentity(name) : nil
        let hasIncoming = isRemote
            ? incomingIdentity.map {
                hasUnfetchedIncomingRemoteBranch(
                    rootPath: rootPath,
                    remote: $0.remote,
                    branch: $0.branch,
                    in: incomingBranches
                )
            } ?? false
            : hasUnfetchedIncomingBranch(
                rootPath: rootPath,
                branch: name,
                in: incomingBranches
            )
        return HStack(spacing: 7) {
            Image(systemName: isRemote ? "cloud" : (isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch"))
                .foregroundStyle(isCurrent ? .green : .secondary)
                .frame(width: 16)
            Text(displayName ?? name)
                .lineLimit(1)
                .truncationMode(.middle)
            if incomingOutgoingInfoEnabled,
               let sync, sync.trackingExists,
               sync.ahead > 0 || sync.behind > 0 || hasIncoming {
                HStack(spacing: 2) {
                    if sync.ahead > 0 { Text("↑\(sync.ahead)") }
                    if sync.behind > 0 { Text("↓\(sync.behind)") }
                    if hasIncoming { Text("↓?") }
                }
                .font(.caption2.monospaced())
                .foregroundStyle(sync.behind > 0 ? .blue : .green)
            } else if incomingOutgoingInfoEnabled, hasIncoming {
                Label("?", systemImage: "arrow.down")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.blue)
                    .help("Remote has incoming commits not fetched locally")
            }
            Spacer()
            if favoriteReferenceIDs.contains(
                branchFavoriteID(rootPath: rootPath, name: name, isRemote: isRemote)
            ) {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
            }
            if isCurrent {
                Menu {
                    Button(localizedArborString(favoriteTitle(rootPath: rootPath, name: name, isRemote: isRemote), locale: locale)) {
                        toggleFavorite(rootPath: rootPath, name: name, isRemote: isRemote)
                    }
                    Divider()
                    if availability.contains(.showDiffWithWorkingTree) {
                        Button("Show Diff with Working Tree") {
                            onShowDiffWithWorkingTree(rootPath, name)
                        }
                    }
                    if availability.contains(.createWorktree) {
                        Button("New Working Tree from Branch…") {
                            onCreateWorktreeFromReference(rootPath, name, false)
                        }
                        .disabled(!availability.isEnabled(.createWorktree))
                    }
                    if availability.contains(.checkoutAsNewBranch) {
                        Button("Checkout as New Branch…") {
                            onCheckoutAsNewBranch(rootPath, name, false)
                        }
                    }
                    if availability.contains(.update) {
                        Button("Update") { onUpdateBranch(rootPath, name) }
                            .disabled(!availability.isEnabled(.update))
                            .help(availability.disabledDescription(for: .update) ?? "")
                    }
                    if let sync, sync.trackingExists, sync.ahead > 0, sync.behind > 0 {
                        Button("Update Force-Pushed Branch…") {
                            onForcePushedUpdate(rootPath, name)
                        }
                        if snapshots.filter({ snapshot in
                            snapshot.branches.contains { branch in
                                branch.name == name && branch.isCurrent
                            } && snapshot.syncStatuses.contains { status in
                                status.branch == name
                                    && status.trackingExists
                                    && status.ahead > 0
                                    && status.behind > 0
                            }
                        }).count > 1,
                           allowsSynchronizedBranchActions {
                            Button("Update Force-Pushed Branch in Repositories…") {
                                onForcePushedUpdateAcrossRoots(name)
                            }
                        }
                    }
                    if availability.contains(.push) {
                        Divider()
                        Button("Push…") { onPushDialog(rootPath, name) }
                    }
                    if let trackedRemote = trackedRemoteBranch(rootPath: rootPath, localName: name) {
                        Divider()
                        trackedBranchMenu(rootPath: rootPath, remote: trackedRemote)
                    }
                    if availability.contains(.rename) {
                        Divider()
                        Button("Rename…") { onRenameBranch(rootPath, name) }
                    }
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("branch-row-menu")
                .accessibilityLabel(Text("Branch Actions"))
            } else {
                Menu {
                    Button(localizedArborString(favoriteTitle(rootPath: rootPath, name: name, isRemote: isRemote), locale: locale)) {
                        toggleFavorite(rootPath: rootPath, name: name, isRemote: isRemote)
                    }
                    Divider()
                    if isRemote {
                        if availability.contains(.pull) {
                            Button("Pull into Current") {
                                onPullRemoteBranch(rootPath, name, false)
                            }
                        }
                        if availability.contains(.pullWithRebase) {
                            Button("Pull into Current with Rebase") {
                                onPullRemoteBranch(rootPath, name, true)
                            }
                        }
                        Divider()
                        if availability.contains(.compareWithCurrent) {
                            Button("Compare with Current…") {
                                onCompare(rootPath, name)
                            }
                        }
                        if availability.contains(.showDiffWithWorkingTree) {
                            Button("Show Diff with Working Tree") {
                                onShowDiffWithWorkingTree(rootPath, name)
                            }
                        }
                        if availability.contains(.rebase) {
                            Button("Rebase Current onto…") {
                                onRebase(rootPath, name)
                            }
                        }
                        if availability.contains(.merge) {
                            Button("Merge into Current…") {
                                onMerge(rootPath, name)
                            }
                        }
                        Divider()
                    } else {
                        if availability.contains(.compareWithCurrent) {
                            Button("Compare with Current…") {
                                onCompare(rootPath, name)
                            }
                        }
                        if availability.contains(.showDiffWithWorkingTree) {
                            Button("Show Diff with Working Tree") {
                                onShowDiffWithWorkingTree(rootPath, name)
                            }
                        }
                        if availability.contains(.createWorktree) {
                            Button("New Working Tree from Branch…") {
                                onCreateWorktreeFromReference(rootPath, name, false)
                            }
                            .disabled(!availability.isEnabled(.createWorktree))
                        }
                        if availability.contains(.merge) {
                            Button("Merge into Current…") {
                                onMerge(rootPath, name)
                            }
                        }
                        if availability.contains(.rebase) {
                            Button("Rebase Current onto…") {
                                onRebase(rootPath, name)
                            }
                        }
                        if availability.contains(.push) {
                            Button("Push…") {
                                onPushDialog(rootPath, name)
                            }
                        }
                        if availability.contains(.update) {
                            Divider()
                            Button("Update") {
                                onUpdateBranch(rootPath, name)
                            }
                            .disabled(!availability.isEnabled(.update))
                            .help(availability.disabledDescription(for: .update) ?? "")
                        }
                        if let trackedRemote = trackedRemoteBranch(rootPath: rootPath, localName: name) {
                            Divider()
                            trackedBranchMenu(rootPath: rootPath, remote: trackedRemote)
                        }
                        if availability.contains(.setUpstream) {
                            Divider()
                            Button("Set Upstream…") {
                                onSetUpstream(rootPath, name)
                            }
                        }
                        if availability.contains(.unsetUpstream) {
                            Divider()
                            Button("Unset Upstream") {
                                onUnsetUpstream(rootPath, name)
                            }
                        }
                    }
                    if availability.contains(.checkout) {
                        Button(isRemote ? "Checkout as Local" : "Checkout") {
                            onCheckout(rootPath, name, isRemote)
                        }
                        .disabled(!availability.isEnabled(.checkout))
                    }
                    if availability.contains(.checkoutAsNewBranch) {
                        Button("Checkout as New Branch…") {
                            onCheckoutAsNewBranch(rootPath, name, isRemote)
                        }
                    }
                    if availability.contains(.checkoutWithUpdate) {
                        Button("Checkout and Update") {
                            onCheckoutAndUpdate(rootPath, name, false, false)
                        }
                        .disabled(!availability.isEnabled(.checkoutWithUpdate))
                        .help(availability.disabledDescription(for: .checkoutWithUpdate) ?? "")
                    }
                    if availability.contains(.checkoutWithRebase) {
                        Button("Checkout with Rebase") {
                            onCheckoutWithRebase(rootPath, name, isRemote)
                        }
                        .disabled(!availability.isEnabled(.checkoutWithRebase))
                    }
                    if availability.contains(.openWorktree),
                       let worktreePath, !worktreePath.isEmpty {
                        Button("Open Worktree…") {
                            onOpenWorktree(worktreePath)
                        }
                    }
                    if !isRemote {
                        Divider()
                        if availability.contains(.rename) {
                            Button("Rename…") {
                                onRenameBranch(rootPath, name)
                            }
                        }
                        let sameNameLocalReferences = snapshots.compactMap { snapshot -> BranchDashboardReference? in
                            guard let branch = snapshot.branches.first(where: { $0.name == name }) else { return nil }
                            let branchSync = snapshot.syncStatuses.first(where: { $0.branch == name })
                            return popupReference(
                                name: branch.name,
                                isCurrent: branch.isCurrent,
                                sync: branchSync,
                                rootPath: snapshot.rootPath,
                                isRemote: false,
                                hasHeadCommit: snapshot.headId != nil,
                                worktreePath: snapshot.worktrees.first { $0.branch == name && !$0.path.isEmpty }?.path
                            )
                        }
                        if sameNameLocalReferences.count > 1,
                           allowsSynchronizedBranchActions {
                            let crossRootAvailability = BranchDashboardActionAvailability.resolve(
                                selection: sameNameLocalReferences
                            )
                            Button("Merge in Repositories…") {
                                onMergeAcrossRoots(name)
                            }
                            Button("Rename in Repositories…") {
                                onRenameBranchAcrossRoots(name)
                            }
                            Button("Delete in Repositories…", role: .destructive) {
                                onDeleteBranchAcrossRoots(name)
                            }
                            .disabled(!crossRootAvailability.isEnabled(.deleteSelected))
                        }
                        if availability.contains(.deleteLocal) {
                            Button("Delete", role: .destructive) {
                                onDeleteBranch(rootPath, name)
                            }
                        }
                    } else if availability.contains(.deleteRemote) {
                        Button("Delete Remote Branch", role: .destructive) {
                            onDeleteRemote(rootPath, name)
                        }
                        .disabled(!availability.isEnabled(.deleteRemote))
                        let sameNameRemoteReferences = snapshots.compactMap { snapshot -> BranchDashboardReference? in
                            guard snapshot.remoteBranches.contains(where: { $0.name == name }) else { return nil }
                            let remoteSync = snapshot.syncStatuses.first(where: { $0.upstream == name })
                            return popupReference(
                                name: name,
                                isCurrent: false,
                                sync: remoteSync,
                                rootPath: snapshot.rootPath,
                                isRemote: true,
                                worktreePath: nil
                            )
                        }
                        if sameNameRemoteReferences.count > 1,
                           allowsSynchronizedBranchActions {
                            Button("Delete in Repositories…", role: .destructive) {
                                onDeleteRemoteAcrossRoots(name)
                            }
                            .disabled(!BranchDashboardActionAvailability.resolve(
                                selection: sameNameRemoteReferences
                            ).isEnabled(.deleteSelected))
                        }
                    }
                } label: {
                    Image(systemName: isRemote ? "arrow.down.to.line" : "arrow.triangle.branch")
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("branch-row-menu")
                .accessibilityLabel(Text("Branch Actions"))
            }
        }
        .padding(.horizontal, 6)
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            selectBranchTarget(
                id: multiTargetID(
                    rootPath: rootPath,
                    kind: isRemote ? .remote : .local,
                    value: name
                )
            )
        }
        .background(selected ? Color.accentColor.opacity(0.22) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
    }

    private func selectRemoteGroupTarget(id: String) {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        selectedBranchTargetID = id
        selectedBranchTargetIDs = []
        branchSelectionAnchorID = nil
        selectedRemoteGroupIDs = toggledBranchTreeSelection(
            current: selectedRemoteGroupIDs,
            id: id,
            command: flags.contains(.command)
        )
    }

    private func selectBranchTarget(id: String) {
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
    }

}
