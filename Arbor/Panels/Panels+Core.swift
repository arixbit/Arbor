import SwiftUI
import AppKit
import UniformTypeIdentifiers

import SwiftUI
import AppKit

func tokenizeGitCommandLine(_ value: String) -> [String] {
    var result: [String] = []
    var token = ""
    var quote: Character?
    var escaping = false
    for character in value {
        if escaping {
            token.append(character)
            escaping = false
        } else if character == "\\" && quote != "'" {
            escaping = true
        } else if quote != nil {
            if character == quote! { quote = nil }
            else { token.append(character) }
        } else if character == "'" || character == "\"" {
            quote = character
        } else if character.isWhitespace {
            if !token.isEmpty { result.append(token); token = "" }
        } else {
            token.append(character)
        }
    }
    if !token.isEmpty { result.append(token) }
    return result
}

/// Rebased 的主窗口视觉骨架：窄工具栏、Git 工具窗、Project 工具窗和编辑区。
/// 这些视图只负责页面编排，实际 Git 操作仍由 ContentView/WorkspaceOperations 提供。

struct RebasedActivityRail: View {
    let selectedMode: ToolWindowMode
    let onSelect: (ToolWindowMode) -> Void
    let onOpenProject: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            railButton("checkmark.circle", mode: .commit, help: "Commit")
            railButton("clock", mode: .log, help: "Log")
            railButton("list.bullet.rectangle", mode: .operations, help: "Operation Log")

            Divider()
                .padding(.vertical, 4)

