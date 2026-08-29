import SwiftUI
import AppKit

/// Shows the two-layer model of a submodule change: the superproject owns the
/// old/new gitlink ids, while the initialized nested root owns the commit range.
struct SubmoduleChangeView: View {
    let repo: Repository
    let revision1: String
    let revision2: String
    let path: String
    let onClose: () -> Void

    @State private var change: SubmoduleChange?
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var loadTask: Task<Void, Never>?
    @State private var nestedDiff: FileDiff?
    @State private var nestedDiffError: String?
    @State private var nestedDiffPath: String?
    @State private var nestedDiffOldRevision: String?
    @State private var nestedDiffNewRevision: String?
    @State private var nestedDiffLoading = false
    @State private var showNestedDiff = false
    @State private var nestedDiffTask: Task<Void, Never>?
    @State private var nestedDiffGeneration = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Submodule Changes")
                        .font(.title2.weight(.semibold))
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Close", action: onClose)
            }

            if let loadError, !loadError.isEmpty {
                Label("Unable to load Submodule Changes", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Design.Colors.error)
                Text(loadError)
                    .font(.caption)
                    .textSelection(.enabled)
                Button("Retry") { load() }
                    .buttonStyle(.bordered)
            } else if isLoading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let change {
                changeSummary(change)
            } else {
                ContentUnavailableView {
                    Label("No Submodule Changes", systemImage: "square.stack.3d.up")
                }
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 520)
        .background(Design.Colors.canvas)
        .task { load() }
        .onDisappear {
            loadTask?.cancel()
            nestedDiffTask?.cancel()
            nestedDiffGeneration &+= 1
        }
        .sheet(isPresented: $showNestedDiff) {
            SubmoduleNestedFileDiffView(
                path: nestedDiffPath ?? "",
                oldRevision: nestedDiffOldRevision,
                newRevision: nestedDiffNewRevision,
                fileDiff: nestedDiff,
                error: nestedDiffError,
                isLoading: nestedDiffLoading,
                onRetry: {
                    guard let change, let nestedDiffPath else { return }
                    loadNestedDiff(for: change, filePath: nestedDiffPath)
                },
                onClose: { showNestedDiff = false }
            )
        }
    }

    @ViewBuilder
    private func changeSummary(_ change: SubmoduleChange) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                revisionRow("Old gitlink", value: change.oldCommit)
                revisionRow("New gitlink", value: change.newCommit)
                revisionRow("Current checkout", value: change.currentCommit)
                statusRow("Initialized", value: change.initialized ? "Yes" : "No")
                statusRow("Local changes", value: change.dirty ? "dirty" : "clean")
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

            Divider()

            if change.initialized {
                HStack {
                    Label("Nested commits", systemImage: "clock")
                        .font(.headline)
                    Spacer()
                    Text("\(change.commits.count)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if change.commits.isEmpty {
                    ContentUnavailableView {
                        Label("No nested commits available", systemImage: "arrow.left.arrow.right")
                    } description: {
                        Text("The gitlink ids are equal, or the nested objects are not available locally.")
                    }
                } else {
                    List(change.commits, id: \.id) { commit in
                        commitRow(commit)
                    }
                    .listStyle(.inset)
                }

                if !change.nestedChanges.isEmpty {
                    Divider()
                    HStack {
                        Label("Nested file changes", systemImage: "doc.on.doc")
                            .font(.headline)
                        Spacer()
                        Text("\(change.nestedChanges.count)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    List(Array(change.nestedChanges.enumerated()), id: \.offset) { _, fileChange in
                        Button {
                            loadNestedDiff(for: change, filePath: fileChange.path)
                        } label: {
                            HStack(spacing: 8) {
                                Text(fileChange.kind.displayTitle)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(fileChangeKindColor(fileChange.kind))
                                    .frame(width: 84, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(fileChange.path)
                                        .font(.caption.monospaced())
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if let oldPath = fileChange.oldPath {
                                        Text("← \(oldPath)")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "doc.text.magnifyingglass")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open nested file diff")
                    }
                    .listStyle(.inset)
                    .frame(minHeight: 100)
                }
            } else {
                Label("Submodule is not initialized", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Initialize the submodule to inspect its commit range.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func revisionRow(_ title: LocalizedStringKey, value: String?) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value ?? "Not available")
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }

    private func statusRow(_ title: LocalizedStringKey, value: LocalizedStringKey) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
        }
    }

    private func commitRow(_ commit: CommitInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(commit.summary)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                Spacer()
                Text(commit.shortId)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(commit.authorName.isEmpty ? "Not available" : commit.authorName)
                Text(Date(timeIntervalSince1970: TimeInterval(commit.time)), style: .date)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.id, forType: .string)
            }
        }
    }

    private func fileChangeKindColor(_ kind: TreeChangeKind) -> Color {
        switch kind {
        case .added: return .green
        case .modified: return .secondary
        case .deleted: return .red
        case .renamed: return .blue
        }
    }

    private func load() {
        loadTask?.cancel()
        nestedDiffTask?.cancel()
        nestedDiffGeneration &+= 1
        change = nil
        loadError = nil
        isLoading = true
        let repo = repo
        let revision1 = revision1
        let revision2 = revision2
        let path = path
        loadTask = Task.detached(priority: .userInitiated) {
            do {
                let change = try repo.submoduleChange(
                    rev1: revision1,
                    rev2: revision2,
                    path: path,
                    limit: 200
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.change = change
                    self.isLoading = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.loadError = "\(error)"
                    self.isLoading = false
                }
            }
        }
    }

    private func loadNestedDiff(for change: SubmoduleChange, filePath: String) {
        nestedDiffTask?.cancel()
        nestedDiffGeneration &+= 1
        let generation = nestedDiffGeneration
        nestedDiff = nil
        nestedDiffError = nil
        nestedDiffPath = filePath
        nestedDiffOldRevision = change.oldCommit
        nestedDiffNewRevision = change.newCommit
        nestedDiffLoading = true
        showNestedDiff = true

        guard let workdir = repo.workdir() else {
            nestedDiffError = "The parent repository has no worktree."
            nestedDiffLoading = false
            return
        }
        let nestedRoot = URL(fileURLWithPath: workdir)
            .appendingPathComponent(path, isDirectory: true)
            .standardizedFileURL
            .path
        guard let nestedRepo = try? openRepository(path: nestedRoot) else {
            nestedDiffError = "The submodule is not initialized or cannot be opened."
            nestedDiffLoading = false
            return
        }

        let oldRevision = change.oldCommit ?? ""
        let newRevision = change.newCommit ?? ""
        let oldPath = change.nestedChanges.first(where: { $0.path == filePath })?.oldPath ?? filePath
        let newPath = filePath
        nestedDiffTask = Task.detached(priority: .userInitiated) {
            do {
                let diff = try nestedRepo.diffCommitsWithPathsWithSettings(
                    rev1: oldRevision,
                    path1: oldPath,
                    rev2: newRevision,
                    path2: newPath,
                    settings: makeArborGitDiffSettings()
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.nestedDiffGeneration == generation,
                          self.nestedDiffPath == filePath else { return }
                    self.nestedDiff = diff
                    self.nestedDiffError = nil
                    self.nestedDiffLoading = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.nestedDiffGeneration == generation,
                          self.nestedDiffPath == filePath else { return }
                    self.nestedDiffError = "\(error)"
                    self.nestedDiffLoading = false
                }
            }
        }
    }
}

