import AppKit
import SwiftUI
import XCTest

@testable import Arbor

/// B 方案的令牌表校验：`docs/restyle-b.md` 里定死的数值，这里逐条钉住。
/// 改调色必须连测试一起改，避免某个面板悄悄换回写死的颜色。
final class ThemeTokensTests: XCTestCase {
    private let darkAppearance = NSAppearance(named: .darkAqua)
    private let lightAppearance = NSAppearance(named: .aqua)

    private func resolved(_ role: Theme.Role, dark: Bool) throws -> NSColor {
        let appearance = try XCTUnwrap(dark ? darkAppearance : lightAppearance)
        return try XCTUnwrap(Theme.nsColor(role, appearance: appearance).usingColorSpace(.sRGB))
    }

    private func assertColor(
        _ role: Theme.Role,
        dark: Bool,
        equals hex: UInt32,
        alpha: CGFloat = 1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let color = try resolved(role, dark: dark)
        let expected = NSColor.hex(hex, alpha: alpha)
        XCTAssertEqual(color.redComponent, expected.redComponent, accuracy: 0.002, file: file, line: line)
        XCTAssertEqual(color.greenComponent, expected.greenComponent, accuracy: 0.002, file: file, line: line)
        XCTAssertEqual(color.blueComponent, expected.blueComponent, accuracy: 0.002, file: file, line: line)
        XCTAssertEqual(color.alphaComponent, alpha, accuracy: 0.002, file: file, line: line)
    }

    func testWindowAndTextValuesMatchTheTokenTable() throws {
        try assertColor(.window, dark: true, equals: 0x08090A)
        try assertColor(.window, dark: false, equals: 0xFBFBFA)
        try assertColor(.ink, dark: true, equals: 0xF7F8F8)
        try assertColor(.ink, dark: false, equals: 0x17181A)
        try assertColor(.inkSecondary, dark: true, equals: 0x8A8F98)
        try assertColor(.inkSecondary, dark: false, equals: 0x6E7278)
        try assertColor(.inkTertiary, dark: true, equals: 0x62666D)
        try assertColor(.inkTertiary, dark: false, equals: 0x9AA0A8)
    }

    func testAccentIsTheSameIndigoInBothModes() throws {
        for role in Theme.sharedRoles {
            let dark = try resolved(role, dark: true)
            let light = try resolved(role, dark: false)
            XCTAssertEqual(dark.redComponent, light.redComponent, accuracy: 0.002, "\(role)")
            XCTAssertEqual(dark.greenComponent, light.greenComponent, accuracy: 0.002, "\(role)")
            XCTAssertEqual(dark.blueComponent, light.blueComponent, accuracy: 0.002, "\(role)")
            XCTAssertEqual(dark.alphaComponent, light.alphaComponent, accuracy: 0.002, "\(role)")
        }
        try assertColor(.accent, dark: true, equals: 0x5E6AD2)
        try assertColor(.accent, dark: false, equals: 0x5E6AD2)
        try assertColor(.addition, dark: true, equals: 0x3FB27F)
        try assertColor(.deletion, dark: true, equals: 0xE5484D)
    }

    func testBorderIsSevenPercentOfTheOppositeInkOnBothModes() throws {
        let dark = try resolved(.border, dark: true)
        let light = try resolved(.border, dark: false)
        XCTAssertEqual(dark.alphaComponent, 0.07, accuracy: 0.002)
        XCTAssertEqual(light.alphaComponent, 0.07, accuracy: 0.002)
        XCTAssertGreaterThan(dark.redComponent, 0.95, "深色下边框是白色描出去的")
        XCTAssertLessThan(light.redComponent, 0.05, "亮色下边框是黑色描出去的")
    }

