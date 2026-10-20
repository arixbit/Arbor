import SwiftUI
import AppKit


func firstConflictedPath(in entries: [FileEntry]) -> String? {
    for entry in entries {
        let stagedIsConflict = entry.staged == .conflicted
        let unstagedIsConflict = entry.unstaged == .conflicted
        if stagedIsConflict || unstagedIsConflict {
            return entry.path
        }
    }
    return nil
}

struct MultiRootMergeRollbackTarget: Identifiable {
    let rootPath: String
    let displayName: String
    let initialHead: String
    let expectedHead: String
    let operationPending: Bool

    var id: String { "\(rootPath):\(initialHead):\(expectedHead)" }
}

struct MultiRootMergeRollbackContext: Identifiable {
    let branchName: String
    let targets: [MultiRootMergeRollbackTarget]
    let failures: [String]
    let pendingRootPath: String?

    var id: String {
        "multi-root-merge:\(branchName):\(targets.map(\.id).joined(separator: "|")):\(pendingRootPath ?? "")"
    }
}

struct MultiRootMergePresentationModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var selectedRootPaths: Set<String>
    @Binding var strategy: MergeStrategyChoice
    @Binding var commitMessage: String
    @Binding var useCustomCommitMessage: Bool
    @Binding var noCommit: Bool
    @Binding var noVerify: Bool
    @Binding var allowUnrelatedHistories: Bool
    @Binding var rollbackContext: MultiRootMergeRollbackContext?
    let branchName: String
    let snapshots: [GitRootBranchSnapshot]
    let mergedBranchesByRoot: [String: Set<String>]
    let onMerge: () -> Void
    let onCancel: () -> Void
    let onRollback: ([MultiRootMergeRollbackTarget]) -> Void
    let onKeep: (MultiRootMergeRollbackContext) -> Void
    let onDone: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                RebasedMultiRootMergeDialog(
                    branchName: branchName,
                    selectedRootPaths: $selectedRootPaths,
                    strategy: $strategy,
                    commitMessage: $commitMessage,
                    useCustomCommitMessage: $useCustomCommitMessage,
                    noCommit: $noCommit,
                    noVerify: $noVerify,
                    allowUnrelatedHistories: $allowUnrelatedHistories,
                    snapshots: snapshots,
                    mergedBranchesByRoot: mergedBranchesByRoot,
                    onMerge: onMerge,
                    onCancel: onCancel
                )
            }
            .sheet(item: $rollbackContext) { context in
                RebasedMultiRootMergeRollbackView(
                    branchName: context.branchName,
                    targets: context.targets,
                    failures: context.failures,
                    onRollback: { onRollback(context.targets) },
                    onKeep: { onKeep(context) },
                    onDone: onDone
                )
            }
    }
}

/// A Find Merged result is a read-only document, but IntelliJ exposes it from
/// the operation notification after the scan has finished. Persist the
/// document itself so that a semantic "Open Report" action remains useful
/// after Arbor is relaunched, instead of silently starting a different scan.
struct PersistedFindMergedReport: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let projectPath: String
    let targetBranch: String
    let prefix: String
    let report: String
    let createdAt: Date
}

enum FindMergedReportStore {
    static let defaultsKey = "arbor.findMergedReports.v1"
    static let maximumReports = 32

    static func save(
        _ report: PersistedFindMergedReport,
        defaults: UserDefaults = .standard
    ) {
        var reports = loadAll(defaults: defaults)
        reports[report.id] = report
        let retained = reports.values
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(maximumReports)
        let encoded = Dictionary(uniqueKeysWithValues: retained.map { ($0.id, $0) })
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    static func load(
        id: String,
        defaults: UserDefaults = .standard
    ) -> PersistedFindMergedReport? {
        loadAll(defaults: defaults)[id]
    }

    static func loadAll(
        defaults: UserDefaults
    ) -> [String: PersistedFindMergedReport] {
        guard let data = defaults.data(forKey: defaultsKey),
              let reports = try? JSONDecoder().decode(
                  [String: PersistedFindMergedReport].self,
                  from: data
              ) else {
            return [:]
        }
        return reports
    }
}

// MARK: - 可编辑三栏合并编辑器（NSTextView + TextKit 2）

/// 本地解析的冲突块（行号 + 两侧内容）。编辑后行号会漂移，每次操作前重解析，不缓存。
struct SwiftConflictBlock: Identifiable {
    let index: Int          // 在当前文本中的块下标
    let lineStart: Int      // <<<<<<< 行（0-based）
    let lineEnd: Int        // >>>>>>> 行的下一行（0-based，splice 用）
    let oursLines: [String]
    let theirsLines: [String]
    var id: Int { index }
}

struct ApplyPatchConflictHunk: Identifiable, Equatable {
    let path: String
    let index: UInt32
    let header: String
    let oldStart: UInt32
    let newStart: UInt32
    let oldLines: [String]
    let newLines: [String]
    let oldChangedLines: [String]
    let newChangedLines: [String]
    var resolution: ApplyPatchHunkResolution

    var id: String { "\(path)#\(index)" }
}

/// Pure patch-hunk model used by the direct Apply Patch conflict viewer.
/// Matching is intentionally bounded around the hunk's expected line, just as
/// the differentiated patch flow does when selecting a base candidate.
enum ApplyPatchConflictHunkModel {
    static func editorPatchText(patch: String, path: String) -> String {
        RebasedUnshelveDialog
            .parsePatchFiles(patch, allowedPaths: [path])
            .first(where: { $0.path == path })?
            .rawPatch ?? patch
    }

    static func patchHunkLineRange(in patchText: String, index: UInt32) -> Range<Int>? {
        let lines = splitLines(patchText)
        let headers = lines.indices.filter { lines[$0].hasPrefix("@@") }
        let hunkIndex = Int(index)
        guard hunkIndex >= 0, hunkIndex < headers.count else { return nil }
        let start = headers[hunkIndex]
        let end = headers.drop { $0 <= start }.first ?? lines.count
        return start..<end
    }

    static func patchHunkIndex(in patchText: String, atPatchLine line: Int) -> UInt32? {
        guard line >= 0 else { return nil }
        let lines = splitLines(patchText)
        let headers = lines.indices.filter { lines[$0].hasPrefix("@@") }
        guard let index = headers.firstIndex(of: line) else { return nil }
        return UInt32(index)
    }

    static func clipboardText(for hunk: ApplyPatchConflictHunk) -> String? {
        let lines = hunk.newChangedLines.isEmpty ? hunk.newLines : hunk.newChangedLines
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n") + "\n"
    }

    static func restoredResolution(
        for hunk: ApplyPatchConflictHunk,
        from persisted: [ShelveRestoreHunkResolution]
    ) -> ApplyPatchHunkResolution? {
        guard let item = persisted.first(where: {
            $0.path == hunk.path && $0.hunkIndex == hunk.index
        }) else { return nil }
        switch item.resolution {
        case "applied": return .applied
        case "automatically_applied": return .automaticallyApplied
        case "ignored": return .ignored
        default: return nil
        }
    }

    static func parse(patch: String, path: String, result: String) -> [ApplyPatchConflictHunk] {
        guard let file = RebasedUnshelveDialog
            .parsePatchFiles(patch, allowedPaths: [path])
            .first(where: { $0.path == path }),
            let diff = RebasedPatchDiffParser.parse(patch: file.rawPatch, path: path) else {
            return []
        }

        return diff.hunks.enumerated().map { offset, hunk in
            let oldLines = hunk.oldLines.map(\.text)
            let newLines = hunk.newLines.map(\.text)
            let oldChangedLines = hunk.oldLines
                .filter { $0.kind == .deletion }
                .map(\.text)
            let newChangedLines = hunk.newLines
                .filter { $0.kind == .addition }
                .map(\.text)
            let header = file.hunks.indices.contains(offset)
                ? file.hunks[offset].header
                : "@@ -\(hunk.oldStart) +\(hunk.newStart) @@"
            var item = ApplyPatchConflictHunk(
                path: path,
                index: UInt32(offset),
                header: header,
                oldStart: hunk.oldStart,
                newStart: hunk.newStart,
                oldLines: oldLines,
                newLines: newLines,
                oldChangedLines: oldChangedLines,
                newChangedLines: newChangedLines,
                resolution: .notApplied
            )
            item.resolution = status(of: item, in: result)
            return item
        }
    }

    static func status(
        of hunk: ApplyPatchConflictHunk,
        in text: String
    ) -> ApplyPatchHunkResolution {
        let lines = splitLines(text)
        let oldExpected = Int(hunk.oldStart == 0 ? 0 : hunk.oldStart - 1)
        let newExpected = Int(hunk.newStart == 0 ? 0 : hunk.newStart - 1)

        if !hunk.oldLines.isEmpty,
           findLineRange(hunk.oldLines, in: lines, expectedStart: oldExpected) != nil {
            return .pending
        }
        if findLineRange(hunk.newLines, in: lines, expectedStart: newExpected) != nil {
            return .alreadyApplied
        }
        if hunk.oldLines.isEmpty, oldExpected <= lines.count {
            return .pending
        }
        return .notApplied
    }

