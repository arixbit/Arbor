import SwiftUI
import AppKit


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
