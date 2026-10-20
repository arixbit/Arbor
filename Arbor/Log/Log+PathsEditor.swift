import SwiftUI
import AppKit
import UniformTypeIdentifiers


extension ContentView {


struct LogPathsTreeChooserView: View {
    let roots: [LogPathChooserRoot]
    @Binding var selections: Set<LogPathFilterSelection>
    let onCancel: () -> Void
    let onApply: () -> Void

    @State var expandedRoots: Set<String> = []
    @State var rootEntries: [String: [DirEntry]] = [:]
    @State var loadingRoots: Set<String> = []
    @State var rootErrors: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select Paths")
                .font(.headline)
            Text("Select files or folders from the Git roots")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(roots) { root in
                        rootSection(root)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(Design.Colors.surface, in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                Text("Selected paths: \(selections.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if selections.count >= logPathTreeSelectionLimit {
                    Text("Maximum 100 paths can be selected")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Apply", action: onApply)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selections.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 620, height: 520)
        .onAppear {
            let paths = Set(roots.map(\.path))
            expandedRoots = paths
            for root in roots {
                loadRootEntries(root)
            }
        }
    }

    @ViewBuilder
    func rootSection(_ root: LogPathChooserRoot) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expandedRoots.contains(root.path) },
                set: { expanded in
                    if expanded {
                        expandedRoots.insert(root.path)
                        loadRootEntries(root)
                    } else {
                        expandedRoots.remove(root.path)
                    }
                }
            )
        ) {
            if let error = rootErrors[root.path], (rootEntries[root.path] ?? []).isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 22)
            } else if loadingRoots.contains(root.path) && (rootEntries[root.path] ?? []).isEmpty {
                ProgressView("Loading…")
                    .controlSize(.small)
                    .padding(.leading, 22)
            } else {
                ForEach(rootEntries[root.path] ?? [], id: \.path) { entry in
                    LogPathTreeNodeView(
                        repository: root.repository,
                        rootPath: root.path,
                        entry: entry,
                        depth: 0,
                        selections: $selections
                    )
                }
            }
        } label: {
            Label(root.displayName, systemImage: "externaldrive.connected.to.line.below")
                .font(.system(size: 13, weight: .semibold))
                .help(root.path)
        }
        .onAppear { loadRootEntries(root) }
    }

    func loadRootEntries(_ root: LogPathChooserRoot) {
        guard rootEntries[root.path] == nil, !loadingRoots.contains(root.path) else { return }
        loadingRoots.insert(root.path)
        rootErrors[root.path] = nil
        Task.detached(priority: .userInitiated) {
            do {
                let entries = try root.repository.listDir(relative: "")
                await MainActor.run {
                    rootEntries[root.path] = entries
                    loadingRoots.remove(root.path)
                }
            } catch {
                await MainActor.run {
                    rootErrors[root.path] = "\(error)"
                    loadingRoots.remove(root.path)
                }
            }
        }
    }
}


struct LogPathTreeNodeView: View {
    let repository: Repository
    let rootPath: String
    let entry: DirEntry
    let depth: Int
    @Binding var selections: Set<LogPathFilterSelection>

    @State var children: [DirEntry] = []
    @State var expanded = false
    @State var loaded = false
    @State var loading = false
    @State var error: String?

    var selection: LogPathFilterSelection {
        LogPathFilterSelection(rootPath: rootPath, path: entry.path)
    }

    var selectionState: LogPathSelectionState {
        logPathTreeSelectionState(selection, in: selections)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if entry.isDir {
                    Button {
                        expanded.toggle()
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.bold))
                            .frame(width: 14)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 14, height: 14)
                }
                Toggle(
                    "",
                    isOn: Binding(
                        get: { selectionState != .clear },
                        set: { _ in
                            selections = logPathTreeSelectionsAfterToggle(
                                selection,
                                in: selections
                            )
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(selectionState == .selectedAbove)
                .help(selectionState == .selectedAbove
                    ? "A parent path is already selected"
                    : "Select this path")
                Image(systemName: entry.isDir ? (expanded ? "folder.fill" : "folder") : "doc")
                    .foregroundStyle(entry.isDir ? Design.Colors.accent : .secondary)
                Text(entry.name)
                    .font(Design.Typography.codeSmall)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 18)
            .padding(.vertical, 3)

            if entry.isDir && expanded {
                if let error, !loaded {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .padding(.leading, CGFloat(depth + 1) * 18 + 22)
                } else if loading && !loaded {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, CGFloat(depth + 1) * 18 + 22)
                } else {
                    ForEach(children, id: \.path) { child in
                        LogPathTreeNodeView(
                            repository: repository,
                            rootPath: rootPath,
                            entry: child,
                            depth: depth + 1,
                            selections: $selections
                        )
                    }
                }
            }
        }
        .onChange(of: expanded) { _, isExpanded in
            if isExpanded && !loaded {
                loadChildren()
            }
        }
    }

    func loadChildren() {
        guard !loading else { return }
        loading = true
        error = nil
        Task.detached(priority: .userInitiated) {
            do {
                let entries = try repository.listDir(relative: entry.path)
                await MainActor.run {
                    children = entries
                    loaded = true
                    loading = false
                }
            } catch {
                await MainActor.run {
                    self.error = "\(error)"
                    loading = false
                }
            }
        }
    }
}


struct LogPathsEditorView: View {
    @Binding var text: String
    let onCancel: () -> Void
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Paths")
                .font(.headline)
            Text("Enter one path per line")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Design.Colors.surface, in: RoundedRectangle(cornerRadius: 8))
                .frame(minHeight: 190)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Apply", action: onApply)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 520, height: 320)
    }
}

}
