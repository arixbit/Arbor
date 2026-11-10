import XCTest
import AppKit

/// Dumps the accessibility tree of both applications, surface by surface, so the
/// two user surfaces can be compared mechanically instead of by eye.
///
/// A screenshot answers "where does it look different"; the accessibility tree
/// answers "which control is missing, which one moved, which one is disabled".
/// That is the defect class this project actually fights — the replica has the
/// same job to do with different names, so a control that never got built shows
/// up here as a named row instead of as a rectangle of red pixels.
///
/// `scripts/ui-parity.py` consumes the dumps.
final class ArborUIParityUITests: XCTestCase {
    /// Both captures use the same window size so frames are directly comparable.
    static let targetSize = CGSize(width: 1642, height: 1015)
    static let rebasedBundleIdentifier = "io.github.detachhead.rebased"

    static var treeDirectory: URL {
        ArborUIFixture.repositoryRoot.appendingPathComponent("build/parity/tree", isDirectory: true)
    }

    /// 带裁剪矩形的导出：窗口内的浮层（分支弹层这类）没有独立的无障碍子树，
    /// 只能在整窗树里认出来。首行写 `#CLIP x,y,w,h`（窗口相对坐标），
    /// `scripts/ui-parity.py` 会据此把浮层区域切出来。
    private func dumpClipped(_ description: String, clip: CGRect, named name: String) throws {
        let header = String(
            format: "#CLIP %d,%d,%d,%d\n",
            Int(clip.minX), Int(clip.minY), Int(clip.width), Int(clip.height)
        )
        try dump(header + description, named: name)
    }

    private func dump(_ description: String, named name: String) throws {
        // The test runner is sandboxed, so the tree cannot be written straight into
        // the checkout. It travels as an attachment and `scripts/ui-parity.sh`
        // exports it, which is the same channel the screenshots already use.
        let attachment = XCTAttachment(string: description)
        attachment.name = "tree-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Best effort: when the suite is run outside the sandbox the dump lands
        // in place immediately and can be inspected without an export step.
        let directory = Self.treeDirectory
        if (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil {
            try? description.write(
                to: directory.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        }
        print("[parity] \(name) — \(description.split(separator: "\n").count) lines")
    }

    // MARK: - Arbor

    /// The window title is the only reliable statement of which surface is on
    /// screen. Assuming the surface instead produced a Log capture filed as a
    /// Commit one, which compares every row against the wrong reference.
    private func surfaceTag(of window: XCUIElement, fallback: String) -> String {
        let title = window.title.lowercased()
        if title.contains("commit") { return "commit" }
        if title.contains("log") || title.contains("history") { return "log" }
        return fallback
    }

    /// Both dumps must describe the same canvas, otherwise every coordinate to
    /// the right of the first split differs by the window size difference.
    /// 窗口靠右时右下角拖不出更宽的窗口：右边缘已经顶到屏幕。先把窗口挪到屏幕
    /// 左缘，再拖角。参考实现默认停在 (200, 59)，于是它只能长到 1600 pt，
    /// 而 Arbor 是 1642 pt——42 pt 的差会让右侧每个控件都「位置不一致」。
    @MainActor
    private func moveToLeftEdge(_ window: XCUIElement) {
        let bar = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02))
        bar.press(forDuration: 0.3, thenDragTo: bar.withOffset(CGVector(dx: -window.frame.minX + 4, dy: 0)))
        Thread.sleep(forTimeInterval: 0.8)
    }

    @MainActor
    private func resize(_ window: XCUIElement, to size: CGSize) {
        if window.frame.width < size.width {
            moveToLeftEdge(window)
        }
        let screen = NSScreen.main?.visibleFrame.size ?? size
        let target = CGSize(width: min(size.width, screen.width), height: min(size.height, screen.height))
        for _ in 0..<2 {
            let delta = CGVector(dx: target.width - window.frame.width, dy: target.height - window.frame.height)
            if abs(delta.dx) < 2 && abs(delta.dy) < 2 { return }
            let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
                .withOffset(CGVector(dx: -2, dy: -2))
            corner.press(forDuration: 0.3, thenDragTo: corner.withOffset(delta))
            Thread.sleep(forTimeInterval: 1.0)
        }
        print("[parity] window at \(window.frame.size), wanted \(target)")
    }

    @MainActor
    func testDumpArborTrees() throws {
        try XCTSkipUnless(
            NSScreen.main?.visibleFrame.width ?? 0 >= Self.targetSize.width,
            "the runner display cannot host the comparison layout"
        )
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }

