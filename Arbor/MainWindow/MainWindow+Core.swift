import SwiftUI
import AppKit

import SwiftUI
import AppKit

// Arbor 主界面：左侧常驻项目树，上下可折叠、可拖动的 IntelliJ 风格工具窗，
// 主区只负责展示当前上下文（文件、变更、提交或冲突）。引擎调用同步阻塞，
// 所有耗时操作仍由 WorkspaceOperations 放到后台 Task。

enum ToolWindowMode: String, CaseIterable, Identifiable {
    case commit
    case log
    case operations

    var id: String { rawValue }
    var title: String {
        switch self {
        case .commit: "Commit"
        case .log: "Log"
        case .operations: "Operation Log"
        }
    }
    var systemImage: String {
        switch self {
        case .commit: "checkmark.circle"
        case .log: "clock"
        case .operations: "list.bullet.rectangle"
        }
    }
}

/// 块接受方向（「两者」= ours+theirs 拼接，UI 侧操作，非引擎 PickKind）。
enum AcceptSide: Equatable { case ours, theirs, both }

/// 匹配 Rust str::lines() 的行切分：按 \n 切，去掉尾随 \n 产生的空串。
func splitLines(_ text: String) -> [String] {
    var lines = text.components(separatedBy: "\n")
    if text.hasSuffix("\n") { lines.removeLast() }
    return lines
}

/// 按 \n 计算每行的字符范围（UTF-16 NSRange，含行尾 \n；与 splitLines 行号对齐）。
func lineCharRanges(_ text: String) -> [NSRange] {
    let ns = text as NSString
    var ranges: [NSRange] = []
    var lineStart = 0
    for i in 0..<ns.length {
        if ns.character(at: i) == 0x000A {
            ranges.append(NSRange(location: lineStart, length: i - lineStart + 1))
            lineStart = i + 1
        }
    }
    if lineStart < ns.length {
        ranges.append(NSRange(location: lineStart, length: ns.length - lineStart))
    }
    return ranges
}

func characterRange(for lineRange: Range<Int>, in text: String) -> NSRange? {
    let ranges = lineCharRanges(text)
    guard !ranges.isEmpty,
          lineRange.lowerBound >= 0,
          lineRange.upperBound <= ranges.count,
          lineRange.lowerBound < lineRange.upperBound else { return nil }
    let start = ranges[lineRange.lowerBound].location
    let end = NSMaxRange(ranges[lineRange.upperBound - 1])
    return NSRange(location: start, length: end - start)
}

/// 语法高亮渲染辅助：HighlightKind → 颜色；span 数组 → AttributedString 前景色。
/// 颜色只是默认调色板（UI 重写时随意换），引擎只负责语义 span（D82）。
enum SyntaxHighlight {
    static func color(for kind: HighlightKind) -> Color {
        switch kind {
        case .keyword: Design.Colors.keyword
        case .string: Design.Colors.string
        case .comment: .secondary
        case .function: Design.Colors.function
        case .type: Design.Colors.type
        case .number: Design.Colors.number
        case .constant: Design.Colors.constant
        case .operator: .secondary
        }
    }

    /// 把行内局部偏移的 span 上色（UTF-8 字节偏移 → String.Index；越界安全）。
    static func apply(_ spans: [HighlightSpan], to text: String, attr: inout AttributedString) {
        guard !spans.isEmpty else { return }
        let utf8 = text.utf8
        for s in spans {
            guard let start = utf8.index(utf8.startIndex, offsetBy: Int(s.start), limitedBy: utf8.endIndex),
                  let end = utf8.index(utf8.startIndex, offsetBy: Int(s.end), limitedBy: utf8.endIndex),
                  let range = Range(start..<end, in: attr) else { continue }
            attr[range].foregroundColor = color(for: s.kind)
        }
    }
}

enum ChangeBadge {
    static func label(_ k: ChangeKind) -> String {
        switch k {
        case .unchanged: return "·"
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .typeChanged: return "T"
        case .untracked: return "U"
        case .ignored: return "I"
        case .conflicted: return "!"
        }
    }
    static func color(_ k: ChangeKind) -> Color {
        switch k {
        case .unchanged: return Design.Colors.secondary.opacity(0.15)
        case .added: return Design.Colors.success
        case .modified: return Design.Colors.info
        case .deleted, .conflicted: return Design.Colors.error
        case .renamed, .typeChanged: return Design.Colors.warning
        case .copied: return Design.Colors.keyword
        case .untracked, .ignored: return .secondary
        }
    }
}

struct Legend: View {
    var body: some View {
        HStack(spacing: 10) {
            legendItem(.added, "新增")
            legendItem(.modified, "修改")
            legendItem(.deleted, "删除")
            legendItem(.untracked, "未跟踪")
        }
    }
    @ViewBuilder
    func legendItem(_ kind: ChangeKind, _ text: String) -> some View {
        HStack(spacing: 3) {
            StatusBadge(kind: kind)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 工具

func dateStr(_ seconds: Int64) -> String {
    Date(timeIntervalSince1970: TimeInterval(seconds))
        .formatted(date: .abbreviated, time: .shortened)
}
