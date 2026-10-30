import XCTest

/// A comparable view of everything the user can currently observe.
///
/// The window's accessibility description is the signature: one accessibility
/// round-trip instead of one per element, and it covers the whole surface
/// (lists, labels, dialogs, enabled states, selection). The sweep compares it
/// before and after every click; an identical signature means the click did
/// nothing observable, which is the "空转" defect this suite exists to catch.
struct ScreenState: Equatable {
    let signature: String
    let lineCount: Int
    let sheets: Int
    let windows: Int
    let menus: Int
    let popovers: Int

    var hasModal: Bool { sheets > 0 }

    /// Accessibility dumps embed per-snapshot object addresses; they are noise
    /// for change detection and would make every comparison differ.
    private static let addressPattern = try! NSRegularExpression(pattern: "0x[0-9a-f]{6,}")

    static func normalize(_ description: String) -> String {
        let range = NSRange(description.startIndex..., in: description)
        return addressPattern.stringByReplacingMatches(in: description, range: range, withTemplate: "0x#")
    }

    static func firstDifference(_ lhs: String, _ rhs: String, limit: Int = 6) -> String {
        let left = lhs.split(separator: "\n", omittingEmptySubsequences: false)
        let right = rhs.split(separator: "\n", omittingEmptySubsequences: false)
        var lines: [String] = []
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? String(left[index]) : "<missing>"
            let r = index < right.count ? String(right[index]) : "<missing>"
            if l != r {
                lines.append("- \(l.trimmingCharacters(in: .whitespaces))\n+ \(r.trimmingCharacters(in: .whitespaces))")
                if lines.count >= limit { break }
            }
        }
        return lines.joined(separator: "\n")
    }

    func summary() -> String {
        "windows=\(windows) sheets=\(sheets) menus=\(menus) popovers=\(popovers) lines=\(lineCount)"
    }
}

enum SweepOutcome: Equatable {
    case changed(String)
    case dead
    case disabled
    case vanished
    case blockedByModal
    case unreachable
    case crashed(String)

    var isFailure: Bool {
        switch self {
        case .dead, .crashed:
            return true
        case .changed, .disabled, .vanished, .blockedByModal, .unreachable:
            return false
        }
    }
}

struct SweepFinding {
    let screen: String
    let role: String
    let label: String
    let identifier: String
    var frame: String = ""
    let outcome: SweepOutcome

    var description: String {
        let name = label.isEmpty ? identifier : label
        let outcomeText: String
        switch outcome {
        case let .changed(what): outcomeText = "changed(\(what))"
        case .dead: outcomeText = "DEAD"
        case .disabled: outcomeText = "disabled(skipped)"
        case .vanished: outcomeText = "vanished(before click)"
        case .blockedByModal: outcomeText = "blocked(a dialog stayed open)"
        case .unreachable: outcomeText = "unreachable(no pointer target)"
        case let .crashed(reason): outcomeText = "CRASHED(\(reason))"
        }
        let geometry = frame.isEmpty ? "" : " @\(frame)"
        return "\(role) “\(name)”\(geometry) → \(outcomeText)"
    }
}

/// Controls that must not be clicked during a sweep because they would leave
/// the fixture repository or the machine in a state the rest of the run cannot
/// recover from. They are still exercised by dedicated tests; this list only
/// keeps the generic sweep deterministic.
enum ArborUISweepPolicy {
    /// Controls that replace the whole surface. They are covered by their own
    /// assertions (`testActivityRailSwitchesViews`) instead of the generic
    /// sweep: after one is clicked every other control on the old surface is
    /// stale, and a stale SwiftUI control still reports itself as hittable.
    static let navigationIdentifiers: Set<String> = [
        "folder", "clock", "list.bullet.rectangle",
    ]

    static let navigationLabels: Set<String> = [
        "Project", "Log", "Operation Log", "Operation History",
        "Commit", "Stash", "Changes",
    ]

