import XCTest

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
    func testChangesGroupingPreservesStagingAndPartialState() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        let session = ArborUISession(fixture: fixture, screenshotSink: { self.add($0) })
        session.extraLaunchArguments = ["-arbor.toolWindowMode", "commit", "-arbor.toolWindowExpanded", "YES"]
        session.launch()
        defer { session.terminate() }

        let app = session.window.checkBoxes["Stage src/App.swift"].firstMatch
        let engine = session.window.checkBoxes["Stage src/Core/Engine.swift"].firstMatch
        XCTAssertTrue(app.waitForExistence(timeout: 10))
        XCTAssertTrue(engine.isHittable)
        func waitForValue(_ value: String, _ checkbox: XCUIElement) {
            let expectation = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in String(describing: checkbox.value ?? "") == value },
                object: checkbox
            )
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
        }
        waitForValue("0", app)
        waitForValue("1", engine)
        XCTAssertFalse(session.window.checkBoxes["Stage src/Untracked.swift"].exists,
                       "untracked files should start collapsed")
        XCTAssertFalse(session.window.staticTexts["Ignored Files"].exists)

        app.click()
        waitForValue("1", app)
        XCTAssertTrue(session.window.staticTexts["2 staged"].waitForExistence(timeout: 5))
        let path = fixture.appendingPathComponent("src/App.swift")
        var content = try String(contentsOf: path, encoding: .utf8)
        content += "\n// a new worktree edit after staging\n"
        try Data(content.utf8).write(to: path)
        XCTAssertTrue(session.window.staticTexts["Partially staged"].firstMatch.waitForExistence(timeout: 10))
        waitForValue("0", app)
        app.click()
        waitForValue("1", app)
        app.rightClick()
        let unstage = session.app.menuItems["Unstage"].firstMatch
        XCTAssertTrue(unstage.waitForExistence(timeout: 5))
        unstage.click()
        waitForValue("0", app)
        XCTAssertTrue(session.window.staticTexts["1 staged"].waitForExistence(timeout: 5))

        session.window.buttons["Unversioned Files"].firstMatch.click()
        let untracked = session.window.checkBoxes["Stage src/Untracked.swift"].firstMatch
        XCTAssertTrue(untracked.waitForExistence(timeout: 5))
        session.window.checkBoxes["Stage group: Unversioned Files"].firstMatch.click()
        XCTAssertTrue(session.window.staticTexts["2 staged"].waitForExistence(timeout: 10))
        XCTAssertTrue(session.window.checkBoxes["Stage src/Untracked.swift"].exists)
        session.window.checkBoxes["Stage group: Changes"].firstMatch.click()
        XCTAssertTrue(session.window.staticTexts["3 staged"].waitForExistence(timeout: 10))
        session.window.checkBoxes["Stage group: Changes"].firstMatch.click()
        XCTAssertTrue(session.window.staticTexts["0 staged"].waitForExistence(timeout: 10))
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

        let options = session.window.descendants(matching: .any)["Commit Options"].firstMatch
        options.click()
        let skipHooks = session.app.menuItems["Skip hooks"].firstMatch
        XCTAssertTrue(skipHooks.waitForExistence(timeout: 5))
        skipHooks.click()
        XCTAssertTrue(session.window.staticTexts["Skip hooks"].firstMatch.waitForExistence(timeout: 5),
                      "the active hook preference should remain visible after the menu closes")
        options.click()
        skipHooks.click()
        XCTAssertFalse(session.window.staticTexts["Skip hooks"].firstMatch.exists)
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
            guard let button = session.railButton(identifier) else {
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
    func testClickingAFileRowShowsItsContent() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }

        let session = ArborUISession(fixture: fixture, toolWindow: "log", screenshotSink: { self.add($0) })
        session.launch()
        defer { session.terminate() }

        XCTAssertTrue(session.openProjectTree(), "the project tree did not open")

        let row = session.window.buttons["README.md"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the project tree does not list README.md")
        let before = session.screenState()
        row.click()

        let deadline = Date().addingTimeInterval(10)
        var changed = session.screenState() != before
        while Date() < deadline, !changed {
            Thread.sleep(forTimeInterval: 0.25)
            changed = session.screenState() != before
        }
        XCTAssertTrue(changed, "clicking README.md in the project tree changed nothing")
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

/// A Git operation that cannot run must say why, not fail silently.
final class ArborUISmokeFeedbackUITests: XCTestCase {
    @MainActor
    func testFetchWithoutRemoteExplainsWhy() throws {
        let fixture = try ArborUIFixture.create()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }

        let session = ArborUISession(fixture: fixture, screenshotSink: { self.add($0) })
        session.launch()
        defer { session.terminate() }

        let before = session.screenState()
        session.window.descendants(matching: .any)["More Git Actions"].firstMatch.click()
        session.app.menuItems["Fetch"].firstMatch.click()

        let deadline = Date().addingTimeInterval(15)
        var after = session.screenState()
        while Date() < deadline, after == before {
            Thread.sleep(forTimeInterval: 0.3)
            after = session.screenState()
        }
        XCTAssertNotEqual(after, before, "Fetch on a repository without remotes changed nothing")

        let feedback = session.app.staticTexts.allElementsBoundByIndex
            .map { $0.label.isEmpty ? String(describing: $0.value ?? "") : $0.label }
            .filter { !$0.isEmpty }
        let explains = feedback.contains { text in
            let lower = text.lowercased()
            return lower.contains("remote") || lower.contains("fetch") || lower.contains("failed")
        }
        if !explains {
            session.recordScreenshot(named: "fetch-without-remote")
            print("=== TREE AFTER FETCH ===")
            print(session.app.debugDescription)
            print("=== END TREE ===")
        }
        XCTAssertTrue(
            explains,
            "Fetch without a remote left no explanation on screen; visible text: \(feedback.prefix(20))"
        )
    }
}
