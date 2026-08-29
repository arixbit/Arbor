import SwiftUI

func revisionBrowserInitialLocation(for path: String) -> (directory: String, file: String)? {
    let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !normalized.isEmpty else { return nil }
    let components = normalized.split(separator: "/")
    return (
        directory: components.dropLast().joined(separator: "/"),
        file: normalized
    )
}

/// Read-only repository browser for a historical revision. It deliberately
/// does not check out the revision or touch the worktree.
struct RevisionBrowserView: View {
    let repo: Repository
    let revision: String
    let commitTitle: String
    let initialPath: String?

    @Environment(\.dismiss) private var dismiss
    @State private var relativePath = ""
    @State private var entries: [RevisionEntry] = []
    @State private var selectedPath: String?
    @State private var content: FileContent?
    @State private var error: String?
    @State private var loadingDirectory = false
    @State private var loadingFile = false
    @State private var directoryTask: Task<Void, Never>?
    @State private var fileTask: Task<Void, Never>?
    @AppStorage(GitRevisionContentSettings.key)
    private var revisionContentModeRaw = GitRevisionContentSettings.defaultValue

    private var revisionContentMode: GitRevisionContentMode {
        GitRevisionContentMode(rawValue: revisionContentModeRaw) ?? .filters
    }

    private var parentPath: String? {
        guard !relativePath.isEmpty else { return nil }
        let components = relativePath.split(separator: "/")
        guard components.count > 1 else { return "" }
        return components.dropLast().joined(separator: "/")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(Design.Colors.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Browse Repository at Revision")
                        .font(.headline)
                    Text("\(commitTitle) · \(revision)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding(12)
            Divider()

            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Button {
                            if let parentPath {
                                relativePath = parentPath
                                selectedPath = nil
                                content = nil
                            }
                        } label: {
                            Label("Up", systemImage: "arrowshape.turn.up.left")
                        }
                        .disabled(parentPath == nil || loadingDirectory)
                        Text(relativePath.isEmpty ? "/" : "/\(relativePath)")
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if loadingDirectory {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    Divider()

                    if let error, entries.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text(error)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(16)
                    } else {
                        List {
                            ForEach(entries, id: \.path) { entry in
                                Button {
                                    if entry.isDir {
                                        relativePath = entry.path
                                        selectedPath = nil
                                        content = nil
                                    } else {
                                        selectedPath = entry.path
                                        loadFile(entry.path)
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: entry.isDir ? "folder" : "doc.text")
                                            .foregroundStyle(entry.isDir ? .blue : .secondary)
                                            .frame(width: 18)
                                        Text(entry.name)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                        if !entry.isDir {
                                            Text("file")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(
                                    selectedPath == entry.path
                                        ? Color.accentColor.opacity(0.14)
                                        : Color.clear
                                )
                            }
                        }
                        .listStyle(.inset)
                    }
                }
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)

                revisionContent
                    .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .onAppear {
            prepareInitialSelection()
            loadDirectory()
        }
        .onChange(of: relativePath) { _, _ in loadDirectory() }
        .onChange(of: revisionContentModeRaw) { _, _ in
            if let selectedPath {
                loadFile(selectedPath)
            }
        }
        .onDisappear {
            directoryTask?.cancel()
            fileTask?.cancel()
        }
    }

    @ViewBuilder
    private var revisionContent: some View {
        if let error, selectedPath != nil {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(error)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
        } else if loadingFile {
            ProgressView("Reading revision…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let content, let selectedPath {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: content.binary ? "doc.zipper" : "doc.text")
                        .foregroundStyle(Design.Colors.accent)
                    Text(selectedPath)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if content.truncated {
                        Label("Truncated", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(10)
                Divider()
                if content.binary {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.zipper")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("Binary file cannot be previewed as text")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView([.vertical, .horizontal]) {
                        Text(content.text)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(12)
                    }
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Select a file to inspect this revision")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadDirectory() {
        directoryTask?.cancel()
        loadingDirectory = true
        error = nil
        let requestedPath = relativePath
        directoryTask = Task.detached(priority: .userInitiated) {
            do {
                let result = try repo.listRevisionDir(revision: revision, relative: requestedPath)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    entries = result
                    loadingDirectory = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.error = String(describing: error)
                    entries = []
                    loadingDirectory = false
                }
            }
        }
    }

    private func prepareInitialSelection() {
        guard let initialPath,
              let location = revisionBrowserInitialLocation(for: initialPath) else { return }
        relativePath = location.directory
        selectedPath = location.file
        loadFile(location.file)
    }

    private func loadFile(_ path: String) {
        fileTask?.cancel()
        loadingFile = true
        content = nil
        error = nil
        let transformMode = revisionContentMode.engineValue
        fileTask = Task.detached(priority: .userInitiated) {
            do {
                let result = try repo.readRevisionFileWithMode(
                    revision: revision,
                    path: path,
                    mode: transformMode
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    content = result
                    loadingFile = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.error = String(describing: error)
                    loadingFile = false
                }
            }
        }
    }
}
