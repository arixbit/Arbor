import SwiftUI
import AppKit


struct RebasedApplyPatchRequest: Identifiable {
    let id = UUID()
    let fileName: String
    let patch: String
    let paths: [String]
}

/// The file encodings exposed by IntelliJ's Create Patch configuration panel.
/// Clipboard output stays a native Swift String; this choice only controls
/// bytes written to a patch file.
enum PatchExportEncodingChoice: String, CaseIterable, Identifiable, Sendable {
    case utf8 = "utf-8"
    case utf16 = "utf-16"
    case isoLatin1 = "iso-8859-1"
    case windows1252 = "windows-1252"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf16: "UTF-16"
        case .isoLatin1: "ISO-8859-1"
        case .windows1252: "Windows-1252"
        }
    }

    var stringEncoding: String.Encoding {
        switch self {
        case .utf8: .utf8
        case .utf16: .utf16
        case .isoLatin1: .isoLatin1
        case .windows1252: .windowsCP1252
        }
    }
}

/// Project-scoped Create Patch preferences. IntelliJ remembers the clipboard
/// choice and patch destination while the encoding defaults to the project
/// charset; scoping all three to the canonical Git root avoids leaking a
/// path or charset choice between unrelated projects.
enum PatchExportSettings {
    static let keyPrefix = "arbor.git.patchExport.project.v1:"

    static func key(for repositoryRootPath: String, suffix: String) -> String {
        let normalized = URL(fileURLWithPath: repositoryRootPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let data = normalized.data(using: .utf8) ?? Data()
        return "\(keyPrefix)\(data.base64EncodedString()):\(suffix)"
    }

    static func encoding(
        for repositoryRootPath: String,
        defaults: UserDefaults = .standard
    ) -> PatchExportEncodingChoice {
        guard let raw = defaults.string(forKey: key(for: repositoryRootPath, suffix: "encoding")),
              let choice = PatchExportEncodingChoice(rawValue: raw) else {
            return .utf8
        }
        return choice
    }

    static func copyToClipboard(
        for repositoryRootPath: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: key(for: repositoryRootPath, suffix: "clipboard"))
    }

    static func lastDirectory(
        for repositoryRootPath: String,
        defaults: UserDefaults = .standard
    ) -> URL? {
        guard let raw = defaults.string(forKey: key(for: repositoryRootPath, suffix: "directory")),
              !raw.isEmpty else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: raw, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    static func save(
        _ options: PatchExportOptions,
        for repositoryRootPath: String,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(options.encoding.rawValue, forKey: key(for: repositoryRootPath, suffix: "encoding"))
        defaults.set(options.copyToClipboard, forKey: key(for: repositoryRootPath, suffix: "clipboard"))
    }

    static func saveDestination(
        _ destination: URL,
        for repositoryRootPath: String,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(
            destination.deletingLastPathComponent().standardizedFileURL.path,
            forKey: key(for: repositoryRootPath, suffix: "directory")
        )
    }
}

/// Configuration shared by every user-facing Create Patch entry point.
/// `baseDirectory` is an absolute directory selected inside the owning Git
/// root; nil means the repository root. `reverse` reverses the comparison
/// currently represented by the action, rather than assuming a particular
/// Git command orientation.
struct PatchExportOptions: Equatable, Sendable {
    let baseDirectory: String?
    let reverse: Bool
    let copyToClipboard: Bool
    let encoding: PatchExportEncodingChoice
}

/// The dialog is deliberately decoupled from a Repository so the UI can be
/// reused by Log, Compare, and Diff Viewer without moving Git work onto the
/// main actor. The callback is invoked only after the user confirms options.
struct PatchExportRequest: Identifiable {
    let id = UUID()
    let title: String
    let defaultFileName: String
    let repositoryRootPath: String
    let paths: [String]
    let allowsBaseDirectory: Bool
    let initialCopyToClipboard: Bool
    let initialEncoding: PatchExportEncodingChoice
    let onExport: (PatchExportOptions) -> Void
}

func choosePatchExportDestination(
    defaultFileName: String,
    repositoryRootPath: String
) -> URL? {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = defaultFileName
    panel.allowedContentTypes = [.plainText]
    panel.canCreateDirectories = true
    panel.prompt = "Create Patch"
    panel.directoryURL = PatchExportSettings.lastDirectory(for: repositoryRootPath)
    guard panel.runModal() == .OK else { return nil }
    if let url = panel.url {
        PatchExportSettings.saveDestination(url, for: repositoryRootPath)
    }
    return panel.url
}

func patchExportData(
    _ patch: String,
    encoding: PatchExportEncodingChoice
) throws -> Data {
    guard let data = patch.data(using: encoding.stringEncoding, allowLossyConversion: false) else {
        throw NSError(
            domain: "Arbor.Git",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The patch contains characters that cannot be represented as \(encoding.title)."
            ]
        )
    }
    return data
}