    static func findLineRange(
        _ sequence: [String],
        in lines: [String],
        expectedStart: Int,
        maxWalk: Int = 100
    ) -> Range<Int>? {
        if sequence.isEmpty {
            guard expectedStart >= 0, expectedStart <= lines.count else { return nil }
            return expectedStart..<expectedStart
        }
        guard sequence.count <= lines.count else { return nil }
        let lastStart = lines.count - sequence.count
        let lower = max(0, expectedStart - maxWalk)
        let upper = min(lastStart, expectedStart + maxWalk)
        guard lower <= upper else { return nil }
        for start in lower...upper {
            if Array(lines[start..<(start + sequence.count)]) == sequence {
                return start..<(start + sequence.count)
            }
        }
        return nil
    }
}

/// 解析冲突 marker 成块（与引擎 parse_marker_blocks 同语义）。
func parseConflictMarkers(_ text: String) -> [SwiftConflictBlock] {
    let lines = splitLines(text)
    var blocks: [SwiftConflictBlock] = []
    var i = 0
    var blockIdx = 0
    while i < lines.count {
        if lines[i].hasPrefix("<<<<<<<") {
            let start = i
            i += 1
            var ours: [String] = []
            while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces) != "=======" {
                ours.append(lines[i]); i += 1
            }
            if i >= lines.count { break }
            i += 1 // 跳过 =======
            var theirs: [String] = []
            while i < lines.count && !lines[i].hasPrefix(">>>>>>>") {
                theirs.append(lines[i]); i += 1
            }
            if i >= lines.count { break }
            let end = i + 1 // >>>>>>> 行的下一行
            blocks.append(SwiftConflictBlock(index: blockIdx, lineStart: start, lineEnd: end,
                                             oursLines: ours, theirsLines: theirs))
            blockIdx += 1
            i = end
        } else {
            i += 1
        }
    }
    return blocks
}

/// NSTextView 的命令式桥接（SwiftUI <-> AppKit）。
/// 持有结果栏 NSTextView 弱引用；块操作直接改文本；保存时读 getResultText()。
/// 铁律：绝不访问 TextKit 1 布局管理器（防降级）；着色走 textStorage 属性。
final class MergeEditorBridge: ObservableObject {
    weak var resultTextView: NSTextView?
    weak var patchTextView: NSTextView?
    /// 文件路径（语法高亮 grammar 选取用）
    var path: String = ""
    /// 当前块列表（重解析后刷新；SwiftUI 观察）
    @Published var blocks: [SwiftConflictBlock] = []
    /// Result text revision, including edits that do not change the number of
    /// marker blocks. Apply Patch uses it to refresh hunk status.
    @Published var resultRevision = 0
    /// NSTextView selection revision, so toolbar actions can follow an editor
    /// range in addition to an explicitly selected hunk chip.
    @Published var selectionRevision = 0
    var resultEditGroupActionName: String?
    var resultEditingEnabled = true

    func attachResult(_ tv: NSTextView) {
        resultTextView = tv
        tv.isEditable = resultEditingEnabled
        applyColoring()
        refreshBlocks()
    }

    func attachPatch(_ tv: NSTextView?) {
        patchTextView = tv
    }

    func getResultText() -> String { resultTextView?.string ?? "" }

    func setResultEditingEnabled(_ enabled: Bool) {
        resultEditingEnabled = enabled
        resultTextView?.isEditable = enabled
    }

    @discardableResult
    func replaceResultText(_ text: String, actionName: String) -> Bool {
        guard let tv = resultTextView else { return false }
        let previous = tv.string
        guard previous != text else { return false }

        // NSTextView.string is a bulk replacement and does not reliably
        // register an undo item. The IntelliJ viewer wraps every hunk action
        // in a command, so keep the same boundary explicitly and suppress a
        // possible duplicate TextKit registration for the bulk assignment.
        if let undoManager = tv.undoManager {
            undoManager.registerUndo(withTarget: self) { target in
                target.replaceResultText(previous, actionName: actionName)
            }
            undoManager.setActionName(actionName)
            undoManager.disableUndoRegistration()
            tv.string = text
            undoManager.enableUndoRegistration()
        } else {
            tv.string = text
        }
        applyColoring()
        refreshBlocks()
        return true
    }

    func beginResultEditGroup(_ actionName: String) {
        guard let undoManager = resultTextView?.undoManager else { return }
        resultEditGroupActionName = actionName
        undoManager.beginUndoGrouping()
    }

    func endResultEditGroup() {
        guard let undoManager = resultTextView?.undoManager else { return }
        if let actionName = resultEditGroupActionName {
            undoManager.setActionName(actionName)
        }
        undoManager.endUndoGrouping()
        resultEditGroupActionName = nil
    }

    func canApplyPatchHunk(_ hunk: ApplyPatchConflictHunk) -> Bool {
        let text = getResultText()
        let lines = splitLines(text)
        let expected = Int(hunk.oldStart == 0 ? 0 : hunk.oldStart - 1)
        if ApplyPatchConflictHunkModel.findLineRange(
            hunk.oldLines,
            in: lines,
            expectedStart: expected
        ) != nil {
            return true
        }
        return conflictBlockIndex(for: hunk, side: .theirs) != nil
    }

    @discardableResult
    func applyPatchHunk(_ hunk: ApplyPatchConflictHunk) -> ApplyPatchHunkResolution {
        guard let tv = resultTextView else { return .notApplied }
        let text = tv.string
        let lines = splitLines(text)
        // A conflict marker contains the local old line verbatim. Prefer the
        // marker-level resolution before the generic line splice, otherwise
        // applying a hunk would leave half of the marker block behind.
        if let blockIndex = conflictBlockIndex(for: hunk, side: .theirs) {
            acceptBlock(blockIndex, .theirs)
            return .applied
        }
        let expected = Int(hunk.oldStart == 0 ? 0 : hunk.oldStart - 1)
        if let range = ApplyPatchConflictHunkModel.findLineRange(
            hunk.oldLines,
            in: lines,
            expectedStart: expected
        ) {
            var updated = lines
            updated.replaceSubrange(range, with: hunk.newLines)
            _ = replaceResultText(
                joinLines(updated, trailingNewline: text.hasSuffix("\n")),
                actionName: "Apply Patch Change"
            )
            return .applied
        }
        let newExpected = Int(hunk.newStart == 0 ? 0 : hunk.newStart - 1)
        if ApplyPatchConflictHunkModel.findLineRange(
            hunk.newLines,
            in: lines,
            expectedStart: newExpected
        ) != nil {
            return .alreadyApplied
        }
        return .notApplied
    }

    /// Ignore is a resolved patch decision even if the result has no matching
    /// marker block (for example, a hunk already removed by manual editing).
    @discardableResult
    func ignorePatchHunk(_ hunk: ApplyPatchConflictHunk) -> Bool {
        guard let blockIndex = conflictBlockIndex(for: hunk, side: .ours) else {
            return true
        }
        acceptBlock(blockIndex, .ours)
        return true
    }

    func isHunkSelected(_ hunk: ApplyPatchConflictHunk) -> Bool {
        if let tv = resultTextView,
           let selected = selectionLineRange(in: tv),
           resultSelectionMatches(selected, hunk: hunk) {
            return true
        }
        guard let tv = patchTextView,
              let selected = selectionLineRange(in: tv),
              let patchRange = ApplyPatchConflictHunkModel.patchHunkLineRange(
                  in: tv.string,
                  index: hunk.index
              ) else { return false }
        return patchRange.lowerBound < selected.upperBound
            && selected.lowerBound < patchRange.upperBound
    }

    func selectionLineRange(in tv: NSTextView) -> Range<Int>? {
        let selection = tv.selectedRange()
        guard selection.length > 0 else { return nil }
        let text = tv.string
        let ranges = lineCharRanges(text)
        guard !ranges.isEmpty else { return nil }

        func line(at offset: Int) -> Int {
            let bounded = min(max(0, offset), (text as NSString).length)
            return ranges.firstIndex(where: { NSMaxRange($0) > bounded })
                ?? max(0, ranges.count - 1)
        }
        let start = line(at: selection.location)
        let end = line(at: selection.location + selection.length - 1)
        return start..<(end + 1)
    }

