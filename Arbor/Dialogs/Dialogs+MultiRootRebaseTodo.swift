import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Multi-root interactive rebase keeps one independent todo list per Git
/// root.  IntelliJ presents the operation as one workflow, but never reuses
/// commit indexes from one repository in another repository.
struct MultiRootRebaseTodoDraft: Identifiable, Sendable {
    let rootPath: String
    let displayName: String
    var items: [RebaseTodoItem]
    var rawTodo: String?
    var loadError: String?

    var id: String { rootPath }
}
func multiRootRebaseNoopRootPaths(_ drafts: [MultiRootRebaseTodoDraft]) -> [String] {
    drafts
        .filter { $0.loadError == nil && $0.items.isEmpty }
        .map(\.rootPath)
}
private struct MultiRootRebaseDetailSelection: Equatable {
    let rootPath: String
    let commitID: String
}
func multiRootRebaseDetailCommitIDs(
    draft: MultiRootRebaseTodoDraft,
    selectedIDs: Set<String>,
    focusedID: String
) -> [String] {
    if selectedIDs.isEmpty {
        return [focusedID]
    }
    return draft.items
        .map(\.commitId)
        .filter { selectedIDs.contains($0) }
}
/// The batch counterpart of `RebaseTodoEditorView`.  The root sections share
/// one confirmation surface while action changes and ordering remain scoped
/// to the selected root.
struct MultiRootRebaseTodoEditorView: View {
    let onto: String
    let branch: String
    @Binding var drafts: [MultiRootRebaseTodoDraft]
    let preserveMerges: Bool
    let autoSquash: Bool
    let keepEmpty: Bool
    let updateRefs: Bool
    let root: Bool
    let onStart: () -> Void
    let onCancel: () -> Void
    let onOpenRawTodo: (MultiRootRebaseTodoDraft) -> Void

    @State private var initialItemsByRoot: [String: [RebaseTodoItem]]
    @State private var historyByRoot: [String: RebaseTodoEditHistory]
    @State private var selectedByRoot: [String: Set<String>] = [:]
    @State private var bulkActionByRoot: [String: RebaseTodoAction] = [:]
    @State private var detailSelection: MultiRootRebaseDetailSelection?
    @State private var repositoriesByRoot: [String: Repository] = [:]
    @State private var repositoryErrorsByRoot: [String: String] = [:]
    @State private var commandsHelpContext: RebaseCommandsHelpContext?
    @State private var showDiscardChangesAlert = false
    @State private var showNoopConfirmation = false

    init(
        onto: String,
        branch: String,
        drafts: Binding<[MultiRootRebaseTodoDraft]>,
        preserveMerges: Bool,
        autoSquash: Bool,
        keepEmpty: Bool,
        updateRefs: Bool,
        root: Bool,
        onStart: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onOpenRawTodo: @escaping (MultiRootRebaseTodoDraft) -> Void
    ) {
        self.onto = onto
        self.branch = branch
        self._drafts = drafts
        self.preserveMerges = preserveMerges
        self.autoSquash = autoSquash
        self.keepEmpty = keepEmpty
        self.updateRefs = updateRefs
        self.root = root
        self.onStart = onStart
        self.onCancel = onCancel
        self.onOpenRawTodo = onOpenRawTodo
        let initialItems = Dictionary(
            uniqueKeysWithValues: drafts.wrappedValue
                .filter { $0.loadError == nil }
                .map { ($0.rootPath, $0.items) }
        )
        self._initialItemsByRoot = State(initialValue: initialItems)
        self._historyByRoot = State(initialValue: initialItems.mapValues(RebaseTodoEditHistory.init(initial:)))
    }

    private var hasErrors: Bool {
        drafts.contains { $0.loadError != nil }
    }

    private var noopRootPaths: [String] {
        multiRootRebaseNoopRootPaths(drafts)
    }

    private var totalItems: Int {
        drafts.reduce(0) { $0 + $1.items.count }
    }