    /// Labels whose click is expected to end the process, mutate the host, or
    /// block on the network without a deterministic result.
    static let skippedLabels: Set<String> = [
        "Quit Arbor", "Quit", "退出 Arbor",
        "Open Project…", "Open Project...", "Clone Git Repository…", "Clone Git Repository...",
        "Initialize Git Repository…", "Initialize Git Repository...",
        "Check for Updates…", "Check for Updates...",
        "Export…", "Export...", "Export Diagnostics…", "Export Diagnostics...",
        "Reveal in Finder", "在 Finder 中显示",
        "Open in Browser", "在浏览器中打开",
        "Send Feedback", "Contact Support",
        // Opens a system open/save panel that covers the window and cannot be
        // driven from here.
        "New Folder", "Open Project", "Choose…", "Browse…", "打开项目",
        // Opens a menu or the Finder: the reaction is outside this app.
        "Template", "arrow.up.forward.app", "arrow.up.forward",
        // Network operations can block on a credential prompt or a Git
        // operation that outlives the click. They are asserted by
        // `testFetchWithoutRemoteExplainsWhy`, which checks the message the
        // user is left with.
        "Update", "Push", "Fetch",
    ]

    /// Labels whose click is allowed but is expected to open a confirmation.
    static let modalLabels: Set<String> = [
        "Push…", "Push...", "Force Push…", "Force Push...",
        "Revert", "Revert Commit", "Reset…", "Reset...",
        "Delete Branch", "Delete Tag", "Drop Commit", "Squash…", "Squash...",
        "Remove Remote", "Delete Worktree", "Abort Operation", "Abort",
        "Unstage All", "Discard All Changes", "Rollback…", "Rollback...",
    ]
}

@MainActor
final class ArborUISession {
    let fixture: URL
    let initialToolWindow: String
    /// Extra arguments for launches that need a specific persisted state,
    /// such as forcing the Commit tool window instead of restoring the last one.
    var extraLaunchArguments: [String] = []
    let screenshotSink: (XCTAttachment) -> Void
    private(set) var app: XCUIApplication
    private(set) var launchedAt = Date()
    private var queue: [Candidate] = []
    private var expectedWindowCount = 1
    private var consecutiveVanished = 0

    init(
        fixture: URL,
        toolWindow: String = "commit",
        screenshotSink: @escaping (XCTAttachment) -> Void = { _ in }
    ) {
        self.fixture = fixture
        self.initialToolWindow = toolWindow
        self.screenshotSink = screenshotSink
        self.app = XCUIApplication(url: ArborUIFixture.applicationUnderTest)
    }

    var window: XCUIElement { app.windows.firstMatch }

    /// The surface the sweep observes. Defaults to the main window; tests set
    /// it to a dialog or the Settings window when they sweep one of those.
    var observationRoot: XCUIElement?

    private var root: XCUIElement { observationRoot ?? window }

    // MARK: - Lifecycle

    func launch(timeout: TimeInterval = 90) {
        app.launchArguments = launchArguments
        app.launchEnvironment["ARBOR_UI_TEST"] = "1"
        app.launch()
        // Clicks only land on the frontmost application; a test run must not
        // depend on whichever window happened to be in front.
        app.activate()
        if !waitForStableState(timeout: timeout) {
            recordScreenshot(named: "launch-timeout")
            XCTFail("Arbor did not reach a stable UI within \(Int(timeout))s: \(screenState().summary())")
        }
        launchedAt = Date()
        expectedWindowCount = app.windows.count
    }