        // Same stored layout the visual baseline uses, so the two dumps describe
        // the same arrangement the screenshots show.
        let layout = [
            "-arbor.toolWindowExpanded", "YES",
            "-arbor.projectPanelExpanded.v3", "YES",
            "-arbor.workspaceSidebarWidth.v12", "582",
            "-arbor.toolWindowHeight.v3", "466",
            "-arbor.logGraphWidth.v8", "688",
            "-arbor.log.showDetails.v1", "YES",
            "-arbor.log.branches.visible.v1", "NO",
        ]

        do {
            let session = ArborUISession(fixture: fixture)
            session.extraLaunchArguments = layout + ["-arbor.toolWindowMode", "commit"]
            session.launch()
            resize(session.window, to: Self.targetSize)
            try dump(session.window.debugDescription, named: "arbor-commit")
            session.terminate()
        }

        do {
            let session = ArborUISession(fixture: fixture, toolWindow: "log")
            session.extraLaunchArguments = layout
            session.launch()
            XCTAssertTrue(session.openProjectTree(), "the activity rail did not open the project tree")
            resize(session.window, to: Self.targetSize)
            try dump(session.window.debugDescription, named: "arbor-log")
            session.terminate()
        }

        // 分支弹层是窗口内的浮层：没有独立子树，所以导整窗树 + 裁剪矩形。
        do {
            let session = ArborUISession(fixture: fixture)
            session.extraLaunchArguments = layout
            session.launch()
            // 弹层有时在启动后第一次点击里没打开（仓库数据还在加载），重试几次；
            // 不重试的话这条基线会随机变成「全部消失」，把快照闸门弄成假红。
            var opened = false
            for _ in 0..<3 where !opened {
                opened = session.openBranchesPopover()
                if !opened { Thread.sleep(forTimeInterval: 1.5) }
            }
            XCTAssertTrue(opened, "the branch chip did not open the branches popover")
            let panel = session.app.descendants(matching: .any)["branches-popover-panel"].firstMatch
            XCTAssertTrue(panel.waitForExistence(timeout: 10),
                          "the branches popover has no container identity")
            let origin = session.window.frame.origin
            let clip = CGRect(
                x: panel.frame.minX - origin.x,
                y: panel.frame.minY - origin.y,
                width: panel.frame.width,
                height: panel.frame.height
            )
            try dumpClipped(session.window.debugDescription, clip: clip, named: "arbor-branches")
            session.terminate()
        }

        // 贮藏面板：切到提交面板的 Stash 标签，再按左侧那一列的滚动区裁剪。
        do {
            let session = ArborUISession(fixture: fixture)
            session.extraLaunchArguments = layout + ["-arbor.toolWindowMode", "commit"]
            session.launch()
            let stashTab = session.window.buttons["Stash"].firstMatch
            XCTAssertTrue(stashTab.waitForExistence(timeout: 10), "the commit panel has no Stash tab")
            stashTab.click()
            Thread.sleep(forTimeInterval: 1.0)
            // 导出的范围是左侧列表的可视区；Stashes 分组收起时里面只有标题行，
            // 展开状态由用户的偏好决定。这一点先如实记录，不在测试里替用户改状态。
            let origin = session.window.frame.origin
            let panel = session.app.descendants(matching: .any)["stash-panel"].firstMatch
            XCTAssertTrue(panel.waitForExistence(timeout: 10), "the stash panel has no container identity")
            if true {
                let clip = CGRect(
                    x: panel.frame.minX - origin.x,
                    y: panel.frame.minY - origin.y,
                    width: panel.frame.width,
                    height: panel.frame.height
                )
                try dumpClipped(session.window.debugDescription, clip: clip, named: "arbor-stash")
            }
            session.terminate()
        }

