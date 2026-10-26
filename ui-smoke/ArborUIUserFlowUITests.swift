import XCTest
import AppKit

/// Full user journeys against disposable repositories and a local bare remote.
/// Use the real Git binary: /usr/bin/git is an xcrun shim that cannot run in
/// the UI runner's sandbox. Git only reads and writes this test's container.
@MainActor
final class ArborUIUserFlowUITests: XCTestCase {
    private var root: URL!
    private var repo: URL!
    private var session: ArborUISession!

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "arbor-user-flow-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repo = root.appendingPathComponent("repo")
    }

    override func tearDownWithError() throws {
        if let session, (testRun?.failureCount ?? 0) > 0 {
            session.recordScreenshot(named: "user-flow-blocked")
            print(session.app.debugDescription)
        }
        session?.terminate()
        // Retain fixtures alongside the result bundle for independent inspection.
        print("USER_FLOW_FIXTURE \(root.path)")
    }

    @discardableResult
    private func git(_ args: String..., at directory: URL? = nil) throws -> String {
        let binary = [
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
            "/Library/Developer/CommandLineTools/usr/bin/git",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }!
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.currentDirectoryURL = directory ?? repo ?? root
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "UserFlowGit", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")): \(output)"])
        }
        return output
    }

    private func prepare() throws {
        try git("init", "--bare", "--initial-branch=main", root.appendingPathComponent("remote.git").path, at: root)
        try git("init", "--initial-branch=main", repo.path, at: root)
        try git("config", "user.name", "Arbor User Flow")
        try git("config", "user.email", "flow@arbor.invalid")
        try git("config", "commit.gpgsign", "false")
        try write((1...24).map { "line \($0)" }.joined(separator: "\n") + "\n", to: "notes.txt")
        try git("add", ".")
        try git("commit", "-m", "Journey initial")
        try git("remote", "add", "origin", root.appendingPathComponent("remote.git").path)
        try git("push", "-u", "origin", "main")
    }

    private func write(_ text: String, to path: String) throws {
        try Data(text.utf8).write(to: repo.appendingPathComponent(path))
    }

    func testGitFixtureSupport() throws {
        try prepare()
        XCTAssertEqual(try git("status", "--porcelain"), "")
        XCTAssertEqual(try git("rev-parse", "HEAD"), try git("rev-parse", "origin/main"))
    }

    private func launch(log: Bool = false, language: String = "en", extraArguments: [String] = []) {
        session = ArborUISession(fixture: repo, toolWindow: log ? "log" : "commit", screenshotSink: { self.add($0) })
        session.extraLaunchArguments = [
            "-arbor.appLanguage", language, "-arbor.toolWindowExpanded", "YES",
            "-arbor.toolWindowMode", log ? "log" : "commit",
        ] + extraArguments
        session.launch()
    }

    private func click(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "missing \(element)", file: file, line: line)
        if element.elementType != .textView {
            XCTAssertTrue(element.isEnabled, "disabled \(element)", file: file, line: line)
        }
        if element.elementType == .menuItem {
            element.click()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }
    }

    private func menu(_ title: String, localChanges: Bool = false) {
        session.app.menuBars.menuBarItems["VCS"].click()
        session.app.menuItems["Git"].firstMatch.hover()
        if localChanges { session.app.menuItems["Local Changes"].firstMatch.hover() }
        let item = session.app.menuItems[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        XCTAssertTrue(item.isEnabled)
        XCTAssertGreaterThan(item.frame.width, 0, "Menu item is not visible: \(title)")
        item.click()
    }

    private func enter(_ value: String, into field: XCUIElement) {
        click(field)
        session.app.menuBars.menuBarItems["Edit"].click()
        session.app.menuItems["Select All"].firstMatch.click()
        // Type directly: other applications may update the shared clipboard
        // while the test is navigating menus.
        session.app.typeText(value)
        XCTAssertEqual(field.value as? String, value)
    }

    private func eventually(_ label: String, _ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(20)
        repeat {
            if try condition() { print("USER_FLOW_PASS \(label)"); return }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        session.recordScreenshot(named: "blocked-\(label)")
        print(session.app.debugDescription)
        XCTFail("Git state did not confirm: \(label)")
    }

    func test01DailyCommitClonePartialStageCommitPush() throws {
        try prepare()
        launch()
        XCTAssertEqual(session.app.menuBars.menuBarItems.matching(identifier: "File").count, 1)
        session.app.menuBars.menuBarItems["File"].click()
        click(session.app.menuItems["Clone Git Repository…"].firstMatch)
        enter(root.appendingPathComponent("remote.git").path, into: session.app.textFields["Repository URL"].firstMatch)
        enter(root.path, into: session.app.textFields["Parent directory"].firstMatch)
        enter("cloned", into: session.app.textFields["Directory name (optional)"].firstMatch)
        click(session.app.buttons["Clone"].firstMatch)
        let clone = root.appendingPathComponent("cloned")
        try eventually("clone") { FileManager.default.fileExists(atPath: clone.appendingPathComponent(".git/HEAD").path) }
        // Reopen the cloned repository, as a user returning to a project would.
        session.terminate()
        repo = clone
        try git("config", "user.name", "Arbor User Flow")
        try git("config", "user.email", "flow@arbor.invalid")
        try git("config", "commit.gpgsign", "false")
        let original = try String(contentsOf: repo.appendingPathComponent("notes.txt"), encoding: .utf8)
        try write(original.replacingOccurrences(of: "line 2\n", with: "selected change\n")
            .replacingOccurrences(of: "line 22\n", with: "leave for later\n"), to: "notes.txt")
        launch()
        let partial = session.window.buttons["Partial stage"].firstMatch
        click(partial)
        let selected = session.app.sheets.firstMatch.staticTexts["selected change"].firstMatch
        click(selected)
        session.recordScreenshot(named: "partial-line-selected")
        XCTAssertTrue(session.app.sheets.firstMatch.frame.contains(
            session.app.buttons["Stage Selected Lines"].firstMatch.frame
        ))
        click(session.app.buttons["Stage Selected Lines"].firstMatch)
        try eventually("partial-stage") {
            let staged = try self.git("diff", "--cached")
            return staged.contains("selected change") && !staged.contains("leave for later")
        }
        session.recordScreenshot(named: "daily-partial-stage")
        // Close the diff dialog and commit only the selected change.
        if session.app.buttons["Close"].firstMatch.exists { click(session.app.buttons["Close"].firstMatch) }
        let editor = session.window.textViews.firstMatch
        enter("Journey partial commit", into: editor)
        let commit = try XCTUnwrap(session.window.buttons
            .matching(NSPredicate(format: "label == %@", "Commit"))
            .allElementsBoundByIndex.first { $0.frame.minY > editor.frame.maxY })
        click(commit)
        try eventually("commit") { try self.git("log", "-1", "--format=%s") == "Journey partial commit" }
        XCTAssertTrue(try git("diff").contains("leave for later"))
        XCTAssertFalse(try git("show", "HEAD:notes.txt").contains("leave for later"))
        menu("Push…")
        click(session.app.sheets.firstMatch.buttons["Push"].firstMatch)
        try eventually("push") {
            try self.git("rev-parse", "HEAD") == self.git("--git-dir", self.root.appendingPathComponent("remote.git").path, "rev-parse", "main")
        }
        session.recordScreenshot(named: "daily-pushed")
    }

    func test02FetchPullCheckout() throws {
        try prepare()
        try git("branch", "topic")
        let peer = root.appendingPathComponent("peer")
        try git("clone", root.appendingPathComponent("remote.git").path, peer.path, at: root)
        try git("config", "user.name", "Peer", at: peer)
        try git("config", "user.email", "peer@arbor.invalid", at: peer)
        try git("config", "commit.gpgsign", "false", at: peer)
        try Data("remote update\n".utf8).write(to: peer.appendingPathComponent("remote.txt"))
        try git("add", ".", at: peer)
        try git("commit", "-m", "Journey remote update", at: peer)
        try git("push", at: peer)
        let remoteHead = try git("rev-parse", "HEAD", at: peer)
        let initialHead = try git("rev-parse", "HEAD")
        launch()
        menu("Fetch")
        try eventually("fetch") { try self.git("rev-parse", "origin/main") == remoteHead }
        XCTAssertEqual(try git("rev-parse", "HEAD"), initialHead)
        menu("Pull…")
        click(session.app.buttons["Pull"].firstMatch)
        try eventually("pull") { try self.git("rev-parse", "HEAD") == remoteHead }
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("remote.txt"), encoding: .utf8), "remote update\n")
        XCTAssertTrue(session.openBranchesPopover())
        click(session.app.buttons["topic"].firstMatch)
        try eventually("checkout") { try self.git("branch", "--show-current") == "topic" }
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("remote.txt").path))
        session.recordScreenshot(named: "branches-checkout")
    }

    private func prepareConflict() throws {
        try prepare()
        try git("switch", "-c", "topic")
        try write("topic version\n", to: "notes.txt")
        try git("commit", "-am", "Journey topic change")
        try git("switch", "main")
        try write("current version\n", to: "notes.txt")
        try git("commit", "-am", "Journey current change")
    }

    private func startConflict(rebase: Bool) throws {
        launch()
        menu(rebase ? "Rebase…" : "Merge…")
        enter("topic", into: session.app.textFields["branch or revision"].firstMatch)
        if rebase {
            let interactive = session.app.checkBoxes["Interactive"].firstMatch
            if String(describing: interactive.value ?? "") == "1" { click(interactive) }
        }
        click(session.app.buttons[rebase ? "Start Rebase" : "Merge"].firstMatch)
        try eventually(rebase ? "rebase-conflict" : "merge-conflict") {
            try self.git("diff", "--name-only", "--diff-filter=U") == "notes.txt"
        }
        if !session.app.buttons["Accept All Theirs"].firstMatch.waitForExistence(timeout: 3) {
            menu("Resolve Conflicts")
        }
        session.recordScreenshot(named: rebase ? "rebase-conflict" : "merge-conflict")
    }

    func test03MergeResolveContinue() throws {
        try prepareConflict()
        try startConflict(rebase: false)
        click(session.app.buttons["Accept All Theirs"].firstMatch)
        click(session.app.buttons["Mark Resolved"].firstMatch)
        try eventually("merge-resolved") { try self.git("diff", "--name-only", "--diff-filter=U").isEmpty }
        click(session.app.buttons["Complete Merge"].firstMatch)
        try eventually("merge-complete") {
            try self.git("rev-list", "--parents", "-1", "HEAD").split(separator: " " ).count == 3
                && self.git("status", "--porcelain").isEmpty
        }
        XCTAssertEqual(try git("rev-list", "--parents", "-1", "HEAD").split(separator: " " ).count, 3)
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("notes.txt"), encoding: .utf8), "topic version\n")
        XCTAssertEqual(try git("status", "--porcelain"), "")
    }

    func test04MergeAbort() throws {
        try prepareConflict()
        let head = try git("rev-parse", "HEAD")
        try startConflict(rebase: false)
        click(session.app.buttons["Abort"].firstMatch)
        click(session.app.dialogs.firstMatch.buttons["Abort"].firstMatch)
        try eventually("merge-abort") {
            try self.git("rev-parse", "HEAD") == head
                && self.git("status", "--porcelain").isEmpty
        }
        XCTAssertEqual(try git("rev-parse", "HEAD"), head)
        XCTAssertEqual(try git("status", "--porcelain"), "")
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("notes.txt"), encoding: .utf8), "current version\n")
    }

    func test05RebaseResolveContinue() throws {
        try prepareConflict()
        let head = try git("rev-parse", "HEAD")
        let topic = try git("rev-parse", "topic")
        try startConflict(rebase: true)
        XCTAssertTrue(session.app.staticTexts["Upstream (ours)"].firstMatch.exists)
        XCTAssertTrue(session.app.staticTexts["Your commit (theirs)"].firstMatch.exists)
        click(session.app.buttons["Accept All Theirs"].firstMatch)
        click(session.app.buttons["Mark Resolved"].firstMatch)
        try eventually("rebase-resolved") { try self.git("diff", "--name-only", "--diff-filter=U").isEmpty }
        click(session.app.buttons["Continue Rebase"].firstMatch)
        try eventually("rebase-complete") { try self.git("branch", "--show-current") == "main" }
        XCTAssertNotEqual(try git("rev-parse", "HEAD"), head)
        XCTAssertEqual(try git("rev-parse", "HEAD^"), topic)
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("notes.txt"), encoding: .utf8), "current version\n")
        XCTAssertEqual(try git("status", "--porcelain"), "")
    }

    func test06RebaseAbort() throws {
        try prepareConflict()
        let head = try git("rev-parse", "HEAD")
        try startConflict(rebase: true)
        click(session.app.buttons["Abort"].firstMatch)
        click(session.app.dialogs.firstMatch.buttons["Abort"].firstMatch)
        try eventually("rebase-abort") { try self.git("branch", "--show-current") == "main" }
        XCTAssertEqual(try git("rev-parse", "HEAD"), head)
        XCTAssertEqual(try git("status", "--porcelain"), "")
    }

    func test07HistoryCherryPickRevertReset() throws {
        try prepare()
        let initial = try git("rev-parse", "HEAD")
        try git("switch", "-c", "source")
        try write("picked content\n", to: "picked.txt")
        try git("add", ".")
        try git("commit", "-m", "Journey pick me")
        try git("switch", "main")
        launch(log: true)
        let source = session.window.staticTexts["Journey pick me"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        click(session.app.menuItems["Cherry-pick"].firstMatch)
        try eventually("cherry-pick") { try self.git("log", "-1", "--format=%s") == "Journey pick me" }
        XCTAssertEqual(try git("rev-parse", "HEAD^"), initial)
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("picked.txt"), encoding: .utf8), "picked content\n")
        // Inspect the selected historical commit before reversing it.
        click(session.window.staticTexts["Journey pick me"].firstMatch)
        let changedFile = session.window.staticTexts["picked.txt"].firstMatch
        XCTAssertTrue(changedFile.waitForExistence(timeout: 10))
        changedFile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()
        XCTAssertTrue(session.app.staticTexts["picked content"].firstMatch.waitForExistence(timeout: 10))
        session.recordScreenshot(named: "history-diff")
        click(session.app.sheets.firstMatch.buttons["Done"].firstMatch)
        session.window.staticTexts["Journey pick me"].firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        click(session.app.menuItems["Revert Commit"].firstMatch)
        click(session.app.buttons["Revert"].firstMatch)
        try eventually("revert") { try self.git("log", "-1", "--format=%s").hasPrefix("Revert ") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("picked.txt").path))
        XCTAssertEqual(try git("rev-list", "--count", "HEAD"), "3")
        try write("keep my local edit\n", to: "notes.txt")
        try write("keep staged file\n", to: "local.txt")
        try git("add", "local.txt")
        menu("Reset Head…")
        enter(initial, into: session.app.textFields["Revision"].firstMatch)
        click(session.app.radioButtons["Mixed — reset index, keep working tree"].firstMatch)
        click(session.app.buttons["Reset"].firstMatch)
        try eventually("reset") {
            try self.git("rev-parse", "HEAD") == initial
                && self.git("diff", "--cached").isEmpty
                && FileManager.default.fileExists(atPath: self.repo.appendingPathComponent(".git/arbor-reset-rollback").path)
        }
        XCTAssertEqual(try git("diff", "--cached"), "")
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("notes.txt"), encoding: .utf8), "keep my local edit\n")
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("local.txt"), encoding: .utf8), "keep staged file\n")
        session.recordScreenshot(named: "history-reset")
    }

    func test08StashSaveAndRestoreIndex() throws {
        try prepare()
        try write("staged content\n", to: "staged.txt")
        try git("add", "staged.txt")
        try write("unstaged content\n", to: "notes.txt")
        let beforeStatus = try git("status", "--porcelain")
        let beforeIndex = try git("diff", "--cached")
        launch()
        menu("Stash…", localChanges: true)
        enter("Journey stash", into: session.app.textFields["Message (optional)"].firstMatch)
        click(session.app.sheets.firstMatch.buttons["Stash"].firstMatch)
        try eventually("stash-save") { try self.git("status", "--porcelain").isEmpty }
        XCTAssertTrue(try git("stash", "list").contains("Journey stash"))
        menu("Unstash…", localChanges: true)
        click(session.app.checkBoxes["Pop stash (remove after applying)"].firstMatch)
        click(session.app.checkBoxes["Restore staged state"].firstMatch)
        click(session.app.buttons["Pop"].firstMatch)
        try eventually("stash-pop") { try self.git("stash", "list").isEmpty }
        XCTAssertEqual(try git("status", "--porcelain"), beforeStatus)
        XCTAssertEqual(try git("diff", "--cached"), beforeIndex)
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("notes.txt"), encoding: .utf8), "unstaged content\n")
        session.recordScreenshot(named: "stash-restored")
    }

    func test09MenusFollowTheActiveProjectWindow() throws {
        try prepare()
        let other = root.appendingPathComponent("other")
        try git("clone", repo.path, other.path, at: root)
        try git("config", "user.name", "Other Project", at: other)
        try git("config", "user.email", "other@arbor.invalid", at: other)
        try write("first project edit\n", to: "notes.txt")
        try Data("second project edit\n".utf8).write(to: other.appendingPathComponent("notes.txt"))
        launch(extraArguments: ["-lastOpenedPaths", "(\"\(other.path)\")"])
        session.app.menuBars.menuBarItems["File"].click()
        session.app.menuItems["Open Recent Project"].firstMatch.click()
        click(session.app.menuItems["other"].firstMatch)
        let secondWindow = session.app.windows.containing(.menuButton, identifier: "other").firstMatch
        XCTAssertTrue(secondWindow.waitForExistence(timeout: 15))
        menu("Stash…", localChanges: true)
        click(session.app.sheets.firstMatch.buttons["Stash"].firstMatch)
        try eventually("active-window-stash") { try self.git("status", "--porcelain", at: other).isEmpty }
        XCTAssertFalse(try git("status", "--porcelain").isEmpty)
        XCTAssertEqual(try git("stash", "list"), "")
        click(secondWindow.buttons["_XCUI:CloseWindow"].firstMatch)
        menu("Stash…", localChanges: true)
        click(session.app.sheets.firstMatch.buttons["Stash"].firstMatch)
        try eventually("returned-window-stash") { try self.git("status", "--porcelain").isEmpty }
        XCTAssertFalse(try git("stash", "list").isEmpty)
    }

    func test10ChineseConflictControlsFitMinimumWindow() throws {
        try prepareConflict()
        XCTAssertThrowsError(try git("merge", "topic"))
        launch(language: "zh-Hans")
        let window = session.window
        let delta = CGVector(dx: 980 - window.frame.width, dy: 640 - window.frame.height)
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
        corner.press(forDuration: 0.3, thenDragTo: corner.withOffset(delta))
        XCTAssertEqual(window.frame.width, 980, accuracy: 2)
        XCTAssertEqual(window.frame.height, 640, accuracy: 2)
        if !session.app.buttons["全部接受 Theirs"].firstMatch.exists {
            click(session.app.buttons["解决冲突"].firstMatch)
        }
        for title in ["全部接受 Ours", "全部接受 Theirs", "标记已解决", "关闭"] {
            let button = session.app.buttons[title].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            XCTAssertTrue(button.isEnabled, "Chinese control is disabled: \(title)")
            XCTAssertTrue(window.frame.contains(button.frame), "Chinese control overflows: \(title)")
        }
        for title in ["当前分支（ours）", "结果（可编辑）", "被合并分支（theirs）", "1 个冲突文件", "已选择 1 项"] {
            XCTAssertTrue(session.app.staticTexts[title].firstMatch.waitForExistence(timeout: 5),
                          "Native editor header ignores the selected language: \(title)")
        }
        session.recordScreenshot(named: "conflict-zh-Hans-980")
        click(session.app.buttons["全部接受 Theirs"].firstMatch)
        click(session.app.buttons["标记已解决"].firstMatch)
        try eventually("chinese-conflict-resolved") {
            try self.git("diff", "--name-only", "--diff-filter=U").isEmpty
        }
        let complete = session.app.buttons["完成合并"].firstMatch
        XCTAssertTrue(window.frame.contains(complete.frame))
        click(complete)
        try eventually("chinese-merge-complete") {
            try self.git("rev-list", "--parents", "-1", "HEAD").split(separator: " " ).count == 3
                && self.git("status", "--porcelain").isEmpty
        }
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("notes.txt"), encoding: .utf8), "topic version\n")
    }
}