    func testSelectionUsesTheAccentFillAndStrokeInBothModes() throws {
        try assertColor(.selectionFill, dark: true, equals: 0x5E6AD2, alpha: 0.13)
        try assertColor(.selectionFill, dark: false, equals: 0x5E6AD2, alpha: 0.09)
        try assertColor(.selectionStroke, dark: true, equals: 0x5E6AD2, alpha: 0.35)
        try assertColor(.selectionStroke, dark: false, equals: 0x5E6AD2, alpha: 0.32)
    }

    func testSidebarSelectionIsNeutralNotAccent() throws {
        // 侧栏选中不许用强调色大面积铺，否则主区就没有主角了。
        for dark in [true, false] {
            let color = try resolved(.navSelection, dark: dark)
            try assertNeutral(color, role: "navSelection", dark: dark)
            XCTAssertEqual(color.alphaComponent, dark ? 0.06 : 0.055, accuracy: 0.002)
        }
        for dark in [true, false] {
            let color = try resolved(.rowHover, dark: dark)
            try assertNeutral(color, role: "rowHover", dark: dark)
            XCTAssertEqual(color.alphaComponent, 0.03, accuracy: 0.002)
        }
    }

    private func assertNeutral(
        _ color: NSColor,
        role: String,
        dark: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(color.redComponent, color.greenComponent, accuracy: 0.001, "\(role) dark:\(dark)", file: file, line: line)
        XCTAssertEqual(color.greenComponent, color.blueComponent, accuracy: 0.001, "\(role) dark:\(dark)", file: file, line: line)
    }

    func testPrimaryButtonInvertsBetweenModes() throws {
        let darkFill = try resolved(.primaryFill, dark: true)
        let lightFill = try resolved(.primaryFill, dark: false)
        XCTAssertGreaterThan(darkFill.redComponent, 0.9, "深色下主按钮是白底")
        XCTAssertLessThan(lightFill.redComponent, 0.2, "亮色下主按钮是黑底")

        let darkInk = try resolved(.primaryInk, dark: true)
        let lightInk = try resolved(.primaryInk, dark: false)
        XCTAssertLessThan(darkInk.redComponent, 0.2, "深色白底上配黑字")
        XCTAssertGreaterThan(lightInk.redComponent, 0.9, "亮色黑底上配白字")
    }

    func testDiffFillsKeepTextReadable() throws {
        // Diff 行底色只染背景，不把整行染成绿字 / 红字。
        for dark in [true, false] {
            XCTAssertLessThanOrEqual(try resolved(.additionFill, dark: dark).alphaComponent, 0.13)
            XCTAssertLessThanOrEqual(try resolved(.deletionFill, dark: dark).alphaComponent, 0.13)
        }
        try assertColor(.additionFill, dark: true, equals: 0x3FB27F, alpha: 0.12)
        try assertColor(.deletionFill, dark: true, equals: 0xE5484D, alpha: 0.12)
        try assertColor(.additionFill, dark: false, equals: 0x3FB27F, alpha: 0.10)
        try assertColor(.deletionFill, dark: false, equals: 0xE5484D, alpha: 0.10)
    }

    func testTextHierarchyDimsDownInBothModes() throws {
        // 深色里「更亮」= 更重要，亮色里「更暗」= 更重要，所以比的是离底色的距离，
        // 不是绝对亮度。
        for dark in [true, false] {
            let background = luminance(try resolved(.window, dark: dark))
            let ink = luminance(try resolved(.ink, dark: dark))
            let secondary = luminance(try resolved(.inkSecondary, dark: dark))
            let tertiary = luminance(try resolved(.inkTertiary, dark: dark))
            XCTAssertGreaterThan(abs(ink - background), abs(secondary - background), "dark:\(dark)")
            XCTAssertGreaterThan(abs(secondary - background), abs(tertiary - background), "dark:\(dark)")
        }
    }

    private func luminance(_ color: NSColor) -> CGFloat {
        // 相对亮度，够用来比较"谁更亮"，不用于颜色科学。
        0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
    }

