import XCTest
import AppKit

/// Click every visible control on the surfaces Arbor's own workflow touches
/// first, and require that each click produces something the user can observe:
/// a list change, a dialog, a message, or a state change.
///
/// A control that reacts to a click with nothing at all is reported as DEAD
/// and fails the test. That is the difference between "the control exists" and
/// "the control works", which is what this suite is for.
final class ArborUISmokeUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - Screens

    @MainActor
    func testCommitScreenControlsReact() throws {
        try sweepScreen(named: "commit", toolWindow: "commit")
    }

    @MainActor
    func testLogScreenControlsReact() throws {
        try sweepScreen(named: "log", toolWindow: "log")
    }

    /// 每个可交互控件都应该有名字。没有 label/title 的按钮在无障碍树里只剩图标名，
    /// 辅助技术读不出它是干什么的——之前 Commit Message History 这类入口就是这么
    /// 被漏掉的（图标在、名字不在）。
    @MainActor
    func testEveryInteractiveControlIsNamed() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }

        var offenders: [String] = []
        for surface in ["commit", "log", "settings"] {
            let session = ArborUISession(fixture: fixture, toolWindow: "commit")
            session.launch()
            defer { session.terminate() }
            if surface == "settings" {
                XCTAssertTrue(session.openSettings(), "the application menu did not open Settings")
            }

            let types: [XCUIElement.ElementType] = [
                .button, .menuButton, .checkBox, .textField, .popUpButton, .radioButton,
            ]
            let observationRoot = surface == "settings" ? (session.observationRoot ?? session.app) : session.window
            for type in types {
                for element in observationRoot.descendants(matching: type).allElementsBoundByIndex {
                    let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
                    let title = element.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    // macOS 上菜单按钮常常只有 title 没有 label，两者都算「有名字」。
                    guard label.isEmpty, title.isEmpty else { continue }
                    // 窗口按钮（关闭/最小化/全屏）、分隔条手柄和系统滚动条没有名字是正常的。
                    if element.identifier.hasPrefix("_XCUI:") { continue }
                    if element.frame.height < 8 || element.frame.width < 8 { continue }
                    if isSystemScrollChrome(element) { continue }
                    let frame = element.frame
                    offenders.append(String(
                        format: "%@/%@ at %.0f,%.0f %.0fx%.0f",
                        surface,
                        element.identifier.isEmpty ? "«no identifier»" : element.identifier,
                        frame.minX, frame.minY, frame.width, frame.height
                    ))
                }
            }
        }
        XCTAssertEqual(
            offenders, [],
            "interactive controls without a name: \(offenders.joined(separator: " | "))"
        )

        // 第二种情况：有名字，但名字就是 SF Symbol 的标识符。界面上看到的是图标，
        // 辅助技术念出来的是 "arrow up forward app" 这种机器名。
        let symbolTokens = [
            "arrow", "chevron", "ellipsis", "circle", "square", "rectangle",
            "fill", "badge", "bubble", "tray", "clock", "doc.", "line.",
        ]
        var symbolLeaks: [String] = []
        for surface in ["commit", "log", "settings"] {
            let session = ArborUISession(fixture: fixture, toolWindow: "commit")
            session.launch()
            defer { session.terminate() }
            if surface == "settings" {
                XCTAssertTrue(session.openSettings(), "the application menu did not open Settings")
            }
            for type in [XCUIElement.ElementType.button, .menuButton, .popUpButton] {
                for element in session.app.descendants(matching: type).allElementsBoundByIndex {
                    let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !label.contains(" "),
                          label.contains("."),
                          label == label.lowercased() else { continue }
                    let lowered = label.lowercased()
                    guard symbolTokens.contains(where: { lowered.contains($0) }) else { continue }
                    let frame = element.frame
                    symbolLeaks.append(String(
                        format: "%@: %@ id=%@ at %.0f,%.0f",
                        surface, label,
                        element.identifier.isEmpty ? "none" : element.identifier,
                        frame.minX, frame.minY
                    ))
                }
            }
        }
        XCTAssertEqual(
            symbolLeaks, [],
            "controls labelled with their SF Symbol name: \(symbolLeaks.joined(separator: " | "))"
        )
    }

    /// 弹层和面板里的控件也要有名字。这两块是动态内容（打开后才存在），
    /// 所以单独一条测试，失败时能一眼看出是哪一块。
    @MainActor
    func testPopoverAndPanelControlsAreNamed() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }

        var offenders: [String] = []

        func sweep(_ surface: String, in app: XCUIApplication) {
            for type in [XCUIElement.ElementType.button, .menuButton, .checkBox, .textField, .popUpButton] {
                for element in app.descendants(matching: type).allElementsBoundByIndex {
                    let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
                    let title = element.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard label.isEmpty, title.isEmpty else { continue }
                    if element.identifier.hasPrefix("_XCUI:") { continue }
                    if element.frame.height < 8 || element.frame.width < 8 { continue }
                    if isSystemScrollChrome(element) { continue }
                    offenders.append("\(surface)/\(element.identifier.isEmpty ? "«no identifier»" : element.identifier)")
                }
            }
        }

        do {
            let session = ArborUISession(fixture: fixture)
            session.launch()
            defer { session.terminate() }
            XCTAssertTrue(session.openBranchesPopover(), "the branches popover did not open")
            sweep("branches", in: session.app)
        }

        do {
            let session = ArborUISession(fixture: fixture, toolWindow: "commit")
            session.launch()
            defer { session.terminate() }
            // A previous launch can persist the Commit tool window as collapsed.
            session.activityRailButton("slider.horizontal.3")?.click()
            let stashTab = session.window.buttons["Stash"].firstMatch
            XCTAssertTrue(stashTab.waitForExistence(timeout: 10), "the commit panel has no Stash tab")
            stashTab.click()
            Thread.sleep(forTimeInterval: 1.0)
            sweep("stash", in: session.app)
        }

        XCTAssertEqual(
            offenders, [],
            "controls without a name in popovers/panels: \(offenders.joined(separator: " | "))"
        )
    }

    /// 对话框里的控件也要有名字。对话框是模态的，单独一条测试；只打开不执行，
    /// 扫完立刻 Escape 关掉。
    @MainActor
    func testDialogControlsAreNamed() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let session = ArborUISession(fixture: fixture, toolWindow: "commit", screenshotSink: { self.add($0) })
        session.launch()
        defer { session.terminate() }

        let push = session.window.buttons["Push"].firstMatch
        XCTAssertTrue(push.waitForExistence(timeout: 10), "the toolbar has no Push action")
        push.click()
        let sheet = session.app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Push did not open a dialog")
        Thread.sleep(forTimeInterval: 0.8)

        var offenders: [String] = []
        for type in [XCUIElement.ElementType.button, .menuButton, .checkBox, .textField, .popUpButton] {
            for element in sheet.descendants(matching: type).allElementsBoundByIndex {
                let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = element.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard label.isEmpty, title.isEmpty else { continue }
                if element.identifier.hasPrefix("_XCUI:") { continue }
                if element.frame.height < 8 || element.frame.width < 8 { continue }
                if isSystemScrollChrome(element) { continue }
                offenders.append("\(element.identifier.isEmpty ? "«no identifier»" : element.identifier)")
            }
        }
        session.app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertEqual(
            offenders, [],
            "controls without a name in dialogs: \(offenders.joined(separator: " | "))"
        )
    }

    @MainActor
    func testProjectTreeControlsReact() throws {
        try sweepScreen(named: "project-tree", toolWindow: "log") { session in
            XCTAssertTrue(session.openProjectTree(), "the project tree rail button did not open the tree")
        }
    }

    @MainActor
    func testBranchesPopoverControlsReact() throws {
        try sweepScreen(named: "branches", toolWindow: "commit") { session in
            XCTAssertTrue(session.openBranchesPopover(), "the branch chip did not open the branches popover")
        }
    }

    /// The branches popup now lives in the window instead of a system popover,
    /// so its dismissal has to be verified explicitly.
    @MainActor
    func testBranchesPopoverClosesLikeAPopover() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }

        let session = ArborUISession(fixture: fixture, screenshotSink: { self.add($0) })
        session.launch()
        defer { session.terminate() }

        XCTAssertTrue(session.openBranchesPopover(), "the branch chip did not open the branches popover")
        session.app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(
            session.app.descendants(matching: .any)["branches-popover-search"].firstMatch
                .arborWaitForNonExistence(timeout: 5),
            "Escape must close the branches popup"
        )

        XCTAssertTrue(session.openBranchesPopover())
        // Clicking outside the popup closes it, as a popover would.
        let editor = session.window.staticTexts["Project"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(
            session.app.descendants(matching: .any)["branches-popover-search"].firstMatch
                .arborWaitForNonExistence(timeout: 5),
            "clicking outside must close the branches popup"
        )
        session.recordScreenshot(named: "branches-popup-dismissed")
    }

    /// 真实仓库里分支可能上百个。参考实现的菜单在这种规模下只能滚，Arbor 的弹层
    /// 靠搜索——规模一大就得证明搜索真的把列表收窄了，而不是只把页面撑长。
    @MainActor
    func testBranchesPopoverStaysUsableWithManyBranches() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }

        // UI 测试进程是沙箱，跑不了 git，所以直接写 refs。
        let head = try String(contentsOf: fixture.appendingPathComponent(".git/refs/heads/main"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 用顶层分支名，避免弹层按目录分组把行藏到折叠的组里。
        let refsRoot = fixture.appendingPathComponent(".git/refs/heads")
        for index in 1...150 {
            let name = String(format: "scale-branch-%03d", index)
            try (head + "\n").write(
                to: refsRoot.appendingPathComponent(name), atomically: true, encoding: .utf8
            )
        }

        let session = ArborUISession(fixture: fixture, screenshotSink: { self.add($0) })
        session.launch()
        defer { session.terminate() }
        XCTAssertTrue(session.openBranchesPopover(), "the branches popover did not open with 150 extra branches")

        // 列表是 LazyVStack：只有可视区内的行会被实例化。用 VStack 时 150 个分支
        // 会全部进无障碍树（坐标一直排到 4400 pt），打开弹层明显变慢，辅助技术也要
        // 遍历整棵树。这里直接数树里的分支行来证明它确实是懒加载的。
        let rendered = session.app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "scale-branch-")).count
        XCTAssertLessThan(
            rendered, 150,
            "\(rendered) branch rows were instantiated: the list is not lazy"
        )

        // 懒加载不等于能用：滚到底要能看到最后一个分支。
        let list = session.app.descendants(matching: .any)["branch-reference-list"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let lastQuery = session.app.descendants(matching: .any)
            .matching(NSPredicate(format: "label ENDSWITH %@", "scale-branch-150"))
        // 滚动方向在 XCUITest 里取决于内容坐标系，两个方向都试，够远就行。
        for delta in [-300.0, 300.0] {
            for _ in 0..<20 {
                if lastQuery.firstMatch.exists { break }
                list.scroll(byDeltaX: 0, deltaY: delta)
                Thread.sleep(forTimeInterval: 0.15)
            }
            if lastQuery.firstMatch.exists { break }
        }
        let lastRow = session.app.descendants(matching: .any)
            .matching(NSPredicate(format: "label ENDSWITH %@", "scale-branch-150")).firstMatch
        XCTAssertTrue(lastRow.exists, "scrolling to the end did not reach the last branch")
        session.recordScreenshot(named: "branches-popover-many")
    }

    @MainActor
    func testSettingsControlsReact() throws {
        // Browse… opens a system panel and is skipped by policy, and Reset to
        // PATH default is disabled while the selection already is the default:
        // two controls is the correct expectation for a fresh profile.
        try sweepScreen(named: "settings", toolWindow: "commit", minimumControls: 2) { session in
            XCTAssertTrue(session.openSettings(), "the application menu did not open a Settings window")
        }
    }

    // MARK: - Harness

    @MainActor
    private func sweepScreen(
        named name: String,
        toolWindow: String,
        minimumControls: Int = 4,
        open: ((ArborUISession) -> Void)? = nil
    ) throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }

        let session = ArborUISession(fixture: fixture, toolWindow: toolWindow, screenshotSink: { self.add($0) })
        session.launch()
        defer { session.terminate() }

        if let open {
            open(session)
        }
        session.recordScreenshot(named: "\(name)-before")

        let findings = session.sweep(screen: name, reopen: open)
        session.attachReport(findings, named: "\(name)-report")
        session.recordScreenshot(named: "\(name)-after")

        print("=== SWEEP \(name) (\(findings.count) controls) ===")
        for finding in findings { print("  " + finding.description) }
        print("=== END SWEEP \(name) ===")

        let failures = ArborUISession.failures(in: findings)
        if !failures.isEmpty {
            let lines = failures.map { "  " + $0.description }.joined(separator: "\n")
            XCTFail("\(failures.count) control(s) on “\(name)” did nothing observable:\n\(lines)")
        }

        XCTAssertGreaterThanOrEqual(
            findings.count, minimumControls,
            "the sweep only found \(findings.count) controls on “\(name)”; the surface likely failed to load"
        )
    }
}