    func resultSelectionMatches(
        _ selected: Range<Int>,
        hunk: ApplyPatchConflictHunk
    ) -> Bool {
        let text = getResultText()
        let markerBlocks = parseConflictMarkers(text)
        for side in [AcceptSide.ours, AcceptSide.theirs] {
            if let blockIndex = conflictBlockIndex(for: hunk, side: side),
               let block = markerBlocks.first(where: { $0.index == blockIndex }),
               block.lineStart < selected.upperBound,
               selected.lowerBound < block.lineEnd {
                return true
            }
        }
        let expectedOld = Int(hunk.oldStart == 0 ? 0 : hunk.oldStart - 1)
        let expectedNew = Int(hunk.newStart == 0 ? 0 : hunk.newStart - 1)
        let oldRange = ApplyPatchConflictHunkModel.findLineRange(
            hunk.oldLines,
            in: splitLines(text),
            expectedStart: expectedOld
        )
        let newRange = ApplyPatchConflictHunkModel.findLineRange(
            hunk.newLines,
            in: splitLines(text),
            expectedStart: expectedNew
        )
        return [oldRange, newRange].compactMap { $0 }.contains { range in
            range.lowerBound < selected.upperBound
                && selected.lowerBound < range.upperBound
        }
    }

    func revealPatchHunk(_ hunk: ApplyPatchConflictHunk) {
        let resultText = getResultText()
        let resultLines: Range<Int>? = {
            let blocks = parseConflictMarkers(resultText)
            if let blockIndex = conflictBlockIndex(for: hunk, side: .theirs),
               let block = blocks.first(where: { $0.index == blockIndex }) {
                return block.lineStart..<block.lineEnd
            }
            let oldExpected = Int(hunk.oldStart == 0 ? 0 : hunk.oldStart - 1)
            let newExpected = Int(hunk.newStart == 0 ? 0 : hunk.newStart - 1)
            return ApplyPatchConflictHunkModel.findLineRange(
                hunk.oldLines,
                in: splitLines(resultText),
                expectedStart: oldExpected
            ) ?? ApplyPatchConflictHunkModel.findLineRange(
                hunk.newLines,
                in: splitLines(resultText),
                expectedStart: newExpected
            )
        }()
        if let resultTextView,
           let resultLines,
           let range = characterRange(for: resultLines, in: resultText) {
            resultTextView.scrollRangeToVisible(range)
        }
        if let patchTextView,
           let patchLines = ApplyPatchConflictHunkModel.patchHunkLineRange(
               in: patchTextView.string,
               index: hunk.index
           ),
           let range = characterRange(for: patchLines, in: patchTextView.string) {
            patchTextView.scrollRangeToVisible(range)
        }
    }

    /// 接受第 i 个块：重解析当前文本定位（编辑后行号漂移），按行替换（同引擎 resolve 语义）。
    func acceptBlock(_ index: Int, _ side: AcceptSide) {
        guard let tv = resultTextView else { return }
        let text = tv.string
        let parsed = parseConflictMarkers(text)
        guard index >= 0, index < parsed.count else { return }
        let b = parsed[index]
        var lines = splitLines(text)
        lines.replaceSubrange(b.lineStart..<b.lineEnd, with: pickedLines(b, side))
        _ = replaceResultText(
            joinLines(lines, trailingNewline: text.hasSuffix("\n")),
            actionName: side == .ours ? "Keep Local Conflict Change" : "Apply Conflict Change"
        )
    }

    /// 全部块按同一方向接受（倒序替换避免行号漂移）。
    func acceptAll(_ side: AcceptSide) {
        guard let tv = resultTextView else { return }
        let text = tv.string
        let parsed = parseConflictMarkers(text)
        var lines = splitLines(text)
        for b in parsed.reversed() {
            lines.replaceSubrange(b.lineStart..<b.lineEnd, with: pickedLines(b, side))
        }
        _ = replaceResultText(
            joinLines(lines, trailingNewline: text.hasSuffix("\n")),
            actionName: side == .ours ? "Keep All Local Changes" : "Apply All Conflict Changes"
        )
    }

    func pickedLines(_ b: SwiftConflictBlock, _ side: AcceptSide) -> [String] {
        switch side {
        case .ours: return b.oursLines
        case .theirs: return b.theirsLines
        case .both: return b.oursLines + b.theirsLines
        }
    }

    func joinLines(_ lines: [String], trailingNewline: Bool) -> String {
        lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
    }

    /// 冲突区域着色（textStorage 背景色；不碰 TextKit 1 布局管理器）。
    func applyColoring() {
        guard let tv = resultTextView, let ts = tv.textStorage else { return }
        let text = tv.string
        let ranges = lineCharRanges(text)
        let blocks = parseConflictMarkers(text)
        ts.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: ts.length))
        let markerColor = NSColor.systemGray.withAlphaComponent(0.28)
        let oursColor = NSColor.systemRed.withAlphaComponent(0.16)
        let theirsColor = NSColor.systemGreen.withAlphaComponent(0.16)
        for b in blocks {
            let sepLine = b.lineStart + 1 + b.oursLines.count // ======= 行
            colorLines(ranges, line: b.lineStart, count: 1, color: markerColor, ts: ts)        // <<<<<<<
            colorLines(ranges, line: sepLine, count: 1, color: markerColor, ts: ts)             // =======
            colorLines(ranges, line: b.lineEnd - 1, count: 1, color: markerColor, ts: ts)       // >>>>>>>
            colorLines(ranges, line: b.lineStart + 1, count: b.oursLines.count, color: oursColor, ts: ts)
            colorLines(ranges, line: sepLine + 1, count: b.theirsLines.count, color: theirsColor, ts: ts)
        }
        // 语法高亮前景色叠加（冲突背景之后；冲突标记行无语法色不影响）
        applySyntaxHighlight(to: tv, path: path)
    }

    func colorLines(_ ranges: [NSRange], line: Int, count: Int, color: NSColor, ts: NSTextStorage) {
        guard count > 0, line >= 0, line + count <= ranges.count else { return }
        let start = ranges[line].location
        let last = ranges[line + count - 1]
        let end = last.location + last.length
        ts.addAttribute(.backgroundColor, value: color, range: NSRange(location: start, length: end - start))
    }

    func refreshBlocks() {
        blocks = parseConflictMarkers(resultTextView?.string ?? "")
        resultRevision &+= 1
    }

    func conflictBlockIndex(
        for hunk: ApplyPatchConflictHunk,
        side: AcceptSide
    ) -> Int? {
        let text = getResultText()
        let blocks = parseConflictMarkers(text)
        let preferred = side == .theirs ? hunk.newChangedLines : hunk.oldChangedLines
        let fallback = side == .theirs ? hunk.oldChangedLines : hunk.newChangedLines
        guard !preferred.isEmpty || !fallback.isEmpty else { return nil }
        let expectedLine = Int(
            side == .theirs
                ? (hunk.newStart == 0 ? 0 : hunk.newStart - 1)
                : (hunk.oldStart == 0 ? 0 : hunk.oldStart - 1)
        )

        var best: (index: Int, score: Int, distance: Int)?
        for block in blocks {
            let primaryLines = side == .theirs ? block.theirsLines : block.oursLines
            let secondaryLines = side == .theirs ? block.oursLines : block.theirsLines
            let primaryScore = preferred.filter(primaryLines.contains).count
            let secondaryScore = fallback.filter(secondaryLines.contains).count
            let score = primaryScore * 2 + secondaryScore
            guard score > 0 else { continue }
            let distance = abs(block.lineStart - expectedLine)
            if best == nil || score > best!.score
                || (score == best!.score && distance < best!.distance) {
                best = (block.index, score, distance)
            }
        }
        return best?.index
    }
}