            Button(action: onOpenProject) {
                Image(systemName: "folder")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Project")

            Spacer()

            Menu {
                Button("Commit") { onSelect(.commit) }
                Button("Log") { onSelect(.log) }
                Button("Operation Log") { onSelect(.operations) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(.secondary)
            .help("More tool windows")
        }
        .padding(.top, 18)
        .padding(.bottom, 12)
        .frame(width: 52)
        .background(Design.Colors.chrome)
    }

    func railButton(_ image: String, mode: ToolWindowMode, help: String) -> some View {
        Button { onSelect(mode) } label: {
            Image(systemName: image)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 34)
                .background(
                    selectedMode == mode
                        ? Color.primary.opacity(0.12)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(selectedMode == mode ? .primary : .secondary)
        .help(help)
    }
}

/// Searchable, keyboard-friendly equivalent of IntelliJ's
/// `VcsQuickListPopupAction`. The regular More Git Actions menu remains
/// available for pointer-first use; this surface provides one stable action
/// list for search, arrow-key navigation, and Return activation.
@MainActor
final class VCSQuickActionsPanelCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    var windowController: NSWindowController?
    var hostingView: NSHostingView<VCSQuickActionsView>?
    var onAction: ((ArborVCSAction) -> Void)?
    private(set) var panelWindow: NSPanel?
    private(set) var isPresented = false

    func present(
        items: [VCSQuickActionItem],
        onAction: @escaping (ArborVCSAction) -> Void
    ) {
        self.onAction = onAction
        if let window = windowController?.window {
            hostingView?.rootView = makeRootView(items: items)
            isPresented = true
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Quick Git Actions"
        window.identifier = NSUserInterfaceItemIdentifier("arbor.vcs-quick-actions")
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.delegate = self
        let hostingView = NSHostingView(rootView: makeRootView(items: items))
        hostingView.frame = NSRect(
            origin: .zero,
            size: window.contentRect(forFrameRect: window.frame).size
        )
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
        self.hostingView = hostingView
        panelWindow = window
        isPresented = true
        windowController = NSWindowController(window: window)
        window.center()
        windowController?.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        windowController?.close()
        isPresented = false
    }

    func windowWillClose(_ notification: Notification) {
        windowController = nil
        hostingView = nil
        onAction = nil
        panelWindow = nil
        isPresented = false
    }

    func makeRootView(items: [VCSQuickActionItem]) -> VCSQuickActionsView {
        VCSQuickActionsView(
            items: items,
            onAction: { [weak self] action in
                guard let self else { return }
                let actionHandler = self.onAction
                self.close()
                actionHandler?(action)
            },
            onDismiss: { [weak self] in
                self?.close()
            },
            sessionID: UUID()
        )
    }
}

struct VCSQuickActionsView: View {
    let items: [VCSQuickActionItem]
    let onAction: (ArborVCSAction) -> Void
    let onDismiss: () -> Void
    let sessionID: UUID

    init(
        items: [VCSQuickActionItem],
        onAction: @escaping (ArborVCSAction) -> Void,
        onDismiss: @escaping () -> Void,
        sessionID: UUID = UUID()
    ) {
        self.items = items
        self.onAction = onAction
        self.onDismiss = onDismiss
        self.sessionID = sessionID
    }

    @State var query = ""
    @State var selection: String?

    var filteredItems: [VCSQuickActionItem] {
        filteredVCSQuickActionItems(items, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Git actions", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit(runSelected)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(12)
            .background(.regularMaterial)

            Divider()

            if filteredItems.isEmpty {
                ContentUnavailableView(
                    "No Git actions",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different search.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(VCSQuickActionItem.Section.allCases, id: \.self) { section in
                        let sectionItems = filteredItems.filter { $0.section == section }
                        if !sectionItems.isEmpty {
                            Section(sectionTitle(section)) {
                                ForEach(sectionItems) { item in
                                    Button {
                                        run(item)
                                    } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: item.systemImage)
                                                .frame(width: 18)
                                                .foregroundStyle(item.isEnabled ? .primary : .secondary)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(item.title)
                                                    .foregroundStyle(item.isEnabled ? .primary : .secondary)
                                                Text(item.subtitle)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                            Spacer(minLength: 8)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .tag(item.id)
                                    .disabled(!item.isEnabled)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .onSubmit(runSelected)
            }

            Divider()
            HStack(spacing: 12) {
                Text("↑↓ Select")
                Text("Return Run")
                Spacer()
                Button("Cancel", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .id(sessionID)
        .frame(width: 520, height: 460)
        .onAppear {
            selection = filteredItems.first?.id
        }
        .onChange(of: query) { _, _ in
            if let selection, filteredItems.contains(where: { $0.id == selection }) {
                return
            }
            selection = filteredItems.first?.id
        }
        .onMoveCommand { direction in
            let enabledItems = filteredItems.filter(\.isEnabled)
            guard !enabledItems.isEmpty else { return }
            let currentIndex = enabledItems.firstIndex { $0.id == selection } ?? 0
            let nextIndex: Int
            switch direction {
            case .up:
                nextIndex = max(0, currentIndex - 1)
            case .down:
                nextIndex = min(enabledItems.count - 1, currentIndex + 1)
            default:
                return
            }
            selection = enabledItems[nextIndex].id
        }
        .onExitCommand(perform: onDismiss)
    }

    func sectionTitle(_ section: VCSQuickActionItem.Section) -> String {
        switch section {
        case .commit: "Commit"
        case .repository: "Repository"
        case .workspace: "Workspace"
        }
    }

    func runSelected() {
        guard let selection,
              let item = filteredItems.first(where: { $0.id == selection }) else { return }
        run(item)
    }

    func run(_ item: VCSQuickActionItem) {
        guard item.isEnabled else { return }
        onAction(item.action)
    }
}

struct RebasedTopBar<BranchMenu: View>: View {
    let projectName: String
    let projectPath: String?
    let currentBranch: String
    let hasRepository: Bool
    let isLoading: Bool
    let onOpenProject: () -> Void
    let onRefresh: () -> Void
    let onUpdate: () -> Void
    let onCommit: () -> Void
    let onPush: () -> Void
    let onFetch: () -> Void
    let onHosting: () -> Void
    let isShallowRepository: Bool
    let hasCurrentBranch: Bool
    let hasConflicts: Bool
    let onQuickAction: (ArborVCSAction) -> Void
    let onSearch: () -> Void
    let recentProjects: [String]
    let onOpenRecent: (String) -> Void
    let operationItems: [GitMergeRebaseWidgetItem]
    let currentOperationState: OperationState?
    let resolvedConflictPaths: [String]
    let onRevertResolved: (String) -> Void
    let onOperationAction: (
        ArborVCSActionRequest.OperationRecoveryAction,
        String
    ) -> Void
    let branchMenu: BranchMenu

    init(
        projectName: String,
        projectPath: String?,
        currentBranch: String,
        hasRepository: Bool,
        isLoading: Bool,
        onOpenProject: @escaping () -> Void,
        onRefresh: @escaping () -> Void,
        onUpdate: @escaping () -> Void,
        onCommit: @escaping () -> Void,
        onPush: @escaping () -> Void,
        onFetch: @escaping () -> Void,
        onHosting: @escaping () -> Void = {},
        isShallowRepository: Bool = false,
        hasCurrentBranch: Bool = false,
        hasConflicts: Bool = false,
        onQuickAction: @escaping (ArborVCSAction) -> Void = { _ in },
        onSearch: @escaping () -> Void,
        recentProjects: [String] = [],
        onOpenRecent: @escaping (String) -> Void = { _ in },
        operationItems: [GitMergeRebaseWidgetItem] = [],
        currentOperationState: OperationState? = nil,
        resolvedConflictPaths: [String] = [],
        onRevertResolved: @escaping (String) -> Void = { _ in },
        onOperationAction: @escaping (
            ArborVCSActionRequest.OperationRecoveryAction,
            String
        ) -> Void = { _, _ in },
        @ViewBuilder branchMenu: () -> BranchMenu
    ) {
        self.projectName = projectName
        self.projectPath = projectPath
        self.currentBranch = currentBranch
        self.hasRepository = hasRepository
        self.isLoading = isLoading
        self.onOpenProject = onOpenProject
        self.onRefresh = onRefresh
        self.onUpdate = onUpdate
        self.onCommit = onCommit
        self.onPush = onPush
        self.onFetch = onFetch
        self.onHosting = onHosting
        self.isShallowRepository = isShallowRepository
        self.hasCurrentBranch = hasCurrentBranch
        self.hasConflicts = hasConflicts
        self.onQuickAction = onQuickAction
        self.onSearch = onSearch
        self.recentProjects = recentProjects
        self.onOpenRecent = onOpenRecent
        self.operationItems = operationItems
        self.currentOperationState = currentOperationState
        self.resolvedConflictPaths = resolvedConflictPaths
        self.onRevertResolved = onRevertResolved
        self.onOperationAction = onOperationAction
        self.branchMenu = branchMenu()
    }

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                Button("打开项目…", action: onOpenProject)
                if !recentProjects.isEmpty {
                    Divider()
                    ForEach(recentProjects, id: \.self) { recentPath in
                        Button(URL(fileURLWithPath: recentPath).lastPathComponent) {
                            onOpenRecent(recentPath)
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(projectName)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        if let projectPath {
                            Text(projectPath)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .help("Open project")

            Divider().frame(height: 22)

            branchMenu

            GitMergeRebaseWidget(
                items: operationItems,
                currentOperationState: currentOperationState,
                resolvedConflictPaths: resolvedConflictPaths,
                onRevertResolved: onRevertResolved,
                onOperationAction: onOperationAction
            )

            Spacer(minLength: 24)

            HStack(spacing: 4) {
                toolbarButton("arrow.down.circle", title: "Update", action: onUpdate)
                toolbarButton("checkmark.circle", title: "Commit", action: onCommit)
                toolbarButton("arrow.up.circle", title: "Push", action: onPush)
                toolbarButton("arrow.triangle.2.circlepath", title: "Fetch", action: onFetch)
            }
            .disabled(!hasRepository || isLoading)

            Menu("More Git Actions") {
                Button("Quick Git Actions…") { onQuickAction(.quickActions) }
                Divider()
                Button("Show Log") { onQuickAction(.showLog) }
                Button("Operation Log") { onQuickAction(.showOperations) }
                Button("Pull Requests & Reviews") { onHosting() }
                Button("Git Roots") { onQuickAction(.showGitRoots) }
                Button("Git Console") { onQuickAction(.showGitConsole) }
                Divider()
                Button("Branches…") { onQuickAction(.branches) }
                Button("Push…") { onQuickAction(.push) }
                Divider()
                Button("Stash…") { onQuickAction(.stash) }
                Button("Unstash Changes…") { onQuickAction(.unstash) }
                Button("Worktrees") { onQuickAction(.worktrees) }
                Divider()
                Button("Stage changes") { onQuickAction(.stageTracked) }
                Button("Stage all changes") { onQuickAction(.stageAll) }
                Button("Copy Current Branch Name") {
                    onQuickAction(.copyCurrentBranchName)
                }
                .disabled(!hasCurrentBranch)
                Divider()
                Button("Resolve Conflicts") { onQuickAction(.resolveConflicts) }
                    .disabled(!hasConflicts)
                if isShallowRepository {
                    Divider()
                    Button("Fetch Full History…") { onQuickAction(.fetchUnshallow) }
                }
            }
            .menuStyle(.borderlessButton)
            .disabled(!hasRepository || isLoading)
            .help("More Git Actions")

            Button(action: onRefresh) {
                Image(systemName: isLoading ? "progress.indicator" : "arrow.clockwise")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!hasRepository || isLoading)
            .help("Refresh")

            AppLanguageMenu()

            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Search")
        }
        .padding(.leading, 70)
        .padding(.trailing, 18)
        .padding(.vertical, 10)
        .background(Design.Colors.chromeElevated)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    func toolbarButton(_ image: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(title)
    }
}

struct RebasedTabButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 2)
            .padding(.vertical, 10)
            .background(Color.clear)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isSelected ? Color.accentColor : Color.clear)
                    .frame(height: 2)
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

struct RebasedChangeGroup: View {
    let title: String
    let entries: [FileEntry]
    let changeListName: String
    let changeLists: [ChangeListInfo]
    var emptyLabel: LocalizedStringKey = "No files"
    let statusKind: (FileEntry) -> ChangeKind
    let isChecked: (FileEntry) -> Bool
    let onToggle: (FileEntry, Bool) -> Void
    var onStageWithoutContent: (String) -> Void = { _ in }
    let onSelect: (String) -> Void
    let onPreviewPath: (String) -> Void
    let onShowDiffPath: (String) -> Void
    var onShowLocalStagedDiffPath: (String) -> Void = { _ in }
    var onShowLocalVersionPath: (String) -> Void = { _ in }
    var onShowStagedVersionPath: (String) -> Void = { _ in }
    var onShowStagedDiffPath: (String) -> Void = { _ in }
    var onShowThreeVersionsPath: (String) -> Void = { _ in }
    let selectedPath: String?
    let onPartial: (String) -> Void
    let binaryPaths: Set<String>
    var lfsTrackedPaths: Set<String> = []
    var lfsPointerPaths: Set<String> = []
    var stagingPresence: [String: StagingVersionPresence] = [:]
    @Binding var contextSelectedPaths: Set<String>
    let contextEligiblePaths: Set<String>
    let onIgnore: ([String], String?) -> Void
    let onExclude: ([String]) -> Void
    let repositoryWorkdir: String?
    var onRestore: ((String) -> Void)? = nil
    var groupByDirectory: Bool = true
    var expansionCommand: Int = 0
    var expansionTarget: Bool = true
    var onDropPaths: (([String]) -> Void)? = nil
    var onDropShelf: ((String) -> Void)? = nil
    var onDropShelfIntoChangeList: ((String, [String]?, String) -> Void)? = nil
    var onMovePathsToChangeList: (([String], String) -> Void)? = nil
    var onStashPaths: ([String]) -> Void = { _ in }
    var onShowHistory: (String) -> Void = { _ in }
    var onEditGitignore: () -> Void = {}
    var onEditGitExclude: () -> Void = {}
    @State var isExpanded = true
    @State var collapsedFolders: Set<String> = []

    struct TreeRow: Identifiable {
        let id: String
        let name: String
        let path: String
        let depth: Int
        let entry: FileEntry?

        var isFolder: Bool { entry == nil }
    }

    /// ChangesTree is hierarchical. Build the directory rows once from the
    /// same status entries instead of showing a basename followed by a
    /// truncated parent path; the latter loses the tree affordance and makes
    /// two files with the same basename indistinguishable.
    var treeRows: [TreeRow] {
        let sortedEntries = entries.sorted {
            intellijFilePathCompare(
                $0.path,
                $1.path,
                flattened: !groupByDirectory
            ) == .orderedAscending
        }
        guard groupByDirectory else {
            return sortedEntries.map { entry in
                TreeRow(
                    id: "file:\(entry.path)",
                    name: entry.path,
                    path: entry.path,
                    depth: 0,
                    entry: entry
                )
            }
        }
        var rows: [TreeRow] = []
        var folders = Set<String>()

        for entry in sortedEntries {
            let components = entry.path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }

            if components.count > 1 {
                var prefix = ""
                for (index, component) in components.dropLast().enumerated() {
                    prefix = prefix.isEmpty ? component : "\(prefix)/\(component)"
                    if folders.insert(prefix).inserted {
                        rows.append(TreeRow(
                            id: "folder:\(prefix)",
                            name: component,
                            path: prefix,
                            depth: index,
                            entry: nil
                        ))
                    }
                }
            }

            rows.append(TreeRow(
                id: "file:\(entry.path)",
                name: components.last ?? entry.path,
                path: entry.path,
                depth: max(0, components.count - 1),
                entry: entry
            ))
        }
        return rows
    }

    var visibleTreeRows: [TreeRow] {
        treeRows.filter { row in
            guard row.depth > 0 else { return true }
            let components = row.path.split(separator: "/").map(String.init)
            guard components.count > 1 else { return true }
            return !components.dropLast().indices.contains { index in
                let prefix = components.prefix(index + 1).joined(separator: "/")
                return collapsedFolders.contains(prefix)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                guard !entries.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: entries.isEmpty || !isExpanded ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.bold))
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(entries.count) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            if entries.isEmpty {
                Text(emptyLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
            } else if isExpanded {
                ForEach(visibleTreeRows) { row in
                    if let entry = row.entry {
                        fileRow(entry, depth: row.depth)
                    } else {
                        folderRow(row)
                    }
                }
            }
        }
        .dropDestination(for: String.self) { paths, _ in
            if let shelfPayload = paths.compactMap(parseShelfDropPayload).first {
                switch shelfPayload {
                case let .shelf(name):
                    if let onDropShelfIntoChangeList {
                        onDropShelfIntoChangeList(name, nil, changeListName)
                    } else if let onDropShelf {
                        onDropShelf(name)
                    } else {
                        return false
                    }
                case let .member(shelf, path):
                    guard let onDropShelfIntoChangeList else { return false }
                    onDropShelfIntoChangeList(shelf, [path], changeListName)
                }
                return true
            }
            let filePaths = paths.filter { !$0.hasPrefix("arbor-shelf") }
            guard let onDropPaths, !filePaths.isEmpty else { return false }
            onDropPaths(filePaths)
            return true
        }
        .onChange(of: expansionCommand) { _, _ in
            isExpanded = expansionTarget
            collapsedFolders = expansionTarget
                ? []
                : Set(treeRows.filter { $0.entry == nil }.map(\.path))
        }
    }

    func folderRow(_ row: TreeRow) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                if collapsedFolders.contains(row.path) {
                    collapsedFolders.remove(row.path)
                } else {
                    collapsedFolders.insert(row.path)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsedFolders.contains(row.path) ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.bold))
                    .frame(width: 12)
                Image(systemName: collapsedFolders.contains(row.path) ? "folder" : "folder.fill")
                    .foregroundStyle(.secondary)
                Text(row.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.leading, CGFloat(row.depth) * 14)
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    func fileRow(_ entry: FileEntry, depth: Int) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Toggle("", isOn: Binding(
                    get: { isChecked(entry) },
                    set: { onToggle(entry, $0) }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)

                // A file with both index and worktree changes is represented
                // in both GitStageTree groups. The unstaged-side checkbox is
                // indeterminate, not simply empty; otherwise the user cannot
                // tell a partially staged file from a wholly unstaged one.
                if !isChecked(entry),
                   entry.staged != .unchanged,
                   entry.unstaged != .unchanged {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor)
                        .frame(width: 12, height: 12)
                        .overlay {
                            Rectangle()
                                .fill(Color.white)
                                .frame(width: 6, height: 2)
                        }
                        .allowsHitTesting(false)
                }
            }
            .frame(width: 16, height: 16)
            StatusBadge(kind: statusKind(entry))
            let fileURL = URL(fileURLWithPath: entry.path)
            Text(groupByDirectory ? fileURL.lastPathComponent : entry.path)
                .lineLimit(1)
            if groupByDirectory {
                let parentPath = fileURL.deletingLastPathComponent().path
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !parentPath.isEmpty, parentPath != "." {
                    Text("/\(parentPath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    .truncationMode(.middle)
                }
            }
            if let oldPath = entry.oldPath {
                Text("← \(oldPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Renamed from \(oldPath)")
            }
            if lfsTrackedPaths.contains(entry.path) {
                let isPointer = lfsPointerPaths.contains(entry.path)
                Text(isPointer ? "LFS ↓" : "LFS")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(isPointer ? Color.orange : Color.purple)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .help(isPointer
                          ? "Git LFS 文件：工作区仍是 pointer，内容尚未下载"
                          : "Git LFS 文件：内容已在工作区")
            }
            if binaryPaths.contains(entry.path) {
                Text("BIN")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .help("二进制文件：diff/行级暂存按降级策略处理")
            }
            Spacer(minLength: 4)
            Button(action: { onPartial(entry.path) }) {
                Image(systemName: "ellipsis")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Partial stage")
        }
        .padding(.leading, CGFloat(depth) * 14 + 4)
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(
            selectedPath == entry.path
                ? Color.accentColor.opacity(0.16)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .contentShape(Rectangle())
        .draggable(entry.path)
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                if contextSelectedPaths.contains(entry.path) {
                    contextSelectedPaths.remove(entry.path)
                } else {
                    contextSelectedPaths.insert(entry.path)
                }
            } else {
                contextSelectedPaths = [entry.path]
            }
            onSelect(entry.path)
        }
        .onTapGesture(count: 2) { onPreviewPath(entry.path) }
        .contextMenu {
            let selectedPaths = contextSelectedPaths.contains(entry.path)
                ? contextSelectedPaths.intersection(contextEligiblePaths).sorted()
                : [entry.path]
            if entry.unstaged != .unchanged,
               entry.unstaged != .ignored,
               entry.unstaged != .conflicted {
                Button {
                    onToggle(entry, true)
                } label: {
                    Label("Stage", systemImage: "arrow.right.circle")
                }
            }
            if entry.unstaged == .untracked {
                Button {
                    onStageWithoutContent(entry.path)
                } label: {
                    Label("Stage Without Content", systemImage: "doc.badge.plus")
                }
            }
            if entry.staged != .unchanged,
               entry.staged != .conflicted {
                Button {
                    onToggle(entry, false)
                } label: {
                    Label("Unstage", systemImage: "arrow.left.circle")
                }
            }
            if entry.unstaged != .unchanged || entry.staged != .unchanged {
                Divider()
                Button {
                    onShowDiffPath(entry.path)
                } label: {
                    Label("Show Diff", systemImage: "doc.text.magnifyingglass")
                }
                let presence = stagingPresence[entry.path]
                let versionActions = stagingVersionActions(for: entry, presence: presence)
                if versionActions.contains(.local) {
                    Button {
                        onShowLocalVersionPath(entry.path)
                    } label: {
                        Label("Show Local Version", systemImage: "doc.text")
                    }
                }
                if versionActions.contains(.staged) {
                    Button {
                        onShowStagedVersionPath(entry.path)
                    } label: {
                        Label("Show Staged Version", systemImage: "square.and.arrow.down")
                    }
                }
                if entry.unstaged != .ignored,
                   entry.unstaged != .conflicted,
                   entry.staged != .conflicted {
                    Button {
                        onStashPaths([entry.path])
                    } label: {
                        Label("Stash Selected Files…", systemImage: "tray.and.arrow.down")
                    }
                }
                let comparisonActions = stagingComparisonActions(for: entry, presence: presence)
                if comparisonActions.contains(.localWithStaged) {
                    Divider()
                    Button("Compare Local with Staged") {
                        onShowLocalStagedDiffPath(entry.path)
                    }
                    Button("Compare Staged with Local") {
                        onShowDiffPath(entry.path)
                    }
                    Button("Compare Three Versions") {
                        onShowThreeVersionsPath(entry.path)
                    }
                }
                if comparisonActions.contains(.stagedWithHead) {
                    if !comparisonActions.contains(.localWithStaged) {
                        Divider()
                    }
                    Button("Compare Staged with HEAD") {
                        onShowStagedDiffPath(entry.path)
                    }
                }
            }
            if changeLists.count > 1, let onMovePathsToChangeList {
                Menu("Move to Changelist") {
                    ForEach(changeLists, id: \.name) { list in
                        Button {
                            guard list.name != changeListName else { return }
                            onMovePathsToChangeList([entry.path], list.name)
                        } label: {
                            if list.name == changeListName {
                                Label(list.name, systemImage: "checkmark")
                            } else {
                                Text(list.name)
                            }
                        }
                    }
                }
            }
            if gitIgnoreActionAvailable(for: entry) {
                let candidates = repositoryWorkdir.map {
                    gitIgnoreFileCandidates(for: selectedPaths, workdir: $0)
                } ?? []
                if candidates.count > 1, let workdir = repositoryWorkdir {
                    Menu("Ignore in…") {
                        ForEach(candidates, id: \.self) { candidate in
                            Button(gitIgnoreFileDisplayName(candidate, workdir: workdir)) {
                                onIgnore(selectedPaths, candidate)
                            }
                        }
                    }
                } else {
                    Button {
                        onIgnore(selectedPaths, candidates.first)
                    } label: {
                        Label(
                            candidates.count == 1 ? "Ignore in .gitignore" : "Ignore (add to .gitignore)",
                            systemImage: "hand.raised"
                        )
                    }
                }
                Button {
                    onExclude(selectedPaths)
                } label: {
                    Label("Exclude (.git/info/exclude)", systemImage: "eye.slash")
                }
            }
            if let onRestore {
                Divider()
                Button("Restore from HEAD", role: .destructive) {
                    onRestore(entry.path)
                }
                .disabled(entry.unstaged == .untracked || entry.unstaged == .ignored)
            }
            Divider()
            Button {
                onShowHistory(entry.path)
            } label: {
                Label("Show History", systemImage: "clock.arrow.circlepath")
            }
            Button {
                onEditGitignore()
            } label: {
                Label("Edit .gitignore", systemImage: "doc.text")
            }
            Button {
                onEditGitExclude()
            } label: {
                Label("Edit .git/info/exclude", systemImage: "doc.text.magnifyingglass")
            }
        }
    }
}
