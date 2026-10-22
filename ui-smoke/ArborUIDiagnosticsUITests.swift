import XCTest

/// Dumps the accessibility tree of every main surface.
///
/// This test never fails on content: it exists so a failure in the sweep can
/// be diagnosed from a real tree instead of a guess. Run it with
/// `ARBOR_UI_DUMP=1` to also write the trees under `tmp/ui-dumps/`.
final class ArborUIDiagnosticsUITests: XCTestCase {
    @MainActor
    func testDumpMainSurfaces() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }

        let session = ArborUISession(fixture: fixture, screenshotSink: { self.add($0) })
        session.launch()
        defer { session.terminate() }

        dump(session, named: "commit")
        session.recordScreenshot(named: "surface-commit")
    }

    @MainActor
    func testDumpLogSurface() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }

        let session = ArborUISession(fixture: fixture, toolWindow: "log", screenshotSink: { self.add($0) })
        session.launch()
        defer { session.terminate() }

        dump(session, named: "log")
        session.recordScreenshot(named: "surface-log")
    }

    @MainActor
    private func dump(_ session: ArborUISession, named name: String) {
        let tree = session.app.debugDescription
        let attachment = XCTAttachment(string: tree)
        attachment.name = "tree-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)

        print("=== A11Y TREE \(name) ===")
        print(tree)
        print("=== END A11Y TREE \(name) ===")
    }
}
