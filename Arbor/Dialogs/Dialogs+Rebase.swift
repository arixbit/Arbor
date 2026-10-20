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
