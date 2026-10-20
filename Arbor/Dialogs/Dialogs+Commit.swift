import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RebasedUncommitRequest: Identifiable {
    let id = UUID()
    let commit: CommitInfo
    let repositoryPath: String
    let changedPaths: [String]
    let changeLists: [ChangeListInfo]
    let headBranch: String?
}
/// IntelliJ GitUncommitAction equivalent: choose the destination Changelist
/// before the soft reset moves the selected HEAD commit's changes back into
/// the Changes Browser.
struct RebasedUncommitDialog: View {
    private enum Field: Hashable {
        case targetList
        case newTargetName
    }

    let request: RebasedUncommitRequest
    let onUncommit: (String) -> Void
    let onCancel: () -> Void
    @State private var targetName = ""
    @State private var newTargetName = ""
    @FocusState private var focusedField: Field?

    private var normalizedNewTargetName: String {
        newTargetName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var newTargetNameError: String? {
        guard !normalizedNewTargetName.isEmpty else { return nil }
        if normalizedNewTargetName.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\t" }) {
            return "Changelist names cannot contain tabs or line breaks."
        }
        return nil
    }

    private var resolvedTargetName: String {
        normalizedNewTargetName.isEmpty ? targetName : normalizedNewTargetName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Undo Latest Commit")
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(request.headBranch ?? "Detached HEAD") · \(request.commit.shortId)")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                Text(request.commit.summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Divider()
            Text("Choose the Changelist for the \(request.changedPaths.count) changes from this commit.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Picker("Target Changelist", selection: $targetName) {
                ForEach(request.changeLists, id: \.name) { list in
                    Text(list.name).tag(list.name)
                }
            }
            .pickerStyle(.menu)
            .focused($focusedField, equals: .targetList)
            .help("Choose the Changelist that will receive the changes after the soft reset.")
            HStack(spacing: 8) {
                TextField("New Changelist (optional)", text: $newTargetName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .newTargetName)
                    .help("Type a new Changelist name, or leave this empty to use the selected list.")
                if !newTargetName.isEmpty {
                    Button("Use Existing") {
                        newTargetName = ""
                        focusedField = .targetList
                    }
                    .buttonStyle(.borderless)
                    .help("Clear the new name and return to the selected Changelist.")
                }
            }
            if let newTargetNameError {
                Text(newTargetNameError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Undo Commit", action: { onUncommit(resolvedTargetName) })
                    .keyboardShortcut(.defaultAction)
                    .help("Soft reset HEAD to its first parent and keep the commit changes staged.")
                    .disabled(resolvedTargetName.isEmpty || newTargetNameError != nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            guard targetName.isEmpty else { return }
            let suggestedName = request.commit.summary
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = request.changeLists.first(where: { $0.name == suggestedName }) {
                targetName = existing.name
                focusedField = .targetList
            } else if GitChangelistSettings.createAutomatically(from: .standard), !suggestedName.isEmpty {
                newTargetName = suggestedName
                focusedField = .newTargetName
            } else {
                targetName = request.changeLists.first(where: { $0.isActive })?.name
                    ?? request.changeLists.first(where: { $0.isDefault })?.name
                    ?? request.changeLists.first?.name
                    ?? ""
                focusedField = .targetList
            }
        }
    }
}
func searchEverywhereCanSearchCommitByHash(_ query: String) -> Bool {
    let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.count >= 7 else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
        (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 65 && scalar.value <= 70)
            || (scalar.value >= 97 && scalar.value <= 102)
    }
}
func searchEverywhereCanSearchCommitByMessage(_ query: String) -> Bool {
    query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
}
func searchEverywhereCommitItems(
    roots: [SearchEverywhereGitRoot],
    query: String
) -> [SearchEverywhereItem] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard searchEverywhereCanSearchCommitByMessage(normalizedQuery) else { return [] }

