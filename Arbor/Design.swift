import SwiftUI
import AppKit
import CoreText

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
    }

    enum Colors {
        static let workspaceFrame = adaptive(
            light: NSColor(calibratedWhite: 0.92, alpha: 1),
            dark: NSColor(calibratedWhite: 0.10, alpha: 1)
        )
        static let logSurface = adaptive(
            light: NSColor(calibratedRed: 0.969, green: 0.973, blue: 0.980, alpha: 1),
            dark: NSColor(calibratedWhite: 0.12, alpha: 1)
        )
        static let accent = Color.accentColor
        static let checkboxBorder = adaptive(
            light: NSColor(calibratedRed: 0.66, green: 0.69, blue: 0.76, alpha: 1),
            dark: NSColor(calibratedRed: 0.47, green: 0.50, blue: 0.56, alpha: 1)
        )
        static let graphPalette: [Color] = [
            adaptive(light: NSColor(calibratedRed: 0.70, green: 0.28, blue: 0.59, alpha: 1),
                     dark: NSColor(calibratedRed: 0.88, green: 0.45, blue: 0.74, alpha: 1)),
            adaptive(light: NSColor(calibratedRed: 0.54, green: 0.29, blue: 0.72, alpha: 1),
                     dark: NSColor(calibratedRed: 0.71, green: 0.50, blue: 0.91, alpha: 1)),
            adaptive(light: NSColor(calibratedRed: 0.27, green: 0.64, blue: 0.71, alpha: 1),
                     dark: NSColor(calibratedRed: 0.34, green: 0.75, blue: 0.82, alpha: 1)),
            .orange, .green, .blue, .indigo
        ]
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
        private static let commitDateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.timeZone = .autoupdatingCurrent
            formatter.dateFormat = "dd/MM/yy h:mm a"
            return formatter
        }()

        static func commitDate(_ timestamp: Int64, locale: Locale = .autoupdatingCurrent) -> String {
            if commitDateFormatter.locale.identifier != locale.identifier {
                commitDateFormatter.locale = locale
                commitDateFormatter.dateFormat = locale.language.languageCode?.identifier == "zh"
                    ? "dd/MM/yy ah:mm" : "dd/MM/yy h:mm a"
            }
            return commitDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
        }

        static func interface(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
            .custom(weight == .semibold || weight == .bold ? "Inter-SemiBold" : "Inter-Regular", size: size).weight(weight)
        }

        static func registerFonts() {
            for name in ["Inter-Regular", "Inter-SemiBold"] {
                if let url = Bundle.main.url(forResource: name, withExtension: "otf") {
                    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
                }
            }
        }

        static let code = Font.system(.body, design: .monospaced)
        static let codeSmall = Font.system(.caption, design: .monospaced)
    }
}
