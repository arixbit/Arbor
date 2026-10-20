import SwiftUI
import AppKit
import UniformTypeIdentifiers

private struct RebaseTodoDropDelegate: DropDelegate {
    let targetCommitID: String
    let sourceCommitIDs: () -> [String]
    let onMove: ([String], String) -> Void

    func dropEntered(info: DropInfo) {
        onMove(sourceCommitIDs(), targetCommitID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        true
    }
}
struct RebaseTodoEditorView: View {
    let repo: Repository
    let onto: String
    @Binding var items: [RebaseTodoItem]
    let preserveMerges: Bool
    let root: Bool
    let onStart: () -> Void
    let onOpenRawTodo: () -> Void
    let onCancel: () -> Void

    @State private var initialItems: [RebaseTodoItem]
    @State private var selected = Set<Int>()
    @State private var history: RebaseTodoEditHistory
    @State private var showDiscardChangesAlert = false
    @State private var draggedCommitID: String?
    @State private var commandsHelpContext: RebaseCommandsHelpContext?

    init(
        repo: Repository,
        onto: String,
        items: Binding<[RebaseTodoItem]>,
        preserveMerges: Bool,
        root: Bool,
        onStart: @escaping () -> Void,
        onOpenRawTodo: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.repo = repo
        self.onto = onto
        self._items = items
        self.preserveMerges = preserveMerges
        self.root = root
        self.onStart = onStart
        self.onOpenRawTodo = onOpenRawTodo
        self.onCancel = onCancel
        self._initialItems = State(initialValue: items.wrappedValue)
        self._history = State(initialValue: RebaseTodoEditHistory(initial: items.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Interactive Rebase").font(.title3.weight(.semibold))
                Spacer()
                Text(root ? "repository root · \(items.count) commits" : "onto \(shortId(onto)) · \(items.count) commits")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if root {
                Label("Rewrite from the repository root", systemImage: "arrow.uturn.left.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if preserveMerges {
                Label("Preserve merge commits", systemImage: "arrow.triangle.merge")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Merge rows keep Git's label/reset/merge topology; rows may be reordered only within one native branch segment. Squash/fixup remains limited to an unchanged segment order, and cross-boundary combinations are blocked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Picker("", selection: $bulkAction) {
                    Text("Pick").tag(RebaseTodoAction.pick)
                    Text("Reword").tag(RebaseTodoAction.reword)
                    Text("Edit").tag(RebaseTodoAction.edit)
                    Text("Squash").tag(RebaseTodoAction.squash)
                    Text("Fixup").tag(RebaseTodoAction.fixup)
                    Text("Drop").tag(RebaseTodoAction.drop)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 110)
                Button("Apply to Selected") { applyBulkAction() }
                    .disabled(selected.isEmpty)
                Button("Undo") { undo() }
                    .disabled(!history.canUndo)
                    .keyboardShortcut("z", modifiers: .command)
                    .help("Undo the last todo edit")
                Button("Redo") { redo() }
                    .disabled(!history.canRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .help("Redo the last todo edit")
                Button("Reset") {
                    let reset = resetRebaseTodoDraftItems(current: items, initial: initialItems)
                    record(reset, change: .structural)
                    selected.removeAll()
                }
                .disabled(items == initialItems)
                .help("Restore the todo order and actions from when this editor opened")
                Button("Edit Native Todo…", action: onOpenRawTodo)
                    .help("Edit Git's complete todo text, including label/reset/merge and other native commands")
                Button("Commands…") {
                    commandsHelpContext = RebaseCommandsHelpContext(
                        title: "Git Rebase Commands",
                        items: items
                    )
                }
                .help("Show the available action commands for this todo")
                Spacer()
                Text(selected.isEmpty ? "单击行选中；⌘ 多选" : "\(selected.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HSplitView {
                List(Array(items.indices), id: \.self, selection: $selected) { index in
                    todoRow(index)
                        .onDrag {
                            draggedCommitID = items[index].commitId
                            return NSItemProvider(object: NSString(string: items[index].commitId))
                        }
                        .onDrop(
                            of: [.text],
                            delegate: RebaseTodoDropDelegate(
                                targetCommitID: items[index].commitId,
                                sourceCommitIDs: {
                                    guard let draggedCommitID else { return [] }
                                    return selectedCommitIDs.contains(draggedCommitID)
                                        ? selectedCommitIDs
                                        : [draggedCommitID]
                                },
                                onMove: moveDraggedRows
                            )
                        )
                }
                .listStyle(.inset)
                .frame(minWidth: 520, idealWidth: 620, maxWidth: .infinity)

                RebaseTodoCommitDetailsPane(
                    repo: repo,
                    commitIDs: selectedCommitIDs
                )
                .frame(minWidth: 380, idealWidth: 460, maxWidth: .infinity)
            }
            .frame(minHeight: 340, maxHeight: .infinity)
            HStack {
                Button("Cancel", role: .cancel, action: requestCancel)
                Spacer()
                Button("Start Rebase", action: onStart)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(items.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 1020, minHeight: 560)
        .sheet(item: $commandsHelpContext) { context in
            RebaseCommandsHelpView(title: context.title, items: context.items)
        }
        .alert("Discard Rebase Changes?", isPresented: $showDiscardChangesAlert) {
            Button("Keep Editing", role: .cancel) {}
            Button("Discard Changes", role: .destructive, action: onCancel)
        } message: {
            Text("Your interactive rebase todo has unsaved changes.")
        }
    }

    private var selectedCommitIDs: [String] {
        selected.sorted().compactMap { index in
            items.indices.contains(index) ? items[index].commitId : nil
        }
    }

    private func moveDraggedRows(_ movingIDs: [String], before targetID: String) {
        guard !movingIDs.isEmpty,
              let targetIndex = items.firstIndex(where: { $0.commitId == targetID }),
              !movingIDs.contains(targetID),
              movingIDs.allSatisfy({ id in
                  items.first(where: { $0.commitId == id })?.isMergeCommit == false
              }) else {
            return
        }
        let source = IndexSet(items.indices.filter { movingIDs.contains(items[$0].commitId) })
        let updated = moveRebaseTodoRows(items, from: source, to: targetIndex)
        guard updated != items,
              !preserveMerges
                || rebaseTodoPreserveMergeReorderIsSafe(original: items, updated: updated) else {
            return
        }
        record(updated, change: .structural)
    }

    @State private var bulkAction: RebaseTodoAction = .pick

    private func todoRow(_ index: Int) -> some View {
        let contextSelection = rebaseTodoContextSelection(
            selectedIndices: selected,
            row: index
        )
        let canEditOrDrop = contextSelection.allSatisfy {
            items.indices.contains($0) && !items[$0].isMergeCommit
        }
        let canUnite = uniteRebaseTodoItems(
            items,
            selectedIndices: contextSelection,
            action: .squash,
            preserveMerges: preserveMerges
        ) != nil && !preserveMergeOrderChanged
        return HStack(spacing: 8) {
            if items[index].isMergeCommit {
                Picker("merge action", selection: Binding(
                    get: { items[index].action },
                    set: { setMergeAction($0, at: index) }
                )) {
                    Text("pick").tag(RebaseTodoAction.pick)
                    Text("reword").tag(RebaseTodoAction.reword)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 100)
            } else {
                Picker("", selection: Binding(
                    get: { items[index].action },
                    set: { setAction($0, at: index) }
                )) {
                    Text("pick").tag(RebaseTodoAction.pick)
                    if rebaseTodoCanReword(items: items, index: index) {
                        Text("reword").tag(RebaseTodoAction.reword)
                    }
                    Text("edit").tag(RebaseTodoAction.edit)
                    if !preserveMergeOrderChanged,
                       rebaseTodoCanSquashOrFixup(
                        items: items,
                        index: index,
                        preserveMerges: preserveMerges
                    ) {
                        Text("squash").tag(RebaseTodoAction.squash)
                        Text("fixup").tag(RebaseTodoAction.fixup)
                    }
                    Text("drop").tag(RebaseTodoAction.drop)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 100)
            }
            Text(shortId(items[index].commitId))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            if items[index].isMergeCommit, items[index].action == .reword {
                TextField("reword merge message", text: Binding(
                    get: { items[index].message ?? items[index].summary },
                    set: { setMessage($0, at: index) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
            } else if items[index].isMergeCommit {
                Text("merge topology controlled by Git: \(items[index].summary)")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            } else if items[index].action == .squash {
                TextEditor(text: Binding(
                    get: { items[index].message ?? "" },
                    set: { setMessage($0, at: index) }
                ))
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 48, maxHeight: 88)
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.25))
                }
                .help("Optional final message for the squashed commit; leave empty for Git's default combined message.")
            } else if items[index].action == .reword {
                TextField("reword message", text: Binding(
                    get: { items[index].message ?? items[index].summary },
                    set: { setMessage($0, at: index) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
            } else {
                Text(items[index].summary)
                    .lineLimit(1)
                    .strikethrough(items[index].action == .drop)
                    .foregroundStyle(items[index].action == .drop ? .secondary : .primary)
            }
            Spacer()
            Button(action: { move(index, by: -1) }) {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.plain)
            .disabled(!rebaseTodoCanMove(
                items,
                selectedIndices: selected,
                requestedIndex: index,
                by: -1,
                preserveMerges: preserveMerges
            ))
            Button(action: { move(index, by: 1) }) {
                Image(systemName: "arrow.down")
            }
            .buttonStyle(.plain)
            .disabled(!rebaseTodoCanMove(
                items,
                selectedIndices: selected,
                requestedIndex: index,
                by: 1,
                preserveMerges: preserveMerges
            ))
        }
        .contextMenu {
            Button("Pick") { applyContextAction(.pick, at: index) }
            if items[index].isMergeCommit
                || rebaseTodoCanReword(items: items, index: index) {
                Button("Reword") { applyContextAction(.reword, at: index) }
            }
            if canEditOrDrop {
                Button("Edit") { applyContextAction(.edit, at: index) }
            }
            if canUnite {
                Button("Squash") { applyContextAction(.squash, at: index) }
                Button("Fixup") { applyContextAction(.fixup, at: index) }
            }
            if canEditOrDrop {
                Button("Drop") { applyContextAction(.drop, at: index) }
            }
            Divider()
            Button("Commands…") {
                commandsHelpContext = RebaseCommandsHelpContext(
                    title: "Git Rebase Commands",
                    items: items
                )
            }
        }
    }

    private func move(_ index: Int, by delta: Int) {
        guard items.indices.contains(index) else { return }
        let effectiveSelection = selected.contains(index) ? selected : [index]
        let updated = moveRebaseTodoItems(
            items,
            selectedIndices: effectiveSelection,
            requestedIndex: index,
            by: delta
        )
        guard updated != items,
              !preserveMerges
                || rebaseTodoPreserveMergeReorderIsSafe(original: items, updated: updated) else {
            return
        }
        record(updated, change: .structural)
    }

    private func applyBulkAction() {
        if bulkAction == .squash || bulkAction == .fixup {
            guard !preserveMergeOrderChanged else { return }
            guard let united = uniteRebaseTodoItems(
                items,
                selectedIndices: selected,
                action: bulkAction,
                preserveMerges: preserveMerges
            ) else { return }
            record(united, change: .structural)
            return
        }

        var updated = items
        let selectedCommitIDs = selected.sorted().compactMap { index in
            items.indices.contains(index) ? items[index].commitId : nil
        }
        for commitID in selectedCommitIDs.reversed() {
            guard let index = updated.firstIndex(where: { $0.commitId == commitID }) else { continue }
            guard !updated[index].isMergeCommit else { continue }
            _ = applyRebaseTodoAction(&updated, at: index, action: bulkAction)
        }
        normalizeRebaseTodoActions(&updated, preserveMerges: preserveMerges)
        record(updated, change: .structural)
    }

    private func applyContextAction(_ action: RebaseTodoAction, at index: Int) {
        guard items.indices.contains(index) else { return }
        let contextSelection = rebaseTodoContextSelection(
            selectedIndices: selected,
            row: index
        )
        if action == .squash || action == .fixup {
            guard !preserveMergeOrderChanged else { return }
            guard let united = uniteRebaseTodoItems(
                items,
                selectedIndices: contextSelection,
                action: action,
                preserveMerges: preserveMerges
            ) else { return }
            selected = contextSelection
            record(united, change: .structural)
            return
        }

        if action == .edit || action == .drop {
            guard contextSelection.allSatisfy({
                items.indices.contains($0) && !items[$0].isMergeCommit
            }) else { return }
        }

        var updated = items
        let contextCommitIDs = contextSelection.sorted().compactMap { target in
            items.indices.contains(target) ? items[target].commitId : nil
        }
        for commitID in contextCommitIDs.reversed() {
            guard let target = updated.firstIndex(where: { $0.commitId == commitID }) else { continue }
            _ = applyRebaseTodoAction(&updated, at: target, action: action)
        }
        normalizeRebaseTodoActions(&updated, preserveMerges: preserveMerges)
        selected = contextSelection
        record(updated, change: .structural)
    }

    private func setAction(_ action: RebaseTodoAction, at index: Int) {
        guard items.indices.contains(index), !items[index].isMergeCommit else { return }
        guard !preserveMergeOrderChanged || (action != .squash && action != .fixup) else { return }
        var updated = items
        guard applyRebaseTodoAction(&updated, at: index, action: action) else { return }
        record(updated, change: .structural)
    }

    private func setMergeAction(_ action: RebaseTodoAction, at index: Int) {
        guard items.indices.contains(index), items[index].isMergeCommit else { return }
        var updated = items
        setRebaseTodoAction(&updated[index], action: action)
        record(updated, change: .structural)
    }

    private func setMessage(_ message: String, at index: Int) {
        guard items.indices.contains(index) else { return }
        var updated = items
        updated[index].message = message.isEmpty ? nil : message
        record(updated, change: .message(commitID: updated[index].commitId))
    }

    private func record(_ updated: [RebaseTodoItem], change: RebaseTodoHistoryChange) {
        let selectedIDs = Set(selected.compactMap { index in
            items.indices.contains(index) ? items[index].commitId : nil
        })
        history.record(updated, change: change)
        items = updated
        selected = Set(updated.indices.filter { selectedIDs.contains(updated[$0].commitId) })
    }

    private func undo() {
        let selectedIDs = Set(selected.compactMap { index in
            items.indices.contains(index) ? items[index].commitId : nil
        })
        guard let previous = history.undo() else { return }
        items = previous
        selected = Set(previous.indices.filter { selectedIDs.contains(previous[$0].commitId) })
    }

    private func redo() {
        let selectedIDs = Set(selected.compactMap { index in
            items.indices.contains(index) ? items[index].commitId : nil
        })
        guard let next = history.redo() else { return }
        items = next
        selected = Set(next.indices.filter { selectedIDs.contains(next[$0].commitId) })
    }

    private func shortId(_ id: String) -> String {
        String(id.prefix(7))
    }

    private var preserveMergeOrderChanged: Bool {
        rebaseTodoPreserveMergeOrderChanged(
            initial: initialItems,
            current: items,
            preserveMerges: preserveMerges
        )
    }

    private func requestCancel() {
        if rebaseTodoHasUnsavedChanges(current: items, initial: initialItems) {
            showDiscardChangesAlert = true
        } else {
            onCancel()
        }
    }
}
