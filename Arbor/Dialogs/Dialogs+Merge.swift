import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// FindMergedLocalBranchesAction is useful only when at least one repository
/// has a candidate local branch in addition to the target branch.
func isFindMergedBranchesActionEnabled(localBranchCounts: [Int]) -> Bool {
    localBranchCounts.contains { $0 > 1 }
}
/// The branch dialog validates local ref conflicts before GitBrancher runs.
/// Keep the conflict portion pure so single-root and multi-root rename flows
/// cannot drift apart while repository I/O remains at their call sites.
func branchRenameConflictMessage(
    oldName: String,
    newName: String,
    localBranchNames: [String],
    remoteBranchNames: [String]
) -> String? {
    let oldName = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
    let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !newName.isEmpty else { return "A branch name is required." }
    guard newName != oldName else { return "The new name must be different." }

    let localConflicts = localBranchNames.filter { name in
        guard name != oldName else { return false }
        return name == newName
            || name.hasPrefix(newName + "/")
            || newName.hasPrefix(name + "/")
    }
    if !localConflicts.isEmpty {
        return "Branch \(newName) conflicts with an existing local branch."
    }

    let remoteShortNames = remoteBranchNames.map { name in
        guard let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }
    if remoteShortNames.contains(newName) {
        return "Branch \(newName) clashes with a remote branch."
    }
    return nil
}
/// Cross-root merge selection follows IntelliJ's repository operation model:
/// only roots that actually contain the local target branch are offered.
struct RebasedMultiRootMergeDialog: View {
    let branchName: String
    @Binding var selectedRootPaths: Set<String>
    @Binding var strategy: MergeStrategyChoice
    @Binding var commitMessage: String
    @Binding var useCustomCommitMessage: Bool
    @Binding var noCommit: Bool
    @Binding var noVerify: Bool
    @Binding var allowUnrelatedHistories: Bool
    let snapshots: [GitRootBranchSnapshot]
    let mergedBranchesByRoot: [String: Set<String>]
    let onMerge: () -> Void
    let onCancel: () -> Void

    private var eligibleSnapshots: [GitRootBranchSnapshot] {
        snapshots
            .filter { snapshot in
                snapshot.branches.contains { $0.name == branchName }
            }
            .sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
    }

    private var allSelected: Bool {
        !mergeableSnapshots.isEmpty
            && mergeableSnapshots.allSatisfy { selectedRootPaths.contains($0.rootPath) }
    }

    private var mergeableSnapshots: [GitRootBranchSnapshot] {
        eligibleSnapshots.filter { !branchIsAlreadyMerged(in: $0) }
    }

    private func branchIsAlreadyMerged(in snapshot: GitRootBranchSnapshot) -> Bool {
        guard let mergedBranches = mergedBranchesByRoot[snapshot.rootPath] else { return false }
        return mergeBranchIsAlreadyMerged(branchName, mergedBranches: mergedBranches)
    }

    private var selectedOptions: Set<MergeOptionChoice> {
        var options = Set<MergeOptionChoice>()
        if useCustomCommitMessage { options.insert(.commitMessage) }
        if noCommit { options.insert(.noCommit) }
        if noVerify { options.insert(.noVerify) }
        if allowUnrelatedHistories { options.insert(.allowUnrelatedHistories) }
        return options
    }

    private func normalizeOptions() {
        if !mergeOptionIsEnabled(
            .commitMessage,
            strategy: strategy,
            selectedOptions: selectedOptions
        ) {
            useCustomCommitMessage = false
            commitMessage = ""
        }
        if !mergeOptionIsEnabled(
            .noCommit,
            strategy: strategy,
            selectedOptions: selectedOptions
        ) {
            noCommit = false
        }
    }

    private func setOption(_ option: MergeOptionChoice, enabled: Bool) {
        guard enabled || mergeOptionIsEnabled(
            option,
            strategy: strategy,
            selectedOptions: selectedOptions
        ) else { return }
        switch option {
        case .commitMessage:
            useCustomCommitMessage = enabled
            if !enabled { commitMessage = "" }
        case .noCommit:
            noCommit = enabled
        case .noVerify:
            noVerify = enabled
        case .allowUnrelatedHistories:
            allowUnrelatedHistories = enabled
        }
    }

