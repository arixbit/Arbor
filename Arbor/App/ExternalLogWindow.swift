import SwiftUI
import AppKit

func canonicalExternalLogPath(_ path: String) -> String {
    URL(fileURLWithPath: path)
        .standardizedFileURL
        .resolvingSymlinksInPath()
        .path
}

struct ExternalLogWindowRequest: Codable, Hashable, Sendable {
    let projectPath: String
    let rootPaths: [String]

    init(projectPath: String, rootPaths: [String]) {
        self.projectPath = canonicalExternalLogPath(projectPath)
        self.rootPaths = normalizedLogRootPaths(rootPaths.map(canonicalExternalLogPath))
    }
}

struct ExternalLogWindowGeometry: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(frame: NSRect) {
        self.init(
            x: frame.origin.x,
            y: frame.origin.y,
            width: frame.width,
            height: frame.height
        )
    }

    var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

func externalLogWindowGeometryIsUsable(
    _ geometry: ExternalLogWindowGeometry,
    visibleFrames: [CGRect]
) -> Bool {
    geometry.width >= 900
        && geometry.height >= 600
        && visibleFrames.contains { $0.intersects(geometry.rect) }
}

private enum ExternalLogWindowGeometryStore {
    private static let userDefaultsKey = "arbor.externalLog.windowGeometry.v1"

    static func restore(on window: NSWindow) {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let geometry = try? JSONDecoder().decode(
                  ExternalLogWindowGeometry.self,
                  from: data
              ),
              externalLogWindowGeometryIsUsable(
                  geometry,
                  visibleFrames: NSScreen.screens.map(\.visibleFrame)
              ) else {
            return
        }
        window.setFrame(
            NSRect(
                x: geometry.x,
                y: geometry.y,
                width: geometry.width,
                height: geometry.height
            ),
            display: false
        )
    }

    static func save(frame: NSRect) {
        guard let data = try? JSONEncoder().encode(ExternalLogWindowGeometry(frame: frame)) else {
            return
        }
        UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
}

/// Observes the SwiftUI WindowGroup window so external Log can retain the
/// reference window's dimension-service behavior and dispose its session when
/// the window is actually closed.
struct ExternalLogWindowLifecycleView: NSViewRepresentable {
    let onClosed: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onClosed: onClosed)
    }

    func makeNSView(context: Context) -> ExternalLogWindowLifecycleNSView {
        let view = ExternalLogWindowLifecycleNSView()
        view.onWindowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(window)
        }
        return view
    }

    func updateNSView(
        _ view: ExternalLogWindowLifecycleNSView,
        context: Context
    ) {
        context.coordinator.onClosed = onClosed
        view.onWindowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(window)
        }
        if let window = view.window {
            context.coordinator.attach(window)
        }
    }

    static func dismantleNSView(
        _ view: ExternalLogWindowLifecycleNSView,
        coordinator: Coordinator
    ) {
        coordinator.detach()
    }

    final class Coordinator: NSObject {
        var onClosed: () -> Void
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var pendingSave: DispatchWorkItem?
        private var didClose = false

        init(onClosed: @escaping () -> Void) {
            self.onClosed = onClosed
        }

        func attach(_ window: NSWindow?) {
            guard self.window !== window else { return }
            detachObservers()
            self.window = window
            didClose = false
            guard let window else { return }

            ExternalLogWindowGeometryStore.restore(on: window)
            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: NSWindow.didResizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in self?.scheduleSave() },
                center.addObserver(
                    forName: NSWindow.didMoveNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in self?.scheduleSave() },
                center.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in self?.handleClose() }
            ]
        }

        func detach() {
            saveImmediately()
            detachObservers()
            window = nil
        }

        private func detachObservers() {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
            pendingSave?.cancel()
            pendingSave = nil
        }

        private func scheduleSave() {
            pendingSave?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.saveImmediately()
            }
            pendingSave = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }

        private func saveImmediately() {
            guard let window else { return }
            ExternalLogWindowGeometryStore.save(frame: window.frame)
        }

        private func handleClose() {
            guard !didClose else { return }
            didClose = true
            saveImmediately()
            onClosed()
            detachObservers()
            window = nil
        }

        deinit {
            detachObservers()
        }
    }
}