/// Targeted assertions for controls whose reaction the generic sweep cannot
/// read from the accessibility tree.
final class ArborUISmokeContractUITests: XCTestCase {
    @MainActor
    func testCommitStructureAndRelocatedActions() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let session = ArborUISession(fixture: fixture, toolWindow: "commit", screenshotSink: { self.add($0) })
        session.launch()
        defer { session.terminate() }

        XCTAssertTrue(session.window.buttons["Update"].firstMatch.isHittable)
        XCTAssertTrue(session.window.buttons["Push"].firstMatch.isHittable)
        XCTAssertFalse(session.window.descendants(matching: .any)["More Git Actions"].exists)
        XCTAssertFalse(session.window.buttons["Partial stage"].exists)
        XCTAssertFalse(session.window.buttons["Stage all changes"].exists)
        XCTAssertFalse(session.window.buttons["New Changelist"].exists)
        XCTAssertFalse(session.window.checkBoxes["Include group: Changes"].firstMatch.isSelected)

        let refresh = session.window.buttons["Refresh"].firstMatch
        let rollback = session.window.buttons["Rollback…"].firstMatch
        let diff = session.window.buttons["Show Diff"].firstMatch
        let shelve = session.window.buttons["Shelve Silently"].firstMatch
        let options = session.window.descendants(matching: .any)["changes-view-options"].firstMatch
        XCTAssertLessThan(refresh.frame.minX, rollback.frame.minX)
        XCTAssertLessThan(rollback.frame.minX, diff.frame.minX)
        XCTAssertLessThan(diff.frame.minX, shelve.frame.minX)
        XCTAssertLessThan(shelve.frame.minX, options.frame.minX)

