import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RebasedStashDialog: View {
    let roots: [GitRootInfo]
    @Binding var selectedRootPath: String?
    @Binding var currentBranch: String
    @Binding var isLoadingRoot: Bool
    @Binding var message: String
    @Binding var keepIndex: Bool
    let onSelectRoot: (String) -> Void
    let onSave: () -> Void
    let onCancel: () -> Void

    private var activeRoot: GitRootInfo? {
        roots.first {
            canonicalExternalLogPath($0.path) == canonicalExternalLogPath(selectedRootPath ?? "")
        }
    }

    private var canSubmit: Bool {
        !isLoadingRoot && activeRoot != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Stash Changes").font(.title3.weight(.semibold))

            if roots.count > 1 {
                Picker("Git root", selection: Binding(
                    get: { selectedRootPath ?? roots.first?.path ?? "" },
                    set: { path in
                        guard !path.isEmpty, path != selectedRootPath else { return }
                        onSelectRoot(path)
                    }
                )) {
                    ForEach(roots, id: \.path) { root in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(root.displayName)
                            Text(root.relativePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(root.path)
                    }
                }
                .pickerStyle(.menu)
            } else if let root = roots.first {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Git root")
                        .foregroundStyle(.secondary)
                    Text(root.displayName)
                        .font(.system(.body, design: .monospaced))
                    Text(root.relativePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Current branch")
                    .foregroundStyle(.secondary)
                Text(currentBranch.isEmpty ? "HEAD" : currentBranch)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
            }

            TextField("Message (optional)", text: $message)
                .textFieldStyle(.roundedBorder)
            Toggle(isOn: $keepIndex) {
                Text("Keep index").font(.callout)
            }
            .toggleStyle(.checkbox)
            Text("Keep the currently staged content; unstaged changes go into the stash.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Stash", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
/// IntelliJ's GitUnstashAsDialog equivalent for a single stash entry.
/// Leaving the branch empty keeps the selected stash available for Apply/Pop;
/// entering a branch uses `git stash branch` and disables the other options.
struct RebasedUnstashAsDialog: View {
    let stash: StashInfo
    let currentBranch: String
    let validateBranchName: (String) -> String?
    let onApply: (Bool) -> Void
    let onPop: (Bool) -> Void
    let onStashBranch: (String) -> Void
    let onCancel: () -> Void

    @State private var branchName = ""
    @State private var popStash = false
    @State private var reinstateIndex = false

    private var normalizedBranchName: String {
        branchName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var branchValidationMessage: String? {
        guard !normalizedBranchName.isEmpty else { return nil }
        return validateBranchName(normalizedBranchName)
    }

    private var actionTitle: String {
        if !normalizedBranchName.isEmpty { return "Create Branch" }
        return popStash ? "Pop" : "Apply"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Unstash Changes")
                .font(.title3.weight(.semibold))

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Current branch")
                    .foregroundStyle(.secondary)
                Text(currentBranch.isEmpty ? "HEAD" : currentBranch)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Stash")
                    .foregroundStyle(.secondary)
                Text(stash.message.isEmpty ? "WIP" : stash.message)
                    .lineLimit(1)
                Text(stash.shortId)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField("Branch name (optional)", text: $branchName)
                    .textFieldStyle(.roundedBorder)
                if let branchValidationMessage {
                    Text(branchValidationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Toggle("Pop stash (remove after applying)", isOn: $popStash)
                .toggleStyle(.checkbox)
                .disabled(!normalizedBranchName.isEmpty)
            Toggle("Restore staged state", isOn: $reinstateIndex)
                .toggleStyle(.checkbox)
                .disabled(!normalizedBranchName.isEmpty)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button(actionTitle) {
                    if !normalizedBranchName.isEmpty {
                        onStashBranch(normalizedBranchName)
                    } else if popStash {
                        onPop(reinstateIndex)
                    } else {
                        onApply(reinstateIndex)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(branchValidationMessage != nil)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
/// IntelliJ's GitUnstashDialog equivalent for the top-level Git actions menu.
/// The Commit/Stash workspace still exposes the same row actions; this dialog
/// provides the repository-level entry point with the reference apply/pop,
/// restore-index, view, drop, clear, and stash-branch choices in one place.
struct RebasedUnstashDialog: View {
    let roots: [GitRootInfo]
    let selectedRootPath: String?
    let isLoadingRoot: Bool
    let stashes: [StashInfo]
    let currentBranch: String
    let onSelectRoot: (String) -> Void
    let validateBranchName: (String, String) -> String?
    let onApply: (String, String, Bool) -> Void
    let onPop: (String, String, Bool) -> Void
    let onStashBranch: (String, String, String) -> Void
    let onViewDiff: (String, String) -> Void
    let onDrop: (String, String) -> Void
    let onClear: (String) -> Void
    let onCancel: () -> Void

    @State private var selectedStashID: String?
    @State private var popStash = false
    @State private var reinstateIndex = false
    @State private var branchName = ""
    @State private var pendingDropRootPath: String?
    @State private var pendingDropStashID: String?
    @State private var showDropConfirmation = false
    @State private var showClearConfirmation = false

    private var selectedStash: StashInfo? {
        guard let selectedStashID else { return nil }
        return stashes.first { $0.id == selectedStashID }
    }

    private var normalizedBranchName: String {
        branchName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var branchValidationMessage: String? {
        guard !normalizedBranchName.isEmpty, let activeRootPath else { return nil }
        return validateBranchName(activeRootPath, normalizedBranchName)
    }

    private var activeRootPath: String? {
        guard let selectedRootPath, roots.isEmpty || roots.contains(where: { $0.path == selectedRootPath }) else {
            return nil
        }
        return selectedRootPath
    }

    private var canOperate: Bool {
        !isLoadingRoot && activeRootPath != nil && selectedStash != nil
    }

    private var clearStashesConfirmation: StashClearConfirmation {
        let repositoryName = activeRootPath.map {
            URL(fileURLWithPath: $0).lastPathComponent
        } ?? ""
        return stashClearConfirmation(repositoryName: repositoryName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Unstash Changes")
                .font(.title3.weight(.semibold))

            if roots.count > 1 {
                Picker("Git root", selection: Binding(
                    get: { selectedRootPath ?? roots.first?.path ?? "" },
                    set: { path in
                        guard !path.isEmpty, path != selectedRootPath else { return }
                        onSelectRoot(path)
                    }
                )) {
                    ForEach(roots, id: \.path) { root in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(root.displayName)
                            Text(root.relativePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(root.path)
                    }
                }
                .pickerStyle(.menu)
            } else if let root = roots.first {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Git root")
                        .foregroundStyle(.secondary)
                    Text(root.displayName)
                        .font(.system(.body, design: .monospaced))
                    Text(root.relativePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Current branch")
                    .foregroundStyle(.secondary)
                Text(currentBranch.isEmpty ? "HEAD" : currentBranch)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
            }

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Stashes")
                        .font(.headline)
                    if isLoadingRoot {
                        ProgressView("Loading stashes…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(.top, 8)
                    } else if stashes.isEmpty {
                        Text("No stashed changes")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(.top, 8)
                    } else {
                        List(stashes, id: \.id, selection: $selectedStashID) { stash in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(stash.message.isEmpty ? "WIP" : stash.message)
                                    .lineLimit(1)
                                Text(stash.shortId)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .tag(stash.id as String?)
                            .padding(.vertical, 2)
                        }
                        .listStyle(.inset)
                    }
                }
                .frame(minWidth: 300, idealWidth: 390, maxWidth: .infinity, minHeight: 180, maxHeight: 260)

                VStack(alignment: .leading, spacing: 8) {
                    Button("View Diff") {
                        if let activeRootPath, let selectedStash {
                            onViewDiff(activeRootPath, selectedStash.id)
                        }
                    }
                    .disabled(!canOperate)
                    Button("Drop", role: .destructive) {
                        pendingDropRootPath = activeRootPath
                        pendingDropStashID = selectedStash?.id
                        showDropConfirmation = selectedStash != nil
                    }
                    .disabled(!canOperate)
                    Divider()
                    Button("Clear All Stashes", role: .destructive) {
                        showClearConfirmation = true
                    }
                    .disabled(isLoadingRoot || activeRootPath == nil || stashes.isEmpty)
                    Spacer()
                }
                .frame(width: 150, alignment: .leading)
            }

            Divider()

            Toggle("Pop stash (remove after applying)", isOn: $popStash)
                .toggleStyle(.checkbox)
                .disabled(!normalizedBranchName.isEmpty)
            Toggle("Restore staged state", isOn: $reinstateIndex)
                .toggleStyle(.checkbox)
                .disabled(!normalizedBranchName.isEmpty)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Create branch from stash (optional)", text: $branchName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: branchName) { _, value in
                        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            popStash = true
                            reinstateIndex = true
                        } else {
                            popStash = false
                            reinstateIndex = false
                        }
                    }
                if let branchValidationMessage {
                    Text(branchValidationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Spacer()
                Button("Close", role: .cancel, action: onCancel)
                if normalizedBranchName.isEmpty {
                    Button(popStash ? "Pop" : "Apply") {
                        guard let activeRootPath, let selectedStash else { return }
                        if popStash {
                            onPop(activeRootPath, selectedStash.id, reinstateIndex)
                        } else {
                            onApply(activeRootPath, selectedStash.id, reinstateIndex)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canOperate)
                } else {
                    Button("Create Branch") {
                        guard let activeRootPath, let selectedStash else { return }
                        onStashBranch(activeRootPath, selectedStash.id, normalizedBranchName)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canOperate || branchValidationMessage != nil)
                }
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear {
            if selectedStashID == nil, let firstStash = stashes.first {
                selectedStashID = firstStash.id
            }
            if selectedRootPath == nil, let firstRoot = roots.first {
                onSelectRoot(firstRoot.path)
            }
        }
        .onChange(of: roots.map(\.path)) { _, paths in
            guard let selectedRootPath,
                  !paths.contains(selectedRootPath),
                  let firstRoot = roots.first else { return }
            onSelectRoot(firstRoot.path)
        }
        .onChange(of: stashes.map(\.id), initial: false) { _, ids in
            if let selectedStashID, ids.contains(selectedStashID) { return }
            self.selectedStashID = ids.first
        }
        .confirmationDialog(
            "Drop stash?",
            isPresented: $showDropConfirmation,
            titleVisibility: .visible
        ) {
            Button("Drop", role: .destructive) {
                if let pendingDropRootPath, let pendingDropStashID {
                    onDrop(pendingDropRootPath, pendingDropStashID)
                }
                pendingDropRootPath = nil
                pendingDropStashID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDropRootPath = nil
                pendingDropStashID = nil
            }
        } message: {
            Text("This permanently removes the selected stash from the repository.")
        }
        .confirmationDialog(
            clearStashesConfirmation.title,
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All Stashes", role: .destructive) {
                if let activeRootPath { onClear(activeRootPath) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(clearStashesConfirmation.message)
        }
    }
}
/// IntelliJ Git 的 Stash Files：只保存选中的路径，并默认把未跟踪文件
/// 纳入当前选区。它与整棵工作树的 Stash 对话框分开，避免误清理未选中的修改。
struct RebasedStashFilesDialog: View {
    @Binding var message: String
    let entries: [FileEntry]
    let initialPaths: Set<String>
    let onStash: ([String]) -> Void
    let onCancel: () -> Void
    @State private var selectedPaths: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stash Selected Files").font(.title3.weight(.semibold))
            TextField("Message (optional)", text: $message)
                .textFieldStyle(.roundedBorder)
            Text("Only selected paths are stashed. Untracked files are included; ignored files are excluded.")
                .font(.caption)
                .foregroundStyle(.secondary)
            List(entries, id: \.path) { entry in
                Toggle(isOn: Binding(
                    get: { selectedPaths.contains(entry.path) },
                    set: { checked in
                        if checked { selectedPaths.insert(entry.path) }
                        else { selectedPaths.remove(entry.path) }
                    }
                )) {
                    HStack {
                        StatusBadge(kind: entry.unstaged != .unchanged ? entry.unstaged : entry.staged)
                        Text(entry.path).lineLimit(1)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .frame(height: 260)
            HStack {
                Button("Select All") { selectedPaths = Set(entries.map(\.path)) }
                Button("Clear") { selectedPaths.removeAll() }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Stash", action: { onStash(Array(selectedPaths).sorted()) })
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedPaths.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear {
            selectedPaths = initialPaths.intersection(Set(entries.map(\.path)))
            if selectedPaths.isEmpty {
                selectedPaths = Set(entries.map(\.path))
            }
        }
    }
}
