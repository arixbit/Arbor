import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RebasedBranchesPopover: View {
    var projectPath: String? = nil
    let branches: [BranchInfo]
    let remoteBranches: [RemoteBranchInfo]
    let recentBranches: [String]
    let tags: [TagInfo]
    let comparisons: [String: BranchCompare]
    let syncStatuses: [SyncStatus]
    var incomingBranches: Set<GitIncomingBranch> = []
    let stashes: [StashInfo]
    var worktrees: [WorktreeInfo] = []
    let hasRemote: Bool
    var protectedBranchPatterns: [String] = []
    var isShallow: Bool = false
    /// An unborn repository cannot create a branch or worktree from HEAD.
    /// Keep this in the action context instead of relying on an optimistic
    /// default while the status snapshot is resolving.
    var hasHeadCommit: Bool = true
    var hasCommitChanges: Bool = false
    let onCheckout: (String) -> Void
    var onRenameBranch: (String) -> Void = { _ in }
    var onDeleteBranch: (String) -> Void = { _ in }
    var onCheckoutRecent: (String) -> Void = { _ in }
    var onCheckoutTag: (String) -> Void = { _ in }
    var onCheckoutAsNewBranch: (String, Bool) -> Void = { _, _ in }
    var onDeleteTag: (String) -> Void = { _ in }
    var onRenameTag: (String) -> Void = { _ in }
    var onPushTag: (String) -> Void = { _ in }
    var tagPushRemotes: [String] = []
    var onPushTagToRemote: (String, String) -> Void = { _, _ in }
    var onShowDiffWithWorkingTree: (String) -> Void = { _ in }
    var onPushAllTags: (String) -> Void = { _ in }
    var onRemoteTags: () -> Void = {}
    var onCheckoutAndUpdate: (String, Bool) -> Void = { _, _ in }
    let onUpdateBranch: (String) -> Void
    /// GitPushBranchAction opens Push with the selected local branch as the
    /// source, including when that branch is not checked out.
    var onPushBranch: (String) -> Void = { _ in }
    var onForcePushedUpdate: () -> Void = {}
    var onPullRemoteBranch: (RemoteBranchInfo, Bool) -> Void = { _, _ in }
    let onCheckoutRemote: (RemoteBranchInfo) -> Void
    var onCheckoutRemoteWithRebase: (RemoteBranchInfo) -> Void = { _ in }
    let onDeleteRemote: (RemoteBranchInfo) -> Void
    let onNewBranch: () -> Void
    var onCommitChanges: () -> Void = {}
    var onFindMerged: () -> Void = {}
    var onCheckoutReference: () -> Void = {}
    var onOpenWorktree: (String) -> Void = { _ in }
    var onCreateWorktreeFromReference: (String, Bool) -> Void = { _, _ in }
    let onCompare: (String) -> Void
    let onMerge: (String?) -> Void
    let onRebase: (String?) -> Void
    let onStash: () -> Void
    let onApplyStash: (String, Bool) -> Void
    let onPopStash: (String, Bool) -> Void
    let onDropStash: (String) -> Void
    let onStashBranch: (String) -> Void
    let onStashDiff: (String) -> Void
    var onStashClear: () -> Void = {}
    let onNewTag: () -> Void
    let onShelve: () -> Void
    let onUpdate: (Bool) -> Void
    let onPush: () -> Void
    let onFetch: () -> Void
    let onRefresh: () -> Void
    var onConfigureRemotes: () -> Void = {}
    var onProjectGitSettings: () -> Void = {}
    var onFetchAll: () -> Void = {}
    var onFetchPrune: () -> Void = {}
    var onFetchUnshallow: () -> Void = {}
    var onSetUpstream: (String) -> Void = { _ in }
    var onUnsetUpstream: (String) -> Void = { _ in }
    var operationState: OperationState? = nil
    var onOperationContinue: () -> Void = {}
    var onOperationSkip: () -> Void = {}
    var onOperationAbort: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @AppStorage(GitIncomingOutgoingInfoSettings.key)
    private var incomingOutgoingInfoEnabled = GitIncomingOutgoingInfoSettings.defaultValue
    @State private var query = ""
    @State private var showRecentBranches = GitBranchesPopupSettings.defaultShowRecentBranches
    @State private var filterByAction = GitBranchesPopupSettings.defaultFilterByActionInPopup
    @State private var showTags = GitBranchesPopupSettings.defaultShowTags
    @State private var groupByDirectory = GitBranchesPopupSettings.defaultGroupByDirectory
    @State private var collapsedDirectoryGroups: Set<String> = []
    @State private var selectedBranchTargetID: String?
    @State private var favoriteReferenceIDs: Set<String> = []
    @State private var popupSize = GitBranchesPopupSettings.defaultPopupSize

    private var filteredBranches: [BranchInfo] {
        branches.filter { branchSearchMatches($0.name, query: query) }
    }

    private var filteredRemoteBranches: [RemoteBranchInfo] {
        remoteBranches.filter { branchSearchMatches($0.name, query: query) }
    }

    private var filteredRecentBranches: [String] {
        recentBranches.filter { branchSearchMatches($0, query: query) }
    }

    private var filteredActionTargets: [BranchTreeTarget] {
        branchPopupVisibleActions(
            query: query,
            filterByAction: filterByAction
        ).map { action in
            BranchTreeTarget(
                id: "single.action:\(action.rawValue)",
                value: action.rawValue,
                title: action.title,
                kind: .action,
                isEnabled: isBranchPopupActionEnabled(
                    action,
                    hasHeadCommit: hasHeadCommit,
                    hasCommitChanges: hasCommitChanges
                )
            )
        }
    }

    private var filteredOperationActionTargets: [BranchTreeTarget] {
        guard let operationState else { return [] }
        return branchPopupOperationActions(
            for: operationState.kind,
            hasConflicts: !operationState.conflictedFiles.isEmpty
        )
            .filter { !filterByAction || branchSearchMatches($0.title, query: query) }
            .map { action in
                BranchTreeTarget(
                    id: "single.operation:\(action.rawValue)",
                    value: action.rawValue,
                    title: action.title,
                    kind: .action,
                    isEnabled: true
                )
            }
    }

    private var keyboardTargets: [BranchTreeTarget] {
        let recentNames = showRecentBranches ? visibleBranchDirectoryRefNames(
            filteredRecentBranches,
            grouped: groupByDirectory,
            scope: "single.recent",
            collapsedGroups: collapsedDirectoryGroups
        ) : []
        let recent = recentNames.map {
            BranchTreeTarget(id: "single.recent:\($0)", value: $0, title: $0, kind: .recent)
        }
        let local = visibleBranchDirectoryRefNames(
            filteredBranches.map(\.name),
            grouped: groupByDirectory,
            scope: "single.local",
            collapsedGroups: collapsedDirectoryGroups
        ).map {
            BranchTreeTarget(id: "single.local:\($0)", value: $0, title: $0, kind: .local)
        }
        let remote = visibleBranchDirectoryRefNames(
            filteredRemoteBranches.map(\.name),
            grouped: groupByDirectory,
            scope: "single.remote",
            collapsedGroups: collapsedDirectoryGroups
        ).map {
            BranchTreeTarget(id: "single.remote:\($0)", value: $0, title: $0, kind: .remote)
        }
        let tagNames = showTags ? visibleBranchDirectoryRefNames(
            tags.filter { branchSearchMatches($0.name, query: query) }.map(\.name),
            grouped: groupByDirectory,
            scope: "single.tags",
            collapsedGroups: collapsedDirectoryGroups
        ) : []
        let tagTargets = tagNames.map {
            BranchTreeTarget(id: "single.tag:\($0)", value: $0, title: $0, kind: .tag)
        }
        let references = recent + local + remote + tagTargets
        let actionTargets = filterByAction
            ? (filteredOperationActionTargets + filteredActionTargets).filter(\.isEnabled)
            : []
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return references + actionTargets
        }
        return actionTargets + references
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.blue)
                Text("Branches")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Refresh branches")
                Menu {
                    Toggle("Show Recent Branches", isOn: $showRecentBranches)
                    Toggle("Show Actions in Search Results", isOn: $filterByAction)
                    Toggle("Show Tags", isOn: $showTags)
                    Toggle("Group by Directory", isOn: $groupByDirectory)
                    Divider()
                    Button("Restore Default Size") {
                        popupSize = GitBranchesPopupSettings.defaultPopupSize
                        GitBranchesPopupSettings.savePopupSize(popupSize, for: projectPath)
                    }
                    .disabled(popupSize == GitBranchesPopupSettings.defaultPopupSize)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(.secondary)
                .help("Branches Popup Settings")
            }
            .padding(.bottom, 10)

            TextField("Search branches", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.bottom, 8)
                .onSubmit { activateSelectedBranch() }
                .onKeyPress(.downArrow, action: handleDownKeyPress)
                .onKeyPress(.upArrow, action: handleUpKeyPress)

            HStack(spacing: 5) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("↓ Incoming / ↑ Outgoing · Pull selected branch without checkout")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !filteredOperationActionTargets.isEmpty {
                        Text("ONGOING OPERATIONS")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.top, 2)
                        ForEach(filteredOperationActionTargets) { target in
                            Button {
                                selectedBranchTargetID = target.id
                                if let action = BranchPopupOperationActionID(rawValue: target.value) {
                                    activateOperationAction(action)
                                }
                                dismiss()
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
                            .padding(.top, 2)
                        ForEach(filteredActionTargets) { target in
                            Button {
                                selectedBranchTargetID = target.id
                                if let action = BranchPopupActionID(rawValue: target.value) {
                                    activateAction(action)
                                }
                                dismiss()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: BranchPopupActionID(rawValue: target.value)?.systemImage ?? "bolt")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 16)
                                    Text(target.title)
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
                                        hasHeadCommit: hasHeadCommit,
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
                    if showRecentBranches && !filteredRecentBranches.isEmpty {
                        Text("RECENT")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.top, 2)
                        ForEach(visibleBranchDirectoryRows(
                            branchDirectoryRows(
                                for: filteredRecentBranches,
                                grouped: groupByDirectory,
                                scope: "single.recent"
                            ),
                            collapsedGroups: collapsedDirectoryGroups
                        )) { row in
                            if row.isGroup {
                                branchDirectoryGroupRow(row)
                            } else if let refName = branchDirectoryRefName(row) {
                                Button {
                                    selectedBranchTargetID = "single.recent:\(refName)"
                                    onCheckoutRecent(refName)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "clock")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 16)
                                        Text(row.name)
                                            .lineLimit(1)
                                    }
                                    .padding(.leading, CGFloat(row.depth) * 14)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                }
                                .buttonStyle(.plain)
                                .background(
                                    selectedBranchTargetID == "single.recent:\(refName)"
                                        ? Color.accentColor.opacity(0.22)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5)
                                )
                            }
                        }
                    }
                    Text("LOCAL BRANCHES")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.top, 2)
                    if filteredBranches.isEmpty {
                        Text("No matching branches")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    } else {
                        ForEach(visibleBranchDirectoryRows(
                            branchDirectoryRows(
                                for: filteredBranches.map(\.name),
                                grouped: groupByDirectory,
                                scope: "single.local"
                            ),
                            collapsedGroups: collapsedDirectoryGroups
                        )) { row in
                            if row.isGroup {
                                branchDirectoryGroupRow(row)
                            } else if let refName = branchDirectoryRefName(row),
                                      let branch = filteredBranches.first(where: { $0.name == refName }) {
                                branchRow(
                                    branch,
                                    title: row.name,
                                    depth: row.depth,
                                    selected: selectedBranchTargetID == "single.local:\(branch.name)"
                                )
                            }
                        }
                    }
                    Text("REMOTE BRANCHES")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.top, 10)
                    if filteredRemoteBranches.isEmpty {
                        Text("No remote-tracking branches")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    } else {
                        ForEach(visibleBranchDirectoryRows(
                            branchDirectoryRows(
                                for: filteredRemoteBranches.map(\.name),
                                grouped: groupByDirectory,
                                scope: "single.remote"
                            ),
                            collapsedGroups: collapsedDirectoryGroups
                        )) { row in
                            if row.isGroup {
                                branchDirectoryGroupRow(row)
                            } else if let refName = branchDirectoryRefName(row),
                                      let remote = filteredRemoteBranches.first(where: { $0.name == refName }) {
                                remoteBranchRow(
                                    remote,
                                    title: row.name,
                                    depth: row.depth,
                                    selected: selectedBranchTargetID == "single.remote:\(remote.name)"
                                )
                            }
                        }
                    }
                    if (showTags && !tags.isEmpty) || hasRemote {
                        HStack {
                            Text("TAGS")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if showTags && !tags.isEmpty {
                                if tagPushRemotes.count == 1 {
                                    Button("Push All Tags") {
                                        onPushAllTags(tagPushRemotes[0])
                                        dismiss()
                                    }
                                    .font(.caption)
                                    .controlSize(.small)
                                } else if tagPushRemotes.count > 1 {
                                    Menu("Push All Tags") {
                                        ForEach(tagPushRemotes, id: \.self) { remote in
                                            Button(remote) {
                                                onPushAllTags(remote)
                                                dismiss()
                                            }
                                        }
                                    }
                                    .font(.caption)
                                    .controlSize(.small)
                                }
                            }
                            if hasRemote {
                                Button("Remote Tags…") {
                                    onRemoteTags()
                                    dismiss()
                                }
                                .font(.caption)
                                .controlSize(.small)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.top, 10)
                        if showTags {
                            ForEach(visibleBranchDirectoryRows(
                                branchDirectoryRows(
                                    for: tags.map(\.name),
                                    grouped: groupByDirectory,
                                    scope: "single.tags"
                                ),
                                collapsedGroups: collapsedDirectoryGroups
                            )) { row in
                            if row.isGroup {
                                branchDirectoryGroupRow(row)
                            } else if let refName = branchDirectoryRefName(row),
                                      let tag = tags.first(where: { $0.name == refName }) {
                                Button {
                                    selectedBranchTargetID = "single.tag:\(tag.name)"
                                    onCheckoutTag(tag.name)
                                    dismiss()
                                } label: {
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
                                    .padding(.leading, CGFloat(row.depth) * 14)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                }
                                .buttonStyle(.plain)
                                .disabled(tag.isCurrent)
                                .background(
                                    selectedBranchTargetID == "single.tag:\(tag.name)"
                                        ? Color.accentColor.opacity(0.22)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5)
                                )
                                .contextMenu {
                                    if !tag.isCurrent {
                                        Button("Checkout") {
                                            onCheckoutTag(tag.name)
                                        }
                                    }
                                    Button("Show Diff with Working Tree") {
                                        onShowDiffWithWorkingTree(tag.name)
                                    }
                                    if !tag.isCurrent {
                                        Button("Merge into Current…") {
                                            onMerge(tag.name)
                                        }
                                        Button("Delete") { onDeleteTag(tag.name) }
                                    }
                                    if tagPushRemotes.count > 1 {
                                        Menu("Push to Remote") {
                                            ForEach(tagPushRemotes, id: \.self) { remote in
                                                Button(remote) { onPushTagToRemote(tag.name, remote) }
                                            }
                                        }
                                    } else if tagPushRemotes.count == 1 {
                                        Button("Push to Remote") { onPushTag(tag.name) }
                                    }
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
                        if !stashes.isEmpty {
                            Button("Clear All") { onStashClear() }
                                .font(.caption)
                                .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 10)
                    if stashes.isEmpty {
                        Text("No stashes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    } else {
                        ForEach(stashes, id: \.id) { stash in
                            stashRow(stash)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 380)

            Divider()
                .padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 4) {
                Button(action: { onCommitChanges(); dismiss() }) {
                    Label("Commit Changes…", systemImage: "checkmark.circle")
                }
                .disabled(!hasCommitChanges)
                .help(
                    branchPopupActionDisabledDescription(
                        .commitChanges,
                        hasHeadCommit: hasHeadCommit,
                        hasCommitChanges: hasCommitChanges
                    ) ?? ""
                )
                Button(action: { onNewBranch(); dismiss() }) {
                    Label("New Branch…", systemImage: "plus")
                }
                .disabled(!hasHeadCommit)
                .help(
                    branchPopupActionDisabledDescription(
                        .newBranch,
                        hasHeadCommit: hasHeadCommit
                    ) ?? ""
                )
                Button(action: { onFindMerged(); dismiss() }) {
                    Label("Find Merged Branches…", systemImage: "checkmark.branch")
                }
                .disabled(!isFindMergedBranchesActionEnabled(localBranchCounts: [branches.count]))
                Button(action: { onCheckoutReference(); dismiss() }) {
                    Label("Checkout Tag or Revision…", systemImage: "arrow.down.to.line")
                }
                Button(action: { onCompare(comparisonTarget); dismiss() }) {
                    Label("Compare with Current…", systemImage: "arrow.left.arrow.right")
                }
                .disabled(comparisonTarget == currentBranchName)
                HStack(spacing: 6) {
                    Button("Update") { onUpdate(false); dismiss() }
                        .disabled(!hasRemote)
                    Button("Push") { onPush(); dismiss() }
                        .disabled(!hasRemote)
                    Button("Fetch") { onFetch(); dismiss() }
                        .disabled(!hasRemote)
                }
                Menu("Remote maintenance…") {
                    Button("Fetch All") { onFetchAll(); dismiss() }
                        .disabled(!hasRemote)
                    Button("Prune Deleted Branches") { onFetchPrune(); dismiss() }
                        .disabled(!hasRemote)
                    if isShallow {
                        Button("Fetch Full History…") { onFetchUnshallow(); dismiss() }
                            .disabled(!hasRemote)
                    }
                }
                HStack(spacing: 6) {
                    Button("Merge…") { onMerge(nil); dismiss() }
                    Button("Rebase…") { onRebase(nil); dismiss() }
                    Button("Stash…") { onStash(); dismiss() }
                }
                HStack(spacing: 6) {
                    Button("New Tag…") { onNewTag(); dismiss() }
                    Button("Shelve…") { onShelve(); dismiss() }
                }
                SettingsLink {
                    Label("Settings…", systemImage: "gearshape")
                }
                .buttonStyle(.link)
                .padding(.top, 2)
                Button(action: { onProjectGitSettings(); dismiss() }) {
                    Label("Project Git Settings…", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.link)
                Button(action: { onConfigureRemotes(); dismiss() }) {
                    Label("Configure Remotes…", systemImage: "server.rack")
                }
                .buttonStyle(.link)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: popupSize.width, height: popupSize.height)
        .overlay(alignment: .bottomTrailing) {
            BranchesPopupResizeHandle(
                size: $popupSize,
                minimum: CGSize(width: 320, height: 360),
                maximum: CGSize(width: 1100, height: 1000)
            ) { size in
                GitBranchesPopupSettings.savePopupSize(size, for: projectPath)
            }
        }
        .onAppear {
            popupSize = GitBranchesPopupSettings.popupSize(for: projectPath)
            favoriteReferenceIDs = GitBranchesPopupSettings.favorites(for: projectPath)
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
        }
    }

    private func moveSelectedBranch(by offset: Int) {
        selectedBranchTargetID = movedBranchTreeSelection(
            currentID: selectedBranchTargetID,
            selectableIDs: keyboardTargets.map(\.id),
            offset: offset
        )
    }

    private func handleDownKeyPress() -> KeyPress.Result {
        moveSelectedBranch(by: 1)
        return .handled
    }

    private func handleUpKeyPress() -> KeyPress.Result {
        moveSelectedBranch(by: -1)
        return .handled
    }

    private func activateSelectedBranch() {
        guard let selectedBranchTargetID,
              let target = keyboardTargets.first(where: { $0.id == selectedBranchTargetID }) else { return }
        switch target.kind {
        case .action:
            if let action = BranchPopupOperationActionID(rawValue: target.value) {
                activateOperationAction(action)
            } else if let action = BranchPopupActionID(rawValue: target.value) {
                activateAction(action)
            }
        case .repository:
            return
        case .head:
            return
        case .recent:
            onCheckoutRecent(target.value)
        case .local:
            onCheckout(target.value)
        case .remote:
            guard let branch = remoteBranches.first(where: { $0.name == target.value }) else { return }
            onCheckoutRemote(branch)
        case .remoteGroup:
            return
        case .tag:
            onCheckoutTag(target.value)
        }
        dismiss()
    }

    private func activateAction(_ action: BranchPopupActionID) {
        switch action {
        case .commitChanges:
            onCommitChanges()
        case .newBranch:
            onNewBranch()
        case .checkoutReference:
            onCheckoutReference()
        }
    }

    private func activateOperationAction(_ action: BranchPopupOperationActionID) {
        switch action.recoveryAction {
        case .continueOperation:
            onOperationContinue()
        case .skip:
            onOperationSkip()
        case .abort:
            onOperationAbort()
        case .openRecovery:
            break
        }
    }

    private var currentBranchName: String {
        branches.first(where: { $0.isCurrent })?.name ?? "HEAD"
    }

    private func popupReference(for branch: BranchInfo) -> BranchDashboardReference {
        let sync = syncStatuses.first(where: { $0.branch == branch.name })
        return BranchDashboardReference(
            rootPath: projectPath ?? "",
            name: branch.name,
            kind: .local,
            remote: nil,
            isCurrent: branch.isCurrent,
            hasUpstream: sync != nil,
            hasTracking: sync?.trackingExists == true,
            hasRemote: hasRemote || sync != nil,
            isProtected: GitProtectedBranchRules.matches(
                branch.name,
                patterns: protectedBranchPatterns
            ),
            hasHeadCommit: hasHeadCommit,
            worktreePath: linkedWorktreePathForBranch(
                branch: branch.name,
                worktrees: worktrees,
                currentRootPath: projectPath ?? ""
            )
        )
    }

    private func popupReference(for branch: RemoteBranchInfo) -> BranchDashboardReference {
        let localBranchName = syncStatus(for: branch)?.branch
        let shortName = branch.name.split(separator: "/", maxSplits: 1)
            .dropFirst()
            .joined(separator: "/")
        return BranchDashboardReference(
            rootPath: projectPath ?? "",
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

    private func trackedRemoteBranch(for branch: BranchInfo) -> RemoteBranchInfo? {
        guard let sync = syncStatuses.first(where: {
            $0.branch == branch.name && $0.trackingExists
        }) else { return nil }
        return remoteBranches.first(where: { $0.name == sync.upstream })
    }

    private var comparisonTarget: String {
        branches.first(where: { !$0.isCurrent })?.name ?? currentBranchName
    }

    private func favoriteTitle(name: String, isRemote: Bool) -> String {
        favoriteReferenceIDs.contains(branchFavoriteID(name: name, isRemote: isRemote))
            ? "Unmark As Favorite"
            : "Mark As Favorite"
    }

    private func branchFavoriteID(name: String, isRemote: Bool) -> String {
        BranchDashboardReference.referenceID(
            rootPath: projectPath ?? "",
            name: name,
            kind: isRemote ? .remote : .local
        )
    }

    private func toggleFavorite(name: String, isRemote: Bool) {
        let id = branchFavoriteID(name: name, isRemote: isRemote)
        if favoriteReferenceIDs.contains(id) {
            favoriteReferenceIDs.remove(id)
        } else {
            favoriteReferenceIDs.insert(id)
        }
        GitBranchesPopupSettings.saveFavorites(favoriteReferenceIDs, for: projectPath)
    }

    @ViewBuilder
    private func branchDirectoryGroupRow(_ row: BranchDirectoryRow) -> some View {
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
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, CGFloat(row.depth) * 14 + 6)
                .padding(.top, 4)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func branchRow(
        _ branch: BranchInfo,
        title: String? = nil,
        depth: Int = 0,
        selected: Bool = false
    ) -> some View {
        let availability = BranchDashboardActionAvailability.resolve(
            selection: [popupReference(for: branch)]
        )
        let hasIncoming = hasUnfetchedIncomingBranch(
            rootPath: projectPath,
            branch: branch.name,
            in: incomingBranches
        )
        HStack(spacing: 6) {
            Button {
                selectedBranchTargetID = "single.local:\(branch.name)"
                guard !branch.isCurrent else { return }
                onCheckout(branch.name)
                dismiss()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: branch.isCurrent ? "checkmark.circle.fill" : "arrow.triangle.branch")
                        .foregroundStyle(branch.isCurrent ? .blue : .secondary)
                        .frame(width: 16)
                    Text(title ?? branch.name)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if incomingOutgoingInfoEnabled,
                       let sync = syncStatuses.first(where: { $0.branch == branch.name }) {
                        syncBadge(sync, hasUnfetchedIncoming: hasIncoming)
                    } else if incomingOutgoingInfoEnabled, hasIncoming {
                        unfetchedIncomingBadge
                    } else if incomingOutgoingInfoEnabled,
                              let compare = comparisons[branch.name], compare.ahead > 0 || compare.behind > 0 {
                        Text("↑\(compare.ahead) ↓\(compare.behind)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if favoriteReferenceIDs.contains(branchFavoriteID(name: branch.name, isRemote: false)) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!availability.isEnabled(.checkout))

            Menu {
                Button(favoriteTitle(name: branch.name, isRemote: false)) {
                    toggleFavorite(name: branch.name, isRemote: false)
                }
                Divider()
                if availability.contains(.compareWithCurrent) {
                    Button("Compare with Current…") { onCompare(branch.name); dismiss() }
                }
                if availability.contains(.showDiffWithWorkingTree) {
                    Button("Show Diff with Working Tree") {
                        onShowDiffWithWorkingTree(branch.name)
                        dismiss()
                    }
                }
                if !branch.isCurrent {
                    Divider()
                    if availability.contains(.rebase) {
                        Button("Rebase Current onto…") { onRebase(branch.name); dismiss() }
                    }
                    if availability.contains(.merge) {
                        Button("Merge into Current…") { onMerge(branch.name); dismiss() }
                    }
                    Divider()
                }
                if availability.contains(.createWorktree) {
                    Button("New Working Tree from Branch…") {
                        onCreateWorktreeFromReference(branch.name, false)
                        dismiss()
                    }
                }
                if let trackedRemote = trackedRemoteBranch(for: branch) {
                    let trackedAvailability = BranchDashboardActionAvailability.resolve(
                        selection: [popupReference(for: trackedRemote)]
                    )
                    Divider()
                    Menu("Tracked Branch: \(trackedRemote.name)") {
                        Button("Compare with Current…") {
                            onCompare(trackedRemote.name)
                            dismiss()
                        }
                        Button("Show Diff with Working Tree") {
                            onShowDiffWithWorkingTree(trackedRemote.name)
                            dismiss()
                        }
                        Divider()
                        Button("Rebase Current onto…") {
                            onRebase(trackedRemote.name)
                            dismiss()
                        }
                        Button("Merge into Current…") {
                            onMerge(trackedRemote.name)
                            dismiss()
                        }
                        Divider()
                        Button("Pull into Current") {
                            onPullRemoteBranch(trackedRemote, false)
                            dismiss()
                        }
                        Button("Pull into Current with Rebase") {
                            onPullRemoteBranch(trackedRemote, true)
                            dismiss()
                        }
                        Divider()
                        Button("Checkout as Local Branch") {
                            onCheckoutRemote(trackedRemote)
                            dismiss()
                        }
                        Button("Checkout as New Branch…") {
                            onCheckoutAsNewBranch(trackedRemote.name, true)
                            dismiss()
                        }
                        Button("Checkout with Rebase") {
                            onCheckoutRemoteWithRebase(trackedRemote)
                            dismiss()
                        }
                        Button("Delete Remote Branch", role: .destructive) {
                            onDeleteRemote(trackedRemote)
                            dismiss()
                        }
                        .disabled(!trackedAvailability.isEnabled(.deleteRemote))
                    }
                }
                if availability.contains(.setUpstream) {
                    Divider()
                    Button("Set Upstream…") { onSetUpstream(branch.name); dismiss() }
                } else if availability.contains(.unsetUpstream) {
                    Divider()
                    Button("Unset Upstream") { onUnsetUpstream(branch.name); dismiss() }
                }
                if availability.contains(.update) {
                    Divider()
                    Button("Update") { onUpdateBranch(branch.name); dismiss() }
                        .disabled(!availability.isEnabled(.update))
                        .help(availability.disabledDescription(for: .update) ?? "")
                }
                if availability.contains(.push) {
                    Divider()
                    Button("Push…") {
                        onPushBranch(branch.name)
                        dismiss()
                    }
                }
                if branch.isCurrent,
                   let sync = syncStatuses.first(where: { $0.branch == branch.name }),
                   sync.trackingExists,
                   sync.ahead > 0,
                   sync.behind > 0 {
                    Button("Update Force-Pushed Branch…") {
                        onForcePushedUpdate()
                        dismiss()
                    }
                }
                if !branch.isCurrent {
                    if availability.contains(.checkout) {
                        Button("Checkout") { onCheckout(branch.name); dismiss() }
                            .disabled(!availability.isEnabled(.checkout))
                    }
                    if availability.contains(.checkoutAsNewBranch) {
                        Button("Checkout as New Branch…") {
                            onCheckoutAsNewBranch(branch.name, false)
                            dismiss()
                        }
                    }
                    if availability.contains(.checkoutWithUpdate) {
                        Button("Checkout and Update") { onCheckoutAndUpdate(branch.name, false); dismiss() }
                            .disabled(!availability.isEnabled(.checkoutWithUpdate))
                            .help(availability.disabledDescription(for: .checkoutWithUpdate) ?? "")
                    }
                    if availability.contains(.checkoutWithRebase) {
                        Button("Checkout with Rebase") { onCheckoutAndUpdate(branch.name, true); dismiss() }
                            .disabled(!availability.isEnabled(.checkoutWithRebase))
                    }
                    if availability.contains(.openWorktree),
                       let worktree = worktrees.first(where: { $0.branch == branch.name && !$0.path.isEmpty }) {
                        Button("Open Worktree…") { onOpenWorktree(worktree.path); dismiss() }
                    }
                    if availability.contains(.deleteLocal) {
                        Divider()
                        Button("Delete", role: .destructive) { onDeleteBranch(branch.name); dismiss() }
                    }
                }
                if availability.contains(.rename) {
                    Divider()
                    Button("Rename…") { onRenameBranch(branch.name); dismiss() }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.vertical, 4)
        .background(selected ? Color.accentColor.opacity(0.22) : (branch.isCurrent ? Color.accentColor.opacity(0.14) : Color.clear),
                    in: RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder
    private func remoteBranchRow(
        _ branch: RemoteBranchInfo,
        title: String? = nil,
        depth: Int = 0,
        selected: Bool = false
    ) -> some View {
        let sync = syncStatus(for: branch)
        let local = localBranch(for: branch)
        let incomingBranch = branch.name.hasPrefix("\(branch.remote)/")
            ? String(branch.name.dropFirst(branch.remote.count + 1))
            : nil
        let hasIncoming = incomingBranch.map {
            hasUnfetchedIncomingRemoteBranch(
                rootPath: projectPath,
                remote: branch.remote,
                branch: $0,
                in: incomingBranches
            )
        } ?? false
        let availability = BranchDashboardActionAvailability.resolve(
            selection: [popupReference(for: branch)]
        )
        HStack(spacing: 7) {
            Image(systemName: "cloud")
                .foregroundStyle(.blue)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title ?? branch.name)
                    .lineLimit(1)
                if incomingOutgoingInfoEnabled, let sync {
                    Text("跟踪本地 \(sync.branch)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if favoriteReferenceIDs.contains(branchFavoriteID(name: branch.name, isRemote: true)) {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(branch.shortId)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                if incomingOutgoingInfoEnabled, let sync {
                    remoteSyncBadge(sync, hasUnfetchedIncoming: hasIncoming)
                } else if incomingOutgoingInfoEnabled, hasIncoming {
                    unfetchedIncomingBadge
                } else if incomingOutgoingInfoEnabled, let local, local.shortId != branch.shortId {
                    Text("远程有更新")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.blue)
                } else if incomingOutgoingInfoEnabled, local != nil {
                    Text("已同步")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Menu {
                Button(favoriteTitle(name: branch.name, isRemote: true)) {
                    toggleFavorite(name: branch.name, isRemote: true)
                }
                Divider()
                Button("Pull into Current") {
                    onPullRemoteBranch(branch, false)
                    dismiss()
                }
                Button("Pull into Current with Rebase") {
                    onPullRemoteBranch(branch, true)
                    dismiss()
                }
                Divider()
                if availability.contains(.compareWithCurrent) {
                    Button("Compare with Current…") {
                        onCompare(branch.name)
                        dismiss()
                    }
                }
                if availability.contains(.showDiffWithWorkingTree) {
                    Button("Show Diff with Working Tree") {
                        onShowDiffWithWorkingTree(branch.name)
                        dismiss()
                    }
                }
                if availability.contains(.rebase) {
                    Button("Rebase Current onto…") {
                        onRebase(branch.name)
                        dismiss()
                    }
                }
                if availability.contains(.merge) {
                    Button("Merge into Current…") {
                        onMerge(branch.name)
                        dismiss()
                    }
                }
                Divider()
                if availability.contains(.checkout) {
                    Button("Checkout as Local Branch") {
                        onCheckoutRemote(branch)
                        dismiss()
                    }
                }
                if availability.contains(.checkoutAsNewBranch) {
                    Button("Checkout as New Branch…") {
                        onCheckoutAsNewBranch(branch.name, true)
                        dismiss()
                    }
                }
                if availability.contains(.checkoutWithRebase) {
                    Button("Checkout with Rebase") {
                        onCheckoutRemoteWithRebase(branch)
                        dismiss()
                    }
                }
                if availability.contains(.deleteRemote) {
                    Button("Delete Remote Branch", role: .destructive) {
                        onDeleteRemote(branch)
                        dismiss()
                    }
                    .disabled(!availability.isEnabled(.deleteRemote))
                    .help(availability.disabledDescription(for: .deleteRemote) ?? "Protected remote branches cannot be deleted.")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedBranchTargetID = "single.remote:\(branch.name)"
        }
        .background(selected ? Color.accentColor.opacity(0.22) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder
    private func stashRow(_ stash: StashInfo) -> some View {
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
                Button("Apply (Keep)") { onApplyStash(stash.id, false); dismiss() }
                Button("Apply + Restore Index (Keep)") { onApplyStash(stash.id, true); dismiss() }
                Button("Pop (Apply and Remove)") { onPopStash(stash.id, false); dismiss() }
                Button("Pop + Restore Index") { onPopStash(stash.id, true); dismiss() }
                Button("Create Branch from Stash…") { onStashBranch(stash.id); dismiss() }
                Button("View Diff") { onStashDiff(stash.id); dismiss() }
                Divider()
                Button("Drop", role: .destructive) { onDropStash(stash.id); dismiss() }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private func syncStatus(for branch: RemoteBranchInfo) -> SyncStatus? {
        syncStatuses.first(where: { $0.upstream == branch.name })
    }

    private func localBranch(for branch: RemoteBranchInfo) -> BranchInfo? {
        let prefix = "\(branch.remote)/"
        guard branch.name.hasPrefix(prefix) else { return nil }
        let localName = String(branch.name.dropFirst(prefix.count))
        return branches.first(where: { $0.name == localName })
    }

    @ViewBuilder
    private func remoteSyncBadge(
        _ sync: SyncStatus,
        hasUnfetchedIncoming: Bool = false
    ) -> some View {
        if !sync.trackingExists {
            Text("未跟踪")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.orange)
        } else if sync.ahead > 0 || sync.behind > 0 || hasUnfetchedIncoming {
            HStack(spacing: 5) {
                if sync.behind > 0 {
                    Label("\(sync.behind)", systemImage: "arrow.down")
                        .foregroundStyle(.blue)
                }
                if sync.ahead > 0 {
                    Label("\(sync.ahead)", systemImage: "arrow.up")
                        .foregroundStyle(.green)
                }
                if hasUnfetchedIncoming {
                    Label("?", systemImage: "arrow.down")
                        .foregroundStyle(.blue)
                }
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .help("蓝色表示远程有更新，绿色表示本地有待推送提交")
        } else {
            Text("已同步")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func syncBadge(
        _ sync: SyncStatus,
        hasUnfetchedIncoming: Bool = false
    ) -> some View {
        if !sync.trackingExists {
            Text("Missing upstream")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.orange)
                .help("Upstream tracking branch is missing")
        } else if sync.ahead > 0 || sync.behind > 0 || hasUnfetchedIncoming {
            HStack(spacing: 5) {
                if sync.ahead > 0 {
                    Label("\(sync.ahead)", systemImage: "arrow.up")
                        .foregroundStyle(.green)
                }
                if sync.behind > 0 {
                    Label("\(sync.behind)", systemImage: "arrow.down")
                        .foregroundStyle(.blue)
                }
                if hasUnfetchedIncoming {
                    Label("?", systemImage: "arrow.down")
                        .foregroundStyle(.blue)
                }
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .help("绿色表示本地待推送提交，蓝色表示远程有更新")
        }
    }

    private var unfetchedIncomingBadge: some View {
        Label("?", systemImage: "arrow.down")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.blue)
            .help("Remote has incoming commits not fetched locally")
    }
}