        options.click()
        session.app.menuItems["Hide Tool Window"].firstMatch.click()
        let collapsed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !shelve.isHittable },
            object: shelve
        )
        XCTAssertEqual(XCTWaiter.wait(for: [collapsed], timeout: 5), .completed, "hiding Commit must collapse its toolbar")
        session.window.buttons["slider.horizontal.3"].firstMatch.click()
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in shelve.isHittable },
            object: shelve
        )
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)

        options.click()
        let stageAll = session.app.menuItems["Stage all changes"].firstMatch
        XCTAssertTrue(stageAll.waitForExistence(timeout: 5))
        XCTAssertTrue(session.app.menuItems["New Changelist"].firstMatch.exists)
        stageAll.click()
        let changes = session.window.checkBoxes["Include group: Changes"].firstMatch
        XCTAssertTrue(changes.waitForExistence(timeout: 10))
        XCTAssertEqual(String(describing: changes.value ?? ""), "0", "staging must not select files for commit")
        changes.click()
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in String(describing: changes.value ?? "") == "1" },
            object: changes
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed)
        changes.click()
        XCTAssertEqual(String(describing: changes.value ?? ""), "0")
        XCTAssertFalse(session.window.buttons["Commit All"].exists)
    }

    @MainActor
    func testStashContextMenuClearAndDiffTab() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let session = ArborUISession(fixture: fixture, toolWindow: "commit", screenshotSink: { self.add($0) })
        session.extraLaunchArguments = [
            "-arbor.toolWindowMode", "commit",
            "-arbor.toolWindowExpanded", "YES",
            "-arbor.projectPanelExpanded.v3", "YES",
        ]
        session.launch()
        defer { session.terminate() }
        if !session.window.exists {
            // An existing macOS Space can leave the launched window offscreen
            // even though XCUITest has activated its process.
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.arbor.app")
            _ = (running.first(where: \.isActive) ?? running.last)?
                .activate(options: [.activateAllWindows])
        }
        XCTAssertTrue(session.window.waitForExistence(timeout: 10))

        let stashTab = session.window.buttons["Stash"].firstMatch
        guard stashTab.waitForExistence(timeout: 10) else {
            XCTFail("the Commit tool window has no Stash tab")
            return
        }
        stashTab.click()
        let stash = session.window.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "stash-row-")).firstMatch
        if !stash.waitForExistence(timeout: 3) {
            // After activating a window on another Space, its first click can
            // focus the window without selecting the tab.
            stashTab.click()
        }
        guard stash.waitForExistence(timeout: 10) else {
            XCTFail("switching to Stash did not show the fixture stash")
            return
        }
        let project = session.window.buttons["Project"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        project.click()
        XCTAssertTrue(stash.waitForExistence(timeout: 5), "closing Project must keep Stash selected")
        project.click()
        XCTAssertTrue(stash.waitForExistence(timeout: 5), "opening Project must keep Stash selected")

        let stashFile = session.window.descendants(matching: .any)["stash-change-file-README.md"].firstMatch
        XCTAssertTrue(stashFile.waitForExistence(timeout: 10))
        XCTAssertTrue(stashFile.label.hasPrefix("Modified README.md"),
                      "the stash file should expose its modified status: \(stashFile.label)")
        stashFile.click()
        XCTAssertFalse(session.window.descendants(matching: .any)["log-file-diff-tab"].firstMatch.exists,
                       "a single click should only select the stash file")
        stashFile.doubleClick()
        let fileTab = session.window.descendants(matching: .any)["log-file-diff-show-tab"].firstMatch
        XCTAssertTrue(fileTab.waitForExistence(timeout: 10))
        XCTAssertTrue(fileTab.label.contains("Stash@{0}: README.md"))
        XCTAssertTrue(session.window.staticTexts["1 difference"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(session.window.staticTexts["Current version"].firstMatch.exists)
        let diffSettings = session.window.descendants(matching: .any)["stash-diff-settings"].firstMatch
        XCTAssertTrue(diffSettings.waitForExistence(timeout: 5))
        diffSettings.click()
        let softWraps = session.app.menuItems["Use Soft Wraps"].firstMatch
        XCTAssertTrue(softWraps.waitForExistence(timeout: 5))
        softWraps.click()
        XCTAssertTrue(session.window.staticTexts["1 difference"].firstMatch.exists)
        diffSettings.click()
        softWraps.click()
        diffSettings.click()
        XCTAssertTrue(session.app.menuItems["External Diff"].firstMatch.waitForExistence(timeout: 5))
        session.app.menuItems["File Properties"].firstMatch.click()
        XCTAssertTrue(session.app.staticTexts["File Properties"].firstMatch.waitForExistence(timeout: 5))
        session.app.typeKey(.escape, modifierFlags: [])
        diffSettings.click()
        session.app.menuItems["Dimensions"].firstMatch.click()
        XCTAssertTrue(session.app.checkBoxes["Line Numbers"].firstMatch.waitForExistence(timeout: 5))
        session.app.typeKey(.escape, modifierFlags: [])

        let jump = session.window.descendants(matching: .any)["stash-diff-jump-to-source"].firstMatch
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        jump.click()
        XCTAssertTrue(session.window.descendants(matching: .any)["workspace-file-editor"].firstMatch
            .waitForExistence(timeout: 10))
        let returnToDiff = session.window.descendants(matching: .any)["workspace-show-diff-tab"].firstMatch
        XCTAssertTrue(returnToDiff.exists, "Jump to Source should keep the stash diff tab")
        returnToDiff.click()
        let sourceTab = session.window.descendants(matching: .any)["log-file-diff-source-tab"].firstMatch
        XCTAssertTrue(sourceTab.waitForExistence(timeout: 10))
        sourceTab.click()
        XCTAssertTrue(session.window.descendants(matching: .any)["workspace-file-editor"].firstMatch
            .waitForExistence(timeout: 10))
        session.window.descendants(matching: .any)["workspace-close-file"].firstMatch.click()
        XCTAssertTrue(session.window.descendants(matching: .any)["log-file-diff-tab"].firstMatch
            .waitForExistence(timeout: 10), "closing the source tab should return to the diff")
        jump.click()
        returnToDiff.click()
        session.window.descendants(matching: .any)["log-file-diff-close"].firstMatch.click()
        XCTAssertTrue(sourceTab.waitForExistence(timeout: 10),
                      "closing the diff should leave the source tab available")
        sourceTab.click()
        XCTAssertTrue(session.window.descendants(matching: .any)["workspace-file-editor"].firstMatch
            .waitForExistence(timeout: 10))
        session.window.descendants(matching: .any)["workspace-close-file"].firstMatch.click()

        stash.rightClick()
        let clear = session.app.menuItems["Clear"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.click()
        let sheet = session.app.sheets.firstMatch
        XCTAssertTrue(sheet.staticTexts["Clear all stashes?"].firstMatch.waitForExistence(timeout: 5))
        sheet.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(stash.waitForExistence(timeout: 5), "cancel must preserve the stash")

        stash.rightClick()
        let newTab = session.app.menuItems["Show Diff in New Tab"].firstMatch
        XCTAssertTrue(newTab.waitForExistence(timeout: 5))
        newTab.click()
        let diffTab = session.window.descendants(matching: .any)["log-file-diff-tab"].firstMatch
        XCTAssertTrue(diffTab.waitForExistence(timeout: 10))
        let tabButton = session.window.descendants(matching: .any)["log-file-diff-show-tab"].firstMatch
        XCTAssertTrue(tabButton.exists)
        XCTAssertTrue(tabButton.label.contains("README.md"), "the diff tab should name the stashed file")
        XCTAssertTrue(session.window.staticTexts["1 difference"].firstMatch.waitForExistence(timeout: 10),
                      "the stash diff tab must load the file's actual change")
        XCTAssertTrue(stash.exists, "opening the diff tab must preserve the stash")
    }

    @MainActor
    func testChangesGroupingPreservesStagingAndPartialState() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let session = ArborUISession(fixture: fixture, screenshotSink: { self.add($0) })
        session.extraLaunchArguments = ["-arbor.toolWindowMode", "commit", "-arbor.toolWindowExpanded", "YES"]
        session.launch()
        defer { session.terminate() }

        let app = session.window.checkBoxes["Include src/App.swift"].firstMatch
        let engine = session.window.checkBoxes["Include src/Core/Engine.swift"].firstMatch
        XCTAssertTrue(app.waitForExistence(timeout: 10))
        XCTAssertTrue(engine.isHittable)
        func waitForValue(_ value: String, _ checkbox: XCUIElement) {
            let expectation = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in String(describing: checkbox.value ?? "") == value },
                object: checkbox
            )
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
        }
        let index = fixture.appendingPathComponent(".git/index")
        let initialIndex = try Data(contentsOf: index)
        waitForValue("0", app)
        waitForValue("0", engine)
        XCTAssertFalse(session.window.checkBoxes["Include src/Untracked.swift"].exists,
                       "untracked files should start collapsed")

        app.click()
        engine.click()
        waitForValue("1", app)
        waitForValue("1", engine)
        XCTAssertEqual(try Data(contentsOf: index), initialIndex,
                       "commit inclusion must leave Git staging untouched")

        app.rightClick()
        let stage = session.app.menuItems["Stage"].firstMatch
        XCTAssertTrue(stage.waitForExistence(timeout: 5))
        stage.click()
        let stagedIndex = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in (try? Data(contentsOf: index)) != initialIndex },
            object: index
        )
        XCTAssertEqual(XCTWaiter.wait(for: [stagedIndex], timeout: 10), .completed)
        waitForValue("1", app)
        let path = fixture.appendingPathComponent("src/App.swift")
        var content = try String(contentsOf: path, encoding: .utf8)
        content += "\n// a new worktree edit after staging\n"
        try Data(content.utf8).write(to: path)
        XCTAssertTrue(session.window.staticTexts["Partially staged"].firstMatch.waitForExistence(timeout: 10))
        waitForValue("1", app)
        app.rightClick()
        let unstage = session.app.menuItems["Unstage"].firstMatch
        XCTAssertTrue(unstage.waitForExistence(timeout: 5))
        unstage.click()
        waitForValue("1", app)

        session.window.buttons["Unversioned Files"].firstMatch.click()
        let untracked = session.window.checkBoxes["Include src/Untracked.swift"].firstMatch
        XCTAssertTrue(untracked.waitForExistence(timeout: 5))
        let beforeUntrackedSelection = try Data(contentsOf: index)
        session.window.checkBoxes["Include group: Unversioned Files"].firstMatch.click()
        waitForValue("1", untracked)
        XCTAssertEqual(try Data(contentsOf: index), beforeUntrackedSelection)
        let changes = session.window.checkBoxes["Include group: Changes"].firstMatch
        changes.click()
        waitForValue("0", app)
        waitForValue("0", engine)
        XCTAssertEqual(try Data(contentsOf: index), beforeUntrackedSelection)
        changes.click()
        waitForValue("1", app)
        waitForValue("1", engine)
    }

    /// The reference opens a change's diff as a `Repository Diff: <file>`
    /// editor tab. The Log's narrow inspector must not host the diff itself,
    /// where a side-by-side view is unreadable.
    @MainActor
    func testLogChangeOpensFullWidthDiffTab() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }

        let session = ArborUISession(fixture: fixture, toolWindow: "log", screenshotSink: { self.add($0) })
        session.launch()
        defer { session.terminate() }

        XCTAssertTrue(
            session.selectLogCommit(containing: "Fix beta behaviour"),
            "the Log did not list the fixture commits"
        )
        XCTAssertTrue(session.revealLogChanges(), "the commit's changes browser did not load")

        let changesTree = session.window.descendants(matching: .any)["log-changes-tree"].firstMatch
        let changedFile = changesTree.staticTexts["Fix.swift"].firstMatch
        XCTAssertTrue(changedFile.waitForExistence(timeout: 10), "the commit's changed files did not load")
        changedFile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        let diffTab = session.window.descendants(matching: .any)["log-file-diff-tab"].firstMatch
        XCTAssertTrue(
            diffTab.waitForExistence(timeout: 10),
            "selecting a changed file must open its diff as a full-width editor tab"
        )
        let diffTabButton = session.window.descendants(matching: .any)["log-file-diff-show-tab"].firstMatch
        XCTAssertTrue(diffTabButton.exists, "the diff tab must stay on the tab strip")
        XCTAssertTrue(diffTabButton.label.contains("Fix.swift"), "the tab must name the changed file")
        // The reference diff toolbar exposes difference navigation, the file
        // list, the difference count and diff settings on this row.
        XCTAssertTrue(
            session.window.descendants(matching: .any)["log-diff-previous-difference"].firstMatch.exists
        )
        XCTAssertTrue(
            session.window.descendants(matching: .any)["log-diff-next-difference"].firstMatch.exists
        )
        XCTAssertTrue(session.window.descendants(matching: .any)["log-diff-files"].firstMatch.exists)
        for identifier in [
            "log-diff-ignore-whitespace",
            "log-diff-word-differences",
            "log-diff-crlf-sensitive",
            "log-diff-selection-mode",
            "log-diff-patch",
            "log-diff-external",
            "log-diff-clipboard",
            "log-diff-properties",
            "log-diff-blame",
            "log-diff-three-version",
            "log-diff-dimensions",
            "log-diff-workspace",
            "log-diff-staged",
            "log-diff-side-by-side",
            "log-diff-unified",
        ] {
            XCTAssertTrue(
                session.window.descendants(matching: .any)[identifier].firstMatch.exists,
                "\(identifier) must be present in the diff toolbar"
            )
        }
        XCTAssertTrue(session.window.staticTexts["1 difference"].firstMatch.exists)
        XCTAssertFalse(
            session.window.textFields["log-text-filter"].exists,
            "the diff tab must replace the Log surface instead of sharing its column"
        )
        session.recordScreenshot(named: "log-diff-tab")

        let returnToLog = session.window.descendants(matching: .any)["log-file-diff-return-to-log"].firstMatch
        XCTAssertTrue(returnToLog.exists, "the diff tab must keep the Log reachable")
        returnToLog.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        // A wide window shows the graph again. A narrow window keeps the
        // changes inspector over the graph, so the filter stays hidden.
        let returnedFile = changesTree.staticTexts["Fix.swift"].firstMatch
        let logFilter = session.window.textFields["log-text-filter"]
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !returnedFile.exists, !logFilter.exists {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(
            returnedFile.waitForExistence(timeout: 2),
            "returning to Log must keep the loaded Changes list instead of reloading the commit"
        )
        XCTAssertFalse(diffTab.exists)
        session.recordScreenshot(named: "log-diff-tab-back-to-log")

        // Switching to Log keeps the diff tab on the tab strip; selecting it
        // again must restore the same diff without reopening the file.
        XCTAssertTrue(diffTabButton.exists, "the diff tab must stay on the tab strip after returning to Log")
        diffTabButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(diffTab.waitForExistence(timeout: 10), "selecting the diff tab must restore the diff")
        session.recordScreenshot(named: "log-diff-tab-restored")
    }

    /// The reference diff viewer shows the complete file, not only Git hunks,
    /// and keeps both line-number gutters next to the center divider. The
    /// fixture's revised guide has two hunks several lines apart.
    @MainActor
    func testLogDiffTabShowsWholeFileAndCenteredGutters() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }

        let session = ArborUISession(fixture: fixture, toolWindow: "log", screenshotSink: { self.add($0) })
        session.launch()
        defer { session.terminate() }

        XCTAssertTrue(
            session.selectLogCommit(containing: "Revise the fixture guide"),
            "the Log did not list the revised guide commit"
        )
        XCTAssertTrue(session.revealLogChanges(), "the commit's changes browser did not load")

        let changesTree = session.window.descendants(matching: .any)["log-changes-tree"].firstMatch
        let changedFile = changesTree.staticTexts["Guide.md"].firstMatch
        XCTAssertTrue(changedFile.waitForExistence(timeout: 10), "the changed guide file did not load")
        changedFile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        let diffTab = session.window.descendants(matching: .any)["log-file-diff-tab"].firstMatch
        XCTAssertTrue(diffTab.waitForExistence(timeout: 10), "the guide diff did not open")

        // The two changes are in separate hunks; the unchanged line between
        // them proves the whole file is rendered rather than only the hunks.
        XCTAssertTrue(
            session.window.staticTexts["Line 15"].firstMatch.waitForExistence(timeout: 10),
            "unchanged lines between hunks must be visible when the whole file is shown"
        )
        XCTAssertTrue(session.window.staticTexts["2 differences"].firstMatch.exists)

        // Both gutters sit against the center divider: the left number ends
        // just before it, the right number starts just after it.
        let oldNumber = session.window.staticTexts["diff-old-line-5"].firstMatch
        let newNumber = session.window.staticTexts["diff-new-line-5"].firstMatch
        XCTAssertTrue(oldNumber.waitForExistence(timeout: 10))
        XCTAssertTrue(newNumber.waitForExistence(timeout: 10))
        XCTAssertLessThan(
            newNumber.frame.minX - oldNumber.frame.maxX,
            80,
            "the two line-number gutters must be adjacent in the middle of the diff"
        )
        session.recordScreenshot(named: "log-diff-whole-file")

        // Patch mode replaces the diff content with the synthesized patch.
        session.window.descendants(matching: .any)["log-diff-patch"].firstMatch.click()
        XCTAssertTrue(
            session.window.staticTexts.matching(
                NSPredicate(format: "value CONTAINS %@", "diff --git")
            ).firstMatch.waitForExistence(timeout: 5),
            "Patch must show the unified patch text"
        )
        session.window.descendants(matching: .any)["log-diff-patch"].firstMatch.click()

        // Blame opens the same sheet for the target revision.
        let blame = session.window.descendants(matching: .any)["log-diff-blame"].firstMatch
        XCTAssertTrue(blame.waitForExistence(timeout: 5))
        blame.click()
        let blameSheet = session.app.sheets.firstMatch
        XCTAssertTrue(blameSheet.waitForExistence(timeout: 10), "Blame must open its sheet")
        XCTAssertTrue(blameSheet.staticTexts["Blame"].exists)
        blameSheet.buttons["Close"].click()
        XCTAssertTrue(blameSheet.waitForNonExistence(timeout: 5))
    }

    /// With the preview option off a single click only selects; the explicit
    /// Show Diff / double-click / Enter action still opens the diff tab.
    @MainActor
    func testLogDiffTabRequiresExplicitActionWhenPreviewIsOff() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }

        let session = ArborUISession(fixture: fixture, toolWindow: "log", screenshotSink: { self.add($0) })
        session.extraLaunchArguments = ["-arbor.log.showDiffPreview.v1", "NO"]
        session.launch()
        defer { session.terminate() }

        XCTAssertTrue(
            session.selectLogCommit(containing: "Fix beta behaviour"),
            "the Log did not list the fixture commits"
        )
        XCTAssertTrue(session.revealLogChanges(), "the commit's changes browser did not load")

        let changesTree = session.window.descendants(matching: .any)["log-changes-tree"].firstMatch
        let changedFile = changesTree.staticTexts["Fix.swift"].firstMatch
        XCTAssertTrue(changedFile.waitForExistence(timeout: 10), "the commit's changed files did not load")
        changedFile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        let diffTab = session.window.descendants(matching: .any)["log-file-diff-tab"].firstMatch
        XCTAssertFalse(
            diffTab.waitForExistence(timeout: 2),
            "a single click must not open a diff tab while Show Diff Preview is off"
        )
        XCTAssertTrue(
            changesTree.exists,
            "a single click must stay on the changes list while Show Diff Preview is off"
        )

        changedFile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        XCTAssertTrue(
            diffTab.waitForExistence(timeout: 10),
            "double-click must open the diff tab even when inline preview is off"
        )
    }

    @MainActor
    func testCommitOptionCheckboxesToggle() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }

        let session = ArborUISession(fixture: fixture, screenshotSink: { self.add($0) })
        session.launch()
        defer { session.terminate() }

        for label in ["Amend"] {
            let toggle = session.window.checkBoxes[label].firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 10), "\(label) checkbox is missing")
            let before = String(describing: toggle.value)
            toggle.click()
            let deadline = Date().addingTimeInterval(5)
            var after = String(describing: toggle.value)
            while Date() < deadline, after == before {
                Thread.sleep(forTimeInterval: 0.2)
                after = String(describing: toggle.value)
            }
            XCTAssertNotEqual(after, before, "clicking \(label) did not change its value")
        }

        let options = session.window.descendants(matching: .any)["commit-tool-window-options"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        options.click()
        let skipHooks = session.app.menuItems["Skip hooks"].firstMatch
        XCTAssertTrue(skipHooks.waitForExistence(timeout: 5))
        skipHooks.click()
        XCTAssertTrue(session.window.staticTexts["Skip hooks"].firstMatch.waitForExistence(timeout: 5),
                      "the active hook preference should remain visible after the menu closes")
        options.click()
        skipHooks.click()
        XCTAssertFalse(session.window.staticTexts["Skip hooks"].firstMatch.exists)

        let commitSettings = session.window.descendants(matching: .any)["commit-options"].firstMatch
        XCTAssertTrue(commitSettings.waitForExistence(timeout: 5))
        commitSettings.click()
        let signOff = session.app.checkBoxes["Sign-off commit"].firstMatch
        XCTAssertTrue(signOff.waitForExistence(timeout: 5))
        let originalValue = String(describing: signOff.value)
        signOff.click()
        XCTAssertNotEqual(String(describing: signOff.value), originalValue)
        session.app.typeKey(.escape, modifierFlags: [])
        commitSettings.click()
        XCTAssertNotEqual(String(describing: signOff.value), originalValue,
                          "the commit setting should survive closing and reopening the gear")
        signOff.click()
        session.app.typeKey(.escape, modifierFlags: [])
    }
}

