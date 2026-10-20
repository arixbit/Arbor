import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RebasedShelveDialog: View {
    @Binding var name: String
    var repo: Repository? = nil
    let entries: [FileEntry]
    let onShelve: ([String], Bool, Bool) -> Void
    let onCancel: () -> Void
    @State private var selectedPaths: Set<String> = []
    @State private var previewPath: String?
    @State private var showPreview = false
    @State private var includeUntracked = false
    @State private var includeIgnored = false

    private var eligibleEntries: [FileEntry] {
        entries.filter { entry in
            if entry.unstaged == .ignored { return includeIgnored }
            if entry.unstaged == .untracked { return includeUntracked }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shelve Changes").font(.title3.weight(.semibold))
            TextField("Shelf name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 10) {
                Text("Files selected: \(selectedPaths.count)/\(eligibleEntries.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(showPreview ? "Hide Diff" : "Review Diff") {
                    showPreview.toggle()
                    if showPreview, previewPath == nil {
                        previewPath = eligibleEntries.first(where: { selectedPaths.contains($0.path) })?.path
                    }
                }
                .disabled(repo == nil || selectedPaths.isEmpty)
            }
            if showPreview, let repo {
                HSplitView {
                    List(eligibleEntries, id: \.path, selection: $previewPath) { entry in
                        Text(entry.path).lineLimit(1).tag(entry.path)
                    }
                    .frame(minWidth: 190, idealWidth: 240)
                    if let previewPath,
                       let entry = eligibleEntries.first(where: { $0.path == previewPath }) {
                        DiffDetailView(
                            repo: repo,
                            entry: entry,
                            onChanged: {},
                            selectionModePath: nil
                        )
                    } else {
                        ContentUnavailableView("Select a file", systemImage: "doc.text")
                    }
                }
                .frame(height: 280)
            } else {
                List(eligibleEntries, id: \.path) { entry in
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
                .frame(height: 220)
            }
            HStack(spacing: 16) {
                Toggle("Include untracked files", isOn: $includeUntracked)
                    .toggleStyle(.checkbox)
                Toggle("Include ignored files", isOn: $includeIgnored)
                    .toggleStyle(.checkbox)
            }
            HStack {
                Button("Select All") { selectedPaths = Set(eligibleEntries.map(\.path)) }
                Button("Clear") { selectedPaths.removeAll(); previewPath = nil }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Shelve", action: {
                    onShelve(Array(selectedPaths), includeUntracked, includeIgnored)
                })
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedPaths.isEmpty)
            }
        }
        .padding(20)
        .frame(width: showPreview ? 860 : 560)
        .onAppear {
            if selectedPaths.isEmpty { selectedPaths = Set(eligibleEntries.map(\.path)) }
        }
        .onChange(of: includeUntracked) { _, enabled in
            let paths = Set(entries.filter { $0.unstaged == .untracked }.map(\.path))
            if enabled { selectedPaths.formUnion(paths) }
            else { selectedPaths.subtract(paths) }
            if let previewPath, !eligibleEntries.contains(where: { $0.path == previewPath }) {
                self.previewPath = nil
            }
        }
        .onChange(of: includeIgnored) { _, enabled in
            let paths = Set(entries.filter { $0.unstaged == .ignored }.map(\.path))
            if enabled { selectedPaths.formUnion(paths) }
            else { selectedPaths.subtract(paths) }
            if let previewPath, !eligibleEntries.contains(where: { $0.path == previewPath }) {
                self.previewPath = nil
            }
        }
    }
}
