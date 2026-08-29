import SwiftUI
import AppKit

enum CodeLineChange: Equatable {
    case added
    case modified
    case deleted

    var color: Color {
        switch self {
        case .added: Design.Colors.success
        case .modified: Design.Colors.info
        case .deleted: Design.Colors.error
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .added: String(localized: "Added line")
        case .modified: String(localized: "Modified line")
        case .deleted: String(localized: "Deleted line")
        }
    }
}

enum FileContentVersion: String, CaseIterable, Equatable {
    case local
    case staged

    var title: String {
        switch self {
        case .local: "Local Version"
        case .staged: "Staged Version"
        }
    }
}

/// Prevents an older asynchronous version read from replacing a newer path,
/// version, or refresh result.
func isCurrentFileContentRequest(
    path: String,
    version: FileContentVersion,
    generation: Int,
    currentPath: String?,
    currentVersion: FileContentVersion,
    currentGeneration: Int
) -> Bool {
    path == currentPath && version == currentVersion && generation == currentGeneration
}

/// Builds the version switcher from the same presence-aware staging actions
/// used by the Changes Browser. When the model has versions, only expose
/// versions that are actually present. An empty model keeps the current value
/// as a transient fallback while status refresh is catching up.
func fileContentVersions(
    for actions: [StagingVersionAction],
    current: FileContentVersion?
) -> [FileContentVersion] {
    var versions: [FileContentVersion] = []
    for action in actions {
        let version: FileContentVersion = action == .local ? .local : .staged
        if !versions.contains(version) { versions.append(version) }
    }
    if versions.isEmpty, let current {
        return [current]
    }
    return versions
}

func resolvedFileContentVersion(
    current: FileContentVersion,
    available: [FileContentVersion]
) -> FileContentVersion? {
    guard !available.isEmpty else { return nil }
    return available.contains(current) ? current : available[0]
}

/// Map the existing Worktree↔HEAD diff into the current file's line gutter.
/// A replacement hunk is represented as modified on its new lines; a pure
/// deletion is anchored at the first surviving line after the deletion.
func codeLineChanges(for diff: FileDiff, lineCount: Int) -> [Int: CodeLineChange] {
    guard !diff.binary else { return [:] }

    var changes: [Int: CodeLineChange] = [:]

    func rank(_ change: CodeLineChange) -> Int {
        switch change {
        case .deleted: 1
        case .added: 2
        case .modified: 3
        }
    }

    func merge(_ change: CodeLineChange, at line: Int) {
        let line = max(1, line)
        if let existing = changes[line], rank(existing) >= rank(change) { return }
        changes[line] = change
    }

    for hunk in diff.hunks {
        let additions = hunk.newLines.filter { $0.kind == .addition && $0.newLine > 0 }
        let hasDeletions = hunk.oldLines.contains { $0.kind == .deletion }
        if !additions.isEmpty {
            let change: CodeLineChange = hasDeletions ? .modified : .added
            for line in additions {
                merge(change, at: Int(line.newLine))
            }
        } else if hasDeletions {
            let anchor = min(max(1, Int(hunk.newStart)), max(1, lineCount))
            merge(.deleted, at: anchor)
        }
    }
    return changes
}

