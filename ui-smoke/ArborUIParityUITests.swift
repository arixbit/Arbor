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
        let surface = surfaceTag(of: window, fallback: "log")
        try dump(window.debugDescription, named: "rebased-\(surface)")
        print("[parity] Rebased 当前界面：\(window.title)（记为 \(surface)）")

        let commitButton = window.buttons["Commit"].firstMatch
        if commitButton.exists && commitButton.isHittable {
            commitButton.click()
            Thread.sleep(forTimeInterval: 1.5)
            let after = surfaceTag(of: window, fallback: surface)
            if after != surface {
                try dump(window.debugDescription, named: "rebased-\(after)")
            }
        }
    }
}