    private var summaryText: String {
        let locale = AppLanguage.interfaceLocale
        let rangeDescription: String
        if onto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rangeDescription = String(
                format: localizedArborString("%@ from repository root", locale: locale),
                branch
            )
        } else {
            rangeDescription = String(
                format: localizedArborString("%@ onto %@", locale: locale),
                branch,
                shortId(onto)
            )
        }
        return String(
            format: localizedArborString("%@ · %lld repositories · %lld commits", locale: locale),
            rangeDescription,
            drafts.count,
            totalItems
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Multi-root Interactive Rebase")
                        .font(.title3.weight(.semibold))
                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if preserveMerges || autoSquash || keepEmpty || updateRefs || root {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.secondary)
                        .help("Advanced rebase options are applied to every repository")
                }
            }

            Text("Each repository has its own todo list. Changes to one section do not affect another repository.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if preserveMerges {
                Label(
                    "Preserve merge topology: merge anchors stay fixed; commits may reorder inside their branch segment. After reordering, squash/fixup is disabled until reset.",
                    systemImage: "arrow.triangle.merge"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if !noopRootPaths.isEmpty {
                Label(
                    "\(noopRootPaths.count) repository\(noopRootPaths.count == 1 ? "" : "ies") has no commits to rebase; starting will ask for confirmation.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HSplitView {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(drafts.indices, id: \.self) { rootIndex in
                            rootSection(rootIndex)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minWidth: 680, idealWidth: 760, maxWidth: .infinity)

                if let detailSelection,
                   let detailRepository = repositoriesByRoot[detailSelection.rootPath] {
                    RebaseTodoCommitDetailsPane(
                        repo: detailRepository,
                        commitIDs: detailCommitIDs(for: detailSelection)
                    )
                    .frame(minWidth: 380, idealWidth: 460, maxWidth: .infinity)
                } else if let detailSelection,
                          let repositoryError = repositoryErrorsByRoot[detailSelection.rootPath] {
                    Label(repositoryError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                } else if detailSelection != nil {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Loading commit details…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "sidebar.right")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("Select a commit to view details")
                            .foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 400, maxHeight: 620)

            HStack {
                if hasErrors {
                    Label("Every repository must have a valid todo before starting", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: requestCancel)
                Button("Start Rebase", action: requestStart)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(hasErrors || drafts.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 1180, minHeight: 620)
        .task(id: drafts.map(\.rootPath)) {
            let rootPaths = drafts.map(\.rootPath)
            let result = await Task.detached(priority: .userInitiated) {
                var repositories: [String: Repository] = [:]
                var errors: [String: String] = [:]
                for rootPath in rootPaths {
                    do {
                        let repository = try openRepository(path: rootPath)
                        repositories[rootPath] = repository
                    } catch {
                        errors[rootPath] = error.localizedDescription
                    }
                }
                return (repositories, errors)
            }.value
            guard !Task.isCancelled else { return }
            repositoriesByRoot = result.0
            repositoryErrorsByRoot = result.1
        }
        .sheet(item: $commandsHelpContext) { context in
            RebaseCommandsHelpView(title: context.title, items: context.items)
        }
        .alert("Discard Rebase Changes?", isPresented: $showDiscardChangesAlert) {
            Button("Keep Editing", role: .cancel) {}
            Button("Discard Changes", role: .destructive, action: onCancel)
        } message: {
            Text("One or more Git roots have unsaved interactive rebase changes.")
        }
        .alert("No Commits to Rebase", isPresented: $showNoopConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Continue", action: onStart)
        } message: {
            Text("One or more selected repositories have no commits to rebase. Continue anyway?")
        }
    }

    @ViewBuilder
    private func rootSection(_ rootIndex: Int) -> some View {
        let draft = drafts[rootIndex]
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(draft.displayName, systemImage: "externaldrive")
                    .font(.callout.weight(.semibold))
                Text(draft.rootPath)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let initialItems = initialItemsByRoot[draft.rootPath] {
                    Button("Undo") { undo(rootIndex: rootIndex) }
                        .disabled(!(historyByRoot[draft.rootPath]?.canUndo ?? false))
                        .help("Undo the last todo edit in this repository")
                    Button("Redo") { redo(rootIndex: rootIndex) }
                        .disabled(!(historyByRoot[draft.rootPath]?.canRedo ?? false))
                        .help("Redo the last todo edit in this repository")
                    Button("Reset") {
                        let reset = resetRebaseTodoDraftItems(
                            current: drafts[rootIndex].items,
                            initial: initialItems
                        )
                        record(reset, rootIndex: rootIndex, change: .structural)
                        drafts[rootIndex].rawTodo = nil
                        selectedByRoot[draft.rootPath] = nil
                    }
                    .disabled(draft.items == initialItems && draft.rawTodo == nil)
                    .help("Restore this repository's todo from when the editor opened")
                }
                if draft.loadError == nil {
                    Button(draft.rawTodo == nil ? "Edit Native Todo…" : "Native Todo Edited") {
                        onOpenRawTodo(draft)
                    }
                    .buttonStyle(.bordered)
                    Button("Commands…") {
                        commandsHelpContext = RebaseCommandsHelpContext(
                            title: "Git Rebase Commands · \(draft.displayName)",
                            items: draft.items
                        )
                    }
                    .help("Show the available action commands for this repository's todo")
                }
                Text("\(draft.items.count) commits")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let loadError = draft.loadError {
                Label(loadError, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                HStack(spacing: 8) {
                    Picker("bulk action", selection: Binding(
                        get: { bulkActionByRoot[draft.rootPath] ?? .pick },
                        set: { bulkActionByRoot[draft.rootPath] = $0 }
                    )) {
                        Text("Pick").tag(RebaseTodoAction.pick)
                        Text("Reword").tag(RebaseTodoAction.reword)
                        Text("Edit").tag(RebaseTodoAction.edit)
                        Text("Squash").tag(RebaseTodoAction.squash)
                        Text("Fixup").tag(RebaseTodoAction.fixup)
                        Text("Drop").tag(RebaseTodoAction.drop)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 100)
                    Button("Apply to Selected") { applyBulkAction(rootIndex: rootIndex) }
                        .disabled((selectedByRoot[draft.rootPath]?.isEmpty ?? true))
                    Text("\(selectedByRoot[draft.rootPath]?.count ?? 0) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                ForEach(drafts[rootIndex].items.indices, id: \.self) { itemIndex in
                    todoRow(rootIndex: rootIndex, itemIndex: itemIndex)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
    }

    private func todoRow(rootIndex: Int, itemIndex: Int) -> some View {
        let rootPath = drafts[rootIndex].rootPath
        let commitID = drafts[rootIndex].items[itemIndex].commitId
        let isSelected = selectedByRoot[rootPath]?.contains(commitID) == true
        let selectedIDs = selectedByRoot[rootPath] ?? []
        let selectedIndices = Set(drafts[rootIndex].items.indices.filter {
            selectedIDs.contains(drafts[rootIndex].items[$0].commitId)
        })
        let contextSelection = rebaseTodoContextSelection(
            selectedIndices: selectedIndices,
            row: itemIndex
        )
        let preserveMergeOrderChanged = preserveMergeOrderChanged(rootIndex: rootIndex)
        let canEditOrDrop = contextSelection.allSatisfy {
            drafts[rootIndex].items.indices.contains($0)
                && !drafts[rootIndex].items[$0].isMergeCommit
        }
        let canUnite = uniteRebaseTodoItems(
            drafts[rootIndex].items,
            selectedIndices: contextSelection,
            action: .squash,
            preserveMerges: preserveMerges
        ) != nil && !preserveMergeOrderChanged
        return HStack(spacing: 8) {
            Button {
                toggleSelection(rootIndex: rootIndex, commitID: commitID)
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isSelected ? "Remove from selection" : "Select this commit")
            if drafts[rootIndex].items[itemIndex].isMergeCommit {
                Picker("merge action", selection: Binding(
                    get: { drafts[rootIndex].items[itemIndex].action },
                    set: { setMergeAction($0, rootIndex: rootIndex, itemIndex: itemIndex) }
                )) {
                    Text("pick").tag(RebaseTodoAction.pick)
                    Text("reword").tag(RebaseTodoAction.reword)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 100)
            } else {
                Picker("", selection: Binding(
                    get: { drafts[rootIndex].items[itemIndex].action },
                    set: { setAction($0, rootIndex: rootIndex, itemIndex: itemIndex) }
                )) {
                    Text("pick").tag(RebaseTodoAction.pick)
                    if rebaseTodoCanReword(
                        items: drafts[rootIndex].items,
                        index: itemIndex
                    ) {
                        Text("reword").tag(RebaseTodoAction.reword)
                    }
                    Text("edit").tag(RebaseTodoAction.edit)
                    if !preserveMergeOrderChanged,
                       rebaseTodoCanSquashOrFixup(
                        items: drafts[rootIndex].items,
                        index: itemIndex,
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

            Text(shortId(drafts[rootIndex].items[itemIndex].commitId))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)

            if drafts[rootIndex].items[itemIndex].isMergeCommit,
               drafts[rootIndex].items[itemIndex].action == .reword {
                TextField("reword merge message", text: Binding(
                    get: { drafts[rootIndex].items[itemIndex].message ?? drafts[rootIndex].items[itemIndex].summary },
                    set: { setMessage($0, rootIndex: rootIndex, itemIndex: itemIndex) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
            } else if drafts[rootIndex].items[itemIndex].isMergeCommit {
                Text("merge topology controlled by Git: \(drafts[rootIndex].items[itemIndex].summary)")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            } else if drafts[rootIndex].items[itemIndex].action == .squash {
                TextEditor(text: Binding(
                    get: { drafts[rootIndex].items[itemIndex].message ?? "" },
                    set: { setMessage($0, rootIndex: rootIndex, itemIndex: itemIndex) }
                ))
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 48, maxHeight: 88)
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.25))
                }
                .help("Optional final message for the squashed commit; leave empty for Git's default combined message.")
            } else if drafts[rootIndex].items[itemIndex].action == .reword {
                TextField("reword message", text: Binding(
                    get: { drafts[rootIndex].items[itemIndex].message ?? drafts[rootIndex].items[itemIndex].summary },
                    set: { setMessage($0, rootIndex: rootIndex, itemIndex: itemIndex) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
            } else {
                Text(drafts[rootIndex].items[itemIndex].summary)
                    .lineLimit(1)
                    .strikethrough(drafts[rootIndex].items[itemIndex].action == .drop)
                    .foregroundStyle(drafts[rootIndex].items[itemIndex].action == .drop ? .secondary : .primary)
            }
            Spacer()
            Button(action: { move(rootIndex: rootIndex, itemIndex: itemIndex, by: -1) }) {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.plain)
            .disabled(!rebaseTodoCanMove(
                drafts[rootIndex].items,
                selectedIndices: selectedIndices,
                requestedIndex: itemIndex,
                by: -1,
                preserveMerges: preserveMerges
            ))
            Button(action: { move(rootIndex: rootIndex, itemIndex: itemIndex, by: 1) }) {
                Image(systemName: "arrow.down")
            }
            .buttonStyle(.plain)
            .disabled(!rebaseTodoCanMove(
                drafts[rootIndex].items,
                selectedIndices: selectedIndices,
                requestedIndex: itemIndex,
                by: 1,
                preserveMerges: preserveMerges
            ))
        }
        .contextMenu {
            Button("Pick") { applyContextAction(.pick, rootIndex: rootIndex, itemIndex: itemIndex) }
            if drafts[rootIndex].items[itemIndex].isMergeCommit
                || rebaseTodoCanReword(items: drafts[rootIndex].items, index: itemIndex) {
                Button("Reword") { applyContextAction(.reword, rootIndex: rootIndex, itemIndex: itemIndex) }
            }
            if canEditOrDrop {
                Button("Edit") { applyContextAction(.edit, rootIndex: rootIndex, itemIndex: itemIndex) }
            }
            if canUnite {
                Button("Squash") { applyContextAction(.squash, rootIndex: rootIndex, itemIndex: itemIndex) }
                Button("Fixup") { applyContextAction(.fixup, rootIndex: rootIndex, itemIndex: itemIndex) }
            }
            if canEditOrDrop {
                Button("Drop") { applyContextAction(.drop, rootIndex: rootIndex, itemIndex: itemIndex) }
            }
            Divider()
            Button("Commands…") {
                commandsHelpContext = RebaseCommandsHelpContext(
                    title: "Git Rebase Commands · \(drafts[rootIndex].displayName)",
                    items: drafts[rootIndex].items
                )
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            detailSelection = MultiRootRebaseDetailSelection(rootPath: rootPath, commitID: commitID)
        }
    }

    private func move(rootIndex: Int, itemIndex: Int, by delta: Int) {
        guard drafts.indices.contains(rootIndex),
              drafts[rootIndex].items.indices.contains(itemIndex) else { return }
        let rootPath = drafts[rootIndex].rootPath
        let selectedIDs = selectedByRoot[rootPath] ?? []
        let selectedIndices = Set(drafts[rootIndex].items.indices.filter {
            selectedIDs.contains(drafts[rootIndex].items[$0].commitId)
        })
        let effectiveSelection = selectedIndices.contains(itemIndex) ? selectedIndices : [itemIndex]
        let updated = moveRebaseTodoItems(
            drafts[rootIndex].items,
            selectedIndices: effectiveSelection,
            requestedIndex: itemIndex,
            by: delta
        )
        guard updated != drafts[rootIndex].items,
              !preserveMerges
                || rebaseTodoPreserveMergeReorderIsSafe(
                    original: drafts[rootIndex].items,
                    updated: updated
                ) else { return }
        record(updated, rootIndex: rootIndex, change: .structural)
    }

    private func setAction(
        _ action: RebaseTodoAction,
        rootIndex: Int,
        itemIndex: Int
    ) {
        guard drafts.indices.contains(rootIndex),
              drafts[rootIndex].items.indices.contains(itemIndex),
              !drafts[rootIndex].items[itemIndex].isMergeCommit else { return }
        guard !preserveMergeOrderChanged(rootIndex: rootIndex)
                || (action != .squash && action != .fixup) else { return }
        var updated = drafts[rootIndex].items
        guard applyRebaseTodoAction(&updated, at: itemIndex, action: action) else { return }
        record(updated, rootIndex: rootIndex, change: .structural)
    }

    private func toggleSelection(rootIndex: Int, commitID: String) {
        guard drafts.indices.contains(rootIndex) else { return }
        let rootPath = drafts[rootIndex].rootPath
        detailSelection = MultiRootRebaseDetailSelection(rootPath: rootPath, commitID: commitID)
        var selection = selectedByRoot[rootPath, default: []]
        if !selection.insert(commitID).inserted {
            selection.remove(commitID)
        }
        selectedByRoot[rootPath] = selection
    }

    private func detailCommitIDs(for selection: MultiRootRebaseDetailSelection) -> [String] {
        guard let draft = drafts.first(where: { $0.rootPath == selection.rootPath }) else {
            return [selection.commitID]
        }
        let selectedIDs = selectedByRoot[selection.rootPath] ?? []
        return multiRootRebaseDetailCommitIDs(
            draft: draft,
            selectedIDs: selectedIDs,
            focusedID: selection.commitID
        )
    }

    private func applyBulkAction(rootIndex: Int) {
        guard drafts.indices.contains(rootIndex) else { return }
        let rootPath = drafts[rootIndex].rootPath
        let selectedIDs = selectedByRoot[rootPath] ?? []
        let indices = Set(drafts[rootIndex].items.indices.filter {
            selectedIDs.contains(drafts[rootIndex].items[$0].commitId)
        })
        guard !indices.isEmpty else { return }
        let action = bulkActionByRoot[rootPath] ?? .pick
        if action == .squash || action == .fixup {
            guard !preserveMergeOrderChanged(rootIndex: rootIndex) else { return }
            guard let united = uniteRebaseTodoItems(
                drafts[rootIndex].items,
                selectedIndices: indices,
                action: action,
                preserveMerges: preserveMerges
            ) else { return }
            record(united, rootIndex: rootIndex, change: .structural)
            return
        }

        var updated = drafts[rootIndex].items
        let selectedCommitIDs = indices.sorted().compactMap { index in
            drafts[rootIndex].items.indices.contains(index)
                ? drafts[rootIndex].items[index].commitId
                : nil
        }
        for commitID in selectedCommitIDs.reversed() {
            guard let index = updated.firstIndex(where: { $0.commitId == commitID }) else { continue }
            guard !updated[index].isMergeCommit else { continue }
            _ = applyRebaseTodoAction(&updated, at: index, action: action)
        }
        normalizeRebaseTodoActions(&updated, preserveMerges: preserveMerges)
        record(updated, rootIndex: rootIndex, change: .structural)
    }

    private func applyContextAction(
        _ action: RebaseTodoAction,
        rootIndex: Int,
        itemIndex: Int
    ) {
        guard drafts.indices.contains(rootIndex),
              drafts[rootIndex].items.indices.contains(itemIndex) else { return }
        let rootPath = drafts[rootIndex].rootPath
        let selectedIDs = selectedByRoot[rootPath] ?? []
        let selectedIndices = Set(drafts[rootIndex].items.indices.filter {
            selectedIDs.contains(drafts[rootIndex].items[$0].commitId)
        })
        let contextSelection = rebaseTodoContextSelection(
            selectedIndices: selectedIndices,
            row: itemIndex
        )
        let contextIDs = Set(contextSelection.compactMap { index in
            drafts[rootIndex].items.indices.contains(index)
                ? drafts[rootIndex].items[index].commitId
                : nil
        })

        if action == .squash || action == .fixup {
            guard !preserveMergeOrderChanged(rootIndex: rootIndex) else { return }
            guard let united = uniteRebaseTodoItems(
                drafts[rootIndex].items,
                selectedIndices: contextSelection,
                action: action,
                preserveMerges: preserveMerges
            ) else { return }
            selectedByRoot[rootPath] = contextIDs
            detailSelection = MultiRootRebaseDetailSelection(
                rootPath: rootPath,
                commitID: drafts[rootIndex].items[itemIndex].commitId
            )
            record(united, rootIndex: rootIndex, change: .structural)
            return
        }

        if action == .edit || action == .drop {
            guard contextSelection.allSatisfy({
                drafts[rootIndex].items.indices.contains($0)
                    && !drafts[rootIndex].items[$0].isMergeCommit
            }) else { return }
        }

        var updated = drafts[rootIndex].items
        let contextCommitIDs = contextSelection.sorted().compactMap { target in
            drafts[rootIndex].items.indices.contains(target)
                ? drafts[rootIndex].items[target].commitId
                : nil
        }
        for commitID in contextCommitIDs.reversed() {
            guard let target = updated.firstIndex(where: { $0.commitId == commitID }) else { continue }
            _ = applyRebaseTodoAction(&updated, at: target, action: action)
        }
        normalizeRebaseTodoActions(&updated, preserveMerges: preserveMerges)
        selectedByRoot[rootPath] = contextIDs
        detailSelection = MultiRootRebaseDetailSelection(
            rootPath: rootPath,
            commitID: drafts[rootIndex].items[itemIndex].commitId
        )
        record(updated, rootIndex: rootIndex, change: .structural)
    }

    private func setMergeAction(
        _ action: RebaseTodoAction,
        rootIndex: Int,
        itemIndex: Int
    ) {
        guard drafts.indices.contains(rootIndex),
              drafts[rootIndex].items.indices.contains(itemIndex),
              drafts[rootIndex].items[itemIndex].isMergeCommit else { return }
        var updated = drafts[rootIndex].items
        setRebaseTodoAction(&updated[itemIndex], action: action)
        record(updated, rootIndex: rootIndex, change: .structural)
    }

    private func setMessage(
        _ message: String,
        rootIndex: Int,
        itemIndex: Int
    ) {
        guard drafts.indices.contains(rootIndex),
              drafts[rootIndex].items.indices.contains(itemIndex) else { return }
        var updated = drafts[rootIndex].items
        updated[itemIndex].message = message.isEmpty ? nil : message
        record(
            updated,
            rootIndex: rootIndex,
            change: .message(commitID: updated[itemIndex].commitId)
        )
    }

    private func record(
        _ updated: [RebaseTodoItem],
        rootIndex: Int,
        change: RebaseTodoHistoryChange
    ) {
        guard drafts.indices.contains(rootIndex) else { return }
        let rootPath = drafts[rootIndex].rootPath
        var rootHistory = historyByRoot[rootPath]
            ?? RebaseTodoEditHistory(initial: drafts[rootIndex].items)
        rootHistory.record(updated, change: change)
        historyByRoot[rootPath] = rootHistory
        drafts[rootIndex].items = updated
    }

    private func undo(rootIndex: Int) {
        guard drafts.indices.contains(rootIndex) else { return }
        let rootPath = drafts[rootIndex].rootPath
        guard var rootHistory = historyByRoot[rootPath],
              let previous = rootHistory.undo() else { return }
        historyByRoot[rootPath] = rootHistory
        drafts[rootIndex].items = previous
    }

    private func redo(rootIndex: Int) {
        guard drafts.indices.contains(rootIndex) else { return }
        let rootPath = drafts[rootIndex].rootPath
        guard var rootHistory = historyByRoot[rootPath],
              let next = rootHistory.redo() else { return }
        historyByRoot[rootPath] = rootHistory
        drafts[rootIndex].items = next
    }

    private func shortId(_ id: String) -> String {
        String(id.prefix(7))
    }

    private func preserveMergeOrderChanged(rootIndex: Int) -> Bool {
        guard preserveMerges,
              drafts.indices.contains(rootIndex),
              let initial = initialItemsByRoot[drafts[rootIndex].rootPath] else {
            return false
        }
        return rebaseTodoPreserveMergeOrderChanged(
            initial: initial,
            current: drafts[rootIndex].items,
            preserveMerges: preserveMerges
        )
    }

    private func requestCancel() {
        let hasChanges = drafts.contains { draft in
            guard let initial = initialItemsByRoot[draft.rootPath] else {
                return draft.rawTodo != nil
            }
            return rebaseTodoHasUnsavedChanges(
                current: draft.items,
                initial: initial,
                rawTodo: draft.rawTodo
            )
        }
        if hasChanges {
            showDiscardChangesAlert = true
        } else {
            onCancel()
        }
    }

    private func requestStart() {
        guard !drafts.isEmpty, !hasErrors else { return }
        if !noopRootPaths.isEmpty {
            showNoopConfirmation = true
        } else {
            onStart()
        }
    }
}
/// REBASE-001：显式 rebase todo 编辑器。
/// 行内 action 菜单（pick/reword/edit/squash/fixup/drop）、上移/下移排序、
/// 多选后批量设置 action；reword 行内编辑新信息。最终顺序与 action 是
/// 执行时的权威（rebase_with_todo）。
func resetRebaseTodoDraftItems(
    current: [RebaseTodoItem],
    initial: [RebaseTodoItem]
) -> [RebaseTodoItem] {
    current == initial ? current : initial
}