/// The activity rail and the status bar are the app's navigation, so they are
/// asserted by their effect (a different surface appears) rather than by the
/// generic sweep.
final class ArborUISmokeNavigationUITests: XCTestCase {
    @MainActor
    func testActivityRailSwitchesViews() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }

        let session = ArborUISession(fixture: fixture, screenshotSink: { self.add($0) })
        session.launch()
        defer { session.terminate() }

        for identifier in ["list.bullet.rectangle", "folder", "clock"] {
            let before = session.screenState()
            guard let button = session.activityRailButton(identifier) else {
                XCTFail("the activity rail has no \(identifier) button")
                continue
            }
            button.click()
            let deadline = Date().addingTimeInterval(10)
            var changed = false
            while Date() < deadline {
                if session.screenState() != before { changed = true; break }
                Thread.sleep(forTimeInterval: 0.2)
            }
            XCTAssertTrue(changed, "clicking the \(identifier) rail button did not switch the surface")
        }
    }
}

/// The project tree is the entry point for every file-level action, so a row
/// click must open that file in the main area.
final class ArborUISmokeProjectTreeUITests: XCTestCase {
    @MainActor
    private func launch(_ session: ArborUISession) {
        session.launch()
        // Unsigned Debug builds can show Sparkle's missing-key startup error.
        // Dismiss that unrelated dialog before exercising the file editor.
        let updaterError = session.app.dialogs.containing(
            .staticText, identifier: "Unable to Check For Updates"
        ).firstMatch
        if updaterError.exists {
            updaterError.buttons["OK"].click()
            XCTAssertTrue(session.waitForStableState(timeout: 30))
        }
    }

