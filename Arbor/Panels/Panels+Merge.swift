import SwiftUI
import AppKit
import UniformTypeIdentifiers


/// GitStageTree keeps conflicts as a first-class node instead of making them
/// look like ordinary unstaged files. The row opens the same Merge Revisions
/// workbench used by merge/rebase operations and has no staging checkbox.
struct RebasedConflictGroup: View {
    let entries: [FileEntry]
    let onOpen: (String) -> Void
    @State var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                guard !entries.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.12)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: entries.isEmpty || !isExpanded ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.bold))
                    Text("Conflicts")
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(entries.count) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            if entries.isEmpty {
                Text("No files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
            } else if isExpanded {
                ForEach(entries, id: \.path) { entry in
                    Button {
                        onOpen(entry.path)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .frame(width: 16)
                            let fileURL = URL(fileURLWithPath: entry.path)
                            Text(fileURL.lastPathComponent)
                                .lineLimit(1)
                            let parentPath = fileURL.deletingLastPathComponent().path
                                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                            if !parentPath.isEmpty, parentPath != "." {
                                Text("/\(parentPath)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 4)
                            Text("Resolve")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        .padding(.leading, 20)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .help("Open Merge Revisions")
                }
            }
        }
    }

}