    func testEveryRoleResolvesAndOnlySharedRolesMatchAcrossModes() throws {
        for role in Theme.Role.allCases {
            let dark = try resolved(role, dark: true)
            let light = try resolved(role, dark: false)
            let matches = dark.redComponent == light.redComponent
                && dark.greenComponent == light.greenComponent
                && dark.blueComponent == light.blueComponent
                && dark.alphaComponent == light.alphaComponent
            XCTAssertEqual(
                matches,
                Theme.sharedRoles.contains(role),
                "\(role) 在深浅两套里的取值关系不符合令牌表"
            )
        }
    }

    func testMetricsMatchTheTokenTable() {
        XCTAssertEqual(Theme.Metrics.topBarHeight, 52)
        XCTAssertEqual(Theme.Metrics.navRowHeight, 34)
        XCTAssertEqual(Theme.Metrics.searchFieldHeight, 32)
        XCTAssertEqual(Theme.Metrics.buttonHeight, 36)
        XCTAssertEqual(Theme.Metrics.radiusNavRow, 7)
        XCTAssertEqual(Theme.Metrics.radiusRow, 8)
        XCTAssertEqual(Theme.Metrics.radiusWindow, 12)
        XCTAssertEqual(Theme.Metrics.logRowVerticalPadding, 9)
        XCTAssertEqual(Theme.Metrics.logRowHorizontalPadding, 10)
        XCTAssertEqual(Theme.Metrics.panelVerticalPadding, 18)
        XCTAssertEqual(Theme.Metrics.hairline, 1)
        XCTAssertEqual(Theme.Metrics.selectionStrokeWidth, 1)
        XCTAssertEqual(Theme.Metrics.disabledOpacity, 0.5)
    }

    func testTypographySizesMatchTheTokenTable() {
        XCTAssertEqual(Theme.Typography.bodySize, 13.5)
        XCTAssertEqual(Theme.Typography.headingSize, 14)
        XCTAssertEqual(Theme.Typography.captionSize, 11.5)
        XCTAssertEqual(Theme.Typography.monospaceSize, 11.5)
    }

    func testAppearanceSettingKeepsItsThreeStates() {
        // 跟随系统是 nil（读系统外观），固定深色 / 亮色不跟系统走。
        XCTAssertNil(Theme.preferredColorScheme(forOverride: Theme.AppearanceOverride.followSystem))
        XCTAssertEqual(Theme.preferredColorScheme(forOverride: Theme.AppearanceOverride.dark), .dark)
        XCTAssertEqual(Theme.preferredColorScheme(forOverride: Theme.AppearanceOverride.light), .light)
        // 旧安装里可能存着别的字符串，不能因此把窗口固定在某个模式里。
        XCTAssertNil(Theme.preferredColorScheme(forOverride: "auto"))
        XCTAssertNil(Theme.preferredColorScheme(forOverride: "Dark "))
    }

    func testPaletteCoversEveryRole() {
        // 视图里只引用 `Theme.Palette.*`。任何一个角色漏了 Palette 入口，
        // 后面换肤时就会有人重新写死一个颜色值。
        let tokens: [Color] = [
            Theme.Palette.window, Theme.Palette.surface, Theme.Palette.surfaceInset,
            Theme.Palette.ink, Theme.Palette.inkSecondary, Theme.Palette.inkTertiary,
            Theme.Palette.border, Theme.Palette.accent, Theme.Palette.accentInk,
            Theme.Palette.selectionFill, Theme.Palette.selectionStroke,
            Theme.Palette.navSelection, Theme.Palette.rowHover,
            Theme.Palette.addition, Theme.Palette.deletion,
            Theme.Palette.additionFill, Theme.Palette.deletionFill,
            Theme.Palette.primaryFill, Theme.Palette.primaryInk
        ]
        XCTAssertEqual(tokens.count, Theme.Role.allCases.count)
    }
}