    private var launchArguments: [String] {
        var args: [String] = [fixture.path]
        if initialToolWindow == "log" {
            args.append("--log")
        }
        args.append(contentsOf: extraLaunchArguments)
        // Force the interface language so accessibility labels are stable.
        args.append(contentsOf: ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"])
        return args
    }

    func relaunch() {
        app.terminate()
        app = XCUIApplication(url: ArborUIFixture.applicationUnderTest)
        launch()
    }

    func terminate() {
        if app.state != .notRunning {
            app.terminate()
        }
    }

    // MARK: - Observation

    func screenState() -> ScreenState {
        let raw = window.exists ? window.debugDescription : app.debugDescription
        let description = ScreenState.normalize(raw)
        return ScreenState(
            signature: description,
            lineCount: description.split(separator: "\n", omittingEmptySubsequences: false).count,
            sheets: app.sheets.count,
            windows: app.windows.count,
            // A MenuButton click opens an NSMenu outside the window's own
            // accessibility subtree; without this the sweep would report
            // every menu as dead.
            menus: app.menus.count,
            // Popovers (Changelist editor, filter settings) are their own
            // element type and swallow clicks aimed at the surface behind them.
            popovers: app.popovers.count
        )
    }

    /// Only roles whose reaction is visible in the accessibility tree.
    ///
    /// Menu buttons are excluded on purpose: AppKit draws an open menu outside
    /// the application's accessibility subtree, so a menu click is
    /// indistinguishable from a dead click here. Menus are covered by their
    /// own assertions instead of being reported as dead controls.
    static let controlTypes: [XCUIElement.ElementType] = [
        .button, .checkBox, .radioButton, .popUpButton,
    ]

    /// Poll until two consecutive observations match, which means the app has
    /// finished animating and loading for this interaction.
    @discardableResult
    func waitForStableState(timeout: TimeInterval = 25, interval: TimeInterval = 0.3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var previous = screenState()
        while Date() < deadline {
            Thread.sleep(forTimeInterval: interval)
            let current = screenState()
            if current == previous, current.lineCount > 5 {
                return true
            }
            if ProcessInfo.processInfo.environment["ARBOR_UI_TRACE"] == "1", current != previous {
                print("[unstable]\n" + ScreenState.firstDifference(previous.signature, current.signature))
            }
            previous = current
        }
        return false
    }

    /// Wait for the next observable state that differs from `before`.
    private func waitForChange(from before: ScreenState, timeout: TimeInterval) -> ScreenState? {
        let deadline = Date().addingTimeInterval(timeout)
        var interval: TimeInterval = 0.2
        while Date() < deadline {
            Thread.sleep(forTimeInterval: interval)
            let current = screenState()
            if current != before {
                return current
            }
            interval = min(interval * 2, 1.0)
        }
        return nil
    }
    // MARK: - Clickeable inventory

    struct Candidate {
        let role: XCUIElement.ElementType
        let label: String
        let identifier: String
        let element: XCUIElement
    }

    /// Every interactive control that is currently visible, enabled and inside
    /// the main window.
    func visibleControls(in scope: XCUIElement? = nil) -> [Candidate] {
        let root = scope ?? self.root
        var seen = Set<String>()
        var candidates: [Candidate] = []
        let windowFrame = root.frame

        for type in ArborUISession.controlTypes {
            for element in root.descendants(matching: type).allElementsBoundByIndex {
                guard element.exists, element.isEnabled, element.isHittable else { continue }
                let frame = element.frame
                guard frame.width > 1, frame.height > 1 else { continue }
                guard windowFrame.contains(frame) || windowFrame.intersects(frame) else { continue }

                let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
                let identifier = element.identifier
                // Window traffic lights are AppKit machinery, not product UI.
                guard !identifier.hasPrefix("_XCUI:") else { continue }
                // Clicking an already-selected control is expected to be inert:
                // it *is* the current state, so there is nothing to change.
                // SwiftUI radios and checkboxes expose selection as a value,
                // not through isSelected.
                guard !element.isSelected else { continue }
                if type == .radioButton, String(describing: element.value ?? "") == "1" { continue }
                guard !label.isEmpty || !identifier.isEmpty else { continue }
                guard !ArborUISweepPolicy.navigationIdentifiers.contains(identifier),
                      !ArborUISweepPolicy.navigationLabels.contains(label) else { continue }
                let key = "\(type.rawValue)|\(identifier)|\(label)"
                guard seen.insert(key).inserted else { continue }
                candidates.append(Candidate(role: type, label: label, identifier: identifier, element: element))
            }
        }
        return candidates
    }

    // MARK: - Sweep

    /// Click every visible control once and require an observable change.
    ///
    /// The candidate list is re-read after every click: a click that opens a
    /// panel or a dialog replaces the surface, and a plan captured up front
    /// would then report stale rows as "vanished" instead of testing them.
    func sweep(
        screen: String,
        limit: Int = 24,
        timeBudget: TimeInterval = 120,
        changeTimeout: TimeInterval = 4,
        isolateOnSurfaceChange: Bool = false,
        reopen: ((ArborUISession) -> Void)? = nil
    ) -> [SweepFinding] {
        var findings: [SweepFinding] = []
        var visited = Set<String>()
        var clicked = 0
        var resets = 0
        let deadline = Date().addingTimeInterval(timeBudget)
        consecutiveVanished = 0

        while clicked < limit, Date() < deadline {
            if queue.isEmpty {
                queue = visibleControls().filter { candidate in
                    !ArborUISweepPolicy.skippedLabels.contains(candidate.label)
                        && !visited.contains(Self.key(candidate))
                }
            }
            guard !queue.isEmpty, let candidate = queue.first else { break }
            queue.removeFirst()
            visited.insert(Self.key(candidate))
            clicked += 1

            if app.state != .runningForeground {
                app.activate()
                Thread.sleep(forTimeInterval: 0.4)
            }
            if app.state != .runningForeground {
                findings.append(
                    SweepFinding(
                        screen: screen, role: candidate.role.arboName, label: candidate.label,
                        identifier: candidate.identifier,
                        outcome: .crashed("app not frontmost before click")
                    )
                )
                break
            }

            // A system panel (NSOpenPanel and friends) is a separate window
            // that covers the main one: every click lands on it.
            dismissCoveringWindows()

            // A modal that survived the previous dismissal swallows every
            // click. That is a stuck dialog, not a dead control.
            if app.sheets.count > 0 || app.popovers.count > 0 || app.windows.count > expectedWindowCount {
                closeFrontmostSheet()
                if app.sheets.count > 0 {
                    findings.append(
                        SweepFinding(
                            screen: screen, role: candidate.role.arboName, label: candidate.label,
                            identifier: candidate.identifier, outcome: .blockedByModal
                        )
                    )
                    continue
                }
            }

            guard let element = resolve(candidate), element.exists, element.isEnabled else {
                consecutiveVanished += 1
                findings.append(
                    SweepFinding(
                        screen: screen, role: candidate.role.arboName, label: candidate.label,
                        identifier: candidate.identifier, outcome: .vanished
                    )
                )
                // A click navigated away and the rest of the plan is stale:
                // re-read the surface instead of reporting every row as gone.
                if consecutiveVanished >= 3 {
                    queue = []
                    consecutiveVanished = 0
                }
                continue
            }
            consecutiveVanished = 0

            // Read the frame once: it is both the hit-test check and the click
            // target. Clicking through the element itself keeps a reference to
            // its accessibility identity, and a surface that rebuilds between
            // the checks and the click makes that reference unresolvable,
            // which aborts the sweep instead of reporting a result.
            guard element.exists else {
                consecutiveVanished += 1
                findings.append(
                    SweepFinding(
                        screen: screen, role: candidate.role.arboName, label: candidate.label,
                        identifier: candidate.identifier, outcome: .vanished
                    )
                )
                continue
            }
            let frame = element.frame

            // Rows scrolled out of a list report an infinite frame; clicking
            // that point aborts the run inside XCUITest instead of reporting.
            guard frame.minX.isFinite, frame.minY.isFinite,
                  frame.width.isFinite, frame.height.isFinite,
                  frame.width > 0, frame.height > 0 else {
                findings.append(
                    SweepFinding(
                        screen: screen, role: candidate.role.arboName, label: candidate.label,
                        identifier: candidate.identifier, outcome: .unreachable
                    )
                )
                continue
            }

            // Elements from a closed menu or a covered surface are still in
            // the tree but have no pointer target; clicking them throws instead
            // of reporting. Record them separately: they are not a defect of
            // the control, but they are not coverage either.
            guard app.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) else {
                findings.append(
                    SweepFinding(
                        screen: screen, role: candidate.role.arboName, label: candidate.label,
                        identifier: candidate.identifier,
                        frame: "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))",
                        outcome: .unreachable
                    )
                )
                continue
            }
            guard element.isHittable else {
                findings.append(
                    SweepFinding(
                        screen: screen, role: candidate.role.arboName, label: candidate.label,
                        identifier: candidate.identifier,
                        frame: "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))",
                        outcome: .unreachable
                    )
                )
                continue
            }

            let before = screenState()
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX, dy: frame.midY))
                .click()
            guard let after = waitForChange(from: before, timeout: changeTimeout) else {
                recordScreenshot(named: "dead-\(screen)-\(clicked)")
                findings.append(
                    SweepFinding(
                        screen: screen, role: candidate.role.arboName, label: candidate.label,
                        identifier: candidate.identifier,
                        frame: "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))",
                        outcome: .dead
                    )
                )
                continue
            }