final class ExternalLogWindowLifecycleNSView: NSView {
    var onWindowChanged: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged?(window)
    }
}

private enum ExternalLogProviderPhase: Equatable {
    case loading
    case ready
    case failed(String)
}

/// Keeps the external Log scene in a provider-loading state until the
/// project-effective Git executable has passed the same version check used by
/// IntelliJ's GitExternalLogService. SwiftUI cancels the task automatically
/// if the WindowGroup scene is closed before initialization finishes.
struct ExternalLogWindowRootView: View {
    let request: ExternalLogWindowRequest
    @Environment(\.locale) private var locale
    @State private var phase: ExternalLogProviderPhase = .loading
    @State private var logManager: ExternalLogManager?
    @State private var retryGeneration = 0

    private var providerTaskID: String {
        let roots = request.rootPaths.joined(separator: "\u{0}")
        return "\(request.projectPath)\u{0}\(roots)\u{0}\(retryGeneration)"
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Preparing Git Log…")
                        .font(.headline)
                    Text("Checking the project Git executable before loading the selected roots.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                if let logManager {
                    ContentView(
                        projectPath: request.projectPath,
                        initialToolWindowMode: .log,
                        externalLogWindow: true,
                        initialExternalLogRootPaths: request.rootPaths,
                        externalLogProviderSession: logManager.providerSession,
                        externalLogUIManager: logManager
                    )
                    .environment(\.locale, locale)
                } else {
                    ProgressView("Preparing Git Log…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case let .failed(message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundStyle(.orange)
                    Text("Git Log could not be initialized")
                        .font(.headline)
                    Text(message)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    Button("Retry") {
                        retryGeneration &+= 1
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background {
            // Keep geometry restoration active while the provider is still
            // loading; ContentView installs the same bridge after readiness
            // to dispose the root-scoped session on close.
            ExternalLogWindowLifecycleView(onClosed: {})
        }
        .task(id: providerTaskID) {
            await prepareProvider()
        }
    }

    private func prepareProvider() async {
        phase = .loading
        logManager?.dispose()
        logManager = nil
        let executable = GitExecutableSettings.projectOverride(for: request.projectPath)
            ?? gitExecutable()
        do {
            let manager = try await Task.detached(priority: .userInitiated) {
                try ExternalLogManager.initialize(
                    request: request,
                    executable: executable
                )
            }.value
            guard !Task.isCancelled else {
                manager.dispose()
                return
            }
            logManager = manager
            phase = .ready
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(String(describing: error))
        }
    }

}

struct ExternalLogWindowRequestUnavailableView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text("Git Log request is unavailable")
                .font(.headline)
            Text("Close this window and choose one or more Git roots again.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Mirrors IntelliJ's GitShowExternalLogAction root chooser: the user picks
/// directories first, and only directories that are themselves Git roots are
/// passed to the external Log window.
func chooseExternalLogWindowRequest(for projectPath: String) -> ExternalLogWindowRequest? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.canCreateDirectories = false
    panel.prompt = "Open Git Log"
    panel.message = "Select one or more Git roots to show in the external Log window."
    panel.directoryURL = URL(fileURLWithPath: projectPath)
    guard panel.runModal() == .OK else { return nil }

    let roots = normalizedLogRootPaths(panel.urls.compactMap { url in
        let path = canonicalExternalLogPath(url.path)
        guard let repository = try? openRepository(path: path),
              let workdir = repository.workdir(),
              canonicalExternalLogPath(workdir) == path else {
            return nil
        }
        return path
    })
    guard !roots.isEmpty else { return nil }
    return ExternalLogWindowRequest(projectPath: projectPath, rootPaths: roots)
}
