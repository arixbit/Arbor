import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Recovery choice for a multi-root rebase that was aborted or failed after
/// one or more repositories already moved their selected branch.
struct RebasedMultiRootRebaseRollbackView: View {
    let branch: String
    let targets: [MultiRootRebaseRollbackTarget]
    let failures: [String]
    let onRollback: () -> Void
    let onKeep: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Multi-root Rebase Partially Completed")
                .font(.title3.weight(.semibold))
            Text(
                String(localized: "Rebase %@ completed in some repositories, but the operation was stopped before every repository finished.")
                    .replacingOccurrences(of: "%@", with: branch)
            )
                .font(.caption)
                .foregroundStyle(.secondary)
            if !targets.isEmpty {
                Text("Successful repositories")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(targets) { target in
                        HStack(spacing: 7) {
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(target.displayName)
                                Text(
                                    "HEAD \(String(target.initialHead.prefix(7))) → \(String(target.expectedHead.prefix(7)))"
                                )
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
            }
            if !failures.isEmpty {
                Text("Failed or stopped repositories")
                    .font(.headline)
                ScrollView {
                    Text(failures.joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
            }
            Text("Rollback only runs when a repository still has the expected HEAD; newer commits are never overwritten.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done", role: .cancel, action: onDone)
                Button("Keep Partial", action: onKeep)
                Button("Rollback Successful Roots", role: .destructive, action: onRollback)
                    .keyboardShortcut(.defaultAction)
                    .disabled(targets.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 680, height: 480)
    }
}
func rebaseStartNeedsNoopConfirmation(interactive: Bool, rangeCount: Int) -> Bool {
    interactive && rangeCount == 0
}
let rebaseHelpDocumentationURL = URL(string: "https://git-scm.com/docs/git-rebase")!
private struct RebaseHelpPopupView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rebase a branch based on one branch to another:")
                .font(.headline)
            Text("A---B---C  main\n     \\\n      D---E    feature\n\nfeature → main\nA---B---C---D'---E'")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Link("git rebase on git-scm.com", destination: rebaseHelpDocumentationURL)
                .help("Open the Git rebase documentation")
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }
}
struct RebasedRebaseDialog: View {
    @Binding var onto: String
    @Binding var branch: String
    @Binding var repositoryPath: String
    @Binding var interactive: Bool
    @Binding var preserveMerges: Bool
    @Binding var autoSquash: Bool
    @Binding var keepEmpty: Bool
    @Binding var updateRefs: Bool
    @Binding var root: Bool
    @Binding var applyToAllRepositories: Bool
    let rangeCount: Int
    let repositories: [GitRootInfo]
    let branches: [BranchInfo]
    let onLoadRange: () -> Void
    let onRangeInputsChanged: () -> Void
    let onRepositoryChanged: () -> Void
    let onStart: () -> Void
    let onCancel: () -> Void

