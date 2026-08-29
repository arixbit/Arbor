import XCTest
@testable import Arbor

/// 冲突解析纯函数的单测（与引擎 parse_marker_blocks / Rust str::lines() 同语义的 Swift 镜像）。
/// 防止 off-by-one、UTF-16 偏移、尾随换行等回归。
final class MergeParserTests: XCTestCase {

    // MARK: - splitLines（匹配 Rust str::lines()）

    func testSplitLines_trailingNewline() {
        XCTAssertEqual(splitLines("a\nb\n"), ["a", "b"])
    }

    func testSplitLines_noTrailingNewline() {
        XCTAssertEqual(splitLines("a\nb"), ["a", "b"])
    }

    func testSplitLines_singleTrailingNewline() {
        XCTAssertEqual(splitLines("a\n"), ["a"])
    }

    func testSplitLines_emptyLines() {
        XCTAssertEqual(splitLines("a\n\nb\n"), ["a", "", "b"])
    }

    func testSplitLines_empty() {
        XCTAssertEqual(splitLines(""), [""])
    }

    // MARK: - parseConflictMarkers

    func testParse_noMarkers() {
        XCTAssertTrue(parseConflictMarkers("plain text\nno conflicts").isEmpty)
    }

    func testParse_singleBlock_trailingNewline() {
        let text = "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\n"
        let blocks = parseConflictMarkers(text)
        XCTAssertEqual(blocks.count, 1)
        let b = blocks[0]
        XCTAssertEqual(b.lineStart, 0)
        XCTAssertEqual(b.lineEnd, 5) // >>>>>>> 行的下一行
        XCTAssertEqual(b.oursLines, ["ours"])
        XCTAssertEqual(b.theirsLines, ["theirs"])
    }

