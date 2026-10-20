import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Clipboard payload used by IntelliJ's Cleanup Branches table copy provider.
/// Each selected row is copied as branch name, last commit date, and tracked
/// branch, separated by tabs and kept in table order.
struct BranchCleanupClipboardRow: Equatable {
    let branchName: String
    let lastCommitDate: String
    let trackedBranch: String
}
func formattedBranchCleanupClipboardRows(_ rows: [BranchCleanupClipboardRow]) -> String {
    rows.map { row in
        [row.branchName, row.lastCommitDate, row.trackedBranch].joined(separator: "\t")
    }
    .joined(separator: "\n")
}
/// IntelliJ's cleanup table copies the selected table rows, not the rows
/// checked for deletion. Keep the two selection concepts separate while
/// preserving the table's current row order.
func branchCleanupSelectedRows(
    _ orderedRows: [BranchCleanupSelection],
    selected: Set<BranchCleanupSelection>
) -> [BranchCleanupSelection] {
    orderedRows.filter(selected.contains)
}
enum BranchCleanupWindowAction: Equatable {
    case calculate(String, String)
    case delete([BranchCleanupSelection])
    case refresh
}
private enum BranchCleanupSelectionHeaderState: Equatable {
    case none
    case some
    case all
}
private enum BranchCleanupSortMode: String, CaseIterable, Identifiable {
    case name
    case lastCommit
    case mergedStatus

    var id: String { rawValue }
}
private struct BranchCleanupHeaderCheckbox: NSViewRepresentable {
    let state: BranchCleanupSelectionHeaderState
    let onToggle: () -> Void

    final class Coordinator: NSObject {
        var onToggle: () -> Void

        init(onToggle: @escaping () -> Void) {
            self.onToggle = onToggle
        }

        @objc func toggle() {
            onToggle()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onToggle: onToggle)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            checkboxWithTitle: "",
            target: context.coordinator,
            action: #selector(Coordinator.toggle)
        )
        button.allowsMixedState = true
        button.toolTip = String(localized: "Select all visible branches")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.onToggle = onToggle
        button.state = switch state {
        case .none: .off
        case .some: .mixed
        case .all: .on
        }
    }
}
@MainActor
final class BranchCleanupWindowCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var roots: [BranchCleanupRoot] = []
    @Published var action: BranchCleanupWindowAction?

    private var windowController: NSWindowController?

    func present(roots: [BranchCleanupRoot]) {
        self.roots = roots
        if let window = windowController?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Cleanup Branches")
        window.identifier = NSUserInterfaceItemIdentifier("arbor.branch-cleanup")
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.minSize = NSSize(width: 900, height: 620)
        window.delegate = self
        let hostingView = NSHostingView(rootView: BranchCleanupWindowRootView(coordinator: self))
        hostingView.frame = NSRect(
            origin: .zero,
            size: window.contentRect(forFrameRect: window.frame).size
        )
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
        window.center()

        let controller = NSWindowController(window: window)
        windowController = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateRoots(_ roots: [BranchCleanupRoot]) {
        self.roots = roots
    }

    func close() {
        windowController?.close()
    }

    func windowWillClose(_ notification: Notification) {
        windowController = nil
        action = nil
    }
}
private struct BranchCleanupWindowRootView: View {
    @ObservedObject var coordinator: BranchCleanupWindowCoordinator

    var body: some View {
        BranchCleanupDialogView(
            roots: coordinator.roots,
            onCalculate: { target, prefix in
                coordinator.action = .calculate(target, prefix)
            },
            onDelete: { selections in
                coordinator.action = .delete(selections)
            },
            onRefresh: {
                coordinator.action = .refresh
            },
            onCancel: {
                coordinator.close()
            }
        )
    }
}
/// IntelliJ 的 CleanupBranchesDialog：按目标分支和名称前缀筛选，
/// 先计算合并状态，再逐项选择并批量删除本地分支。
struct BranchCleanupDialogView: View {
    let roots: [BranchCleanupRoot]
    let onCalculate: (String, String) -> Void
    let onDelete: ([BranchCleanupSelection]) -> Void
    let onRefresh: () -> Void
    let onCancel: () -> Void

    @State private var targetBranch = ""
    @State private var prefix = ""
    @State private var appliedPrefix = ""
    @State private var sortMode: BranchCleanupSortMode = .name
    @State private var selected = Set<BranchCleanupSelection>()
    @State private var rowSelection = Set<BranchCleanupSelection>()
    @State private var showDeleteConfirmation = false

