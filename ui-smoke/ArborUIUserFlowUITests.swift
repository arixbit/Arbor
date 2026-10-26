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

    /// Paste through the Edit menu instead of sending keystrokes: XCTest typing
    /// composes ASCII through whichever input method the host has active, which
    /// leaves fields empty (or with the wrong text) when a Chinese layout is on.
    private func enter(_ value: String, into field: XCUIElement) {
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
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
        for _ in 1...3 {
            click(field)
            session.app.menuBars.menuBarItems["Edit"].click()
            let selectAll = session.app.menuItems["Select All"].firstMatch
            XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
            click(selectAll)
            board.clearContents()
            XCTAssertTrue(board.setString(value, forType: .string))
            session.app.menuBars.menuBarItems["Edit"].click()
            let paste = session.app.menuItems["Paste"].firstMatch
            XCTAssertTrue(paste.waitForExistence(timeout: 5))
            click(paste)
            if field.value as? String == value { return }
        }
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

    func test11ChineseMultiRootBranchesFitMinimumWindow() throws {
        let project = root.appendingPathComponent("frontend")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        repo = project
        try prepare()
        let backend = project.appendingPathComponent("backend")
        try git("init", "--initial-branch=main", backend.path, at: project)
        try git("config", "user.name", "Arbor User Flow", at: backend)
        try git("config", "user.email", "flow@arbor.invalid", at: backend)
        try git("-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Backend initial", at: backend)
        try Data("backend/\n".utf8).write(to: repo.appendingPathComponent(".git/info/exclude"))
        let longBranch = "feature/localization-audit-with-a-deliberately-long-branch-name"
        for directory in [repo!, backend] {
            try git("switch", "-c", longBranch, at: directory)
            try git("-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Branch tip", at: directory)
            try git("switch", "main", at: directory)
        }
        let heads = try [repo!, backend].map { try git("rev-parse", "HEAD", at: $0) }
        session = ArborUISession(fixture: project, screenshotSink: { self.add($0) })
        session.extraLaunchArguments = ["-arbor.appLanguage", "zh-Hans"]
        session.launch()
        let window = session.window
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.3, thenDragTo: corner.withOffset(CGVector(
            dx: 980 - window.frame.width, dy: 640 - window.frame.height
        )))
        XCTAssertEqual(window.frame.width, 980, accuracy: 2)
        XCTAssertEqual(window.frame.height, 640, accuracy: 2)
        XCTAssertTrue(session.openBranchesPopover())
        func capturePopup(_ name: String) {
            let attachment = XCTAttachment(screenshot: session.app.popovers.firstMatch.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        capturePopup("multi-root-branches-zh-Hans-980")
        let tree = XCTAttachment(string: session.app.debugDescription)
        tree.name = "multi-root-branches-chinese-tree"
        tree.lifetime = .keepAlways
        add(tree)
        let popup = session.app.popovers.firstMatch
        let references = session.app.scrollViews["multi-root-branch-reference-list"].firstMatch
        XCTAssertTrue(references.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(references.frame.height, 300)
        XCTAssertTrue(session.app.staticTexts["2 个仓库"].firstMatch.waitForExistence(timeout: 5))
        for title in ["提交变更…", "新建分支…", "检出 Tag 或版本…"] {
            let buttons = session.app.buttons.matching(NSPredicate(format: "label == %@", title))
            XCTAssertEqual(buttons.count, 1, "Duplicate or untranslated action: \(title)")
            XCTAssertTrue(popup.frame.contains(buttons.firstMatch.frame), "Action overflows: \(title)")
            XCTAssertTrue(references.frame.contains(buttons.firstMatch.frame))
        }
        let actions = popup.menuButtons["操作"].firstMatch
        XCTAssertTrue(actions.isHittable)
        XCTAssertTrue(popup.frame.contains(actions.frame))
        click(actions)
        XCTAssertTrue(session.app.menuItems["配置远程…"].firstMatch.isEnabled)
        XCTAssertFalse(session.app.menuItems["远程操作…"].firstMatch.exists)
        actions.click()
        let search = session.app.textFields["过滤分支"].firstMatch
        XCTAssertTrue(popup.frame.contains(search.frame))
        func pasteSearch(_ text: String) {
            XCTAssertEqual(search.value as? String, "")
            enter(text, into: search)
        }
        pasteSearch("backend")
        let repository = session.app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "backend")).firstMatch
        click(repository)
        let allRepositories = session.app.buttons["所有仓库"].firstMatch
        XCTAssertTrue(allRepositories.waitForExistence(timeout: 5))
        XCTAssertTrue(session.app.staticTexts["1 个仓库"].firstMatch.exists)
        XCTAssertTrue(session.app.staticTexts["位于 backend"].firstMatch.exists)
        pasteSearch("localization-audit")
        let branch = references.staticTexts[String(longBranch.split(separator: "/").last!)].firstMatch
        XCTAssertTrue(branch.waitForExistence(timeout: 5))
        XCTAssertTrue(branch.isHittable)
        XCTAssertTrue(references.frame.contains(branch.frame))
        XCTAssertTrue(references.staticTexts["没有贮藏"].firstMatch.exists)
        capturePopup("multi-root-branch-search-zh-Hans-980")
        let branchMenu = try XCTUnwrap(references.menuButtons.allElementsBoundByIndex.first {
            !$0.frame.isEmpty && abs($0.frame.midY - branch.frame.midY) < 3
        })
        click(branchMenu)
        let merge = try XCTUnwrap(session.app.menuItems.matching(identifier: "在多个仓库中合并…")
            .allElementsBoundByIndex.first { !$0.frame.isEmpty })
        click(merge)
        let sheet = session.app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.staticTexts["合并分支"].firstMatch.exists)
        XCTAssertTrue(sheet.staticTexts["在 Git roots 中 Merge \(longBranch)"].firstMatch.exists)
        XCTAssertTrue(sheet.staticTexts["已选择 2 个仓库"].firstMatch.exists)
        XCTAssertTrue(sheet.staticTexts["自动（可用时 fast-forward）"].firstMatch.exists)
        for name in ["frontend", "backend"] {
            XCTAssertTrue(sheet.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch.exists)
        }
        session.recordScreenshot(named: "multi-root-branch-merge-cancel-zh-Hans-980")
        click(sheet.buttons["取消"].firstMatch)
        XCTAssertFalse(sheet.exists)
        XCTAssertTrue(session.openBranchesPopover())
        XCTAssertTrue(session.app.staticTexts["2 个仓库"].firstMatch.waitForExistence(timeout: 5))
        pasteSearch("backend")
        click(repository)
        XCTAssertTrue(allRepositories.waitForExistence(timeout: 5))
        click(allRepositories)
        // Leaving the repository scope restores the speed-search text, as in IntelliJ.
        XCTAssertEqual(search.value as? String, "backend")
        XCTAssertFalse(session.app.buttons["所有仓库"].firstMatch.exists)
        XCTAssertFalse(session.app.staticTexts["位于 backend"].firstMatch.exists)
        XCTAssertTrue(session.app.staticTexts["1 个仓库"].firstMatch.exists)
        click(search)
        session.app.menuBars.menuBarItems["Edit"].click()
        click(session.app.menuItems["Select All"].firstMatch)
        search.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        XCTAssertEqual(search.value as? String, "")
        XCTAssertTrue(session.app.staticTexts["2 个仓库"].firstMatch.waitForExistence(timeout: 5))
        for (index, directory) in [repo!, backend].enumerated() {
            XCTAssertEqual(try git("rev-parse", "HEAD", at: directory), heads[index])
            XCTAssertEqual(try git("branch", "--show-current", at: directory), "main")
            XCTAssertEqual(try git("status", "--porcelain", at: directory), "")
        }
        print("USER_FLOW_PASS chinese-multi-root-branches")
    }

    func test12ChineseOperationDialogsUseTranslatedOptions() throws {
        try prepare()
        launch(language: "zh-Hans")
        menu("Pull…")
        let pull = session.app.buttons["Pull"].firstMatch
        XCTAssertTrue(pull.waitForExistence(timeout: 10))
        XCTAssertTrue(session.app.staticTexts["默认"].firstMatch.waitForExistence(timeout: 5))
        let modify = session.app.menuButtons["修改…"].firstMatch
        XCTAssertTrue(modify.waitForExistence(timeout: 5))
        click(modify)
        XCTAssertTrue(session.app.menuItems["仅 fast-forward"].firstMatch.waitForExistence(timeout: 5))
        session.recordScreenshot(named: "pull-options-zh-Hans")
        session.app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        click(session.app.buttons["取消"].firstMatch)
        XCTAssertFalse(pull.exists)

        menu("Push…")
        let pushTags = session.app.checkBoxes["推送标签"].firstMatch
        XCTAssertTrue(pushTags.waitForExistence(timeout: 10))
        click(pushTags)
        let tagMode = session.app.popUpButtons
            .matching(NSPredicate(format: "value == %@ OR label == %@", "所有标签", "所有标签"))
            .firstMatch
        XCTAssertTrue(tagMode.waitForExistence(timeout: 5))
        session.recordScreenshot(named: "push-options-zh-Hans")
        click(session.app.buttons["取消"].firstMatch)
        let pushSheet = session.app.sheets.firstMatch
        XCTAssertTrue(pushSheet.waitForNonExistence(timeout: 10), "Push sheet did not close")

        session.app.activate()
        let window = session.window
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.3, thenDragTo: corner.withOffset(CGVector(
            dx: 980 - window.frame.width, dy: 640 - window.frame.height
        )))
        XCTAssertEqual(window.frame.width, 980, accuracy: 2)
        XCTAssertEqual(window.frame.height, 640, accuracy: 2)
        XCTAssertTrue(session.openBranchesPopover())
        let actions = session.app.menuButtons["操作"].firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        click(actions)
        let projectSettings = session.app.menuItems["项目 Git 设置…"].firstMatch
        XCTAssertTrue(projectSettings.waitForExistence(timeout: 5))
        click(projectSettings)
        let sheet = session.app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.staticTexts["项目 Git 设置"].firstMatch.exists)
        let incoming = sheet.popUpButtons
            .matching(NSPredicate(format: "value == %@", "使用全局 Git 设置"))
            .firstMatch
        XCTAssertTrue(incoming.waitForExistence(timeout: 5))
        let save = sheet.buttons["保存"].firstMatch
        let cancel = sheet.buttons["取消"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isHittable, "Save is outside the sheet")
        XCTAssertTrue(cancel.isHittable, "Cancel is outside the sheet")
        XCTAssertTrue(session.window.frame.contains(save.frame))
        XCTAssertTrue(session.window.frame.contains(cancel.frame))
        session.recordScreenshot(named: "project-git-settings-zh-Hans")
        click(cancel)
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        print("USER_FLOW_PASS chinese-operation-dialogs")
    }

    func test13ChineseMultiRootBranchDialogs() throws {
        let project = root.appendingPathComponent("frontend")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        repo = project
        try prepare()
        let backend = project.appendingPathComponent("backend")
        try git("init", "--initial-branch=main", backend.path, at: project)
        try git("config", "user.name", "Arbor User Flow", at: backend)
        try git("config", "user.email", "flow@arbor.invalid", at: backend)
        try git("-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Backend initial", at: backend)
        try Data("backend/\n".utf8).write(to: repo.appendingPathComponent(".git/info/exclude"))
        for directory in [repo!, backend] {
            try git("branch", "shared", at: directory)
        }
        launch(language: "zh-Hans")
        XCTAssertTrue(session.openBranchesPopover())
        click(session.app.buttons["新建分支…"].firstMatch)
        let sheet = session.app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.staticTexts["新建分支"].firstMatch.exists)
        XCTAssertTrue(sheet.staticTexts["在 Git 根仓库中创建"].firstMatch.exists)
        XCTAssertTrue(sheet.staticTexts["已选择 2 个仓库"].firstMatch.exists)
        XCTAssertTrue(sheet.checkBoxes["全部仓库"].firstMatch.exists)
        session.recordScreenshot(named: "multi-root-new-branch-zh-Hans")
        click(sheet.buttons["取消"].firstMatch)
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))

        session.app.activate()
        XCTAssertTrue(session.openBranchesPopover())
        let references = session.app.scrollViews["multi-root-branch-reference-list"].firstMatch
        XCTAssertTrue(references.waitForExistence(timeout: 5))
        enter("shared", into: session.app.textFields["过滤分支"].firstMatch)
        let row = references.staticTexts["shared"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let rowMenu = try XCTUnwrap(references.menuButtons.allElementsBoundByIndex.first {
            !$0.frame.isEmpty && abs($0.frame.midY - row.frame.midY) < 3
        })
        click(rowMenu)
        let rename = try XCTUnwrap(session.app.menuItems.matching(identifier: "在多个仓库中重命名…")
            .allElementsBoundByIndex.first { !$0.frame.isEmpty })
        click(rename)
        let renameSheet = session.app.sheets.firstMatch
        XCTAssertTrue(renameSheet.waitForExistence(timeout: 5))
        XCTAssertTrue(renameSheet.staticTexts["在 Git roots 中重命名 shared"].firstMatch.exists)
        XCTAssertTrue(renameSheet.staticTexts["已选择 2 个仓库"].firstMatch.exists)
        XCTAssertTrue(renameSheet.staticTexts["新名称必须不同。"].firstMatch.exists)
        XCTAssertTrue(renameSheet.buttons["重命名"].firstMatch.exists)
        session.recordScreenshot(named: "multi-root-rename-branch-zh-Hans")
        click(renameSheet.buttons["取消"].firstMatch)
        XCTAssertTrue(renameSheet.waitForNonExistence(timeout: 5))

        session.app.activate()
        XCTAssertTrue(session.openBranchesPopover())
        let referencesAgain = session.app.scrollViews["multi-root-branch-reference-list"].firstMatch
        XCTAssertTrue(referencesAgain.waitForExistence(timeout: 5))
        enter("shared", into: session.app.textFields["过滤分支"].firstMatch)
        let rowAgain = referencesAgain.staticTexts["shared"].firstMatch
        XCTAssertTrue(rowAgain.waitForExistence(timeout: 5))
        let rowMenuAgain = try XCTUnwrap(referencesAgain.menuButtons.allElementsBoundByIndex.first {
            !$0.frame.isEmpty && abs($0.frame.midY - rowAgain.frame.midY) < 3
        })
        click(rowMenuAgain)
        let delete = try XCTUnwrap(session.app.menuItems.matching(identifier: "在多个仓库中删除…")
            .allElementsBoundByIndex.first { !$0.frame.isEmpty })
        click(delete)
        let deleteSheet = session.app.sheets.firstMatch
        XCTAssertTrue(deleteSheet.waitForExistence(timeout: 5))
        XCTAssertTrue(deleteSheet.staticTexts["从 Git root 删除 shared"].firstMatch.exists)
        XCTAssertTrue(deleteSheet.buttons["删除"].firstMatch.exists)
        session.recordScreenshot(named: "multi-root-delete-branch-zh-Hans")
        click(deleteSheet.buttons["取消"].firstMatch)
        XCTAssertTrue(deleteSheet.waitForNonExistence(timeout: 5))
        print("USER_FLOW_PASS chinese-multi-root-branch-dialogs")
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
