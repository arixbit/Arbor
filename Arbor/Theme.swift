import AppKit
import SwiftUI

/// B 方案（Linear 式极简、深浅双色）的设计令牌。
///
/// 规则只有两条：
/// 1. 视图里只引用这里的名字，不再出现写死的颜色、字号、间距和圆角；
/// 2. 深浅两套共用同一批令牌名，只换取值——"一套布局、两种模式"。
///
/// 取值来源是 `docs/restyle-b.md` 的令牌表。调色只改这张表，不动引用点，
/// 这样回滚就是"把令牌表换回旧取值"，不需要碰任何结构。
enum Theme {
    /// 令牌角色。逐个列出而不是只给约束，是为了能一次测全深浅两套取值。
    enum Role: CaseIterable {
        /// 窗口与主区底色。
        case window
        /// 搜索框、输入框、次按钮底色：比窗口底略亮（深色）/ 略暗（亮色）一档。
        case surface
        /// Diff 与代码区底色：与窗口底拉开半档，让面板边界靠明暗而不是线。
        case surfaceInset
        /// 主文字与选中态文字。
        case ink
        /// 次要文字：作者、文件说明。
        case inkSecondary
        /// 弱文字：时间、哈希、分组标题。
        case inkTertiary
        /// 头发丝边框与分隔线。
        case border
        /// 全应用唯一的强调色。
        case accent
        /// 分支 / 版本胶囊里的文字。
        case accentInk
        /// 选中行填充。
        case selectionFill
        /// 选中行内描边。
        case selectionStroke
        /// 侧栏导航选中：中性填充，不用强调色大面积铺。
        case navSelection
        /// 列表行悬停。
        case rowHover
        /// 新增（加号计数、Diff 新增）。
        case addition
        /// 删除（减号计数、Diff 删除）。
        case deletion
        /// Diff 新增行底色。
        case additionFill
        /// Diff 删除行底色。
        case deletionFill
        /// 主按钮填充。
        case primaryFill
        /// 主按钮文字。
        case primaryInk
    }

    /// 两种模式完全共用的取值：色相不变，只在透明度或底色上做区分。
    static let sharedRoles: Set<Role> = [
        .accent, .addition, .deletion
    ]

    /// 外观设置的三档取值。沿用现有的 `arbor.appearance` 设置项，不新增入口。
    enum AppearanceOverride {
        static let followSystem = ""
        static let light = "light"
        static let dark = "dark"
    }