    @MainActor
    func testClickingAFileRowShowsItsContent() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }

        let session = ArborUISession(fixture: fixture, toolWindow: "log", screenshotSink: { self.add($0) })
        launch(session)
        defer { session.terminate() }

        XCTAssertTrue(session.openProjectTree(), "the project tree did not open")

        let row = session.window.descendants(matching: .button)
            .matching(NSPredicate(format: "identifier == %@ OR label == %@", "README.md", "README.md"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the project tree does not list README.md")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        let editor = session.window.descendants(matching: .any)["workspace-file-editor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "a project file must open its content in the main editor")
        XCTAssertTrue(editor.staticTexts["Local Version · README.md"].exists)
        let firstLine = editor.otherElements["Line 1: # Arbor UI Fixture"].firstMatch
        XCTAssertTrue(firstLine.waitForExistence(timeout: 10), "the editor must display the actual file contents")
        session.recordScreenshot(named: "project-file-content")
    }

    /// 项目工具窗那个「在 Changes 里选中」的入口，点了之后必须真的把选择交接过去，
    /// 而不是只触发一次点击。可观察的结果是：selectChangedFile 把选择交给变更列表，
    /// 同时清空项目树的选择，所以这个入口随即变灰。
    @MainActor
    func testSelectOpenedFileInChangesViewHandsSelectionToChanges() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        // 在仓库根目录造一个未跟踪文件：它同时出现在项目树和变更列表里，
        // 测试就不必展开目录（项目树的文件夹行是 OutlineRow + DisclosureTriangle，
        // 在 XCUITest 里定位不稳）。
        try Data("# Notes\n".utf8).write(to: fixture.appendingPathComponent("Notes.md"))

        let session = ArborUISession(fixture: fixture, screenshotSink: { self.add($0) })
        session.extraLaunchArguments = [
            "-arbor.toolWindowMode", "commit",
            "-arbor.toolWindowExpanded", "YES",
            "-arbor.projectPanelExpanded.v3", "YES",
        ]
        launch(session)
        defer { session.terminate() }

        let fileRow = session.window.buttons["Notes.md"].firstMatch
        XCTAssertTrue(fileRow.waitForExistence(timeout: 10),
                      "the project tree does not list the untracked file")
        fileRow.click()

        let sync = session.window.buttons["Select Opened File in Changes View"].firstMatch
        XCTAssertTrue(sync.waitForExistence(timeout: 10),
                      "the project tool window has no entry that hands the selection over")
        XCTAssertTrue(sync.isEnabled,
                      "the entry is disabled although a changed file is selected")
        // 项目树的选择和变更列表的选择是两条链；点这一下的意义就是让右边的变更
        // 列表接过选择、并显示这个文件的预览。所以判据是「界面出现了可观察的变化」，
        // 这也是本套件对任何一次点击的定义：什么都不变就是空转。
        let before = session.screenState()
        sync.click()
        var after = session.screenState()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, after.signature == before.signature {
            Thread.sleep(forTimeInterval: 0.2)
            after = session.screenState()
        }
        XCTAssertNotEqual(
            after.signature, before.signature,
            "handing the selection to the changes view produced no observable change"
        )
        session.recordScreenshot(named: "select-opened-file-in-changes")
    }

    @MainActor
    func testClickingChangesOpensDiffAndProjectFileOpensContent() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let session = ArborUISession(fixture: fixture, screenshotSink: { self.add($0) })
        session.extraLaunchArguments = [
            "-arbor.toolWindowMode", "commit",
            "-arbor.toolWindowExpanded", "YES",
            "-arbor.projectPanelExpanded.v3", "YES",
        ]
        launch(session)
        defer { session.terminate() }

        let commitRows = session.window.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Select commit ")
        )
        // The Log loads its rows asynchronously; reading the query once is a
        // race, not an assertion.
        XCTAssertTrue(commitRows.firstMatch.waitForExistence(timeout: 15), "the Log did not list any commit")
        let rows = commitRows.allElementsBoundByIndex
        // The oldest row can sit below the visible part of a short window, and
        // a row without a pointer target cannot be clicked.
        guard let commit = rows.last(where: { $0.isHittable }) ?? rows.last else {
            return XCTFail("the Log did not list any commit")
        }
        commit.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let selectedRow = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"),
            object: commit
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [selectedRow], timeout: 5), .completed,
            "clicking a commit row must select it"
        )
        let selectedCommitLabel = commit.label

        let diff = session.window.descendants(matching: .any)["workspace-diff-editor"].firstMatch
        for (name, expected) in [("App.swift", "let modified = true"), ("Engine.swift", "var revision = 2")] {
            let row = session.window.staticTexts[name].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            XCTAssertTrue(diff.waitForExistence(timeout: 10), "selecting \(name) must replace Log with its diff")
            XCTAssertTrue(diff.staticTexts.matching(
                NSPredicate(format: "value CONTAINS %@", expected)
            ).firstMatch.waitForExistence(timeout: 10), "the diff must show the selected file's changes")
            session.recordScreenshot(named: "changes-diff-\(name)")
        }

        let projectFile = session.window.buttons["README.md"].firstMatch
        XCTAssertTrue(projectFile.waitForExistence(timeout: 10))
        // In a short window the last tree rows sit below the visible area. The
        // accessibility tree still reports their frame, so a click there lands
        // on the status bar and selects nothing.
        let anchorRow = session.window.buttons[".gitignore"].firstMatch
        for delta in [-80.0, -160.0, 80.0] where !projectFile.isHittable {
            anchorRow.scroll(byDeltaX: 0, deltaY: delta)
        }
        XCTAssertTrue(projectFile.isHittable, "the project tree never scrolled README.md into view")
        projectFile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let content = session.window.descendants(matching: .any)["workspace-file-editor"].firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 10))
        XCTAssertTrue(content.staticTexts["Local Version · README.md"].exists)
        XCTAssertFalse(diff.exists, "selecting a project file must leave the diff editor")
        session.recordScreenshot(named: "changes-to-project-content")

        session.window.buttons["workspace-return-to-log"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(session.window.textFields["log-text-filter"].waitForExistence(timeout: 10))
        let reselected = session.window.buttons.matching(
            NSPredicate(format: "label == %@", selectedCommitLabel)
        ).firstMatch
        XCTAssertTrue(reselected.isSelected, "returning to Log must retain the selected commit")
        XCTAssertFalse(content.exists, "returning to Log must close the file editor")
        session.recordScreenshot(named: "file-back-to-log")
    }
}