    var items: [SearchEverywhereItem] = []
    if searchEverywhereCanSearchCommitByHash(normalizedQuery) {
        for root in roots {
            guard let repository = try? openRepository(path: root.rootPath),
                  let commit = try? repository.commitInfo(commitId: normalizedQuery) else {
                continue
            }
            items.append(SearchEverywhereItem(
                kind: .commitByHash,
                rootPath: root.rootPath,
                revision: commit.id,
                title: commit.summary,
                subtitle: "\(root.displayName) · \(commit.authorName)",
                shortID: commit.shortId
            ))
        }
    }

    for root in roots {
        guard let repository = try? openRepository(path: root.rootPath),
              let commits = try? repository.logWithCommand(
                  commandArgs: [
                      "--all",
                      "--grep", normalizedQuery,
                      "--regexp-ignore-case",
                      "--fixed-strings",
                  ],
                  limit: 20
              ) else {
            continue
        }
        items.append(contentsOf: commits.map { commit in
            SearchEverywhereItem(
                kind: .commitByMessage,
                rootPath: root.rootPath,
                revision: commit.id,
                title: commit.summary,
                subtitle: "\(root.displayName) · \(commit.authorName)",
                shortID: commit.shortId
            )
        })
    }
    return items
}
/// Project-level commit confirmation. IntelliJ's commit workflow makes the
/// message and affected repositories explicit; never fall back to a hidden
/// WIP message or the current window's repository.
struct MultiRootCommitDialogView: View {
    let groups: [MultiRootCommitGroup]
    let isLoading: Bool
    let error: String?
    let recentMessages: [String]
    let onTemplate: ([String]) -> Void
    let onBeforeCommitSettings: () -> Void
    let onIdentitySettings: () -> Void
    @Binding var message: String
    @Binding var amendMode: Bool
    @Binding var skipHooks: Bool
    @AppStorage(GitCommitHooksSettings.key)
    private var alwaysSkipCommitHooks = GitCommitHooksSettings.defaultValue
    @Binding var authorName: String
    @Binding var authorEmail: String
    @Binding var committerName: String
    @Binding var committerEmail: String
    @Binding var signOff: Bool
    @Binding var coAuthors: String
    /// Non-nil when the dialog was opened from Changes Browser's file
    /// selection. Nil retains the root-level Commit workflow.
    let selectedChanges: [MultiRootChangeSelection]?
    let onCommit: ([String], String) -> Void
    let onCommitAndPush: ([String], String) -> Void
    let onCommitSelectedChanges: ([MultiRootChangeSelection], String) -> Void
    let onCommitAndPushSelectedChanges: ([MultiRootChangeSelection], String) -> Void
    let onCancel: () -> Void
    @State private var selectedRootPaths: Set<String> = []
    @State private var selectedChangeIDs: Set<String> = []
    @State private var selectionInitialized = false
    @State private var showCommitOptions = false

    private var eligibleGroups: [MultiRootCommitGroup] {
        groups.filter { $0.canCommit(amend: amendMode) }
    }

    private var selectedEligibleGroups: [MultiRootCommitGroup] {
        eligibleGroups.filter { selectedRootPaths.contains($0.rootPath) }
    }

    private var selectedEligibleChanges: [MultiRootChangeSelection] {
        let eligibleRootPaths = Set(eligibleGroups.map(\.rootPath))
        return groups
            .flatMap(\.stagedEntries)
            .filter {
                eligibleRootPaths.contains($0.rootPath)
                    && selectedChangeIDs.contains($0.id)
            }
            .sorted {
                if $0.rootPath == $1.rootPath { return $0.path < $1.path }
                return $0.rootPath < $1.rootPath
            }
    }

    private var selectedEligibleChangeRootPaths: [String] {
        Array(Set(selectedEligibleChanges.map(\.rootPath))).sorted()
    }