/// 普通冲突为三栏 NSTextView；direct Apply Patch 为结果/patch 双栏，均由
/// NSViewRepresentable 包进 SwiftUI。
struct MergeEditorView: NSViewRepresentable {
    let ours: String
    let theirs: String
    let initialResult: String
    let path: String
    let bridge: MergeEditorBridge
    let patchText: String?
    let patchHunks: [ApplyPatchConflictHunk]
    let onSelectPatchHunk: (ApplyPatchConflictHunk) -> Void
    let onApplyPatchHunk: (ApplyPatchConflictHunk) -> Void
    let onCopyPatchHunk: (ApplyPatchConflictHunk) -> Void
    let onIgnorePatchHunk: (ApplyPatchConflictHunk) -> Void
    /// 外部重载令牌：刷新/切文件时递增，updateNSView 据此同步（不覆盖用户编辑）。
    let reloadToken: Int

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        if let patchText {
            let (resultScroll, resultTV) = Self.makePane(readOnly: false, tint: nil)
            let (patchScroll, patchTV) = Self.makePane(
                readOnly: true,
                tint: NSColor.systemGray.withAlphaComponent(0.05)
            )
            patchTV.textContainerInset = NSSize(width: ApplyPatchGutterView.width + 8, height: 6)
            patchTV.isHorizontallyResizable = true
            patchTV.textContainer?.widthTracksTextView = false
            patchTV.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            resultTV.string = initialResult
            patchTV.string = ApplyPatchConflictHunkModel.editorPatchText(
                patch: patchText,
                path: path
            )
            resultTV.delegate = context.coordinator
            patchTV.delegate = context.coordinator
            context.coordinator.resultScroll = resultScroll
            context.coordinator.patchScroll = patchScroll
            context.coordinator.attachScrolls(result: resultScroll, patch: patchScroll)
            context.coordinator.resultTV = resultTV
            context.coordinator.patchTV = patchTV
            context.coordinator.oursTV = nil
            context.coordinator.theirsTV = nil
            context.coordinator.lastReloadToken = reloadToken
            bridge.path = path
            bridge.attachResult(resultTV)
            bridge.attachPatch(patchTV)
            applyPatchHighlight(to: patchTV)

            let gutter = ApplyPatchGutterView(frame: NSRect(
                x: 0,
                y: 0,
                width: ApplyPatchGutterView.width,
                height: patchScroll.bounds.height
            ))
            gutter.hunks = patchHunks
            gutter.onSelect = onSelectPatchHunk
            gutter.onApply = onApplyPatchHunk
            gutter.onCopy = onCopyPatchHunk
            gutter.onIgnore = onIgnorePatchHunk
            context.coordinator.attachPatchGutter(gutter, to: patchScroll, textView: patchTV)

            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.distribution = .fillEqually
            stack.spacing = 1
            stack.addView(Self.wrap(resultScroll, title: "结果（可编辑）", color: .orange), in: .center)
            stack.addView(Self.wrap(patchScroll, title: "Patch（只读）", color: .blue), in: .center)
            stack.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: container.topAnchor),
                stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
            return container
        }
        let (oursScroll, oursTV) = Self.makePane(readOnly: true, tint: NSColor.systemRed.withAlphaComponent(0.05))
        let (resultScroll, resultTV) = Self.makePane(readOnly: false, tint: nil)
        let (theirsScroll, theirsTV) = Self.makePane(readOnly: true, tint: NSColor.systemGreen.withAlphaComponent(0.05))
        oursTV.string = ours
        theirsTV.string = theirs
        resultTV.string = initialResult
        applySyntaxHighlight(to: oursTV, path: path)
        applySyntaxHighlight(to: theirsTV, path: path)
        resultTV.delegate = context.coordinator
        context.coordinator.resultTV = resultTV
        context.coordinator.patchTV = nil
        context.coordinator.patchGutter = nil
        context.coordinator.resultScroll = nil
        context.coordinator.patchScroll = nil
        context.coordinator.clearScrolls()
        context.coordinator.oursTV = oursTV
        context.coordinator.theirsTV = theirsTV
        context.coordinator.lastReloadToken = reloadToken
        bridge.path = path
        bridge.attachResult(resultTV)
        bridge.attachPatch(nil)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 1
        stack.addView(Self.wrap(oursScroll, title: "本地 (ours)", color: .red), in: .center)
        stack.addView(Self.wrap(resultScroll, title: "结果（可编辑）", color: .orange), in: .center)
        stack.addView(Self.wrap(theirsScroll, title: "远程 (theirs)", color: .green), in: .center)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.patchGutter?.hunks = patchHunks
        context.coordinator.patchGutter?.onSelect = onSelectPatchHunk
        context.coordinator.patchGutter?.onApply = onApplyPatchHunk
        context.coordinator.patchGutter?.onCopy = onCopyPatchHunk
        context.coordinator.patchGutter?.onIgnore = onIgnorePatchHunk
        // 仅在外部重载（reloadToken 变化）时同步当前编辑器的内容；用户编辑/块操作不触发。
        guard context.coordinator.lastReloadToken != reloadToken else { return }
        if let patchText {
            context.coordinator.resultTV?.string = initialResult
            context.coordinator.patchTV?.string = ApplyPatchConflictHunkModel.editorPatchText(
                patch: patchText,
                path: path
            )
            applyPatchHighlight(to: context.coordinator.patchTV)
            context.coordinator.lastReloadToken = reloadToken
            bridge.path = path
            bridge.applyColoring()
            bridge.refreshBlocks()
            return
        }
        context.coordinator.oursTV?.string = ours
        context.coordinator.theirsTV?.string = theirs
        applySyntaxHighlight(to: context.coordinator.oursTV, path: path)
        applySyntaxHighlight(to: context.coordinator.theirsTV, path: path)
        context.coordinator.resultTV?.string = initialResult
        context.coordinator.lastReloadToken = reloadToken
        bridge.path = path
        bridge.applyColoring()
        bridge.refreshBlocks()
    }

    func makeCoordinator() -> Coordinator { Coordinator(bridge: bridge) }

    static func makePane(readOnly: Bool, tint: NSColor?) -> (NSScrollView, NSTextView) {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        let textView = NSTextView()
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isEditable = !readOnly
        textView.allowsUndo = !readOnly
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = tint ?? .textBackgroundColor
        textView.textColor = .labelColor
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        return (scrollView, textView)
    }

    static func wrap(_ view: NSView, title: String, color: Color) -> NSView {
        let container = NSView()
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        label.textColor = NSColor(color)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        container.addSubview(view)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            view.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var resultTV: NSTextView?
        weak var patchTV: NSTextView?
        weak var patchGutter: ApplyPatchGutterView?
        weak var resultScroll: NSScrollView?
        weak var patchScroll: NSScrollView?
        weak var oursTV: NSTextView?
        weak var theirsTV: NSTextView?
        var syncingScroll = false
        var scrollObservers: [NSObjectProtocol] = []
        var lastReloadToken = 0
        let bridge: MergeEditorBridge
        init(bridge: MergeEditorBridge) { self.bridge = bridge }

        func textDidChange(_ notification: Notification) {
            // 延迟刷新块列表（避免在文本变更通知中重入；合并连续输入）。
            // 着色不在此重算——textStorage 背景属性随文本持久，块操作/重载时重算即可。
            DispatchQueue.main.async { [weak self] in
                self?.bridge.refreshBlocks()
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            bridge.selectionRevision &+= 1
        }

        func attachScrolls(result: NSScrollView, patch: NSScrollView) {
            clearScrolls()
            for clipView in [result.contentView, patch.contentView] {
                clipView.postsBoundsChangedNotifications = true
                let observer = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clipView,
                    queue: .main
                ) { [weak self] notification in
                    self?.syncScroll(for: notification)
                }
                scrollObservers.append(observer)
            }
        }

        func attachPatchGutter(
            _ gutter: ApplyPatchGutterView,
            to scroll: NSScrollView,
            textView: NSTextView
        ) {
            patchGutter = gutter
            gutter.autoresizingMask = [.height]
            scroll.addSubview(gutter, positioned: .above, relativeTo: scroll.contentView)
            gutter.frame = NSRect(
                x: 0,
                y: 0,
                width: ApplyPatchGutterView.width,
                height: scroll.bounds.height
            )
            gutter.update(
                textView: textView,
                scrollOriginY: scroll.contentView.bounds.origin.y
            )
        }

        func clearScrolls() {
            for observer in scrollObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            scrollObservers.removeAll()
        }

        deinit {
            clearScrolls()
        }

        func syncScroll(for notification: Notification) {
            guard !syncingScroll,
                  let source = notification.object as? NSClipView else { return }
            let targetScroll = source === resultScroll?.contentView ? patchScroll : resultScroll
            guard let target = targetScroll, source !== target.contentView else { return }
            let sourceMax = max(
                0,
                source.documentRect.height - source.bounds.height
            )
            let targetMax = max(
                0,
                (target.documentView?.bounds.height ?? 0) - target.contentView.bounds.height
            )
            let fraction = sourceMax > 0
                ? source.bounds.origin.y / sourceMax
                : 0
            syncingScroll = true
            var origin = target.contentView.bounds.origin
            origin.y = min(targetMax, max(0, fraction * targetMax))
            target.contentView.setBoundsOrigin(origin)
            target.reflectScrolledClipView(target.contentView)
            if let patchGutter, let patchTV, let patchScroll {
                patchGutter.update(
                    textView: patchTV,
                    scrollOriginY: patchScroll.contentView.bounds.origin.y
                )
            }
            syncingScroll = false
        }
    }
}

// MARK: - 冲突三栏视图（可编辑）

func isCurrentConflictLoadRequest(
    repositoryID: String,
    path: String,
    generation: Int,
    currentRepositoryID: String?,
    currentPath: String,
    currentGeneration: Int
) -> Bool {
    repositoryID == currentRepositoryID
        && path == currentPath
        && generation == currentGeneration
}

