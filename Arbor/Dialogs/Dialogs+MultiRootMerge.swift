import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
    let locale = AppLanguage.interfaceLocale
    guard !newName.isEmpty else {
        return localizedArborString("A branch name is required.", locale: locale)
    }
    guard newName != oldName else {
        return localizedArborString("The new name must be different.", locale: locale)
    }

    let localConflicts = localBranchNames.filter { name in
        guard name != oldName else { return false }
        return name == newName
            || name.hasPrefix(newName + "/")
            || newName.hasPrefix(name + "/")
    }
    if !localConflicts.isEmpty {
        return String(
            format: localizedArborString(
                "Branch %@ conflicts with an existing local branch.",
                locale: locale
            ),
            newName
        )
    }

    let remoteShortNames = remoteBranchNames.map { name in
        guard let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }
    if remoteShortNames.contains(newName) {
        return String(
            format: localizedArborString("Branch %@ clashes with a remote branch.", locale: locale),
            newName
        )
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
            Text("Merge \(branchName) in Git roots")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Repositories run in order. Conflicts continue to the next repository; a fatal failure stops the remaining repositories and keeps successful roots available for rollback.")
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
                Text("\(String(selectedRootPaths.count)) repositories selected")
                    .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("Strategy")
                    .foregroundStyle(.secondary)
                Text(LocalizedStringKey(strategy.title))
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
                                    LocalizedStringKey(choice.title),
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
                            LocalizedStringKey(MergeOptionChoice.commitMessage.title),
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
                            LocalizedStringKey(MergeOptionChoice.noCommit.title),
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
                            LocalizedStringKey(MergeOptionChoice.noVerify.title),
                            isOn: Binding(
                                get: { noVerify },
                                set: { setOption(.noVerify, enabled: $0) }
                            )
                        )
                        Toggle(
                            LocalizedStringKey(MergeOptionChoice.allowUnrelatedHistories.title),
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