            findings.append(
                SweepFinding(
                    screen: screen, role: candidate.role.arboName, label: candidate.label,
                    identifier: candidate.identifier,
                    outcome: .changed(describeChange(from: before, to: after))
                )
            )
            dismissModalIfNeeded(reference: before)

            // A click that swapped the surface leaves the previous controls in
            // the accessibility tree while they are no longer reachable by a
            // pointer. Reload the app and re-open the screen so the remaining
            // controls are evaluated against a real surface.
            let surfaceReplaced = after.sheets != before.sheets
                || after.windows != before.windows
                || abs(after.lineCount - before.lineCount) > 30
            // Relaunching resets the working tree, so labels such as
            // “Unstaged Files, 2 files” can change and the sweep would keep
            // exploring. Bound the resets and the whole run.
            if isolateOnSurfaceChange, surfaceReplaced, resets < 2, Date() < deadline {
                resets += 1
                resetSurface(reopen: reopen)
            }
        }
        return findings
    }

    private func resetSurface(reopen: ((ArborUISession) -> Void)?) {
        relaunch()
        reopen?(self)
        queue = []
        consecutiveVanished = 0
    }

    private static func key(_ candidate: Candidate) -> String {
        "\(candidate.role.rawValue)|\(candidate.identifier)|\(candidate.label)"
    }

    private func resolve(_ candidate: Candidate) -> XCUIElement? {
        if !candidate.identifier.isEmpty {
            let byIdentifier = root.descendants(matching: candidate.role)
                .matching(identifier: candidate.identifier)
                .matching(NSPredicate(format: "label == %@", candidate.label)).firstMatch
            if byIdentifier.exists { return byIdentifier }
        }
        let byLabel = root.descendants(matching: candidate.role)
            .matching(NSPredicate(format: "label == %@", candidate.label)).firstMatch
        return byLabel.exists ? byLabel : nil
    }

    private func describeChange(from before: ScreenState, to after: ScreenState) -> String {
        var parts: [String] = []
        if after.sheets != before.sheets { parts.append("sheet \(before.sheets)→\(after.sheets)") }
        if after.windows != before.windows { parts.append("window \(before.windows)→\(after.windows)") }
        if after.popovers != before.popovers { parts.append("popover \(before.popovers)→\(after.popovers)") }
        if after.menus != before.menus { parts.append("menu \(before.menus)→\(after.menus)") }
        if after.lineCount != before.lineCount { parts.append("tree \(before.lineCount)→\(after.lineCount) lines") }
        return parts.isEmpty ? "tree content" : parts.joined(separator: ", ")
    }

    /// Closes windows that are not the surface under test (open panels, extra
    /// editors) so the next click reaches the control it names.
    func dismissCoveringWindows() {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, app.windows.count > expectedWindowCount {
            let top = app.windows.element(boundBy: app.windows.count - 1)
            guard top.exists else { break }
            var closed = false
            for label in ["Cancel", "Close", "Done", "OK", "取消", "关闭", "完成"] {
                let button = top.buttons[label].firstMatch
                if button.exists, button.isHittable {
                    button.click()
                    closed = true
                    break
                }
            }
            if !closed { closeWindow(top) }
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    /// Closes the frontmost sheet through its own dismiss button.
    func closeFrontmostSheet() {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, app.sheets.count > 0 {
            let labels = ["Cancel", "Close", "Done", "OK", "取消", "关闭", "完成"]
            let sheet = app.sheets.firstMatch
            var closed = false
            for label in labels {
                let button = sheet.buttons[label].firstMatch
                if button.exists, button.isHittable {
                    button.click()
                    closed = true
                    break
                }
            }
            if !closed { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// Any dialog opened by a sweep click is cancelled, so the next control is
    /// evaluated against the same screen.
    func dismissModalIfNeeded(reference: ScreenState) {
        closeFrontmostSheet()
        // Transient surfaces (popovers, inline editors, menus) are not always
        // typed as an XCUI popover or menu, and they swallow the next click.
        // Click unused title-bar space so dismissal does not synthesize a
        // keyboard event and trigger third-party input-method authorization.
        dismissTransientSurface()
        Thread.sleep(forTimeInterval: 0.2)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, app.menus.count > reference.menus || app.popovers.count > 0 {
            dismissTransientSurface()
            Thread.sleep(forTimeInterval: 0.2)
        }
        if app.windows.count > reference.windows, app.state == .runningForeground {
            closeWindow(app.windows.element(boundBy: app.windows.count - 1))
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    func dismissTransientSurface() {
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.02)).click()
    }

    private func closeWindow(_ target: XCUIElement) {
        let close = target.buttons["_XCUI:CloseWindow"].firstMatch
        if close.exists, close.isHittable { close.click() }
    }

    // MARK: - Screenshots

    @discardableResult
    func recordScreenshot(named name: String) -> XCTAttachment? {
        guard window.exists else { return nil }
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        screenshotSink(attachment)
        return attachment
    }

    // MARK: - Reporting

    func attachReport(_ findings: [SweepFinding], named name: String) {
        let body = findings.map(\.description).joined(separator: "\n")
        let attachment = XCTAttachment(string: body.isEmpty ? "(no controls clicked)" : body)
        attachment.name = name
        attachment.lifetime = .keepAlways
        screenshotSink(attachment)
    }

    static func failures(in findings: [SweepFinding]) -> [SweepFinding] {
        findings.filter { $0.outcome.isFailure }
    }
}

extension XCUIElement.ElementType {
    /// Readable role name for sweep reports.
    var arboName: String {
        switch self {
        case .button: return "button"
        case .checkBox: return "checkbox"
        case .radioButton: return "radio"
        case .popUpButton: return "popup"
        case .menuButton: return "menu"
        case .tab: return "tab"
        case .disclosureTriangle: return "disclosure"
        default: return "type\(rawValue)"
        }
    }
}

// MARK: - Navigation

extension ArborUISession {
    /// The left activity rail hosts project tree, log, operations and commit
    /// views. They are icon-only buttons, so they are located by symbol
    /// identifier inside the narrow rail column.
    func railButton(_ identifier: String) -> XCUIElement? {
        let windowFrame = window.frame
        let candidates = window.buttons.matching(identifier: identifier).allElementsBoundByIndex
        return candidates.first { element in
            element.frame.minX - windowFrame.minX < 140 && element.frame.width < 60
        }
    }

    @discardableResult
    func openProjectTree() -> Bool {
        guard let button = railButton("folder") else { return false }
        button.click()
        return waitForStableState(timeout: 15)
    }

    @discardableResult
    func openOperations() -> Bool {
        guard let button = railButton("list.bullet.rectangle") else { return false }
        button.click()
        return waitForStableState(timeout: 15)
    }

    @discardableResult
    func openLog() -> Bool {
        guard let button = railButton("clock") else { return false }
        button.click()
        return waitForStableState(timeout: 15)
    }

    /// The branches popover, when one is presented.
    ///
    /// XCUITest classifies a SwiftUI popover as a window on macOS, and
    /// `app.popovers` keeps a zero-size element for a popover that is not on
    /// screen, so the content carries its own identifier.
    private var branchesPopoverContent: XCUIElement {
        app.descendants(matching: .any)["branches-popover"].firstMatch
    }

    /// Whether the branches popover is on screen.
    var isBranchesPopoverOpen: Bool {
        branchesPopoverContent.exists
            || app.descendants(matching: .any)["branches-popover-search"].firstMatch.exists
    }

    /// The current-branch chip in the header opens the branches popover.
    @discardableResult
    func openBranchesPopover(branch: String = "main") -> Bool {
        // The chip toggles the popover, so clicking it again closes it.
        if isBranchesPopoverOpen { return waitForStableState(timeout: 15) }
        // The status bar repeats the branch name, so the first match is not
        // necessarily the chip that opens the popover. Try them top-down.
        let candidates = window.buttons
            .matching(NSPredicate(format: "label == %@", branch))
            .allElementsBoundByIndex
            .sorted { $0.frame.minY < $1.frame.minY }
        for chip in candidates where chip.exists && chip.isHittable {
            chip.click()
            let search = app.descendants(matching: .any)["branches-popover-search"].firstMatch
            if branchesPopoverContent.waitForExistence(timeout: 3) || search.exists {
                return waitForStableState(timeout: 15)
            }
        }
        recordScreenshot(named: "branches-popover-missing")
        return false
    }

    /// Open the Settings scene through the application menu.
    @discardableResult
    func openSettings() -> Bool {
        app.menuBars.menuBarItems["Arbor"].click()
        let settingsItem = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "Settings")).firstMatch
        guard settingsItem.waitForExistence(timeout: 3) else { return false }
        settingsItem.click()
        let deadline = Date().addingTimeInterval(15)
        defer { expectedWindowCount = app.windows.count }
        while Date() < deadline {
            let settings = app.windows
                .matching(identifier: "com_apple_SwiftUI_Settings_window").firstMatch
            if settings.exists {
                observationRoot = settings
                return waitForStableState(timeout: 10)
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }
}
