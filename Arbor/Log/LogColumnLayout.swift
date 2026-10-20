import SwiftUI
import AppKit


enum LogColumnID: String, CaseIterable, Hashable, Identifiable {
    case commit
    case author
    case date
    case hash
    case root
    case signature

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .commit: "Commit"
        case .author: "Author"
        case .date: "Date"
        case .hash: "Hash"
        case .root: "Root Names"
        case .signature: "Commit Signature"
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .commit: 276
        case .author: 132
        case .date: 154
        case .hash: 76
        case .root: 180
        case .signature: 156
        }
    }

    var minimumWidth: CGFloat {
        switch self {
        case .commit: 276
        case .author: 88
        case .date: 112
        case .hash: 64
        case .root: 120
        case .signature: 120
        }
    }

    /// IntelliJ's Git signature external-status column has a fixed renderer
    /// width and is not user-resizable.
    var isResizable: Bool {
        self != .signature
    }
}

struct LogColumnLayout: Equatable {
    static let defaultOrder: [LogColumnID] = [.commit, .author, .date, .hash, .root, .signature]

    let order: [LogColumnID]
    let widths: [LogColumnID: CGFloat]

    init(orderRaw: String, widthsRaw: String = "") {
        let parsedOrder = orderRaw
            .split(separator: ",")
            .compactMap { LogColumnID(rawValue: String($0)) }
        order = Self.normalizedOrder(parsedOrder)

        var parsedWidths: [LogColumnID: CGFloat] = [:]
        for entry in widthsRaw.split(separator: ";") {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let column = LogColumnID(rawValue: parts[0]),
                  let width = Double(parts[1]) else { continue }
            parsedWidths[column] = max(column.minimumWidth, CGFloat(width))
        }
        widths = Dictionary(uniqueKeysWithValues: LogColumnID.allCases.map { column in
            (column, parsedWidths[column] ?? column.defaultWidth)
        })
    }

    init(
        order: [LogColumnID] = Self.defaultOrder,
        widths: [LogColumnID: CGFloat] = [:]
    ) {
        self.order = Self.normalizedOrder(order)
        self.widths = Dictionary(uniqueKeysWithValues: LogColumnID.allCases.map { column in
            (column, max(column.minimumWidth, widths[column] ?? column.defaultWidth))
        })
    }

    var orderRaw: String { order.map(\.rawValue).joined(separator: ",") }

    var widthsRaw: String {
        LogColumnID.allCases
            .map { "\($0.rawValue)=\(Int(width(for: $0)))" }
            .joined(separator: ";")
    }

    func width(for column: LogColumnID) -> CGFloat {
        widths[column] ?? column.defaultWidth
    }

    func moving(_ column: LogColumnID, by offset: Int) -> LogColumnLayout {
        guard let index = order.firstIndex(of: column) else { return self }
        let newIndex = index + offset
        guard order.indices.contains(newIndex) else { return self }
        var nextOrder = order
        nextOrder.swapAt(index, newIndex)
        return LogColumnLayout(order: nextOrder, widths: widths)
    }

    func moving(_ column: LogColumnID, before target: LogColumnID) -> LogColumnLayout {
        guard column != target,
              order.contains(column),
              order.contains(target) else { return self }
        var nextOrder = order
        nextOrder.removeAll { $0 == column }
        guard let targetIndex = nextOrder.firstIndex(of: target) else { return self }
        nextOrder.insert(column, at: targetIndex)
        return LogColumnLayout(order: nextOrder, widths: widths)
    }

    func settingWidth(_ width: CGFloat, for column: LogColumnID) -> LogColumnLayout {
        var nextWidths = widths
        nextWidths[column] = max(column.minimumWidth, width)
        return LogColumnLayout(order: order, widths: nextWidths)
    }

    func visibleOrder(
        showAuthor: Bool,
        showDate: Bool,
        showHash: Bool,
        showRoot: Bool,
        showSignature: Bool
    ) -> [LogColumnID] {
        order.filter { column in
            switch column {
            case .commit: true
            case .author: showAuthor
            case .date: showDate
            case .hash: showHash
            case .root: showRoot
            case .signature: showSignature
            }
        }
    }

    private static func normalizedOrder(_ order: [LogColumnID]) -> [LogColumnID] {
        var result: [LogColumnID] = []
        for column in order where !result.contains(column) {
            result.append(column)
        }
        for column in defaultOrder where !result.contains(column) {
            result.append(column)
        }
        return result
    }
}