    private func selectionBinding(for path: String) -> Binding<Bool> {
        Binding(
            get: { selectedRootPaths.contains(path) },
            set: { isSelected in
                if isSelected {
                    selectedRootPaths.insert(path)
                } else {
                    selectedRootPaths.remove(path)
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Merge Branch")
                .font(.title3.weight(.semibold))
            Text(
                String(localized: "Merge %@ in Git roots")
                    .replacingOccurrences(of: "%@", with: branchName)
            )
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(
                String(localized: "Repositories run in order. Conflicts continue to the next repository; a fatal failure stops the remaining repositories and keeps successful roots available for rollback.")
            )
                .font(.caption)
                .foregroundStyle(.orange)
            Divider()
            Toggle(
                "All eligible repositories",
                isOn: Binding(
                    get: { allSelected },
                    set: { isSelected in
                        selectedRootPaths = isSelected ? Set(mergeableSnapshots.map(\.rootPath)) : []
                    }
                )
            )
            .toggleStyle(.checkbox)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(eligibleSnapshots, id: \.rootPath) { snapshot in
                        let alreadyMerged = branchIsAlreadyMerged(in: snapshot)
                        Toggle(isOn: selectionBinding(for: snapshot.rootPath)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(snapshot.displayName)
                                Text(snapshot.relativePath)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if alreadyMerged {
                                    Text("Already merged into current branch")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(alreadyMerged)
                    }
                }
            }
            .frame(maxHeight: 180)
            if eligibleSnapshots.isEmpty {
                Text("No repository contains this local branch.")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if mergeableSnapshots.isEmpty {
                Text("This branch is already merged in every eligible repository.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if selectedRootPaths.isEmpty {
                Text("Select at least one repository")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text(
                    String(localized: "%@ repositories selected")
                        .replacingOccurrences(of: "%@", with: String(selectedRootPaths.count))
                )
                    .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("Strategy")
                    .foregroundStyle(.secondary)
                Text(strategy.title)
                Spacer()
                Menu("Modify options…") {
                    Section("Merge strategy") {
                        ForEach(MergeStrategyChoice.allCases) { choice in
                            Button {
                                guard mergeStrategyIsEnabled(
                                    choice,
                                    selectedOptions: selectedOptions
                                ) else { return }
                                strategy = choice
                                normalizeOptions()
                            } label: {
                                Label(
                                    choice.title,
                                    systemImage: strategy == choice ? "checkmark" : ""
                                )
                            }
                            .disabled(!mergeStrategyIsEnabled(
                                choice,
                                selectedOptions: selectedOptions
                            ))
                        }
                    }
                    Section("Merge options") {
                        Toggle(
                            MergeOptionChoice.commitMessage.title,
                            isOn: Binding(
                                get: { useCustomCommitMessage },
                                set: { setOption(.commitMessage, enabled: $0) }
                            )
                        )
                        .disabled(!mergeOptionIsEnabled(
                            .commitMessage,
                            strategy: strategy,
                            selectedOptions: selectedOptions
                        ))
                        Toggle(
                            MergeOptionChoice.noCommit.title,
                            isOn: Binding(
                                get: { noCommit },
                                set: { setOption(.noCommit, enabled: $0) }
                            )
                        )
                        .disabled(!mergeOptionIsEnabled(
                            .noCommit,
                            strategy: strategy,
                            selectedOptions: selectedOptions
                        ))
                        Toggle(
                            MergeOptionChoice.noVerify.title,
                            isOn: Binding(
                                get: { noVerify },
                                set: { setOption(.noVerify, enabled: $0) }
                            )
                        )
                        Toggle(
                            MergeOptionChoice.allowUnrelatedHistories.title,
                            isOn: Binding(
                                get: { allowUnrelatedHistories },
                                set: { setOption(.allowUnrelatedHistories, enabled: $0) }
                            )
                        )
                    }
                }
                .menuStyle(.borderlessButton)
            }
            if useCustomCommitMessage {
                TextField("Commit message", text: $commitMessage)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Merge", action: onMerge)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        selectedRootPaths.isEmpty
                            || mergeableSnapshots.isEmpty
                            || !selectedRootPaths.contains(where: { path in
                                mergeableSnapshots.contains { $0.rootPath == path }
                            })
                    )
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear(perform: normalizeOptions)
    }
}
/// Recovery choice shown when a cross-root merge has both completed roots and
/// a later fatal failure. It keeps rollback explicit and guarded by each root's
/// expected HEAD in the operation layer.
struct RebasedMultiRootMergeRollbackView: View {
    let branchName: String
    let targets: [MultiRootMergeRollbackTarget]
    let failures: [String]
    let onRollback: () -> Void
    let onKeep: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Multi-root Merge Partially Completed")
                .font(.title3.weight(.semibold))
            Text(
                String(localized: "Merge %@ completed in some repositories, but the operation could not finish everywhere.")
                    .replacingOccurrences(of: "%@", with: branchName)
            )
                .font(.caption)
                .foregroundStyle(.secondary)
            if !targets.isEmpty {
                Text("Successful repositories")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(targets) { target in
                        HStack(spacing: 7) {
                            Image(systemName: target.operationPending ? "exclamationmark.triangle" : "checkmark.circle")
                                .foregroundStyle(target.operationPending ? .orange : .green)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(target.displayName)
                                Text(
                                    "HEAD \(String(target.initialHead.prefix(7))) → \(String(target.expectedHead.prefix(7)))"
                                )
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if target.operationPending {
                                Text("needs resolution")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            if !failures.isEmpty {
                Text("Failed or skipped repositories")
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
enum MergeStrategyChoice: String, CaseIterable, Codable, Identifiable {
    case automatic
    case fastForwardOnly
    case noFastForward
    case squash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic (fast-forward when possible)"
        case .fastForwardOnly: return "Fast-forward only"
        case .noFastForward: return "No fast-forward (create merge commit)"
        case .squash: return "Squash (single-parent commit)"
        }
    }
}
enum MergeOptionChoice: String, CaseIterable, Hashable, Identifiable {
    case commitMessage
    case noCommit
    case noVerify
    case allowUnrelatedHistories

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commitMessage: return "Use custom commit message"
        case .noCommit: return "Do not commit automatically"
        case .noVerify: return "Skip hooks"
        case .allowUnrelatedHistories: return "Allow unrelated histories"
        }
    }
}
/// Mirrors GitMergeOption.isOptionSuitable from the reference implementation.
/// Strategy choices are the mutually exclusive --no-ff/--ff-only/--squash
/// options; the remaining options are the popup's independent choices.
func mergeOptionIsEnabled(
    _ option: MergeOptionChoice,
    strategy: MergeStrategyChoice,
    selectedOptions: Set<MergeOptionChoice>
) -> Bool {
    switch option {
    case .commitMessage:
        return strategy != .fastForwardOnly
            && strategy != .squash
            && !selectedOptions.contains(.noCommit)
    case .noCommit:
        return !selectedOptions.contains(.commitMessage)
    case .noVerify, .allowUnrelatedHistories:
        return true
    }
}
func mergeStrategyIsEnabled(
    _ strategy: MergeStrategyChoice,
    selectedOptions: Set<MergeOptionChoice>
) -> Bool {
    switch strategy {
    case .automatic, .noFastForward:
        return true
    case .fastForwardOnly, .squash:
        return !selectedOptions.contains(.commitMessage)
    }
}
func mergeEngineMode(for strategy: MergeStrategyChoice) -> MergeMode {
    switch strategy {
    case .automatic: return .fastForward
    case .fastForwardOnly: return .fastForwardOnly
    case .noFastForward: return .noFastForward
    case .squash: return .squash
    }
}
func mergeBranchIsAlreadyMerged(_ value: String, mergedBranches: Set<String>) -> Bool {
    let branch = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !branch.isEmpty else { return false }
    if mergedBranches.contains(branch) { return true }
    if branch.hasPrefix("refs/heads/") {
        return mergedBranches.contains(String(branch.dropFirst("refs/heads/".count)))
    }
    if branch.hasPrefix("refs/remotes/") {
        return mergedBranches.contains(String(branch.dropFirst("refs/remotes/".count)))
    }
    return false
}
struct RebasedMergeDialog: View {
    @Binding var branch: String
    @Binding var strategy: MergeStrategyChoice
    @Binding var commitMessage: String
    @Binding var useCustomCommitMessage: Bool
    @Binding var noCommit: Bool
    @Binding var noVerify: Bool
    @Binding var allowUnrelatedHistories: Bool
    let branches: [BranchInfo]
    let mergedBranches: Set<String>
    let onMerge: () -> Void
    let onCancel: () -> Void

    private var branchAlreadyMerged: Bool {
        mergeBranchIsAlreadyMerged(branch, mergedBranches: mergedBranches)
    }

    private var selectedOptions: Set<MergeOptionChoice> {
        var options = Set<MergeOptionChoice>()
        if useCustomCommitMessage { options.insert(.commitMessage) }
        if noCommit { options.insert(.noCommit) }
        if noVerify { options.insert(.noVerify) }
        if allowUnrelatedHistories { options.insert(.allowUnrelatedHistories) }
        return options
    }

    private func normalizeOptions() {
        if !mergeOptionIsEnabled(
            .commitMessage,
            strategy: strategy,
            selectedOptions: selectedOptions
        ) {
            useCustomCommitMessage = false
            commitMessage = ""
        }
        if !mergeOptionIsEnabled(
            .noCommit,
            strategy: strategy,
            selectedOptions: selectedOptions
        ) {
            noCommit = false
        }
    }

    private func setOption(_ option: MergeOptionChoice, enabled: Bool) {
        guard enabled || mergeOptionIsEnabled(
            option,
            strategy: strategy,
            selectedOptions: selectedOptions
        ) else { return }
        switch option {
        case .commitMessage:
            useCustomCommitMessage = enabled
            if !enabled { commitMessage = "" }
        case .noCommit:
            noCommit = enabled
        case .noVerify:
            noVerify = enabled
        case .allowUnrelatedHistories:
            allowUnrelatedHistories = enabled
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Merge Revisions").font(.title3.weight(.semibold))
            Text("Select a branch or revision to merge into the current branch.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("Revision")
                    .foregroundStyle(.secondary)
                TextField("branch or revision", text: $branch)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    ForEach(branches.filter { !$0.isCurrent }, id: \.name) { item in
                        Button(item.name) { branch = item.name }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
            }
            if branchAlreadyMerged {
                Label(
                    "This branch is already merged into the current branch.",
                    systemImage: "checkmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                Text("Strategy")
                    .foregroundStyle(.secondary)
                Text(strategy.title)
                Spacer()
                Menu("Modify options…") {
                    Section("Merge strategy") {
                        ForEach(MergeStrategyChoice.allCases) { choice in
                            Button {
                                guard mergeStrategyIsEnabled(
                                    choice,
                                    selectedOptions: selectedOptions
                                ) else { return }
                                strategy = choice
                                normalizeOptions()
                            } label: {
                                Label(
                                    choice.title,
                                    systemImage: strategy == choice ? "checkmark" : ""
                                )
                            }
                            .disabled(!mergeStrategyIsEnabled(
                                choice,
                                selectedOptions: selectedOptions
                            ))
                        }
                    }
                    Section("Merge options") {
                        Toggle(
                            MergeOptionChoice.commitMessage.title,
                            isOn: Binding(
                                get: { useCustomCommitMessage },
                                set: { setOption(.commitMessage, enabled: $0) }
                            )
                        )
                        .disabled(!mergeOptionIsEnabled(
                            .commitMessage,
                            strategy: strategy,
                            selectedOptions: selectedOptions
                        ))
                        Toggle(
                            MergeOptionChoice.noCommit.title,
                            isOn: Binding(
                                get: { noCommit },
                                set: { setOption(.noCommit, enabled: $0) }
                            )
                        )
                        .disabled(!mergeOptionIsEnabled(
                            .noCommit,
                            strategy: strategy,
                            selectedOptions: selectedOptions
                        ))
                        Toggle(
                            MergeOptionChoice.noVerify.title,
                            isOn: Binding(
                                get: { noVerify },
                                set: { setOption(.noVerify, enabled: $0) }
                            )
                        )
                        Toggle(
                            MergeOptionChoice.allowUnrelatedHistories.title,
                            isOn: Binding(
                                get: { allowUnrelatedHistories },
                                set: { setOption(.allowUnrelatedHistories, enabled: $0) }
                            )
                        )
                    }
                }
                .menuStyle(.borderlessButton)
            }
            if useCustomCommitMessage {
                TextField("Commit message", text: $commitMessage)
                    .textFieldStyle(.roundedBorder)
            }
            Text(strategy == .squash
                 ? "The merged tree will be staged and finished as a single-parent commit."
                 : "The selected strategy is applied before conflict resolution and merge completion.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Merge", action: onMerge)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || branchAlreadyMerged
                    )
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: normalizeOptions)
    }
}
/// IntelliJ GitConflictsView 的批量动作只作用于当前冲突选择，且保持稳定路径顺序。
func conflictPathsForSelection(_ selection: Set<String>, paths: [String]) -> [String] {
    paths.filter(selection.contains).sorted()
}
/// 对话框化的 Merge Revisions 三栏页面。左侧文件清单，右侧是
/// Local │ Result │ Remote 三栏编辑器；解析文件后仍由父视图刷新状态。
struct MergeRevisionsDialogView: View {
    enum Mode {
        case merge
        case rebase
        case cherryPick
        case revert
        case stashRestore
        case shelveRestore(isPop: Bool)
        case applyPatch

        var title: String {
            switch self {
            case .merge: "Merge Revisions"
            case .rebase: "Rebase — Resolve Conflicts"
            case .cherryPick: "Cherry-pick — Resolve Conflicts"
            case .revert: "Revert — Resolve Conflicts"
            case .stashRestore: "Stash — Resolve Conflicts"
            case .shelveRestore: "Shelve — Resolve Conflicts"
            case .applyPatch: "Apply Patch — Resolve Conflicts"
            }
        }

        var primaryTitle: String {
            switch self {
            case .merge: "Complete Merge"
            case .rebase: "Continue Rebase"
            case .cherryPick: "Continue Cherry-pick"
            case .revert: "Continue Revert"
            case .stashRestore: "Complete Stash Apply"
            case .shelveRestore(let isPop): isPop ? "Complete Shelve Pop" : "Complete Unshelve"
            case .applyPatch: "Complete Apply Patch"
            }
        }

        var abortTitle: String {
            switch self {
            case .shelveRestore(let isPop):
                return isPop ? "Rollback Shelve Pop" : "Rollback Unshelve"
            case .applyPatch:
                return "Rollback Apply Patch"
            default:
                return "Abort"
            }
        }

        var isApplyPatch: Bool {
            if case .applyPatch = self { return true }
            return false
        }
    }

    let repo: Repository
    @Binding var entries: [FileEntry]
    let initialPath: String?
    let mode: Mode
    let directPatchText: String?
    let directPatchRestoreName: String?
    let onChanged: () -> Void
    let onComplete: () -> Void
    let onAbort: (() -> Void)?
    let onSkip: (() -> Void)?
    /// Non-modal resolver panels use a smaller minimum size so the main
    /// workspace remains visible beside the conflict queue.
    let compact: Bool

    init(
        repo: Repository,
        entries: Binding<[FileEntry]>,
        initialPath: String?,
        mode: Mode,
        directPatchText: String? = nil,
        directPatchRestoreName: String? = nil,
        onChanged: @escaping () -> Void,
        onComplete: @escaping () -> Void,
        onAbort: (() -> Void)?,
        onSkip: (() -> Void)?,
        compact: Bool = false
    ) {
        self.repo = repo
        self._entries = entries
        self.initialPath = initialPath
        self.mode = mode
        self.directPatchText = directPatchText
        self.directPatchRestoreName = directPatchRestoreName
        self.onChanged = onChanged
        self.onComplete = onComplete
        self.onAbort = onAbort
        self.onSkip = onSkip
        self.compact = compact
    }

    @State private var selectedPath: String?
    @State private var selectedPaths: Set<String> = []
    @State private var resolvedPaths: [String] = []
    @State private var binaryPaths: Set<String> = []
    @State private var batchWorking = false
    @State private var pendingRevertPath: String?
    @State private var revertingPath: String?
    @State private var actionError: String?

    private var conflictPaths: [String] {
        entries
            .filter { $0.staged == .conflicted || $0.unstaged == .conflicted }
            .map(\.path)
            .sorted()
    }

    private var selectedConflictPaths: [String] {
        conflictPathsForSelection(selectedPaths, paths: conflictPaths)
    }

    var body: some View {
        VStack(spacing: 0) {
            conflictToolbar
            Divider()
            if let actionError {
                Text(actionError)
                    .font(.caption)
                    .foregroundStyle(.red)
        .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }

            conflictWorkspace
        }
        .frame(minWidth: compact ? 920 : 1120, minHeight: compact ? 540 : 700)
        .onAppear {
            loadWorkspaceState()
        }
        .onChange(of: conflictPaths) { _, paths in
            selectAvailablePath(preferred: selectedPath, conflictPaths: paths, resolvedPaths: resolvedPaths)
        }
        .onChange(of: resolvedPaths) { _, paths in
            selectAvailablePath(preferred: selectedPath, conflictPaths: conflictPaths, resolvedPaths: paths)
        }
        .onChange(of: selectedPaths) { _, paths in
            let available = Set(conflictPaths).union(resolvedPaths)
            let valid = paths.intersection(available)
            if valid != paths {
                selectedPaths = valid
            }
            if let selectedPath, valid.contains(selectedPath) {
                return
            }
            self.selectedPath = valid.sorted().first
        }
        .alert("Revert resolved file?", isPresented: Binding(
            get: { pendingRevertPath != nil },
            set: { if !$0 { pendingRevertPath = nil } }
        )) {
            Button("Revert", role: .destructive) {
                guard let path = pendingRevertPath else { return }
                pendingRevertPath = nil
                revertResolved(path)
            }
            Button("Cancel", role: .cancel) { pendingRevertPath = nil }
        } message: {
            Text("The file will return to the unresolved conflict list.")
        }
    }

    private var conflictToolbar: AnyView {
        let selectedPathsForBatch = selectedConflictPaths
        let patchMode = mode.isApplyPatch
        return AnyView(HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.merge")
                .foregroundStyle(.orange)
            Text(mode.title)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Text("\(conflictPaths.count) conflicted files")
                .font(.caption)
                .foregroundStyle(conflictPaths.isEmpty ? .green : .secondary)
            if !resolvedPaths.isEmpty {
                Text("\(resolvedPaths.count) resolved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !selectedPathsForBatch.isEmpty {
                Text("\(selectedPathsForBatch.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(patchMode ? "Keep Local" : "Accept Ours") { acceptSelectedConflicts(.ours) }
                    .disabled(batchWorking)
                Button(patchMode ? "Apply Patch" : "Accept Theirs") { acceptSelectedConflicts(.theirs) }
                    .disabled(batchWorking)
            }
            if let onAbort {
                Button(mode.abortTitle, role: .destructive, action: onAbort)
            }
            if let onSkip {
                Button("Skip", action: onSkip)
                    .disabled(!conflictPaths.isEmpty)
            }
            Button(mode.primaryTitle, action: onComplete)
                .buttonStyle(.borderedProminent)
                .disabled(!conflictPaths.isEmpty)
        }
        .padding(12))
    }

    private var conflictWorkspace: AnyView {
        AnyView(HStack(spacing: 0) {
            conflictPathList
            Divider()
            conflictDetail
        })
    }

    private var conflictPathList: AnyView {
        AnyView(VStack(alignment: .leading, spacing: 0) {
            if conflictPaths.isEmpty && resolvedPaths.isEmpty {
                Text("All conflicts resolved")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .padding(12)
            } else {
                List(selection: $selectedPaths) {
                    if !conflictPaths.isEmpty {
                        Section("CONFLICTS") {
                            ForEach(conflictPaths, id: \.self) { path in
                                conflictPathRow(path)
                            }
                        }
                    }
                    if !resolvedPaths.isEmpty {
                        Section("RESOLVED") {
                            ForEach(resolvedPaths, id: \.self) { path in
                                resolvedPathRow(path)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            Spacer()
        }
        .frame(width: 230))
    }

    private var conflictDetail: AnyView {
        if let selectedPath, conflictPaths.contains(selectedPath) {
            return AnyView(ConflictDetailView(
                repo: repo,
                path: selectedPath,
                patchText: directPatchText,
                restoreName: directPatchRestoreName,
                onChanged: {
                    onChanged()
                    loadWorkspaceState()
                }
            ))
        }
        if let selectedPath, resolvedPaths.contains(selectedPath) {
            return AnyView(ResolvedConflictFileView(
                path: selectedPath,
                isWorking: revertingPath == selectedPath,
                error: actionError,
                onRevert: { pendingRevertPath = selectedPath }
            ))
        }
        return AnyView(VStack(spacing: 10) {
            Image(systemName: "arrow.left.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Select a conflicted file")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity))
    }

    private func resolvedPathRow(_ path: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
            Text(path)
                .lineLimit(1)
        }
        .tag(path)
    }

    @ViewBuilder
    private func conflictPathRow(_ path: String) -> some View {
        let isBinary = binaryPaths.contains(path)
        HStack(spacing: 6) {
            Image(systemName: isBinary
                  ? "doc.badge.gearshape"
                  : "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Text(path)
                .lineLimit(1)
            if isBinary {
                Text("Binary")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .tag(path)
    }

    private func selectAvailablePath(
        preferred: String?,
        conflictPaths: [String],
        resolvedPaths: [String]
    ) {
        let available = Set(conflictPaths).union(resolvedPaths)
        selectedPaths = selectedPaths.intersection(available)
        if let preferred, available.contains(preferred), selectedPaths.isEmpty {
            selectedPath = preferred
            selectedPaths = [preferred]
            return
        }
        if let selectedPath, available.contains(selectedPath), selectedPaths.contains(selectedPath) {
            return
        }
        selectedPath = initialPath.flatMap { available.contains($0) ? $0 : nil }
            ?? conflictPaths.first
            ?? resolvedPaths.first
        if let selectedPath {
            selectedPaths = [selectedPath]
        }
    }

    private func loadWorkspaceState() {
        Task.detached(priority: .userInitiated) {
            do {
                let workspace = try repo.conflictWorkspace()
                await MainActor.run {
                    self.resolvedPaths = workspace.resolvedFiles
                    self.binaryPaths = Set(workspace.files.filter(\.binary).map(\.path))
                    self.selectAvailablePath(
                        preferred: self.selectedPath,
                        conflictPaths: self.conflictPaths,
                        resolvedPaths: workspace.resolvedFiles
                    )
                }
            } catch {
                await MainActor.run {
                    self.binaryPaths.removeAll()
                    self.actionError = "\(error)"
                }
            }
        }
    }

    private func acceptSelectedConflicts(_ pick: FilePick) {
        guard !batchWorking else { return }
        let paths = selectedConflictPaths
        guard !paths.isEmpty else { return }
        batchWorking = true
        actionError = nil
        Task.detached(priority: .userInitiated) {
            var accepted: [String] = []
            var failure: String?
            for path in paths {
                do {
                    try repo.acceptConflict(path: path, pick: pick)
                    accepted.append(path)
                } catch {
                    failure = "\(path): \(error)"
                    break
                }
            }
            let acceptedPaths = accepted
            let failureMessage = failure
            await MainActor.run {
                self.batchWorking = false
                self.selectedPaths.subtract(acceptedPaths)
                if let failureMessage {
                    self.actionError = "部分冲突已解决；\(failureMessage)"
                }
                self.onChanged()
                self.loadWorkspaceState()
            }
        }
    }

    private func revertResolved(_ path: String) {
        guard revertingPath == nil else { return }
        revertingPath = path
        actionError = nil
        Task.detached(priority: .userInitiated) {
            do {
                try repo.revertResolvedConflict(path: path)
                await MainActor.run {
                    self.revertingPath = nil
                    self.selectedPath = path
                    self.onChanged()
                    self.loadWorkspaceState()
                }
            } catch {
                await MainActor.run {
                    self.revertingPath = nil
                    self.actionError = "\(error)"
                }
            }
        }
    }
}
private struct ResolvedConflictFileView: View {
    let path: String
    let isWorking: Bool
    let error: String?
    let onRevert: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.green)
            Text("Resolved: \(path)")
                .font(.headline)
            Text("This file is resolved in the current Git operation. Revert the resolution to reopen the three-way conflict editor.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(isWorking ? "Reverting…" : "Revert Resolved") {
                onRevert()
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking)
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
/// IntelliJ 的 FindMergedLocalBranchesAction：只读扫描各 Git root，按目标分支
/// 和名称前缀列出已合并的本地分支，并保留仓库边界。
struct FindMergedBranchesDialogView: View {
    let roots: [BranchCleanupRoot]
    let projectName: String
    @Binding var targetBranch: String
    @Binding var prefix: String
    let isRunning: Bool
    let hasCalculated: Bool
    let summary: FindMergedScanSummary?
    let onCalculate: () -> Void
    let onOpenReport: () -> Void
    let onCopy: () -> Void
    let onDone: () -> Void
    let onCancel: () -> Void

    private var normalizedTarget: String {
        targetBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedPrefix: String {
        prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasMatchingCalculation: Bool {
        summary?.targetBranch == normalizedTarget && summary?.prefix == normalizedPrefix
    }

    private var reportText: String? {
        guard let summary, hasMatchingCalculation else { return nil }
        return findMergedBranchesReportText(
            summary: summary,
            roots: roots,
            projectName: projectName
        )
    }

    private var mergedBranchCount: Int {
        roots.reduce(0) { count, root in
            count + mergedBranches(in: root).count
        }
    }

    private func mergedBranches(in root: BranchCleanupRoot) -> [BranchInfo] {
        mergedBranchNames(
            in: root,
            targetBranch: normalizedTarget,
            prefix: normalizedPrefix
        ).compactMap { name in root.branches.first { $0.name == name } }
    }

    private func rootStatus(for root: BranchCleanupRoot) -> String? {
        guard hasCalculated, root.calculatedTarget == nil else { return nil }
        let title = String(localized: "Calculation unavailable in this repository")
        guard let error = root.calculationError, !error.isEmpty else { return title }
        return "\(title): \(error)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Find Merged Local Branches")
                    .font(.title3.weight(.semibold))
                Spacer()
                if isRunning {
                    Button("Cancel", role: .cancel, action: onCancel)
                } else {
                    Button("Done", role: .cancel, action: onDone)
                }
            }

            HStack(spacing: 10) {
                Text("Target branch")
                TextField("Target branch", text: $targetBranch)
                    .textFieldStyle(.roundedBorder)
                Text("Filter prefix")
                TextField("Filter prefix", text: $prefix)
                    .textFieldStyle(.roundedBorder)
                Button("Find", action: onCalculate)
                    .disabled(normalizedTarget.isEmpty || isRunning)
            }

            HStack(spacing: 8) {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text("Finding merged branches…")
                        .foregroundStyle(.secondary)
                } else if hasMatchingCalculation {
                    Text(
                        String(localized: "%@ merged branches found")
                            .replacingOccurrences(of: "%@", with: String(mergedBranchCount))
                    )
                        .foregroundStyle(.secondary)
                } else if hasCalculated {
                    Text("Run Find after changing the target or prefix")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if reportText != nil {
                    Button("Open Report", action: onOpenReport)
                }
                Button("Copy", action: onCopy)
                    .disabled(!hasMatchingCalculation || isRunning)
            }

            if roots.isEmpty {
                if isRunning {
                    ProgressView("Loading repositories…")
                } else if hasCalculated {
                    Text("No repository results are available for this target")
                        .foregroundStyle(.secondary)
                } else {
                    Text("No repositories loaded")
                        .foregroundStyle(.secondary)
                }
            } else {
                List {
                    ForEach(roots) { root in
                        Section {
                        let branches = mergedBranches(in: root)
                            if !hasCalculated {
                                Text("Run Find to calculate merged branches")
                                    .foregroundStyle(.secondary)
                            } else if root.calculatedTarget != normalizedTarget
                                        || root.calculatedPrefix != normalizedPrefix {
                                Text("Run Find after changing the target or prefix")
                                    .foregroundStyle(.secondary)
                            } else if let status = rootStatus(for: root) {
                                Text(status)
                                    .foregroundStyle(.secondary)
                            } else if branches.isEmpty {
                                Text("No merged branches")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(branches, id: \.name) { branch in
                                    HStack(spacing: 8) {
                                        Image(systemName: "checkmark.branch")
                                            .foregroundStyle(.green)
                                        Text(branch.name)
                                            .font(.system(.body, design: .monospaced))
                                        Spacer()
                                        Text(branch.shortId)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.tertiary)
                                    }
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
            }
        }
        .padding(16)
        .frame(minWidth: 820, minHeight: 520)
    }
}
/// IntelliJ opens FindMergedLocalBranches results as a standalone plain-text
/// editor. Keep the document independent from the grouped scan dialog so it
/// can be inspected, selected, edited, or copied after the dialog changes.
struct FindMergedReportEditorView: View {
    let report: String
    @Environment(\.dismiss) private var dismiss
    @State private var document: String

    init(report: String) {
        self.report = report
        _document = State(initialValue: report)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .foregroundStyle(Design.Colors.accent)
                Text("Merged Branches Report")
                    .font(.headline)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(document, forType: .string)
                }
                Button("Done", role: .cancel) {
                    dismiss()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            TextEditor(text: $document)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}
/// Returns stable branch rows for a completed calculation. A root with an
/// error intentionally produces no rows, so a partial result cannot be read
/// as a successful empty result.
func mergedBranchNames(
    in root: BranchCleanupRoot,
    targetBranch: String,
    prefix: String
) -> [String] {
    guard root.calculatedTarget == targetBranch,
          root.calculatedPrefix == prefix else {
        return []
    }
    return root.branches
        .filter {
            $0.name != targetBranch
                && root.mergedBranches.contains($0.name)
                && (prefix.isEmpty || $0.name.hasPrefix(prefix))
        }
        .map(\.name)
        .sorted()
}
/// Builds the plain-text result document used by Find Merged Local Branches.
/// Raw root errors remain visible instead of being reduced to an empty list.
func findMergedBranchesReportText(
    summary: FindMergedScanSummary,
    roots: [BranchCleanupRoot],
    projectName: String
) -> String {
    var lines = [
        "=== Merged local branches into '\(summary.targetBranch)' ==="
    ]
    if !summary.prefix.isEmpty {
        lines.append("Filter prefix: '\(summary.prefix)'")
    }
    if !projectName.isEmpty {
        lines.append("Project: \(projectName)")
    }
    lines.append("")

    var found = 0
    for root in roots.sorted(by: { $0.relativePath < $1.relativePath }) {
        lines.append("Root: \(root.rootPath)")
        if let error = root.calculationError, !error.isEmpty {
            lines.append("  Error: \(error)")
        } else {
            let branches = mergedBranchNames(
                in: root,
                targetBranch: summary.targetBranch,
                prefix: summary.prefix
            )
            found += branches.count
            if branches.isEmpty {
                lines.append("  No merged branches found.")
            } else {
                lines.append(contentsOf: branches.map { "  \($0)" })
            }
        }
        lines.append("")
    }

    lines.append("Summary:")
    lines.append("  Status: \(summary.isCancelled ? "Cancelled" : "Completed")")
    lines.append("  Repositories discovered: \(summary.repositoriesDiscovered)")
    lines.append("  Repositories scanned: \(summary.repositoriesScanned)")
    lines.append("  Candidate branches checked: \(summary.candidateBranchesChecked)")
    lines.append("  Merged branches found: \(found)")
    lines.append("  Errors count: \(summary.errorsCount)")
    lines.append("  Total search time: \(summary.elapsedMilliseconds) ms")
    return lines.joined(separator: "\n") + "\n"
}
/// 项目级冲突 resolver 的一个待处理 root。一个 root 可能来自 Git
/// operation、普通 unmerged files，或 Update Project stash 恢复冲突。
enum MultiRootConflictResolverKind {
    case operation(OperationKind)
    case workingTree
    case stash(stashID: String?, index: Int, isPop: Bool)
    case shelve(name: String, isPop: Bool)
}
struct MultiRootConflictResolverRoot: Identifiable {
    let rootPath: String
    let displayName: String
    let relativePath: String
    let paths: [String]
    let kind: MultiRootConflictResolverKind

    var id: String { rootPath }

    var operation: OperationKind? {
        guard case let .operation(kind) = kind else { return nil }
        return kind
    }

    var isStash: Bool {
        if case .stash = kind { return true }
        return false
    }

    var isShelf: Bool {
        if case .shelve = kind { return true }
        return false
    }

    var canSkip: Bool {
        operation == .rebase
    }
}
func stableMultiRootConflictResolverRoots(
    _ roots: [MultiRootConflictResolverRoot]
) -> [MultiRootConflictResolverRoot] {
    roots.sorted { $0.rootPath < $1.rootPath }
}
/// IntelliJ GitConflictResolver 的项目级 SwiftUI 外壳：左侧保持所有
/// Git root 的待处理队列，右侧复用当前 root 的三栏冲突编辑器。
struct MultiRootConflictResolverView: View {
    let roots: [MultiRootConflictResolverRoot]
    let activeRootPath: String?
    let activeRepo: Repository?
    @Binding var entries: [FileEntry]
    let initialPath: String?
    let activeKind: MultiRootConflictResolverKind?
    let isWorking: Bool
    let error: String?
    let onSelectRoot: (String) -> Void
    let onChanged: () -> Void
    let onComplete: () -> Void
    let onSkip: () -> Void
    let onAbort: () -> Void
    let onClose: () -> Void
    /// Compact mode is used by the non-modal project conflict panel.
    let compact: Bool

    private var activeMode: MergeRevisionsDialogView.Mode {
        switch activeKind {
        case .operation(.rebase): return .rebase
        case .operation(.cherryPick): return .cherryPick
        case .operation(.revert): return .revert
        case .operation(.merge): return .merge
        case .stash: return .stashRestore
        case .shelve(_, let isPop): return .shelveRestore(isPop: isPop)
        case .workingTree, nil: return .merge
        }
    }

    private var activeRoot: MultiRootConflictResolverRoot? {
        roots.first(where: { $0.rootPath == activeRootPath })
    }

    private var activeOperation: OperationKind? {
        activeRoot?.operation
    }

    private var allowsAbort: Bool {
        if activeOperation != nil { return true }
        if case .shelve = activeKind { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if !compact {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.merge")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Git Roots Conflicts")
                                .font(.headline)
                            Text("\(roots.count) root\(roots.count == 1 ? "" : "s") pending")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Close", action: onClose)
                            .controlSize(.small)
                    }
                    .padding(12)
                    Divider()
                }

                List {
                    ForEach(roots) { root in
                        Button {
                            onSelectRoot(root.rootPath)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Image(systemName: root.isStash || root.isShelf
                                          ? "archivebox.fill"
                                          : "exclamationmark.triangle.fill")
                                        .foregroundStyle(root.isStash || root.isShelf ? .purple : .orange)
                                    Text(root.displayName)
                                        .font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    if root.canSkip {
                                        Text("Skip")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text(root.relativePath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                HStack(spacing: 6) {
                                    Text(root.isStash
                                         ? "Stash restore"
                                         : root.isShelf
                                         ? "Shelf restore"
                                         : operationLabel(root.operation))
                                    Text("·")
                                    Text("\(root.paths.count) conflicted file\(root.paths.count == 1 ? "" : "s")")
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .listRowBackground(
                            root.rootPath == activeRootPath
                                ? Color.accentColor.opacity(0.16)
                                : Color.clear
                        )
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(width: compact ? 230 : 290)

            Divider()

            VStack(spacing: 0) {
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                if let activeRepo {
                    MergeRevisionsDialogView(
                        repo: activeRepo,
                        entries: $entries,
                        initialPath: initialPath,
                        mode: activeMode,
                        onChanged: onChanged,
                        onComplete: onComplete,
                        onAbort: allowsAbort ? onAbort : nil,
                        onSkip: activeOperation == .rebase ? onSkip : nil,
                        compact: compact
                    )
                    .disabled(isWorking)
                } else if isWorking {
                    ProgressView("Loading Git root…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.circle")
                            .font(.title)
                            .foregroundStyle(.green)
                        Text("All Git roots are resolved")
                            .font(.headline)
                        Button("Close", action: onClose)
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: compact ? 980 : 1420, minHeight: compact ? 620 : 760)
    }

    private func operationLabel(_ operation: OperationKind?) -> String {
        switch operation {
        case .merge: return "Merge"
        case .rebase: return "Rebase"
        case .cherryPick: return "Cherry-pick"
        case .revert: return "Revert"
        case nil: return "Unmerged files"
        }
    }
}
/// 多 root 冲突恢复的聚合索引；详情仍在对应 root 的 Repository 上执行。
struct MultiRootConflictGroup: Identifiable, Hashable {
    let rootPath: String
    let displayName: String
    let relativePath: String
    let operation: OperationKind?
    let paths: [String]

    var id: String { rootPath }
}
/// 项目级冲突树中的叶节点。rootPath 参与 identity，避免不同 Git root 的同名文件串到一起。
struct MultiRootConflictTarget: Identifiable, Hashable {
    let rootPath: String
    let path: String

    var id: String { "\(rootPath)\u{0}\(path)" }
}
func multiRootConflictTargets(from groups: [MultiRootConflictGroup]) -> [MultiRootConflictTarget] {
    groups
        .sorted { $0.rootPath < $1.rootPath }
        .flatMap { group in
            group.paths.sorted().map { path in
                MultiRootConflictTarget(rootPath: group.rootPath, path: path)
            }
    }
}
