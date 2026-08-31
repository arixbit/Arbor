import SwiftUI
import AppKit

enum ShelfViewSettings {
    private static let keyPrefix = "arbor.commit.shelves.project.v2:"
    private static let showRecycledKey = "showRecycled"
    private static let removeAppliedKey = "removeAppliedFilesFromShelf"
    private static let shelvesExpandedKey = "shelvesExpanded"
    private static let groupByDirectoryKey = "groupByDirectory"
    private static let deletedShelvesExpandedKey = "deletedShelvesExpanded"

    private static func baseKey(for projectPath: String?) -> String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        guard let data = normalized.data(using: .utf8) else { return nil }
        return "\(keyPrefix)\(data.base64EncodedString())"
    }

    private static func key(for projectPath: String?) -> String? {
        guard let baseKey = baseKey(for: projectPath) else { return nil }
        return "\(baseKey):\(showRecycledKey)"
    }

    static func showRecycled(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let key = key(for: projectPath),
              defaults.object(forKey: key) != nil else { return false }
        return defaults.bool(forKey: key)
    }

    static func saveShowRecycled(
        _ value: Bool,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = key(for: projectPath) else { return }
        defaults.set(value, forKey: key)
    }

    static func removeAppliedFilesFromShelf(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let baseKey = baseKey(for: projectPath) else { return false }
        let key = "\(baseKey):\(removeAppliedKey)"
        return defaults.object(forKey: key) != nil && defaults.bool(forKey: key)
    }

    static func saveRemoveAppliedFilesFromShelf(
        _ value: Bool,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let baseKey = baseKey(for: projectPath) else { return }
        defaults.set(value, forKey: "\(baseKey):\(removeAppliedKey)")
    }

    static func shelvesExpanded(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        value(for: shelvesExpandedKey, projectPath: projectPath, defaultValue: true, defaults: defaults)
    }

    static func saveShelvesExpanded(
        _ value: Bool,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        save(value, for: shelvesExpandedKey, projectPath: projectPath, defaults: defaults)
    }

    static func groupByDirectory(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        value(for: groupByDirectoryKey, projectPath: projectPath, defaultValue: true, defaults: defaults)
    }

    static func saveGroupByDirectory(
        _ value: Bool,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        save(value, for: groupByDirectoryKey, projectPath: projectPath, defaults: defaults)
    }

    static func deletedShelvesExpanded(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        value(for: deletedShelvesExpandedKey, projectPath: projectPath, defaultValue: true, defaults: defaults)
    }

    static func saveDeletedShelvesExpanded(
        _ value: Bool,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        save(value, for: deletedShelvesExpandedKey, projectPath: projectPath, defaults: defaults)
    }

    private static func value(
        for suffix: String,
        projectPath: String?,
        defaultValue: Bool,
        defaults: UserDefaults
    ) -> Bool {
        guard let baseKey = baseKey(for: projectPath) else { return defaultValue }
        let key = "\(baseKey):\(suffix)"
        return defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }

    private static func save(
        _ value: Bool,
        for suffix: String,
        projectPath: String?,
        defaults: UserDefaults
    ) {
        guard let baseKey = baseKey(for: projectPath) else { return }
        defaults.set(value, forKey: "\(baseKey):\(suffix)")
    }
}

enum GitStageViewSettings {
    private static let keyPrefix = "arbor.git.stage.ui.project.v1:"
    private static let ignoredFilesShownKey = "ignoredFilesShown"

    private static func key(for projectPath: String?) -> String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        guard let data = normalized.data(using: .utf8) else { return nil }
        return "\(keyPrefix)\(data.base64EncodedString()):\(ignoredFilesShownKey)"
    }

    static func ignoredFilesShown(
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let key = key(for: projectPath) else { return true }
        return defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }

    static func saveIgnoredFilesShown(
        _ value: Bool,
        for projectPath: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let key = key(for: projectPath) else { return }
        defaults.set(value, forKey: key)
    }
}

enum GitStashViewSettings {
    static let splitPreviewKey = "arbor.git.stash.splitPreview.v1"
    static let defaultSplitPreview = true

    static func splitPreview(
        from defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.object(forKey: splitPreviewKey) == nil
            ? defaultSplitPreview
            : defaults.bool(forKey: splitPreviewKey)
    }

    static func saveSplitPreview(
        _ value: Bool,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(value, forKey: splitPreviewKey)
    }
}

private func shelfTimestampLabel(_ timestamp: Int64) -> String {
    guard timestamp > 0 else { return "" }
    return Date(timeIntervalSince1970: TimeInterval(timestamp))
        .formatted(date: .abbreviated, time: .shortened)
}

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