/// Converts valid UTF-8 Git output to the selected patch encoding. If Git
/// returned non-UTF-8 bytes, only UTF-8 output is safe without guessing the
/// source charset; preserve those bytes verbatim instead of silently replacing
/// them. Callers can still present `GitCommandResult.stdout` as lossy Unicode
/// text for the clipboard/UI path.
func patchExportData(
    _ rawPatch: Data,
    encoding: PatchExportEncodingChoice
) throws -> Data {
    guard let patch = String(data: rawPatch, encoding: .utf8) else {
        guard encoding == .utf8 else {
            throw NSError(
                domain: "Arbor.Git",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The patch contains characters that cannot be represented as \(encoding.title)."
                ]
            )
        }
        return rawPatch
    }
    return try patchExportData(patch, encoding: encoding)
}

/// Returns the repository-relative base used by Git's `--relative` option.
/// IntelliJ's patch builder requires every selected path to be relative to
/// the chosen base; rejecting an unsafe base prevents Git from silently
/// excluding changes outside that directory.
func patchExportBaseDirectoryRelativePath(
    repositoryRootPath: String,
    baseDirectory: String?,
    paths: [String]
) -> String? {
    let root = URL(fileURLWithPath: repositoryRootPath)
        .resolvingSymlinksInPath()
        .standardizedFileURL
    guard let baseDirectory,
          !baseDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }

    let base = URL(fileURLWithPath: baseDirectory)
        .resolvingSymlinksInPath()
        .standardizedFileURL
    guard base.path == root.path || base.path.hasPrefix(root.path + "/") else {
        return nil
    }
    guard paths.allSatisfy({ path in
        guard let relative = normalizedRepositoryRelativePath(path) else { return false }
        let absolute = root.appendingPathComponent(relative).standardizedFileURL
        return absolute.path == base.path || absolute.path.hasPrefix(base.path + "/")
    }) else {
        return nil
    }
    guard base.path != root.path else { return nil }
    return String(base.path.dropFirst(root.path.count + 1))
}

func patchExportBaseDirectoryIsValid(
    repositoryRootPath: String,
    baseDirectory: String?,
    paths: [String]
) -> Bool {
    guard let baseDirectory,
          !baseDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return true
    }
    let root = URL(fileURLWithPath: repositoryRootPath)
        .resolvingSymlinksInPath()
        .standardizedFileURL
    let base = URL(fileURLWithPath: baseDirectory)
        .resolvingSymlinksInPath()
        .standardizedFileURL
    guard base.path == root.path || base.path.hasPrefix(root.path + "/") else {
        return false
    }
    guard !paths.isEmpty else { return base.path == root.path }
    return paths.allSatisfy { path in
        guard let relative = normalizedRepositoryRelativePath(path) else { return false }
        let absolute = root.appendingPathComponent(relative).standardizedFileURL
        return absolute.path == base.path || absolute.path.hasPrefix(base.path + "/")
    }
}

