import SwiftUI
import AppKit

/// Arbor v0.13 的轻量视觉 token。颜色使用 macOS 语义色，自动适配浅色/深色模式。
enum Design {
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 14
    }

    enum Colors {
        static let accent = Color.accentColor
        static let secondary = Color.secondary
        static let surface = Color(nsColor: .controlBackgroundColor)
        static let canvas = Color(nsColor: .windowBackgroundColor)
        static let chrome = adaptive(
            light: NSColor(calibratedWhite: 0.96, alpha: 1),
            dark: NSColor(calibratedWhite: 0.105, alpha: 1)
        )
        static let chromeElevated = adaptive(
            light: NSColor(calibratedWhite: 0.98, alpha: 1),
            dark: NSColor(calibratedWhite: 0.115, alpha: 1)
        )
        static let chromeInset = adaptive(
            light: NSColor.textBackgroundColor,
            dark: NSColor(calibratedWhite: 0.07, alpha: 1)
        )
        static let selection = Color.accentColor.opacity(0.14)
        static let addition = Color.green.opacity(0.14)
        static let deletion = Color.red.opacity(0.14)
        static let warning = Color.orange.opacity(0.16)
        static let error = Color.red
        static let success = Color.green
        static let info = Color.blue
        static let keyword = Color.purple
        static let string = Color.red
        static let function = Color.blue
        static let type = Color.teal
        static let number = Color.orange
        static let constant = Color.pink

        private static func adaptive(light: NSColor, dark: NSColor) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            })
        }
    }

    enum Typography {
        static let code = Font.system(.body, design: .monospaced)
        static let codeSmall = Font.system(.caption, design: .monospaced)
    }
}