    func testParse_singleBlock_noTrailingNewline() {
        let text = "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature"
        let blocks = parseConflictMarkers(text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].lineStart, 0)
        XCTAssertEqual(blocks[0].lineEnd, 5)
    }

    func testParse_blockWithContext() {
        let text = "ctx-before\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\nctx-after\n"
        let blocks = parseConflictMarkers(text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].lineStart, 1)
        XCTAssertEqual(blocks[0].lineEnd, 6)
    }

    func testParse_multiLineSides() {
        let text = "<<<<<<< HEAD\no1\no2\no3\n=======\nt1\nt2\n>>>>>>> b\n"
        let blocks = parseConflictMarkers(text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].oursLines, ["o1", "o2", "o3"])
        XCTAssertEqual(blocks[0].theirsLines, ["t1", "t2"])
        // ======= 在 lineStart+1+oursLines.count = 0+1+3 = 4
        XCTAssertEqual(blocks[0].lineEnd, 8) // >>>>>>> 在第 7 行，end=8
    }

    func testParse_multipleBlocks() {
        let text = """
        <<<<<<< HEAD
        o1
        =======
        t1
        >>>>>>> b
        shared
        <<<<<<< HEAD
        o2
        =======
        t2
        >>>>>>> b
        """
        let blocks = parseConflictMarkers(text)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].oursLines, ["o1"])
        XCTAssertEqual(blocks[1].oursLines, ["o2"])
        XCTAssertEqual(blocks[0].index, 0)
        XCTAssertEqual(blocks[1].index, 1)
    }

    func testParse_emptySides() {
        let text = "<<<<<<< HEAD\n=======\ntheirs\n>>>>>>> b\n"
        let blocks = parseConflictMarkers(text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertTrue(blocks[0].oursLines.isEmpty)
        XCTAssertEqual(blocks[0].theirsLines, ["theirs"])
    }

    func testParse_incompleteBlock_ignored() {
        // 缺 >>>>>>> -> 解析中止，不产出块
        let text = "<<<<<<< HEAD\nours\n=======\ntheirs\n"
        XCTAssertTrue(parseConflictMarkers(text).isEmpty)
    }

    // MARK: - accept 语义验证（splice 后行号正确，与引擎 resolve 同语义）

    /// 验证「接受 ours」的行替换结果与引擎 resolve 的 splice 语义一致。
    func testAcceptOurs_spliceSemantics() {
        let text = "ctx\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> b\nctx2\n"
        var lines = splitLines(text)
        let blocks = parseConflictMarkers(text)
        XCTAssertEqual(blocks.count, 1)
        let b = blocks[0]
        lines.replaceSubrange(b.lineStart..<b.lineEnd, with: b.oursLines)
        let result = lines.joined(separator: "\n") + (text.hasSuffix("\n") ? "\n" : "")
        XCTAssertEqual(result, "ctx\nours\nctx2\n")
    }

    func testAcceptTheirs_spliceSemantics() {
        let text = "ctx\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> b\nctx2\n"
        var lines = splitLines(text)
        let b = parseConflictMarkers(text)[0]
        lines.replaceSubrange(b.lineStart..<b.lineEnd, with: b.theirsLines)
        let result = lines.joined(separator: "\n") + (text.hasSuffix("\n") ? "\n" : "")
        XCTAssertEqual(result, "ctx\ntheirs\nctx2\n")
    }

    func testMergeEditorBridge_applyPatchBlockUsesTheirsAndClearsMarker() {
        let text = "ctx\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> b\nctx2\n"
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        textView.string = text
        let bridge = MergeEditorBridge()
        bridge.attachResult(textView)

        bridge.acceptBlock(0, .theirs)

        XCTAssertEqual(textView.string, "ctx\ntheirs\nctx2\n")
        XCTAssertTrue(bridge.blocks.isEmpty)
    }

    func testMergeEditorBridge_ignorePatchBlockKeepsOursAndClearsMarker() {
        let text = "ctx\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> b\nctx2\n"
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        textView.string = text
        let bridge = MergeEditorBridge()
        bridge.attachResult(textView)

        bridge.acceptBlock(0, .ours)

        XCTAssertEqual(textView.string, "ctx\nours\nctx2\n")
        XCTAssertTrue(bridge.blocks.isEmpty)
    }

    func testApplyPatchHunkModelTracksPendingAlreadyAppliedAndNotApplied() {
        let patch = """
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1,3 +1,3 @@
         before
        -old
        +new
         after
        """

        let pending = ApplyPatchConflictHunkModel.parse(
            patch: patch,
            path: "Sources/App.swift",
            result: "before\nold\nafter\n"
        )
        let alreadyApplied = ApplyPatchConflictHunkModel.parse(
            patch: patch,
            path: "Sources/App.swift",
            result: "before\nnew\nafter\n"
        )
        let notApplied = ApplyPatchConflictHunkModel.parse(
            patch: patch,
            path: "Sources/App.swift",
            result: "before\nother\nafter\n"
        )

        XCTAssertEqual(pending.map(\.id), ["Sources/App.swift#0"])
        XCTAssertEqual(pending.first?.resolution, .pending)
        XCTAssertEqual(alreadyApplied.first?.resolution, .alreadyApplied)
        XCTAssertEqual(notApplied.first?.resolution, .notApplied)
    }

    func testMergeEditorBridge_applyPatchHunkResolvesMatchingConflictBlock() {
        let text = "ctx\n<<<<<<< HEAD\nold\n=======\nnew\n>>>>>>> b\n"
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        textView.string = text
        let bridge = MergeEditorBridge()
        bridge.attachResult(textView)
        let hunk = ApplyPatchConflictHunk(
            path: "Sources/App.swift",
            index: 0,
            header: "@@ -2,1 +2,1 @@",
            oldStart: 2,
            newStart: 2,
            oldLines: ["old"],
            newLines: ["new"],
            oldChangedLines: ["old"],
            newChangedLines: ["new"],
            resolution: .notApplied
        )

        XCTAssertEqual(bridge.applyPatchHunk(hunk), .applied)
        XCTAssertEqual(textView.string, "ctx\nnew\n")
        XCTAssertTrue(bridge.blocks.isEmpty)
    }

    func testMergeEditorBridge_applyPatchHunkParticipatesInUndo() {
        let original = "ctx\n<<<<<<< HEAD\nold\n=======\nnew\n>>>>>>> b\n"
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        textView.allowsUndo = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        textView.string = original
        let bridge = MergeEditorBridge()
        bridge.attachResult(textView)
        let hunk = ApplyPatchConflictHunk(
            path: "Sources/App.swift",
            index: 0,
            header: "@@ -2,1 +2,1 @@",
            oldStart: 2,
            newStart: 2,
            oldLines: ["old"],
            newLines: ["new"],
            oldChangedLines: ["old"],
            newChangedLines: ["new"],
            resolution: .pending
        )

        XCTAssertEqual(bridge.applyPatchHunk(hunk), .applied)
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, original)
        window.orderOut(nil)
    }

    func testMergeEditorBridge_editorSelectionMatchesPatchConflictHunk() {
        let text = "ctx\n<<<<<<< HEAD\nold\n=======\nnew\n>>>>>>> b\n"
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        textView.string = text
        textView.setSelectedRange(NSRange(location: 0, length: (text as NSString).length))
        let bridge = MergeEditorBridge()
        bridge.attachResult(textView)
        let hunk = ApplyPatchConflictHunk(
            path: "Sources/App.swift",
            index: 0,
            header: "@@ -2,1 +2,1 @@",
            oldStart: 2,
            newStart: 2,
            oldLines: ["old"],
            newLines: ["new"],
            oldChangedLines: ["old"],
            newChangedLines: ["new"],
            resolution: .pending
        )

        XCTAssertTrue(bridge.isHunkSelected(hunk))
    }

    func testMergeEditorBridge_patchEditorSelectionMatchesStableHunkIndex() {
        let resultView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        resultView.string = "old\nkeep\nold2\n"
        let patchText = "--- a/Sources/App.swift\n+++ b/Sources/App.swift\n@@ -1,1 +1,1 @@\n-old\n+new\n@@ -3,1 +3,1 @@\n-old2\n+new2\n"
        let patchView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        patchView.string = patchText
        let secondHeader = (patchText as NSString).range(of: "@@ -3,1 +3,1 @@")
        patchView.setSelectedRange(NSRange(
            location: secondHeader.location,
            length: secondHeader.length
        ))
        let bridge = MergeEditorBridge()
        bridge.attachResult(resultView)
        bridge.attachPatch(patchView)
        let hunk = ApplyPatchConflictHunk(
            path: "Sources/App.swift",
            index: 1,
            header: "@@ -3,1 +3,1 @@",
            oldStart: 3,
            newStart: 3,
            oldLines: ["old2"],
            newLines: ["new2"],
            oldChangedLines: ["old2"],
            newChangedLines: ["new2"],
            resolution: .pending
        )

        XCTAssertTrue(bridge.isHunkSelected(hunk))
    }

    func testMergeEditorBridge_fullPatchSelectionMatchesMultipleChanges() {
        let resultView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        resultView.string = "old\nkeep\nold2\n"
        let patchText = "--- a/Sources/App.swift\n+++ b/Sources/App.swift\n@@ -1,1 +1,1 @@\n-old\n+new\n@@ -3,1 +3,1 @@\n-old2\n+new2\n"
        let patchView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        patchView.string = patchText
        patchView.setSelectedRange(NSRange(location: 0, length: (patchText as NSString).length))

        let bridge = MergeEditorBridge()
        bridge.attachResult(resultView)
        bridge.attachPatch(patchView)
        let hunks = ApplyPatchConflictHunkModel.parse(
            patch: patchText,
            path: "Sources/App.swift",
            result: resultView.string
        )

        XCTAssertEqual(hunks.count, 2)
        XCTAssertTrue(hunks.allSatisfy(bridge.isHunkSelected))
    }

    func testApplyPatchHunkModel_mapsPatchHeaderLineToStableHunkIndex() {
        let patchText = "--- a/Sources/App.swift\n+++ b/Sources/App.swift\n@@ -1,1 +1,1 @@\n-old\n+new\n@@ -3,1 +3,1 @@\n-old2\n+new2\n"

        XCTAssertEqual(
            ApplyPatchConflictHunkModel.patchHunkIndex(
                in: patchText,
                atPatchLine: 2
            ),
            0
        )
        XCTAssertEqual(
            ApplyPatchConflictHunkModel.patchHunkIndex(
                in: patchText,
                atPatchLine: 5
            ),
            1
        )
        XCTAssertNil(
            ApplyPatchConflictHunkModel.patchHunkIndex(
                in: patchText,
                atPatchLine: 4
            )
        )
    }

    func testApplyPatchHunkModel_clipboardTextUsesChangedLinesOnly() {
        let hunk = ApplyPatchConflictHunk(
            path: "Sources/App.swift",
            index: 0,
            header: "@@ -1,3 +1,3 @@",
            oldStart: 1,
            newStart: 1,
            oldLines: ["before", "old", "after"],
            newLines: ["before", "new", "after"],
            oldChangedLines: ["old"],
            newChangedLines: ["new"],
            resolution: .notApplied
        )

        XCTAssertEqual(
            ApplyPatchConflictHunkModel.clipboardText(for: hunk),
            "new\n"
        )
    }

    func testApplyPatchHunkModel_restoresPersistedResolutionByStableIdentity() {
        let hunk = ApplyPatchConflictHunk(
            path: "Sources/App.swift",
            index: 1,
            header: "@@ -3,1 +3,1 @@",
            oldStart: 3,
            newStart: 3,
            oldLines: ["old"],
            newLines: ["new"],
            oldChangedLines: ["old"],
            newChangedLines: ["new"],
            resolution: .pending
        )
        let persisted = [ShelveRestoreHunkResolution(
            path: "Sources/App.swift",
            hunkIndex: 1,
            resolution: "ignored"
        )]

        XCTAssertEqual(
            ApplyPatchConflictHunkModel.restoredResolution(for: hunk, from: persisted),
            .ignored
        )
    }

    func testMergeEditorBridge_applyPatchHunkUsesExpectedLineToDisambiguateBlocks() {
        let text = "pre\n<<<<<<< HEAD\nold\n=======\nnew\n>>>>>>> b\nmid\n<<<<<<< HEAD\nold\n=======\nnew\n>>>>>>> b\n"
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        textView.string = text
        let bridge = MergeEditorBridge()
        bridge.attachResult(textView)
        let hunk = ApplyPatchConflictHunk(
            path: "Sources/App.swift",
            index: 1,
            header: "@@ -8,1 +8,1 @@",
            oldStart: 8,
            newStart: 8,
            oldLines: ["old"],
            newLines: ["new"],
            oldChangedLines: ["old"],
            newChangedLines: ["new"],
            resolution: .pending
        )

        XCTAssertEqual(bridge.applyPatchHunk(hunk), .applied)
        XCTAssertEqual(
            textView.string,
            "pre\n<<<<<<< HEAD\nold\n=======\nnew\n>>>>>>> b\nmid\nnew\n"
        )
    }

    /// 倒序全接受：多块替换行号不错位。
    func testAcceptAll_reversedNoShift() {
        let text = """
        <<<<<<< H
        o1
        =======
        t1
        >>>>>>> b
        mid
        <<<<<<< H
        o2
        =======
        t2
        >>>>>>> b
        """
        var lines = splitLines(text)
        for b in parseConflictMarkers(text).reversed() {
            lines.replaceSubrange(b.lineStart..<b.lineEnd, with: b.oursLines)
        }
        let result = lines.joined(separator: "\n")
        XCTAssertEqual(result, "o1\nmid\no2")
    }

    // MARK: - lineCharRanges（UTF-16 NSRange，与 splitLines 行号对齐）

    func testLineCharRanges_trailingNewline() {
        let ranges = lineCharRanges("a\nb\n")
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0], NSRange(location: 0, length: 2))  // "a\n"
        XCTAssertEqual(ranges[1], NSRange(location: 2, length: 2))  // "b\n"
    }

    func testLineCharRanges_noTrailingNewline() {
        let ranges = lineCharRanges("a\nb")
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0], NSRange(location: 0, length: 2))  // "a\n"
        XCTAssertEqual(ranges[1], NSRange(location: 2, length: 1))  // "b"
    }

    func testLineCharRanges_empty() {
        XCTAssertTrue(lineCharRanges("").isEmpty)
    }

    /// CJK 内容：UTF-16 偏移必须正确（你=1 code unit，\n=1）。
    func testLineCharRanges_cjk() {
        let ranges = lineCharRanges("你\n好\n")
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0], NSRange(location: 0, length: 2))  // "你\n"
        XCTAssertEqual(ranges[1], NSRange(location: 2, length: 2))  // "好\n"
    }

    /// 行号对齐：lineCharRanges 的下标必须与 splitLines 一致（着色用）。
    func testLineIndexAlignment_cjkConflict() {
        let text = "你\n<<<<<<< HEAD\n改\n=======\ntheir\n>>>>>>> b\nend\n"
        let lines = splitLines(text)
        let ranges = lineCharRanges(text)
        XCTAssertEqual(lines.count, ranges.count, "line count must match for coloring alignment")
        let b = parseConflictMarkers(text)[0]
        // <<<<<<< 行 = lineStart，其字符范围应覆盖 "<<<<<<< HEAD\n"
        let markerRange = ranges[b.lineStart]
        let ns = (text as NSString)
        XCTAssertEqual(ns.substring(with: markerRange), "<<<<<<< HEAD\n")
    }
}

/// Update Project recovery deliberately relies on a stable, exact stash
/// message so the pending local changes can be rediscovered after relaunch.
final class GitRecoveryTests: XCTestCase {
    func testUpdateStashMessagesAreRecognized() {
        XCTAssertTrue(isArborUpdateStashMessage("Arbor: Update Project"))
        XCTAssertTrue(isArborUpdateStashMessage("Arbor: Update Project (rebase)"))
    }

    func testUserStashMessagesAreNotClaimedAsUpdateRecovery() {
        XCTAssertFalse(isArborUpdateStashMessage("WIP"))
        XCTAssertFalse(isArborUpdateStashMessage("Arbor: Update Project extra"))
        XCTAssertFalse(isArborUpdateStashMessage("Arbor: Update Project (rebase) "))
    }
}