/// Re-tests one control in isolation.
///
/// The sweep clicks many controls in one session, and a click that starts a
/// long Git operation can leave the following controls unresponsive. When the
/// sweep reports a control as dead, reproduce it alone with
/// `scripts/ui-smoke.sh --focus "Label" --surface commit|log|project-tree`.
final class ArborUISmokeFocusUITests: XCTestCase {
    struct Request: Decodable {
        let label: String
        let surface: String
    }

    @MainActor
    func testFocusedControlReacts() throws {
        let requestURL = ArborUIFixture.repositoryRoot.appendingPathComponent(".build/UISmoke/focus.json")
        guard let data = try? Data(contentsOf: requestURL),
              let request = try? JSONDecoder().decode(Request.self, from: data) else {
            throw XCTSkip("no focus request; run scripts/ui-smoke.sh --focus <label>")
        }

        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }

        let session = ArborUISession(fixture: fixture, toolWindow: request.surface == "log" ? "log" : "commit", screenshotSink: { self.add($0) })
        session.launch()
        defer { session.terminate() }

        switch request.surface {
        case "project-tree":
            XCTAssertTrue(session.openProjectTree(), "the project tree did not open")
        case "branches":
            XCTAssertTrue(session.openBranchesPopover(), "the branches popover did not open")
        case "settings":
            XCTAssertTrue(session.openSettings(), "Settings did not open")
        default:
            break
        }