    /// 把设置项的原始取值翻成 `preferredColorScheme`：跟随时返回 nil，让窗口读系统外观；
    /// 固定深色 / 亮色时不跟系统走。未知取值一律按跟随处理，不让手改的偏好把窗口卡住。
    static func preferredColorScheme(forOverride value: String) -> ColorScheme? {
        switch value {
        case AppearanceOverride.light: return .light
        case AppearanceOverride.dark: return .dark
        default: return nil
        }
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// 按外观取令牌取值。视图层不直接调用，只在 `color(_:)` 与本文件的测试里用。
    static func nsColor(_ role: Role, appearance: NSAppearance) -> NSColor {
        let dark = isDark(appearance)
        switch role {
        case .window:
            return dark ? NSColor.hex(0x08090A) : NSColor.hex(0xFBFBFA)
        case .surface:
            return dark ? NSColor.hex(0x131417) : NSColor.hex(0xF4F4F2)
        case .surfaceInset:
            return dark ? NSColor.hex(0x0C0D0F) : NSColor.hex(0xFFFFFF)
        case .ink:
            return dark ? NSColor.hex(0xF7F8F8) : NSColor.hex(0x17181A)
        case .inkSecondary:
            return dark ? NSColor.hex(0x8A8F98) : NSColor.hex(0x6E7278)
        case .inkTertiary:
            return dark ? NSColor.hex(0x62666D) : NSColor.hex(0x9AA0A8)
        case .border:
            // 深色用白 7%、亮色用黑 7%：同一条令牌，两种底色下都只是头发丝。
            return dark
                ? NSColor.hex(0xFFFFFF, alpha: 0.07)
                : NSColor.hex(0x000000, alpha: 0.07)
        case .accent:
            return NSColor.hex(0x5E6AD2)
        case .accentInk:
            return dark ? NSColor.hex(0x9BA3F0) : NSColor.hex(0x4C57B8)
        case .selectionFill:
            return dark
                ? NSColor.hex(0x5E6AD2, alpha: 0.13)
                : NSColor.hex(0x5E6AD2, alpha: 0.09)
        case .selectionStroke:
            return dark
                ? NSColor.hex(0x5E6AD2, alpha: 0.35)
                : NSColor.hex(0x5E6AD2, alpha: 0.32)
        case .navSelection:
            return dark
                ? NSColor.hex(0xFFFFFF, alpha: 0.06)
                : NSColor.hex(0x000000, alpha: 0.055)
        case .rowHover:
            return dark
                ? NSColor.hex(0xFFFFFF, alpha: 0.03)
                : NSColor.hex(0x000000, alpha: 0.03)
        case .addition:
            return NSColor.hex(0x3FB27F)
        case .deletion:
            return NSColor.hex(0xE5484D)
        case .additionFill:
            return dark
                ? NSColor.hex(0x3FB27F, alpha: 0.12)
                : NSColor.hex(0x3FB27F, alpha: 0.10)
        case .deletionFill:
            return dark
                ? NSColor.hex(0xE5484D, alpha: 0.12)
                : NSColor.hex(0xE5484D, alpha: 0.10)
        case .primaryFill:
            // 主按钮在深色下是白底黑字、亮色下是黑底白字：反相，不换色相。
            return dark ? NSColor.hex(0xF7F8F8) : NSColor.hex(0x17181A)
        case .primaryInk:
            return dark ? NSColor.hex(0x08090A) : NSColor.hex(0xF7F8F8)
        }
    }

    /// 随外观自动取值的令牌。用法：`Theme.Palette.ink`。
    static func color(_ role: Role) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            nsColor(role, appearance: appearance)
        })
    }

    enum Palette {
        static let window = color(.window)
        static let surface = color(.surface)
        static let surfaceInset = color(.surfaceInset)
        static let ink = color(.ink)
        static let inkSecondary = color(.inkSecondary)
        static let inkTertiary = color(.inkTertiary)
        static let border = color(.border)
        static let accent = color(.accent)
        static let accentInk = color(.accentInk)
        static let selectionFill = color(.selectionFill)
        static let selectionStroke = color(.selectionStroke)
        static let navSelection = color(.navSelection)
        static let rowHover = color(.rowHover)
        static let addition = color(.addition)
        static let deletion = color(.deletion)
        static let additionFill = color(.additionFill)
        static let deletionFill = color(.deletionFill)
        static let primaryFill = color(.primaryFill)
        static let primaryInk = color(.primaryInk)
    }

    /// 尺寸、间距、圆角。两种模式完全一致：切换外观时位置和大小都不许变。
    enum Metrics {
        static let hairline: CGFloat = 1

        static let topBarHeight: CGFloat = 52
        static let navRowHeight: CGFloat = 34
        static let searchFieldHeight: CGFloat = 32
        static let buttonHeight: CGFloat = 36

        static let logRowVerticalPadding: CGFloat = 9
        static let logRowHorizontalPadding: CGFloat = 10
        static let panelVerticalPadding: CGFloat = 18
        static let panelHorizontalPadding: CGFloat = 20

        /// Changes 行下方那条增删比例的色条。
        static let changeBarHeight: CGFloat = 3

        /// 圆角：侧栏导航行最小，行 / 按钮 / 输入框一档，窗口最大。
        static let radiusNavRow: CGFloat = 7
        static let radiusRow: CGFloat = 8
        static let radiusWindow: CGFloat = 12

        /// 选中行的内描边宽度。
        static let selectionStrokeWidth: CGFloat = 1

        /// 加载与禁用态统一用降低透明度表达，不引入新的灰色取值。
        static let disabledOpacity: Double = 0.5
    }

    /// 字号常量。字体族仍是 `Design.Typography` 决定的那一档，这里只用来说大小。
    enum Typography {
        static let bodySize: CGFloat = 13.5
        static let headingSize: CGFloat = 14
        static let captionSize: CGFloat = 11.5
        static let monospaceSize: CGFloat = 11.5
        /// 分组标题（NOV 10 这类日期组头）放宽的字距。
        static let groupTracking: CGFloat = 0.6
    }
}

extension NSColor {
    /// sRGB hex 取值，与 `docs/restyle-b.md` 的令牌表逐位对应。
    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }
}