    private var canSubmit: Bool {
        guard !isLoading, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if selectedChanges != nil {
            return !selectedEligibleChanges.isEmpty
        }
        return !selectedEligibleGroups.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle").foregroundStyle(Design.Colors.accent)
                Text("Commit Changes")
                    .font(.title2.weight(.semibold))
                Spacer()
                Toggle("Amend", isOn: $amendMode)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                if isLoading { ProgressView().controlSize(.small) }
            }

            Text(
                selectedChanges == nil
                    ? "Select the Git roots whose staged changes should be committed."
                    : "Select the staged files to commit. Files remain qualified by their Git root."
            )
                .font(.callout)
                .foregroundStyle(.secondary)

            if let error, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            if isLoading && groups.isEmpty {
                ProgressView("Loading staged changes…")
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else if groups.isEmpty {
                ContentUnavailableView(
                    "No Git Roots",
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text("No Git root is available for this commit.")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                if selectedChanges != nil {
                    List {
                        ForEach(groups) { group in
                            if !group.stagedEntries.isEmpty {
                                Section {
                                    ForEach(group.stagedEntries, id: \.id) { selection in
                                        Toggle(isOn: changeSelectionBinding(for: selection.id)) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(selection.path)
                                                    .font(.callout)
                                                if let oldPath = selection.oldPath,
                                                   oldPath != selection.path {
                                                    Text("renamed from \(oldPath)")
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                        }
                                        .toggleStyle(.checkbox)
                                        .disabled(
                                            isLoading
                                                || !group.canCommit(amend: amendMode)
                                        )
                                    }
                                } header: {
                                    HStack(spacing: 6) {
                                        Text(group.displayName)
                                            .font(.callout.weight(.medium))
                                        Text(group.relativePath)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .frame(minHeight: 180, maxHeight: 300)
                } else {
                    List {
                        ForEach(groups) { group in
                            Toggle(isOn: selectionBinding(for: group.rootPath)) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(group.displayName)
                                            .font(.callout.weight(.medium))
                                        Text(group.relativePath)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if !group.conflictedPaths.isEmpty {
                                        Text("\(group.conflictedPaths.count) conflicted file(s); resolve before committing")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    } else if group.stagedPaths.isEmpty {
                                        Text(amendMode ? "Amend current HEAD" : "No staged changes")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("\(group.stagedPaths.count) staged file(s)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(!group.canCommit(amend: amendMode) || isLoading)
                        }
                    }
                    .listStyle(.inset)
                    .frame(minHeight: 180, maxHeight: 300)
                }
            }

            DisclosureGroup("Commit options", isExpanded: $showCommitOptions) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(
                        "Skip hooks",
                        isOn: Binding(
                            get: { skipHooks || alwaysSkipCommitHooks },
                            set: { skipHooks = $0 }
                        )
                    )
                        .toggleStyle(.checkbox)
                        .disabled(alwaysSkipCommitHooks)
                    Toggle("Add Signed-off-by", isOn: $signOff)
                        .toggleStyle(.checkbox)
                    Text("Configured before-commit checks run separately for every selected root.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("Before-commit settings", action: onBeforeCommitSettings)
                        Button("Git identity", action: onIdentitySettings)
                    }
                    HStack(spacing: 8) {
                        TextField("Author name", text: $authorName)
                            .textFieldStyle(.roundedBorder)
                        TextField("Author email", text: $authorEmail)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack(spacing: 8) {
                        TextField("Committer name", text: $committerName)
                            .textFieldStyle(.roundedBorder)
                        TextField("Committer email", text: $committerEmail)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("Co-authors (one Name <email> per line)")
                        .font(.caption.weight(.medium))
                    TextEditor(text: $coAuthors)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 46)
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.secondary.opacity(0.25))
                        }
                }
                .padding(.top, 6)
            }

            HStack(spacing: 8) {
                Text("Commit message")
                    .font(.callout.weight(.medium))
                Spacer()
                Button("Template") {
                    let roots: [String]
                    if selectedChanges != nil {
                        roots = selectedEligibleChangeRootPaths.isEmpty
                            ? eligibleGroups.map(\.rootPath)
                            : selectedEligibleChangeRootPaths
                    } else {
                        roots = selectedRootPaths.isEmpty
                            ? eligibleGroups.map(\.rootPath)
                            : Array(selectedRootPaths)
                    }
                    onTemplate(roots.sorted())
                }
                Menu {
                    if recentMessages.isEmpty {
                        Text("No recent commit messages")
                    } else {
                        ForEach(recentMessages, id: \.self) { recentMessage in
                            Button(recentMessage) { message = recentMessage }
                        }
                    }
                } label: {
                    Image(systemName: "clock")
                }
                .menuStyle(.borderlessButton)
                .help("Recent commit messages")
            }
            TextEditor(text: $message)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 90, maxHeight: 150)
                .padding(6)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.35))
                }

            HStack {
                Text(
                    selectedChanges == nil
                        ? "\(selectedEligibleGroups.count) root(s) selected"
                        : "\(selectedEligibleChanges.count) file(s) selected"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button(
                    selectedChanges == nil
                        ? (amendMode ? "Amend Selected" : "Commit Selected")
                        : (amendMode ? "Amend Selected Files" : "Commit Selected Files")
                ) {
                    let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    if selectedChanges != nil {
                        guard !selectedEligibleChanges.isEmpty else { return }
                        onCommitSelectedChanges(selectedEligibleChanges, text)
                    } else {
                        let selected = selectedEligibleGroups.map(\.rootPath).sorted()
                        guard !selected.isEmpty else { return }
                        onCommit(selected, text)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
                Button(
                    selectedChanges == nil
                        ? (amendMode ? "Amend and Push Selected" : "Commit and Push Selected")
                        : (amendMode
                            ? "Amend and Push Selected Files"
                            : "Commit and Push Selected Files")
                ) {
                    let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    if selectedChanges != nil {
                        guard !selectedEligibleChanges.isEmpty else { return }
                        onCommitAndPushSelectedChanges(selectedEligibleChanges, text)
                    } else {
                        let selected = selectedEligibleGroups.map(\.rootPath).sorted()
                        guard !selected.isEmpty else { return }
                        onCommitAndPush(selected, text)
                    }
                }
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(minWidth: 700, minHeight: 700)
        .onAppear { initializeSelection() }
        .onChange(of: groups.map { group in
            "\(group.rootPath)|\(group.stagedEntries.map(\.id).joined(separator: ","))|\(group.conflictedPaths.count)"
        }) { _, _ in
            initializeSelection()
        }
        .onChange(of: amendMode) { _, _ in
            initializeSelection()
        }
        .onChange(of: selectedChanges?.map(\.id) ?? []) { _, _ in
            selectionInitialized = false
            initializeSelection()
        }
    }

    private func selectionBinding(for rootPath: String) -> Binding<Bool> {
        Binding(
            get: { selectedRootPaths.contains(rootPath) },
            set: { selected in
                if selected {
                    selectedRootPaths.insert(rootPath)
                } else {
                    selectedRootPaths.remove(rootPath)
                }
            }
        )
    }

    private func changeSelectionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selectedChangeIDs.contains(id) },
            set: { selected in
                if selected {
                    selectedChangeIDs.insert(id)
                } else {
                    selectedChangeIDs.remove(id)
                }
            }
        )
    }

    private func initializeSelection() {
        guard !groups.isEmpty else { return }
        if let selectedChanges {
            let eligible = Set(groups.flatMap(\.stagedEntries).map(\.id))
            if !selectionInitialized {
                selectedChangeIDs = Set(selectedChanges.map(\.id)).intersection(eligible)
                selectionInitialized = true
            } else {
                selectedChangeIDs.formIntersection(eligible)
            }
        } else {
            let eligible = Set(eligibleGroups.map(\.rootPath))
            if !selectionInitialized {
                selectedRootPaths = eligible
                selectionInitialized = true
            } else {
                selectedRootPaths.formIntersection(eligible)
            }
        }
    }
}