private struct SubmoduleNestedFileDiffView: View {
    let path: String
    let oldRevision: String?
    let newRevision: String?
    let fileDiff: FileDiff?
    let error: String?
    let isLoading: Bool
    let onRetry: () -> Void
    let onClose: () -> Void

    @State private var presentationMode: DiffPresentationMode = .sideBySide

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nested File Diff")
                        .font(.title2.weight(.semibold))
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Picker("Diff View", selection: $presentationMode) {
                    ForEach(DiffPresentationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                Button("Close", action: onClose)
            }
            .padding(16)

            HStack(spacing: 12) {
                Text("Old: \(oldRevision.map { String($0.prefix(12)) } ?? "empty tree")")
                Text("New: \(newRevision.map { String($0.prefix(12)) } ?? "empty tree")")
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            Divider()

            if let error {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Unable to load nested diff", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Design.Colors.error)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button("Retry", action: onRetry)
                        .buttonStyle(.bordered)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if isLoading {
                ProgressView("Loading nested diff…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let fileDiff {
                if fileDiff.binary {
                    Text("Binary file — diff preview unavailable")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if fileDiff.hunks.isEmpty {
                    Text("No content changes")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if presentationMode == .unified {
                    UnifiedDiffView(fileDiff: fileDiff)
                } else {
                    SideBySideDiffView(fileDiff: fileDiff)
                }
            } else {
                Text("Select a nested file to view its diff")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(Design.Colors.canvas)
    }
}