    private func selection(for root: BranchCleanupRoot, branch: BranchInfo) -> BranchCleanupSelection {
        BranchCleanupSelection(rootPath: root.rootPath, branchName: branch.name)
    }

    private func visibleBranches(in root: BranchCleanupRoot, prefix filterPrefix: String? = nil) -> [BranchInfo] {
        let filter = (filterPrefix ?? appliedPrefix).trimmingCharacters(in: .whitespacesAndNewlines)
        let branches = root.branches
            .filter { filter.isEmpty || $0.name.hasPrefix(filter) }
        return branches.sorted { lhs, rhs in
            switch sortMode {
            case .name:
                return lhs.name < rhs.name
            case .lastCommit:
                if lhs.lastCommitTime != rhs.lastCommitTime {
                    return lhs.lastCommitTime > rhs.lastCommitTime
                }
                return lhs.name < rhs.name
            case .mergedStatus:
                let lhsMerged = root.mergedBranches.contains(lhs.name)
                let rhsMerged = root.mergedBranches.contains(rhs.name)
                if lhsMerged != rhsMerged { return lhsMerged && !rhsMerged }
                return lhs.name < rhs.name
            }
        }
    }

    private var selectableVisibleBranches: [BranchCleanupSelection] {
        roots.flatMap { root in
            visibleBranches(in: root)
                .filter { !$0.isCurrent }
                .map { selection(for: root, branch: $0) }
        }
    }

    private var selectedNames: String {
        selected.compactMap { branch in
            guard let root = roots.first(where: { $0.rootPath == branch.rootPath }) else { return nil }
            return "\(root.relativePath): \(branch.branchName)"
        }
        .sorted()
        .joined(separator: ", ")
    }

    private var selectionHeaderState: BranchCleanupSelectionHeaderState {
        let visible = selectableVisibleBranches
        guard !visible.isEmpty else { return .none }
        let selectedCount = visible.filter { selected.contains($0) }.count
        if selectedCount == 0 { return .none }
        if selectedCount == visible.count { return .all }
        return .some
    }

    private func toggleVisibleSelection() {
        if selectionHeaderState == .all {
            selected.subtract(selectableVisibleBranches)
        } else {
            selected.formUnion(selectableVisibleBranches)
        }
    }

    private func applyFilter() {
        let nextPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        appliedPrefix = nextPrefix
        let visibleRows = roots.flatMap { root in
            visibleBranches(in: root, prefix: nextPrefix).map { branch in
                (root: root, branch: branch)
            }
        }
        selected.formIntersection(Set(
            visibleRows
                .filter { !$0.branch.isCurrent }
                .map { selection(for: $0.root, branch: $0.branch) }
        ))
        rowSelection.formIntersection(Set(
            visibleRows.map { selection(for: $0.root, branch: $0.branch) }
        ))
    }

    private func selectedBranchesClipboardText() -> String? {
        let orderedRows = roots.flatMap { root in
            visibleBranches(in: root).map { selection(for: root, branch: $0) }
        }
        let selectedRows = branchCleanupSelectedRows(orderedRows, selected: rowSelection)
        let rows = selectedRows.compactMap { row -> BranchCleanupClipboardRow? in
            guard let root = roots.first(where: { $0.rootPath == row.rootPath }),
                  let branch = root.branches.first(where: { $0.name == row.branchName }) else {
                return nil
            }
            return BranchCleanupClipboardRow(
                branchName: branch.name,
                lastCommitDate: lastCommitDate(for: branch),
                trackedBranch: root.trackingByBranch[branch.name] ?? ""
            )
        }
        let copied = formattedBranchCleanupClipboardRows(rows)
        return copied.isEmpty ? nil : copied
    }

