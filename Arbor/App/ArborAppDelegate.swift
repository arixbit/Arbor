import SwiftUI
import AppKit

@MainActor
final class ArborAppDelegate: NSObject, NSApplicationDelegate {
    // SwiftUI may replace the delegate instance while it is materialising a
    // WindowGroup. Keep the explicit AppKit host independent of that
    // lifecycle so the `open --args` window cannot disappear immediately
    // after applicationDidFinishLaunching returns.
    private static var fallbackWindow: NSWindow?
    private static var fallbackController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ArborPinentryProcess.isInvocation {
            NSApp.setActivationPolicy(.prohibited)
            _ = ArborPinentryProcess.startIfRequested()
            return
        }
        NSApp.setActivationPolicy(.regular)
        ArborNativeNotificationCenter.shared.install()
        // `open --args` can be terminated by AppKit's automatic-termination
        // pass before a delayed SwiftUI WindowGroup materialises. Create the
        // explicit project window during launch, then let the normal scene
        // handle Finder/Xcode launches.
        let hasExplicitLaunchRequest = CommandLine.arguments.contains("--log")
            || CommandLine.arguments.dropFirst().contains { argument in
                guard !argument.hasPrefix("-") else { return false }
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: argument, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
        if hasExplicitLaunchRequest {
            ensureLaunchWindowIfNeeded()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.ensureLaunchWindowIfNeeded()
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !ArborPinentryProcess.isInvocation else { return }
        ArborNativeNotificationCenter.shared.refreshAuthorizationStatus()
    }

    private func ensureLaunchWindowIfNeeded() {
        guard !ArborPinentryProcess.isInvocation else { return }
        // A hosted XCTest process must remain windowless. For a real launch,
        // however, a WindowGroup can be restored without materialising a
        // visible window (this is reproducible after a previous hidden-title
        // bar window restoration). The old code only enabled this fallback
        // for `open --args <repository>`, so a normal Finder/Xcode launch
        // could leave Arbor running with zero windows. Rebased always keeps a
        // project window available; use the same rule here and only skip the
        // fallback for the test host.
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCTestBundlePath"] == nil,
              environment["XCTestSessionIdentifier"] == nil else {
            return
        }

        // A value-based scene can remain windowless when the app was started
        // with `open --args <repository>`. Only create the AppKit bridge when
        // SwiftUI did not create any visible project window itself.
        guard !NSApp.windows.contains(where: { $0.isVisible && $0.contentView != nil }) else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let projectPath = CommandLine.arguments.dropFirst().first { argument in
            guard !argument.hasPrefix("-") else { return false }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: argument, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
        let language = AppLanguage.resolve(
            UserDefaults.standard.string(forKey: "arbor.appLanguage")
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1642, height: 1015),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Arbor"
        window.isRestorable = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.level = .normal
        window.minSize = NSSize(width: 980, height: 540)
        // Put a lightweight AppKit view in the window before constructing the
        // large SwiftUI workspace. This makes the window visible before
        // AppKit's automatic-termination pass can observe an empty app, and
        // keeps repository loading out of window creation.
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1642, height: 1015))
        window.center()
        Self.fallbackWindow = window
        let controller = NSWindowController(window: window)
        Self.fallbackController = controller
        controller.showWindow(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)

        let launchMode: ToolWindowMode = CommandLine.arguments.contains("--log") ? .log : .commit
        DispatchQueue.main.async {
            guard Self.fallbackWindow === window else { return }
            let content = ContentView(
                projectPath: projectPath,
                initialToolWindowMode: launchMode
            )
            .environment(\.locale, language.locale)
            // Assigning an NSHostingView directly as a window content view
            // does not reliably adopt the window's content bounds on a
            // manually-created AppKit window. Without an explicit frame the
            // window exists but the SwiftUI surface renders as a black,
            // zero-sized view on launch.
            let hostingView = NSHostingView(rootView: content)
            // The workspace already includes the full titlebar area. Let the
            // explicit window minimum govern resizing instead of adding the
            // hosting view's safe-area inset to its 540pt minimum a second time.
            hostingView.sizingOptions = []
            hostingView.frame = window.contentView?.bounds ?? NSRect(origin: .zero, size: window.frame.size)
            hostingView.autoresizingMask = [.width, .height]
            window.contentView = hostingView
            hostingView.needsLayout = true
            hostingView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            Self.fallbackController?.showWindow(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