struct GitConsoleView: View {
    let result: GitCommandResult?
    let onRun: (String, [String]) -> Void
    let onClear: () -> Void
    @State private var commandLine = "status --short"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .foregroundStyle(Design.Colors.accent)
                Text("Git Console")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("清除", action: onClear)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            HStack(spacing: 8) {
                Text("git")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField("command and arguments", text: $commandLine)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(run)
                Button("运行", action: run)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Text("命令按参数执行，不经过 shell；复杂参数请使用引号。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
            Divider()
            if let result {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: result.exitCode == 0 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(result.exitCode == 0 ? .green : .red)
                            Text(result.command)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Text("exit \(result.exitCode) · \(result.durationMs) ms")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !result.stdout.isEmpty {
                            consoleOutput(title: "stdout", value: result.stdout, color: .primary)
                        }
                        if !result.stderr.isEmpty {
                            consoleOutput(title: "stderr", value: result.stderr, color: .red)
                        }
                        if result.stdout.isEmpty && result.stderr.isEmpty {
                            Text("(no output)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView(
                    "暂无命令结果",
                    systemImage: "terminal",
                    description: Text("输入 Git 子命令后运行，完整 stdout/stderr 会保留在操作历史中。")
                )
            }
        }
        .background(Design.Colors.canvas)
    }

    private func consoleOutput(title: String, value: String, color: Color) -> some View {
        DisclosureGroup(title) {
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(10)
                .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func run() {
        let tokens = tokenizeGitCommandLine(commandLine)
        guard let command = tokens.first else { return }
        onRun(command, Array(tokens.dropFirst()))
    }

}

struct WorktreePanel: View {
    let worktrees: [WorktreeInfo]
    let feedback: String?
    let onRefresh: () -> Void
    let onCreate: (String, String, String) -> Void
    let onOpen: (String) -> Void
    let onRemove: (String, Bool) -> Void
    let onLock: (String) -> Void
    let onUnlock: (String) -> Void
    let onPrune: () -> Void
    @State private var path = ""
    @State private var branch = ""
    @State private var revision = ""

    private var occupiedBranches: Set<String> {
        Set(worktrees.map(\.branch).filter { !$0.isEmpty })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.split.2x1")
                    .foregroundStyle(Design.Colors.accent)
                Text("Worktrees")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(worktrees.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Prune", action: onPrune)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("新 worktree 路径", text: $path)
                        .textFieldStyle(.roundedBorder)
                    TextField("新分支（可选）", text: $branch)
                        .textFieldStyle(.roundedBorder)
                    TextField("revision（可选）", text: $revision)
                        .textFieldStyle(.roundedBorder)
                    Button("创建") {
                        onCreate(path, branch, revision)
                        path = ""
                        branch = ""
                        revision = ""
                    }
                    .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || occupiedBranches.contains(branch))
                }
                if occupiedBranches.contains(branch), !branch.isEmpty {
                    Text("分支 (branch) 已被其他 worktree 占用；请换一个分支或只填写 revision。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let feedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(feedback.hasPrefix("已") ? .green : .red)
                }
            }
            .padding(14)
            Divider()
            if worktrees.isEmpty {
                ContentUnavailableView("暂无 worktree", systemImage: "square.split.2x1")
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(worktrees.enumerated()), id: \.element.path) { index, item in
                            worktreeRow(item, isMain: index == 0)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .background(Design.Colors.canvas)
    }

    private func worktreeRow(_ item: WorktreeInfo, isMain: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: isMain ? "house" : "square.split.2x1")
                    .foregroundStyle(isMain ? .blue : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.path)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 8) {
                        Text(item.branch.isEmpty ? "detached" : item.branch)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(item.headId.prefix(8))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if item.prunable { Text("prunable").foregroundStyle(.orange) }
                        if item.locked { Text("locked").foregroundStyle(.orange) }
                    }
                }
                Spacer()
                Button("打开") { onOpen(item.path) }
                    .buttonStyle(.borderless)
                if item.locked {
                    Button("解锁") { onUnlock(item.path) }
                        .buttonStyle(.borderless)
                } else {
                    Button("锁定") { onLock(item.path) }
                        .buttonStyle(.borderless)
                }
                Button("删除") { onRemove(item.path, false) }
                    .buttonStyle(.borderless)
                    .disabled(isMain)
                if !isMain {
                    Button("强制") { onRemove(item.path, true) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
    }
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

    private func railButton(_ image: String, mode: ToolWindowMode, help: String) -> some View {
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
    private var windowController: NSWindowController?
    private var hostingView: NSHostingView<VCSQuickActionsView>?
    private var onAction: ((ArborVCSAction) -> Void)?
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

    private func makeRootView(items: [VCSQuickActionItem]) -> VCSQuickActionsView {
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

    @State private var query = ""
    @State private var selection: String?

    private var filteredItems: [VCSQuickActionItem] {
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

    private func sectionTitle(_ section: VCSQuickActionItem.Section) -> String {
        switch section {
        case .commit: "Commit"
        case .repository: "Repository"
        case .workspace: "Workspace"
        }
    }

    private func runSelected() {
        guard let selection,
              let item = filteredItems.first(where: { $0.id == selection }) else { return }
        run(item)
    }

    private func run(_ item: VCSQuickActionItem) {
        guard item.isEnabled else { return }
        onAction(item.action)
    }
}

struct GitMergeRebaseWidgetItem: Identifiable {
    let rootPath: String
    let displayName: String
    let relativePath: String
    let operation: OperationKind
    let isCurrent: Bool

    var id: String { canonicalExternalLogPath(rootPath) }

    var operationTitle: String {
        switch operation {
        case .merge: return "Merge"
        case .rebase: return "Rebase"
        case .cherryPick: return "Cherry-pick"
        case .revert: return "Revert"
        }
    }

    var continueTitle: String {
        switch operation {
        case .merge: return "Commit Merge"
        case .rebase: return "Continue Rebase"
        case .cherryPick: return "Continue Cherry-pick"
        case .revert: return "Continue Revert"
        }
    }

    var widgetTitle: String {
        switch operation {
        case .merge: return "Merge in progress"
        case .rebase: return "Rebase paused"
        case .cherryPick: return "Cherry-pick in progress"
        case .revert: return "Revert in progress"
        }
    }

    var icon: String {
        switch operation {
        case .merge: return "arrow.triangle.merge"
        case .rebase: return "arrow.triangle.branch"
        case .cherryPick: return "doc.on.clipboard"
        case .revert: return "arrow.uturn.backward"
        }
    }
}

/// Build the project-toolbar operation list from the live selected-root state
/// plus the last discovered state for every other root. A live nil state also
/// removes a stale snapshot entry for the selected root.
func gitMergeRebaseWidgetItems(
    currentRootPath: String?,
    currentOperation: OperationKind?,
    roots: [GitRootInfo]
) -> [GitMergeRebaseWidgetItem] {
    let currentPath = currentRootPath.map(canonicalExternalLogPath)
    var itemsByPath: [String: GitMergeRebaseWidgetItem] = [:]

    for root in roots {
        guard let operation = root.operation else { continue }
        let rootPath = canonicalExternalLogPath(root.path)
        itemsByPath[rootPath] = GitMergeRebaseWidgetItem(
            rootPath: rootPath,
            displayName: root.displayName,
            relativePath: root.relativePath,
            operation: operation,
            isCurrent: rootPath == currentPath
        )
    }

    if let currentPath {
        if let currentOperation {
            let snapshot = itemsByPath[currentPath]
            itemsByPath[currentPath] = GitMergeRebaseWidgetItem(
                rootPath: currentPath,
                displayName: snapshot?.displayName
                    ?? URL(fileURLWithPath: currentPath).lastPathComponent,
                relativePath: snapshot?.relativePath ?? ".",
                operation: currentOperation,
                isCurrent: true
            )
        } else {
            itemsByPath.removeValue(forKey: currentPath)
        }
    }

    return itemsByPath.values.sorted { lhs, rhs in
        if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
        if lhs.relativePath != rhs.relativePath {
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
        return lhs.rootPath < rhs.rootPath
    }
}

/// IntelliJ's `main.toolbar.git.MergeRebase` action group, adapted to the
/// project toolbar. Direct actions are offered only for the live selected
/// root; another active root opens its own recovery context first.
struct GitMergeRebaseWidget: View {
    let items: [GitMergeRebaseWidgetItem]
    let currentOperationState: OperationState?
    let resolvedConflictPaths: [String]
    let onRevertResolved: (String) -> Void
    let onOperationAction: (
        ArborVCSActionRequest.OperationRecoveryAction,
        String
    ) -> Void

    var body: some View {
        if let primaryItem = items.first {
            Menu {
                ForEach(items) { item in
                    Section {
                        if item.isCurrent,
                           let state = currentOperationState,
                           state.kind == item.operation
                        {
                            if !state.conflictedFiles.isEmpty {
                                Button("Resolve Conflicts") {
                                    onOperationAction(.openRecovery, item.rootPath)
                                }
                            }
                            if !resolvedConflictPaths.isEmpty {
                                Menu("Revert Resolved") {
                                    ForEach(resolvedConflictPaths, id: \.self) { path in
                                        Button("Revert \(path)") {
                                            onRevertResolved(path)
                                        }
                                    }
                                }
                            }
                            Button(item.continueTitle) {
                                onOperationAction(.continueOperation, item.rootPath)
                            }
                            .disabled(
                                item.operation == .merge
                                    && !state.conflictedFiles.isEmpty
                            )
                            if item.operation == .rebase {
                                Button("Skip Rebase Step") {
                                    onOperationAction(.skip, item.rootPath)
                                }
                            }
                            Button("Abort \(item.operationTitle)", role: .destructive) {
                                onOperationAction(.abort, item.rootPath)
                            }
                        }
                        Button("Open Recovery") {
                            onOperationAction(.openRecovery, item.rootPath)
                        }
                    } header: {
                        Text(item.isCurrent ? item.widgetTitle : "\(item.widgetTitle) · \(item.displayName)")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: primaryItem.icon)
                    Text(primaryItem.widgetTitle)
                        .lineLimit(1)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            }
            .menuStyle(.borderlessButton)
            .help(operationHelpText(for: primaryItem))
        }
    }

    private func operationHelpText(for item: GitMergeRebaseWidgetItem) -> String {
        if items.count == 1 { return item.widgetTitle }
        return "\(item.widgetTitle) in \(item.displayName) and other Git roots"
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

    private func toolbarButton(_ image: String, title: String, action: @escaping () -> Void) -> some View {
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

struct ShelfTreeRow: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
    let depth: Int
    let isFolder: Bool
}

/// Build the same two-level ShelvedChangeList -> path tree that IntelliJ uses
/// for a shelf. The helper is kept pure so ordering and folder de-duplication
/// remain testable independently from SwiftUI state.
func intellijFilePathCompare(
    _ lhs: String,
    _ rhs: String,
    flattened: Bool
) -> ComparisonResult {
    if flattened {
        let lhsName = lhs.split(separator: "/").last.map(String.init) ?? lhs
        let rhsName = rhs.split(separator: "/").last.map(String.init) ?? rhs
        let nameOrder = lhsName.localizedStandardCompare(rhsName)
        if nameOrder != .orderedSame {
            return nameOrder
        }
    }
    return lhs.localizedStandardCompare(rhs)
}

func shelfTreeRows(paths: [String], groupByDirectory: Bool) -> [ShelfTreeRow] {
    let sortedPaths = paths.sorted {
        intellijFilePathCompare($0, $1, flattened: !groupByDirectory) == .orderedAscending
    }
    guard groupByDirectory else {
        return sortedPaths.map {
            ShelfTreeRow(id: "file:\($0)", name: $0, path: $0, depth: 0, isFolder: false)
        }
    }

    var rows: [ShelfTreeRow] = []
    var folders = Set<String>()
    for path in sortedPaths {
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { continue }
        if components.count > 1 {
            var prefix = ""
            for (index, component) in components.dropLast().enumerated() {
                prefix = prefix.isEmpty ? component : "\(prefix)/\(component)"
                if folders.insert(prefix).inserted {
                    rows.append(ShelfTreeRow(
                        id: "folder:\(prefix)",
                        name: component,
                        path: prefix,
                        depth: index,
                        isFolder: true
                    ))
                }
            }
        }
        rows.append(ShelfTreeRow(
            id: "file:\(path)",
            name: components.last ?? path,
            path: path,
            depth: max(0, components.count - 1),
            isFolder: false
        ))
    }
    return rows
}

func shelfMemberSelectionID(shelfID: String, path: String) -> String {
    "\(shelfID)\u{1F}\(path)"
}

private struct ShelfUnshelveRequest: Identifiable {
    let id = UUID()
    let name: String
    let paths: [String]?
    let rootPath: String
}

private struct ShelfBatchUnshelveRequest: Identifiable {
    let id = UUID()
    let names: [String]
    let rootPath: String
}

private struct ShelfMemberBatchUnshelveRequest: Identifiable {
    let id = UUID()
    let groups: [ShelfPathDeleteGroup]
    let rootPath: String
}

enum ShelfDropPayload: Equatable {
    case shelf(String)
    case member(shelf: String, path: String)
}

struct ShelfPathDeleteGroup: Equatable, Sendable {
    let shelfName: String
    let paths: [String]
}

struct ShelfDeletePlan: Equatable, Sendable {
    let activeShelfNames: [String]
    let activePathGroups: [ShelfPathDeleteGroup]
    let deletedShelfNames: [String]
    let deletedPathGroups: [ShelfPathDeleteGroup]

    var isEmpty: Bool {
        activeShelfNames.isEmpty
            && activePathGroups.isEmpty
            && deletedShelfNames.isEmpty
            && deletedPathGroups.isEmpty
    }
}

enum ShelfDeleteOperationKind: String, Equatable, Sendable {
    case activeShelf
    case activePaths
    case deletedShelf
    case deletedPaths
}

struct ShelfDeleteOperation: Equatable, Sendable {
    let kind: ShelfDeleteOperationKind
    let shelfName: String
    let paths: [String]

    var key: String {
        let scope: String
        switch kind {
        case .activeShelf: scope = "active-shelf"
        case .activePaths: scope = "active-paths"
        case .deletedShelf: scope = "deleted-shelf"
        case .deletedPaths: scope = "deleted-paths"
        }
        return "\(scope)\u{1f}\(shelfName)\u{1f}\(paths.joined(separator: "\u{1f}"))"
    }

    var displayName: String {
        switch kind {
        case .activeShelf, .activePaths:
            shelfName
        case .deletedShelf, .deletedPaths:
            shelfName + " (Recently Deleted)"
        }
    }
}

/// Expands the DeleteProvider scope into the same stable ordering used by the
/// unified Shelf deletion runner: active lists, active members, deleted lists,
/// then deleted members. The plan builder already gives whole-list selection
/// precedence over child selection, so no operation here can overlap another.
func shelfDeleteOperations(_ plan: ShelfDeletePlan) -> [ShelfDeleteOperation] {
    plan.activeShelfNames.map {
        ShelfDeleteOperation(kind: .activeShelf, shelfName: $0, paths: [])
    }
    + plan.activePathGroups.map {
        ShelfDeleteOperation(kind: .activePaths, shelfName: $0.shelfName, paths: $0.paths)
    }
    + plan.deletedShelfNames.map {
        ShelfDeleteOperation(kind: .deletedShelf, shelfName: $0, paths: [])
    }
    + plan.deletedPathGroups.map {
        ShelfDeleteOperation(kind: .deletedPaths, shelfName: $0.shelfName, paths: $0.paths)
    }
}

/// Builds the same delete scope that IntelliJ's Shelf DeleteProvider receives
/// from the tree: a selected list wins over its selected child changes, while
/// child changes from different lists remain independent operations.
func shelfDeletePlan(
    visibleShelves: [ShelveInfo],
    deletedShelves: [ShelveInfo],
    selectedShelfIDs: Set<String>,
    selectedShelfMemberIDs: Set<String>,
    selectedDeletedShelfIDs: Set<String>,
    selectedDeletedShelfMemberIDs: Set<String>
) -> ShelfDeletePlan {
    func pathGroups(
        shelves: [ShelveInfo],
        selectedShelfIDs: Set<String>,
        selectedMemberIDs: Set<String>
    ) -> (names: [String], groups: [ShelfPathDeleteGroup]) {
        var names: [String] = []
        var groups: [ShelfPathDeleteGroup] = []
        for shelf in shelves where selectedShelfIDs.contains(shelf.id) {
            names.append(shelf.name)
        }
        for shelf in shelves where !selectedShelfIDs.contains(shelf.id) {
            let paths = shelf.paths.filter {
                selectedMemberIDs.contains(
                    shelfMemberSelectionID(shelfID: shelf.id, path: $0)
                )
            }
            if !paths.isEmpty {
                groups.append(ShelfPathDeleteGroup(shelfName: shelf.name, paths: paths))
            }
        }
        return (names, groups)
    }

    let active = pathGroups(
        shelves: visibleShelves,
        selectedShelfIDs: selectedShelfIDs,
        selectedMemberIDs: selectedShelfMemberIDs
    )
    let deleted = pathGroups(
        shelves: deletedShelves,
        selectedShelfIDs: selectedDeletedShelfIDs,
        selectedMemberIDs: selectedDeletedShelfMemberIDs
    )
    return ShelfDeletePlan(
        activeShelfNames: active.names,
        activePathGroups: active.groups,
        deletedShelfNames: deleted.names,
        deletedPathGroups: deleted.groups
    )
}

/// Stash rows are addressed by their commit identity rather than their
/// volatile stack index. Dropping a stash shifts every older index, so both
/// actions and previews must resolve the index only at invocation time.
func stashIndex(forID id: String?, in stashes: [StashInfo]) -> Int? {
    guard let id else { return nil }
    return stashes.firstIndex { $0.id == id }
}

/// Decode the two drag payloads used by the Shelf tree. Keeping this parser
/// separate from the drop views prevents a member payload from accidentally
/// falling through to the whole-Shelf Unshelve action.
func parseShelfDropPayload(_ payload: String) -> ShelfDropPayload? {
    let shelfPrefix = "arbor-shelf:"
    let memberPrefix = "arbor-shelf-member:"
    if payload.hasPrefix(shelfPrefix) {
        let name = String(payload.dropFirst(shelfPrefix.count))
        return name.isEmpty ? nil : .shelf(name)
    }
    guard payload.hasPrefix(memberPrefix) else { return nil }
    let body = payload.dropFirst(memberPrefix.count)
    guard let separator = body.firstIndex(of: "\u{1F}") else { return nil }
    let shelf = String(body[..<separator])
    let path = String(body[body.index(after: separator)...])
    guard !shelf.isEmpty, !path.isEmpty else { return nil }
    return .member(shelf: shelf, path: path)
}

enum StagingPreviewMode: String, CaseIterable {
    case unstaged
    case staged

    var title: String {
        switch self {
        case .unstaged: "Unstaged"
        case .staged: "Staged"
        }
    }
}

enum StagingComparisonAction: String, CaseIterable, Equatable {
    case localWithStaged
    case stagedWithLocal
    case stagedWithHead
    case threeVersions
}

enum StagingVersionAction: String, CaseIterable, Equatable {
    case local
    case staged
}

enum StagingPreviewFileAction: String, CaseIterable, Equatable {
    case stage
    case unstage
    case revertUnstaged
}

func stagingPreviewDiffMode(for mode: StagingPreviewMode) -> DiffMode {
    switch mode {
    case .unstaged: .worktreeToIndex
    case .staged: .indexToHead
    }
}

struct StagingVersionPresence: Equatable {
    let head: Bool
    let staged: Bool
    let local: Bool
}

func stagingVersionPresence(for entry: StagingEntry) -> StagingVersionPresence {
    StagingVersionPresence(
        head: entry.headPresent,
        staged: entry.stagedPresent,
        local: entry.localPresent
    )
}

func stagingComparisonDiffMode(for action: StagingComparisonAction) -> DiffMode? {
    switch action {
    case .localWithStaged:
        // IntelliJ's Local-with-Staged and Staged-with-Local actions share
        // compareStagedWithLocal: staged is the base and local is the right
        // side, which is also the coordinate system used by stageLines.
        return .worktreeToIndex
    case .stagedWithLocal:
        return .worktreeToIndex
    case .stagedWithHead:
        return .indexToHead
    case .threeVersions:
        return nil
    }
}

/// Keep file-level staging preview actions derived from the same two-sided
/// status model as the Changes Browser. In particular, an untracked file can
/// be staged but cannot be reverted to an index version that does not exist.
func stagingPreviewFileActions(
    for entry: FileEntry?,
    mode: StagingPreviewMode
) -> [StagingPreviewFileAction] {
    guard let entry else { return [] }
    switch mode {
    case .unstaged:
        guard entry.unstaged != .unchanged,
              entry.unstaged != .ignored,
              entry.unstaged != .conflicted else { return [] }
        var actions: [StagingPreviewFileAction] = [.stage]
        if entry.unstaged != .untracked {
            actions.append(.revertUnstaged)
        }
        return actions
    case .staged:
        guard entry.staged != .unchanged,
              entry.staged != .ignored,
              entry.staged != .conflicted else { return [] }
        return [.unstage]
    }
}

/// Hunk-level actions exposed by the staging diff preview. Keep this matrix
/// pure so status edge cases are testable without constructing SwiftUI views.
func stagingHunkActions(
    for entry: FileEntry?,
    mode: StagingPreviewMode,
    diff: FileDiff?
) -> [DiffHunkAction] {
    guard let diff, !diff.binary, !diff.hunks.isEmpty else { return [] }
    let fileActions = stagingPreviewFileActions(for: entry, mode: mode)
    switch mode {
    case .unstaged:
        var actions: [DiffHunkAction] = []
        if fileActions.contains(.stage) { actions.append(.stage) }
        if fileActions.contains(.revertUnstaged) { actions.append(.rollback) }
        return actions
    case .staged:
        return fileActions.contains(.unstage) ? [.unstage] : []
    }
}

func resolvedStagingPreviewMode(
    preferred: StagingPreviewMode,
    available: [StagingPreviewMode]
) -> StagingPreviewMode? {
    guard !available.isEmpty else { return nil }
    return available.contains(preferred) ? preferred : available[0]
}

/// Match IntelliJ's staging action visibility to the two-dimensional status
/// model. A comparison is only offered when both sides are represented by the
/// entry; single-sided untracked/deleted changes must not advertise a second
/// version that does not exist.
func stagingComparisonActions(
    for entry: FileEntry,
    presence: StagingVersionPresence? = nil
) -> [StagingComparisonAction] {
    guard entry.staged != .conflicted,
          entry.unstaged != .conflicted,
          entry.staged != .ignored,
          entry.unstaged != .ignored else { return [] }

    var actions: [StagingComparisonAction] = []
    let hasHead = presence?.head ?? (
        entry.staged != .unchanged
            && entry.staged != .added
            && entry.staged != .untracked
    )
    let hasStaged = presence?.staged ?? (entry.staged != .unchanged)
    let hasLocal = presence?.local ?? (entry.unstaged != .unchanged)
    if hasStaged && hasLocal {
        actions.append(contentsOf: [.localWithStaged, .stagedWithLocal])
        if hasHead {
            actions.append(.threeVersions)
        }
    }
    if hasStaged && hasHead {
        actions.append(.stagedWithHead)
    }
    return actions
}

func stagingVersionActions(
    for entry: FileEntry,
    presence: StagingVersionPresence? = nil
) -> [StagingVersionAction] {
    var actions: [StagingVersionAction] = []
    let hasLocal = presence?.local ?? (
        entry.unstaged != .deleted
            && entry.unstaged != .ignored
            && entry.unstaged != .conflicted
            && !(entry.staged == .deleted && entry.unstaged == .unchanged)
    )
    let hasStaged = presence?.staged ?? (
        entry.staged != .unchanged
            && entry.staged != .deleted
            && entry.staged != .ignored
            && entry.staged != .conflicted
    )
    if hasLocal { actions.append(.local) }
    if hasStaged { actions.append(.staged) }
    return actions
}

struct RebasedCommitWorkspace: View {
    let projectPath: String?
    let repo: Repository?
    let repositoryWorkdir: String?
    let shelfRepo: Repository?
    let entries: [FileEntry]
    let changeLists: [ChangeListInfo]
    let untrackedEntries: [FileEntry]
    let ignoredRules: [IgnoreRuleInfo]
    let stashes: [StashInfo]
    let shelves: [ShelveInfo]
    let deletedShelves: [ShelveInfo]
    let shelfChangeLists: [ChangeListInfo]
    /// Monotonic request from the VCS main menu to select the combined
    /// Shelf/Stash tab.
    var showShelfRequestID: Int = 0
    /// Keeps selection-scoped main-menu actions from using a stale Changes
    /// selection while the Shelf tab is active.
    var onWorkspaceTabChange: (Bool) -> Void = { _ in }
    let shelfRootPath: String?
    let shelfRootOptions: [GitRootInfo]
    let selectedShelfRootPath: String
    let isShelfRootReadOnly: Bool
    let canMutateShelfMetadata: Bool
    let canApplyShelfWorktree: Bool
    let isShelfRootLoading: Bool
    let shelfRootError: String?
    let onShelfRootChange: (String) -> Void
    let isLoading: Bool
    let isShowingCachedStatusSnapshot: Bool
    let hasStaged: Bool
    let commitFeedback: String?
    /// OPS-001 统一操作状态：非 nil 时显示 Operation Recovery Bar。
    let operationState: OperationState?
    let operationFeedback: String?
    /// IDX-001 二进制文件路径集合（staging model 提供，diff 降级展示）。
    let binaryPaths: Set<String>
    /// HEAD/index/worktree presence facts from the staging model.
    var stagingPresence: [String: StagingVersionPresence] = [:]
    /// Invalidates the preview when an external status/index refresh changes
    /// file contents without changing the selected path or status kind.
    var refreshToken: Int = 0
    let recentMessages: [String]
    @Binding var commitMessage: String
    @Binding var amendMode: Bool
    @Binding var skipHooks: Bool
    @AppStorage(GitCommitHooksSettings.key)
    private var alwaysSkipCommitHooks = GitCommitHooksSettings.defaultValue
    let onStage: (String) -> Void
    var onStageWithoutContent: (String) -> Void = { _ in }
    var onStageWithoutContentAll: () -> Void = {}
    let onUnstage: (String) -> Void
    let onPartial: (String) -> Void
    let onSelect: (String) -> Void
    let onPreviewPath: (String) -> Void
    /// Explicitly opens the stage diff preview. This is separate from
    /// `onPreviewPath`: the latter mirrors GitStagePanel's double-click/open
    /// source path, while the tree context menu's Show Diff action must keep
    /// the Commit/Stash workspace in place.
    let onShowDiffPath: (String) -> Void
    /// Reverse Local → Staged comparison; normal Show Diff remains Staged → Local.
    var onShowLocalStagedDiffPath: (String) -> Void = { _ in }
    var onShowLocalVersionPath: (String) -> Void = { _ in }
    var onShowStagedVersionPath: (String) -> Void = { _ in }
    let onShowStagedDiffPath: (String) -> Void
    let onShowThreeVersionsPath: (String) -> Void
    @Binding var previewMode: StagingPreviewMode
    let comparisonMode: DiffMode?
    @Binding var showThreeVersions: Bool
    @Binding var previewPath: String?
    @Binding var isPreviewVisible: Bool
    @Binding var selectionModePath: String?
    let onRestore: (String) -> Void
    let onRevertUnstaged: (String) -> Void
    let onRefresh: () -> Void
    let onStageAll: () -> Void
    let onStageEverything: () -> Void
    let onCreateChangeList: () -> Void
    let onRenameChangeList: (String) -> Void
    let onDeleteChangeList: (String) -> Void
    let onActivateChangeList: (String) -> Void
    let onMovePathsToChangeList: ([String], String) -> Void
    let onTemplate: () -> Void
    let onBeforeCommitSettings: () -> Void
    let onCommit: () -> Void
    let onCommitAll: () -> Void
    let onCommitAndRebase: () -> Void
    let autoSquashCommitKind: AutoSquashCommitKind?
    let onCommitAndPush: () -> Void
    let onOperationContinue: () -> Void
    let onOperationSkip: () -> Void
    let onOperationAbort: () -> Void
    let onOpenConflictResolver: () -> Void
    let onShelve: () -> Void
    /// Opens the repository-scoped Shelf storage settings.
    var onShelfSettings: () -> Void = {}
    let onShelvePaths: ([String]) -> Void
    let onImportShelve: (String?) -> Void
    let onPreview: () -> Void
    let onStash: () -> Void
    var onStashPaths: ([String]) -> Void = { _ in }
    let onStashSilently: () -> Void
    let onApplyStash: (String, Bool) -> Void
    let onPopStash: (String, Bool) -> Void
    let onDropStash: (String) -> Void
    let onStashBranch: (String) -> Void
    var onUnstashAs: (String) -> Void = { _ in }
    let onStashDiffPreview: (String) -> Void
    let stashDiffText: String?
    @Binding var stashPreviewStashID: String?
    @Binding var isStashPreviewVisible: Bool
    let onStashClear: () -> Void
    let onShelveDiffPreview: (String) -> Void
    let shelfDiffText: String?
    @Binding var shelfPreviewName: String?
    @Binding var shelfPreviewIsDeleted: Bool
    @Binding var isShelfPreviewVisible: Bool
    let onRenameShelve: (String, String) -> Void
    var onRenameShelveDescription: (String, String) -> Void = { _, _ in }
    let onExportShelve: (String) -> Void
    let onUnshelve: (String) -> Void
    let onUnshelveWithOptions: (String, Bool) -> Void
    let onUnshelvePathsWithOptions: (String, [String], Bool) -> Void
    var onUnshelvePathGroupsWithOptions: ([ShelfPathDeleteGroup], Bool, Bool) -> Void = { _, _, _ in }
    let onUnshelveSelectionsWithOptions: (String, [ShelvePatchSelection], Bool) -> Void
    var onUnshelvePathsWithBase: (String, [String], Bool, String, UInt32) -> Void = { _, _, _, _, _ in }
    var onUnshelveSelectionsWithBase: (String, [ShelvePatchSelection], Bool, String, UInt32) -> Void = { _, _, _, _, _ in }
    var onUnshelveShelvesIntoChangeList: ([String], String, Bool) -> Void = { _, _, _ in }
    var onUnshelvePathGroupsIntoChangeList: ([ShelfPathDeleteGroup], String, Bool) -> Void = { _, _, _ in }
    var onUnshelveShelvesSilently: ([String], Bool) -> Void = { _, _ in }
    var onUnshelveDeletedShelvesSilently: ([String], Bool) -> Void = { _, _ in }
    var onUnshelveDeletedPathsWithOptions: (String, [String], Bool) -> Void = { _, _, _ in }
    var onUnshelveDeletedPathsWithBase: (String, [String], Bool, String, UInt32) -> Void = { _, _, _, _, _ in }
    var onPopShelve: (String) -> Void = { _ in }
    var onPopShelves: ([String]) -> Void = { _ in }
    let onUnshelveIntoChangeList: (String, [String]?, String) -> Void
    var onUnshelveSelectionsIntoChangeList: (String, [ShelvePatchSelection], String, Bool) -> Void = { _, _, _, _ in }
    var onUnshelveIntoChangeListWithBase: (String, [String]?, String, Bool, String, UInt32) -> Void = { _, _, _, _, _, _ in }
    var onUnshelveSelectionsIntoChangeListWithBase: (String, [ShelvePatchSelection], String, Bool, String, UInt32) -> Void = { _, _, _, _, _, _ in }
    /// Persists an optional Unshelve comment on the explicit target
    /// Changelist after the apply operation has been dispatched.
    var onRecordUnshelveComment: (String, String) -> Void = { _, _ in }
    let onCleanRecycledShelves: () -> Void
    let onDropShelve: (String) -> Void
    var onDropShelves: ([String]) -> Void = { _ in }
    let onDropShelvePaths: (String, [String]) -> Void
    var onDropShelvePathGroups: ([ShelfPathDeleteGroup]) -> Void = { _ in }
    let onMoveShelfPaths: (String, String, [String]) -> Void
    let onRestoreDeletedShelve: (String) -> Void
    let onDeleteDeletedShelve: (String) -> Void
    var onDeleteDeletedShelfPaths: (String, [String]) -> Void = { _, _ in }
    var onDeleteDeletedShelfPathGroups: ([ShelfPathDeleteGroup]) -> Void = { _ in }
    var onRestoreDeletedShelves: ([String]) -> Void = { _ in }
    var onDeleteDeletedShelves: ([String], Bool) -> Void = { _, _ in }
    var onDeleteShelfPlan: (ShelfDeletePlan) -> Void = { _ in }
    let onIgnore: ([String], String?) -> Void
    let onExclude: ([String]) -> Void
    let onOpenConflict: (String) -> Void
    var resolvedConflictPaths: [String] = []
    var onRevertResolved: (String) -> Void = { _ in }
    var onShowHistory: (String) -> Void = { _ in }
    var onEditGitignore: () -> Void = {}
    var onEditGitExclude: () -> Void = {}

    @State private var tab: Tab = .commit
    @State private var stashesExpanded = true
    @State private var shelvesExpanded = true
    @State private var shelfGroupByDirectory = true
    @State private var deletedShelvesExpanded = true
    @State private var showRecycledShelves = false
    @State private var removeAppliedFilesFromShelf = false
    @State private var expandedShelfIDs: Set<String> = []
    @State private var collapsedShelfFolders: Set<String> = []
    @State private var selectedShelfIDs: Set<String> = []
    @State private var selectedShelfMemberIDs: Set<String> = []
    @State private var selectedDeletedShelfIDs: Set<String> = []
    @State private var selectedDeletedShelfMemberIDs: Set<String> = []
    @State private var selectedStashID: String?
    @State private var pendingUnshelve: ShelfUnshelveRequest?
    @State private var pendingUnshelveShelves: ShelfBatchUnshelveRequest?
    @State private var pendingUnshelveMemberGroups: ShelfMemberBatchUnshelveRequest?
    @State private var showClearStashesConfirmation = false
    @State private var showCommitAllConfirmation = false
    @State private var groupByDirectory = true
    @State private var showIgnored = true
    @State private var contextSelectedPaths: Set<String> = []
    @State private var treeExpansionCommand = 0
    @State private var treeExpansionTarget = true
    @State private var editingShelfID: String?
    @State private var editingShelfDescription = ""
    @State private var lastAppliedShelfRequestID = 0
    @AppStorage(GitStashViewSettings.splitPreviewKey)
    private var stashSplitPreviewEnabled = GitStashViewSettings.defaultSplitPreview
    @FocusState private var focusedShelfID: String?

    private enum Tab: String, CaseIterable {
        case commit = "Commit"
        case stash = "Stash"
    }

    private var conflictedEntries: [FileEntry] {
        entries.filter { $0.staged == .conflicted || $0.unstaged == .conflicted }
    }

    private var conflictedPaths: Set<String> {
        Set(conflictedEntries.map(\.path))
    }

    /// IntelliJ leaves the Commit tool window usable while an interactive
    /// rebase is paused at `edit`, but only for amending that paused commit.
    /// A conflict pause must continue to use the conflict resolver instead.
    private var canAmendPausedRebase: Bool {
        rebaseEditPauseAllowsAmend(operationState)
    }

    /// GitStageTree keeps ordinary-sized untracked sets under Unstaged. It
    /// creates a separate Unversioned node only when IntelliJ's
    /// `vcs.unversioned.files.max.intree` threshold is exceeded.
    private var standaloneUnversionedEntries: [FileEntry] {
        untrackedEntries.count > 1_000 ? untrackedEntries : []
    }

    private var embeddedUntrackedPaths: Set<String> {
        Set(untrackedEntries.count > 1_000 ? [] : untrackedEntries.map(\.path))
    }

    private var contextEligiblePaths: Set<String> {
        Set(entries.filter(gitIgnoreActionAvailable).map(\.path))
    }

    private var unstagedEntries: [FileEntry] {
        entries.filter {
            guard $0.unstaged != .unchanged,
                  $0.unstaged != .ignored,
                  !conflictedPaths.contains($0.path) else { return false }
            if $0.unstaged == .untracked {
                return embeddedUntrackedPaths.contains($0.path)
            }
            return true
        }
    }

    private var visibleChangedCount: Int {
        // A partially staged file is rendered in both Unstaged and Staged
        // groups, but Rebased's Changes counter represents files, not group
        // rows. Counting the three arrays directly made the header jump by
        // two for one physical file.
        Set((conflictedEntries + unstagedEntries + untrackedEntries + stagedEntries).map(\.path)).count
    }

    private var ignoredEntries: [FileEntry] {
        entries.filter { $0.unstaged == .ignored }
    }

    private var stagedEntries: [FileEntry] {
        entries.filter { $0.staged != .unchanged && !conflictedPaths.contains($0.path) }
    }

    private var visibleChangeLists: [ChangeListInfo] {
        if !changeLists.isEmpty {
            return changeLists
        }
        // Keep the tree useful during the short interval before repository
        // metadata loads. The engine will replace this synthetic default with
        // the persisted list state on the next refresh.
        return [ChangeListInfo(
            name: "Default",
            paths: entries.map(\.path),
            isDefault: true,
            isActive: true
        )]
    }

    private var visibleShelfChangeLists: [ChangeListInfo] {
        if !shelfChangeLists.isEmpty {
            return shelfChangeLists
        }
        return [ChangeListInfo(
            name: "Default",
            paths: [],
            isDefault: true,
            isActive: true
        )]
    }

    private var visibleShelves: [ShelveInfo] {
        showRecycledShelves ? shelves : shelves.filter { !$0.isRecycled }
    }

    private var showRecycledShelvesBinding: Binding<Bool> {
        Binding(
            get: { showRecycledShelves },
            set: { value in
                showRecycledShelves = value
                ShelfViewSettings.saveShowRecycled(value, for: projectPath)
            }
        )
    }

    private func loadShelfViewSettings() {
        showRecycledShelves = ShelfViewSettings.showRecycled(for: projectPath)
        removeAppliedFilesFromShelf = ShelfViewSettings.removeAppliedFilesFromShelf(for: projectPath)
        shelvesExpanded = ShelfViewSettings.shelvesExpanded(for: projectPath)
        shelfGroupByDirectory = ShelfViewSettings.groupByDirectory(for: projectPath)
        deletedShelvesExpanded = ShelfViewSettings.deletedShelvesExpanded(for: projectPath)
    }

    private func loadGitStageViewSettings() {
        showIgnored = GitStageViewSettings.ignoredFilesShown(for: projectPath)
    }

    private func shelfDisplayDescription(_ shelf: ShelveInfo) -> String {
        shelf.description.isEmpty ? shelf.name : shelf.description
    }

    @ViewBuilder
    private func shelfTitleView(_ shelf: ShelveInfo) -> some View {
        if editingShelfID == shelf.id {
            TextField("Shelf description", text: $editingShelfDescription)
                .textFieldStyle(.plain)
                .focused($focusedShelfID, equals: shelf.id)
                .onSubmit { commitShelfRename(shelf) }
                .onExitCommand { cancelShelfRename() }
        } else {
            Text(shelfDisplayDescription(shelf))
                .lineLimit(1)
                .onTapGesture(count: 2) { beginShelfRename(shelf) }
        }
    }

    private func entries(_ source: [FileEntry], in list: ChangeListInfo) -> [FileEntry] {
        let members = Set(list.paths)
        return source.filter { members.contains($0.path) }
    }

    private var hasTrackedUnstagedChanges: Bool {
        entries.contains {
            $0.unstaged != .unchanged
                && $0.unstaged != .untracked
                && $0.unstaged != .ignored
        }
    }

    private var hasCommitAllEligibleChanges: Bool {
        entries.contains {
            $0.staged != .conflicted
                && $0.unstaged != .conflicted
                && $0.unstaged != .unchanged
                && $0.unstaged != .untracked
                && $0.unstaged != .ignored
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 22) {
                ForEach(Tab.allCases, id: \.self) { item in
                    Button(item.rawValue) {
                        tab = item
                        onWorkspaceTabChange(item == .stash)
                    }
                    .buttonStyle(RebasedTabButtonStyle(isSelected: tab == item))
                }
                Spacer()
                Menu {
                    Button("Refresh") { onRefresh() }
                    Button("Stash…") { onStash() }
                    Button("Shelve…") { onShelve() }
                        .disabled(isShelfRootReadOnly || isShelfRootLoading)
                    Button("Shelf Location…") { onShelfSettings() }
                        .disabled(!canMutateShelfMetadata || isShelfRootLoading)
                    Divider()
                    Button("Clear Already Unshelved", role: .destructive) {
                        onCleanRecycledShelves()
                    }
                    .disabled(
                        !canMutateShelfMetadata
                            || !shelves.contains(where: \.isRecycled)
                    )
                    Button("Clear All Stashes", role: .destructive) {
                        showClearStashesConfirmation = true
                    }
                        .disabled(stashes.isEmpty)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .background(rebasedSurface)

            Divider()

            if let operationState {
                OperationRecoveryBar(
                    state: operationState,
                    feedback: operationFeedback,
                    onContinue: onOperationContinue,
                    onSkip: onOperationSkip,
                    onAbort: onOperationAbort,
                    onOpenConflictResolver: onOpenConflictResolver,
                    onOpenConflict: onOpenConflict
                )
            }

            if tab == .commit {
                commitContent
            } else {
                stashContent
            }
        }
        .background(rebasedBackground)
        .foregroundStyle(.primary)
        .onAppear {
            loadShelfViewSettings()
            loadGitStageViewSettings()
            applyShowShelfRequest(showShelfRequestID)
            onWorkspaceTabChange(tab == .stash)
        }
        .onChange(of: showShelfRequestID) { _, requestID in
            applyShowShelfRequest(requestID)
        }
        .onChange(of: projectPath) { _, _ in
            loadShelfViewSettings()
            loadGitStageViewSettings()
            contextSelectedPaths.removeAll()
        }
        .onChange(of: repositoryWorkdir) { _, _ in
            contextSelectedPaths.removeAll()
        }
        .onChange(of: removeAppliedFilesFromShelf) { _, value in
            ShelfViewSettings.saveRemoveAppliedFilesFromShelf(value, for: projectPath)
        }
        .onChange(of: shelvesExpanded) { _, value in
            ShelfViewSettings.saveShelvesExpanded(value, for: projectPath)
        }
        .onChange(of: shelfGroupByDirectory) { _, value in
            ShelfViewSettings.saveGroupByDirectory(value, for: projectPath)
        }
        .onChange(of: deletedShelvesExpanded) { _, value in
            ShelfViewSettings.saveDeletedShelvesExpanded(value, for: projectPath)
        }
        .onChange(of: showIgnored) { _, value in
            GitStageViewSettings.saveIgnoredFilesShown(value, for: projectPath)
        }
        .confirmationDialog(
            "Clear all stashes?",
            isPresented: $showClearStashesConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All Stashes", role: .destructive, action: onStashClear)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently removes every local stash from this repository.")
        }
        .confirmationDialog(
            "Commit All",
            isPresented: $showCommitAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Commit All", action: onCommitAll)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Nothing is staged. Commit all tracked changes?")
        }
        .sheet(item: $pendingUnshelve) { request in
            let shelfPaths = shelves.first(where: { $0.name == request.name })?.paths
                ?? request.paths
                ?? []
            RebasedUnshelveDialog(
                name: request.name,
                paths: shelfPaths,
                initialPaths: request.paths ?? shelfPaths,
                changeLists: visibleShelfChangeLists,
                repo: shelfRepo,
                removeAppliedFilesFromShelf: $removeAppliedFilesFromShelf,
                onUnshelve: { selectedPaths, selections, targetName, removeApplied, basePath, pathStrip, comment in
                    guard shelfActionRootMatchesCurrentRoot(
                        requestedRootPath: request.rootPath,
                        currentRootPath: selectedShelfRootPath
                    ) else {
                        pendingUnshelve = nil
                        return
                    }
                    pendingUnshelve = nil
                    if let targetName, let comment, !comment.isEmpty {
                        onRecordUnshelveComment(targetName, comment)
                    }
                    let hasMapping = (basePath?.isEmpty == false) || pathStrip != 1
                    if let targetName {
                        if !selections.isEmpty {
                            if hasMapping {
                                onUnshelveSelectionsIntoChangeListWithBase(
                                    request.name,
                                    selections,
                                    targetName,
                                    removeApplied,
                                    basePath ?? "",
                                    pathStrip
                                )
                            } else {
                                onUnshelveSelectionsIntoChangeList(
                                    request.name,
                                    selections,
                                    targetName,
                                    removeApplied
                                )
                            }
                        } else {
                            if hasMapping {
                                onUnshelveIntoChangeListWithBase(
                                    request.name,
                                    selectedPaths,
                                    targetName,
                                    removeApplied,
                                    basePath ?? "",
                                    pathStrip
                                )
                            } else {
                                onUnshelveIntoChangeList(request.name, selectedPaths, targetName)
                            }
                        }
                    } else if !selections.isEmpty {
                        if hasMapping {
                            onUnshelveSelectionsWithBase(
                                request.name,
                                selections,
                                removeApplied,
                                basePath ?? "",
                                pathStrip
                            )
                        } else {
                            onUnshelveSelectionsWithOptions(
                                request.name,
                                selections,
                                removeApplied
                            )
                        }
                    } else if Set(selectedPaths) == Set(shelfPaths) {
                        if hasMapping {
                            onUnshelvePathsWithBase(
                                request.name,
                                selectedPaths,
                                removeApplied,
                                basePath ?? "",
                                pathStrip
                            )
                        } else {
                            onUnshelveWithOptions(request.name, removeApplied)
                        }
                    } else if hasMapping {
                        onUnshelvePathsWithBase(
                            request.name,
                            selectedPaths,
                            removeApplied,
                            basePath ?? "",
                            pathStrip
                        )
                    } else {
                        onUnshelvePathsWithOptions(request.name, selectedPaths, removeApplied)
                    }
                },
                onCancel: { pendingUnshelve = nil }
            )
        }
        .sheet(item: $pendingUnshelveShelves) { request in
            RebasedUnshelveMultipleDialog(
                names: request.names,
                changeLists: visibleShelfChangeLists,
                suggestedName: request.names.first.flatMap { name in
                    shelves.first(where: { $0.name == name })?.description
                },
                removeAppliedFilesFromShelf: $removeAppliedFilesFromShelf,
                onUnshelve: { targetName, removeApplied in
                    guard shelfActionRootMatchesCurrentRoot(
                        requestedRootPath: request.rootPath,
                        currentRootPath: selectedShelfRootPath
                    ) else {
                        pendingUnshelveShelves = nil
                        return
                    }
                    pendingUnshelveShelves = nil
                    onUnshelveShelvesIntoChangeList(request.names, targetName, removeApplied)
                },
                onCancel: { pendingUnshelveShelves = nil }
            )
        }
        .sheet(item: $pendingUnshelveMemberGroups) { request in
            RebasedUnshelveMultipleDialog(
                names: request.groups.map(\.shelfName),
                changeLists: visibleShelfChangeLists,
                suggestedName: request.groups.first.flatMap { group in
                    shelves.first(where: { $0.name == group.shelfName })?.description
                },
                removeAppliedFilesFromShelf: $removeAppliedFilesFromShelf,
                onUnshelve: { targetName, removeApplied in
                    guard shelfActionRootMatchesCurrentRoot(
                        requestedRootPath: request.rootPath,
                        currentRootPath: selectedShelfRootPath
                    ) else {
                        pendingUnshelveMemberGroups = nil
                        return
                    }
                    pendingUnshelveMemberGroups = nil
                    onUnshelvePathGroupsIntoChangeList(
                        request.groups,
                        targetName,
                        removeApplied
                    )
                },
                onCancel: { pendingUnshelveMemberGroups = nil }
            )
        }
    }

    private var commitContent: some View {
        Group {
            if isPreviewVisible {
                HSplitView {
                    commitPanel
                        .frame(minWidth: 250, idealWidth: 360, maxWidth: .infinity, maxHeight: .infinity)

                    Group {
                        if let comparisonMode,
                           let previewPath,
                           let entry = entries.first(where: { $0.path == previewPath }) {
                            DiffDetailView(
                                repo: repo,
                                entry: entry,
                                onChanged: onRefresh,
                                selectionModePath: nil,
                                initialMode: comparisonMode,
                                refreshToken: refreshToken
                            )
                        } else {
                            StagingDiffPreviewView(
                                repo: repo,
                                path: previewPath,
                                entry: entries.first(where: { $0.path == previewPath }),
                                refreshToken: refreshToken,
                                selectionModePath: $selectionModePath,
                                previewMode: $previewMode,
                                showThreeVersions: $showThreeVersions,
                                onStage: onStage,
                                onUnstage: onUnstage,
                                onRevertUnstaged: onRevertUnstaged,
                                onChanged: onRefresh,
                                onClose: {
                                    isPreviewVisible = false
                                    showThreeVersions = false
                                    selectionModePath = nil
                                }
                            )
                        }
                    }
                    .frame(minWidth: 260, idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                commitPanel
            }
        }
    }

    /// rebased 的 PreviewDiffSplitterComponent 包住的是整个 Stage panel，
    /// 而不是把 diff 插进 Changes 和 Commit Message 中间。保留这个边界
    /// 后，提交编辑器的高度和操作按钮不会随着 diff 预览被挤成不可用的
    /// 小条，左右两个工作区也各自保持独立的滚动上下文。
    private var commitPanel: some View {
        VSplitView {
            stagingTreePanel
                // Rebased keeps the Changes tree as the dominant region;
                // the commit editor is a compact footer, not an equal-sized
                // second pane. The tree therefore absorbs extra height.
                .frame(minHeight: 180, idealHeight: 640, maxHeight: .infinity)

            commitEditorPanel
                .frame(minHeight: 180, idealHeight: 180, maxHeight: 240)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// GitStagePanel's first splitter component: toolbar + the staged tree.
    /// The commit message is deliberately not inside this scroll view; the
    /// divider between the two components is a real workspace affordance.
    private var stagingTreePanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                // Keep the same action order as GitStagePanel's
                // Git.Stage.Toolbar: preview, refresh, stage tracked, stash,
                // then the grouping/ignored settings popup.
                compactButton(
                    isPreviewVisible ? "eye.fill" : "eye",
                    help: isPreviewVisible ? "Hide changes preview" : "Show changes preview",
                    action: onPreview
                )
                .disabled(visibleChangedCount == 0)
                compactButton("arrow.clockwise", help: "Refresh", action: onRefresh)
                compactButton("arrow.right", help: "Stage tracked changes", action: onStageAll)
                    .disabled(operationState != nil || !hasTrackedUnstagedChanges)
                compactButton("arrow.right.to.line", help: "Stage all changes", action: onStageEverything)
                    .disabled(operationState != nil || visibleChangedCount == 0)
                compactButton("doc.badge.plus", help: "Stage untracked without content", action: onStageWithoutContentAll)
                    .disabled(operationState != nil || untrackedEntries.isEmpty)
                if !resolvedConflictPaths.isEmpty {
                    Menu {
                        ForEach(resolvedConflictPaths, id: \.self) { path in
                            Button("Revert \(path)") { onRevertResolved(path) }
                        }
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 22, height: 22)
                    }
                    .menuStyle(.borderlessButton)
                    .foregroundStyle(.secondary)
                    .help("Revert resolved conflict")
                }
                compactButton("tray.and.arrow.down", help: "Stash changes silently", action: onStashSilently)
                    .disabled(operationState != nil || visibleChangedCount == 0)
                Menu {
                    Toggle("Group by Directory", isOn: $groupByDirectory)
                    Divider()
                    Toggle("Show Ignored", isOn: $showIgnored)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(.secondary)
                .help("Stage view settings")
                compactButton("list.bullet.indent", help: "New Changelist", action: onCreateChangeList)
                // GitStagePanel appends TreeActionsToolbarPanel to the stage
                // toolbar. These are first-class toolbar actions in rebased,
                // not settings-menu-only commands: they must work while the
                // tree has focus and remain discoverable beside the other
                // stage actions.
                compactButton("chevron.down", help: "Expand All", action: {
                    treeExpansionTarget = true
                    treeExpansionCommand += 1
                })
                compactButton("chevron.up", help: "Collapse All", action: {
                    treeExpansionTarget = false
                    treeExpansionCommand += 1
                })
                Spacer()
                if isShowingCachedStatusSnapshot {
                    ProgressView()
                        .controlSize(.small)
                        .help("Refreshing cached changes")
                }
                if isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            HStack {
                Text("变更")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(visibleChangedCount) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if showIgnored, !ignoredEntries.isEmpty {
                    Text("· \(ignoredEntries.count) ignored")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !conflictedEntries.isEmpty {
                        RebasedConflictGroup(
                            entries: conflictedEntries,
                            onOpen: onOpenConflict
                        )
                    }
                    changeGroups
                    if !standaloneUnversionedEntries.isEmpty {
                        RebasedChangeGroup(
                            title: "Unversioned Files",
                            entries: standaloneUnversionedEntries,
                            changeListName: visibleChangeLists.first(where: { $0.isDefault })?.name ?? "Default",
                            changeLists: visibleChangeLists,
                            emptyLabel: "没有文件",
                            statusKind: { $0.unstaged },
                            isChecked: { _ in false },
                            onToggle: { entry, checked in
                                if checked { onStage(entry.path) } else { onUnstage(entry.path) }
                            },
                            onStageWithoutContent: onStageWithoutContent,
                            onSelect: onSelect,
                            onPreviewPath: onPreviewPath,
                            onShowDiffPath: onShowDiffPath,
                            onShowLocalStagedDiffPath: onShowLocalStagedDiffPath,
                            onShowLocalVersionPath: onShowLocalVersionPath,
                            onShowStagedVersionPath: onShowStagedVersionPath,
                            onShowStagedDiffPath: onShowStagedDiffPath,
                            onShowThreeVersionsPath: onShowThreeVersionsPath,
                            selectedPath: previewPath,
                            onPartial: onPartial,
                            binaryPaths: binaryPaths,
                            stagingPresence: stagingPresence,
                            contextSelectedPaths: $contextSelectedPaths,
                            contextEligiblePaths: contextEligiblePaths,
                            onIgnore: onIgnore,
                            onExclude: onExclude,
                            repositoryWorkdir: repositoryWorkdir,
                            onRestore: onRestore,
                            groupByDirectory: groupByDirectory,
                            expansionCommand: treeExpansionCommand,
                            expansionTarget: treeExpansionTarget,
                            onDropPaths: { paths in paths.forEach(onStage) },
                            onDropShelf: onUnshelve,
                            onDropShelfIntoChangeList: onUnshelveIntoChangeList,
                            onMovePathsToChangeList: onMovePathsToChangeList,
                            onStashPaths: onStashPaths,
                            onShowHistory: onShowHistory,
                            onEditGitignore: onEditGitignore,
                            onEditGitExclude: onEditGitExclude
                        )
                    }
                    if showIgnored {
                        RebasedIgnoredGroup(
                            entries: ignoredEntries,
                            rules: ignoredRules,
                            onStage: onStage
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// GitStagePanel's second splitter component: commit message and actions.
    private var commitEditorPanel: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 8) {
                Toggle("Amend", isOn: $amendMode)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .disabled(operationState != nil && !canAmendPausedRebase)
                Text("最近一次提交")
                    .font(.caption)
                    .foregroundStyle(.blue)
                if canAmendPausedRebase {
                    Label("Rebase edit", systemImage: "pencil.line")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("Stage the changes for this paused commit, then Amend before continuing the rebase.")
                }
                Menu {
                    if recentMessages.isEmpty {
                        Text("暂无最近提交信息")
                    } else {
                        ForEach(recentMessages, id: \.self) { message in
                            Button(message) { commitMessage = message }
                        }
                    }
                } label: {
                    Image(systemName: "clock")
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            TextEditor(text: $commitMessage)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 66, maxHeight: 92)
                .background(Design.Colors.chromeInset, in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if commitMessage.isEmpty {
                        Text("提交信息")
                            .foregroundStyle(.secondary)
                            .padding(.leading, 16)
                            .padding(.top, 16)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)

            HStack(spacing: 8) {
                Button("模板", action: onTemplate)
                Menu {
                    Button("模板") { onTemplate() }
                    Button("提交前检查") { onBeforeCommitSettings() }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                Spacer()
                Toggle(
                    "跳过 hooks",
                    isOn: Binding(
                        get: { skipHooks || alwaysSkipCommitHooks },
                        set: { skipHooks = $0 }
                    )
                )
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .disabled(alwaysSkipCommitHooks)
                Button(amendMode ? "Amend" : "提交", action: onCommit)
                    .buttonStyle(.bordered)
                    .disabled(
                        repo == nil
                            || !hasStaged
                            || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || (operationState != nil && (!canAmendPausedRebase || !amendMode))
                    )
                if !amendMode && !hasStaged && hasCommitAllEligibleChanges {
                    Button("Commit All") {
                        showCommitAllConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(operationState != nil || repo == nil || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if autoSquashCommitKind != nil {
                    Button("Commit and Rebase", action: onCommitAndRebase)
                        .buttonStyle(.borderedProminent)
                        .disabled(operationState != nil || repo == nil || amendMode || !hasStaged || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Button("提交并推送…", action: onCommitAndPush)
                    .buttonStyle(.bordered)
                    .disabled(operationState != nil || repo == nil || amendMode || !hasStaged || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if let commitFeedback {
                Text(commitFeedback)
                    .font(.caption)
                    .foregroundStyle(commitFeedback.hasPrefix("已") ? .green : .red)
                    .lineLimit(1)
                    .padding(.bottom, 7)
            }
        }
    }

    /// GitStageTree's model creates staged before unstaged when both contain
    /// files. With an empty/one-sided tree the reference UI keeps the stable
    /// Unstaged → Staged order, which is also what the empty state displays.
    @ViewBuilder
    private var changeGroups: some View {
        ForEach(visibleChangeLists, id: \.name) { list in
            RebasedChangeListHeader(
                list: list,
                onRename: onRenameChangeList,
                onDelete: onDeleteChangeList,
                onActivate: onActivateChangeList,
                onMovePaths: onMovePathsToChangeList,
                onDropShelfIntoChangeList: onUnshelveIntoChangeList
            )
            let listUnstaged = entries(unstagedEntries, in: list)
            let listStaged = entries(stagedEntries, in: list)
            if !listUnstaged.isEmpty {
                unstagedChangeGroup(for: list, entries: listUnstaged)
            }
            if !listStaged.isEmpty {
                stagedChangeGroup(for: list, entries: listStaged)
            }
            if listUnstaged.isEmpty && listStaged.isEmpty {
                Text("没有文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
            }
        }
    }

    private func unstagedChangeGroup(for list: ChangeListInfo, entries: [FileEntry]) -> some View {
        RebasedChangeGroup(
            title: "Unstaged Files",
            entries: entries,
            changeListName: list.name,
            changeLists: visibleChangeLists,
            emptyLabel: "没有文件",
            statusKind: { $0.unstaged },
            // This checkbox stages the currently unstaged side of the file.
            // A partially staged file can appear in both groups, so this must
            // not mirror the staged bit here.
            isChecked: { _ in false },
            onToggle: { entry, checked in
                if checked { onStage(entry.path) } else { onUnstage(entry.path) }
            },
            onStageWithoutContent: onStageWithoutContent,
            onSelect: onSelect,
            onPreviewPath: onPreviewPath,
            onShowDiffPath: onShowDiffPath,
            onShowLocalStagedDiffPath: onShowLocalStagedDiffPath,
            onShowLocalVersionPath: onShowLocalVersionPath,
            onShowStagedVersionPath: onShowStagedVersionPath,
            onShowStagedDiffPath: onShowStagedDiffPath,
            onShowThreeVersionsPath: onShowThreeVersionsPath,
            selectedPath: previewPath,
            onPartial: onPartial,
            binaryPaths: binaryPaths,
            stagingPresence: stagingPresence,
            contextSelectedPaths: $contextSelectedPaths,
            contextEligiblePaths: contextEligiblePaths,
            onIgnore: onIgnore,
            onExclude: onExclude,
            repositoryWorkdir: repositoryWorkdir,
            onRestore: onRestore,
            groupByDirectory: groupByDirectory,
            expansionCommand: treeExpansionCommand,
            expansionTarget: treeExpansionTarget,
            onDropPaths: { paths in paths.forEach(onUnstage) },
            onDropShelf: onUnshelve,
            onDropShelfIntoChangeList: onUnshelveIntoChangeList,
            onMovePathsToChangeList: onMovePathsToChangeList,
            onStashPaths: onStashPaths,
            onShowHistory: onShowHistory,
            onEditGitignore: onEditGitignore,
            onEditGitExclude: onEditGitExclude
        )
    }

    private func stagedChangeGroup(for list: ChangeListInfo, entries: [FileEntry]) -> some View {
        RebasedChangeGroup(
            title: "Staged Files",
            entries: entries,
            changeListName: list.name,
            changeLists: visibleChangeLists,
            emptyLabel: "没有文件",
            statusKind: { $0.staged },
            isChecked: { _ in true },
            onToggle: { entry, checked in
                if !checked { onUnstage(entry.path) }
            },
            onStageWithoutContent: onStageWithoutContent,
            onSelect: onSelect,
            onPreviewPath: onPreviewPath,
            onShowDiffPath: onShowDiffPath,
            onShowLocalStagedDiffPath: onShowLocalStagedDiffPath,
            onShowLocalVersionPath: onShowLocalVersionPath,
            onShowStagedVersionPath: onShowStagedVersionPath,
            onShowStagedDiffPath: onShowStagedDiffPath,
            onShowThreeVersionsPath: onShowThreeVersionsPath,
            selectedPath: previewPath,
            onPartial: onPartial,
            binaryPaths: binaryPaths,
            stagingPresence: stagingPresence,
            contextSelectedPaths: $contextSelectedPaths,
            contextEligiblePaths: contextEligiblePaths,
            onIgnore: onIgnore,
            onExclude: onExclude,
            repositoryWorkdir: repositoryWorkdir,
            onRestore: onRestore,
            groupByDirectory: groupByDirectory,
            expansionCommand: treeExpansionCommand,
            expansionTarget: treeExpansionTarget,
            onDropPaths: { paths in paths.forEach(onStage) },
            onDropShelf: onUnshelve,
            onDropShelfIntoChangeList: onUnshelveIntoChangeList,
            onMovePathsToChangeList: onMovePathsToChangeList,
            onStashPaths: onStashPaths,
            onShowHistory: onShowHistory,
            onEditGitignore: onEditGitignore,
            onEditGitExclude: onEditGitExclude
        )
    }

    private var stashContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onStash) {
                    Label("Stash…", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Refresh Stashes")
                Spacer()
                Toggle(isOn: $stashSplitPreviewEnabled) {
                    Image(systemName: "rectangle.split.2x1")
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(stashSplitPreviewEnabled ? "Hide split preview" : "Show split preview")
                Button("Clear All", role: .destructive) {
                    showClearStashesConfirmation = true
                }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(stashes.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if isShelfPreviewVisible || (isStashPreviewVisible && stashSplitPreviewEnabled) {
                HSplitView {
                    stashList
                        .frame(minWidth: 170, idealWidth: 220, maxWidth: 300)
                    Group {
                        if isStashPreviewVisible {
                            stashDiffPreview
                        } else {
                            PatchDiffPreviewView(
                                title: shelfPreviewTitle,
                                diffText: shelfDiffText,
                                repo: repo,
                                shelfRepo: shelfRepo,
                                shelfRootPath: shelfRootPath,
                                commitID: shelfPreviewID,
                                stashID: nil,
                                shelfName: shelfPreviewName,
                                isDeletedShelf: shelfPreviewIsDeleted,
                                onClose: {
                                    isShelfPreviewVisible = false
                                    shelfPreviewName = nil
                                    shelfPreviewIsDeleted = false
                                }
                            )
                        }
                    }
                    .frame(minWidth: 180, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                stashList
            }
        }
        .sheet(
            isPresented: Binding(
                get: {
                    isStashPreviewVisible
                        && !stashSplitPreviewEnabled
                        && resolvedStashPreviewIndex != nil
                },
                set: { isPresented in
                    guard !isPresented else { return }
                    isStashPreviewVisible = false
                    stashPreviewStashID = nil
                }
            )
        ) {
            stashDiffPreview
                .frame(minWidth: 720, minHeight: 480)
        }
    }

    private var stashDiffPreview: some View {
        PatchDiffPreviewView(
            title: stashPreviewTitle,
            diffText: stashDiffText,
            repo: repo,
            shelfRepo: nil,
            shelfRootPath: nil,
            commitID: nil,
            stashID: stashPreviewStashID,
            shelfName: nil,
            isDeletedShelf: false,
            onClose: {
                isStashPreviewVisible = false
                stashPreviewStashID = nil
            }
        )
    }

    private func applyShowShelfRequest(_ requestID: Int) {
        guard requestID > 0, requestID != lastAppliedShelfRequestID else { return }
        lastAppliedShelfRequestID = requestID
        tab = .stash
        onWorkspaceTabChange(true)
    }

    private var stashPreviewTitle: String {
        guard let index = resolvedStashPreviewIndex else {
            return String(localized: "Stash Diff")
        }
        let stash = stashes[index]
        let label = stash.message.isEmpty ? stash.shortId : stash.message
        return String(localized: "Stash Diff") + " · " + label
    }

    private var resolvedStashPreviewIndex: Int? {
        guard let stashPreviewStashID else { return nil }
        return stashIndex(forID: stashPreviewStashID, in: stashes)
    }

    private var shelfPreviewTitle: String {
        guard let name = shelfPreviewName else {
            return String(localized: "Shelf Diff")
        }
        return String(localized: "Shelf Diff") + " · " + name
    }

    private var shelfPreviewID: String? {
        guard let name = shelfPreviewName else { return nil }
        return shelves.first(where: { $0.name == name })?.id
            ?? deletedShelves.first(where: { $0.name == name })?.id
    }

    private var stashList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                stashSection
                shelfSection
            }
            .padding(12)
        }
    }

    private var stashSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                guard !stashes.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    stashesExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: stashes.isEmpty || !stashesExpanded ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.bold))
                    Text("Stashes")
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(stashes.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            if stashes.isEmpty {
                Text("No stashed changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
            } else if stashesExpanded {
                ForEach(stashes, id: \.id) { stash in
                    HStack(spacing: 7) {
                        Image(systemName: "tray.full")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(stash.message.isEmpty ? "WIP" : stash.message)
                                .lineLimit(1)
                            Text(stash.shortId)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Menu {
                            Button("Apply (Keep)") { onApplyStash(stash.id, false) }
                            Button("Apply + Restore Index (Keep)") { onApplyStash(stash.id, true) }
                            Button("Pop (Apply and Remove)") { onPopStash(stash.id, false) }
                            Button("Pop + Restore Index") { onPopStash(stash.id, true) }
                            Button("Unstash As…") { onUnstashAs(stash.id) }
                            Button("Create Branch from Stash…") { onStashBranch(stash.id) }
                            Button("View Diff") { onStashDiffPreview(stash.id) }
                            Divider()
                            Button("Drop", role: .destructive) { onDropStash(stash.id) }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 24, height: 24)
                        }
                        .menuStyle(.borderlessButton)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 5)
                    .background(
                        selectedStashID == stash.id || stashPreviewStashID == stash.id
                            ? Color.accentColor.opacity(0.16)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedStashID = stash.id
                        if stashSplitPreviewEnabled {
                            onStashDiffPreview(stash.id)
                        }
                    }
                }
            }
        }
        .onChange(of: stashes.map(\.id), initial: false) { _, ids in
            if let selectedStashID, !ids.contains(selectedStashID) {
                self.selectedStashID = nil
            }
            if let stashPreviewStashID, !ids.contains(stashPreviewStashID) {
                self.stashPreviewStashID = nil
                self.isStashPreviewVisible = false
            }
        }
        .onDeleteCommand {
            guard let selectedStashID,
                  stashes.contains(where: { $0.id == selectedStashID }) else { return }
            self.selectedStashID = nil
            onDropStash(selectedStashID)
        }
    }

    private func toggleShelfExpansion(_ id: String) {
        if expandedShelfIDs.contains(id) {
            expandedShelfIDs.remove(id)
        } else {
            expandedShelfIDs.insert(id)
        }
    }

    private func beginShelfRename(_ shelf: ShelveInfo) {
        guard canMutateShelfMetadata else { return }
        editingShelfID = shelf.id
        editingShelfDescription = shelfDisplayDescription(shelf)
        DispatchQueue.main.async {
            focusedShelfID = shelf.id
        }
    }

    private func cancelShelfRename() {
        editingShelfID = nil
        editingShelfDescription = ""
        focusedShelfID = nil
    }

    private func commitShelfRename(_ shelf: ShelveInfo) {
        guard canMutateShelfMetadata,
              editingShelfID == shelf.id else { return }
        let description = editingShelfDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldDescription = shelfDisplayDescription(shelf)
        cancelShelfRename()
        guard !description.isEmpty, description != oldDescription else { return }
        onRenameShelveDescription(shelf.name, description)
    }

    private func handleShelfRenameKeyPress() -> KeyPress.Result {
        guard editingShelfID == nil else { return .ignored }
        let selected: ShelveInfo? = if selectedShelfIDs.count == 1 {
            shelves.first { selectedShelfIDs.contains($0.id) }
        } else if selectedDeletedShelfIDs.count == 1 {
            deletedShelves.first { selectedDeletedShelfIDs.contains($0.id) }
        } else {
            nil
        }
        guard let selected else { return .ignored }
        beginShelfRename(selected)
        return .handled
    }

    private var shelfRenameKeyEquivalent: KeyEquivalent {
        KeyEquivalent(Character(UnicodeScalar(NSF2FunctionKey)!))
    }

    private func shelfFolderID(shelfID: String, path: String) -> String {
        "\(shelfID)\u{1F}\(path)"
    }

    private func toggleShelfFolder(_ shelfID: String, _ path: String) {
        let id = shelfFolderID(shelfID: shelfID, path: path)
        if collapsedShelfFolders.contains(id) {
            collapsedShelfFolders.remove(id)
        } else {
            collapsedShelfFolders.insert(id)
        }
    }

    private func visibleShelfRows(for shelf: ShelveInfo) -> [ShelfTreeRow] {
        let rows = shelfTreeRows(paths: shelf.paths, groupByDirectory: shelfGroupByDirectory)
        guard shelfGroupByDirectory else { return rows }
        return rows.filter { row in
            !rows.contains { folder in
                folder.isFolder
                    && row.path.hasPrefix(folder.path + "/")
                    && collapsedShelfFolders.contains(
                        shelfFolderID(shelfID: shelf.id, path: folder.path)
                    )
            }
        }
    }

    private func selectedShelfPaths(for shelf: ShelveInfo) -> [String] {
        shelf.paths.filter {
            selectedShelfMemberIDs.contains(shelfMemberSelectionID(shelfID: shelf.id, path: $0))
        }
    }

    private func requestUnshelve(_ shelf: ShelveInfo, paths: [String]? = nil) {
        pendingUnshelve = ShelfUnshelveRequest(
            name: shelf.name,
            paths: paths,
            rootPath: selectedShelfRootPath
        )
    }

    private func selectShelf(_ shelfID: String) {
        if NSEvent.modifierFlags.contains(.command) {
            if selectedShelfIDs.contains(shelfID) {
                selectedShelfIDs.remove(shelfID)
            } else {
                selectedShelfIDs.insert(shelfID)
            }
        } else {
            selectedShelfIDs = [shelfID]
        }
    }

    private func selectShelfMember(_ shelfID: String, _ path: String) {
        let id = shelfMemberSelectionID(shelfID: shelfID, path: path)
        if NSEvent.modifierFlags.contains(.command) {
            if selectedShelfMemberIDs.contains(id) {
                selectedShelfMemberIDs.remove(id)
            } else {
                selectedShelfMemberIDs.insert(id)
            }
        } else {
            selectedShelfMemberIDs = [id]
        }
    }

    /// IntelliJ exposes the Shelf tree through a DeleteProvider, so Delete
    /// must use the current tree selection rather than only the visible menu
    /// button. A list selection takes precedence over child selections from
    /// that list; selections from different lists are all preserved.
    private func deleteSelectedShelfItems() {
        guard canMutateShelfMetadata else { return }
        let plan = shelfDeletePlan(
            visibleShelves: visibleShelves,
            deletedShelves: deletedShelves,
            selectedShelfIDs: selectedShelfIDs,
            selectedShelfMemberIDs: selectedShelfMemberIDs,
            selectedDeletedShelfIDs: selectedDeletedShelfIDs,
            selectedDeletedShelfMemberIDs: selectedDeletedShelfMemberIDs
        )
        guard !plan.isEmpty else { return }

        selectedShelfIDs.removeAll()
        selectedShelfMemberIDs.removeAll()
        selectedDeletedShelfIDs.removeAll()
        selectedDeletedShelfMemberIDs.removeAll()

        // IntelliJ's DeleteProvider submits one mixed plan to
        // ShelvedChangesViewManager. Keep this as one callback so the
        // operation layer can serialize all four scopes and publish one
        // notification/undo lifecycle.
        onDeleteShelfPlan(plan)
    }

    private func selectDeletedShelf(_ shelfID: String) {
        if NSEvent.modifierFlags.contains(.command) {
            if selectedDeletedShelfIDs.contains(shelfID) {
                selectedDeletedShelfIDs.remove(shelfID)
            } else {
                selectedDeletedShelfIDs.insert(shelfID)
            }
        } else {
            selectedDeletedShelfIDs = [shelfID]
        }
    }

    private func visibleDeletedShelfRows(for shelf: ShelveInfo) -> [ShelfTreeRow] {
        let rows = shelfTreeRows(paths: shelf.paths, groupByDirectory: shelfGroupByDirectory)
        guard shelfGroupByDirectory else { return rows }
        return rows.filter { row in
            !rows.contains { folder in
                folder.isFolder
                    && row.path.hasPrefix(folder.path + "/")
                    && collapsedShelfFolders.contains(
                        shelfFolderID(shelfID: shelf.id, path: folder.path)
                    )
            }
        }
    }

    private func selectedDeletedShelfPaths(for shelf: ShelveInfo) -> [String] {
        shelf.paths.filter {
            selectedDeletedShelfMemberIDs.contains(
                shelfMemberSelectionID(shelfID: shelf.id, path: $0)
            )
        }
    }

    private func selectDeletedShelfMember(_ shelfID: String, _ path: String) {
        let id = shelfMemberSelectionID(shelfID: shelfID, path: path)
        if NSEvent.modifierFlags.contains(.command) {
            if selectedDeletedShelfMemberIDs.contains(id) {
                selectedDeletedShelfMemberIDs.remove(id)
            } else {
                selectedDeletedShelfMemberIDs.insert(id)
            }
        } else {
            selectedDeletedShelfMemberIDs = [id]
        }
    }

    private func unshelveDeletedMember(
        _ name: String,
        paths: [String],
        removeApplied: Bool
    ) {
        selectedDeletedShelfMemberIDs.removeAll()
        onUnshelveDeletedPathsWithOptions(name, paths, removeApplied)
    }

    @ViewBuilder
    private func shelfMemberContextMenu(for shelf: ShelveInfo, path: String) -> some View {
        Button("Unshelve Changes") {
            onUnshelvePathsWithOptions(shelf.name, [path], false)
        }
        .disabled(!canApplyShelfWorktree)
        Button("Unshelve Changes and Remove") {
            onUnshelvePathsWithOptions(shelf.name, [path], true)
        }
        .disabled(!canApplyShelfWorktree)
        Divider()
        Button("Unshelve") {
            requestUnshelve(shelf, paths: [path])
        }
        .disabled(!canApplyShelfWorktree)
        Button("Drop", role: .destructive) {
            onDropShelvePaths(shelf.name, [path])
        }
        .disabled(!canMutateShelfMetadata)
        if visibleShelves.count > 1 {
            Menu("Move to Shelf") {
                ForEach(visibleShelves, id: \.id) { target in
                    if target.name != shelf.name {
                        Button(target.name) {
                            onMoveShelfPaths(shelf.name, target.name, [path])
                        }
                        .disabled(!canMutateShelfMetadata)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func deletedShelfMemberContextMenu(for shelf: ShelveInfo, path: String) -> some View {
        Button("Unshelve Changes") {
            unshelveDeletedMember(shelf.name, paths: [path], removeApplied: false)
        }
        .disabled(!canApplyShelfWorktree)
        Button("Unshelve Changes and Remove") {
            unshelveDeletedMember(shelf.name, paths: [path], removeApplied: true)
        }
        .disabled(!canApplyShelfWorktree)
        let selectedPaths = selectedDeletedShelfPaths(for: shelf)
        if selectedPaths.count > 1 {
            Divider()
            Button("Unshelve Selected Changes") {
                unshelveDeletedMember(shelf.name, paths: selectedPaths, removeApplied: false)
            }
            .disabled(!canApplyShelfWorktree)
            Button("Unshelve Selected Changes and Remove") {
                unshelveDeletedMember(shelf.name, paths: selectedPaths, removeApplied: true)
            }
            .disabled(!canApplyShelfWorktree)
        }
        Divider()
        let pathsToDelete = selectedPaths.contains(path) ? selectedPaths : [path]
        Button(
            pathsToDelete.count > 1 ? "Delete Selected Permanently" : "Delete Permanently",
            role: .destructive
        ) {
            onDeleteDeletedShelfPaths(shelf.name, pathsToDelete)
        }
        .disabled(!canMutateShelfMetadata)
        Button("View Diff") { onShelveDiffPreview(shelf.name) }
    }

    @ViewBuilder
    private func shelfTreeRowView(_ row: ShelfTreeRow, shelf: ShelveInfo) -> some View {
        if row.isFolder {
            Button {
                toggleShelfFolder(shelf.id, row.path)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsedShelfFolders.contains(
                        shelfFolderID(shelfID: shelf.id, path: row.path)
                    ) ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.bold))
                    Image(systemName: "folder")
                        .font(.caption2)
                    Text(row.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.leading, 34 + CGFloat(row.depth * 14))
            .padding(.vertical, 2)
        } else {
            let selected = selectedShelfMemberIDs.contains(
                shelfMemberSelectionID(shelfID: shelf.id, path: row.path)
            )
            Button {
                selectShelfMember(shelf.id, row.path)
                onShelveDiffPreview(shelf.name)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(row.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.leading, 34 + CGFloat(row.depth * 14))
            .padding(.vertical, 2)
            .background(
                selected ? Color.accentColor.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
            .draggable("arbor-shelf-member:\(shelf.name)\u{1F}\(row.path)")
            .contextMenu {
                shelfMemberContextMenu(for: shelf, path: row.path)
            }
        }
    }

    private func moveDroppedShelfMember(_ payloads: [String], to targetShelfName: String) -> Bool {
        guard canMutateShelfMetadata else { return false }
        guard let payload = payloads.first(where: {
            $0.hasPrefix("arbor-shelf-member:")
        }) else { return false }
        let body = String(payload.dropFirst("arbor-shelf-member:".count))
        let components = body.split(separator: "\u{1F}", maxSplits: 1)
        guard components.count == 2 else { return false }
        let sourceShelfName = String(components[0])
        let path = String(components[1])
        guard sourceShelfName != targetShelfName else { return false }
        onMoveShelfPaths(sourceShelfName, targetShelfName, [path])
        return true
    }

    @ViewBuilder
    private func shelfItemView(_ shelf: ShelveInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Button {
                    selectShelf(shelf.id)
                } label: {
                    Image(systemName: selectedShelfIDs.contains(shelf.id)
                        ? "checkmark.circle.fill"
                        : "circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    selectedShelfIDs.contains(shelf.id)
                        ? Color.accentColor
                        : Color.secondary
                )
                Button {
                    toggleShelfExpansion(shelf.id)
                } label: {
                    Image(systemName: expandedShelfIDs.contains(shelf.id) ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                        .frame(width: 14, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Image(systemName: shelf.isRecycled ? "arrow.uturn.backward.circle" : "archivebox")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    shelfTitleView(shelf)
                    HStack(spacing: 6) {
                        Text(shelf.shortId)
                            .font(.system(size: 10, design: .monospaced))
                        Text("· \(shelf.paths.count) files")
                            .font(.caption2)
                        if !shelfTimestampLabel(shelf.timestamp).isEmpty {
                            Text("· \(shelfTimestampLabel(shelf.timestamp))")
                                .font(.caption2)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Menu {
                    Button("Apply (Keep)") {
                        onUnshelve(shelf.name)
                    }
                    .disabled(!canApplyShelfWorktree)
                    Button("Pop (Apply and Remove)") {
                        onPopShelve(shelf.name)
                    }
                    .disabled(!canApplyShelfWorktree)
                    Divider()
                    Button("View Diff") { onShelveDiffPreview(shelf.name) }
                    Button("Export Patch…") { onExportShelve(shelf.name) }
                        .disabled(!canMutateShelfMetadata)
                    Button("Rename…") {
                        onRenameShelve(shelf.name, shelfDisplayDescription(shelf))
                    }
                    .disabled(!canMutateShelfMetadata)
                    Button("Unshelve") { requestUnshelve(shelf) }
                        .disabled(!canApplyShelfWorktree)
                    if !selectedShelfPaths(for: shelf).isEmpty {
                        Divider()
                        Button("Unshelve Selected Changes") {
                            onUnshelvePathsWithOptions(
                                shelf.name,
                                selectedShelfPaths(for: shelf),
                                false
                            )
                        }
                        .disabled(!canApplyShelfWorktree)
                        Button("Unshelve Selected Changes and Remove") {
                            onUnshelvePathsWithOptions(
                                shelf.name,
                                selectedShelfPaths(for: shelf),
                                true
                            )
                        }
                        .disabled(!canApplyShelfWorktree)
                        Button("Unshelve Selected") {
                            requestUnshelve(shelf, paths: selectedShelfPaths(for: shelf))
                        }
                        .disabled(!canApplyShelfWorktree)
                        Button("Drop Selected", role: .destructive) {
                            onDropShelvePaths(shelf.name, selectedShelfPaths(for: shelf))
                        }
                        .disabled(!canMutateShelfMetadata)
                    }
                    Button("Drop", role: .destructive) { onDropShelve(shelf.name) }
                        .disabled(!canMutateShelfMetadata)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 5)
            .background(
                shelfPreviewName == shelf.name
                    ? Color.accentColor.opacity(0.16)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
            .contentShape(Rectangle())
            .draggable("arbor-shelf:\(shelf.name)")
            .dropDestination(for: String.self) { payloads, _ in
                moveDroppedShelfMember(payloads, to: shelf.name)
            }
            .onTapGesture { onShelveDiffPreview(shelf.name) }

            if expandedShelfIDs.contains(shelf.id) {
                ForEach(visibleShelfRows(for: shelf)) { row in
                    shelfTreeRowView(row, shelf: shelf)
                }
            }
        }
    }

    @ViewBuilder
    private func deletedShelfTreeRowView(_ row: ShelfTreeRow, shelf: ShelveInfo) -> some View {
        if row.isFolder {
            Button {
                toggleShelfFolder(shelf.id, row.path)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsedShelfFolders.contains(
                        shelfFolderID(shelfID: shelf.id, path: row.path)
                    ) ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.bold))
                    Image(systemName: "folder")
                        .font(.caption2)
                    Text(row.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.leading, 55 + CGFloat(row.depth * 14))
            .padding(.vertical, 2)
        } else {
            let selected = selectedDeletedShelfMemberIDs.contains(
                shelfMemberSelectionID(shelfID: shelf.id, path: row.path)
            )
            Button {
                selectDeletedShelfMember(shelf.id, row.path)
                onShelveDiffPreview(shelf.name)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(row.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.leading, 55 + CGFloat(row.depth * 14))
            .padding(.vertical, 2)
            .background(
                selected ? Color.accentColor.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
            .contextMenu {
                deletedShelfMemberContextMenu(for: shelf, path: row.path)
            }
        }
    }

    @ViewBuilder
    private func recentlyDeletedShelfSection() -> some View {
        if !deletedShelves.isEmpty {
            Divider()
                .padding(.vertical, 3)
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        deletedShelvesExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: deletedShelvesExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.bold))
                        Image(systemName: "trash")
                            .font(.caption2)
                        Text("Recently Deleted")
                            .font(.system(size: 12, weight: .semibold))
                        Text("\(deletedShelves.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .foregroundStyle(.secondary)

            if deletedShelvesExpanded {
                ForEach(deletedShelves, id: \.id) { shelf in
                    HStack(spacing: 7) {
                        Button {
                            selectDeletedShelf(shelf.id)
                        } label: {
                            Image(systemName: selectedDeletedShelfIDs.contains(shelf.id)
                                ? "checkmark.circle.fill"
                                : "circle")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(
                            selectedDeletedShelfIDs.contains(shelf.id)
                                ? Color.accentColor
                                : Color.secondary
                        )
                        Button {
                            toggleShelfExpansion(shelf.id)
                        } label: {
                            Image(systemName: expandedShelfIDs.contains(shelf.id)
                                ? "chevron.down"
                                : "chevron.right")
                                .font(.caption2.weight(.bold))
                                .frame(width: 14, height: 20)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        Image(systemName: "archivebox.fill")
                            .font(.caption)
                        .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            shelfTitleView(shelf)
                            HStack(spacing: 5) {
                                Text("\(shelf.paths.count) files")
                                if !shelfTimestampLabel(shelf.timestamp).isEmpty {
                                    Text("· \(shelfTimestampLabel(shelf.timestamp))")
                                }
                            }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Menu {
                            Button("Unshelve Silently") {
                                selectedDeletedShelfIDs.remove(shelf.id)
                                onUnshelveDeletedShelvesSilently(
                                    [shelf.name],
                                    removeAppliedFilesFromShelf
                                )
                            }
                            .disabled(!canApplyShelfWorktree)
                            let selectedPaths = selectedDeletedShelfPaths(for: shelf)
                            if !selectedPaths.isEmpty {
                                Divider()
                                Button("Unshelve Selected Changes") {
                                    unshelveDeletedMember(
                                        shelf.name,
                                        paths: selectedPaths,
                                        removeApplied: false
                                    )
                                }
                                .disabled(!canApplyShelfWorktree)
                                Button("Unshelve Selected Changes and Remove") {
                                    unshelveDeletedMember(
                                        shelf.name,
                                        paths: selectedPaths,
                                        removeApplied: true
                                    )
                                }
                                .disabled(!canApplyShelfWorktree)
                            }
                            Divider()
                            Button("Rename…") {
                                onRenameShelve(shelf.name, shelfDisplayDescription(shelf))
                            }
                            .disabled(!canMutateShelfMetadata)
                            Button("Restore") { onRestoreDeletedShelve(shelf.name) }
                                .disabled(!canMutateShelfMetadata)
                            Button("Delete Permanently", role: .destructive) {
                                onDeleteDeletedShelve(shelf.name)
                            }
                            .disabled(!canMutateShelfMetadata)
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 24, height: 24)
                        }
                        .menuStyle(.borderlessButton)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .padding(.leading, 20)

                    if expandedShelfIDs.contains(shelf.id) {
                        ForEach(visibleDeletedShelfRows(for: shelf)) { row in
                            deletedShelfTreeRowView(row, shelf: shelf)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var shelfRows: some View {
        if visibleShelves.isEmpty {
            Text("No shelves")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
        } else if shelvesExpanded {
            ForEach(visibleShelves, id: \.id, content: shelfItemView)
        }
    }

    @ViewBuilder
    private var selectedShelfActionsMenu: some View {
        let plan = shelfDeletePlan(
            visibleShelves: visibleShelves,
            deletedShelves: deletedShelves,
            selectedShelfIDs: selectedShelfIDs,
            selectedShelfMemberIDs: selectedShelfMemberIDs,
            selectedDeletedShelfIDs: selectedDeletedShelfIDs,
            selectedDeletedShelfMemberIDs: selectedDeletedShelfMemberIDs
        )
        if !plan.isEmpty {
            Menu {
                if !plan.activeShelfNames.isEmpty {
                    Button("Apply (Keep)") {
                        let names = plan.activeShelfNames
                        selectedShelfIDs.removeAll()
                        selectedShelfMemberIDs.removeAll()
                        onUnshelveShelvesSilently(names, false)
                    }
                    .disabled(!canApplyShelfWorktree)
                    Button("Pop (Apply and Remove)") {
                        let names = plan.activeShelfNames
                        selectedShelfIDs.removeAll()
                        selectedShelfMemberIDs.removeAll()
                        onPopShelves(names)
                    }
                    .disabled(!canApplyShelfWorktree)
                    Button("Drop Selected Shelves", role: .destructive) {
                        let names = plan.activeShelfNames
                        selectedShelfIDs.removeAll()
                        selectedShelfMemberIDs.removeAll()
                        onDropShelves(names)
                    }
                    .disabled(!canMutateShelfMetadata)
                    if plan.activeShelfNames.count > 1 {
                        Divider()
                        Button("Unshelve Selected Shelves…") {
                            pendingUnshelveShelves = ShelfBatchUnshelveRequest(
                                names: plan.activeShelfNames,
                                rootPath: selectedShelfRootPath
                            )
                        }
                        .disabled(!canApplyShelfWorktree)
                    }
                }
                if !plan.activePathGroups.isEmpty {
                    Divider()
                    if plan.activePathGroups.count > 1 {
                        Button("Unshelve Selected Changes into Changelist…") {
                            pendingUnshelveMemberGroups = ShelfMemberBatchUnshelveRequest(
                                groups: plan.activePathGroups,
                                rootPath: selectedShelfRootPath
                            )
                        }
                        .disabled(!canApplyShelfWorktree)
                    }
                    Button("Unshelve Selected Changes") {
                        selectedShelfMemberIDs.removeAll()
                        onUnshelvePathGroupsWithOptions(plan.activePathGroups, false, false)
                    }
                    .disabled(!canApplyShelfWorktree)
                    Button("Unshelve Selected Changes and Remove") {
                        selectedShelfMemberIDs.removeAll()
                        onUnshelvePathGroupsWithOptions(plan.activePathGroups, true, false)
                    }
                    .disabled(!canApplyShelfWorktree)
                    Button("Drop Selected Changes", role: .destructive) {
                        selectedShelfMemberIDs.removeAll()
                        onDropShelvePathGroups(plan.activePathGroups)
                    }
                    .disabled(!canMutateShelfMetadata)
                }
                if !plan.deletedShelfNames.isEmpty {
                    Divider()
                    Button("Unshelve Deleted Shelves Silently") {
                        let names = plan.deletedShelfNames
                        selectedDeletedShelfIDs.removeAll()
                        selectedDeletedShelfMemberIDs.removeAll()
                        onUnshelveDeletedShelvesSilently(
                            names,
                            removeAppliedFilesFromShelf
                        )
                    }
                    .disabled(!canApplyShelfWorktree)
                    .keyboardShortcut("u", modifiers: [.control, .option])
                    Button("Restore Selected") {
                        let names = plan.deletedShelfNames
                        selectedDeletedShelfIDs.removeAll()
                        onRestoreDeletedShelves(names)
                    }
                    .disabled(!canMutateShelfMetadata)
                    Button("Delete Permanently Selected", role: .destructive) {
                        let names = plan.deletedShelfNames
                        selectedDeletedShelfIDs.removeAll()
                        onDeleteDeletedShelves(names, true)
                    }
                    .disabled(!canMutateShelfMetadata)
                }
                if !plan.deletedPathGroups.isEmpty {
                    Divider()
                    Button("Unshelve Deleted Changes") {
                        selectedDeletedShelfMemberIDs.removeAll()
                        onUnshelvePathGroupsWithOptions(plan.deletedPathGroups, false, true)
                    }
                    .disabled(!canApplyShelfWorktree)
                    Button("Unshelve Deleted Changes and Remove") {
                        selectedDeletedShelfMemberIDs.removeAll()
                        onUnshelvePathGroupsWithOptions(plan.deletedPathGroups, true, true)
                    }
                    .disabled(!canApplyShelfWorktree)
                    Button("Delete Selected Permanently", role: .destructive) {
                        selectedDeletedShelfMemberIDs.removeAll()
                        onDeleteDeletedShelfPathGroups(plan.deletedPathGroups)
                    }
                    .disabled(!canMutateShelfMetadata)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(.secondary)
            .help("Actions for selected Shelves and changes")
        }
    }

    private var shelfHeaderView: some View {
        HStack(spacing: 6) {
            Button {
                guard !visibleShelves.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    shelvesExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: visibleShelves.isEmpty || !shelvesExpanded ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.bold))
                    Text("Shelves")
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(visibleShelves.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            if shelfRootOptions.count > 1 {
                Picker("Shelf Root", selection: Binding(
                    get: { selectedShelfRootPath },
                    set: { onShelfRootChange($0) }
                )) {
                    ForEach(shelfRootOptions, id: \.path) { root in
                        let path = canonicalExternalLogPath(root.path)
                        Text(root.relativePath == "."
                            ? root.displayName
                            : root.displayName + " · " + root.relativePath)
                            .tag(path)
                            .help(path)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(maxWidth: 190)
                if isShelfRootLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Spacer()
            selectedShelfActionsMenu
            Menu {
                Button("Import Patches…") { onImportShelve(shelfRootPath) }
                    .disabled(!canMutateShelfMetadata)
                Divider()
                Toggle("Group by Directory", isOn: $shelfGroupByDirectory)
                    Toggle("Show Already Unshelved", isOn: showRecycledShelvesBinding)
                Divider()
                Button("Clear Already Unshelved", role: .destructive) {
                    onCleanRecycledShelves()
                }
                .disabled(!canMutateShelfMetadata
                    || !shelves.contains(where: \.isRecycled))
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(.secondary)
            .help("Shelf view settings")
        }
    }

    private var shelfSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            shelfHeaderView
            if isShelfRootReadOnly || shelfRootError != nil {
                HStack(spacing: 6) {
                    Image(systemName: isShelfRootReadOnly ? "lock" : "exclamationmark.triangle")
                    if isShelfRootReadOnly {
                        Text(canMutateShelfMetadata
                            ? "Secondary root: whole/member Apply, Pop, Unshelve, Drop, Restore, Delete, target-Changelist dialog, Patch import/export and recycled cleanup are available"
                            : "Secondary root is read-only until its Shelf repository is loaded")
                    } else if let shelfRootError {
                        Text(shelfRootError)
                            .lineLimit(2)
                    }
                }
                .font(.caption2)
                .foregroundStyle(isShelfRootReadOnly ? .secondary : Design.Colors.error)
                .padding(.horizontal, 22)
            }
            shelfRows

            recentlyDeletedShelfSection()
        }
        .onChange(of: shelves.map(\.id)) { _, ids in
            selectedShelfIDs.formIntersection(Set(ids))
        }
        .onChange(of: shelves.map { shelf in
            "\(shelf.id)\u{1E}\(shelf.paths.joined(separator: "\u{1F}"))"
        }) { _, _ in
            pruneShelfMemberSelection()
        }
        .onChange(of: deletedShelves.map(\.id)) { _, ids in
            selectedDeletedShelfIDs.formIntersection(Set(ids))
            pruneDeletedShelfMemberSelection()
        }
        .onChange(of: deletedShelves.map { shelf in
            "\(shelf.id)\u{1E}\(shelf.paths.joined(separator: "\u{1F}"))"
        }) { _, _ in
            pruneDeletedShelfMemberSelection()
        }
        .onKeyPress(shelfRenameKeyEquivalent, action: handleShelfRenameKeyPress)
        .onDeleteCommand(perform: deleteSelectedShelfItems)
        .dropDestination(for: String.self) { paths, _ in
            guard !isShelfRootReadOnly, !isShelfRootLoading else { return false }
            let changedPaths = Set(entries.map(\.path))
            let validPaths = paths.filter { changedPaths.contains($0) }
            guard !validPaths.isEmpty else { return false }
            onShelvePaths(validPaths)
            return true
        }
    }

    private func pruneShelfMemberSelection() {
        let validMemberIDs = Set(
            shelves.flatMap { shelf in
                shelf.paths.map {
                    shelfMemberSelectionID(shelfID: shelf.id, path: $0)
                }
            }
        )
        selectedShelfMemberIDs.formIntersection(validMemberIDs)
    }

    private func pruneDeletedShelfMemberSelection() {
        let validMemberIDs = Set(
            deletedShelves.flatMap { shelf in
                shelf.paths.map {
                    shelfMemberSelectionID(shelfID: shelf.id, path: $0)
                }
            }
        )
        selectedDeletedShelfMemberIDs.formIntersection(validMemberIDs)
    }

/// Stash/Shelf 的 diff 留在同一个 Saved Patches 工作区内，复用文件列表与
/// patch 承载区。两者都优先使用提交树的结构化 FileDiff，支持真正的
/// side-by-side/unified 切换；原始 patch 只作为 binary、路径解析或旧对象
/// 不可读取时的安全 fallback。
private struct PatchDiffPreviewView: View {
    let title: String
    let diffText: String?
    let repo: Repository?
    let shelfRepo: Repository?
    let shelfRootPath: String?
    let commitID: String?
    let stashID: String?
    let shelfName: String?
    let isDeletedShelf: Bool
    let onClose: () -> Void
    @State private var selectedFilePath: String?
    @State private var structuredDiff: FileDiff?
    @State private var structuredDiffError: String?
    @State private var presentationMode: DiffPresentationMode = .sideBySide
    @State private var compareShelfWithLocal = false

    private struct PatchFile: Identifiable, Hashable {
        let path: String
        let patch: String

        var id: String { path }
    }

    private var patchFiles: [PatchFile] {
        Self.parsePatchFiles(diffText ?? "")
    }

    private var visiblePatch: String {
        guard let selectedFilePath,
              let file = patchFiles.first(where: { $0.path == selectedFilePath }) else {
            return diffText ?? ""
        }
        return file.patch
    }

    private var supportsStructuredDiff: Bool {
        repo != nil && (commitID != nil || stashID != nil || shelfName != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if shelfName != nil {
                    Button {
                        compareShelfWithLocal.toggle()
                    } label: {
                        Label(
                            compareShelfWithLocal ? "View Diff" : "Compare with Local",
                            systemImage: "arrow.left.arrow.right"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Compare with Local")
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Hide patch preview")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Design.Colors.surface)

            if diffText != nil {
                if patchFiles.count > 1 {
                    HSplitView {
                        List(patchFiles, selection: $selectedFilePath) { file in
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.secondary)
                                Text(file.path)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .tag(file.path as String?)
                        }
                        .listStyle(.inset)
                        .frame(minWidth: 150, idealWidth: 210, maxWidth: 300)

                        selectedFilePreview
                    }
                } else {
                    selectedFilePreview
                }
            } else {
                ProgressView("Loading diff…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Design.Colors.canvas)
        .onChange(of: diffText) { _, _ in
            selectedFilePath = patchFiles.first?.path
        }
        .onChange(of: selectedFilePath) { _, path in
            loadStructuredDiff(path)
        }
        .onChange(of: commitID) { _, _ in
            loadStructuredDiff(selectedFilePath)
        }
        .onChange(of: stashID) { _, _ in
            loadStructuredDiff(selectedFilePath)
        }
        .onChange(of: shelfName) { _, _ in
            compareShelfWithLocal = false
            loadStructuredDiff(selectedFilePath)
        }
        .onChange(of: isDeletedShelf) { _, _ in
            loadStructuredDiff(selectedFilePath)
        }
        .onChange(of: compareShelfWithLocal) { _, _ in
            loadStructuredDiff(selectedFilePath)
        }
        .onAppear {
            compareShelfWithLocal = false
            selectedFilePath = patchFiles.first?.path
            loadStructuredDiff(patchFiles.first?.path)
        }
    }

    @ViewBuilder
    private var selectedFilePreview: some View {
        if let structuredDiff {
            if structuredDiff.binary {
                patchTextView(visiblePatch)
            } else if structuredDiff.hunks.isEmpty {
                Text("No changes")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Picker("Diff View", selection: $presentationMode) {
                            ForEach(DiffPresentationMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Design.Colors.surface)
                    if presentationMode == .sideBySide {
                        SideBySideDiffView(fileDiff: structuredDiff)
                    } else {
                        UnifiedDiffView(fileDiff: structuredDiff)
                    }
                }
            }
        } else if let structuredDiffError {
            VStack(alignment: .leading, spacing: 8) {
                Label("Unable to load diff", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Design.Colors.error)
                Text(structuredDiffError)
                    .font(.caption)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                patchTextView(visiblePatch)
            }
            .padding(10)
        } else if supportsStructuredDiff, !patchFiles.isEmpty {
            ProgressView("Loading diff…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            patchTextView(visiblePatch)
        }
    }

    private func loadStructuredDiff(_ path: String?) {
        structuredDiff = nil
        structuredDiffError = nil
        guard let repo, let path else { return }
        let expectedCommitID = commitID
        let expectedStashID = stashID
        let expectedShelfName = shelfName
        let expectedShelfRootPath = shelfRootPath
        let expectedIsDeletedShelf = isDeletedShelf
        let expectedCompareShelfWithLocal = compareShelfWithLocal
        let expectedPath = path
        Task.detached(priority: .userInitiated) {
            do {
                let diff: FileDiff
                if let expectedShelfName {
                    guard let shelfRepo else {
                        throw EngineError.GitOperation(message: "Shelf root repository is unavailable")
                    }
                    if expectedIsDeletedShelf {
                        diff = try shelfRepo.shelveDeletedFileDiffWithSettings(
                            name: expectedShelfName,
                            path: expectedPath,
                            withLocal: expectedCompareShelfWithLocal,
                            settings: makeArborGitDiffSettings()
                        )
                    } else {
                        diff = try shelfRepo.shelveFileDiffWithSettings(
                            name: expectedShelfName,
                            path: expectedPath,
                            withLocal: expectedCompareShelfWithLocal,
                            settings: makeArborGitDiffSettings()
                        )
                    }
                } else if let expectedStashID {
                    let currentStashes = try repo.stashList()
                    guard let currentIndex = currentStashes.firstIndex(where: { $0.id == expectedStashID }) else {
                        throw NSError(
                            domain: "Arbor.StashPreview",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "The selected stash no longer exists."]
                        )
                    }
                    diff = try repo.stashFileDiffWithSettings(
                        index: UInt32(currentIndex),
                        path: expectedPath,
                        settings: makeArborGitDiffSettings()
                    )
                } else if let expectedCommitID {
                    diff = try repo.commitFileDiffWithSettings(
                        commitId: expectedCommitID,
                        parentIndex: 0,
                        path: expectedPath,
                        settings: makeArborGitDiffSettings()
                    )
                } else {
                    return
                }
                await MainActor.run {
                    guard self.commitID == expectedCommitID,
                          self.stashID == expectedStashID,
                          self.shelfName == expectedShelfName,
                          self.shelfRootPath == expectedShelfRootPath,
                          self.isDeletedShelf == expectedIsDeletedShelf,
                          self.compareShelfWithLocal == expectedCompareShelfWithLocal,
                          self.selectedFilePath == expectedPath else { return }
                    self.structuredDiff = diff
                }
            } catch {
                await MainActor.run {
                    guard self.commitID == expectedCommitID,
                          self.stashID == expectedStashID,
                          self.shelfName == expectedShelfName,
                          self.shelfRootPath == expectedShelfRootPath,
                          self.isDeletedShelf == expectedIsDeletedShelf,
                          self.compareShelfWithLocal == expectedCompareShelfWithLocal,
                          self.selectedFilePath == expectedPath else { return }
                    self.structuredDiffError = "\(error)"
                }
            }
        }
    }

    private func patchTextView(_ patch: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(patch.isEmpty ? "No changes" : patch)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(10)
        }
    }

    private static func parsePatchFiles(_ patch: String) -> [PatchFile] {
        guard !patch.isEmpty else { return [] }
        var files: [PatchFile] = []
        var currentPath: String?
        var currentLines: [String] = []

        func flush() {
            guard let currentPath, !currentLines.isEmpty else { return }
            files.append(PatchFile(path: currentPath, patch: currentLines.joined(separator: "\n")))
        }

        for line in patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("diff --git ") {
                flush()
                currentPath = pathFromDiffHeader(line)
                currentLines = [line]
            } else if currentPath != nil {
                currentLines.append(line)
            }
        }
        flush()
        return files
    }

    private static func pathFromDiffHeader(_ line: String) -> String? {
        // Git's normal header is `diff --git a/path b/path`. Use the second
        // side as the display path; rename/copy headers still get a useful
        // destination path. Quoted paths are unwrapped for presentation.
        guard let separator = line.range(of: " b/") else { return nil }
        let prefix = line[..<separator.lowerBound]
        guard prefix.hasPrefix("diff --git a/") else { return nil }
        let path = String(line[separator.upperBound...])
        return path.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}

    private func compactButton(_ image: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private var rebasedBackground: Color {
        Design.Colors.canvas
    }

    private var rebasedSurface: Color {
        Design.Colors.surface
    }
}

private struct RebasedTabButtonStyle: ButtonStyle {
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

/// GitStageTree keeps conflicts as a first-class node instead of making them
/// look like ordinary unstaged files. The row opens the same Merge Revisions
/// workbench used by merge/rebase operations and has no staging checkbox.
private struct RebasedConflictGroup: View {
    let entries: [FileEntry]
    let onOpen: (String) -> Void
    @State private var isExpanded = true

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
                    Text("Conflicts")
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
                Text("没有文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
            } else if isExpanded {
                ForEach(entries, id: \.path) { entry in
                    Button {
                        onOpen(entry.path)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .frame(width: 16)
                            let fileURL = URL(fileURLWithPath: entry.path)
                            Text(fileURL.lastPathComponent)
                                .lineLimit(1)
                            let parentPath = fileURL.deletingLastPathComponent().path
                                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                            if !parentPath.isEmpty, parentPath != "." {
                                Text("/\(parentPath)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 4)
                            Text("Resolve")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        .padding(.leading, 20)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .help("Open Merge Revisions")
                }
            }
        }
    }

}

private struct RebasedChangeListHeader: View {
    let list: ChangeListInfo
    let onRename: (String) -> Void
    let onDelete: (String) -> Void
    let onActivate: (String) -> Void
    let onMovePaths: ([String], String) -> Void
    let onDropShelfIntoChangeList: (String, [String]?, String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: list.isActive ? "checkmark.circle.fill" : "circle")
                .font(.caption2)
                .foregroundStyle(list.isActive ? Color.accentColor : Color.secondary)
            Image(systemName: "list.bullet.rectangle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(list.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text("\(list.paths.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Menu {
                Button(list.isActive ? "Active Changelist" : "Set Active") {
                    onActivate(list.name)
                }
                .disabled(list.isActive)
                Divider()
                Button("Rename…") { onRename(list.name) }
                Button("Delete", role: .destructive) { onDelete(list.name) }
                    .disabled(list.isDefault)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 22)
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 1)
        .dropDestination(for: String.self) { paths, _ in
            if let shelfPayload = paths.compactMap(parseShelfDropPayload).first {
                switch shelfPayload {
                case let .shelf(name):
                    onDropShelfIntoChangeList(name, nil, list.name)
                case let .member(shelf, path):
                    onDropShelfIntoChangeList(shelf, [path], list.name)
                }
                return true
            }
            let payloads = paths.filter { !$0.hasPrefix("arbor-shelf") }
            guard !payloads.isEmpty else { return false }
            onMovePaths(payloads, list.name)
            return true
        }
    }
}

/// IntelliJ's `Git.Ignore.File` action group is offered for unversioned files
/// only.  A tracked or already-staged path must not be turned into a
/// `.gitignore` rule: Git would keep tracking it and the action would present
/// a misleading success path.
func gitIgnoreActionAvailable(for entry: FileEntry) -> Bool {
    entry.unstaged == .untracked && entry.staged == .unchanged
}

/// IntelliJ offers existing `.gitignore` files from the target's directory
/// and its ancestors. Keep the result root-scoped and nearest-first so the
/// SwiftUI menu has the same candidate set as `IgnoreFileActionGroup`.
func gitIgnoreFileCandidates(for filePath: String, workdir: String) -> [String] {
    let root = URL(fileURLWithPath: workdir).standardizedFileURL
    let target = filePath.hasPrefix("/")
        ? URL(fileURLWithPath: filePath).standardizedFileURL
        : root.appendingPathComponent(filePath).standardizedFileURL
    guard target.path == root.path || target.path.hasPrefix(root.path + "/") else {
        return []
    }

    let fileManager = FileManager.default
    var isDirectory = ObjCBool(false)
    let targetIsDirectory = fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory)
        && isDirectory.boolValue
    var directory = targetIsDirectory ? target : target.deletingLastPathComponent()
    var candidates: [String] = []
    while directory.path == root.path || directory.path.hasPrefix(root.path + "/") {
        let candidate = directory.appendingPathComponent(".gitignore")
        var candidateIsDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: candidate.path, isDirectory: &candidateIsDirectory),
           !candidateIsDirectory.boolValue {
            candidates.append(candidate.path)
        }
        if directory.path == root.path { break }
        let parent = directory.deletingLastPathComponent()
        guard parent.path != directory.path else { break }
        directory = parent
    }
    return candidates
}

/// Return the ignore files suitable for every selected unversioned path with
/// existing candidates, preserving the nearest-first order of the first
/// non-empty candidate list.
func gitIgnoreFileCandidates(for filePaths: [String], workdir: String) -> [String] {
    guard !filePaths.isEmpty else { return [] }
    let candidateLists = filePaths.map {
        gitIgnoreFileCandidates(for: $0, workdir: workdir)
    }
    // IgnoreFileActionGroup drops selected paths with no existing candidate
    // before intersecting the remaining candidate sets. IgnoreFileAction then
    // filters those paths out again when writing to the selected file root.
    let nonEmptyCandidateLists = candidateLists.filter { !$0.isEmpty }
    guard let orderedCandidates = nonEmptyCandidateLists.first else { return [] }
    let candidateSets = nonEmptyCandidateLists.map(Set.init)
    return orderedCandidates.filter { candidate in
        candidateSets.allSatisfy { $0.contains(candidate) }
    }
}

/// IntelliJ asks before `CreateNewIgnoreFileAction` creates the repository
/// root `.gitignore`. Keep this decision separate from candidate discovery so
/// an existing root file never causes a redundant confirmation.
func gitIgnoreNeedsRootCreationConfirmation(
    ignoreFilePath: String?,
    workdir: String
) -> Bool {
    guard ignoreFilePath == nil else { return false }
    let root = URL(fileURLWithPath: workdir).standardizedFileURL
    let ignoreFile = root.appendingPathComponent(".gitignore")
    var isDirectory = ObjCBool(false)
    return !FileManager.default.fileExists(
        atPath: ignoreFile.path,
        isDirectory: &isDirectory
    )
}

func gitIgnoreFileDisplayName(_ path: String, workdir: String) -> String {
    let root = URL(fileURLWithPath: workdir).standardizedFileURL
    let file = URL(fileURLWithPath: path).standardizedFileURL
    return file.path == root.path || !file.path.hasPrefix(root.path + "/")
        ? file.lastPathComponent
        : String(file.path.dropFirst(root.path.count + 1))
}

func gitIgnoreRule(for targetPath: String, ignoreFile: String, workdir: String) -> String {
    let root = URL(fileURLWithPath: workdir).standardizedFileURL
    let target = targetPath.hasPrefix("/")
        ? URL(fileURLWithPath: targetPath).standardizedFileURL
        : root.appendingPathComponent(targetPath).standardizedFileURL
    let parent = URL(fileURLWithPath: ignoreFile)
        .standardizedFileURL
        .deletingLastPathComponent()
    guard target.path.hasPrefix(parent.path + "/") else { return targetPath }
    return String(target.path.dropFirst(parent.path.count + 1))
        .replacingOccurrences(of: "\\", with: "/")
}

func gitIgnoreTargetPaths(
    for targetPaths: [String],
    ignoreFile: String,
    workdir: String
) -> [String] {
    let root = URL(fileURLWithPath: workdir).standardizedFileURL
    let ignoreRoot = URL(fileURLWithPath: ignoreFile)
        .standardizedFileURL
        .deletingLastPathComponent()
    return targetPaths.filter { targetPath in
        let target = targetPath.hasPrefix("/")
            ? URL(fileURLWithPath: targetPath).standardizedFileURL
            : root.appendingPathComponent(targetPath).standardizedFileURL
        return target.path.hasPrefix(ignoreRoot.path + "/")
    }
}

private struct RebasedChangeGroup: View {
    let title: String
    let entries: [FileEntry]
    let changeListName: String
    let changeLists: [ChangeListInfo]
    var emptyLabel: String = "没有文件"
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
    @State private var isExpanded = true
    @State private var collapsedFolders: Set<String> = []

    private struct TreeRow: Identifiable {
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
    private var treeRows: [TreeRow] {
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

    private var visibleTreeRows: [TreeRow] {
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

    private func folderRow(_ row: TreeRow) -> some View {
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

    private func fileRow(_ entry: FileEntry, depth: Int) -> some View {
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

/// Commit/Stash 工作区内的轻量 diff 预览。
///
/// rebased 的 Stage panel 会在变更树旁/下方保留 diff preview，不会把右侧
/// Git Log 编辑器替换掉。这里直接复用引擎已经提供的三层 staging diff，
/// 因而 staged + unstaged 同时存在时仍然可以切换查看两个真实维度。
private struct StagingDiffPreviewView: View {
    let repo: Repository?
    let path: String?
    let entry: FileEntry?
    let refreshToken: Int
    @Binding var selectionModePath: String?
    @Binding var previewMode: StagingPreviewMode
    @Binding var showThreeVersions: Bool
    let onStage: (String) -> Void
    let onUnstage: (String) -> Void
    let onRevertUnstaged: (String) -> Void
    let onChanged: () -> Void
    let onClose: () -> Void

    @State private var result: StagingFileDiff?
    @State private var isLoading = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var hunkTask: Task<Void, Never>?
    @State private var loadGeneration = 0

    private var availableModes: [StagingPreviewMode] {
        var modes: [StagingPreviewMode] = []
        if result?.unstaged != nil { modes.append(.unstaged) }
        if result?.staged != nil { modes.append(.staged) }
        return modes
    }

    private var activeDiff: FileDiff? {
        switch previewMode {
        case .unstaged: result?.unstaged
        case .staged: result?.staged
        }
    }

    private var fileActions: [StagingPreviewFileAction] {
        stagingPreviewFileActions(for: entry, mode: previewMode)
    }

    private var canSelectLines: Bool {
        guard let activeDiff, !activeDiff.binary, !activeDiff.hunks.isEmpty else { return false }
        return fileActions.contains(previewMode == .unstaged ? .stage : .unstage)
    }

    private var hunkActions: [DiffHunkAction] {
        stagingHunkActions(for: entry, mode: previewMode, diff: activeDiff)
    }

    var body: some View {
        if showThreeVersions, let path {
            ThreeVersionComparisonView(
                repo: repo,
                path: path,
                entry: entry,
                refreshToken: refreshToken,
                onChanged: onChanged,
                onClose: { showThreeVersions = false }
            )
        } else if selectionModePath == path, let path {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                    Text("逐行暂存 · \(path)")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        selectionModePath = nil
                    } label: {
                        Label("Back to preview", systemImage: "eye")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Return to the file diff preview")
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Hide changes preview")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Design.Colors.surface)

                DiffDetailView(
                    repo: repo,
                    entry: entry,
                    onChanged: onChanged,
                    selectionModePath: selectionModePath,
                    initialMode: stagingPreviewDiffMode(for: previewMode),
                    refreshToken: refreshToken
                )
            }
        } else {
            ordinaryPreview
        }
    }

    private var ordinaryPreview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .foregroundStyle(.secondary)
                Text(path.map { "Preview · \($0)" } ?? "Changes preview")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if availableModes.count > 1 {
                    Picker("Diff", selection: $previewMode) {
                        ForEach(availableModes, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .frame(width: 150)
                    .disabled(hunkTask != nil)
                }
                if canSelectLines, let path {
                    Button {
                        selectionModePath = path
                    } label: {
                        Label("Select Lines", systemImage: "selection.pin.in.out")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(hunkTask != nil)
                    .help("Select lines to stage or unstage")
                }
                if previewMode == .unstaged {
                    if fileActions.contains(.stage), let path {
                        Button {
                            onStage(path)
                        } label: {
                            Label("Stage", systemImage: "plus.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(hunkTask != nil)
                        .help("Stage this file")
                    }
                    if fileActions.contains(.revertUnstaged), let path {
                        Button(role: .destructive) {
                            onRevertUnstaged(path)
                        } label: {
                            Label("Revert", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(hunkTask != nil)
                        .help("Revert unstaged changes to the staged version")
                    }
                } else if fileActions.contains(.unstage), let path {
                    Button {
                        onUnstage(path)
                    } label: {
                        Label("Unstage", systemImage: "minus.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(hunkTask != nil)
                    .help("Unstage this file")
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Hide changes preview")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Design.Colors.surface)

            Group {
                if let error {
                    Text(error)
                        .foregroundStyle(Design.Colors.error)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(10)
                } else if isLoading {
                    ProgressView("Loading diff…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let activeDiff {
                    if activeDiff.binary {
                        Text("Binary file — diff preview unavailable")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if activeDiff.hunks.isEmpty {
                        Text("No changes in this dimension")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        SideBySideDiffView(
                            fileDiff: activeDiff,
                            hunkActions: hunkActions,
                            hunkActionsDisabled: hunkTask != nil,
                            onHunkAction: applyHunk
                        )
                    }
                } else if path == nil {
                    Text("Select a changed file to preview its diff")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("No changes")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Design.Colors.canvas)
        }
        .onAppear { load() }
        .onChange(of: path) { _, _ in load() }
        .onChange(of: entry) { _, _ in load() }
        .onChange(of: refreshToken) { _, _ in load() }
        .onDisappear {
            loadGeneration &+= 1
            task?.cancel()
            hunkTask?.cancel()
        }
        .onChange(of: availableModes) { _, modes in
            if let resolved = resolvedStagingPreviewMode(preferred: previewMode, available: modes),
               resolved != previewMode {
                previewMode = resolved
            }
        }
    }

    private func applyHunk(_ action: DiffHunkAction, _ hunkIndex: Int) {
        guard let repo, let path, let activeDiff,
              hunkIndex >= 0, hunkIndex < activeDiff.hunks.count,
              hunkTask == nil else { return }
                        let selection = LineSelection(hunkIndex: UInt32(hunkIndex), oldLines: [], newLines: [])
        let expectedPath = path
        hunkTask = Task.detached(priority: .userInitiated) {
            do {
                switch action {
                case .stage:
                    try repo.stageLines(path: expectedPath, selections: [selection])
                case .unstage:
                    try repo.unstageLines(path: expectedPath, selections: [selection])
                case .rollback:
                    try repo.restoreUnstagedLines(path: expectedPath, selections: [selection])
                }
                await MainActor.run {
                    guard self.path == expectedPath else {
                        self.hunkTask = nil
                        return
                    }
                    self.hunkTask = nil
                    self.onChanged()
                    self.load()
                    self.error = nil
                }
            } catch {
                await MainActor.run {
                    guard self.path == expectedPath else {
                        self.hunkTask = nil
                        return
                    }
                    self.hunkTask = nil
                    self.error = "\(error)"
                }
            }
        }
    }

    private func load() {
        loadGeneration &+= 1
        let generation = loadGeneration
        task?.cancel()
        result = nil
        error = nil
        isLoading = false
        guard let repo, let path else { return }
        let expectedPath = path
        isLoading = true
        task = Task.detached(priority: .userInitiated) {
            do {
                let diff = try repo.stagingDiff(path: expectedPath, ignoreWhitespace: false)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard isCurrentDiffRequest(
                        path: expectedPath,
                        generation: generation,
                        currentPath: self.path,
                        currentGeneration: self.loadGeneration
                    ) else { return }
                    self.result = diff
                    self.isLoading = false
                    self.error = nil
                    let modes: [StagingPreviewMode] = [
                        diff.unstaged != nil ? .unstaged : nil,
                        diff.staged != nil ? .staged : nil
                    ].compactMap { $0 }
                    if let resolved = resolvedStagingPreviewMode(
                        preferred: self.previewMode,
                        available: modes
                    ) {
                        self.previewMode = resolved
                    }
                }
            } catch {
                await MainActor.run {
                    guard isCurrentDiffRequest(
                        path: expectedPath,
                        generation: generation,
                        currentPath: self.path,
                        currentGeneration: self.loadGeneration
                    ) else { return }
                    self.result = nil
                    self.isLoading = false
                    self.error = "\(error)"
                }
            }
        }
    }
}

private struct RebasedIgnoredGroup: View {
    let entries: [FileEntry]
    let rules: [IgnoreRuleInfo]
    let onStage: (String) -> Void
    @State private var isExpanded = true
    @State private var pendingStagePath: String?
    @State private var showStageConfirmation = false

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
                    Text("Ignored Files")
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
                Text("No ignored files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
            } else if isExpanded {
                ForEach(entries, id: \.path) { entry in
                    HStack(spacing: 6) {
                        StatusBadge(kind: .ignored)
                        Text(entry.path)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let rule = rules.first(where: { entry.path == $0.path || entry.path.hasPrefix($0.pattern) }) {
                            Text("\(ignoreRuleSourceName(rule.source)) · \(rule.pattern)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .help("\(rule.sourcePath):\(rule.line)")
                        }
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Add to Git…") {
                            pendingStagePath = entry.path
                            showStageConfirmation = true
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Add Ignored File to Git?",
            isPresented: $showStageConfirmation,
            titleVisibility: .visible
        ) {
            if let pendingStagePath {
                Button("Add to Git") {
                    onStage(pendingStagePath)
                    self.pendingStagePath = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingStagePath = nil
            }
        } message: {
            if let pendingStagePath {
                Text("\(pendingStagePath) is ignored by Git. Adding it will explicitly track the file and commit its current contents.")
            }
        }
    }
}

private func ignoreRuleSourceName(_ source: IgnoreRuleSource) -> String {
    switch source {
    case .gitignore: return ".gitignore"
    case .infoExclude: return ".git/info/exclude"
    case .global: return "global ignore"
    case .other: return "ignore rule"
    }
}

struct RebasedStatusBar: View {
    let branch: String
    let headID: String?
    let changedCount: Int
    let projectPath: String?
    let onBranch: () -> Void
    @ObservedObject var feedbackCenter: FeedbackCenter
    let syncStatus: SyncStatus?
    let hasUnfetchedIncoming: Bool
    let onOperationLog: () -> Void
    let onCancelOperation: () -> Void
    let onFeedbackDetails: (FeedbackMessage) -> Void
    @AppStorage(GitIncomingOutgoingInfoSettings.key)
    private var incomingOutgoingInfoEnabled = GitIncomingOutgoingInfoSettings.defaultValue

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onBranch) {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .help("Open branches")
            if incomingOutgoingInfoEnabled, let syncStatus {
                if syncStatus.trackingExists {
                    HStack(spacing: 3) {
                        Text("↑\(syncStatus.ahead) ↓\(syncStatus.behind)")
                        if hasUnfetchedIncoming {
                            Text("↓?")
                                .foregroundStyle(.blue)
                        }
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(syncStatus.ahead > 0 || syncStatus.behind > 0 ? .orange : .secondary)
                    .help("Upstream: \(syncStatus.upstream)")
                } else {
                    Text("Missing upstream")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.orange)
                    .help("Upstream tracking branch is missing")
                }
            } else if incomingOutgoingInfoEnabled, hasUnfetchedIncoming {
                Text("↓?")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.blue)
                    .help("Remote has incoming commits not fetched locally")
            }
            Divider().frame(height: 14)
            Label("Git", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
            Button(action: onOperationLog) {
                Label("操作", systemImage: "list.bullet.rectangle")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open Git tasks and operation log")
            if changedCount > 0 {
                Text("\(changedCount) changed")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let feedback = feedbackCenter.current {
                Divider().frame(height: 14)
                if feedbackCenter.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                FeedbackMessageView(
                    message: feedback,
                    isCompact: true,
                    onDetails: { onFeedbackDetails(feedback) }
                )
                .font(.caption)
                .frame(maxWidth: 480, alignment: .leading)
                if let progress = feedbackCenter.progress {
                    HStack(spacing: 5) {
                        if let percentage = progress.percentage {
                            ProgressView(value: Double(percentage), total: 100)
                                .frame(width: 72)
                            Text("\(percentage)%")
                                .monospacedDigit()
                        }
                        Text(progress.phase)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                            .help(progress.detail)
                        if !progress.rootName.isEmpty {
                            Text("· \(progress.rootName)")
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption2)
                }
                if let batchProgress = feedbackCenter.batchProgress {
                    HStack(spacing: 5) {
                        ProgressView(
                            value: Double(batchProgress.completed),
                            total: Double(max(batchProgress.total, 1))
                        )
                        .frame(width: 72)
                        if let percentage = batchProgress.percentage {
                            Text("\(percentage)%")
                                .monospacedDigit()
                        } else {
                            Text("\(batchProgress.completed)/\(batchProgress.total)")
                                .monospacedDigit()
                        }
                        Text(batchProgress.phase)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                            .help(batchProgress.detail ?? batchProgress.phase)
                    }
                    .font(.caption2)
                }
                if feedbackCenter.canCancel {
                    Button("Cancel") { onCancelOperation() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            if let permissionWarning = feedbackCenter.nativeNotificationPermissionWarning {
                Divider().frame(height: 14)
                Label(permissionWarning.title, systemImage: "bell.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(permissionWarning.detail ?? permissionWarning.title)
                if let actionTitle = permissionWarning.actionTitle,
                   let action = permissionWarning.action
                {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            Spacer()
            if let projectPath {
                Text(projectPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let headID {
                Text(String(headID.prefix(7)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Design.Colors.chrome)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }
}


/// OPS-001 Operation Recovery Bar：订阅引擎的 operation_state()，
/// 按操作类别展示 continue/skip/abort；危险状态下普通操作按钮已禁用。
func rebaseEditPauseAllowsAmend(_ state: OperationState?) -> Bool {
    state?.kind == .rebase
        && state?.conflictedFiles.isEmpty == true
}

func operationRecoveryContinueIsEnabled(for state: OperationState) -> Bool {
    state.kind != .merge || state.conflictedFiles.isEmpty
}

private struct OperationRecoveryBar: View {
    let state: OperationState
    let feedback: String?
    let onContinue: () -> Void
    let onSkip: () -> Void
    let onAbort: () -> Void
    let onOpenConflictResolver: () -> Void
    let onOpenConflict: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.medium))
                    HStack(spacing: 6) {
                        if !state.conflictedFiles.isEmpty {
                            Label("\(state.conflictedFiles.count) unresolved", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if state.origin == .engine {
                            Text("Arbor-managed state")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        if state.kind == .rebase, let steps = state.stepsTotal {
                            Text("step \(state.stepsDone ?? 0)/\(steps)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer()
                if state.kind == .rebase {
                    Button("Skip", action: onSkip)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Button("Abort", action: onAbort)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(continueTitle, action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!operationRecoveryContinueIsEnabled(for: state))
            }
            if let context = operationRecoveryContext(for: state) {
                Text(context)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !state.conflictedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Resolve conflicts before continuing")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Resolve Conflicts", action: onOpenConflictResolver)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    ForEach(Array(state.conflictedFiles.prefix(5)), id: \.self) { path in
                        Button {
                            onOpenConflict(path)
                        } label: {
                            Label(path, systemImage: "arrow.up.forward.app")
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .buttonStyle(.link)
                    }
                    if state.conflictedFiles.count > 5 {
                        Text("and \(state.conflictedFiles.count - 5) more…")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 28)
            }
            if let feedback, !feedback.isEmpty {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.10))
    }

    private var icon: String {
        switch state.kind {
        case .merge: return "arrow.triangle.merge"
        case .rebase: return "arrow.triangle.branch"
        case .cherryPick: return "doc.on.clipboard"
        case .revert: return "arrow.uturn.backward"
        }
    }

    private var title: String {
        switch state.kind {
        case .merge: return "Merge in progress"
        case .rebase: return "Rebase paused"
        case .cherryPick: return "Cherry-pick in progress"
        case .revert: return "Revert in progress"
        }
    }

    private var continueTitle: String {
        switch state.kind {
        case .merge: return "Commit Merge"
        case .rebase: return "Continue Rebase"
        case .cherryPick: return "Continue Cherry-pick"
        case .revert: return "Continue Revert"
        }
    }

}

/// The recovery banner keeps the raw engine state intact, but exposes the
/// rebase context in one deterministic string so the SwiftUI view and tests
/// exercise the same presentation rule.
func operationRecoveryContext(for state: OperationState) -> String? {
    guard state.kind == .rebase else { return nil }
    var details: [String] = []
    if let branch = state.originalBranch, !branch.isEmpty {
        details.append("from \(branch)")
    }
    if let onto = state.onto, !onto.isEmpty {
        details.append("onto \(String(onto.prefix(10)))")
    }
    if state.backend == .apply {
        details.append("apply backend")
    } else if state.backend == .merge {
        details.append(state.interactive ? "interactive merge backend" : "merge backend")
    }
    return details.isEmpty ? nil : details.joined(separator: " · ")
}

/// An aggregate Changes Browser for projects containing nested Git roots.
/// Every staging mutation remains explicitly tied to the row's owning root;
/// the project-level view never falls back to the primary Repository.
struct MultiRootChangesBrowser: View {
    let groups: [MultiRootChangeGroup]
    let isLoading: Bool
    let error: String?
    let onRefresh: () -> Void
    let onStage: (String, String) -> Void
    let onUnstage: (String, String) -> Void
    let onStageSelected: ([MultiRootChangeSelection]) -> Void
    let onUnstageSelected: ([MultiRootChangeSelection]) -> Void
    let onCommitSelected: ([MultiRootChangeSelection]) -> Void
    let onStageAll: (String) -> Void
    let onUnstageAll: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var detailSelection: MultiRootChangeSelection?
    @State private var selectedRows = Set<MultiRootChangeSelection>()
    @State private var refreshToken = 0

    private var changedFileCount: Int {
        groups.reduce(0) { $0 + $1.changedEntries.count }
    }

    private var selectedStageableRows: [MultiRootChangeSelection] {
        orderedSelections(selectedRows).filter { selection in
            guard let entry = entry(for: selection) else { return false }
            return canStage(entry)
        }
    }

    private var selectedUnstageableRows: [MultiRootChangeSelection] {
        orderedSelections(selectedRows).filter { selection in
            guard let entry = entry(for: selection) else { return false }
            return canUnstage(entry)
        }
    }

    private var selectedCommittableRows: [MultiRootChangeSelection] {
        orderedSelections(selectedRows).filter { selection in
            guard let entry = entry(for: selection) else { return false }
            return entry.staged != .unchanged
                && entry.staged != .ignored
                && entry.staged != .conflicted
                && entry.unstaged != .conflicted
        }
    }

    private var selectedGroup: MultiRootChangeGroup? {
        guard let detailSelection else { return nil }
        return groups.first { $0.rootPath == detailSelection.rootPath }
    }

    private var selectedEntry: FileEntry? {
        guard let detailSelection, let selectedGroup else { return nil }
        return selectedGroup.entries.first { $0.path == detailSelection.path }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(Design.Colors.accent)
                Text("Changes · All Git Roots")
                    .font(.headline)
                Text("\(groups.count) roots · \(changedFileCount) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !selectedRows.isEmpty {
                    Menu {
                        Button("Stage Selected (\(selectedStageableRows.count))") {
                            onStageSelected(selectedStageableRows)
                        }
                        .disabled(selectedStageableRows.isEmpty)
                        Button("Unstage Selected (\(selectedUnstageableRows.count))") {
                            onUnstageSelected(selectedUnstageableRows)
                        }
                        .disabled(selectedUnstageableRows.isEmpty)
                        Divider()
                        Button("Commit Selected (\(selectedCommittableRows.count))") {
                            onCommitSelected(selectedCommittableRows)
                        }
                        .disabled(selectedCommittableRows.isEmpty)
                    } label: {
                        Label("Selected", systemImage: "checklist")
                    }
                    .help("Stage or unstage the selected files across Git roots")
                }
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Refresh", action: onRefresh)
                    .disabled(isLoading)
                Button("Done", role: .cancel) { dismiss() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if let error, !error.isEmpty, !groups.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }

            if let error, !error.isEmpty, groups.isEmpty {
                ContentUnavailableView(
                    "Loading Changes Failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if isLoading && groups.isEmpty {
                ProgressView("Loading changes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.allSatisfy({ $0.changedEntries.isEmpty }) {
                ContentUnavailableView(
                    "No Changes",
                    systemImage: "checkmark.circle",
                    description: Text("All Git roots are clean.")
                )
            } else {
                NavigationSplitView {
                    List(selection: $selectedRows) {
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.changedEntries, id: \.path) { entry in
                                    let row = MultiRootChangeSelection(
                                        rootPath: group.rootPath,
                                        path: entry.path,
                                        oldPath: entry.oldPath
                                    )
                                    HStack(spacing: 8) {
                                        Image(systemName: icon(for: entry))
                                            .foregroundStyle(color(for: entry))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.path)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Text(statusText(for: entry))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 4)
                                        Menu {
                                            if canStage(entry) {
                                                Button("Stage") {
                                                    onStage(group.rootPath, entry.path)
                                                }
                                            }
                                            if canUnstage(entry) {
                                                Button("Unstage") {
                                                    onUnstage(group.rootPath, entry.path)
                                                }
                                            }
                                        } label: {
                                            Image(systemName: "ellipsis.circle")
                                        }
                                        .menuStyle(.borderlessButton)
                                        .help("Stage or unstage this file")
                                        .disabled(!canStage(entry) && !canUnstage(entry))
                                    }
                                    .contextMenu {
                                        if canStage(entry) {
                                            Button("Stage") {
                                                onStage(group.rootPath, entry.path)
                                            }
                                        }
                                        if canUnstage(entry) {
                                            Button("Unstage") {
                                                onUnstage(group.rootPath, entry.path)
                                            }
                                        }
                                    }
                                    .tag(row)
                                }
                            } header: {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(group.displayName)
                                            .font(.system(size: 13, weight: .semibold))
                                        Text(group.relativePath)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 4)
                                    Menu {
                                        Button("Stage All") {
                                            onStageAll(group.rootPath)
                                        }
                                        .disabled(!hasUnstagedChanges(in: group))
                                        Button("Unstage All") {
                                            onUnstageAll(group.rootPath)
                                        }
                                        .disabled(!hasStagedChanges(in: group))
                                    } label: {
                                        Image(systemName: "ellipsis.circle")
                                    }
                                    .menuStyle(.borderlessButton)
                                    .help("Stage or unstage all changes in this Git root")
                                }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: 300)
                } detail: {
                    if let selectedGroup, let selectedEntry {
                        DiffDetailView(
                            repo: selectedGroup.repository,
                            entry: selectedEntry,
                            onChanged: {
                                refreshToken &+= 1
                                onRefresh()
                            },
                            selectionModePath: nil,
                            refreshToken: refreshToken
                        )
                    } else {
                        ContentUnavailableView(
                            "Select a Change",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text("Select a file to inspect its root-scoped diff.")
                        )
                    }
                }
            }
        }
        .frame(minWidth: 1050, minHeight: 680)
        .onAppear {
            selectFirstChangeIfNeeded()
        }
        .onChange(of: groups.map(\.id)) { _, _ in
            selectFirstChangeIfNeeded()
        }
        .onChange(of: groups.map { group in
            "\(group.rootPath)\u{1f}\(group.changedEntries.map(\.path).joined(separator: "\u{1f}"))"
        }) { _, _ in
            selectFirstChangeIfNeeded()
        }
        .onChange(of: selectedRows) { _, newSelection in
            guard !newSelection.isEmpty else {
                detailSelection = nil
                return
            }
            if let detailSelection, newSelection.contains(detailSelection) { return }
            detailSelection = orderedSelections(newSelection).first
        }
    }

    private func selectFirstChangeIfNeeded() {
        let validSelections = Set(groups.flatMap { group in
            group.changedEntries.map {
                MultiRootChangeSelection(rootPath: group.rootPath, path: $0.path)
            }
        })
        selectedRows = selectedRows.intersection(validSelections)
        if let detailSelection, validSelections.contains(detailSelection) {
            if !selectedRows.contains(detailSelection) {
                selectedRows.insert(detailSelection)
            }
            return
        }
        detailSelection = nil
        guard let group = groups.first(where: { !$0.changedEntries.isEmpty }),
              let entry = group.changedEntries.first else { return }
        let firstSelection = MultiRootChangeSelection(rootPath: group.rootPath, path: entry.path)
        detailSelection = firstSelection
        selectedRows = [firstSelection]
    }

    private func orderedSelections(
        _ selections: Set<MultiRootChangeSelection>
    ) -> [MultiRootChangeSelection] {
        selections.sorted {
            if $0.rootPath == $1.rootPath { return $0.path < $1.path }
            return $0.rootPath < $1.rootPath
        }
    }

    private func entry(for selection: MultiRootChangeSelection) -> FileEntry? {
        groups.first { $0.rootPath == selection.rootPath }?.entries.first {
            $0.path == selection.path
        }
    }

    private func icon(for entry: FileEntry) -> String {
        if entry.staged == .conflicted || entry.unstaged == .conflicted {
            return "exclamationmark.triangle.fill"
        }
        if entry.staged == .added || entry.unstaged == .added || entry.unstaged == .untracked {
            return "plus"
        }
        if entry.staged == .deleted || entry.unstaged == .deleted {
            return "minus"
        }
        if entry.staged == .renamed || entry.unstaged == .renamed {
            return "arrow.right"
        }
        return "pencil"
    }

    private func color(for entry: FileEntry) -> Color {
        if entry.staged == .conflicted || entry.unstaged == .conflicted { return .orange }
        if entry.staged == .added || entry.unstaged == .added || entry.unstaged == .untracked { return .green }
        if entry.staged == .deleted || entry.unstaged == .deleted { return .red }
        return .secondary
    }

    private func statusText(for entry: FileEntry) -> String {
        var labels: [String] = []
        if entry.staged != .unchanged { labels.append("staged: \(kindText(entry.staged))") }
        if entry.unstaged != .unchanged { labels.append("local: \(kindText(entry.unstaged))") }
        return labels.joined(separator: " · ")
    }

    private func kindText(_ kind: ChangeKind) -> String {
        switch kind {
        case .unchanged: return "unchanged"
        case .added: return "added"
        case .modified: return "modified"
        case .deleted: return "deleted"
        case .renamed: return "renamed"
        case .copied: return "copied"
        case .typeChanged: return "type changed"
        case .untracked: return "untracked"
        case .ignored: return "ignored"
        case .conflicted: return "conflicted"
        }
    }

    private func canStage(_ entry: FileEntry) -> Bool {
        entry.unstaged != .unchanged
            && entry.unstaged != .ignored
            && entry.unstaged != .conflicted
            && entry.staged != .conflicted
    }

    private func canUnstage(_ entry: FileEntry) -> Bool {
        entry.staged != .unchanged
            && entry.staged != .conflicted
            && entry.unstaged != .conflicted
    }

    private func hasUnstagedChanges(in group: MultiRootChangeGroup) -> Bool {
        group.entries.contains(where: canStage)
    }

    private func hasStagedChanges(in group: MultiRootChangeGroup) -> Bool {
        group.entries.contains(where: canUnstage)
    }
}