        // Settings 是独立窗口，不在主窗口的子树里，所以单独导一份——它同样属于
        // 用户能看见的界面，值得进快照基线。
        do {
            let session = ArborUISession(fixture: fixture)
            session.launch()
            XCTAssertTrue(session.openSettings(), "the application menu did not open a Settings window")
            // 直接 dump 那个 window 元素只拿到嵌套的 window 行（XCUITest 对独立窗口
            // 的子树叶给出的就是这样）。openSettings() 已经把观察根切到设置窗口，
            // 用它产出的整棵树才是用户真正看见的内容。
            try dump(session.screenState().signature, named: "arbor-settings")
            session.terminate()
        }
    }

    // MARK: - Reference

    @MainActor
    func testDumpRebasedTrees() throws {
        // Arbor 侧的导出在 CI 上也有用（ui-snapshot.sh 拿它当基线），参考侧没有。
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil,
                      "the reference application is not installed on CI runners")
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.rebasedBundleIdentifier) != nil else {
            throw XCTSkip("Rebased is not installed")
        }
        let rebased = XCUIApplication(bundleIdentifier: Self.rebasedBundleIdentifier)
        guard rebased.state != .notRunning else {
            throw XCTSkip("Rebased is not running; open the fixture project in it first")
        }
        rebased.activate()
        Thread.sleep(forTimeInterval: 1)

        let window = rebased.windows
            .matching(NSPredicate(format: "title CONTAINS %@", "visual-fixture"))
            .firstMatch
        guard window.waitForExistence(timeout: 10) else {
            throw XCTSkip("Rebased has no window for the visual-fixture project")
        }
        resize(window, to: Self.targetSize)

        // Only what is actually on screen is dumped, filed under the surface its
        // title claims. Navigating the reference IDE from a test would mean blind
        // clicks in the user's editor, so the surface is observed, not forced.
        // 参考 IDE 的窗口状态会跨运行保留（上一轮开着的工具窗这一轮还开着），
        // 所以先观察再决定导出哪两个界面，而不是假设。
        //
        // 重开 Commit 工具窗需要一个可靠的按钮，而树里叫 "Commit" 的按钮既可能是
        // 活动栏入口、也可能是提交动作本身——点错就在用户的仓库里提交了一次。
        // 所以这里只用参考脚本里已经在用的那个隐藏按钮坐标（一个纯 UI 切换），
        // 反向（开）不做。
        let commitPanel = window.checkBoxes["Amend"].firstMatch
        if commitPanel.waitForExistence(timeout: 3) {
            try dump(window.debugDescription, named: "rebased-commit")
            window.coordinate(withNormalizedOffset: CGVector(dx: 595.0 / 1642.0, dy: 59.0 / 1015.0)).click()
            Thread.sleep(forTimeInterval: 1.5)
        }
        try dump(window.debugDescription, named: "rebased-log")
        print("[parity] Rebased 当前界面：\(window.title)")

        // Branches… 打开的是一个独立窗口（实测 375×353、无标题），不在主窗口的树里。
        // 用「动作前后的窗口集合差集」把它找出来，再导它的子树——比点坐标安全，
        // 也比导整棵树干净。
        func windowSignatures() -> [String] {
            rebased.windows.allElementsBoundByIndex.map {
                "\($0.title)|\(Int($0.frame.minX)),\(Int($0.frame.minY)),"
                    + "\(Int($0.frame.width))x\(Int($0.frame.height))"
            }
        }
        let before = Set(windowSignatures())
        rebased.menuBars.menuBarItems["Git"].firstMatch.click()
        let branchesItem = rebased.menuItems["Branches…"].firstMatch
        if branchesItem.waitForExistence(timeout: 3) {
            branchesItem.click()
            Thread.sleep(forTimeInterval: 1.5)
            let after = windowSignatures()
            if let index = after.firstIndex(where: { !before.contains($0) }) {
                let popup = rebased.windows.element(boundBy: index)
                try dump(popup.debugDescription, named: "rebased-branches")
                rebased.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            } else {
                print("[parity] Branches: 没有出现新窗口，跳过")
            }
        } else {
            rebased.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            print("[parity] Branches: 菜单项不存在，跳过")
        }

        // Show Git Stash 不开新窗口：它在主窗口里加一块「Stash Tool Window」。
        // 实测那块是可裁出来的，所以按它自己的边框裁剪导出。
        rebased.menuBars.menuBarItems["Git"].firstMatch.click()
        let stashItem = rebased.menuItems["Show Git Stash"].firstMatch
        if stashItem.waitForExistence(timeout: 3) {
            stashItem.click()
            Thread.sleep(forTimeInterval: 1.5)
            // 这块是 Group，标识为空、只有 label，所以要按 label 的谓词去找。
            let tool = rebased.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Stash Tool Window")).firstMatch
            if tool.waitForExistence(timeout: 5) {
                let origin = window.frame.origin
                let clip = CGRect(
                    x: tool.frame.minX - origin.x,
                    y: tool.frame.minY - origin.y,
                    width: tool.frame.width,
                    height: tool.frame.height
                )
                let header = String(
                    format: "#CLIP %d,%d,%d,%d\n",
                    Int(clip.minX), Int(clip.minY), Int(clip.width), Int(clip.height)
                )
                try dump(header + window.debugDescription, named: "rebased-stash")
            } else {
                print("[parity] Stash: 没找到 Stash Tool Window，跳过")
            }
        } else {
            rebased.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            print("[parity] Stash: 菜单项不存在，跳过")
        }
    }
}
