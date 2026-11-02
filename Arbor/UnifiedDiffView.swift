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

struct UnifiedDiffView: View {
    let fileDiff: FileDiff
    /// Ordinal of the difference the toolbar selected. Rows in it get a marker
    /// and the view scrolls to it when the ordinal changes.
    var activeDifference: Int? = nil

    var body: some View {
        let rowsByHunk = fileDiff.hunks.map(unifiedDiffRows)
        let ordinals = differenceOrdinals(isChange: rowsByHunk.map { rows in
            rows.map { $0.prefix != " " }
        })
        GeometryReader { proxy in
            ScrollViewReader { scroller in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(fileDiff.hunks.indices, id: \.self) { hindex in
                            HunkHeaderView(hunk: fileDiff.hunks[hindex])
                                .frame(minWidth: proxy.size.width, alignment: .leading)
                            ForEach(
                                Array(rowsByHunk[hindex].enumerated()),
                                id: \.offset
                            ) { rindex, row in
                                UnifiedDiffRowView(
                                    row: row,
                                    isActiveDifference: ordinals[hindex][rindex] == activeDifference
                                )
                                .frame(minWidth: proxy.size.width, alignment: .leading)
                                .id(diffRowAnchorID(hunk: hindex, row: rindex))
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

func diffRowAnchorID(hunk: Int, row: Int) -> String {
    "diff-row-\(hunk)-\(row)"
}

func differenceOrdinals(isChange: [[Bool]]) -> [[Int?]] {
    var ordinal = 0
    return isChange.map { rows in
        var previousWasChange = false
        var result: [Int?] = []
        result.reserveCapacity(rows.count)
        for isChanged in rows {
            if isChanged && !previousWasChange { ordinal += 1 }
            result.append(isChanged ? ordinal - 1 : nil)
            previousWasChange = isChanged
        }
        return result
    }
}

func sideBySideDifferenceOrdinals(in hunks: [DiffHunk]) -> [[Int?]] {
    differenceOrdinals(isChange: hunks.map { hunk in
        sideBySideRows(hunk).map { row in
            row.old?.kind == .deletion || row.new?.kind == .addition
        }
    })
}

func unifiedDifferenceOrdinals(in hunks: [DiffHunk]) -> [[Int?]] {
    differenceOrdinals(isChange: hunks.map { hunk in
        unifiedDiffRows(hunk).map { $0.prefix != " " }
    })
}

func sideBySideDifferenceCount(in hunks: [DiffHunk]) -> Int {
    differenceCount(in: sideBySideDifferenceOrdinals(in: hunks))
}

func unifiedDifferenceCount(in hunks: [DiffHunk]) -> Int {
    differenceCount(in: unifiedDifferenceOrdinals(in: hunks))
}

func differenceCount(in ordinals: [[Int?]]) -> Int {
    ordinals
        .flatMap { $0 }
        .compactMap { $0 }
        .max()
        .map { $0 + 1 } ?? 0
}

func differenceAnchorID(ordinal: Int, ordinals: [[Int?]]) -> String? {
    for (hunkIndex, rows) in ordinals.enumerated() {
        if let rowIndex = rows.firstIndex(where: { $0 == ordinal }) {
            return diffRowAnchorID(hunk: hunkIndex, row: rowIndex)
        }
    }
    return nil
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
