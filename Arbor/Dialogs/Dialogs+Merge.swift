import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