struct ConflictDetailView: View {
    let repo: Repository?
    let path: String
    let onChanged: () -> Void
    /// Direct Apply Patch conflicts use the same Git conflict stages, but the
    /// second side is the patch rather than a branch or shelf. Keep the
    /// original effective patch available for an IntelliJ-style preview.
    let patchText: String?
    /// Restore snapshot name used to persist per-hunk Apply Patch decisions.
    let restoreName: String?

    init(
        repo: Repository?,
        path: String,
        patchText: String? = nil,
        restoreName: String? = nil,
        onChanged: @escaping () -> Void
    ) {
        self.repo = repo
        self.path = path
        self.patchText = patchText
        self.restoreName = restoreName
        self.onChanged = onChanged
    }

    @State var conflict: ConflictFile?
    @State var conflictBatchPreview: ConflictBatchPreview?
    @State var conflictIsBinary = false
    @State var conflictError: String?
    @State var feedback: String?
    @State var saving = false
    @State var externalToolWorking = false
    @State var externalToolCancelling = false
    @State var externalToolCancelHandle: GitCancelHandle?
    @State var showExternalToolSettings = false
    @State var selectedBlock = 0
    @State var patchHunks: [ApplyPatchConflictHunk] = []
    @State var selectedPatchHunkID: String?
    @State var showBase = false
    @State var showPatchPreview = false
    @State var showLocalDiff = false
    @State var patchPreviewPresentationMode: DiffPresentationMode = .sideBySide
    @State var localDiffPresentationMode: DiffPresentationMode = .sideBySide
    @State var localDiff: FileDiff?
    @State var localDiffLoading = false
    @State var localDiffError: String?
    @State var showPartialResolveConfirmation = false
    @State var pendingResolveContent: String?
    @State var reloadToken = 0
    @State var loadGeneration = 0
    @StateObject var bridge = MergeEditorBridge()

    var isPatchMode: Bool { patchText != nil }

    var selectedPatchHunk: ApplyPatchConflictHunk? {
        guard isPatchMode else { return nil }
        return patchHunks.first { $0.id == selectedPatchHunkID }
    }

    var editorSelectedPatchHunk: ApplyPatchConflictHunk? {
        guard isPatchMode else { return nil }
        return patchHunks.first { bridge.isHunkSelected($0) }
    }

    var editorSelectedPatchHunks: [ApplyPatchConflictHunk] {
        guard isPatchMode else { return [] }
        return patchHunks.filter { bridge.isHunkSelected($0) }
    }

    var actionPatchHunks: [ApplyPatchConflictHunk] {
        if !editorSelectedPatchHunks.isEmpty {
            return editorSelectedPatchHunks
        }
        return selectedPatchHunk.map { [$0] } ?? []
    }

    var unresolvedPatchHunks: [ApplyPatchConflictHunk] {
        patchHunks.filter { !$0.resolution.isResolved }
    }

