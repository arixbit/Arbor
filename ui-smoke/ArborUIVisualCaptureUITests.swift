import XCTest

/// Captures the two surfaces the visual baseline compares, at the same window
/// size, from this app and from the reference application.
///
/// The reference app is not driven beyond resizing and switching tool windows:
/// the screenshots are taken from a real window, not a rendered mock.
final class ArborUIVisualCaptureUITests: XCTestCase {
    static let targetSize = CGSize(width: 1642, height: 1015)
    static let rebasedBundleIdentifier = "io.github.detachhead.rebased"

    // MARK: - Arbor

    @MainActor
    func testCaptureArborCommitAndLog() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }

        // The Commit surface: the app restores the last tool window unless the
        // stored preference is overridden, so both states are requested
        // explicitly instead of depending on whatever ran before.
        do {
            let session = ArborUISession(fixture: fixture, screenshotSink: { self.add($0) })
            session.extraLaunchArguments = ["-arbor.toolWindowMode", "commit"]
            session.launch()
            resize(session.window, to: Self.targetSize, label: "arbor-commit")
            capture(window: session.window, named: "arbor-commit")
            session.terminate()
        }

        // The Log surface: the Log tool window with the project tree.
        do {
            let session = ArborUISession(fixture: fixture, toolWindow: "log", screenshotSink: { self.add($0) })
            session.launch()
            XCTAssertTrue(session.openProjectTree(), "the activity rail did not open the project tree")
            resize(session.window, to: Self.targetSize, label: "arbor-log")
            capture(window: session.window, named: "arbor-log")
            session.terminate()
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
            "-arbor.workspaceSidebarWidth.v11", "564",
            "-arbor.logGraphWidth.v6", "545",
        ]
        session.launch()
        defer { session.terminate() }
        XCTAssertTrue(session.openProjectTree())
        resize(session.window, to: Self.targetSize, label: "log-filters")

        let branchMenu = session.window.menuButtons["log-branch-filter"]
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
                session.window.buttons["Author and date filters"],
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
                ] {
                    XCTAssertTrue(control.isHittable)
                    XCTAssertTrue(bar.scrollViews.firstMatch.frame.contains(control.frame), "filter overflows at the baseline width: \(control.frame)")
                }
            } else {
                let filters = bar.scrollViews.firstMatch
                filters.hover()
                filters.scroll(byDeltaX: -600, deltaY: 0)
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

        let paths = session.window.menuButtons["log-path-filter"]
        paths.click()
        session.app.menuItems["Edit Paths…"].click()
        let sheet = session.window.sheets.firstMatch
        let editor = sheet.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("src/" + String(repeating: "long-path-", count: 12) + "Missing.swift")
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
        dragDivider(in: session.window, atX: bar.frame.minX - 16,
                    by: session.window.frame.minX + 474 - bar.frame.minX)
        XCTAssertFalse(openInspector.exists, "the wide window should show both columns")
        dragDivider(in: session.window, atX: bar.frame.maxX + 16,
                    by: 480 - bar.frame.width)

        // Exercise both native dividers before checking that a compact visit
        // does not overwrite the user's chosen widths.
        let originalWidth = bar.frame.width
        dragDivider(in: session.window, atX: bar.frame.maxX + 16, by: -40)
        XCTAssertLessThan(bar.frame.width, originalWidth - 20)
        let originalOrigin = bar.frame.minX
        dragDivider(in: session.window, atX: originalOrigin - 16, by: -40)
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
            for label in ["Revert Commit", "Cherry-pick", "Create Branch from Commit"] {
                let action = session.window.buttons[label]
                XCTAssertTrue(action.isHittable, "\(label) is clipped at \(size)")
                XCTAssertTrue(session.window.frame.contains(action.frame))
            }
            XCTAssertTrue(session.window.staticTexts["Changes"].firstMatch.isHittable)
            capture(window: session.window, named: "log-details-\(Int(size.width))")

            // The compact inspector shares the normal dialog presenter.
            session.window.buttons["Create Branch from Commit"].click()
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
        let commitButton = try XCTUnwrap(session.railButton("checkmark.circle"))
        commitButton.click()
        resize(session.window, to: CGSize(width: 980, height: 1015), label: "commit-log-columns")
        XCTAssertGreaterThanOrEqual(bar.frame.width, 519)
        XCTAssertTrue(openInspector.isHittable)
        capture(window: session.window, named: "commit-log-columns-980")
    }

    @MainActor
    func testAuthorFilterAppliesWhenDoneIsClicked() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let session = ArborUISession(fixture: fixture, toolWindow: "log", screenshotSink: { self.add($0) })
        session.launch()
        defer { session.terminate() }

        let filters = session.window.buttons["Author and date filters"]
        filters.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let author = session.app.textFields["User"].firstMatch
        XCTAssertTrue(author.waitForExistence(timeout: 5))
        author.click()
        author.typeText("author-with-no-matching-commits")
        session.app.buttons["Done"].click()
        let empty = session.window.staticTexts["No commits match the current filters"]
        XCTAssertTrue(empty.waitForExistence(timeout: 10), "Done did not apply the author filter")

        filters.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let clear = session.app.buttons["Clear"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.click()
        session.app.buttons["Done"].click()
        XCTAssertTrue(session.window.staticTexts["Initial commit"].firstMatch.waitForExistence(timeout: 10))
    }

    // MARK: - Rebased

    @MainActor
    func testCaptureRebasedCommitAndLog() throws {
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
