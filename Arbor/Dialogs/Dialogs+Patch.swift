import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Shared Create Patch configuration. IntelliJ keeps these choices in the
/// patch dialog instead of making reverse/export destination separate actions.
struct RebasedPatchExportDialog: View {
    let request: PatchExportRequest
    let onExport: (PatchExportOptions) -> Void
    let onCancel: () -> Void

    @State private var baseDirectory: String
    @State private var reverse = false
    @State private var copyToClipboard: Bool
    @State private var encoding: PatchExportEncodingChoice

    init(
        request: PatchExportRequest,
        onExport: @escaping (PatchExportOptions) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.onExport = onExport
        self.onCancel = onCancel
        _baseDirectory = State(initialValue: request.repositoryRootPath)
        _copyToClipboard = State(initialValue: request.initialCopyToClipboard)
        _encoding = State(initialValue: request.initialEncoding)
    }

    private var baseDirectoryError: String? {
        guard request.allowsBaseDirectory else { return nil }
        return patchExportBaseDirectoryIsValid(
            repositoryRootPath: request.repositoryRootPath,
            baseDirectory: baseDirectory,
            paths: request.paths
        ) ? nil : "Choose a directory inside the Git root that contains every selected path."
    }

    private func chooseBaseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: baseDirectory)
        panel.prompt = "Choose Base Directory"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        baseDirectory = url.standardizedFileURL.path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.title)
                .font(.title2.weight(.semibold))

            Text("Choose how the selected Git changes are written. The patch remains a portable Git patch.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 7) {
                Text("Base directory")
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(baseDirectory == request.repositoryRootPath ? "Repository root" : baseDirectory)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…", action: chooseBaseDirectory)
                        .disabled(!request.allowsBaseDirectory)
                }
                if !request.allowsBaseDirectory {
                    Text("Full revision export uses the repository root because its complete path set is not loaded in the dialog.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let baseDirectoryError {
                    Label(baseDirectoryError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Patch paths are written relative to this directory.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Reverse patch", isOn: $reverse)
                .toggleStyle(.checkbox)
                .help("Swap the before and after sides of the selected comparison.")
            Toggle("Copy to Clipboard", isOn: $copyToClipboard)
                .toggleStyle(.checkbox)

            HStack(spacing: 10) {
                Text("Encoding")
                Picker("Encoding", selection: $encoding) {
                    ForEach(PatchExportEncodingChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .labelsHidden()
                .frame(width: 180, alignment: .leading)
                if copyToClipboard {
                    Text("Clipboard uses Unicode text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button(copyToClipboard ? "Copy Patch" : "Create Patch") {
                    let selectedBase = baseDirectory == request.repositoryRootPath ? nil : baseDirectory
                    onExport(PatchExportOptions(
                        baseDirectory: selectedBase,
                        reverse: reverse,
                        copyToClipboard: copyToClipboard,
                        encoding: encoding
                    ))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(baseDirectoryError != nil)
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}
/// Applies a patch's raw path-strip independently from filesystem matching.
/// Keeping this pure lets the Apply Patch tree explain an invalid mapping
/// before invoking Git, while a user-selected base can still be tried again.
enum RebasedPatchPathMapper {
    static func strippedPath(rawPath: String, pathStrip: UInt32) -> String? {
        let components = rawPath
            .split(separator: "/")
            .map(String.init)
        guard !components.isEmpty, Int(pathStrip) < components.count else { return nil }
        return components.dropFirst(Int(pathStrip)).joined(separator: "/")
    }
}
struct RebasedPatchBaseCandidate: Hashable, Identifiable {
    let basePath: String
    let pathStrip: UInt32
    var contextScore: Int

    var id: String { "\(basePath)|\(pathStrip)" }

    var title: String {
        let base = basePath.isEmpty ? "Repository root" : basePath
        return "\(base) (−p\(pathStrip))"
    }
}
/// The project-scoped equivalent of IntelliJ's GlobalSearchScope.projectScope.
/// Arbor has no IDE content-root model, so a repository patch starts with its
/// worktree as the content root and accepts explicit excluded roots from the
/// caller. This keeps scope behavior data-driven instead of guessing hidden
/// directory names.
struct RebasedPatchCandidateScope: Hashable, Codable, Sendable {
    let rootPath: String
    /// Explicit content roots mirror IntelliJ's project scope without
    /// inventing module/IDE metadata. An empty list means the repository root.
    let contentRootPaths: [String]
    let excludedPaths: [String]

    init(
        rootPath: String,
        contentRootPaths: [String] = [],
        excludedPaths: [String] = []
    ) {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        self.rootPath = root
        self.contentRootPaths = Array(
            Set(contentRootPaths.map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            })
        ).sorted()
        self.excludedPaths = Array(
            Set(excludedPaths.map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            })
        ).sorted()
    }

    static func repository(rootPath: String) -> Self {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        return Self(
            rootPath: root.path,
            excludedPaths: [root.appendingPathComponent(".git").path]
        )
    }

    func contains(_ path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard normalized == rootPath || normalized.hasPrefix(rootPath + "/") else {
            return false
        }
        if !contentRootPaths.isEmpty,
           !contentRootPaths.contains(where: {
               normalized == $0 || normalized.hasPrefix($0 + "/")
           }) {
            return false
        }
        return !isExcluded(normalized)
    }

    func isExcluded(_ path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        return excludedPaths.contains {
            normalized == $0 || normalized.hasPrefix($0 + "/")
        }
    }

    /// Roots to walk for a physical index build. Nested content roots are
    /// collapsed so the same file is not visited twice.
    var scanRoots: [URL] {
        let roots = (contentRootPaths.isEmpty ? [rootPath] : contentRootPaths)
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { contains($0.path) && !isExcluded($0.path) }
            .sorted { $0.path.count < $1.path.count }
        return roots.filter { candidate in
            !roots.contains { parent in
                parent.path != candidate.path && candidate.path.hasPrefix(parent.path + "/")
            }
        }
    }
}
/// Project-scoped filename index used by patch matching. IntelliJ's
/// `PsiPatchBaseDirectoryDetector` queries `FilenameIndex` rather than the
/// Git index, so this model deliberately combines materialized project files
/// with paths known by Git and applies the caller's content/excluded scope
/// before candidates are generated.
struct RebasedPatchFilenameIndex: Hashable, Codable, Sendable {
    let rootPath: String
    let relativeFiles: [String]
    let relativeDirectories: [String]
    let directoryModificationDates: [String: TimeInterval]

    init(
        rootPath: String,
        filePaths: [String],
        directoryPaths: [String] = [],
        scope: RebasedPatchCandidateScope? = nil
    ) {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        let candidateScope = scope ?? RebasedPatchCandidateScope.repository(rootPath: root.path)
        self.rootPath = root.path

        var files = Set<String>()
        var directories = Set<String>([""])

        func relativePath(_ path: String) -> String? {
            let candidateURL: URL
            if path.hasPrefix("/") {
                candidateURL = URL(fileURLWithPath: path).standardizedFileURL
            } else {
                candidateURL = root.appendingPathComponent(path).standardizedFileURL
            }
            let candidatePath = candidateURL.path
            guard candidatePath != root.path,
                  candidateScope.rootPath == root.path,
                  candidateScope.contains(candidatePath) else {
                return nil
            }
            return String(candidatePath.dropFirst(root.path.count + 1))
        }

        func addParentDirectories(for relativePath: String) {
            let components = relativePath.split(separator: "/").map(String.init)
            guard components.count > 1 else { return }
            for depth in 1..<components.count {
                directories.insert(components.prefix(depth).joined(separator: "/"))
            }
        }

        for path in filePaths {
            guard let relative = relativePath(path), !relative.isEmpty else { continue }
            files.insert(relative)
            addParentDirectories(for: relative)
        }
        for path in directoryPaths {
            guard let relative = relativePath(path), !relative.isEmpty else { continue }
            directories.insert(relative)
        }

        self.relativeFiles = files.sorted()
        self.relativeDirectories = directories.sorted()
        self.directoryModificationDates = Self.modificationDates(
            root: root,
            relativeDirectories: self.relativeDirectories
        )
    }

    /// Build the index from all files visible under the project scope. This
    /// is intentionally an explicit provider boundary: callers can inject
    /// virtual/index-backed paths in tests or when a project root is not fully
    /// materialized, while the default path still covers untracked files.
    static func build(
        rootPath: String,
        indexedPaths: [String],
        scope: RebasedPatchCandidateScope? = nil
    ) -> Self {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        let candidateScope = scope ?? RebasedPatchCandidateScope.repository(rootPath: root.path)
        var files = indexedPaths
        var directories: [String] = []

        for scanRoot in candidateScope.scanRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: scanRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else { continue }
            for case let url as URL in enumerator {
                let path = url.standardizedFileURL.path
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                guard candidateScope.contains(path) else {
                    if isDirectory { enumerator.skipDescendants() }
                    continue
                }
                if isDirectory {
                    directories.append(path)
                } else {
                    files.append(path)
                }
            }
        }

        return Self(
            rootPath: root.path,
            filePaths: files,
            directoryPaths: directories,
            scope: candidateScope
        )
    }

    func files(matchingSuffix components: [String]) -> [String] {
        guard !components.isEmpty else { return [] }
        return relativeFiles.filter { path in
            let pathComponents = path.split(separator: "/").map(String.init)
            return pathComponents.count >= components.count
                && Array(pathComponents.suffix(components.count)) == components
        }
    }

    func directories(matchingSuffix components: [String]) -> [String] {
        guard !components.isEmpty else { return [] }
        return relativeDirectories.filter { path in
            let pathComponents = path.split(separator: "/").map(String.init)
            return pathComponents.count >= components.count
                && Array(pathComponents.suffix(components.count)) == components
        }
    }

    var indexedItems: Set<String> {
        Set(relativeFiles + relativeDirectories.filter { !$0.isEmpty })
    }

    /// A persisted filename index is valid as long as every indexed directory
    /// still exists with the same filesystem revision. Directory metadata is
    /// enough for filename membership: file content changes do not affect the
    /// candidate set, while create/delete/rename changes update a directory.
    func isFilesystemCurrent() -> Bool {
        guard !directoryModificationDates.isEmpty else { return true }
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        for (relativePath, expectedDate) in directoryModificationDates {
            let url = relativePath.isEmpty
                ? root
                : root.appendingPathComponent(relativePath)
            guard let actualDate = Self.modificationDate(for: url),
                  actualDate == expectedDate else {
                return false
            }
        }
        return true
    }

    private static func modificationDates(
        root: URL,
        relativeDirectories: [String]
    ) -> [String: TimeInterval] {
        Dictionary(uniqueKeysWithValues: relativeDirectories.compactMap { relativePath in
            let url = relativePath.isEmpty
                ? root
                : root.appendingPathComponent(relativePath)
            guard let date = modificationDate(for: url) else { return nil }
            return (relativePath, date)
        })
    }

    private static func modificationDate(for url: URL) -> TimeInterval? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970
    }
}
/// A project-scoped, persisted approximation of IntelliJ's VFS/Psi
/// FilenameIndex. The cache is keyed by root and content/excluded scope, is
/// validated through directory revisions, and can be explicitly invalidated
/// by the repository watcher. It stores names only; candidate application
/// still verifies the actual target file and patch context.
enum RebasedPatchFilenameIndexStore {
    private static let keyPrefix = "arbor.git.patchFilenameIndex.v2."

    private struct Snapshot: Codable {
        let scope: RebasedPatchCandidateScope
        let indexedPathRevision: String
        let index: RebasedPatchFilenameIndex
    }

    static func loadOrBuild(
        rootPath: String,
        indexedPaths: [String],
        scope: RebasedPatchCandidateScope? = nil,
        defaults: UserDefaults = .standard
    ) -> RebasedPatchFilenameIndex {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        let candidateScope = scope ?? RebasedPatchCandidateScope.repository(rootPath: root)
        let revision = indexedPathRevision(indexedPaths)
        let key = cacheKey(rootPath: root, scope: candidateScope)

        if let data = defaults.data(forKey: key),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
           snapshot.scope == candidateScope,
           snapshot.indexedPathRevision == revision,
           snapshot.index.rootPath == root,
           snapshot.index.isFilesystemCurrent() {
            return snapshot.index
        }

        let index = RebasedPatchFilenameIndex.build(
            rootPath: root,
            indexedPaths: indexedPaths,
            scope: candidateScope
        )
        let snapshot = Snapshot(
            scope: candidateScope,
            indexedPathRevision: revision,
            index: index
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: key)
        }
        return index
    }

    static func invalidate(
        rootPath: String,
        defaults: UserDefaults = .standard
    ) {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        let prefix = keyPrefix + encoded(root) + "."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private static func cacheKey(
        rootPath: String,
        scope: RebasedPatchCandidateScope
    ) -> String {
        let scopeData = (try? JSONEncoder().encode(scope)) ?? Data()
        return keyPrefix + encoded(rootPath) + "." + scopeData.base64EncodedString()
    }

    private static func encoded(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    private static func indexedPathRevision(_ paths: [String]) -> String {
        // Stable FNV-1a avoids relying on Swift's randomized Hashable value.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for path in paths.sorted() {
            for byte in path.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            hash ^= 0xff
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
/// Matches imported patch hunks using the same signal as IntelliJ's
/// `GenericPatchApplier.weightContextMatch(100, 5)`: one point per matching
/// split hunk, bounded by a line-position window and by the first five parts.
/// This is deliberately kept pure so candidate selection can be regression-tested.
enum RebasedPatchContextMatcher {
    private struct SplitHunk {
        let expectedOldStart: Int
        let oldLines: [String]
        let newLines: [String]
    }

    static func score(
        patch: String,
        text: String,
        maxWalk: Int = 100,
        maxPartsToCheck: Int = 5
    ) -> Int {
        guard maxPartsToCheck > 0 else { return 0 }
        let textLines = text.components(separatedBy: .newlines)
        var score = 0
        var checkedParts = 0
        for hunk in parseSplitHunks(patch: patch) {
            // GenericPatchApplier does not consume a maxPartsToCheck slot for
            // a pure insertion, because it cannot provide old-file context.
            guard !hunk.oldLines.isEmpty else { continue }
            if checkedParts == maxPartsToCheck { break }
            checkedParts += 1
            let oldMatches = matches(
                hunk.oldLines,
                in: textLines,
                expectedStart: hunk.expectedOldStart,
                maxWalk: maxWalk
            )
            let newMatches = matches(
                hunk.newLines,
                in: textLines,
                expectedStart: hunk.expectedOldStart,
                maxWalk: maxWalk
            )
            if oldMatches || newMatches { score += 1 }
        }
        return score
    }

    private static func parseSplitHunks(patch: String) -> [SplitHunk] {
        let lines = patch
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let hunkStarts = lines.indices.filter { lines[$0].hasPrefix("@@") }
        var result: [SplitHunk] = []

        for (offset, start) in hunkStarts.enumerated() {
            let nextHunk = hunkStarts.dropFirst(offset + 1).first ?? lines.count
            let end = lines[start..<nextHunk].firstIndex(where: { $0.hasPrefix("diff --git ") }) ?? nextHunk
            guard let oldStart = oldStartLine(in: lines[start]) else { continue }
            let body = Array(lines[(start + 1)..<end])

            var pendingContext: [String] = []
            var oldLineOffset = 0
            var index = 0
            while index < body.count {
                if let context = contextLine(body[index]) {
                    pendingContext.append(context)
                    oldLineOffset += 1
                    index += 1
                    continue
                }

                var oldChanges: [String] = []
                var newChanges: [String] = []
                let expectedOffset = oldLineOffset - pendingContext.count
                var hasChange = false
                while index < body.count, let type = body[index].first {
                    switch type {
                    case "-":
                        oldChanges.append(String(body[index].dropFirst()))
                        oldLineOffset += 1
                        hasChange = true
                    case "+":
                        newChanges.append(String(body[index].dropFirst()))
                        hasChange = true
                    case "\\":
                        index += 1
                        continue
                    default:
                        break
                    }
                    if type == " " || (type != "-" && type != "+" && type != "\\") {
                        break
                    }
                    index += 1
                }

                var trailingContext: [String] = []
                while index < body.count, let context = contextLine(body[index]) {
                    trailingContext.append(context)
                    oldLineOffset += 1
                    index += 1
                }

                if hasChange {
                    result.append(
                        SplitHunk(
                            expectedOldStart: max(0, oldStart - 1 + expectedOffset),
                            oldLines: pendingContext + oldChanges + trailingContext,
                            newLines: pendingContext + newChanges + trailingContext
                        )
                    )
                }
                pendingContext = trailingContext
            }
        }
        return result
    }

    private static func oldStartLine(in header: String) -> Int? {
        guard let range = header.range(of: "@@ -") else { return nil }
        let suffix = header[range.upperBound...]
        let digits = suffix.prefix { $0.isNumber }
        return Int(digits)
    }

    private static func contextLine(_ line: String) -> String? {
        guard line.first == " " else { return nil }
        return String(line.dropFirst())
    }

    private static func matches(
        _ sequence: [String],
        in lines: [String],
        expectedStart: Int,
        maxWalk: Int
    ) -> Bool {
        guard !sequence.isEmpty, sequence.count <= lines.count else { return false }
        let lastStart = lines.count - sequence.count
        let lowerBound = max(0, expectedStart - maxWalk)
        let upperBound = min(lastStart, expectedStart + maxWalk)
        guard lowerBound <= upperBound else { return false }
        for start in lowerBound...upperBound {
            if Array(lines[start..<(start + sequence.count)]) == sequence {
                return true
            }
        }
        return false
    }
}
/// Converts a raw unified/Git patch hunk into the same structured diff model
/// used by revision-backed previews. Apply Patch has no revision tree to ask
/// the engine for, but the patch itself already contains enough old/new line
/// content for a faithful side-by-side or unified viewer.
enum RebasedPatchDiffParser {
    static func parse(
        patch: String,
        path: String
    ) -> FileDiff? {
        let lines = patch
            .components(separatedBy: "\n")
            .map { line in
                line.hasSuffix("\r") ? String(line.dropLast()) : line
            }
        let hunkStarts = lines.indices.filter { lines[$0].hasPrefix("@@") }
        guard !hunkStarts.isEmpty else { return nil }

        var hunks: [DiffHunk] = []
        for (offset, start) in hunkStarts.enumerated() {
            guard let starts = parseHunkStarts(lines[start]) else { continue }
            let end = hunkStarts.dropFirst(offset + 1).first ?? lines.count
            var oldLineNumber = starts.old
            var newLineNumber = starts.new
            var oldLines: [DiffLine] = []
            var newLines: [DiffLine] = []

            for line in lines[(start + 1)..<end] {
                guard let marker = line.first else { continue }
                let text = String(line.dropFirst())
                switch marker {
                case " ":
                    let context = DiffLine(
                        kind: .context,
                        oldLine: oldLineNumber,
                        newLine: newLineNumber,
                        text: text,
                        spans: [],
                        highlights: []
                    )
                    oldLines.append(context)
                    newLines.append(context)
                    oldLineNumber += 1
                    newLineNumber += 1
                case "-":
                    oldLines.append(DiffLine(
                        kind: .deletion,
                        oldLine: oldLineNumber,
                        newLine: 0,
                        text: text,
                        spans: [],
                        highlights: []
                    ))
                    oldLineNumber += 1
                case "+":
                    newLines.append(DiffLine(
                        kind: .addition,
                        oldLine: 0,
                        newLine: newLineNumber,
                        text: text,
                        spans: [],
                        highlights: []
                    ))
                    newLineNumber += 1
                case "\\":
                    // Git's "No newline at end of file" marker is metadata.
                    continue
                default:
                    // Be tolerant of extended patch metadata inside a chunk.
                    continue
                }
            }

            hunks.append(DiffHunk(
                oldStart: starts.old,
                newStart: starts.new,
                oldLines: oldLines,
                newLines: newLines
            ))
        }

        return hunks.isEmpty ? nil : FileDiff(path: path, binary: false, hunks: hunks)
    }

    private static func parseHunkStarts(_ header: String) -> (old: UInt32, new: UInt32)? {
        let tokens = header.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count >= 3,
              let old = parseLineStart(String(tokens[1]), marker: "-"),
              let new = parseLineStart(String(tokens[2]), marker: "+") else {
            return nil
        }
        return (old, new)
    }

    private static func parseLineStart(_ token: String, marker: String) -> UInt32? {
        guard token.hasPrefix(marker) else { return nil }
        let value = token.dropFirst().split(separator: ",", maxSplits: 1).first
        return value.flatMap { UInt32($0) }
    }
}
