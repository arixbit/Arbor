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
    var projectOpen = false
    var logOpen = false
    let onSelect: (ToolWindowMode) -> Void
    let onOpenProject: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            // The live Log window still keeps Commit above Project. It stays
            // unselected while Log is open, with a divider under it.
            railButton("slider.horizontal.3", mode: .commit, help: "Commit", commitMark: true)
            Divider().padding(.horizontal, 6)
            Button(action: onOpenProject) {
                Image(systemName: "folder")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 28, height: 28)
                    .background(
                        projectOpen ? Color.primary.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Project")
            .accessibilityLabel("Project")
            // SwiftUI only derives an AX identifier from the symbol name on
            // newer systems, so state it explicitly for the UI smoke suite.
            .accessibilityIdentifier("folder")

            Menu {
                Button("Commit") { onSelect(.commit) }
                Button("Project") { onOpenProject() }
                Button("Git") { onSelect(.log) }
                Button("Terminal") { onSelect(.operations) }
                Divider()
                Button("Operation Log") { onSelect(.operations) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundStyle(.secondary)
            .help("More tool windows")
            .accessibilityLabel("More tool windows")
            .accessibilityIdentifier("activity-rail-more")

            Spacer()
            railButton("terminal", mode: .operations, help: "Terminal")
            // The Log editor is the main surface, not a selected tool window.
            // Rebased leaves this Git button plain while Log is open.
            railButton(
                "arrow.triangle.branch",
                mode: .log,
                help: "Git",
                branchMark: true,
                highlighted: false,
                emphasizeSelection: false
            )
        }
        .padding(.top, 4)
        .padding(.bottom, 12)
        .frame(width: 40)
        .background(Design.Colors.workspaceFrame)
    }

    func railButton(_ image: String, mode: ToolWindowMode, help: String, commitMark: Bool = false, branchMark: Bool = false, highlighted: Bool = false, emphasizeSelection: Bool = true) -> some View {
        let selected = emphasizeSelection && selectedMode == mode
        let chip = selected || highlighted
        return Button { onSelect(mode) } label: {
            Group {
                if commitMark {
                    commitRailMark()
                } else if branchMark {
                    branchMarkIcon()
                } else {
                    Image(systemName: image)
                        .font(.system(size: 15, weight: .medium))
                }
            }
            .frame(width: 28, height: 28)
            .foregroundStyle(selected && commitMark ? Color.white : (selected ? Color.primary : Color.secondary))
            .background(
                chip
                    ? (selected && commitMark ? Color.accentColor : Color.primary.opacity(selected ? 0.12 : 0.08))
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
        }
        .buttonStyle(.plain)
        .help(help)
        // Matches the identifier SwiftUI derives from the symbol name on newer
        // systems; on older ones nothing is derived and the smoke suite cannot
        // find the rail at all.
        .accessibilityIdentifier(image)
        .accessibilityLabel(LocalizedStringKey(help))
        .accessibilityAddTraits(selectedMode == mode ? .isSelected : [])
    }

    func commitRailMark() -> some View {
        Canvas { context, size in
            let midY = size.height / 2
            var line = Path()
            line.move(to: CGPoint(x: 1, y: midY))
            line.addLine(to: CGPoint(x: size.width - 1, y: midY))
            context.stroke(line, with: .foreground, lineWidth: 1.3)
            let radius: CGFloat = 4
            let circle = Path(ellipseIn: CGRect(
                x: size.width / 2 - radius,
                y: midY - radius,
                width: radius * 2,
                height: radius * 2
            ))
            context.stroke(circle, with: .foreground, lineWidth: 1.3)
        }
        .frame(width: 22, height: 16)
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
                            Section(LocalizedStringKey(sectionTitle(section))) {
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
    let onUpdate: () -> Void
    let onPush: () -> Void
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
        onUpdate: @escaping () -> Void,
        onPush: @escaping () -> Void,
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
        self.onUpdate = onUpdate
        self.onPush = onPush
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

    private func projectInitials(_ name: String) -> String {
        let parts = name.split { !$0.isLetter && !$0.isNumber }
        let letters: [Character]
        if parts.count >= 2 {
            letters = parts.prefix(2).compactMap(\.first)
        } else {
            letters = Array(name.filter { $0.isLetter || $0.isNumber }.prefix(2))
        }
        let text = String(letters).uppercased()
        return text.isEmpty ? "\u{2022}" : text
    }

    private func projectBadge(_ name: String) -> Image {
        let initials = projectInitials(name)
        let size = NSSize(width: 22, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(calibratedRed: 0.55, green: 0.73, blue: 0.45, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let string = initials as NSString
            let textSize = string.size(withAttributes: attributes)
            string.draw(
                at: NSPoint(
                    x: (rect.width - textSize.width) / 2,
                    y: (rect.height - textSize.height) / 2
                ),
                withAttributes: attributes
            )
            return true
        }
        return Image(nsImage: image)
    }

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                Button("Open Project…", action: onOpenProject)
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
                    projectBadge(projectName)
                        .accessibilityHidden(true)
                    Text(projectName)
                        .font(Design.Typography.interface(13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 240)
            .fixedSize(horizontal: true, vertical: false)
            .help(projectPath ?? projectName)

            HStack(spacing: 4) {
                toolbarButton("arrow.down.left", title: "Update", action: onUpdate)
                toolbarButton("arrow.up.right", title: "Push", action: onPush)
            }
            .disabled(!hasRepository || isLoading)

            branchMenu
                .frame(maxWidth: 260, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)

            GitMergeRebaseWidget(
                items: operationItems,
                currentOperationState: currentOperationState,
                resolvedConflictPaths: resolvedConflictPaths,
                onRevertResolved: onRevertResolved,
                onOperationAction: onOperationAction
            )

            Spacer(minLength: 24)

            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Search")
            .help("Search")

            Menu {
                AppLanguageMenu()
                SettingsLink {
                    Label("Settings…", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Settings")
            .help("Settings")
        }
        .padding(.leading, 90)
        .padding(.trailing, 12)
        .frame(height: 43)
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
        // Without an explicit label macOS exposes the SF Symbol name
        // (“Arrow Down Circle”), so VoiceOver reads the icon instead of the
        // action and the control cannot be addressed by name.
        .accessibilityLabel(title)
        .help(title)
    }
}

struct RebasedTabButtonStyle: ButtonStyle {
    let isSelected: Bool
    var tinted = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Design.Typography.interface(13, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                isSelected
                    ? (tinted ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.08))
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(
                        isSelected
                            ? (tinted ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.12))
                            : Color.clear,
                        lineWidth: 1
                    )
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

/// Repository-relative display helpers. `NSString`'s path helpers do not
/// resolve against the process working directory, unlike
/// `URL(fileURLWithPath:)`, so a row never pays a `getcwd` syscall and never
/// shows the checkout's absolute prefix for a relative change path.
func changeTreeRowName(_ path: String) -> String {
    (path as NSString).lastPathComponent
}

func changeTreeRowParentPath(_ path: String) -> String {
    let parent = (path as NSString).deletingLastPathComponent
    return parent == "." ? "" : parent
}

/// `treeRows` re-sorted every changed path and rebuilt the folder rows on
/// every body evaluation, which is what made a large change list expensive to
/// render. The rows only depend on the entries and the grouping mode, so they
/// are memoized against those inputs.
final class ChangeTreeRowsCache {
    struct Key: Equatable {
        let digest: Int
        let count: Int
        let grouped: Bool
    }

    private var key: Key?
    private var rows: [RebasedChangeGroup.TreeRow] = []

    func rows(
        for key: Key,
        build: () -> [RebasedChangeGroup.TreeRow]
    ) -> [RebasedChangeGroup.TreeRow] {
        if self.key == key { return rows }
        let built = build()
        self.key = key
        self.rows = built
        return built
    }
}

/// What the Commit panel's Expand All / Collapse All buttons can do right now.
///
/// Every change group publishes its own state and the panel aggregates them, so
/// a button that cannot change anything is disabled instead of being a
/// clickable no-op.
struct ChangeTreeExpansionState: Equatable {
    var canExpand = false
    var canCollapse = false
}

struct ChangeTreeExpansionStateKey: PreferenceKey {
    static var defaultValue = ChangeTreeExpansionState()

    static func reduce(
        value: inout ChangeTreeExpansionState,
        nextValue: () -> ChangeTreeExpansionState
    ) {
        let next = nextValue()
        value.canExpand = value.canExpand || next.canExpand
        value.canCollapse = value.canCollapse || next.canCollapse
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
    var onStagePath: (String) -> Void = { _ in }
    var onUnstagePath: (String) -> Void = { _ in }
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
    /// IntelliJ `$Delete`：从磁盘删除选中路径（不跑 `git rm`）。
    var onDeletePaths: ([String]) -> Void = { _ in }
    var onEditGitignore: () -> Void = {}
    var onEditGitExclude: () -> Void = {}
    @State var isExpanded = true
    @State var collapsedFolders: Set<String> = []
    @State var rowsCache = ChangeTreeRowsCache()

    /// Folders whose expansion is tracked inside this group.
    var folderPaths: Set<String> {
        Set(treeRows.compactMap { $0.entry == nil ? $0.path : nil })
    }

    /// What the panel-wide Expand All / Collapse All buttons can do to this
    /// group right now. A section that is already fully expanded cannot be
    /// expanded again, and an enabled button that cannot act is a clickable
    /// no-op.
    var expansionState: ChangeTreeExpansionState {
        guard !entries.isEmpty else { return ChangeTreeExpansionState() }
        return ChangeTreeExpansionState(
            canExpand: !isExpanded || !collapsedFolders.isEmpty,
            canCollapse: isExpanded
        )
    }

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
        let key = ChangeTreeRowsCache.Key(
            digest: entries.hashValue,
            count: entries.count,
            grouped: groupByDirectory
        )
        return rowsCache.rows(for: key) { buildTreeRows() }
    }

    private func buildTreeRows() -> [TreeRow] {
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
        Group {
            HStack(spacing: 6) {
                Button {
                    guard !entries.isEmpty else { return }
                    isExpanded.toggle()
                } label: {
                    Image(systemName: entries.isEmpty || !isExpanded ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10))
                        .frame(width: 12, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey(title))
                ZStack {
                    Toggle("", isOn: Binding(
                        get: { !entries.isEmpty && entries.allSatisfy(isChecked) },
                        set: { checked in entries.forEach { onToggle($0, checked) } }
                    ))
                    .labelsHidden()
                    .toggleStyle(RebasedCheckboxStyle(
                        labelsHidden: true,
                        isMixed: entries.contains(where: isChecked) && !entries.allSatisfy(isChecked)
                    ))
                    .accessibilityLabel("Include group: \(String(localized: String.LocalizationValue(title)))")
                    .disabled(entries.isEmpty)
                }
                Text(LocalizedStringKey(title))
                    .font(Design.Typography.interface(13, weight: title == "Changes" ? .semibold : .regular))
                Text(entries.count == 1 ? "1 file" : "\(entries.count) files")
                    .font(Design.Typography.interface(12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(height: 24)
            .padding(.horizontal, 4)
            .background(title == "Changes" ? Design.Colors.selection : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .padding(.top, 2)
            .onChange(of: expansionCommand) { _, _ in
                isExpanded = expansionTarget
                collapsedFolders = expansionTarget ? [] : folderPaths
            }

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
        .preference(key: ChangeTreeExpansionStateKey.self, value: expansionState)
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
                    .font(Design.Typography.interface(12, weight: .medium))
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
                .toggleStyle(RebasedCheckboxStyle(labelsHidden: true))
                .accessibilityLabel("Include \(entry.path)")
                .accessibilityHint(Text(LocalizedStringKey(
                    entry.staged != .unchanged && entry.unstaged != .unchanged ? "Partially staged" : ""
                )))

            }
            .frame(width: 16, height: 16)
            Image(systemName: repositoryFileSymbol(for: entry.path))
                .font(Design.Typography.interface(13))
                .foregroundStyle(repositoryFileIconColor(for: entry.path))
                .frame(width: 16)
            // `URL(fileURLWithPath:)` resolves relative change paths against
            // the process working directory. That both ran a `getcwd` syscall
            // for every row of every render and displayed the checkout's
            // absolute parent path instead of the repository-relative folder.
            // Change paths are already repository-relative, so split them
            // directly.
            Text(changeTreeRowName(entry.path))
                .font(Design.Typography.interface(13))
                .foregroundStyle(ChangeBadge.color(statusKind(entry)))
                .lineLimit(1)
            if !groupByDirectory {
                let parentPath = changeTreeRowParentPath(entry.path)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !parentPath.isEmpty, parentPath != "." {
                    Text(parentPath)
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
                    .help("Binary file: diff and line staging use the fallback policy")
            }
            Spacer(minLength: 4)
            if entry.staged != .unchanged && entry.unstaged != .unchanged {
                Text("Partially staged")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, CGFloat(depth) * 14 + 4)
        .frame(minHeight: 24)
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
                    onStagePath(entry.path)
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
                    onUnstagePath(entry.path)
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
                Button("Partial stage") { onPartial(entry.path) }
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
            Divider()
            Button(role: .destructive) {
                onDeletePaths(selectedPaths)
            } label: {
                Label("Delete…", systemImage: "trash")
            }
            .help("Delete the selected paths from disk. Git keeps tracking the deletion.")
        }
    }
}

/// Outlined actions, plus the filled Commit button.
/// The live reference keeps Commit blue even while the readiness hint is showing.
/// Rebased's Show Diff mark is a left-pointing arrow stacked above a
/// right-pointing arrow, not the diagonal expand pair.
func showDiffIcon() -> Image {
    let size = NSSize(width: 16, height: 16)
    let image = NSImage(size: size, flipped: false) { _ in
        NSColor.black.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.35
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: NSPoint(x: 13.4, y: 11.4))
        path.line(to: NSPoint(x: 3.0, y: 11.4))
        path.move(to: NSPoint(x: 5.6, y: 13.8))
        path.line(to: NSPoint(x: 2.8, y: 11.4))
        path.line(to: NSPoint(x: 5.6, y: 9.0))
        path.move(to: NSPoint(x: 2.6, y: 4.4))
        path.line(to: NSPoint(x: 13.0, y: 4.4))
        path.move(to: NSPoint(x: 10.4, y: 6.8))
        path.line(to: NSPoint(x: 13.2, y: 4.4))
        path.line(to: NSPoint(x: 10.4, y: 2.0))
        path.stroke()
        return true
    }
    image.isTemplate = true
    return Image(nsImage: image)
}

func eyeMenuIcon() -> Image {
    let size = NSSize(width: 18, height: 16)
    let image = NSImage(size: size, flipped: false) { _ in
        let symbol = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
        let configured = symbol?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        )
        configured?.draw(
            in: NSRect(x: 0, y: 1.5, width: 15, height: 12),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        let mark = NSBezierPath()
        mark.move(to: NSPoint(x: 12.6, y: 4.4))
        mark.line(to: NSPoint(x: 17.2, y: 0.6))
        mark.line(to: NSPoint(x: 12.6, y: 0.6))
        mark.close()
        NSColor.secondaryLabelColor.setFill()
        mark.fill()
        return true
    }
    image.isTemplate = false
    return Image(nsImage: image)
}

extension View {
    /// IntelliJ icon menus keep a tiny corner triangle instead of a separate chevron.
    func rebasedMenuCorner() -> some View {
        overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 5.5))
                .foregroundStyle(.secondary)
                .padding(.trailing, 1)
                .padding(.bottom, 1)
                .allowsHitTesting(false)
        }
    }
}

struct RebasedActionButtonStyle: ButtonStyle {
    var prominent = false
    var dimsWhenDisabled = true
    var height: CGFloat = 28
    var minWidth: CGFloat? = nil
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Design.Typography.interface(13, weight: prominent ? .medium : .regular))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .frame(minWidth: minWidth)
            .frame(height: height)
            .background(background(isPressed: configuration.isPressed),
                        in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                if !prominent {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(.separator, lineWidth: 1)
                }
            }
            .opacity(prominent || isEnabled || !dimsWhenDisabled ? 1 : 0.45)
    }

    private func background(isPressed: Bool) -> Color {
        if prominent {
            return Design.Colors.accent.opacity(isPressed ? 0.85 : 1)
        }
        return isPressed ? Color.primary.opacity(0.06) : Color.clear
    }
}

/// Outline artwork with native Toggle semantics for VoiceOver and UI automation.
struct RebasedCheckboxStyle: ToggleStyle {
    var labelsHidden = false
    var isMixed = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(configuration.isOn || isMixed ? Color.accentColor : Color.clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(configuration.isOn || isMixed ? Color.accentColor : Design.Colors.checkboxBorder, lineWidth: 1)
                    }
                    .overlay {
                        if isMixed {
                            Rectangle().fill(.white).frame(width: 8, height: 2)
                        } else if configuration.isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 16, height: 16)
                if !labelsHidden { configuration.label }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.checkbox)
        }
    }
}