/// 只读工作区文件查看器：行号 + tree-sitter 语法高亮 + 截断/二进制提示。
struct FileContentView: View {
    let repo: Repository?
    let path: String?
    var version: FileContentVersion = .local
    var availableVersions: [FileContentVersion] = [.local]
    var onVersionChange: (FileContentVersion) -> Void = { _ in }
    var onShowFileHistory: (String) -> Void = { _ in }
    var blameRequestID: Int = 0
    /// Incremented by the workspace after a Git status/index refresh. This
    /// mirrors the invalidation part of IntelliJ's VFS-backed version views.
    var refreshToken: Int = 0
    @State private var content: FileContent?
    @State private var error: String?
    @State private var loading = false
    @State private var showBlame = false
    @State private var blameLines: [BlameLine] = []
    @State private var blameError: String?
    @State private var blameLoading = false
    @State private var lineChanges: [Int: CodeLineChange] = [:]
    @State private var loadGeneration = 0
    @State private var blameGeneration = 0
    @State private var appliedBlameRequestID = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let path {
                HStack(spacing: Design.Spacing.sm) {
                    Image(systemName: version == .staged ? "square.and.arrow.down" : "doc.text")
                        .foregroundStyle(Design.Colors.accent)
                    Text("\(version.title) · \(path)")
                        .font(Design.Typography.codeSmall)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if availableVersions.count > 1 {
                        Picker(
                            "Version",
                            selection: Binding(
                                get: { version },
                                set: { onVersionChange($0) }
                            )
                        ) {
                            ForEach(availableVersions, id: \.self) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .frame(width: 210)
                        .help("Switch between versions present in the repository")
                    }
                    if showBlame {
                        GitAnnotationOptionsMenu {
                            loadBlame(path)
                        }
                    }
                    if let historyPath = projectFileTreeHistoryPath(path, isDirectory: false) {
                        Button {
                            onShowFileHistory(historyPath)
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .buttonStyle(.borderless)
                        .help("Show File History")
                    }
                    Spacer()
                    if version == .local, let content, !content.binary {
                        Button(showBlame ? "Code" : "Blame") {
                            showBlame.toggle()
                            if showBlame { loadBlame(path) }
                        }
                        .disabled(content.truncated)
                    }
                    if content?.truncated == true {
                        Label("内容已截断", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, Design.Spacing.md)
                .padding(.vertical, Design.Spacing.sm)
                Divider()
            }

            if let error {
                messageView(systemImage: "exclamationmark.triangle", text: error, color: Design.Colors.error)
            } else if loading {
                ProgressView("读取文件…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let content, content.binary {
                messageView(systemImage: "doc.zipper", text: "二进制文件，无法作为文本查看", color: .secondary)
            } else if showBlame, content != nil {
                if blameLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let blameError {
                    messageView(systemImage: "exclamationmark.triangle", text: blameError, color: Design.Colors.error)
                } else if !blameLines.isEmpty {
                    BlameCodeLinesView(lines: blameLines, onCommit: openCommitDetail)
                } else {
                    messageView(systemImage: "person.2", text: "Blame", color: .secondary)
                }
            } else if let content {
                CodeLinesView(text: content.text, path: path ?? "", lineChanges: lineChanges)
            } else {
                messageView(systemImage: "doc", text: "从文件树选择一个文件", color: .secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Design.Colors.canvas)
        .onAppear {
            load()
            applyBlameRequestIfNeeded()
        }
        .onChange(of: path) { _, _ in load() }
        .onChange(of: version) { _, _ in load() }
        .onChange(of: refreshToken) { _, _ in load() }
        .onChange(of: blameRequestID) { _, _ in applyBlameRequestIfNeeded() }
    }

    private func applyBlameRequestIfNeeded() {
        guard blameRequestID > appliedBlameRequestID else { return }
        appliedBlameRequestID = blameRequestID
        guard version == .local, let path else { return }
        showBlame = true
        loadBlame(path)
    }

    private func load() {
        loadGeneration &+= 1
        blameGeneration &+= 1
        let generation = loadGeneration
        guard let repo, let path else {
            content = nil
            error = nil
            showBlame = false
            blameLines = []
            blameError = nil
            lineChanges = [:]
            return
        }
        loading = true
        error = nil
        showBlame = false
        blameLines = []
        blameError = nil
        lineChanges = [:]
        let requestedVersion = version
        Task.detached(priority: .userInitiated) {
            do {
                let result: FileContent
                let diffMode: DiffMode
                switch requestedVersion {
                case .local:
                    result = try repo.readWorktreeFile(path: path)
                    diffMode = .worktreeToHead
                case .staged:
                    result = try repo.readIndexFile(path: path)
                    diffMode = .indexToHead
                }
                let diff = (!result.binary && !result.truncated)
                    ? try? repo.diffFile(path: path, mode: diffMode, ignoreWhitespace: false)
                    : nil
                let lineCount = max(1, result.text.components(separatedBy: "\n").count - (result.text.hasSuffix("\n") ? 1 : 0))
                await MainActor.run {
                    guard isCurrentFileContentRequest(
                        path: path,
                        version: requestedVersion,
                        generation: generation,
                        currentPath: self.path,
                        currentVersion: self.version,
                        currentGeneration: self.loadGeneration
                    ) else { return }
                    content = result
                    lineChanges = diff.map {
                        codeLineChanges(for: $0, lineCount: lineCount)
                    } ?? [:]
                    loading = false
                }
            } catch {
                await MainActor.run {
                    guard isCurrentFileContentRequest(
                        path: path,
                        version: requestedVersion,
                        generation: generation,
                        currentPath: self.path,
                        currentVersion: self.version,
                        currentGeneration: self.loadGeneration
                    ) else { return }
                    self.error = "\(error)"
                    loading = false
                }
            }
        }
    }

    private func loadBlame(_ path: String) {
        guard version == .local, let repo else { return }
        blameGeneration &+= 1
        let generation = blameGeneration
        let requestedVersion = version
        blameLoading = true
        blameLines = []
        blameError = nil
        Task.detached(priority: .userInitiated) {
            do {
                let lines = try repo.blameWorktreeWithOptions(
                    path: path,
                    options: GitAnnotationSettings.options()
                )
                await MainActor.run {
                    guard self.blameGeneration == generation,
                          self.path == path,
                          self.version == requestedVersion else { return }
                    self.blameLines = lines
                    self.blameLoading = false
                }
            } catch {
                await MainActor.run {
                    guard self.blameGeneration == generation,
                          self.path == path,
                          self.version == requestedVersion else { return }
                    self.blameError = "\(error)"
                    self.blameLoading = false
                }
            }
        }
    }

    private func openCommitDetail(_ commitId: String) {
        NotificationCenter.default.post(name: .arborOpenCommitDetail, object: commitId)
    }

    private func messageView(systemImage: String, text: String, color: Color) -> some View {
        VStack(spacing: Design.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(color)
            Text(text)
                .foregroundStyle(color)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Design.Spacing.xl)
    }
}

/// The annotation gutter action group from IntelliJ's Git provider. Options
/// are global, and changing one invalidates the current blame so the new Git
/// arguments are applied immediately.
struct GitAnnotationOptionsMenu: View {
    let onChanged: () -> Void

    @AppStorage(GitAnnotationSettings.ignoreWhitespacesKey)
    private var ignoreWhitespaces = GitAnnotationSettings.defaultIgnoreWhitespaces
    @AppStorage(GitAnnotationSettings.movementKey)
    private var movementRaw = "none"
    @AppStorage(GitAnnotationSettings.preferCommitDateKey)
    private var preferCommitDate = GitAnnotationSettings.defaultPreferCommitDate

    var body: some View {
        Menu("Blame Options") {
            Toggle("Ignore Whitespaces", isOn: $ignoreWhitespaces)
            Divider()
            Toggle(
                "Detect Movements Within File",
                isOn: Binding(
                    get: { movementRaw == "inner" || movementRaw == "outer" },
                    set: { movementRaw = $0 ? "inner" : "none" }
                )
            )
            Toggle(
                "Detect Movements Across Files",
                isOn: Binding(
                    get: { movementRaw == "outer" },
                    set: { movementRaw = $0 ? "outer" : "inner" }
                )
            )
            Toggle("Prefer Commit Date", isOn: $preferCommitDate)
        }
        .onChange(of: ignoreWhitespaces) { _, _ in onChanged() }
        .onChange(of: movementRaw) { _, _ in onChanged() }
        .onChange(of: preferCommitDate) { _, _ in onChanged() }
    }
}

private struct BlameCodeLinesView: View {
    let lines: [BlameLine]
    let onCommit: (String) -> Void

    private let lineNumberWidth: CGFloat = 52 + Design.Spacing.md

    private var maxLineWidth: CGFloat {
        lines.map { line in
            ceil((line.text as NSString).size(withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            ]).width)
        }.max() ?? 0
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines, id: \.line) { line in
                        HStack(alignment: .top, spacing: 0) {
                            Text(line.author.isEmpty ? "—" : line.author)
                                .font(.system(.caption, design: .default))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 120, alignment: .leading)
                                .help(line.summary)
                            Text(line.shortId)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(blameColor(line.shortId))
                                .frame(width: 64, alignment: .leading)
                                .help(line.summary)
                            Text(dateStr(line.time))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 120, alignment: .leading)
                            Text(String(line.line))
                                .font(Design.Typography.codeSmall)
                                .foregroundStyle(.tertiary)
                                .frame(width: 52, alignment: .trailing)
                                .padding(.trailing, Design.Spacing.md)
                            Text(highlightedLine(line))
                                .font(Design.Typography.code)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 1)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard canOpenCommit(line.commitId) else { return }
                            onCommit(line.commitId)
                        }
                    }
                }
                .frame(width: max(proxy.size.width, lineNumberWidth + 304 + maxLineWidth), alignment: .topLeading)
                .frame(minHeight: proxy.size.height, alignment: .topLeading)
                .padding(.vertical, Design.Spacing.sm)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .scrollContentBackground(.hidden)
    }

    private func highlightedLine(_ line: BlameLine) -> AttributedString {
        var result = AttributedString(line.text)
        SyntaxHighlight.apply(line.highlights, to: line.text, attr: &result)
        return result
    }

    private func canOpenCommit(_ commitId: String) -> Bool {
        commitId.count == 40 && !commitId.allSatisfy { $0 == "0" }
    }

    private func blameColor(_ shortId: String) -> Color {
        let palette: [Color] = [
            .orange, .pink, .teal, .indigo, .brown,
            .mint, .purple, .cyan, .green, .red,
        ]
        var hash: UInt64 = 0
        for byte in shortId.utf8 {
            hash = hash &* 31 &+ UInt64(byte)
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

private struct CodeLinesView: View {
    let text: String
    let path: String
    let lineChanges: [Int: CodeLineChange]
    private let spans: [HighlightSpan]

    private let lineNumberWidth: CGFloat = 52 + Design.Spacing.md + 8

    init(text: String, path: String, lineChanges: [Int: CodeLineChange]) {
        self.text = text
        self.path = path
        self.lineChanges = lineChanges
        self.spans = highlightCode(content: text, path: path)
    }

    private var lines: [String] {
        var result = text.components(separatedBy: "\n")
        if result.last == "" && text.hasSuffix("\n") { result.removeLast() }
        return result.isEmpty ? [""] : result
    }

    private var lineOffsets: [Int] {
        var offsets: [Int] = []
        offsets.reserveCapacity(lines.count)
        var offset = 0
        for line in lines {
            offsets.append(offset)
            offset += line.utf8.count + 1
        }
        return offsets
    }

    /// 使用实际等宽字体测量最长行，避免短文件被居中，也避免长行被压缩换行。
    private var maxLineWidth: CGFloat {
        lines.map { line in
            ceil((line as NSString).size(withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            ]).width)
        }.max() ?? 0
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .top, spacing: 0) {
                            Rectangle()
                                .fill(lineChanges[index + 1]?.color ?? .clear)
                                .frame(width: 4, height: 15)
                                .padding(.trailing, 4)
                                .accessibilityHidden(lineChanges[index + 1] == nil)
                            Text(String(index + 1))
                                .font(Design.Typography.codeSmall)
                                .foregroundStyle(.tertiary)
                                .frame(width: 52, alignment: .trailing)
                                .padding(.trailing, Design.Spacing.md)
                            Text(highlightedLine(line, index: index))
                                .font(Design.Typography.code)
                                .textSelection(.enabled)
                                // Keep each source line on one visual line so long
                                // lines extend the scrollable content horizontally.
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 1)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            lineChanges[index + 1].map {
                                "Line \(index + 1), \($0.accessibilityLabel)"
                            } ?? "Line \(index + 1)"
                        )
                    }
                }
                .frame(width: max(proxy.size.width, lineNumberWidth + maxLineWidth), alignment: .topLeading)
                // Keep short files at the top of the editor. Using an
                // unbounded maxHeight inside ScrollView makes SwiftUI center
                // the intrinsic rows vertically.
                .frame(minHeight: proxy.size.height, alignment: .topLeading)
                .padding(.vertical, Design.Spacing.sm)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .scrollContentBackground(.hidden)
    }

    private func highlightedLine(_ line: String, index: Int) -> AttributedString {
        var result = AttributedString(line)
        let offset = lineOffsets[index]
        let end = offset + line.utf8.count
        let localSpans = spans.compactMap { span -> HighlightSpan? in
            let start = max(Int(span.start), offset)
            let finish = min(Int(span.end), end)
            guard finish > start else { return nil }
            return HighlightSpan(
                start: UInt32(start - offset),
                end: UInt32(finish - offset),
                kind: span.kind
            )
        }
        SyntaxHighlight.apply(localSpans, to: line, attr: &result)
        return result
    }
}
