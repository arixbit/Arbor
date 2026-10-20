import SwiftUI
import AppKit


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