        let matches = session.visibleControls().filter { $0.label == request.label }
        guard let candidate = matches.first else {
            XCTFail("no visible control is labelled “\(request.label)” on the \(request.surface) surface")
            return
        }

        let before = session.screenState()
        candidate.element.click()
        let deadline = Date().addingTimeInterval(8)
        var after = session.screenState()
        while Date() < deadline, after == before {
            Thread.sleep(forTimeInterval: 0.25)
            after = session.screenState()
        }
        XCTAssertNotEqual(after, before, "“\(request.label)” did nothing observable in isolation")
    }
}

/// Main-menu actions expose their availability before an operation starts.
final class ArborUISmokeFeedbackUITests: XCTestCase {
    @MainActor
    func testFetchWithoutRemoteIsDisabled() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let session = ArborUISession(fixture: fixture, screenshotSink: { self.add($0) })
        session.launch()
        defer { session.terminate() }

        session.app.menuBars.menuBarItems["VCS"].click()
        session.app.menuItems["Git"].firstMatch.click()
        let fetch = session.app.menuItems["Fetch"].firstMatch
        XCTAssertTrue(fetch.waitForExistence(timeout: 5))
        XCTAssertFalse(fetch.isEnabled, "Fetch needs a configured remote")
        session.app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }
}

/// The conflict workbench is opened from the merge banner. This test is meant
/// to run against a fixture that already has an unresolved merge (see
/// docs/user-flow-audit.md); with the regular fixture it skips instead of
/// failing the sweep.
final class ArborUIConflictUITests: XCTestCase {
    @MainActor
    func testConflictResolverShowsOperationAwareSides() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }

        let session = ArborUISession(fixture: fixture, toolWindow: "commit", screenshotSink: { self.add($0) })
        session.extraLaunchArguments = ["-arbor.appLanguage", "en"]
        session.launch()
        defer { session.terminate() }

        let resolve = session.window.buttons["Resolve Conflicts"].firstMatch
        let overlayTitle = session.window.staticTexts["Resolve Conflicts"].firstMatch
        if !overlayTitle.exists {
            guard resolve.waitForExistence(timeout: 5), resolve.isHittable else {
                throw XCTSkip("fixture has no unresolved merge")
            }
            resolve.click()
        }

        if !overlayTitle.waitForExistence(timeout: 10) {
            print("=== CONFLICT TREE AFTER CLICK ===")
            print(session.window.debugDescription)
            print("=== END CONFLICT TREE ===")
            session.recordScreenshot(named: "conflict-after-click")
            XCTFail("the conflict workbench did not open")
            return
        }
        XCTAssertTrue(
            session.window.buttons["Accept All Ours"].firstMatch.waitForExistence(timeout: 5)
                || session.window.buttons["Ours"].firstMatch.waitForExistence(timeout: 5),
            "the workbench did not expose the ours side"
        )
        XCTAssertTrue(
            session.window.buttons["Accept All Theirs"].firstMatch.exists
                || session.window.buttons["Theirs"].firstMatch.exists,
            "the workbench did not expose the theirs side"
        )
        session.recordScreenshot(named: "conflict-resolver")
    }
}

/// AppKit overlay scrollers, legacy scroll arrows and the scroll corner are
/// unnamed and at most 16pt on their short side. Toolbar icons start at 18pt.
private func isSystemScrollChrome(_ element: XCUIElement) -> Bool {
    let frame = element.frame
    return min(frame.width, frame.height) <= 16
}
