import SwiftUI

extension TreeChangeKind {
    var displayTitle: LocalizedStringKey {
        switch self {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        }
    }
}

enum DiffPresentationMode: String, CaseIterable, Identifiable {
    case sideBySide
    case unified

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .sideBySide: "Side-by-side"
        case .unified: "Unified"
        }
    }
}

/// Whole-file texts for both sides of a diff.
///
/// The reference diff viewer shows the complete file and lets the difference
/// arrows jump between changed runs. Git's `FileDiff` only carries hunks with
/// a few context lines, so the log's Repository Diff tab also reads both file
/// versions and renders every line; hunk data still supplies the changed rows
/// and line numbers. A nil side means the file does not exist there (added or
/// deleted file) or could not be read completely.
struct FullFileDiff: Equatable {
    var oldLines: [String]?
    var newLines: [String]?
}

/// One line of the unified presentation. Hunk headers only appear when the
/// full file is unavailable; the reference hides them while showing the whole
/// file continuously.
enum UnifiedDisplayItem {
    case hunkHeader(Int)
    case row(UnifiedDiffRow)
}

struct UnifiedDiffView: View {
    let fileDiff: FileDiff
    var fullFile: FullFileDiff? = nil
    /// Ordinal of the difference the toolbar selected. Rows in it get a marker
    /// and the view scrolls to it when the ordinal changes.
    var activeDifference: Int? = nil

