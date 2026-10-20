import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