/// Applies export-only options while preserving the base command's existing
/// orientation (for example Diff Viewer's index-to-worktree command already
/// contains `--reverse`). Options are inserted before `--`, so pathspecs
/// remain data and never become Git options.
func patchExportGitArguments(
    baseArguments: [String],
    repositoryRootPath: String,
    paths: [String],
    options: PatchExportOptions
) -> [String]? {
    guard patchExportBaseDirectoryIsValid(
        repositoryRootPath: repositoryRootPath,
        baseDirectory: options.baseDirectory,
        paths: paths
    ) else {
        return nil
    }

    let separatorIndex = baseArguments.firstIndex(of: "--") ?? baseArguments.endIndex
    let prefix = Array(baseArguments[..<separatorIndex])
    let suffix = Array(baseArguments[separatorIndex...])
    let hasBaseReverse = prefix.contains { $0 == "--reverse" || $0 == "-R" }
    var normalizedPrefix = prefix.filter { $0 != "--reverse" && $0 != "-R" }
    if hasBaseReverse != options.reverse {
        normalizedPrefix.append("--reverse")
    }
    if let base = patchExportBaseDirectoryRelativePath(
        repositoryRootPath: repositoryRootPath,
        baseDirectory: options.baseDirectory,
        paths: paths
    ) {
        normalizedPrefix.append("--relative=\(base)")
    }
    return normalizedPrefix + suffix
}

/// Git normally terminates a patch with LF. Normalize each independently
/// generated member before concatenating so a multi-commit export has one
/// unambiguous boundary and never gains accidental blank records.
func joinedGitPatchParts(_ parts: [String]) -> String {
    let nonEmpty = parts.filter { !$0.isEmpty }
    guard !nonEmpty.isEmpty else { return "" }
    return nonEmpty.map { part in
        part.trimmingCharacters(in: .newlines)
    }.joined(separator: "\n") + "\n"
}

/// The byte-preserving counterpart used when several Git commands contribute
/// one exported patch. Only trailing line separators are normalized; all
/// other bytes remain untouched.
func joinedGitPatchData(_ parts: [Data]) -> Data {
    let nonEmpty = parts.filter { !$0.isEmpty }
    guard !nonEmpty.isEmpty else { return Data() }

    var result = Data()
    for part in nonEmpty {
        var bytes = Array(part)
        while let last = bytes.last, last == 0x0A || last == 0x0D {
            bytes.removeLast()
        }
        result.append(contentsOf: bytes)
        result.append(UInt8(0x0A))
    }
    return result
}

/// Adds the optional IntelliJ-style commit header without round-tripping the
/// Git body through a lossy String conversion.
func patchExportData(
    _ rawPatch: Data,
    commitMessage: String?,
    encoding: PatchExportEncodingChoice
) throws -> Data {
    guard let commitMessage else {
        return try patchExportData(rawPatch, encoding: encoding)
    }
    let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else {
        return try patchExportData(rawPatch, encoding: encoding)
    }
    let header = try patchExportData(
        "Subject: [PATCH] \(message)\n---\n",
        encoding: encoding
    )
    var output = Data()
    output.append(header)
    output.append(try patchExportData(rawPatch, encoding: encoding))
    return output
}

/// Matches IntelliJ UnifiedDiffWriter's optional commit-message header for a
/// single revision patch. Git's diff body remains untouched, including binary
/// patch records and Unix line separators.
func patchTextWithCommitMessage(_ patch: String, commitMessage: String?) -> String {
    guard let commitMessage else { return patch }
    let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else { return patch }
    return "Subject: [PATCH] \(message)\n---\n\(patch)"
}

/// Apply Patch 的稳定 hunk 状态。`pending`/`alreadyApplied`/`notApplied`
/// 是当前 result 文本相对于 patch 的判定；其余三种是用户在当前 viewer
/// 会话中的 resolved 状态。
enum ApplyPatchHunkResolution: Equatable {
    case pending
    case alreadyApplied
    case notApplied
    case applied
    case automaticallyApplied
    case ignored

    var isResolved: Bool {
        switch self {
        case .applied, .automaticallyApplied, .ignored: return true
        case .pending, .alreadyApplied, .notApplied: return false
        }
    }

    var title: String {
        switch self {
        case .pending: return "Ready to apply"
        case .alreadyApplied: return "Already applied"
        case .notApplied: return "Not applied"
        case .applied: return "Applied"
        case .automaticallyApplied: return "Applied automatically"
        case .ignored: return "Ignored"
        }
    }
}