    var body: some View {
        let items = unifiedDisplayItems(fileDiff: fileDiff, fullFile: fullFile)
        let ordinals = unifiedDifferenceOrdinals(items)
        GeometryReader { proxy in
            ScrollViewReader { scroller in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items.indices, id: \.self) { index in
                            switch items[index] {
                            case let .hunkHeader(hunkIndex):
                                HunkHeaderView(hunk: fileDiff.hunks[hunkIndex])
                                    .frame(minWidth: proxy.size.width, alignment: .leading)
                            case let .row(row):
                                UnifiedDiffRowView(
                                    row: row,
                                    isActiveDifference: ordinals[index] == activeDifference
                                )
                                .frame(minWidth: proxy.size.width, alignment: .leading)
                                .id(diffRowAnchorID(index))
                            }
                        }
                    }
                    .font(.system(.body, design: .monospaced))
                    .frame(
                        minWidth: proxy.size.width,
                        minHeight: proxy.size.height,
                        alignment: .topLeading
                    )
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                .onChange(of: activeDifference) { _, value in
                    guard let value,
                          let anchor = differenceAnchorID(ordinal: value, ordinals: ordinals) else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        scroller.scrollTo(anchor, anchor: .top)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Difference navigation shared by both presentations

func diffRowAnchorID(_ index: Int) -> String {
    "diff-row-\(index)"
}

func differenceAnchorID(ordinal: Int, ordinals: [Int?]) -> String? {
    guard let index = ordinals.firstIndex(where: { $0 == ordinal }) else { return nil }
    return diffRowAnchorID(index)
}

/// Counts contiguous changed runs, matching the reference's difference count
/// rather than Git's hunk count.
func countDifferenceRuns(_ flags: [Bool]) -> Int {
    var count = 0
    var previousWasChange = false
    for flag in flags {
        if flag && !previousWasChange { count += 1 }
        previousWasChange = flag
    }
    return count
}

func unifiedDifferenceOrdinals(_ items: [UnifiedDisplayItem]) -> [Int?] {
    var ordinal = 0
    var previousWasChange = false
    return items.map { item in
        guard case let .row(row) = item else {
            previousWasChange = false
            return nil
        }
        let isChange = row.prefix != " "
        if isChange && !previousWasChange { ordinal += 1 }
        previousWasChange = isChange
        return isChange ? ordinal - 1 : nil
    }
}

func unifiedDifferenceCount(in hunks: [DiffHunk]) -> Int {
    hunks.reduce(0) { count, hunk in
        count + countDifferenceRuns(unifiedDiffRows(hunk).map { $0.prefix != " " })
    }
}

func unifiedDisplayItems(fileDiff: FileDiff, fullFile: FullFileDiff?) -> [UnifiedDisplayItem] {
    if let fullFile,
       let rows = fullFileUnifiedRows(fileDiff: fileDiff, fullFile: fullFile) {
        return rows.map { .row($0) }
    }
    return fileDiff.hunks.enumerated().flatMap { hunkIndex, hunk in
        [UnifiedDisplayItem.hunkHeader(hunkIndex)] + unifiedDiffRows(hunk).map { .row($0) }
    }
}

/// Whole-file to unified rows. Rows before, between and after hunks are
/// unchanged pairs read from the full file; a change of line count between
/// hunks cannot happen because Git would have merged those regions into one
/// hunk.
func fullFileUnifiedRows(fileDiff: FileDiff, fullFile: FullFileDiff) -> [UnifiedDiffRow]? {
    guard fullFile.oldLines != nil || fullFile.newLines != nil else { return nil }
    var rows: [UnifiedDiffRow] = []
    var oldCursor = 1
    var newCursor = 1
    for hunk in fileDiff.hunks {
        let oldStart = max(1, Int(hunk.oldStart))
        let newStart = max(1, Int(hunk.newStart))
        while oldCursor < oldStart, newCursor < newStart,
              let row = unifiedContextRow(fullFile: fullFile, oldNumber: oldCursor, newNumber: newCursor) {
            rows.append(row)
            oldCursor += 1
            newCursor += 1
        }
        rows.append(contentsOf: unifiedDiffRows(hunk))
        oldCursor = max(oldCursor, oldStart + hunk.oldLines.count)
        newCursor = max(newCursor, newStart + hunk.newLines.count)
    }
    while let row = unifiedContextRow(fullFile: fullFile, oldNumber: oldCursor, newNumber: newCursor) {
        rows.append(row)
        oldCursor += 1
        newCursor += 1
    }
    return rows
}

private func unifiedContextRow(
    fullFile: FullFileDiff,
    oldNumber: Int,
    newNumber: Int
) -> UnifiedDiffRow? {
    guard let oldLines = fullFile.oldLines,
          let newLines = fullFile.newLines,
          oldLines.indices.contains(oldNumber - 1),
          newLines.indices.contains(newNumber - 1) else { return nil }
    let text = newLines[newNumber - 1]
    return UnifiedDiffRow(
        line: DiffLine(
            kind: .context,
            oldLine: UInt32(oldNumber),
            newLine: UInt32(newNumber),
            text: text,
            spans: [],
            highlights: []
        ),
        oldLine: UInt32(oldNumber),
        newLine: UInt32(newNumber),
        prefix: " "
    )
}

func unifiedDiffRows(_ hunk: DiffHunk) -> [UnifiedDiffRow] {
    var rows: [UnifiedDiffRow] = []
    var oldIndex = 0
    var newIndex = 0

    while oldIndex < hunk.oldLines.count || newIndex < hunk.newLines.count {
        let old = oldIndex < hunk.oldLines.count ? hunk.oldLines[oldIndex] : nil
        let new = newIndex < hunk.newLines.count ? hunk.newLines[newIndex] : nil

        if let old, let new, old.kind == .context, new.kind == .context {
            rows.append(UnifiedDiffRow(
                line: old,
                oldLine: old.oldLine,
                newLine: new.newLine,
                prefix: " "
            ))
            oldIndex += 1
            newIndex += 1
        } else if let old, old.kind == .deletion {
            rows.append(UnifiedDiffRow(
                line: old,
                oldLine: old.oldLine,
                newLine: 0,
                prefix: "-"
            ))
            oldIndex += 1
        } else if let new, new.kind == .addition {
            rows.append(UnifiedDiffRow(
                line: new,
                oldLine: 0,
                newLine: new.newLine,
                prefix: "+"
            ))
            newIndex += 1
        } else if let old, let new {
            rows.append(UnifiedDiffRow(
                line: old,
                oldLine: old.oldLine,
                newLine: new.newLine,
                prefix: " "
            ))
            oldIndex += 1
            newIndex += 1
        } else if let old {
            rows.append(UnifiedDiffRow(
                line: old,
                oldLine: old.oldLine,
                newLine: 0,
                prefix: "-"
            ))
            oldIndex += 1
        } else if let new {
            rows.append(UnifiedDiffRow(
                line: new,
                oldLine: 0,
                newLine: new.newLine,
                prefix: "+"
            ))
            newIndex += 1
        }
    }
    return rows
}

struct UnifiedDiffRow: Identifiable {
    let line: DiffLine
    let oldLine: UInt32
    let newLine: UInt32
    let prefix: String

    var id: String {
        "\(oldLine):\(newLine):\(prefix):\(line.text)"
    }
}

private struct UnifiedDiffRowView: View {
    let row: UnifiedDiffRow
    var isActiveDifference = false

    var body: some View {
        HStack(spacing: 0) {
            Text(row.oldLine == 0 ? " " : String(row.oldLine))
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text(row.newLine == 0 ? " " : String(row.newLine))
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(.secondary)
            Text(row.prefix)
                .frame(width: 22, alignment: .center)
                .foregroundStyle(rowColor)
            Text(highlightedText)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 0.5)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if isActiveDifference {
                Rectangle()
                    .fill(Design.Colors.accent)
                    .frame(width: 3)
            }
        }
    }

    private var rowColor: Color {
        switch row.line.kind {
        case .addition: Design.Colors.success
        case .deletion: Design.Colors.error
        case .context: .secondary
        }
    }

    private var rowBackground: Color {
        switch row.line.kind {
        case .addition: Design.Colors.addition
        case .deletion: Design.Colors.deletion
        case .context: .clear
        }
    }

    private var highlightedText: AttributedString {
        var value = AttributedString(row.line.text)
        SyntaxHighlight.apply(row.line.highlights, to: row.line.text, attr: &value)
        if !row.line.spans.isEmpty {
            let background = row.line.kind == .addition
                ? Design.Colors.success.opacity(0.3)
                : Design.Colors.error.opacity(0.3)
            let utf8 = row.line.text.utf8
            for span in row.line.spans {
                guard let start = utf8.index(
                    utf8.startIndex,
                    offsetBy: Int(span.start),
                    limitedBy: utf8.endIndex
                ),
                let end = utf8.index(
                    utf8.startIndex,
                    offsetBy: Int(span.end),
                    limitedBy: utf8.endIndex
                ),
                let range = Range(start..<end, in: value) else { continue }
                value[range].backgroundColor = background
            }
        }
        return value
    }
}
