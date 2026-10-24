import SwiftUI
import AppKit

@main
struct ArborApp: App {
    @NSApplicationDelegateAdaptor(ArborAppDelegate.self) private var appDelegate
    @AppStorage("arbor.appLanguage") private var appLanguageRawValue = AppLanguage.defaultLanguage.rawValue

    init() {
        Design.Typography.registerFonts()
        ArborAppIconController.install()
        migrateLegacyPersistedStatusCaches()
        let savedPath = UserDefaults.standard.string(forKey: "arbor.git.executable") ?? ""
        if !savedPath.isEmpty {
            _ = try? setGitExecutable(path: savedPath)
        }
    }

    private var appLanguage: AppLanguage {
        AppLanguage.resolve(appLanguageRawValue)
    }

    /// A value-based WindowGroup is useful for opening additional projects,
    /// but it does not create a window when the app is launched from the
    /// command line with `--args`. Keep a dedicated launch scene so the run
    /// script always presents the requested repository in the foreground.
    private var commandLineProjectPath: String? {
        CommandLine.arguments.dropFirst().first { argument in
            guard !argument.hasPrefix("-") else { return false }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: argument, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    private var commandLineStartsWithLog: Bool {
        CommandLine.arguments.contains("--log")
    }

    /// Hosted XCTest launches the application bundle only to inject the test
    /// bundle. It is not a user workspace launch. Constructing the full
    /// project shell here makes SwiftUI restore a window, open the most recent
    /// repository, and mutate several @State values while XCTest is still
    /// installing the bundle; that is the source of the AttributeGraph cycle
    /// spam seen in `xcodebuild test`. Keep the host scene inert and let the
    /// test bundle exercise the application module directly.
    private var isRunningUnderXCTest: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }

    @ViewBuilder
    private var launchRoot: some View {
        if isRunningUnderXCTest || ArborPinentryProcess.isInvocation {
            Color.clear
        } else {
            ContentView(
                projectPath: commandLineProjectPath,
                initialToolWindowMode: commandLineStartsWithLog ? .log : .commit
            )
            .environment(\.locale, appLanguage.locale)
        }
    }

    var body: some Scene {
        // The primary launch scene is intentionally not value-based. macOS
        // opens it immediately, which is required for `build_and_run.sh` and
        // for double-clicking Arbor in Finder.
        WindowGroup("Project", id: "launch") {
            launchRoot
        }
        .windowStyle(.hiddenTitleBar)

        // Additional project windows retain an explicit value so opening a
        // recent project or a worktree never overwrites the current window.
        WindowGroup("Project", id: "project", for: String.self) { projectPath in
            ContentView(
                projectPath: projectPath.wrappedValue,
                initialToolWindowMode: .commit
            )
                .environment(\.locale, appLanguage.locale)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            ProjectCommands()
        }

        WindowGroup("Git Log", id: "git-log", for: ExternalLogWindowRequest.self) { request in
            if let request = request.wrappedValue {
                ExternalLogWindowRootView(request: request)
                    .environment(\.locale, appLanguage.locale)
            } else {
                ExternalLogWindowRequestUnavailableView()
                    .environment(\.locale, appLanguage.locale)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1642, height: 1015)

        Window("About Arbor", id: "about") {
            AboutView()
                .environment(\.locale, appLanguage.locale)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 430, height: 500)

        Settings {
            DiagnosticsSettingsView()
                .environment(\.locale, appLanguage.locale)
        }
    }
}