/// 对 NSTextView 应用 tree-sitter 语法高亮（前景色；字节偏移转 UTF-16 NSRange）。
/// 复用引擎 HighlightSpan + SyntaxHighlight 调色板。静默降级（未知语言/超长/失败 -> 空）。
func applySyntaxHighlight(to tv: NSTextView?, path: String) {
    guard let tv, let ts = tv.textStorage else { return }
    let text = tv.string
    let spans = highlightCode(content: text, path: path)
    guard !spans.isEmpty else { return }
    let utf8 = text.utf8
    let nsLen = (text as NSString).length
    for s in spans {
        guard let startIdx = utf8.index(utf8.startIndex, offsetBy: Int(s.start), limitedBy: utf8.endIndex),
              let endIdx = utf8.index(utf8.startIndex, offsetBy: Int(s.end), limitedBy: utf8.endIndex) else { continue }
        let start16 = text.utf16.distance(from: text.utf16.startIndex, to: startIdx)
        let end16 = text.utf16.distance(from: text.utf16.startIndex, to: endIdx)
        let len = end16 - start16
        if start16 >= 0, len > 0, start16 + len <= nsLen {
            ts.addAttribute(.foregroundColor, value: SyntaxHighlight.color(for: s.kind),
                            range: NSRange(location: start16, length: len))
        }
    }
}

func applyPatchHighlight(to tv: NSTextView?) {
    guard let tv, let textStorage = tv.textStorage else { return }
    let text = tv.string
    let ranges = lineCharRanges(text)
    let lines = splitLines(text)
    textStorage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: textStorage.length))
    for (index, line) in lines.enumerated() where index < ranges.count {
        let color: NSColor?
        if line.hasPrefix("@@") {
            color = NSColor.systemBlue.withAlphaComponent(0.16)
        } else if line.hasPrefix("+++") || line.hasPrefix("---") {
            color = NSColor.systemGray.withAlphaComponent(0.12)
        } else if line.hasPrefix("+") {
            color = NSColor.systemGreen.withAlphaComponent(0.16)
        } else if line.hasPrefix("-") {
            color = NSColor.systemRed.withAlphaComponent(0.16)
        } else {
            color = nil
        }
        if let color {
            textStorage.addAttribute(.backgroundColor, value: color, range: ranges[index])
        }
    }
}

enum ApplyPatchGutterAction {
    case apply
    case copy
    case ignore
}

/// Patch editor 的轻量 gutter。IntelliJ 把逐 hunk 操作放在 Patch 编辑器
/// gutter；这里使用覆盖在 NSScrollView 上的 AppKit view，避免引入 TextKit 1
/// layout manager。行高固定为编辑器字体的默认行高，Patch pane 关闭软换行，
/// 因而 gutter 行号与 raw patch 行号保持一一对应。
final class ApplyPatchGutterView: NSView {
    static let width: CGFloat = 48

    weak var textView: NSTextView?
    var hunks: [ApplyPatchConflictHunk] = [] {
        didSet { needsDisplay = true }
    }
    var onSelect: ((ApplyPatchConflictHunk) -> Void)?
    var onApply: ((ApplyPatchConflictHunk) -> Void)?
    var onCopy: ((ApplyPatchConflictHunk) -> Void)?
    var onIgnore: ((ApplyPatchConflictHunk) -> Void)?
    var scrollOriginY: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    func update(textView: NSTextView, scrollOriginY: CGFloat) {
        self.textView = textView
        self.scrollOriginY = scrollOriginY
        needsDisplay = true
    }

    var lineHeight: CGFloat {
        max(1, ceil(textView?.font?.boundingRectForFont.height ?? 14))
    }

    func documentY(for line: Int) -> CGFloat {
        let inset = textView?.textContainerInset.height ?? 0
        return inset + CGFloat(line) * lineHeight
    }

    func visibleY(for line: Int) -> CGFloat {
        documentY(for: line) - scrollOriginY
    }