    private func copySelectedBranches() {
        guard let copied = selectedBranchesClipboardText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copied, forType: .string)
    }

    private func mergeStatusIsAvailable(for root: BranchCleanupRoot) -> Bool {
        let target = targetBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = appliedPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return !target.isEmpty
            && root.calculatedTarget == target
            && root.calculatedPrefix == prefix
    }

    private var mergeStatusIsAvailableForAllRoots: Bool {
        !roots.isEmpty && roots.allSatisfy { mergeStatusIsAvailable(for: $0) }
    }

    private func defaultTargetBranch() -> String {
        let allBranches = roots.flatMap(\.branches)
        return allBranches.first(where: { $0.name == "main" })?.name
            ?? allBranches.first(where: { $0.name == "master" })?.name
            ?? allBranches.first(where: { $0.isCurrent })?.name
            ?? allBranches.first?.name
            ?? ""
    }

    private func lastCommitDate(for branch: BranchInfo) -> String {
        guard branch.lastCommitTime > 0 else { return "" }
        return Date(timeIntervalSince1970: TimeInterval(branch.lastCommitTime))
            .formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Cleanup Branches")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Refresh") {
                    selected.removeAll()
                    rowSelection.removeAll()
                    onRefresh()
                }
                Button("Done", role: .cancel, action: onCancel)
            }

            HStack(spacing: 10) {
                Text("Target branch")
                TextField("Target branch", text: $targetBranch)
                    .textFieldStyle(.roundedBorder)
                Text("Filter prefix")
                TextField("Filter prefix", text: $prefix)
                    .textFieldStyle(.roundedBorder)
                Button("Filter", action: applyFilter)
                Button("Calculate") {
                    selected.removeAll()
                    onCalculate(
                        targetBranch.trimmingCharacters(in: .whitespacesAndNewlines),
                        appliedPrefix
                    )
                }
                .disabled(targetBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack {
                Text("Branch")
                Spacer()
                Text("Last commit")
                    .frame(width: 150, alignment: .leading)
                Text("Tracked branch")
                    .frame(width: 180, alignment: .leading)
                Text("Status")
                    .frame(width: 100, alignment: .leading)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                BranchCleanupHeaderCheckbox(state: selectionHeaderState, onToggle: toggleVisibleSelection)
                    .frame(width: 18, height: 18)
                    .accessibilityLabel("Select all visible branches")
                Button("Clear") { selected.removeAll() }
                Button("Copy", action: copySelectedBranches)
                    .disabled(rowSelection.isEmpty)
                Menu("Sort") {
                    Picker("Sort", selection: $sortMode) {
                        Text("Name").tag(BranchCleanupSortMode.name)
                        Text("Last commit").tag(BranchCleanupSortMode.lastCommit)
                        Text("Merged status").tag(BranchCleanupSortMode.mergedStatus)
                    }
                }
                if mergeStatusIsAvailableForAllRoots {
                    Text(
                        String(localized: "Merged status calculated for %@")
                            .replacingOccurrences(
                                of: "%@",
                                with: targetBranch.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(
                    String(localized: "%@ selected")
                        .replacingOccurrences(of: "%@", with: String(selected.count))
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            List(selection: $rowSelection) {
                ForEach(roots) { root in
                    Section {
                        let rows = visibleBranches(in: root)
                        let mergeStatusAvailable = mergeStatusIsAvailable(for: root)
                        if rows.isEmpty {
                            Text("No branches")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(rows, id: \.name) { branch in
                                let branchSelection = selection(for: root, branch: branch)
                                Toggle(isOn: Binding(
                                    get: { selected.contains(branchSelection) },
                                    set: { value in
                                        if value {
                                            selected.insert(branchSelection)
                                        } else {
                                            selected.remove(branchSelection)
                                        }
                                    }
                                )) {
                                    HStack(spacing: 8) {
                                        Text(branch.name)
                                            .font(.system(.body, design: .monospaced))
                                        if branch.isCurrent {
                                            Text("Current")
                                                .font(.caption)
                                                .foregroundStyle(.blue)
                                        }
                                        Spacer()
                                        Text(lastCommitDate(for: branch))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 150, alignment: .leading)
                                        Text(root.trackingByBranch[branch.name] ?? "")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .frame(width: 180, alignment: .leading)
                                        if mergeStatusAvailable {
                                            Text(root.mergedBranches.contains(branch.name) ? "Merged" : "Not merged")
                                                .font(.caption)
                                                .foregroundStyle(root.mergedBranches.contains(branch.name) ? .green : .secondary)
                                        } else {
                                            Text("Not calculated")
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .tag(branchSelection)
                                .disabled(branch.isCurrent)
                            }
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(root.displayName)
                                .font(.system(size: 13, weight: .semibold))
                            Text(root.relativePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)

            HStack {
                Text(
                    String(localized: "%@ repositories")
                        .replacingOccurrences(of: "%@", with: String(roots.count))
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Delete selected branches", role: .destructive) {
                    showDeleteConfirmation = true
                }
                .disabled(selected.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 900, minHeight: 560)
        .onAppear {
            if targetBranch.isEmpty { targetBranch = defaultTargetBranch() }
        }
        .onCopyCommand {
            guard let copied = selectedBranchesClipboardText() else { return [] }
            return [NSItemProvider(object: NSString(string: copied))]
        }
        .alert("Delete selected branches", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                onDelete(Array(selected))
                selected.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(selectedNames)
        }
    }
}
