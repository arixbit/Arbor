import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {


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
        BranchDirectoryGroupRow(
            row: row,
            collapsedGroups: $collapsedDirectoryGroups,
            style: .log
        )
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
        let updated = toggledBranchFavoriteIDs(selection, current: favoriteReferenceIDs)
        favoriteReferenceIDs = updated
        GitBranchesPopupSettings.saveFavorites(updated, for: projectPath)
    }
}
}