    func hunk(at point: NSPoint) -> (ApplyPatchConflictHunk, ApplyPatchGutterAction)? {
        let line = Int(floor((point.y + scrollOriginY - (textView?.textContainerInset.height ?? 0)) / lineHeight))
        guard line >= 0 else { return nil }
        guard let index = ApplyPatchConflictHunkModel.patchHunkIndex(
            in: textView?.string ?? "",
            atPatchLine: line
        ), let hunk = hunks.first(where: { $0.index == index }) else { return nil }
        let action: ApplyPatchGutterAction = point.x < Self.width / 2
            ? (hunk.resolution == .pending ? .apply : .copy)
            : .ignore
        return (hunk, action)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()

        NSColor.separatorColor.setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: bounds.maxX - 0.5, y: dirtyRect.minY))
        divider.line(to: NSPoint(x: bounds.maxX - 0.5, y: dirtyRect.maxY))
        divider.stroke()

        for hunk in hunks {
            guard let range = ApplyPatchConflictHunkModel.patchHunkLineRange(
                in: textView?.string ?? "",
                index: hunk.index
            ) else { continue }
            let y = visibleY(for: range.lowerBound)
            let row = NSRect(x: 1, y: y + 1, width: Self.width - 2, height: lineHeight - 2)
            guard row.intersects(dirtyRect) else { continue }

            drawStatusDot(at: NSPoint(x: 7, y: row.midY), resolution: hunk.resolution)
            guard !hunk.resolution.isResolved else { continue }
            let operationRect = NSRect(x: 14, y: row.minY + 2, width: 13, height: 13)
            if hunk.resolution == .pending {
                drawCheckmark(in: operationRect, enabled: true)
            } else {
                drawCopy(in: operationRect, enabled: true)
            }
            drawCross(in: NSRect(x: 31, y: row.minY + 2, width: 13, height: 13), enabled: true)
        }
    }

    func drawStatusDot(at point: NSPoint, resolution: ApplyPatchHunkResolution) {
        let color: NSColor
        switch resolution {
        case .pending: color = .systemOrange
        case .alreadyApplied, .automaticallyApplied, .applied: color = .systemGreen
        case .notApplied: color = .systemRed
        case .ignored: color = .secondaryLabelColor
        }
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)).fill()
    }

    func drawCheckmark(in rect: NSRect, enabled: Bool) {
        (enabled ? NSColor.systemGreen : NSColor.tertiaryLabelColor).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.8
        path.move(to: NSPoint(x: rect.minX + 2, y: rect.midY))
        path.line(to: NSPoint(x: rect.minX + 5, y: rect.minY + 3))
        path.line(to: NSPoint(x: rect.maxX - 2, y: rect.maxY - 3))
        path.stroke()
    }

    func drawCross(in rect: NSRect, enabled: Bool) {
        (enabled ? NSColor.systemRed : NSColor.tertiaryLabelColor).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.6
        path.move(to: NSPoint(x: rect.minX + 3, y: rect.minY + 3))
        path.line(to: NSPoint(x: rect.maxX - 3, y: rect.maxY - 3))
        path.move(to: NSPoint(x: rect.maxX - 3, y: rect.minY + 3))
        path.line(to: NSPoint(x: rect.minX + 3, y: rect.maxY - 3))
        path.stroke()
    }

    func drawCopy(in rect: NSRect, enabled: Bool) {
        (enabled ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.4
        path.appendRoundedRect(
            NSRect(x: rect.minX + 4, y: rect.minY + 2, width: 7, height: 9),
            xRadius: 1.5,
            yRadius: 1.5
        )
        path.appendRoundedRect(
            NSRect(x: rect.minX + 2, y: rect.minY + 4, width: 7, height: 9),
            xRadius: 1.5,
            yRadius: 1.5
        )
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let (hunk, action) = hunk(at: point) else {
            super.mouseDown(with: event)
            return
        }
        onSelect?(hunk)
        switch action {
        case .apply: onApply?(hunk)
        case .copy: onCopy?(hunk)
        case .ignore: onIgnore?(hunk)
        }
    }
}
