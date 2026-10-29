import XCTest
import AppKit

/// Captures the two surfaces the visual baseline compares, at the same window
/// size, from this app and from the reference application.
///
/// Reference captures come from real windows, resized and navigated to the
/// surface being compared.
final class ArborUIVisualCaptureUITests: XCTestCase {
    static let targetSize = CGSize(width: 1642, height: 1015)
    static let rebasedBundleIdentifier = "io.github.detachhead.rebased"

    /// The reference application only exists on a developer machine, and
    /// `XCUIApplication(bundleIdentifier:)` throws for an unknown bundle, so
    /// the parity captures skip instead of failing the run in CI.
    static func referenceApplication() throws -> XCUIApplication {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: rebasedBundleIdentifier) != nil else {
            throw XCTSkip("Rebased is not installed")
        }
        let app = XCUIApplication(bundleIdentifier: rebasedBundleIdentifier)
        guard app.state != .notRunning else {
            throw XCTSkip("Rebased is not running; open the fixture project in it first")
        }
        return app
    }

    // MARK: - Arbor

    @MainActor
    func testCaptureArborCommitAndLog() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let layoutArguments = [
            "-arbor.toolWindowExpanded", "YES",
            "-arbor.projectPanelExpanded.v3", "YES",
            "-arbor.workspaceSidebarWidth.v12", "582",
            "-arbor.toolWindowHeight.v3", "466",
            "-arbor.logGraphWidth.v8", "688",
            "-arbor.log.showDetails.v1", "YES",
            "-arbor.log.branches.visible.v1", "NO",
        ]

        // The Commit surface: the app restores the last tool window unless the
        // stored preference is overridden, so both states are requested
        // explicitly instead of depending on whatever ran before.
        do {
            let session = ArborUISession(fixture: fixture, screenshotSink: { self.add($0) })
            session.extraLaunchArguments = layoutArguments + ["-arbor.toolWindowMode", "commit"]
            session.launch()
            resize(session.window, to: Self.targetSize, label: "arbor-commit")
            capture(window: session.window, named: "arbor-commit")
            // Ask below the supported height to verify the actual scene's
            // minimum, including its native titlebar, rather than a test host.
            resize(session.window, to: CGSize(width: 980, height: 500), label: "arbor-commit-minimum")
            XCTAssertEqual(session.window.frame.width, 980, accuracy: 2)
            XCTAssertEqual(session.window.frame.height, 540, accuracy: 2)
            let commitAndPush = session.window.buttons["Commit and Push…"].firstMatch
            XCTAssertTrue(session.window.frame.contains(commitAndPush.frame))
            capture(window: session.window, named: "arbor-commit-minimum")
            session.terminate()
        }

        // The Log surface: the Log tool window with the project tree.
        do {
            let session = ArborUISession(fixture: fixture, toolWindow: "log", screenshotSink: { self.add($0) })
            session.extraLaunchArguments = layoutArguments
            session.launch()
            XCTAssertTrue(session.openProjectTree(), "the activity rail did not open the project tree")
            resize(session.window, to: Self.targetSize, label: "arbor-log")
            capture(window: session.window, named: "arbor-log")
            session.terminate()
        }
    }

    @MainActor
    func testLongCommitSubjectsStayInsideTheirRows() throws {
        struct FixtureCommit: Decodable {
            let id: String
            let subject: String
        }
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let commits = try JSONDecoder().decode(
            [FixtureCommit].self,
            from: Data(contentsOf: fixture.appendingPathComponent(".git/arbor-ui-log-rows.json"))
        )
        let tip = try XCTUnwrap(commits.last)
        try Data((tip.id + "\n").utf8).write(
            to: fixture.appendingPathComponent(".git/refs/heads/main")
        )
        let session = ArborUISession(fixture: fixture, toolWindow: "log", screenshotSink: { self.add($0) })
        session.extraLaunchArguments = [
            "-arbor.workspaceSidebarWidth.v12", "582",
            "-arbor.logGraphWidth.v8", "688",
            "-arbor.log.branches.visible.v1", "NO",
            "-arbor.log.alignLabels.v1", "NO",
        ]
        session.launch()
        defer { session.terminate() }
        XCTAssertTrue(session.openProjectTree())

        for width: CGFloat in [1642, 1540, 1200, 980] {
            resize(session.window, to: CGSize(width: width, height: 1015), label: "log-row-heights")
            var previousRow: CGRect?
            for commit in commits.reversed() {
                let row = session.window.buttons["Select commit \(commit.id.prefix(7))"]
                XCTAssertTrue(row.waitForExistence(timeout: 5))
                let subject = session.window.staticTexts.matching(
                    NSPredicate(format: "value BEGINSWITH %@", String(commit.subject.prefix(18)))
                ).firstMatch
                XCTAssertTrue(subject.exists)
                XCTAssertEqual(row.frame.height, 26, accuracy: 1)
                XCTAssertLessThanOrEqual(subject.frame.height, row.frame.height,
                                         "a long subject escaped its row at \(width)pt: \(subject.frame)")
                XCTAssertEqual(subject.frame.midY, row.frame.midY, accuracy: 1)
                if let previousRow {
                    XCTAssertEqual(row.frame.minY - previousRow.minY, 26, accuracy: 1)
                }
                previousRow = row.frame
            }
            let longCommit = commits[1]
            let longRow = session.window.buttons["Select commit \(longCommit.id.prefix(7))"]
            longRow.click()
            XCTAssertTrue(longRow.isSelected, "clicking a long subject selected the wrong row")
            capture(window: session.window, named: "log-row-heights-\(Int(width))")
        }
    }

    @MainActor
    func testLogFiltersStayInsidePane() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let longBranch = "feature/" + String(repeating: "long-branch-name-", count: 10)
        let branchRef = fixture.appendingPathComponent(".git/refs/heads/" + longBranch)
        try FileManager.default.createDirectory(
            at: branchRef.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: fixture.appendingPathComponent(".git/refs/heads/main"), to: branchRef
        )

        let session = ArborUISession(fixture: fixture, toolWindow: "log", screenshotSink: { self.add($0) })
        session.extraLaunchArguments = [
            "-arbor.workspaceSidebarWidth.v12", "582",
            "-arbor.logGraphWidth.v8", "688",
        ]
        session.launch()
        defer { session.terminate() }
        XCTAssertTrue(session.openProjectTree())
        resize(session.window, to: Self.targetSize, label: "log-filters")

        let branchMenu = session.window.descendants(matching: .any)["log-branch-filter"].firstMatch
        branchMenu.click()
        let branchItem = session.app.menuItems.matching(NSPredicate(format: "title == %@", longBranch)).firstMatch
        XCTAssertTrue(branchItem.waitForExistence(timeout: 5))
        branchItem.click()

        let bar = session.window.descendants(matching: .any)["log-filter-bar"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        for width: CGFloat in [1642, 1540, 1440, 1200, 980] {
            resize(session.window, to: CGSize(width: width, height: 1015), label: "log-filters")
            XCTAssertLessThanOrEqual(abs(session.window.frame.width - width), 2)
            XCTAssertGreaterThanOrEqual(bar.frame.width, 399, "the Log column collapsed at \(width)pt")
            for control in [
                session.window.checkBoxes["Follow current branch"],
                session.window.buttons["Refresh log"],
            ] {
                XCTAssertTrue(control.isHittable, "\(control.label) is not usable at \(width)pt")
                XCTAssertTrue(bar.frame.contains(control.frame), "\(control.label) overflows \(bar.frame) at \(width)pt: \(control.frame)")
            }
            if width == 1642 {
                for control in [
                    session.window.textFields["log-text-filter"],
                    session.window.menuButtons["log-path-filter"],
                    branchMenu,
                    session.window.buttons["log-user-filter"],
                    session.window.buttons["log-date-filter"],
                ] {
                    XCTAssertTrue(control.isHittable)
                    XCTAssertTrue(bar.scrollViews.firstMatch.frame.contains(control.frame), "filter overflows at the baseline width: \(control.frame)")
                }
            } else {
                let filters = bar.scrollViews.firstMatch
                filters.hover()
                filters.scroll(byDeltaX: 600, deltaY: 0)
                let branchVisible = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in
                        filters.frame.insetBy(dx: -1, dy: -1).contains(branchMenu.frame)
                    }, object: nil
                )
                XCTAssertEqual(XCTWaiter.wait(for: [branchVisible], timeout: 5), .completed,
                               "branch \(branchMenu.frame) is outside the filter viewport \(filters.frame)")
                XCTAssertTrue(branchMenu.isHittable)
            }
            capture(window: session.window, named: "log-filters-\(Int(width))")
        }
    }

    @MainActor
    func testPathFilterMenuAppliesAndClears() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let session = ArborUISession(fixture: fixture, toolWindow: "log", screenshotSink: { self.add($0) })
        session.launch()
        defer { session.terminate() }
        resize(session.window, to: Self.targetSize, label: "log-paths")

        let paths = session.window.descendants(matching: .any)["log-path-filter"].firstMatch
        paths.click()
        session.app.menuItems["Edit Paths…"].click()
        let sheet = session.window.sheets.firstMatch
        let editor = sheet.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        paste("src/" + String(repeating: "long-path-", count: 12) + "Missing.swift", into: editor, app: session.app)
        sheet.buttons["Apply"].click()
        XCTAssertTrue(session.window.staticTexts["No commits match the current filters"].waitForExistence(timeout: 10))
        let bar = session.window.descendants(matching: .any)["log-filter-bar"].firstMatch
        XCTAssertTrue(bar.scrollViews.firstMatch.frame.contains(paths.frame), "a long path overflowed the filter bar")

        paths.click()
        session.app.menuItems["Clear"].click()
        XCTAssertTrue(session.window.staticTexts["Initial commit"].firstMatch.waitForExistence(timeout: 10))
    }

    @MainActor
    func testCompactLogPreservesSelectionAndDividerWidths() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let session = ArborUISession(fixture: fixture, toolWindow: "log", screenshotSink: { self.add($0) })
        session.extraLaunchArguments = [
            "-arbor.log.showDetails.v1", "YES",
            "-arbor.log.branches.visible.v1", "NO",
        ]
        session.launch()
        defer { session.terminate() }
        XCTAssertTrue(session.openProjectTree())
        resize(session.window, to: Self.targetSize, label: "log-columns")

        let bar = session.window.descendants(matching: .any)["log-filter-bar"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        let openInspector = session.window.buttons["log-open-inspector"]
        let closeInspector = session.window.buttons["log-close-inspector"]
        // Seed widths through the real dividers: launch-argument defaults
        // would override the persisted widths that this test needs to verify.
        dragDivider(in: session.window, atX: bar.frame.minX - 13,
                    by: session.window.frame.minX + 474 - bar.frame.minX)
        XCTAssertFalse(openInspector.exists, "the wide window should show both columns")
        dragDivider(in: session.window, atX: bar.frame.maxX + 13,
                    by: 620 - bar.frame.width)

        // Exercise both native dividers before checking that a compact visit
        // does not overwrite the user's chosen widths.
        let originalWidth = bar.frame.width
        dragDivider(in: session.window, atX: bar.frame.maxX + 13, by: -40)
        XCTAssertLessThan(bar.frame.width, originalWidth - 20)
        let originalOrigin = bar.frame.minX
        dragDivider(in: session.window, atX: originalOrigin - 13, by: -40)
        XCTAssertLessThan(bar.frame.minX, originalOrigin - 20)
        let savedBarFrame = bar.frame
        let savedBarOffset = savedBarFrame.minX - session.window.frame.minX

        for size in [CGSize(width: 1200, height: 1015), CGSize(width: 980, height: 540)] {
            resize(session.window, to: size, label: "log-columns")
            XCTAssertLessThanOrEqual(abs(session.window.frame.width - size.width), 2)
            XCTAssertGreaterThanOrEqual(bar.frame.width, 519)
            XCTAssertTrue(openInspector.isHittable)
            let commit = session.window.staticTexts["Initial commit"].firstMatch
            XCTAssertTrue(session.window.frame.contains(commit.frame))
            commit.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            capture(window: session.window, named: "log-columns-\(Int(size.width))")

            openInspector.click()
            XCTAssertTrue(closeInspector.waitForExistence(timeout: 5))
            XCTAssertFalse(bar.exists, "the covered graph must not remain in the accessibility tree")
            XCTAssertTrue(session.window.staticTexts["Initial commit"].firstMatch.isHittable)
            let actions = session.window.descendants(matching: .any)["Commit Actions"].firstMatch
            XCTAssertTrue(actions.isHittable)
            actions.click()
            for label in ["Revert Commit", "Cherry-pick", "Create Branch from Commit"] {
                let action = session.app.menuItems[label].firstMatch
                XCTAssertTrue(action.isHittable, "\(label) is clipped at \(size)")
            }
            session.dismissTransientSurface()
            XCTAssertTrue(session.window.staticTexts["Changes"].firstMatch.isHittable)
            capture(window: session.window, named: "log-details-\(Int(size.width))")

            // The compact inspector shares the normal dialog presenter.
            actions.click()
            session.app.menuItems["Create Branch from Commit"].firstMatch.click()
            let sheet = session.window.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 5))
            sheet.buttons["Cancel"].click()
            closeInspector.click()
            XCTAssertTrue(bar.waitForExistence(timeout: 5))
            XCTAssertTrue(session.window.frame.contains(commit.frame))
        }

        // Widen directly from details, then verify the selected commit and
        // both divider positions survived the change of presentation.
        openInspector.click()
        resize(session.window, to: Self.targetSize, label: "log-columns-restored")
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertFalse(openInspector.exists)
        XCTAssertFalse(closeInspector.exists)
        XCTAssertEqual(bar.frame.width, savedBarFrame.width, accuracy: 2)
        XCTAssertEqual(bar.frame.minX - session.window.frame.minX,
                       savedBarOffset, accuracy: 2)
        XCTAssertEqual(session.window.staticTexts.matching(identifier: "Initial commit").count, 2)

        // Commit mode retains the same readable Log alongside staging.
        let commitButton = try XCTUnwrap(session.railButton("slider.horizontal.3"))
        commitButton.click()
        resize(session.window, to: CGSize(width: 980, height: 1015), label: "commit-log-columns")
        XCTAssertGreaterThanOrEqual(bar.frame.width, 519)
        XCTAssertTrue(openInspector.isHittable)
        capture(window: session.window, named: "commit-log-columns-980")
    }

    @MainActor
    func testAuthorAndDateFiltersApplyAndClear() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let session = ArborUISession(fixture: fixture, toolWindow: "log", screenshotSink: { self.add($0) })
        session.launch()
        defer { session.terminate() }

        let filters = session.window.buttons["log-user-filter"]
        filters.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let author = session.app.textFields["User"].firstMatch
        XCTAssertTrue(author.waitForExistence(timeout: 5))
        paste("author-with-no-matching-commits", into: author, app: session.app)
        session.app.buttons["Done"].click()
        let empty = session.window.staticTexts["No commits match the current filters"]
        XCTAssertTrue(empty.waitForExistence(timeout: 10), "Done did not apply the author filter")

        filters.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let clear = session.app.buttons["Clear"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.click()
        session.app.buttons["Done"].click()
        XCTAssertTrue(session.window.staticTexts["Initial commit"].firstMatch.waitForExistence(timeout: 10))

        let dates = session.window.buttons["log-date-filter"]
        dates.click()
        let since = session.app.textFields["Since"].firstMatch
        XCTAssertTrue(since.waitForExistence(timeout: 5))
        paste("2030-01-01", into: since, app: session.app)
        session.app.buttons["Done"].click()
        XCTAssertTrue(empty.waitForExistence(timeout: 10), "Done did not apply the date filter")
        dates.click()
        session.app.buttons["Clear"].firstMatch.click()
        session.app.buttons["Done"].click()
        XCTAssertTrue(session.window.staticTexts["Initial commit"].firstMatch.waitForExistence(timeout: 10))
    }

    /// The Edit menu avoids XCTest switching to a third-party input method and
    /// triggering the system's input-source authorization dialog.
    @MainActor
    private func paste(_ text: String, into field: XCUIElement, app: XCUIApplication) {
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer {
            board.clearContents()
            board.writeObjects(saved)
        }
        board.clearContents()
        board.setString(text, forType: .string)
        field.click()
        app.menuBars.menuBarItems["Edit"].click()
        app.menuItems["Paste"].firstMatch.click()
        XCTAssertEqual(field.value as? String, text)
    }

    // MARK: - Rebased

    @MainActor
    func testBranchPopupReferencesAndActionsStayReachable() throws {
        try checkBranchPopupReferencesAndActions(language: "en")
    }

    @MainActor
    func testChineseBranchPopupReferencesAndActionsStayReachable() throws {
        try checkBranchPopupReferencesAndActions(language: "zh-Hans")
    }

    @MainActor
    private func checkBranchPopupReferencesAndActions(language: String) throws {
        continueAfterFailure = false
        let chinese = language == "zh-Hans"
        let fixture = ArborUIFixture.repositoryRoot
            .appendingPathComponent(".build/UISmoke/branch-comparison-fixture")
        let session = ArborUISession(fixture: fixture, screenshotSink: { self.add($0) })
        session.extraLaunchArguments = ["-arbor.appLanguage", language]
        session.launch()
        defer { session.terminate() }
        if chinese { resize(session.window, to: CGSize(width: 980, height: 640), label: "chinese-branches") }
        XCTAssertTrue(session.openBranchesPopover())
        capture(window: session.window, named: "arbor-branch-popup-compact-actions-\(language)")
        if chinese {
            let tree = XCTAttachment(string: session.app.debugDescription)
            tree.name = "arbor-branch-popup-chinese-tree"
            tree.lifetime = .keepAlways
            add(tree)
        }
        let actionTitles = chinese
            ? ["提交变更…", "新建分支…", "检出 Tag 或版本…"]
            : ["Commit Changes…", "New Branch…", "Checkout Tag or Revision…"]
        for title in actionTitles {
            XCTAssertEqual(session.app.buttons.matching(NSPredicate(format: "label == %@", title)).count, 1)
        }
        let localTitle = chinese ? "本地分支" : "LOCAL BRANCHES"
        let references = session.app.descendants(matching: .any)["branch-reference-list"].firstMatch
        let local = references.staticTexts[localTitle].firstMatch
        XCTAssertTrue(local.waitForExistence(timeout: 5))
        XCTAssertTrue(references.frame.contains(local.frame), "The footer hides the branch list")
        if chinese { XCTAssertTrue(references.staticTexts["最近"].exists) }

        let search = session.app.textFields[chinese ? "搜索分支" : "Search branches"].firstMatch
        paste("localization-audit", into: search, app: session.app)
        capture(window: session.window, named: "arbor-branch-popup-long-search-\(language)")
        let longBranch = references.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "localization-audit-with-a-deliberately-long-branch-name")
        ).firstMatch
        XCTAssertTrue(longBranch.waitForExistence(timeout: 5))
        XCTAssertTrue(longBranch.isHittable)
        XCTAssertTrue(references.frame.contains(longBranch.frame), "The long branch escapes the list")
        if chinese {
            for title in ["标签", "贮藏"] {
                let heading = references.staticTexts[title]
                XCTAssertTrue(heading.exists)
                XCTAssertTrue(references.frame.contains(heading.frame))
            }
        }

        let actions = session.app.menuButtons[chinese ? "操作" : "Actions"].firstMatch
        XCTAssertTrue(session.window.frame.contains(actions.frame))
        actions.click()
        let merge = try XCTUnwrap(
            session.app.menuItems.matching(identifier: "Merge…").allElementsBoundByIndex
                .first { !$0.frame.isEmpty },
            "Merge is not visible in the Actions menu"
        )
        XCTAssertTrue(merge.isEnabled)
        merge.click()
        XCTAssertTrue(session.app.sheets.firstMatch.waitForExistence(timeout: 5))
        session.app.sheets.firstMatch.buttons[chinese ? "取消" : "Cancel"].firstMatch.click()
    }

    @MainActor
    func testCaptureBranchPopupParity() throws {
        continueAfterFailure = false
        let branchCaptureSize = Self.targetSize
        let fixture = ArborUIFixture.repositoryRoot
            .appendingPathComponent(".build/UISmoke/branch-comparison-fixture")
        guard FileManager.default.fileExists(atPath: fixture.appendingPathComponent(".git").path) else {
            throw XCTSkip("branch-comparison-fixture has not been built")
        }
        let rebased = try Self.referenceApplication()
        let session = ArborUISession(fixture: fixture, screenshotSink: { self.add($0) })
        defer { session.terminate() }
        session.extraLaunchArguments = ["-arbor.appLanguage", "en"]
        session.launch()
        resize(session.window, to: branchCaptureSize, label: "arbor-branches")
        XCTAssertEqual(session.window.frame.width, branchCaptureSize.width, accuracy: 2)
        XCTAssertEqual(session.window.frame.height, branchCaptureSize.height, accuracy: 2)
        XCTAssertTrue(session.openBranchesPopover())
        capture(window: session.window, named: "arbor-branch-popup")
        session.terminate()

        rebased.activate()
        let trust = rebased.buttons["Trust Project"].firstMatch
        if trust.waitForExistence(timeout: 2) {
            let prompt = rebased.windows.firstMatch.textFields.allElementsBoundByIndex
                .compactMap { $0.value as? String }.joined(separator: " ")
            guard prompt.contains(fixture.lastPathComponent) else {
                XCTFail("Rebased trust prompt does not identify the comparison fixture")
                return
            }
            trust.click()
        }
        let window = rebased.windows.matching(
            NSPredicate(format: "title CONTAINS %@", fixture.lastPathComponent)
        ).firstMatch
        guard window.waitForExistence(timeout: 15) else {
            let attachment = XCTAttachment(screenshot: rebased.screenshot())
            attachment.name = "rebased-project-opening"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail("Rebased has not opened the comparison fixture")
            return
        }
        resize(window, to: branchCaptureSize, label: "rebased-branches")
        XCTAssertEqual(window.frame.width, branchCaptureSize.width, accuracy: 2)
        // Rebased keeps its current height on this desktop. Record the full
        // frame below; popup layout comparisons use the matched window width.
        XCTAssertGreaterThanOrEqual(window.frame.height, branchCaptureSize.height)
        capture(window: window, named: "rebased-before-branches")
        let branch = window.buttons["main, menu"].firstMatch
        XCTAssertTrue(branch.waitForExistence(timeout: 5))
        branch.click()
        Thread.sleep(forTimeInterval: 1)
        capture(window: window, named: "rebased-branch-popup")
        let tree = XCTAttachment(string: rebased.debugDescription)
        tree.name = "rebased-branch-popup-tree"
        tree.lifetime = .keepAlways
        add(tree)
    }

    @MainActor
    func testCaptureRebasedCommitAndLog() throws {
        let rebased = try Self.referenceApplication()
        rebased.activate()
        Thread.sleep(forTimeInterval: 1)

        let window = rebased.windows
            .matching(NSPredicate(format: "title CONTAINS %@", "visual-fixture"))
            .firstMatch
        guard window.waitForExistence(timeout: 10) else {
            throw XCTSkip("Rebased has no window for the visual-fixture project")
        }

        resize(window, to: Self.targetSize, label: "rebased")
        // The Commit tool window is open in this session; capture it first,
        // then collapse it through its activity-rail button to get the Log
        // surface. Rail buttons are clicked rather than driven by ⌘K so the
        // capture never asks macOS for input-method permission.
        capture(window: window, named: "rebased-commit")

        // The Commit tool window's own Hide control is not exposed to the
        // accessibility tree, so it is clicked at its known position in a
        // 1642 wide window (the ⋮ and — pair at the right of the tab strip).
        let hide = window.coordinate(withNormalizedOffset: CGVector(dx: 595.0 / 1642.0, dy: 59.0 / 1015.0))
        hide.click()
        Thread.sleep(forTimeInterval: 1.5)
        capture(window: window, named: "rebased-log")

        // Restore the Commit tool window through its activity-rail button.
        let commitButton = window.buttons["Commit"].firstMatch
        if commitButton.exists {
            commitButton.click()
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    // MARK: - Helpers

    @MainActor
    private func resize(_ window: XCUIElement, to size: CGSize, label: String) {
        let frame = window.frame
        let delta = CGVector(dx: size.width - frame.width, dy: size.height - frame.height)
        if abs(delta.dx) < 2 && abs(delta.dy) < 2 {
            print("[capture] \(label) already at \(frame.size)")
            return
        }
        dragCorner(window, by: delta)
        if window.frame.size != size {
            // A zoomed window ignores corner drags: unzoom through the title
            // bar, then resize again.
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).doubleTap()
            Thread.sleep(forTimeInterval: 1.0)
            let adjusted = CGVector(
                dx: size.width - window.frame.width,
                dy: size.height - window.frame.height
            )
            dragCorner(window, by: adjusted)
        }
        print("[capture] \(label) \(frame.size) → \(window.frame.size) (target \(size))")
    }

    @MainActor
    private func dragCorner(_ window: XCUIElement, by delta: CGVector) {
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.3, thenDragTo: corner.withOffset(delta))
        Thread.sleep(forTimeInterval: 1.0)
    }

    @MainActor
    private func dragDivider(in window: XCUIElement, atX x: CGFloat, by delta: CGFloat) {
        let start = window.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: x - window.frame.minX, dy: window.frame.height / 2)
        )
        start.press(forDuration: 0.3, thenDragTo: start.withOffset(CGVector(dx: delta, dy: 0)))
        Thread.sleep(forTimeInterval: 0.5)
    }

    @MainActor
    private func capture(window: XCUIElement, named name: String) {
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[capture] \(name) frame=\(window.frame)")
    }
}