    var patchPreviewDiff: FileDiff? {
        guard let patchText else { return nil }
        let file = RebasedUnshelveDialog.parsePatchFiles(
            patchText,
            allowedPaths: [path]
        ).first { $0.path == path }
        guard let file else { return nil }
        return RebasedPatchDiffParser.parse(patch: file.rawPatch, path: path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text((isPatchMode ? "补丁冲突：" : "冲突：") + path)
                    .font(.headline).lineLimit(1)
                Spacer()
                if patchText != nil {
                    Button("Patch") { showPatchPreview = true }
                        .help("查看当前 Apply Patch 冲突的实际补丁")
                    Button("Local Diff") { loadLocalDiff() }
                        .help("比较本地冲突阶段与当前结果编辑器")
                }
                Button("Reset") { resetConflictFile() }
                    .help("从 index stages 重新生成冲突 marker，并清理当前文件的 hunk 决策")
                    .disabled(conflict == nil || conflictIsBinary || saving)
                if !isPatchMode {
                    Button("Accept Both") { acceptFile(.both) }
                        .help("保留双方内容（ours 在上）")
                        .disabled(conflict == nil || conflictIsBinary)
                    Button("Base") { showBase = true }
                        .help("查看共同祖先版本")
                        .disabled(conflict == nil || conflictIsBinary)
                    Button(externalToolWorking ? (externalToolCancelling ? "Canceling…" : "Cancel") : "External Tool") {
                        if externalToolWorking {
                            externalToolCancelling = true
                            externalToolCancelHandle?.cancel()
                        } else {
                            openExternalTool()
                        }
                    }
                    .help("Run Git's configured external merge tool")
                    .disabled(
                        externalToolCancelling
                            || saving
                            || repo == nil
                            || conflict == nil
                    )
                    Button("Settings…") { showExternalToolSettings = true }
                        .disabled(repo == nil || externalToolWorking || saving)
                }
                Button("刷新") { load() }
                Button(saving ? "保存中…" : "标记已解决") { markResolved() }
                    .disabled(saving || repo == nil || conflict == nil || conflictIsBinary)
            }
            .padding(10)
            Divider()
            if let conflictError {
                Text(conflictError).foregroundStyle(.red).padding()
                Spacer()
            } else if conflict == nil, let feedback {
                Label(feedback, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .padding()
                Spacer()
            } else if conflictIsBinary {
                binaryConflictView
            } else if let conflict {
                MergeEditorView(ours: conflict.ours, theirs: conflict.theirs,
                                initialResult: conflict.result, path: path, bridge: bridge,
                                patchText: patchText,
                                patchHunks: patchHunks,
                                onSelectPatchHunk: { selectedPatchHunkID = $0.id },
                                onApplyPatchHunk: { applySelectedPatchHunk($0) },
                                onCopyPatchHunk: { copyPatchHunk($0) },
                                onIgnorePatchHunk: { ignoreSelectedPatchHunk($0) },
                                reloadToken: reloadToken)
                Divider()
                if isPatchMode {
                    applyPatchToolbar
                } else {
                    blockToolbar
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { load() }
        .onChange(of: path) { _, _ in load() }
        .onChange(of: repo?.gitDir()) { _, _ in load() }
        .onChange(of: bridge.blocks.count) { _, n in
            if selectedBlock >= n { selectedBlock = max(0, n - 1) }
        }
        .onChange(of: bridge.resultRevision) { _, _ in
            if isPatchMode { refreshUnresolvedPatchHunks() }
        }
        .onChange(of: bridge.selectionRevision) { _, _ in
            guard isPatchMode, let hunk = editorSelectedPatchHunk else { return }
            if selectedPatchHunkID != hunk.id {
                selectedPatchHunkID = hunk.id
            }
            bridge.revealPatchHunk(hunk)
        }
        .onChange(of: selectedPatchHunkID) { _, _ in
            guard isPatchMode, let hunk = selectedPatchHunk else { return }
            bridge.revealPatchHunk(hunk)
        }
        .sheet(isPresented: $showBase) { baseSheet }
        .sheet(isPresented: $showPatchPreview) { patchPreviewSheet }
        .sheet(isPresented: $showLocalDiff) { localDiffSheet }
        .sheet(isPresented: $showExternalToolSettings) {
            if let repo {
                GitMergeToolSettingsView(
                    repo: repo,
                    onSaved: { showExternalToolSettings = false },
                    onCancel: { showExternalToolSettings = false }
                )
            }
        }
        .alert("Patch changes remain unresolved", isPresented: $showPartialResolveConfirmation) {
            Button("Finish Anyway", role: .destructive) {
                let content = pendingResolveContent
                pendingResolveContent = nil
                guard let content else { return }
                resolveEditedContent(content, allowConflictMarkers: true)
            }
            Button("Continue Editing", role: .cancel) {
                pendingResolveContent = nil
            }
        } message: {
            Text("\(unresolvedPatchHunks.count) patch change(s) are still unresolved. Finish the file anyway, or continue editing.")
        }
    }

    var binaryConflictView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Binary Conflict", systemImage: "doc.badge.gearshape")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.orange)
            Text(isPatchMode
                 ? "This file cannot be merged in the text editor. Keep the local file or apply the complete patch side."
                 : "This file cannot be merged in the text editor. Choose which complete version to keep.")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(isPatchMode ? "Keep Local" : "Accept Ours") { acceptFile(.ours) }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving)
                Button(isPatchMode ? "Apply Patch" : "Accept Theirs") { acceptFile(.theirs) }
                    .buttonStyle(.bordered)
                    .disabled(saving)
            }
            Text("Accept Both, Reset, manual editing, and Base are unavailable for binary conflicts to avoid corrupting the file.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
    }

    var blockToolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("全部接受本地") { acceptAllBlocks(.ours) }
                Button("全部接受远程") { acceptAllBlocks(.theirs) }
                Button("Resolve Simple") { applyConflictBatch(.resolveSimple) }
                    .help("Resolve all conflict blocks whose two sides are identical")
                    .disabled(saving || bridge.blocks.isEmpty)
                Button("Apply Left Non-conflicts") {
                    applyConflictBatch(.applyOursNonConflicting)
                }
                    .help("Apply only non-conflicting changes from the local side")
                    .disabled(saving || bridge.blocks.isEmpty)
                Button("Apply Right Non-conflicts") {
                    applyConflictBatch(.applyTheirsNonConflicting)
                }
                    .help("Apply only non-conflicting changes from the remote side")
                    .disabled(saving || bridge.blocks.isEmpty)
                Spacer()
                Button("↑") { navigateBlock(-1) }
                    .help("上一个冲突块")
                    .disabled(bridge.blocks.isEmpty)
                Text(bridge.blocks.isEmpty ? "无冲突块" : "块 \(selectedBlock + 1)/\(bridge.blocks.count)")
                    .font(.caption).foregroundStyle(.secondary).frame(minWidth: 90)
                Button("↓") { navigateBlock(1) }
                    .help("下一个冲突块")
                    .disabled(bridge.blocks.isEmpty)
            }
            .padding(6)
            if let preview = conflictBatchPreview,
               preview.simpleBlocks + preview.oursOnlyBlocks + preview.theirsOnlyBlocks + preview.trueConflictBlocks > 0 {
                Text("Safe blocks: \(preview.simpleBlocks) simple · \(preview.oursOnlyBlocks) local-only · \(preview.theirsOnlyBlocks) remote-only · \(preview.trueConflictBlocks) overlapping")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
            if !bridge.blocks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(bridge.blocks) { b in
                            blockChip(b)
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 8)
                }
            }
            if let feedback {
                Text(feedback).font(.caption)
                    .foregroundStyle(feedback.hasPrefix("已") ? .green : .red)
                    .padding(.horizontal, 8).padding(.bottom, 6)
            }
        }
    }

    var applyPatchToolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("Keep All Local") { acceptAllBlocks(.ours) }
                Button("Apply All Patch") { acceptAllBlocks(.theirs) }
                Button("Apply Non-Conflicts") { applyNonConflictingPatchHunks() }
                    .disabled(patchHunks.allSatisfy { $0.resolution.isResolved || $0.resolution == .notApplied })
                Button("Apply Selected Changes") { applySelectedPatchHunk() }
                    .help("将结果或 Patch 编辑器选中的 patch changes 应用到结果编辑器")
                    .disabled(!canApplySelectedPatchHunk || saving)
                Button("Ignore Selected Changes") { ignoreSelectedPatchHunk() }
                    .help("忽略选中的 patch hunk，并保留当前结果")
                    .disabled(!canIgnoreSelectedPatchHunk || saving)
                Spacer()
                Button("Previous Unresolved") { navigatePatchHunk(-1) }
                    .help("跳到上一个未解决 patch hunk")
                    .disabled(unresolvedPatchHunks.isEmpty)
                Text(patchHunkSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 180)
                Button("Next Unresolved") { navigatePatchHunk(1) }
                    .help("跳到下一个未解决 patch hunk")
                    .disabled(unresolvedPatchHunks.isEmpty)
            }
            .padding(6)
            if patchHunks.isEmpty {
                Text("No structured text hunks for this patch file; use the result editor or file-level actions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(patchHunks) { hunk in
                            patchHunkChip(hunk)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
            if let feedback {
                Text(feedback).font(.caption)
                    .foregroundStyle(feedback.hasPrefix("已") ? .green : .red)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
        }
    }

    func patchHunkChip(_ hunk: ApplyPatchConflictHunk) -> some View {
        let isSelected = hunk.id == selectedPatchHunkID
        return Button {
            selectedPatchHunkID = hunk.id
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Hunk \(hunk.index + 1)")
                    .font(.caption2.weight(.semibold))
                Text(hunk.resolution.title)
                    .font(.caption2)
                    .foregroundStyle(patchHunkColor(hunk.resolution))
            }
            .padding(5)
            .frame(minWidth: 92, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 4)
            )
        }
        .buttonStyle(.plain)
        .help(hunk.header)
    }

    func blockChip(_ b: SwiftConflictBlock) -> some View {
        let isSel = b.index == selectedBlock
        return HStack(spacing: 4) {
            Button {
                selectedBlock = b.index
            } label: {
                Text(isPatchMode ? "Patch Block \(b.index + 1)" : "块 \(b.index + 1)").font(.caption2)
            }
            .buttonStyle(.plain)
            Button("本地") { resolveBlock(b.index, .ours) }
            Button(isPatchMode ? "应用补丁" : "远程") { resolveBlock(b.index, .theirs) }
            Button("两者") { resolveBlock(b.index, .both) }
        }
        .padding(4)
        .background(isSel ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 4))
    }

    func navigateBlock(_ dir: Int) {
        let n = bridge.blocks.count
        guard n > 0 else { return }
        selectedBlock = (selectedBlock + dir + n) % n
    }

    func acceptAllBlocks(_ side: AcceptSide) {
        let count = bridge.blocks.count
        guard isPatchMode || count > 0 else { return }
        if isPatchMode {
            guard !patchHunks.isEmpty else {
                bridge.acceptAll(side)
                feedback = side == .ours ? "已全部保留本地结果" : "已全部应用补丁"
                return
            }
            var resolved = 0
            for hunk in patchHunks.reversed() {
                guard !hunk.resolution.isResolved else { continue }
                if side == .ours {
                    _ = bridge.ignorePatchHunk(hunk)
                    setPatchHunkResolution(hunk.id, .ignored)
                    resolved += 1
                } else {
                    switch bridge.applyPatchHunk(hunk) {
                    case .applied:
                        setPatchHunkResolution(hunk.id, .applied)
                        resolved += 1
                    case .alreadyApplied:
                        setPatchHunkResolution(hunk.id, .automaticallyApplied)
                        resolved += 1
                    case .pending, .notApplied, .automaticallyApplied, .ignored:
                        break
                    }
                }
            }
            refreshUnresolvedPatchHunks()
            selectedPatchHunkID = nil
            feedback = side == .ours
                ? "已忽略 \(resolved) 个 patch hunk"
                : "已应用 \(resolved) 个 patch hunk"
            return
        }
        bridge.acceptAll(side)
        feedback = side == .ours ? "已全部接受本地" : "已全部接受远程"
    }

    func applyConflictBatch(_ action: ConflictBatchAction) {
        guard let repo, !saving else { return }
        let path = self.path
        let repositoryID = repo.gitDir()
        let resultContent = bridge.getResultText()
        bridge.setResultEditingEnabled(false)
        saving = true
        Task.detached(priority: .userInitiated) {
            do {
                let result = try repo.conflictApplyBatch(
                    path: path,
                    resultContent: resultContent,
                    action: action
                )
                await MainActor.run {
                    self.bridge.setResultEditingEnabled(true)
                    self.saving = false
                    guard self.repo?.gitDir() == repositoryID, self.path == path else {
                        self.onChanged()
                        return
                    }
                    self.feedback = result.fullyResolved
                        ? "All eligible conflicts resolved"
                        : "Applied \(result.appliedBlocks) safe block(s); \(result.remainingBlocks) remain"
                    self.onChanged()
                    self.load()
                }
            } catch {
                await MainActor.run {
                    self.bridge.setResultEditingEnabled(true)
                    self.saving = false
                    guard self.repo?.gitDir() == repositoryID, self.path == path else { return }
                    self.feedback = "\(error)"
                }
            }
        }
    }

    func resolveBlock(_ index: Int, _ side: AcceptSide) {
        guard bridge.blocks.contains(where: { $0.index == index }) else { return }
        bridge.acceptBlock(index, side)
        if selectedBlock >= bridge.blocks.count {
            selectedBlock = max(0, bridge.blocks.count - 1)
        }
    }

    var patchHunkSummary: String {
        guard !patchHunks.isEmpty else { return "No patch hunks" }
        let resolved = patchHunks.filter { $0.resolution.isResolved }.count
        if resolved == patchHunks.count {
            return "All patch hunks resolved"
        }
        let selected = selectedPatchHunk.map { "Hunk \($0.index + 1) · " } ?? ""
        return "\(selected)\(resolved)/\(patchHunks.count) resolved"
    }

    var canApplySelectedPatchHunk: Bool {
        actionPatchHunks.contains { hunk in
            !hunk.resolution.isResolved
                && (hunk.resolution == .pending || bridge.canApplyPatchHunk(hunk))
        }
    }

    var canIgnoreSelectedPatchHunk: Bool {
        actionPatchHunks.contains { !$0.resolution.isResolved }
    }

    func patchHunkColor(_ resolution: ApplyPatchHunkResolution) -> Color {
        switch resolution {
        case .pending: return .orange
        case .alreadyApplied, .automaticallyApplied: return .green
        case .notApplied: return .red
        case .applied: return .green
        case .ignored: return .secondary
        }
    }

    func navigatePatchHunk(_ direction: Int) {
        let candidates = unresolvedPatchHunks
        guard !candidates.isEmpty else { return }
        let currentIndex = selectedPatchHunk.flatMap { hunk in
            candidates.firstIndex { $0.id == hunk.id }
        } ?? (direction > 0 ? -1 : 0)
        let next = (currentIndex + direction + candidates.count) % candidates.count
        selectedPatchHunkID = candidates[next].id
    }

    func applySelectedPatchHunk(_ explicitHunk: ApplyPatchConflictHunk? = nil) {
        let candidates = (explicitHunk.map { [$0] } ?? actionPatchHunks)
            .filter { !$0.resolution.isResolved }
        guard !candidates.isEmpty else { return }

        var applied = 0
        var alreadyApplied = 0
        var skipped = 0
        let grouped = candidates.count > 1
        if grouped {
            bridge.beginResultEditGroup("Apply Selected Changes")
        }
        defer {
            if grouped { bridge.endResultEditGroup() }
        }
        // Apply from the bottom up so a replacement cannot invalidate the
        // editor ranges used by a later selected change.
        for hunk in candidates.reversed() {
            selectedPatchHunkID = hunk.id
            switch bridge.applyPatchHunk(hunk) {
            case .applied:
                setPatchHunkResolution(hunk.id, .applied)
                applied += 1
            case .alreadyApplied:
                setPatchHunkResolution(hunk.id, .automaticallyApplied)
                alreadyApplied += 1
            case .notApplied, .pending, .automaticallyApplied, .ignored:
                skipped += 1
            }
        }
        refreshUnresolvedPatchHunks()
        feedback = "已应用 (applied + alreadyApplied) 个 patch change"
            + (skipped == 0 ? "" : "，跳过 (skipped) 个不可精确应用的 change")
        selectNextUnresolvedPatchHunkIfNeeded()
    }

    func ignoreSelectedPatchHunk(_ explicitHunk: ApplyPatchConflictHunk? = nil) {
        let candidates = (explicitHunk.map { [$0] } ?? actionPatchHunks)
            .filter { !$0.resolution.isResolved }
        guard !candidates.isEmpty else { return }
        let grouped = candidates.count > 1
        if grouped {
            bridge.beginResultEditGroup("Ignore Selected Changes")
        }
        defer {
            if grouped { bridge.endResultEditGroup() }
        }
        for hunk in candidates {
            selectedPatchHunkID = hunk.id
            _ = bridge.ignorePatchHunk(hunk)
            setPatchHunkResolution(hunk.id, .ignored)
        }
        refreshUnresolvedPatchHunks()
        feedback = "已忽略 (candidates.count) 个 patch change"
        selectNextUnresolvedPatchHunkIfNeeded()
    }

    func copyPatchHunk(_ hunk: ApplyPatchConflictHunk) {
        guard let content = ApplyPatchConflictHunkModel.clipboardText(for: hunk) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        selectedPatchHunkID = hunk.id
        feedback = "已复制 Hunk \(hunk.index + 1) 的补丁内容"
    }

    func applyNonConflictingPatchHunks() {
        var appliedCount = 0
        var automaticallyResolvedCount = 0
        let candidates = patchHunks.filter { !$0.resolution.isResolved }
        let grouped = candidates.count > 1
        if grouped {
            bridge.beginResultEditGroup("Apply Non-Conflicts")
        }
        defer {
            if grouped { bridge.endResultEditGroup() }
        }
        for hunk in candidates.reversed() {
            guard !hunk.resolution.isResolved else { continue }
            if hunk.resolution == .alreadyApplied {
                setPatchHunkResolution(hunk.id, .automaticallyApplied)
                automaticallyResolvedCount += 1
                continue
            }
            guard hunk.resolution == .pending || bridge.canApplyPatchHunk(hunk) else { continue }
            if bridge.applyPatchHunk(hunk) == .applied {
                setPatchHunkResolution(hunk.id, .applied)
                appliedCount += 1
            }
        }
        refreshUnresolvedPatchHunks()
        selectNextUnresolvedPatchHunkIfNeeded()
        let total = appliedCount + automaticallyResolvedCount
        feedback = total == 0
            ? "没有可自动应用的 patch hunk"
            : "已自动处理 \(total) 个 patch hunk"
    }

    func setPatchHunkResolution(
        _ id: String,
        _ resolution: ApplyPatchHunkResolution
    ) {
        guard let index = patchHunks.firstIndex(where: { $0.id == id }) else { return }
        if persistPatchHunkResolution(patchHunks[index], resolution) {
            patchHunks[index].resolution = resolution
        }
    }

    func persistPatchHunkResolution(
        _ hunk: ApplyPatchConflictHunk,
        _ resolution: ApplyPatchHunkResolution
    ) -> Bool {
        guard isPatchMode, let repo, let restoreName else { return true }
        let rawResolution: String
        switch resolution {
        case .applied: rawResolution = "applied"
        case .automaticallyApplied: rawResolution = "automatically_applied"
        case .ignored: rawResolution = "ignored"
        case .pending, .alreadyApplied, .notApplied: return true
        }
        do {
            try repo.shelveSetRestoreHunkResolution(
                name: restoreName,
                path: hunk.path,
                hunkIndex: hunk.index,
                resolution: rawResolution
            )
        } catch {
            feedback = "保存 patch hunk 状态失败：\(error)"
            return false
        }
        return true
    }

    func selectNextUnresolvedPatchHunkIfNeeded() {
        guard selectedPatchHunk?.resolution.isResolved == true else { return }
        selectedPatchHunkID = patchHunks.first(where: { !$0.resolution.isResolved })?.id
    }

    func refreshUnresolvedPatchHunks() {
        guard isPatchMode else { return }
        let result = bridge.getResultText()
        patchHunks = patchHunks.map { hunk in
            var updated = hunk
            if !updated.resolution.isResolved {
                updated.resolution = ApplyPatchConflictHunkModel.status(of: updated, in: result)
            }
            return updated
        }
        if selectedPatchHunkID == nil {
            selectedPatchHunkID = patchHunks.first(where: { !$0.resolution.isResolved })?.id
        }
    }

    var baseSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Base（共同祖先）").font(.headline)
                Spacer()
                Button("关闭") { showBase = false }
            }.padding(10)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(conflict?.base ?? "（无）")
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    var patchPreviewSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Patch to Apply").font(.headline)
                Spacer()
                Button("关闭") { showPatchPreview = false }
            }
            .padding(10)
            Divider()
            if let patchPreviewDiff, !patchPreviewDiff.binary, !patchPreviewDiff.hunks.isEmpty {
                VStack(spacing: 0) {
                    HStack {
                        Text("Structured patch preview")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("Diff View", selection: $patchPreviewPresentationMode) {
                            ForEach(DiffPresentationMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Design.Colors.surface)
                    if patchPreviewPresentationMode == .sideBySide {
                        SideBySideDiffView(fileDiff: patchPreviewDiff)
                    } else {
                        UnifiedDiffView(fileDiff: patchPreviewDiff)
                    }
                }
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(patchText ?? "")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    var localDiffSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Local → Result").font(.headline)
                Spacer()
                Button("关闭") { showLocalDiff = false }
            }
            .padding(10)
            Divider()
            if localDiffLoading {
                ProgressView("Loading local diff…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let localDiff {
                if localDiff.binary {
                    Label("Binary content cannot be rendered as a text diff.", systemImage: "doc.badge.gearshape")
                        .foregroundStyle(.secondary)
                        .padding(16)
                    Spacer()
                } else if localDiff.hunks.isEmpty {
                    Text("No changes between local and the current result.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            Text(path)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            Picker("Diff View", selection: $localDiffPresentationMode) {
                                ForEach(DiffPresentationMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 180)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Design.Colors.surface)
                        if localDiffPresentationMode == .sideBySide {
                            SideBySideDiffView(fileDiff: localDiff)
                        } else {
                            UnifiedDiffView(fileDiff: localDiff)
                        }
                    }
                }
            } else if let localDiffError {
                Text(localDiffError)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(16)
                Spacer()
            } else {
                Text("No local diff loaded.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    func loadLocalDiff() {
        guard isPatchMode, let repo, let conflict else { return }
        let path = self.path
        let local = conflict.ours
        let result = bridge.getResultText()
        localDiff = nil
        localDiffError = nil
        localDiffLoading = true
        showLocalDiff = true
        Task.detached(priority: .userInitiated) {
            do {
                let diff = try repo.diffTexts(
                    path: path,
                    oldText: local,
                    newText: result,
                    ignoreWhitespace: false
                )
                await MainActor.run {
                    self.localDiff = diff
                    self.localDiffLoading = false
                }
            } catch {
                await MainActor.run {
                    self.localDiffError = "无法生成 Local Diff：\(error)"
                    self.localDiffLoading = false
                }
            }
        }
    }

    func load() {
        loadGeneration &+= 1
        let generation = loadGeneration
        conflict = nil
        conflictIsBinary = false
        conflictBatchPreview = nil
        conflictError = nil
        patchHunks = []
        selectedPatchHunkID = nil
        guard let repo else { return }
        let path = self.path
        let repositoryID = repo.gitDir()
        let directPatchText = patchText
        let restoreName = self.restoreName
        Task.detached(priority: .userInitiated) {
            do {
                let workspace = try repo.conflictWorkspace()
                let persistedResolutions: [ShelveRestoreHunkResolution]
                if directPatchText != nil, let restoreName,
                   let restoreInfo = try? repo.shelveRestoreInfo(),
                   restoreInfo.name == restoreName {
                    persistedResolutions = restoreInfo.resolvedHunks
                } else {
                    persistedResolutions = []
                }
                guard let workspaceFile = workspace.files.first(where: { $0.path == path }) else {
                    await MainActor.run {
                        guard isCurrentConflictLoadRequest(
                            repositoryID: repositoryID,
                            path: path,
                            generation: generation,
                            currentRepositoryID: self.repo?.gitDir(),
                            currentPath: self.path,
                            currentGeneration: self.loadGeneration
                        ) else { return }
                        self.conflict = nil
                        self.conflictIsBinary = false
                        self.conflictBatchPreview = nil
                        self.conflictError = "冲突文件已解决或不再存在：\(path)"
                        self.patchHunks = []
                        self.selectedPatchHunkID = nil
                    }
                    return
                }
                let cf = workspaceFile.file
                let batchPreview = directPatchText == nil
                    ? try? repo.conflictBatchPreview(path: path)
                    : nil
                await MainActor.run {
                    guard isCurrentConflictLoadRequest(
                        repositoryID: repositoryID,
                        path: path,
                        generation: generation,
                        currentRepositoryID: self.repo?.gitDir(),
                        currentPath: self.path,
                        currentGeneration: self.loadGeneration
                    ) else { return }
                    var restoredHunks = directPatchText.map {
                        ApplyPatchConflictHunkModel.parse(
                            patch: $0,
                            path: path,
                            result: cf.result
                        )
                    } ?? []
                    for index in restoredHunks.indices {
                        if let resolution = ApplyPatchConflictHunkModel.restoredResolution(
                            for: restoredHunks[index],
                            from: persistedResolutions
                        ) {
                            restoredHunks[index].resolution = resolution
                        }
                    }
                    self.conflict = cf
                    self.conflictIsBinary = workspaceFile.binary
                    self.conflictBatchPreview = batchPreview
                    self.conflictError = nil
                    self.selectedBlock = 0
                    self.patchHunks = restoredHunks
                    self.selectedPatchHunkID = self.patchHunks
                        .first(where: { !$0.resolution.isResolved })?.id
                        ?? self.patchHunks.first?.id
                    self.reloadToken += 1  // 外部重载：触发编辑器同步
                }
            } catch {
                await MainActor.run {
                    guard isCurrentConflictLoadRequest(
                        repositoryID: repositoryID,
                        path: path,
                        generation: generation,
                        currentRepositoryID: self.repo?.gitDir(),
                        currentPath: self.path,
                        currentGeneration: self.loadGeneration
                    ) else { return }
                    self.conflict = nil
                    self.conflictIsBinary = false
                    self.conflictBatchPreview = nil
                    self.conflictError = "\(error)"
                    self.patchHunks = []
                    self.selectedPatchHunkID = nil
                }
            }
        }
    }

    /// 标记已解决：取结果栏文本 -> resolve_edited -> 刷新 status（文件不再显示 !）。
    /// 文件级 Accept（CONFLICT-001）：整文件接受一侧或双方，二进制安全。
    func acceptFile(_ pick: FilePick) {
        guard let repo, !saving else { return }
        let path = self.path
        saving = true
        Task.detached(priority: .userInitiated) {
            do {
                try repo.acceptConflict(path: path, pick: pick)
                await MainActor.run {
                    self.saving = false
                    let side = pick == .both ? "双方" : pick == .ours
                        ? "本地" : self.isPatchMode ? "补丁" : "远程"
                    self.feedback = "已接受" + side
                    self.onChanged()
                }
            } catch {
                await MainActor.run {
                    self.saving = false
                    self.conflictError = "\(error)"
                }
            }
        }
    }

    /// 重置冲突现场：放弃当前编辑，从 index stages 重新生成 marker。
    func resetConflictFile() {
        guard let repo, !saving else { return }
        let path = self.path
        let restoreName = self.restoreName
        saving = true
        Task.detached(priority: .userInitiated) {
            do {
                try repo.resetConflict(path: path)
                let resetFeedback: String
                if let restoreName {
                    do {
                        try repo.shelveClearRestoreHunkResolutions(name: restoreName, path: path)
                        resetFeedback = "已重置为未解决状态"
                    } catch {
                        resetFeedback = "已重置为未解决状态，但清理恢复状态失败：\(error)"
                    }
                } else {
                    resetFeedback = "已重置为未解决状态"
                }
                await MainActor.run {
                    self.saving = false
                    self.feedback = resetFeedback
                    self.onChanged()
                    self.load()
                }
            } catch {
                await MainActor.run {
                    self.saving = false
                    self.conflictError = "\(error)"
                }
            }
        }
    }

    func markResolved() {
        guard repo != nil, !saving else { return }
        let content = bridge.getResultText()
        if isPatchMode {
            // textDidChange coalesces through the main queue; refresh once
            // synchronously here so a fast click after editing cannot bypass
            // the partial-resolution confirmation with stale hunk state.
            refreshUnresolvedPatchHunks()
        }
        if isPatchMode, !unresolvedPatchHunks.isEmpty {
            pendingResolveContent = content
            showPartialResolveConfirmation = true
            return
        }
        if !parseConflictMarkers(content).isEmpty {
            feedback = "仍有未解决的冲突标记；请先解决每个冲突块"
            return
        }
        resolveEditedContent(content)
    }

    func resolveEditedContent(
        _ content: String,
        allowConflictMarkers: Bool = false
    ) {
        guard let repo, !saving else { return }
        let path = self.path
        let repositoryID = repo.gitDir()
        bridge.setResultEditingEnabled(false)
        saving = true
        Task.detached(priority: .userInitiated) {
            do {
                if allowConflictMarkers {
                    try repo.resolveEditedAllowConflictMarkers(path: path, content: content)
                } else {
                    try repo.resolveEdited(path: path, content: content)
                }
                await MainActor.run {
                    self.bridge.setResultEditingEnabled(true)
                    self.saving = false
                    guard self.repo?.gitDir() == repositoryID, self.path == path else {
                        self.onChanged()
                        return
                    }
                    self.feedback = "已标记为已解决"
                    self.onChanged()
                }
            } catch {
                await MainActor.run {
                    self.bridge.setResultEditingEnabled(true)
                    self.saving = false
                    guard self.repo?.gitDir() == repositoryID, self.path == path else { return }
                    self.feedback = "\(error)"
                }
            }
        }
    }

    /// 运行 Git 配置的 mergetool；Git 返回后重新读取 index stages，保留
    /// 外部工具只改工作区但未完成 stage 的情况，不能把它误报成已解决。
    func openExternalTool() {
        guard let repo, !externalToolWorking else { return }
        let path = self.path
        let cancelHandle = GitCancelHandle()
        externalToolWorking = true
        externalToolCancelling = false
        externalToolCancelHandle = cancelHandle
        conflictError = nil
        feedback = nil
        Task.detached(priority: .userInitiated) {
            do {
                let result = try repo.openExternalMergeToolWithCancel(path: path, cancel: cancelHandle)
                await MainActor.run {
                    self.externalToolWorking = false
                    self.externalToolCancelling = false
                    self.externalToolCancelHandle = nil
                    self.onChanged()
                    if result.resolved {
                        self.conflict = nil
                        self.conflictIsBinary = false
                        self.feedback = "External merge tool resolved the file."
                    } else {
                        self.feedback = "External merge tool returned; conflicts remain."
                        self.load()
                    }
                }
            } catch {
                await MainActor.run {
                    self.externalToolWorking = false
                    self.externalToolCancelling = false
                    self.externalToolCancelHandle = nil
                    if cancelHandle.isCancelled() {
                        self.feedback = String(localized: "External merge tool canceled.")
                        self.load()
                    } else {
                        self.conflictError = "\(error)"
                    }
                }
            }
        }
    }
}
