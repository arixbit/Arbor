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
    private func capture(window: XCUIElement, named name: String) {
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("[capture] \(name) frame=\(window.frame)")
    }
}
