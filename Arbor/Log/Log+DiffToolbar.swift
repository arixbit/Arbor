import SwiftUI
import AppKit

/// A toolbar row that wraps instead of clipping when the window gets narrow.
/// The reference diff toolbar keeps every action reachable at any width; a
/// plain `HStack` silently loses the right-hand controls.
struct WrappingHStack: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                widest = max(widest, x - spacing)
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        widest = max(widest, max(0, x - spacing))
        return CGSize(
            width: maxWidth.isFinite ? maxWidth : widest,
            height: y + lineHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Small toolbar controls that match the reference diff viewer's density.
struct DiffToolbarToggle: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool
    let identifier: String

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .fixedSize()
            .accessibilityIdentifier(identifier)
    }
}

struct DiffToolbarButton: View {
    let title: LocalizedStringKey
    let systemImage: String?
    let identifier: String
    var isEnabled = true
    var help: LocalizedStringKey?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .disabled(!isEnabled)
        .help(help ?? title)
        .accessibilityIdentifier(identifier)
    }
}

struct DiffToolbarChoice: View {
    let title: LocalizedStringKey
    let isSelected: Bool
    let identifier: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Design.Typography.interface(11))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(
                    isSelected ? Design.Colors.selection : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(
                            isSelected ? Design.Colors.accent.opacity(0.55) : .clear,
                            lineWidth: 1
                        )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The reference's file-properties popup.
struct LogDiffPropertiesView: View {
    let record: LogChangeRecord
    let source: LogDiffSource
    let fullFile: FullFileDiff?
    let differenceCount: Int
    var isBinary = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("File Properties")
                .font(.headline)
            row("Path", record.change.path)
            if let oldPath = record.change.oldPath, oldPath != record.change.path {
                row("Old Path", oldPath)
            }
            row("Base Revision", baseRevision)
            row("Target Revision", targetRevision)
            row("Old Mode", mode(record.change.oldMode))
            row("New Mode", mode(record.change.newMode))
            row("Old Lines", lineCount(fullFile?.oldLines))
            row("New Lines", lineCount(fullFile?.newLines))
            row("Differences", "\(differenceCount)")
            row("Binary", isBinary
                ? localizedArborString("Yes", locale: AppLanguage.interfaceLocale)
                : localizedArborString("No", locale: AppLanguage.interfaceLocale))
            if record.change.oldMode == 0o160000 || record.change.newMode == 0o160000 {
                row("Submodule", localizedArborString("Yes", locale: AppLanguage.interfaceLocale))
            }
        }
        .font(Design.Typography.interface(12))
        .padding(14)
        .frame(minWidth: 300, alignment: .leading)
    }

    private var baseRevision: String {
        switch source {
        case .commit:
            guard let index = record.parentIndex,
                  record.commit.parentIds.indices.contains(Int(index)) else { return "" }
            return String(record.commit.parentIds[Int(index)].prefix(12))
        case let .local(revision):
            return String(revision.prefix(12))
        }
    }

    private var targetRevision: String {
        switch source {
        case .commit: return record.commit.shortId
        case .local: return localizedArborString("Local", locale: AppLanguage.interfaceLocale)
        }
    }

    private func mode(_ value: UInt32) -> String {
        String(format: "%06o", value)
    }

    private func lineCount(_ lines: [String]?) -> String {
        guard let lines else { return "—" }
        return "\(lines.count)"
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}

/// Blame for the target side of a Log diff. `blamePreviousRevision` covers a
/// historical commit, `blameWorktree` covers Compare with Local.
struct LogBlameSheet: View {
    let path: String
    let revisionLabel: String
    let loader: () async throws -> [BlameLine]

    @Environment(\.dismiss) private var dismiss
    @State var lines: [BlameLine] = []
    @State var error: String?
    @State var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Blame")
                    .font(.headline)
                Text(path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(revisionLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()

            if let error {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Unable to load blame", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Design.Colors.error)
                    Text(error)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
            } else if isLoading && lines.isEmpty {
                ProgressView("Loading blame…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(lines, id: \.line) { line in
                    HStack(spacing: 8) {
                        Text(line.shortId)
                            .font(.caption.monospaced())
                            .foregroundStyle(Design.Colors.accent)
                            .frame(width: 64, alignment: .leading)
                        Text(line.author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)
                            .lineLimit(1)
                        Text(dateStr(line.time))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 120, alignment: .leading)
                        Text(String(line.line))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                        Text(line.text)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .task {
            do {
                lines = try await loader()
            } catch {
                self.error = "\(error)"
            }
            isLoading = false
        }
    }
}

/// A monospaced text sheet for clipboard comparisons and patch previews.
struct DiffTextSheet: View {
    let title: LocalizedStringKey
    let subtitle: String?
    let text: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

enum ExternalDiffLauncher {
    /// Opens the two file versions in macOS FileMerge. The reference exposes
    /// configured external tools; FileMerge is the system default here.
    static func launch(oldLines: [String], newLines: [String], path: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborExternalDiff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = URL(fileURLWithPath: path).lastPathComponent
        let oldURL = directory.appendingPathComponent("old-\(name)")
        let newURL = directory.appendingPathComponent("new-\(name)")
        try oldLines.joined(separator: "\n").write(to: oldURL, atomically: true, encoding: .utf8)
        try newLines.joined(separator: "\n").write(to: newURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/opendiff")
        process.arguments = [oldURL.path, newURL.path]
        try process.run()
    }
}

enum TextDiffRunner {
    /// Runs the system `diff -u` so clipboard comparison does not need a
    /// second in-process line-diff engine. Returns the unified patch.
    static func unifiedDiff(left: String, right: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArborTextDiff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let leftURL = directory.appendingPathComponent("clipboard.txt")
        let rightURL = directory.appendingPathComponent("target.txt")
        try left.write(to: leftURL, atomically: true, encoding: .utf8)
        try right.write(to: rightURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
        process.arguments = ["-u", leftURL.path, rightURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        if process.terminationStatus == 0 {
            return localizedArborString("No differences", locale: AppLanguage.interfaceLocale)
        }
        if process.terminationStatus > 1 {
            throw NSError(
                domain: "Arbor.TextDiff",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: output]
            )
        }
        return output
    }
}

/// A unified patch synthesized from the diff model. The engine exposes a
/// structured diff but no patch text for a single committed file.
func logFilePatchText(
    record: LogChangeRecord,
    fileDiff: FileDiff
) -> String {
    let oldPath = record.change.oldPath ?? record.change.path
    var lines: [String] = [
        "diff --git a/\(oldPath) b/\(record.change.path)",
        "--- a/\(oldPath)",
        "+++ b/\(record.change.path)",
    ]
    for hunk in fileDiff.hunks {
        lines.append(
            "@@ -\(hunk.oldStart),\(hunk.oldLines.count) +\(hunk.newStart),\(hunk.newLines.count) @@"
        )
        for row in unifiedDiffRows(hunk) {
            lines.append("\(row.prefix)\(row.line.text)")
        }
    }
    return lines.joined(separator: "\n")
}