    @State private var showNoopConfirmation = false
    @State private var showRebaseHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rebase").font(.title3.weight(.semibold))
            if repositories.count > 1 {
                Picker("Repository", selection: $repositoryPath) {
                    ForEach(repositories, id: \.path) { repository in
                        Text(repository.displayName).tag(repository.path)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if !repositoryPath.isEmpty {
                LabeledContent("Repository") {
                    Text(repositoryPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if repositories.count > 1 {
                Toggle("Edit todo for all repositories", isOn: $applyToAllRepositories)
                    .toggleStyle(.checkbox)
            }
            HStack(spacing: 8) {
                Text("Branch")
                    .foregroundStyle(.secondary)
                TextField("branch to rebase", text: $branch)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    ForEach(branches, id: \.name) { item in
                        Button(item.name) { branch = item.name }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
            }
            HStack(spacing: 8) {
                Text(root ? "New base" : "Onto")
                    .foregroundStyle(.secondary)
                TextField(root ? "optional branch or revision" : "branch or revision", text: $onto)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    ForEach(branches, id: \.name) { item in
                        Button(item.name) { onto = item.name }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                Button {
                    showRebaseHelp = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Show Git rebase help")
                .accessibilityLabel("Show Git rebase help")
                .popover(isPresented: $showRebaseHelp, arrowEdge: .bottom) {
                    RebaseHelpPopupView()
                }
            }
            HStack(spacing: 14) {
                Toggle("Interactive", isOn: $interactive)
                    .toggleStyle(.checkbox)
                Toggle("Preserve merge commits", isOn: $preserveMerges)
                    .toggleStyle(.checkbox)
                Toggle("Autosquash", isOn: $autoSquash)
                    .toggleStyle(.checkbox)
            }
            HStack(spacing: 14) {
                Toggle("Keep empty commits", isOn: $keepEmpty)
                    .toggleStyle(.checkbox)
                Toggle("Update refs", isOn: $updateRefs)
                    .toggleStyle(.checkbox)
                Toggle("Rebase from root", isOn: $root)
                    .toggleStyle(.checkbox)
            }
            if rangeCount > 0 {
                Text("\(rangeCount) commits loaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Load Range", action: onLoadRange)
                    .disabled(!rebaseInputsCanLoadRange(onto: onto, branch: branch, root: root))
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Start Rebase", action: requestStart)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        !rebaseInputsCanLoadRange(onto: onto, branch: branch, root: root)
                    )
            }
        }
        .padding(20)
        .frame(width: 600)
        .onChange(of: onto) { _, _ in
            onRangeInputsChanged()
        }
        .onChange(of: branch) { _, _ in
            onRangeInputsChanged()
        }
        .onChange(of: repositoryPath) { _, _ in
            onRepositoryChanged()
        }
        .onChange(of: preserveMerges) { _, _ in
            onRangeInputsChanged()
        }
        .onChange(of: interactive) { _, newValue in
            if !newValue {
                onRangeInputsChanged()
            }
        }
        .onChange(of: root) { _, _ in
            onRangeInputsChanged()
        }
        .alert("No Commits to Rebase", isPresented: $showNoopConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Continue", action: onStart)
        } message: {
            Text("The selected branch has no commits to rebase. Continue anyway?")
        }
    }

    private func requestStart() {
        guard rebaseInputsCanLoadRange(onto: onto, branch: branch, root: root) else { return }
        if rebaseStartNeedsNoopConfirmation(interactive: interactive, rangeCount: rangeCount) {
            showNoopConfirmation = true
        } else {
            onStart()
        }
    }
}
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
        let rangeDescription = onto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? branch + " from repository root"
            : branch + " onto " + shortId(onto)
        return rangeDescription + " · " + String(drafts.count)
            + " repositories · " + String(totalItems) + " commits"
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
/// Read-only commit details shown beside the structured rebase table.
/// The selected todo rows remain the source of truth; this pane only loads
/// metadata and changes for inspection, matching IntelliJ's details splitter.
private struct RebaseTodoCommitDetailsPane: View {
    let repo: Repository
    let commitIDs: [String]
    @State private var commits: [CommitInfo] = []
    @State private var focusedID: String?
    @State private var loadError: String?

    private var focusedCommit: CommitInfo? {
        guard let focusedID else { return commits.first }
        return commits.first { $0.id == focusedID } ?? commits.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if commits.count > 1 {
                List(selection: $focusedID) {
                    ForEach(commits, id: \.id) { commit in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(commit.summary)
                                .font(.callout.weight(.semibold))
                                .lineLimit(2)
                            Text(commit.shortId)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .tag(commit.id)
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 90, idealHeight: 125, maxHeight: 180)
            }

            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if let focusedCommit {
                CommitDetailView(
                    repo: repo,
                    commit: focusedCommit,
                    remotes: [],
                    onReverted: {},
                    onCherryPicked: {},
                    onCreateBranch: { _ in },
                    showsMetadata: true,
                    showsActions: false,
                    showsDiffPreview: true,
                    showsChanges: true
                )
            } else if commitIDs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sidebar.right")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Select a commit to view details")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Loading commit details…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: commitIDs) {
            commits = []
            focusedID = nil
            loadError = nil
            guard !commitIDs.isEmpty else { return }
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try commitIDs.map { try repo.commitInfo(commitId: $0) }
                }.value
                guard !Task.isCancelled else { return }
                commits = loaded
                focusedID = loaded.first?.id
            } catch {
                guard !Task.isCancelled else { return }
                loadError = error.localizedDescription
            }
        }
    }
}
/// Move the selected entries by one row while preserving their entry identity.
/// This mirrors IntelliJ's table move action: non-contiguous selections move
/// one step at a time, in order, rather than being treated as one index range.
func moveRebaseTodoItems(
    _ items: [RebaseTodoItem],
    selectedIndices: Set<Int>,
    requestedIndex: Int,
    by delta: Int
) -> [RebaseTodoItem] {
    guard (delta == -1 || delta == 1),
          items.indices.contains(requestedIndex) else { return items }
    let movingIDs: Set<String>
    if selectedIndices.contains(requestedIndex) {
        movingIDs = Set(selectedIndices.compactMap { index in
            items.indices.contains(index) ? items[index].commitId : nil
        })
    } else {
        movingIDs = [items[requestedIndex].commitId]
    }
    guard !movingIDs.isEmpty else { return items }

    let orderedIDs = items.filter { movingIDs.contains($0.commitId) }.map(\.commitId)
    var result = items
    let iteration: [String] = delta < 0 ? orderedIDs : Array(orderedIDs.reversed())
    for commitID in iteration {
        _ = moveOneRebaseTodoItem(&result, commitID: commitID, by: delta)
    }
    return result
}
/// Move one todo entry with the same group semantics as IntelliJ's
/// `GitRebaseTodoModel.exchangeIndices`:
///
/// - a squash/fixup child stays inside its group while moving within the
///   group, but becomes an independent pick when moved outside it;
/// - a group root moves together with all of its children;
/// - an entry inserted immediately before another group's child joins that
///   group as a fixup.
///
/// The structured model has no separate UniteRoot/UniteChild type, so the
/// action (`pick`/`squash`/`fixup`) is the persisted representation of that
/// relationship.
@discardableResult
private func moveOneRebaseTodoItem(
    _ items: inout [RebaseTodoItem],
    commitID: String,
    by delta: Int
) -> Bool {
    guard (delta == -1 || delta == 1),
          let index = items.firstIndex(where: { $0.commitId == commitID }),
          !items[index].isMergeCommit else { return false }

    let groupRoot = rebaseTodoGroupRootIndex(items: items, index: index) ?? index
    let groupIndices = rebaseTodoGroupIndices(items: items, rootIndex: groupRoot)
    let isGroupChild = groupIndices.count > 1 && index != groupRoot

    if isGroupChild {
        let targetIndex = index + delta
        guard items.indices.contains(targetIndex) else { return false }

        // IntelliJ first removes a UniteChild, moves it to the old group's
        // last slot, and only then applies the requested exchange. This
        // preserves the group's invariant when a child is exchanged with
        // another child, while making a child an independent pick when it
        // crosses the group's root or its trailing boundary.
        let groupEnd = groupIndices.last ?? index
        var detached = items.remove(at: index)
        setRebaseTodoAction(&detached, action: .pick)
        let groupSlot = min(groupEnd, items.count)
        items.insert(detached, at: groupSlot)

        if groupSlot == targetIndex {
            setRebaseTodoAction(&items[groupSlot], action: .fixup)
            return true
        }

        let moved = items.remove(at: groupSlot)
        items.insert(moved, at: targetIndex)
        attachRebaseTodoEntryIfNeeded(&items, at: targetIndex)
        return true
    }

    let isGroupRoot = groupIndices.count > 1 && index == groupRoot
    if isGroupRoot {
        let range = groupRoot...(groupIndices.last ?? groupRoot)
        let destination = delta < 0 ? range.lowerBound - 1 : range.upperBound + 1
        guard destination >= 0, destination < items.count else { return false }

        let moving = Array(items[range])
        items.removeSubrange(range)
        let insertionIndex = delta < 0
            ? destination
            : min(destination - moving.count + 1, items.count)
        items.insert(contentsOf: moving, at: insertionIndex)
        attachRebaseTodoUnitIfNeeded(&items, at: insertionIndex, count: moving.count)
        return true
    }

    let adjacentIndex = index + delta
    guard items.indices.contains(adjacentIndex) else { return false }
    items.swapAt(index, adjacentIndex)
    attachRebaseTodoEntryIfNeeded(&items, at: adjacentIndex)
    return true
}
/// If a moved entry now sits immediately before a UniteChild, preserve the
/// reference model's implicit group join by representing it as a fixup.
private func attachRebaseTodoEntryIfNeeded(
    _ items: inout [RebaseTodoItem],
    at index: Int
) {
    attachRebaseTodoUnitIfNeeded(&items, at: index, count: 1)
}
private func attachRebaseTodoUnitIfNeeded(
    _ items: inout [RebaseTodoItem],
    at index: Int,
    count: Int
) {
    guard count > 0,
          index >= 0,
          index + count <= items.count,
          index + count < items.count,
          !items[index].isMergeCommit,
          !items[index + count].isMergeCommit,
          items[index + count].action == .squash || items[index + count].action == .fixup,
          let groupRoot = rebaseTodoGroupRootIndex(items: items, index: index + count),
          groupRoot < index + count else {
        return
    }
    for offset in 0..<count {
        setRebaseTodoAction(&items[index + offset], action: .fixup)
    }
}
/// Apply SwiftUI's drag/drop destination to the todo array while preserving
/// the dragged commit identities and the order of a multi-row selection.
/// The destination is expressed in the pre-removal coordinate space.
func moveRebaseTodoRows(
    _ items: [RebaseTodoItem],
    from source: IndexSet,
    to destination: Int
) -> [RebaseTodoItem] {
    let sourceIndices = source.filter { items.indices.contains($0) }
    guard sourceIndices.count == source.count,
          !sourceIndices.isEmpty,
          (0...items.count).contains(destination) else { return items }

    // Dragging any member of a squash/fixup group moves the complete group.
    // This keeps the drag path consistent with the arrow buttons and avoids
    // manufacturing a group whose root is left behind in the source range.
    var expandedSource = Set(sourceIndices)
    for index in sourceIndices {
        guard let root = rebaseTodoGroupRootIndex(items: items, index: index) else { continue }
        expandedSource.formUnion(rebaseTodoGroupIndices(items: items, rootIndex: root))
    }
    let expandedIndices = expandedSource.sorted()
    let moving = expandedIndices.map { items[$0] }
    let movingSet = Set(expandedIndices)
    var remaining = items.enumerated()
        .filter { !movingSet.contains($0.offset) }
        .map(\.element)
    let removedBeforeDestination = expandedIndices.filter { $0 < destination }.count
    let insertionIndex = min(
        max(destination - removedBeforeDestination, 0),
        remaining.count
    )
    remaining.insert(contentsOf: moving, at: insertionIndex)
    attachRebaseTodoUnitIfNeeded(&remaining, at: insertionIndex, count: moving.count)
    return remaining
}
/// Preserve-merges structured editing may reorder rows only inside the
/// branch segments represented by the native todo. Merge rows are the visible
/// anchors for Git's hidden label/reset/merge control blocks and must keep
/// both their position and identity.
func rebaseTodoPreserveMergeSegmentRanges(
    _ items: [RebaseTodoItem]
) -> [Range<Int>] {
    guard !items.isEmpty else { return [] }
    var ranges: [Range<Int>] = []
    var segmentStart: Int?
    for index in items.indices {
        if items[index].isMergeCommit {
            if let segmentStart {
                ranges.append(segmentStart..<index)
            }
            segmentStart = nil
            continue
        }
        let startsSegment = index == items.startIndex
            || items[index - 1].isMergeCommit
            || !items[index].canSquashOrFixup
        if startsSegment {
            if let segmentStart {
                ranges.append(segmentStart..<index)
            }
            segmentStart = index
        }
    }
    if let segmentStart {
        ranges.append(segmentStart..<items.count)
    }
    return ranges
}
/// Return false when a proposed structured move would cross a merge control
/// boundary. The check is identity-based so selection and action edits cannot
/// make a stale index appear safe.
func rebaseTodoPreserveMergeReorderIsSafe(
    original: [RebaseTodoItem],
    updated: [RebaseTodoItem]
) -> Bool {
    guard original.count == updated.count else { return false }
    guard zip(original, updated).allSatisfy({ $0.isMergeCommit == $1.isMergeCommit }) else {
        return false
    }
    for (index, item) in original.enumerated() where item.isMergeCommit {
        guard original[index].commitId == updated[index].commitId else { return false }
    }
    for range in rebaseTodoPreserveMergeSegmentRanges(original) {
        let originalIDs = Set(original[range].map(\.commitId))
        let updatedIDs = Set(updated[range].map(\.commitId))
        guard originalIDs == updatedIDs else { return false }
    }
    return true
}
/// Whether a preserve-merges todo changed its visible commit order. The
/// identity check is shared by single-root and per-root multi-root editors.
func rebaseTodoPreserveMergeOrderChanged(
    initial: [RebaseTodoItem],
    current: [RebaseTodoItem],
    preserveMerges: Bool
) -> Bool {
    preserveMerges && initial.map(\.commitId) != current.map(\.commitId)
}
func rebaseTodoCanMove(
    _ items: [RebaseTodoItem],
    selectedIndices: Set<Int>,
    requestedIndex: Int,
    by delta: Int,
    preserveMerges: Bool
) -> Bool {
    guard items.indices.contains(requestedIndex),
          !items[requestedIndex].isMergeCommit else { return false }
    let updated = moveRebaseTodoItems(
        items,
        selectedIndices: selectedIndices,
        requestedIndex: requestedIndex,
        by: delta
    )
    guard updated != items else { return false }
    return !preserveMerges
        || rebaseTodoPreserveMergeReorderIsSafe(original: items, updated: updated)
}
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
/// A squash/fixup row consumes the immediately preceding kept commit. The
/// graph capability is static, but the predecessor's action is user-editable;
/// keep the picker and bulk actions aligned with Git's todo constraint.
func rebaseTodoCanSquashOrFixup(
    items: [RebaseTodoItem],
    index: Int,
    preserveMerges: Bool
) -> Bool {
    guard items.indices.contains(index), index > 0 else { return false }
    guard !items[index].isMergeCommit, !items[index - 1].isMergeCommit else { return false }
    guard items[index - 1].action != .drop else { return false }
    return !preserveMerges || items[index].canSquashOrFixup
}
private func rebaseTodoGroupRootIndex(
    items: [RebaseTodoItem],
    index: Int
) -> Int? {
    guard items.indices.contains(index), !items[index].isMergeCommit else { return nil }
    var root = index
    while root > 0,
          items[root].action == .squash || items[root].action == .fixup {
        root -= 1
    }
    guard !items[root].isMergeCommit,
          items[root].action != .drop || root == index else { return nil }
    return root
}
private func rebaseTodoGroupIndices(
    items: [RebaseTodoItem],
    rootIndex: Int
) -> [Int] {
    guard items.indices.contains(rootIndex) else { return [] }
    var indices = [rootIndex]
    var next = rootIndex + 1
    while next < items.count,
          !items[next].isMergeCommit,
          items[next].action == .squash || items[next].action == .fixup {
        indices.append(next)
        next += 1
    }
    return indices
}
private func rebaseTodoEffectiveGroupMessage(
    items: [RebaseTodoItem],
    rootIndex: Int
) -> String {
    let indices = rebaseTodoGroupIndices(items: items, rootIndex: rootIndex)
    guard items.indices.contains(rootIndex) else { return "" }
    let root = items[rootIndex]
    if let message = root.message?.trimmingCharacters(in: .whitespacesAndNewlines),
       !message.isEmpty {
        return message
    }
    var parts = [root.summary]
    for index in indices.dropFirst() where items[index].action == .squash {
        parts.append(items[index].message ?? items[index].summary)
    }
    return parts.joined(separator: "\n\n")
}
/// Apply IntelliJ's selection-based unite behavior to a structured todo.
/// Selected rows (or their existing groups) are moved behind one kept root;
/// Fixup keeps the root message, while Squash exposes one final message row
/// and turns earlier children into fixups. In merge-preserving mode, only a
/// contiguous selection within one branch segment is accepted; native
/// topology rows and cross-segment selections remain fail-closed.
func uniteRebaseTodoItems(
    _ items: [RebaseTodoItem],
    selectedIndices: Set<Int>,
    action: RebaseTodoAction,
    preserveMerges: Bool
) -> [RebaseTodoItem]? {
    guard action == .squash || action == .fixup else { return nil }
    let selected = selectedIndices.sorted()
    guard !selected.isEmpty,
          selected.allSatisfy({ items.indices.contains($0) && !items[$0].isMergeCommit }) else {
        return nil
    }
    if preserveMerges {
        guard let first = selected.first,
              let last = selected.last,
              selected == Array(first...last),
              selected.dropFirst().allSatisfy({
                  rebaseTodoCanSquashOrFixup(items: items, index: $0, preserveMerges: true)
              }) else {
            return nil
        }
    }

    let targetRoot: Int?
    if selected.count == 1 {
        let selectedIndex = selected[0]
        targetRoot = (0..<selectedIndex).reversed()
            .compactMap { rebaseTodoGroupRootIndex(items: items, index: $0) }
            .first { items[$0].action != .drop }
    } else {
        targetRoot = rebaseTodoGroupRootIndex(items: items, index: selected[0])
    }
    guard let targetRoot else { return nil }

    let targetGroup = rebaseTodoGroupIndices(items: items, rootIndex: targetRoot)
    let targetGroupSet = Set(targetGroup)
    var addedIndices: [Int] = []
    for index in selected {
        guard let root = rebaseTodoGroupRootIndex(items: items, index: index) else { return nil }
        if targetGroupSet.contains(index) {
            continue
        }
        let group = rebaseTodoGroupIndices(items: items, rootIndex: root)
        if root == index, group.count > 1 {
            addedIndices.append(contentsOf: group)
        } else {
            addedIndices.append(index)
        }
    }
    guard !addedIndices.isEmpty else { return nil }
    var groupIndexSet = targetGroupSet
    groupIndexSet.formUnion(addedIndices)

    var orderedGroupIndices = targetGroup + addedIndices
    var seen = Set<Int>()
    orderedGroupIndices = orderedGroupIndices.filter { seen.insert($0).inserted }
    let groupItems = orderedGroupIndices.map { items[$0] }
    let remaining = items.enumerated()
        .filter { !groupIndexSet.contains($0.offset) }
        .map(\.element)
    let insertionIndex = items.enumerated()
        .prefix(targetRoot)
        .filter { !groupIndexSet.contains($0.offset) }
        .count

    var result = remaining
    result.insert(contentsOf: groupItems, at: insertionIndex)
    let rootResultIndex = insertionIndex
    let childStart = rootResultIndex + 1
    guard childStart < result.count else { return nil }

    if result[rootResultIndex].action == .edit || result[rootResultIndex].action == .drop {
        setRebaseTodoAction(&result[rootResultIndex], action: .pick)
    }
    for offset in 1..<groupItems.count {
        let originalIndex = orderedGroupIndices[offset]
        guard !targetGroupSet.contains(originalIndex) else { continue }
        let resultIndex = rootResultIndex + offset
        setRebaseTodoAction(&result[resultIndex], action: .fixup)
    }
    if action == .squash {
        let finalChildIndex = rootResultIndex + groupItems.count - 1
        setRebaseTodoAction(&result[finalChildIndex], action: .squash)
        var messageParts = [rebaseTodoEffectiveGroupMessage(items: items, rootIndex: targetRoot)]
        var consumedAddedIndices = Set<Int>()
        for index in addedIndices {
            guard !consumedAddedIndices.contains(index),
                  let root = rebaseTodoGroupRootIndex(items: items, index: index) else { continue }
            let group = rebaseTodoGroupIndices(items: items, rootIndex: root)
            if root == index, group.count > 1 {
                messageParts.append(rebaseTodoEffectiveGroupMessage(items: items, rootIndex: root))
                consumedAddedIndices.formUnion(group)
            } else if items[index].action != .fixup {
                messageParts.append(items[index].message ?? items[index].summary)
                consumedAddedIndices.insert(index)
            } else {
                consumedAddedIndices.insert(index)
            }
        }
        result[finalChildIndex].message = messageParts
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
    return result
}
/// Return whether a structured editor row can be reworded without breaking a
/// squash/fixup group. IntelliJ keeps reword on the group's root; a child must
/// first be detached with Pick/Edit/Drop.
func rebaseTodoCanReword(
    items: [RebaseTodoItem],
    index: Int
) -> Bool {
    guard items.indices.contains(index), !items[index].isMergeCommit else { return false }
    return rebaseTodoGroupRootIndex(items: items, index: index) == index
}
/// Apply one structured todo action while preserving IntelliJ's root/child
/// group semantics. A non-root action on a squash/fixup child detaches that
/// child and moves it after the group; dropping a group root drops the whole
/// group. Returning false means the action is not valid for this row.
@discardableResult
func applyRebaseTodoAction(
    _ items: inout [RebaseTodoItem],
    at index: Int,
    action: RebaseTodoAction
) -> Bool {
    guard items.indices.contains(index) else { return false }
    if items[index].isMergeCommit {
        guard action == .pick || action == .reword else { return false }
        setRebaseTodoAction(&items[index], action: action)
        return true
    }

    guard let rootIndex = rebaseTodoGroupRootIndex(items: items, index: index) else {
        return false
    }
    if action == .reword, rootIndex != index {
        return false
    }

    let groupIndices = rebaseTodoGroupIndices(items: items, rootIndex: rootIndex)
    if action == .drop, rootIndex == index, groupIndices.count > 1 {
        for groupIndex in groupIndices {
            setRebaseTodoAction(&items[groupIndex], action: .drop)
        }
        return true
    }

    if rootIndex != index,
       action != .squash,
       action != .fixup {
        let groupEndIndex = groupIndices.last ?? index
        var detached = items.remove(at: index)
        setRebaseTodoAction(&detached, action: action)
        items.insert(detached, at: min(groupEndIndex, items.count))
        return true
    }

    setRebaseTodoAction(&items[index], action: action)
    return true
}
func normalizeRebaseTodoActions(
    _ items: inout [RebaseTodoItem],
    preserveMerges: Bool
) {
    for index in items.indices {
        guard items[index].action == .squash || items[index].action == .fixup else { continue }
        guard rebaseTodoCanSquashOrFixup(items: items, index: index, preserveMerges: preserveMerges) else {
            items[index].action = .pick
            items[index].message = nil
            continue
        }
    }
}
func setRebaseTodoAction(_ item: inout RebaseTodoItem, action: RebaseTodoAction) {
    item.action = action
    if action != .reword && action != .squash {
        item.message = nil
    }
}
enum RebaseTodoHistoryChange: Equatable {
    case structural
    case message(commitID: String)
}
struct RebaseTodoEditHistory: Equatable {
    static let maximumStateCount = 10

    private(set) var states: [[RebaseTodoItem]]
    private(set) var cursor: Int
    private var lastChange: RebaseTodoHistoryChange?

    init(initial: [RebaseTodoItem]) {
        states = [initial]
        cursor = 0
        lastChange = nil
    }

    var current: [RebaseTodoItem] { states[cursor] }
    var canUndo: Bool { cursor > 0 }
    var canRedo: Bool { cursor + 1 < states.count }

    mutating func record(
        _ items: [RebaseTodoItem],
        change: RebaseTodoHistoryChange
    ) {
        guard items != current else { return }

        if cursor + 1 < states.count {
            states.removeSubrange((cursor + 1)..<states.count)
        }

        if case let .message(commitID) = change,
           lastChange == .message(commitID: commitID),
           !states.isEmpty {
            states[cursor] = items
        } else {
            states.append(items)
            cursor = states.count - 1
            if states.count > Self.maximumStateCount {
                states.removeFirst()
                cursor -= 1
            }
        }
        lastChange = change
    }

    mutating func undo() -> [RebaseTodoItem]? {
        guard canUndo else { return nil }
        cursor -= 1
        lastChange = nil
        return current
    }

    mutating func redo() -> [RebaseTodoItem]? {
        guard canRedo else { return nil }
        cursor += 1
        lastChange = nil
        return current
    }
}
func rebaseTodoActionCommand(_ action: RebaseTodoAction) -> String {
    switch action {
    case .pick: "pick"
    case .reword: "reword"
    case .edit: "edit"
    case .squash: "squash"
    case .fixup: "fixup"
    case .drop: "drop"
    }
}
func rebaseTodoContextSelection(selectedIndices: Set<Int>, row: Int) -> Set<Int> {
    selectedIndices.contains(row) ? selectedIndices : [row]
}
private struct RebaseCommandsHelpContext: Identifiable {
    let id = UUID()
    let title: String
    let items: [RebaseTodoItem]
}
/// IntelliJ's GitRebaseCommandsDialog equivalent. Keep this as a read-only
/// command reference so it cannot mutate the todo while the main editor keeps
/// ownership of selection, history, and execution state.
private struct RebaseCommandsHelpView: View {
    let title: String
    let items: [RebaseTodoItem]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
            HStack(spacing: 10) {
                Text("Action")
                    .frame(width: 90, alignment: .leading)
                Text("Commit")
                    .frame(width: 90, alignment: .leading)
                Text("Subject")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Divider()
            List(items.indices, id: \.self) { index in
                let item = items[index]
                HStack(spacing: 10) {
                    Text(rebaseTodoActionCommand(item.action))
                        .font(.system(.callout, design: .monospaced))
                        .frame(width: 90, alignment: .leading)
                    Text(String(item.commitId.prefix(10)))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)
                    Text(item.summary)
                        .lineLimit(1)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
            HStack {
                Text("Native label/reset/merge/exec/break/update-ref rows are available from Edit Native Todo…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 420)
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
enum NativeRebaseTodoLineKind: Equatable {
    case blank
    case comment
    case commit(command: String, commitID: String, subject: String)
    case control(command: String, arguments: String)
    case invalid
}
struct NativeRebaseTodoPreviewRow: Identifiable, Equatable {
    let lineNumber: Int
    let source: String
    let kind: NativeRebaseTodoLineKind

    var id: Int { lineNumber }
}
/// Parse only enough of Git's native todo syntax to make control rows
/// legible while editing. Git remains the execution authority; this preview
/// deliberately warns about unknown/malformed rows instead of rejecting a
/// command that a newer Git version may understand.
func parseNativeRebaseTodoPreview(_ text: String) -> [NativeRebaseTodoPreviewRow] {
    let commitCommands: Set<String> = [
        "pick", "p", "reword", "r", "edit", "e", "squash", "s", "fixup", "f", "drop", "d"
    ]
    let controlCommands: Set<String> = [
        "label", "reset", "merge", "exec", "break", "update-ref"
    ]

    let normalizedLines = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .components(separatedBy: "\n")

    return normalizedLines.enumerated().map { offset, source in
        let lineNumber = offset + 1
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return NativeRebaseTodoPreviewRow(lineNumber: lineNumber, source: source, kind: .blank)
        }
        if trimmed.hasPrefix("#") {
            return NativeRebaseTodoPreviewRow(lineNumber: lineNumber, source: source, kind: .comment)
        }

        let tokens = trimmed.split { character in
            character == " " || character == "\t"
        }
        guard let commandToken = tokens.first else {
            return NativeRebaseTodoPreviewRow(lineNumber: lineNumber, source: source, kind: .blank)
        }
        let command = String(commandToken).lowercased()
        if commitCommands.contains(command), tokens.count >= 2 {
            let subject = tokens.dropFirst(2).map(String.init).joined(separator: " ")
            return NativeRebaseTodoPreviewRow(
                lineNumber: lineNumber,
                source: source,
                kind: .commit(
                    command: command,
                    commitID: String(tokens[tokens.index(tokens.startIndex, offsetBy: 1)]),
                    subject: subject
                )
            )
        }
        if controlCommands.contains(command) {
            return NativeRebaseTodoPreviewRow(
                lineNumber: lineNumber,
                source: source,
                kind: .control(
                    command: command,
                    arguments: tokens.dropFirst().map(String.init).joined(separator: " ")
                )
            )
        }
        return NativeRebaseTodoPreviewRow(lineNumber: lineNumber, source: source, kind: .invalid)
    }
}
/// Update only the argument payload of one native control row. Keeping this
/// transformation line-scoped preserves comments, commit rows, unknown Git
/// syntax, and the original newline convention; Git still validates the
/// resulting todo before execution.
func updateNativeRebaseTodoControlLine(
    _ text: String,
    lineNumber: Int,
    command: String,
    arguments: String
) -> String {
    guard lineNumber > 0 else { return text }
    let newline = text.contains("\r\n") ? "\r\n" : "\n"
    var lines = text.components(separatedBy: newline)
    let index = lineNumber - 1
    guard lines.indices.contains(index) else { return text }

    let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedCommand.isEmpty else { return text }
    let indentation = lines[index].prefix { character in
        character == " " || character == "\t"
    }
    let trimmedArguments = trimmedCommand.lowercased() == "break"
        ? ""
        : arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    lines[index] = String(indentation) + trimmedCommand
        + (trimmedArguments.isEmpty ? "" : " \(trimmedArguments)")
    return lines.joined(separator: newline)
}
let nativeRebaseTodoControlCommands = [
    "label", "reset", "merge", "exec", "break", "update-ref"
]
/// Move one native control row without interpreting the surrounding todo.
/// Raw text remains the source of truth, so comments, unknown commands, and
/// Git-version-specific syntax travel with the line exactly as entered.
func moveNativeRebaseTodoControlLine(
    _ text: String,
    lineNumber: Int,
    by delta: Int
) -> String {
    guard lineNumber > 0, delta != 0 else { return text }
    let newline = text.contains("\r\n") ? "\r\n" : "\n"
    var lines = text.components(separatedBy: newline)
    let sourceIndex = lineNumber - 1
    let destinationIndex = sourceIndex + delta
    guard lines.indices.contains(sourceIndex),
          lines.indices.contains(destinationIndex),
          let sourceRow = parseNativeRebaseTodoPreview(text)
              .first(where: { $0.lineNumber == lineNumber }),
          case .control = sourceRow.kind else {
        return text
    }
    lines.swapAt(sourceIndex, destinationIndex)
    return lines.joined(separator: newline)
}
func nativeRebaseTodoControlCommand(_ text: String, lineNumber: Int) -> String? {
    guard let row = parseNativeRebaseTodoPreview(text)
        .first(where: { $0.lineNumber == lineNumber }),
        case let .control(command, _) = row.kind else { return nil }
    return command
}
func nativeRebaseTodoControlArguments(_ text: String, lineNumber: Int) -> String? {
    guard let row = parseNativeRebaseTodoPreview(text)
        .first(where: { $0.lineNumber == lineNumber }),
        case let .control(_, arguments) = row.kind else { return nil }
    return arguments
}
private struct NativeRebaseTodoPreviewView: View {
    @Binding var text: String

    private var rows: [NativeRebaseTodoPreviewRow] {
        parseNativeRebaseTodoPreview(text)
    }

    private var invalidCount: Int {
        rows.filter { $0.kind == .invalid }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Structured Preview", systemImage: "list.bullet.rectangle")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text("Git remains authoritative")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if invalidCount > 0 {
                Label(
                    String(invalidCount) + " line(s) are not recognized by this preview; Git will validate them on start.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            List(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(String(row.lineNumber))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .frame(width: 32, alignment: .trailing)
                    previewRow(row)
                }
                .listRowSeparator(.visible)
            }
            .listStyle(.inset)
        }
        .padding(.leading, 8)
    }

    @ViewBuilder
    private func previewRow(_ row: NativeRebaseTodoPreviewRow) -> some View {
        switch row.kind {
        case .blank:
            Text("blank")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .comment:
            Text(row.source.trimmingCharacters(in: .whitespaces))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case let .commit(command, commitID, subject):
            Text(command)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 64, alignment: .leading)
            Text(String(commitID.prefix(10)))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(subject.isEmpty ? "(commit message)" : subject)
                .lineLimit(1)
        case let .control(command, arguments):
            Picker(
                "control command",
                selection: Binding(
                    get: {
                        nativeRebaseTodoControlCommand(text, lineNumber: row.lineNumber)
                            ?? command
                    },
                    set: { newCommand in
                        let newArguments = newCommand == "break" ? "" : arguments
                        text = updateNativeRebaseTodoControlLine(
                            text,
                            lineNumber: row.lineNumber,
                            command: newCommand,
                            arguments: newArguments
                        )
                    }
                )
            ) {
                ForEach(nativeRebaseTodoControlCommands, id: \.self) { controlCommand in
                    Text(controlCommand).tag(controlCommand)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(.caption.monospaced().weight(.semibold))
            .frame(width: 120, alignment: .leading)

            if command == "break" {
                Text("(stop here)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                TextField(
                    "arguments",
                    text: Binding(
                        get: {
                            nativeRebaseTodoControlArguments(text, lineNumber: row.lineNumber)
                                ?? arguments
                        },
                        set: { newValue in
                            text = updateNativeRebaseTodoControlLine(
                                text,
                                lineNumber: row.lineNumber,
                                command: nativeRebaseTodoControlCommand(
                                    text,
                                    lineNumber: row.lineNumber
                                ) ?? command,
                                arguments: newValue
                            )
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity)
            }
            Button {
                text = moveNativeRebaseTodoControlLine(
                    text,
                    lineNumber: row.lineNumber,
                    by: -1
                )
            } label: {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.plain)
            .disabled(row.lineNumber == 1)
            .help("Move control row up")
            Button {
                text = moveNativeRebaseTodoControlLine(
                    text,
                    lineNumber: row.lineNumber,
                    by: 1
                )
            } label: {
                Image(systemName: "arrow.down")
            }
            .buttonStyle(.plain)
            .disabled(row.lineNumber == rows.count)
            .help("Move control row down")
        case .invalid:
            Label(row.source, systemImage: "questionmark.square")
                .font(.caption.monospaced())
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }
}
/// Text fallback for Git's native interactive-rebase todo. The editor keeps
/// comments and control rows intact, while the adjacent preview makes
/// `label/reset/merge/exec/break/update-ref` understandable without taking
/// ownership of Git's evolving native syntax.
struct RawRebaseTodoEditorView: View {
    let onto: String
    @Binding var text: String
    let preserveMerges: Bool
    let root: Bool
    let onStart: () -> Void
    let onCancel: () -> Void
    private let initialText: String
    @State private var showDiscardChangesAlert = false

    init(
        onto: String,
        text: Binding<String>,
        preserveMerges: Bool,
        root: Bool,
        onStart: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onto = onto
        self._text = text
        self.preserveMerges = preserveMerges
        self.root = root
        self.onStart = onStart
        self.onCancel = onCancel
        self.initialText = text.wrappedValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Native Git Rebase Todo")
                        .font(.title3.weight(.semibold))
                    Text(root ? "repository root" : "onto \(shortId(onto))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label("Git syntax", systemImage: "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("This is Git's complete todo file. Keep commit IDs and control rows valid; commands such as exec run with the repository's normal Git permissions.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if preserveMerges {
                Label("Merge-preserving topology is controlled by the native label/reset/merge rows.", systemImage: "arrow.triangle.merge")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HSplitView {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(minWidth: 680, minHeight: 520)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25))
                    }

                NativeRebaseTodoPreviewView(text: $text)
                    .frame(minWidth: 390, idealWidth: 460, maxWidth: .infinity)
            }
            HStack {
                Button("Cancel", role: .cancel, action: requestCancel)
                Spacer()
                Button("Start Rebase", action: onStart)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 1180, minHeight: 680)
        .alert("Discard Native Todo Changes?", isPresented: $showDiscardChangesAlert) {
            Button("Keep Editing", role: .cancel) {}
            Button("Discard Changes", role: .destructive, action: onCancel)
        } message: {
            Text("The native Git rebase todo has unsaved changes.")
        }
    }

    private func shortId(_ id: String) -> String {
        String(id.prefix(7))
    }

    private func requestCancel() {
        if text == initialText {
            onCancel()
        } else {
            showDiscardChangesAlert = true
        }
    }
}
/// SwiftUI counterpart of Git's unstructured commit-message editor request
/// during a native raw-todo rebase.
struct RawRebaseMessageEditorView: View {
    @Binding var message: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Commit Message")
                .font(.title3.weight(.semibold))
            Text("Git is waiting for the message for a reword or squash step.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $message)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 620, minHeight: 300)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25))
                }
            HStack {
                Button("Cancel Message Edit", role: .cancel, action: onCancel)
                Spacer()
                Button("Save Message", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 700, minHeight: 420)
    }
}
/// IntelliJ's multi-commit Squash action edits the final combined message
/// before starting the rewrite; it does not open the generic todo editor.
struct LogSquashDialogView: View {
    let commitSummaries: [String]
    @Binding var message: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Squash Commits")
                .font(.title3.weight(.semibold))
            Text("Edit the combined commit message. The selected commits will be replayed as one commit.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(commitSummaries.enumerated()), id: \.offset) { _, summary in
                        Text("• \(summary)")
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 86)
            .padding(8)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            TextEditor(text: $message)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 600, minHeight: 210)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Squash", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 660, minHeight: 430)
    }
}
